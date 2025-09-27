#---------------------------------------------
# shark.pm
#---------------------------------------------

package shark;
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
use r_utils;
use r_sniffer;
use r_RAYDP;
use r_NAVSTAT;
use r_FILESYS;
use r_NAVQRY;
use r_characterize;
use s_resources;
use s_frame;
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

                # The above commands work with no RNS on a fresh E80
                # without any keep alives, etc.  However, we are not
                # getting any other "regular" packets, except for 5801
                # "ALIVE" packets.
                
                if (ord($char) == 4)            # CTRL-D
                {
                    $CONSOLE->Cls();    # manually clear the screen
                }
                #   elsif ($char eq 'w')
                #   {
                #       wakeup_e80();
                #   }
                #   #   elsif ($char eq 'a')
                #   #   {
                #   #       $SEND_ALIVE = $SEND_ALIVE ? 0 : 1;
                #   #       warning(0,0,"SEND_ALIVE=$SEND_ALIVE");
                #   #   }

                elsif (1)
                {
                    # NAVQUERY TESTING

                    if ($char eq 'a')
                    {
                        startNavQuery();
                    }
                    elsif ($char eq 'b')
                    {
                        refreshNavQuery();
                    }
                    elsif ($char eq 'c')
                    {
                        toggleNavQueryAutoRefresh();
                    }
                    elsif ($char eq 'x')
                    {
                        showCharacterizedCommands(0);
                    }
                    elsif ($char eq 'y')
                    {
                        showCharacterizedCommands(1);
                    }
                    elsif ($char eq 'z')
                    {
                        clearCharacterizedCommands();
                    }

                }
                elsif (0)    # FILESYS TESTING
                {
                    if (ord($char) == 1)            # CTRL-A
                    {
                        r_FILESYS::sendFilesysRequest(0);
                    }
                    elsif (ord($char) == 2)            # CTRL-B
                    {
                        r_FILESYS::sendFilesysRequest(2,'\junk_data\test_data_image1.jpg');
                    }

                    elsif ($char eq 'g')
                    {
                        requestFile('\ARCHIVE.FSH','ARCHIVE.FSH');
                    }

                    elsif ($char eq 'h')
                    {
                        requestFile('\junk_data\test_data_image1.jpg',"test.jpg");
                    }
                    elsif ($char eq 'i')
                    {
                        requestDirectory('\junk_data');
                    }
                    elsif ($char eq 'j')
                    {
                        requestDirectory('\\');
                    }
                    elsif ($char eq 'k')
                    {
                        requestSize('\junk_data\test_data_image1.jpg');
                    }
                    elsif ($char eq 'l')
                    {
                        requestSize('\junk_data');
                    }
                    elsif ($char eq 'm')
                    {
                        requestSize('\\');
                    }
                    elsif ($char eq 'n')
                    {
                        requestDirectory('\blah\blurb');
                    }
                    elsif ($char eq 'o')
                    {
                        requestSize('\ARCHIVE.FSH');
                    }

                    # probing FILESYS

                    elsif ($char eq 'q')
                    {
                        r_FILESYS::sendFilesysRequest(7,'');
                    }

                    elsif ((0 && $char ge '0' && $char le '9') || ($char ge 'a' && $char le 'f'))
                    {
                        my @paths = (
                            '\\',                                   # root directory
                            '\junk_data',                           # exiting directory
                            '\junk_data\test_data_image1.jpg',      # existing file
                            '\blah',                                # non existing outer level path or filename
                            '\junk_data\blah',                      # non existing inner level path or filename
                            '\SYSTEM VOLUME INFORMATION',           # hidden operating system file
                            '\ARCHIVE.FSH',                         # a big file
                        );

                        display(0,0,"Probing FILESYS($char)");
                        my $cmd = ord($char);
                        $cmd = $cmd >= ord('a') ? 10+$cmd-ord('a') : $cmd-ord('0');

                        my $extra;
                        my $extra2;
                        $extra = '0000' if $cmd == 3 || $cmd > 9;
                            # extra bytes before cmd(3) or a-f didn't seem to help
                            # extra bytes after the the required length don't seem to do anything
                            
                        for my $path (@paths)
                        {
                            $path = '' if $cmd==7 && $cmd==8;
                            display(0,1,"probe($char) path=$path");
                            r_FILESYS::sendFilesysRequest($cmd,$path,1,$extra,$extra2);
                            sleep(1);
                        }

                    }
                }   # FILESYS TESTING
            }   #   Got $char
        }   # $in->GetEvents()
        else
        {
            sleep(0.1);
        }
        
    }   # while (1)
}   #   serial_thread()



#-----------------------------------------
# sniffer thread
#-----------------------------------------

sub sniffer_thread
{
    display($dbg_shark,0,"sniffer thread started");
    # sleep(2);
        # if the sniffer thread is not started last then this is needed.
        # give all threads time to start before any blocking reads
        # without this line, the call to nextSniffPacket will block
        # if there is no traffic on the ethernet port, i.e. the E80 is off,
        # and that causes threads->create() to subsequently block.

    my $rayport_raydp = findRayPortByName('RAYDP');
    my $rayport_file = findRayPortByName('FILE');
    my $rayport_file_rns = findRayPortByName('FILE');

    while (1)
    {
        my $packet = nextSniffPacket();
        if ($packet)
        {
            my $len = length($packet->{raw_data});
            # display($dbg_shark+1,1,"got $packet->{proto} packet len($len)");
            if ($packet->{udp} &&
                # $packet->{dest_ip} eq $RAYDP_IP &&
                $packet->{dest_port} == $RAYDP_PORT)
            {
                if (decodeRAYDP($packet) &&
                    $rayport_raydp &&
                    $rayport_raydp->{mon_out})
                {
                    # one time monitoring of new RAYDP ports
                    showPacket($rayport_raydp,$packet,0);
                }
                next;
            }


            my $ray_src = findRayPort($packet->{src_ip},$packet->{src_port});
            my $ray_dest = findRayPort($packet->{dest_ip},$packet->{dest_port});

            # my $dest_rns_filesys = $packet->{dest_port} == $RNS_FILESYS_LISTEN_PORT ? {
            #     color => $UTILS_COLOR_BROWN,
            #     multi => 0, } : 0;
            # my $dest_filesys = $packet->{dest_port} == $FILESYS_LISTEN_PORT ? {
            #     color => $UTILS_COLOR_BROWN,
            #     multi => 0, } : 0;
            # if (0 && $dest_18433)
            # {
            #     my $raw_data = $packet->{raw_data};
            #     my ($num_packets,$packet_num,$bytes) = unpack('v3',substr($raw_data,12,6));
            #     showPacket($dest_18433,$packet,0);
            # }
            # elsif (0 && $dest_18432)
            # {
            #     my $raw_data = $packet->{raw_data};
            #     showPacket($dest_18432,$packet,0);
            # }
            # els

            if ($ray_src && $ray_src->{mon_out})
            {
                showPacket($ray_src,$packet,0);
            }
            elsif ($ray_dest && $ray_dest->{mon_in})
            {
                showPacket($ray_dest,$packet,1);
                if (0 && $ray_dest->{name} eq "NAVSTAT")
                {
                    decodeNAVSTAT($packet);
                }
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
            sleep(0.1);
            # sleep(0.001);
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
# main
#---------------------------------------------------------

display(0,0,"shark.pm initializing");

initRAYDP();


if (openConsoleIn())
{
    display(0,0,"initing serial_thread");
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
    display(0,0,"initing filesysThread");
    my $filesys_thread = threads->create(\&filesysThread);
    display(0,0,"filesysThread created");
    $filesys_thread->detach();
    display(0,0,"filesysThread detached");
}

#   if (0)
#   {
#       my $gps_thread = threads->create(\&tcp_thread,'GPS',9876,$gps_script);
#       $gps_thread->detach();
#   }

if (1)
{
    display(0,0,"initing nav_thread");
    my $nav_thread = threads->create(\&navQueryThread);
    display(0,0,"nav_thread created");
    $nav_thread->detach();
    display(0,0,"nav_thread detached");
}


# the sniffer is started last because it has a blocking
# read in the thread which, for some reason, will cause
# threads->create() to block unless the E80 is turned on
# or there is ethernet traffice.

exit(0) if !startSniffer();

if (1)
{
    display(0,0,"initing sniffer_thread");
    my $sniffer_thread = threads->create(\&sniffer_thread);
    $sniffer_thread->detach();
}


#----------------
# WX
#----------------

display(0,0,"starting app");

my $frame;

sub OnInit
{
	$frame = s_frame->new();
	if (!$frame)
	{
		error("unable to create frame");
		return undef;
	}
	$frame->Show( 1 );
	display(0,0,"$$resources{app_title} started");
	return 1;
}

my $app = shark->new();
Pub::WX::Main::run($app);


display(0,0,"ending $appName.pm frame=$frame");
$frame->DESTROY() if $frame;
$frame = undef;
display(0,0,"finished $appName.pm");



1;