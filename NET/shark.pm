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


#-----------------------------------------
# serial_thread
#-----------------------------------------

my $console_in = 0;

sub openConsoleIn
{
    $console_in = Win32::Console->new(STD_INPUT_HANDLE);
    $console_in->Mode(ENABLE_MOUSE_INPUT | ENABLE_WINDOW_INPUT ) if $console_in;
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
                    sendListenPacket();
                }
                if (ord($char) == 2)            # CTRL-B
                {
                    sendRequestPacket();
                }
                if (ord($char) == 4)            # CTRL-D
                {
                    $CONSOLE->Cls();    # manually clear the screen
                }
                if ($char eq 'w')
                {
                    wakeup_e80();
                }
            }
        }
    }
}



#-----------------------------------------
# sniffer thread
#-----------------------------------------


my $E80NAV_PORT  = 2562;


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



            if ($dest_18432)
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
                if ($packet->{dest_port} == $E80NAV_PORT)
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


my $LISTEN_PORT = 18433;
my $PACKED_PORT = pack('v',$LISTEN_PORT);
    # 1048 for me 0048 for RNS
display(0,0,"packed_port=$PACKED_PORT");

my $REGISTER_PACKET = pack("H*", "0901050000000000").$PACKED_PORT;
    # 18433 encodes to "09010500000000000148"
    # but it works with any unused port number
# my $CHART_REQUEST_PACKET = pack("H*","0101050002000000").$PACKED_PORT.pack("H*","00000e005c6368617274 6361742e786d6c00");  #   .........H....\chartcat.xml.
my $CHART_REQUEST_PACKET = pack("H*","0201050010110000").$PACKED_PORT.pack("H*","009a4c00000400001c005c4e6176696f6e69635c4368617274735c3347313338584c2e4e5632");
    # .........H.šL.......\Navionic\Charts\3G138XL.NV2


my $E80_IP = '10.0.241.54';
my $REGISTER_PORT = 2049;
my $REGISTER_ADDR = pack_sockaddr_in($LISTEN_PORT, inet_aton($E80_IP));

my $sock_listen;
my $sock_register = $LOCAL_UDP_SOCKET;


sub openListenSocket()
{
    $sock_listen = IO::Socket::INET->new(
            LocalPort => $LISTEN_PORT,
            Proto     => 'udp',
            ReuseAddr => 1 );
    error("Could not open sock_listen")
        if !$sock_listen;
    return $sock_listen;
}

sub sendListenPacket
{
    display(0,0,"sendListenPacket()");
    if (!$sock_register)
    {
        display(0,1,"opening sock_register");
        $sock_register = IO::Socket::INET->new(
            PeerAddr => $E80_IP,
            PeerPort => $REGISTER_PORT,
            Proto    => 'udp' );
        if (!$sock_register)
        {
            error("Could not open sock_register");
            return;
        }
    }
    display(0,1,"sending register_packet");
    $sock_register->send($REGISTER_PACKET, 0, $REGISTER_ADDR);
    display(0,1,"register_packet sent");
}

sub sendRequestPacket
{
    display(0,0,"sendListenPacket()");
    if (!$sock_register)
    {
        error("sock_register not open in sendRequest packet");
        return;
    }
    display(0,1,"sending chart_request_packet");
    $sock_register->send($CHART_REQUEST_PACKET, 0, $REGISTER_ADDR);
    display(0,1,"chart_request_packet sent");
}




sub listen_thread
{
    display(0,0,"listen_thread() started");
    while (1)
    {
        my $raw;
        recv($sock_listen, $raw, 4096, 0);
        if ($raw)
        {
            # my $hex = unpack("H*",$raw);
            setConsoleColor($UTILS_COLOR_LIGHT_MAGENTA);
            display_bytes(0,0,"LISTEN GOT ".length($raw)." BYTES",$raw);
            # print "LISTEN got $hex\n";
            setConsoleColor();
        }
    }
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

if (openListenSocket())
{
    my $listen_thread = threads->create(\&listen_thread);
    $listen_thread->detach();
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