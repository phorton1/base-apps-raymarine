#---------------------------------------------
# shark.pm
#---------------------------------------------
package apps::raymarine::NET::shark;
use strict;
use warnings;
use threads;
use threads::shared;
use Socket;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use Pub::WX::Resources;
use Pub::WX::Main;
use Win32::Console;
use apps::raymarine::NET::r_utils;
use apps::raymarine::NET::r_sniffer;
use apps::raymarine::NET::r_RAYDP;
use apps::raymarine::NET::r_E80NAV;
use apps::raymarine::NET::s_resources;
use apps::raymarine::NET::s_frame;
use base 'Wx::App';


my $dbg_shark = 0;

our $SEND_ALIVE:shared = 0;

BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

        $SEND_ALIVE
    );
}

my $console_in;
my $sock_listen;


# When I sniffed these packets from RNS to the E80, {PORT} was 0048=0x4800 which is 18432
# To create these message, which register a listener port with an E80 udp function which
# accepts requests, we replace those bytes

# port(2049) is tending toward the CHARTREQ 'function'
# I'm not sure if I should have a separate listener for
# each 'function'


my $IP_2049 = '10.0.241.54';
my $PORT_2049 = 2049;

my $LISTEN_2049_PORT = 0x4801;  # 18433;
my $REGISTER_2049_TEMPLATE = "0901050000000000{PORT}";
my $REQUEST_2049_TEMPLATE = "0201050010110000{PORT}009a4c00000400001c005c4e6176696f6e69635c4368617274735c3347313338584c2e4e5632";
    #   .........H.šL.......\Navionic\Charts\3G138XL.NV2
    # an alternative is "0101050002000000{PORT}00000e005c6368617274 6361742e786d6c00"
    #   .........H....\chartcat.xml.

# The first packet sent, apart from WAKEUP/ALIVE by RNS is a registration packet
#   udp 10.0.241.54:2049 <-- 10.0.241.200:65362        09010500 00000000 0048
# The E80 responds by sending a udp packet to 0048 == 18432, perhaps an ack of th eregistration
#   10.0.241.54:1215     --> 10.0.241.200:18432    09000500 00000000 >>> ...0014802A08W7
# (I get the exact same packet back when I "register" with 2049)


# The next thing that happens is with 2050 GPS,
# It appears as if a local, two way tcp port is opened to 2050 ..
#   tcp 10.0.241.54:2050     <-- 10.0.241.200:51877    0800                                                                      ..
#   tcp 10.0.241.54:2050     <-- 10.0.241.200:51877    02011000 62000000                                                         ....b...
#   tcp 10.0.241.54:2050     <-- 10.0.241.200:51877    0c00                                                                      ..
#   tcp 10.0.241.54:2050     <-- 10.0.241.200:51877    05011000 01000000 62000000
# I don't know what the 6200 is
#     51877 = 0xCAA5 (A5CA in hex format)
#     0x62 = 98 if its on the uint32 boundry
#     0x6200 = 25088 doesn't match anything
# After this, the E80 apparently sends an E80NAV packet
#   udp(36)   224.30.38.195:2562   <-- 10.0.241.54:1217      00031000 02000000 17000000 2a000200 b8650506 00004700 00002a00 0200e767   ............*....e....G...*....g
#       E80NAV len(26) type(0x17) version(0x02)
#           6     HEAD(DEV,b865)                149.20
#           20    HEAD(ABS,e767)                152.40
# Before responding with a reply from 2050
#   tcp(2)    10.0.241.54:2050     --> 10.0.241.200:51877    1000
# After which some big 2563 packet is sent, and more 2050 packets
#   start going back and forth.

# I don't know if I really have to join multicast groups
# for the E80 to respond, or if I can send these things blindly.
# What I do suspect is that it will be very difficult to open
# all needed sockets inline in this main perl thread.
# And I'm already seeing wonky behavior from threads in general.




sub createPortifiedPacket
{
    my ($port,$hex) = @_;
    my $packed_port = pack('v',$port);
    my $hex_port = unpack("H*",$packed_port);
    $hex =~ s/{PORT}/$hex_port/g;
    return pack("H*",$hex);
}


sub sendPortifiedPacket
{
    my ($name,$dest_ip,$dest_port,$listen_port,$template) = @_;
    display(0,1,"sending $name packet");
    if (!$LOCAL_UDP_SOCKET)
    {
        error("LOCAL_UDP_SOCKET not open in sendRequest packet");
        return;
    }
    my $dest_addr = pack_sockaddr_in($dest_port, inet_aton($dest_ip));
    my $packet = createPortifiedPacket($listen_port,$template);
    $LOCAL_UDP_SOCKET->send($packet, 0, $dest_addr);
    display(0,1,"$name packet sent");
}


#-----------------------------------------
# serial_thread
#-----------------------------------------



sub openConsoleIn
{
    $console_in = Win32::Console->new(STD_INPUT_HANDLE);
    $console_in->Mode(ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT ) if $console_in;
    $console_in ?
        display(0,0,"openConsoleIn() succeeded") :
        error("openConsoleIn() failed");
    return $console_in;
}

sub isEventCtrlC
    # my ($type,$key_down,$repeat_count,$key_code,$scan_code,$char,$key_state) = @event;
    # my ($$type,posx,$posy,$button,$key_state,$event_flags) = @event;
{
    my (@event) = @_;
    if ($event[0] &&
        $event[0] == 1 &&      # key event
        $event[5] == 3)        # char = 0x03
    {
        warning(0,0,"ctrl-C pressed ...");
        return 1;
    }
    return 0;
}


sub getChar
{
    my (@event) = @_;
    if ($event[0] &&
        $event[0] == 1 &&       # key event
        $event[1] == 1 &&       # key down
        $event[5])              # char
    {
        return chr($event[5]);
    }
    return undef;
}



sub serial_thread
{
    display(0,0,"serial_thread() started");
    while (1)
    {
        if ($console_in->GetEvents())
        {
            my @event = $console_in->Input();
            if (@event && isEventCtrlC(@event))			# CTRL-C
            {
                warning(0,0,"EXITING PROGRAM from serial_thread()");
                kill 6,$$;
            }
            my $char = getChar(@event);
            if (defined($char))
            {
                if (ord($char) == 1)            # CTRL-A
                {
                    sendPortifiedPacket(
                        "register2049",
                        $IP_2049,
                        $PORT_2049,
                        $LISTEN_2049_PORT,
                        $REGISTER_2049_TEMPLATE);
                }
                elsif (ord($char) == 2)            # CTRL-B
                {
                    sendPortifiedPacket(
                        "request2049",
                        $IP_2049,
                        $PORT_2049,
                        $LISTEN_2049_PORT,
                        $REQUEST_2049_TEMPLATE);
                }

                # The above commands work with no RNS on a fresh E80
                # without any keep alives, etc.  However, we are not
                # getting any other "regular" packets, except for 5801
                # "ALIVE" packets.

                elsif (ord($char) == 4)            # CTRL-D
                {
                    $CONSOLE->Cls();    # manually clear the screen
                }
                elsif ($char eq 'w')
                {
                    wakeup_e80();
                }
                elsif ($char eq 'a')
                {
                    $SEND_ALIVE = $SEND_ALIVE ? 0 : 1;
                    warning(0,0,"SEND_ALIVE=$SEND_ALIVE");
                }
            }
        }
    }
}



#-----------------------------------------
# sniffer thread
#-----------------------------------------





my $xml = '';


sub sniffer_thread
{
    display($dbg_shark,0,"sniffer thread started");
    while (1)
    {
        my $packet = nextSniffPacket();
        if ($packet)
        {
            my $len = length($packet->{raw_data});
            display($dbg_shark+1,1,"got $packet->{proto} packet len($len)");
            if ($packet->{udp} &&
                # $packet->{dest_ip} eq $RAYDP_IP &&
                $packet->{dest_port} == $RAYDP_PORT)
            {
                decodeRAYDP($packet);
                next;
            }

            my $ray_src = findRayPort($packet->{src_ip},$packet->{src_port});
            my $ray_dest = findRayPort($packet->{dest_ip},$packet->{dest_port});
            my $dest_18432 = $packet->{dest_port} == 18432 ? {
                color => $UTILS_COLOR_BROWN,
                multi => 0, } : 0;

            if (0 && $dest_18432)
            {
                # found an xml file
                # the length of most of the packets is 1042, last is 428
                #
                #
                #   raw_data offset
                #       12 = uint16 = 6800 = number of packets = 0x68
                #       14 = uint16 = 0000 = packet number
                #       16 = uint16 = packet_bytes
                #           most: 0004 (0x0400) = 1024
                #           last; 9a01 (0x019a) = 410
                #       18 = start of text, 0x0a delimited lines,
                #
                # So, baaed on packet size alone
                #       most 1042 = 18 = 1024 bytes of text
                #       last 428 - 18 = 410
                #   agrees with interpretation of packet_bytes

                my $raw_data = $packet->{raw_data};
                my $start_xml = $raw_data =~ /<\?xml/ ? 1 : 0;
                $dest_18432->{multi} = 1 if $start_xml;

                # $dest_18432->{multi} = 1 if
                #     $packet->{raw_data} =~ /<\?xml/ ||
                #     $packet->{hex_data} =~ /68006700/;

                if ($xml || $start_xml)
                {
                    my ($num_packets,$packet_num,$bytes) = unpack('v3',substr($raw_data,12,6));
                    display(0,1,"xml num($packet_num/$num_packets) bytes($bytes)");
                    $xml .= substr($raw_data,18);
                    if ($packet_num == $num_packets-1)
                    {
                        printVarToFile(1,"/junk/test.xml",$xml,1);
                        $xml = '';
                        $dest_18432->{multi} = 1
                    }
                }

                showPacket($dest_18432,$packet,0);
            }
            elsif ($ray_src && $ray_src->{mon_out})
            {
                showPacket($ray_src,$packet,0);
            }
            elsif ($ray_dest && $ray_dest->{mon_in})
            {
                showPacket($ray_dest,$packet,1);
                if ($ray_dest->{name} eq "E80NAV")
                {
                    handleE80NAV($packet);
                }
            }


            if (0 && ($packet->{raw_data} =~ /Waypoint (\w+)/ ||
                      $packet->{raw_data} =~ /(Popa\d\d)/i))
            {
                my $wp_name = $1;
                # print "ray_src("._def($ray_src).") ray_dest("._def($ray_dest).") ";
                print "$packet->{src_ip}:$packet->{src_port} --> $packet->{dest_ip}:$packet->{dest_port} : Found Waypoint: $wp_name\n";
            }
            elsif (0 && $packet->{raw_data} =~ /(\w+\.xml)/)
            {
                my $xml = $1;
                # print "ray_src("._def($ray_src).") ray_dest("._def($ray_dest).") ";
                print "$packet->{src_ip}:$packet->{src_port} --> $packet->{dest_ip}:$packet->{dest_port} : Found XMK: $xml\n";
            }

            # udp(10)   10.0.241.54:2049     <-- 10.0.241.200:55481    09010500 00000000 0048

            elsif ($packet->{raw_data} =~ /(navionic)/i && $packet->{dest_port} != 2049)
            {
                # print "ray_src("._def($ray_src).") ray_dest("._def($ray_dest).") ";
                print "$packet->{src_ip}:$packet->{src_port} --> $packet->{dest_ip}:$packet->{dest_port} : Found NAVIONIC\n";
            }


            # elsif ($packet->{tcp} && $packet->{src_ip} eq '10.0.241.200')
            # {
            #     # print "ray_src("._def($ray_src).") ray_dest("._def($ray_dest).") ";
            #     print packetWireHeader($packet,0)."$packet->{hex32}\n";
            # }
            # elsif ($packet->{tcp} && $packet->{src_ip} eq '10.0.241.54')
            # {
            #     # print "ray_src("._def($ray_src).") ray_dest("._def($ray_dest).") ";
            #     print packetWireHeader($packet,1)."$packet->{hex32}\n";
            # }
        }
        else
        {
            sleep(0.001);
        }
    }
}


#-------------------------------------------------
# listen thread
#-------------------------------------------------


sub listen_udp_thread
    # blocking unidirectional single port monitoring thread
{
    my ($port) = @_;
    display(0,0,"listen_udp_thread($port) started");
    my $sock = IO::Socket::INET->new(
            LocalPort => $LISTEN_2049_PORT,
            Proto     => 'udp',
            ReuseAddr => 1 );
    if (!$sock)
    {
        error("Could not open sock in listen_udp_thread($port)");
        return;
    }
    while (1)
    {
        my $raw;
        recv($sock, $raw, 4096, 0);
        if ($raw)
        {
            # my $hex = unpack("H*",$raw);
            setConsoleColor($UTILS_COLOR_LIGHT_MAGENTA);
            display_bytes(0,0,"listen_udp_thread($port) GOT ".length($raw)." BYTES",$raw);
            # print "LISTEN got $hex\n";
            setConsoleColor();
        }
    }
}



#--------------------------------------------------------
# alive_thread
#--------------------------------------------------------

sub alive_thread
{
    display(0,0,"alive_thread() started");
    while (1)
    {
        sendAlive() if $SEND_ALIVE;
        sleep(1);
    }
}


#---------------------------------------------------------
# tcp thread
#---------------------------------------------------------
# GPS
#   tcp 10.0.241.54:2050     <-- 10.0.241.200:51877    0800                                                                      ..
#   tcp 10.0.241.54:2050     <-- 10.0.241.200:51877    02011000 62000000                                                         ....b...
#   tcp 10.0.241.54:2050     <-- 10.0.241.200:51877    0c00                                                                      ..
#   tcp 10.0.241.54:2050     <-- 10.0.241.200:51877    05011000 01000000 62000000
# NAVQRY
#   tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811    0800
#   tcp(8)    10.0.241.54:2052     <-- 10.0.241.200:52811    b0010f00 00000000
#   tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52811    0c00
#   tcp(12)   10.0.241.54:2052     --> 10.0.241.200:52811    b0000f00 00000000 08000000
#   tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811    0800
#   tcp(8)    10.0.241.54:2052     <-- 10.0.241.200:52811    00010f00 01000000
#   tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811    1400
#   tcp(20)   10.0.241.54:2052     <-- 10.0.241.200:52811    00020f00 01000000 00000000 00000000 1a000000
#   tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811    3400
#   tcp(52)   10.0.241.54:2052     <-- 10.0.241.200:52811    01020f00 01000000 28000000 00000000 00000000 00000000 00000000 00000000
#                                                            10270000 00000000 00000000 00000000 00000000
#   tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811    1000
#   tcp(16)   10.0.241.54:2052     <-- 10.0.241.200:52811    02020f00 01000000 00000000 00000000

# WAYPOINT INDEX

#   tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52811    0c00                                                                      ..
#   tcp(158)  10.0.241.54:2052     --> 10.0.241.200:52811    00000f00 01000000 00000400 14000002 0f000100 00000000 00000000 00001900
#                                                            00006800 01020f00 01000000 5c000000 0b000000 [d18299aa f567e68e] 81b237a6
#                                                            37008ff4 81b237a6 36002a9d 81b237a6 3700208c 81b237a6 36001996 81b237a6
#                                                            370014d0 81b237a6 3600b880 81b237a6 35008a98 81b237a6 34007ff8 81b237a6
#                                                            3500818a 81b237a6 3500478a 10000202 0f000100 00000000 00000000 0000
#
#   Then it appears as if it gets the uint32's d18299aa f567e68e ( 14th and 15th uint32's, 1 based) from that 0c00 packet
#   and increments an index (th2 2nd dword in the packet) and sends a 1000 packet with those bytes.
#   and gets back what looks like a known waypoint (Cristobal)
#
#   tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811    1000                                                                      ..
#   tcp(16)   10.0.241.54:2052     <-- 10.0.241.200:52811    03010f00 02000000 d18299aa f567e68e                                       .............g..
#   tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52811    0c00                                                                      ..
#   tcp(131)  10.0.241.54:2052     --> 10.0.241.200:52811    06000f00 02000000 00000400 14000002 0f000200 0000d182 99aaf567 e68e0100   ...........................g....
#                                                            00004d00 01020f00 02000000 41000000 ef488405 48dbf4ce 72069106 64217dc5   ..M.........A....H..H...r...d!..
#                                                            00000000 00000000 00000000 026100ff ffffff62 d700007b 4f000900 01000000   .............a.....b....O.......
#                                                            43726973 746f6261 6cd38299 a1f567e6 8e100002 020f0002 000000d1 8299aaf5   Cristobal.....g.................
#                                                            67e68e                                                                    g..
#
#   It looks like it iterates through subdequent pairs of dwords in that first message getting more waypoints
#   Popa01 is another known waypoint.  Any of those hunan readable strings are things I'm familiar with.
#
#   tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811    1000                                                                      ..
#   tcp(16)   10.0.241.54:2052     <-- 10.0.241.200:52811    03010f00 03000000 81b237a6 37008ff4                                       ..........7.7...
#   tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52811    0c00                                                                      ..
#   tcp(120)  10.0.241.54:2052     --> 10.0.241.200:52811    06000f00 03000000 00000400 14000002 0f000300 0000[81b2 37a6]3700 8ff40100   ........................7.7.....
#                                                            00004200 01020f00 03000000 36000000 23cf8605 7e9200cf 790e9406 971b8bc5   ..B.........6...#.......y.......
#                                                            00000000 00000000 00000000 02ffffff ffffff3a 8d00007e 4f000600 00000000   ...................:....O.......
#                                                            506f7061 30311000 02020f00 03000000 81b237a6 37008ff4                     Popa01............7.7...
#   tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811    1000                                                                      ..
#   tcp(16)   10.0.241.54:2052     <-- 10.0.241.200:52811    03010f00 04000000 81b237a6 36002a9d                                       ..........7.6.*.
#   tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52811    0c00
#
# The pattern seems to change at index (06000000).
# It exposes some routes, and then eventually starts returning
# the current waypoint (Popa1) being navigated to.

# I think a good understanding of this protocol will allow me to retrieve waypoints
# and is likely half the battle of RWT!!








sub tcp_thread
{
    my ($name,$commands,$repeat_commands) = @_;
    $commands ||= [];
    display(0,0,"starting tcp_thread($name)");
    my $port;
    my $sock;
    my $commands_sent = 0;
    my $rayport;

    while (1)
    {
        if (!$sock)
        {
            $rayport = findRayPortByName($name);
            if (!$rayport)
            {
                sleep(1);
            }
            else
            {
                $port = $rayport->{port};
                display(0,1,"opening tcp port to $rayport->{ip}:$port");

                $sock = IO::Socket::INET->new(
                    LocalAddr => $LOCAL_IP,
                    PeerAddr => $rayport->{ip},
                    PeerPort => $port,
                    Proto    => 'tcp',
                    Timeout  => 5 );
                if (!$sock)
                {
                    error("Could not create tcp socket($name) to $rayport->{ip}:$port: $!");
                    return;
                }

                sleep(0.5);
            }
        }
        elsif (!$commands_sent)
        {
            $commands_sent = 1;
            for my $command (@$commands)
            {
                display(0,1,"sending command: $command") if $rayport->{mon_out};
                $sock->send(pack("H*",$command));
                sleep(0.1);
            }
        }
        else
        {
            # the sniffer is returning 1 byte packets, but
            # we don't see them here.  They show as TCP
            # "keep-alives" with ACKS in wireShark

            my $raw;
            recv($sock, $raw, 4096, 0);
            if ($raw && $rayport->{mon_in})
            {
                # my $hex = unpack("H*",$raw);
                setConsoleColor($UTILS_COLOR_LIGHT_CYAN);
                display_bytes(0,0,"tcp_thread($name,$port) GOT ".length($raw)." BYTES",$raw);
                # print "LISTEN got $hex\n";
                setConsoleColor();
            }

            # Just sending 0100 one time is not sufficient
            # to get another reply.
            # I can send the commands over and over and
            # get a response.

            $commands = $repeat_commands if $commands;
            $commands_sent = 0;
            sleep(1);

        }
    }   # while (1)
}   # tcp_thread



#---------------------------------------------------------
# main
#---------------------------------------------------------

display(0,0,"shark.pm initializing");

# exit(0) if !wakeup_e80();
exit(0) if !startSniffer();


my $sniffer_thread = threads->create(\&sniffer_thread);
$sniffer_thread->detach();

if (openConsoleIn())
{
    my $serial_thread = threads->create(\&serial_thread);
    $serial_thread->detach();
}

if ($LOCAL_UDP_SOCKET)
{
    # for some reason this has to come before listen socket
    display(0,0,"initing alive_thread");
    my $alive_thread = threads->create(\&alive_thread);
    display(0,0,"alive_thread created");
    $alive_thread->detach();
    display(0,0,"alive_thread detached");
}

if (1)  # openListenSocket())
{
    my $listen_thread = threads->create(\&listen_udp_thread,$LISTEN_2049_PORT);
    $listen_thread->detach();
}

if (0)
{
    my $gps_thread = threads->create(\&tcp_thread,'GPS',[
        '0800',
        '0201100062000000',
        '0c00',
        '050110000100000062000000', ]);
    $gps_thread->detach();
}
if (0)
{
    my $nav_thread = threads->create(\&tcp_thread,'GPS',[
        '0800',
        '0201100062000000',
        '0c00',
        '050110000100000062000000', ]);
    $nav_thread->detach();
}
'0800',
'b0010f0000000000',
'0800',
'00010f0001000000',
'1400',
'00020f000100000000000000000000001a000000',
'3400',
'01020f00010000002800000000000000000000000000000000000000'.
    '000000001027000000000000000000000000000000000000',
'1000',
'02020f00010000000000000000000000',

'1000',
'02020f00010000000000000000000000',



# NAVQRY
#   tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811    0800                                                                      ..
#   tcp(8)    10.0.241.54:2052     <-- 10.0.241.200:52811    b0010f00 00000000                                                         ........
#   tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52811    0c00                                                                      ..
#   tcp(12)   10.0.241.54:2052     --> 10.0.241.200:52811    b0000f00 00000000 08000000                                                ............
#   tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811    0800                                                                      ..
#   tcp(8)    10.0.241.54:2052     <-- 10.0.241.200:52811    00010f00 01000000                                                         ........
#   tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811    1400                                                                      ..
#   tcp(20)   10.0.241.54:2052     <-- 10.0.241.200:52811                                 ....................
#   tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811    3400                                                                      4.
#   tcp(52)   10.0.241.54:2052     <-- 10.0.241.200:52811    01020f00 01000000 28000000 00000000 00000000 00000000 00000000 00000000   ........(.......................
#                                                            10270000 00000000 00000000 00000000 00000000                              .'..................
#   tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52811    1000                                                                      ..
#   tcp(16)   10.0.241.54:2052     <-- 10.0.241.200:52811    02020f00 01000000 00000000 00000000                                       ................
#   tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52811    0c00                                                                      ..
#   tcp(158)  10.0.241.54:2052     --> 10.0.241.200:52811    00000f00 01000000 00000400 14000002 0f000100 00000000 00000000 00001900   ................................
#                                                            00006800 01020f00 01000000 5c000000 0b000000 d18299aa f567e68e 81b237a6   ..h.........\............g....7.
#                                                            37008ff4 81b237a6 36002a9d 81b237a6 3700208c 81b237a6 36001996 81b237a6   7.....7.6.*...7.7. ...7.6.....7.
#                                                            370014d0 81b237a6 3600b880 81b237a6 35008a98 81b237a6 34007ff8 81b237a6   7.....7.6.....7.5.....7.4.....7.
#                                                            3500818a 81b237a6 3500478a 10000202 0f000100 00000000 00000000 0000
#   Then it appears as if it jsut keeps sending 1000 and getting back bigger 0c00 packets


#----------------
# WX
#----------------

my $frame;

sub OnInit
{
	$frame = apps::raymarine::NET::s_frame->new();
	if (!$frame)
	{
		error("unable to create frame");
		return undef;
	}
	$frame->Show( 1 );
	display(0,0,"$$resources{app_title} started");
	return 1;
}

my $app = apps::raymarine::NET::shark->new();
Pub::WX::Main::run($app);


display(0,0,"ending $appName.pm frame=$frame");
$frame->DESTROY() if $frame;
$frame = undef;
display(0,0,"finished $appName.pm");



1;