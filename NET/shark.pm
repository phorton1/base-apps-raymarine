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
use IO::Handle;
use IO::Socket::INET;
use IO::Select;
use apps::raymarine::NET::r_utils;
use apps::raymarine::NET::r_sniffer;
use apps::raymarine::NET::r_RAYDP;
use apps::raymarine::NET::r_E80NAV;
use apps::raymarine::NET::r_FILESYS;
use apps::raymarine::NET::s_resources;
use apps::raymarine::NET::s_frame;
use base 'Wx::App';


my $dbg_shark = 0;

our $SEND_ALIVE:shared = 0;
our $MON_RAYNET:shared = 1;

BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

        $SEND_ALIVE

    );
}

my $console_in;



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
                    apps::raymarine::NET::r_FILESYS::sendRegisterRequest();
                }
                elsif (ord($char) == 2)            # CTRL-B
                {
                    apps::raymarine::NET::r_FILESYS::sendFilesysRequest(2,'\junk_data\test_data_image1.jpg');
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
                elsif ($char eq 'r')
                {
                    $MON_RAYNET = $MON_RAYNET ? 0 : 1;
                    warning(0,0,"MON_RAYNET=$MON_RAYNET");
                }
                elsif ($char eq 'g')
                {
                    requestFile('\junk_data\test_data_image1.jpg');
                }
                elsif ($char eq 'd')
                {
                    requestDirectory('\junk_data');
                }
                elsif ($char eq '1')
                {
                    requestDirectory('\\');
                }
                elsif ($char eq '2')
                {
                    requestSize('\junk_data\test_data_image1.jpg');
                }
                elsif ($char eq '3')
                {
                    requestSize('\junk_data');
                }
                elsif ($char eq '4')
                {
                    requestSize('\\');
                }
                elsif ($char eq '5')
                {
                    requestDirectory('\blah\blurb');
                }
                elsif ($char eq '6')
                {
                    requestDirectory('\Navionic\Charts');
                }

            }
        }
        #   else
        #   {
        #       if ($file_request_state == $FILE_REQUEST_STARTED ||
        #           $file_request_state == $FILE_REQUEST_PACKET0 ||
        #           $file_request_state == $FILE_REQUEST_PACKETS)
        #       {
        #           my $elapsed = time() - $file_request_time;
        #           if ($elapsed > $FILE_REQUEST_TIMEOUT)
        #           {
        #               my $byte = length($file_contents);
        #               fileRequestError("timeout in file_request($file_request_filename) at byte($byte)");
        #           }
        #       }
        #       sleep(0.1);
        #   }
    }
}



#-----------------------------------------
# sniffer thread
#-----------------------------------------


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
                if (decodeRAYDP($packet) && $MON_RAYNET)
                {
                    my $rayport_5800 = {
                        color => 0,
                        multi => 1 };
                    showPacket($rayport_5800,$packet,0);
                }
                next;
            }

            my $ray_src = findRayPort($packet->{src_ip},$packet->{src_port});
            my $ray_dest = findRayPort($packet->{dest_ip},$packet->{dest_port});
            my $dest_18432 = $packet->{dest_port} == 18432 ? {
                color => $UTILS_COLOR_BROWN,
                multi => 0, } : 0;
            my $dest_18433 = $packet->{dest_port} == 18433 ? {
                color => $UTILS_COLOR_BROWN,
                multi => 0, } : 0;

            if (1 && $dest_18433)
            {
                my $raw_data = $packet->{raw_data};
                my ($num_packets,$packet_num,$bytes) = unpack('v3',substr($raw_data,12,6));
                showPacket($dest_18433,$packet,0);
            }
            elsif (1 && $dest_18432)
            {
                my $raw_data = $packet->{raw_data};
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
                print "$packet->{src_ip}:$packet->{src_port} --> $packet->{dest_ip}:$packet->{dest_port} : Found XML: $xml\n";
            }

            # udp(10)   10.0.241.54:2049     <-- 10.0.241.200:55481    09010500 00000000 0048
            
            elsif (0 && $packet->{raw_data} =~ /(navionic)/i && $packet->{dest_port} != 2049)
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




my $script_parse = 'parse';
my $script_repeat = 'repeat';
my $script_wait = 'wait';


my $gps_script = [
    '0800',
    '0201100062000000',
    '0c00',
    '050110000100000062000000',
    "$script_repeat:" ];

my $nav_script = [
    '0800',
    'b0010f00'.'00000000',
    $script_wait,
    '0800',
    '00010f00'.'01000000',
    '1400',
    '00020f00'.'01000000'.'00000000'.'00000000'.'1a000000',
    '3400',
    '01020f00'.'01000000'.'28000000'.('00000000' x 5).'10270000'.('00000000' x 4),
    '1000',
    '02020f00'.'01000000'.'00000000'.'00000000',
];

my $wp_index_header = '0c0000000f0001000000';


sub tcp_thread
{
    my ($name,$local_port,$script) = @_;
    display(0,0,"starting tcp_thread($name)");
    sleep(2);

    print "script=".join("\r\n   ",@$script)."\r\n";

    my $sel;
    my $port;
    my $sock;
    my $rayport;

    my $done = 0;
    my $hex_buf = '';
    my $script_index = 0;
    my $script_steps = @$script;

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
                print "opening tcp port to $rayport->{ip}:$port\r\n";

                $sock = IO::Socket::INET->new(
                    LocalAddr => $LOCAL_IP,
                    LocalPort => $local_port,
                    PeerAddr  => $rayport->{ip},
                    PeerPort  => $port,
                    Proto     => 'tcp',
                );
                if (!$sock)
                {
                    error("Could not create tcp socket($name) to $rayport->{ip}:$port: $!");
                    return;
                }
                $sel = IO::Select->new($sock);
            }
            next;
        }

        #---------------------------

        if ($sel->can_read())
        {
            my $buf;
            recv($sock, $buf, 4096, 0);
            if ($buf)
            {
                my $hex = unpack("H*",$buf);
                $hex_buf .= $hex;
                $done ?
                    display_bytes(0,1,"buf",$buf) :
                    print "got "._lim($hex,200)."\r\n";
                # sleep(0.001);
            }
        }

        my $pos = index($hex_buf,$wp_index_header);
        if (!$done && $pos >= 0)
        {
            $done = 1;
            $script_index = $script_steps;
            $hex_buf = substr($hex_buf,$pos);
            print "-->HEX_BUF=$hex_buf\r\n";
            
            my $len = length($hex_buf);
            my $num = 2;                # the first request is sequence number 2
            my $offset = 4 + 13 * 8;    # the 13th dword inside the packet following 0c00
            while ($offset < $len + 16) # 16 hex chars for 2 dword uuid
            {
                my $uuid = substr($hex_buf,$offset,16);
                last if $uuid eq ('0' x 16);
                requestOneWp($sock,$num++,$uuid);
                $offset += 16;
            }
        }


        if ($script_index < $script_steps)
        {
            if ($script->[$script_index] eq $script_wait)
            {
                $script_index++;
                sleep(0.5);
            }
            elsif ($sel->can_write())
            {
                my $command = $script->[$script_index++];
                print "-->$command\r\n";
                my $packed = pack("H*",$command);
                my $sent = $sock->send($packed);
                if (0 && !$sent)
                {
                    error("Could not send: $! $^E");
                    sleep(1);
                    $script_index--;
                }
            }
        }
    }
}


sub requestOneWp
{
    my ($sock,$num,$uuid) = @_;
    $sock->send(pack("H*",'1000'));
    my $hex = '03010f00'.unpack("H*",pack('V',$num)).$uuid;
    print "request($num) uuid($uuid) --> $hex\r\n";
    $sock->send(pack("H*",$hex));
}



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
    my $listen_thread = threads->create(\&fileRequestThread);
    $listen_thread->detach();
}

if (0)
{
    my $gps_thread = threads->create(\&tcp_thread,'GPS',9876,$gps_script);
    $gps_thread->detach();
}
if (0)
{
    my $nav_thread = threads->create(\&tcp_thread,'NAVQRY',9877,$nav_script);
    $nav_thread->detach();
}




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