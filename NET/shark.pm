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
use r_serial;
use r_sniffer;
use r_RAYDP;
use r_NAVSTAT;
use r_FILESYS;
use r_NAVQRY;
use r_NEWQRY;
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


#-----------------------------------------
# handleCommand()
#-----------------------------------------

sub handleCommand
{
    my ($lpart,$rpart) = @_;
    display(0,0,"handleCommand left($lpart) right($rpart)");

	if ($lpart eq 'q')
    {
        doNavQuery();
    }
    elsif ($lpart eq 'auto')
    {
        setNavQueryAutoRefresh($rpart);
    }

    elsif ($lpart eq 'create' || $lpart eq 'delete')
    {
        my ($what,$num) = split(/\s+/,$rpart);
    	$what = lc($what);
        createWaypoint($num) if $lpart eq 'create' && $what eq 'wp';
        createRoute($num) 	 if $lpart eq 'create' && $what eq 'route';
        createGroup($num) 	 if $lpart eq 'create' && $what eq 'group';
        deleteWaypoint($num) if $lpart eq 'delete' && $what eq 'wp';
        deleteRoute($num) 	 if $lpart eq 'delete' && $what eq 'route';
        deleteGroup($num) 	 if $lpart eq 'delete' && $what eq 'group';
	}
	elsif ($lpart eq "route")
	{
        my ($route_num,$op,$wp_num) = split(/\s+/,$rpart);
		if ($op eq '+' || $op eq '-')
		{
			routeWaypoint($route_num,$wp_num,$op eq '+');
		}
		else
		{
			error("bad route command syntax");
		}
	}
	elsif ($lpart eq 'group')
	{
        my ($wp_num,$group_num) = split(/\s+/,$rpart);
		setWaypointFolder($wp_num,$group_num);
	}


    # showCharacterizedCommands(0);
    # showCharacterizedCommands(1);
    # clearCharacterizedCommands();
    # createWaypoint();
    # deleteWaypoint();


     # FILESYS TESTING

    if ($lpart eq 'cardid')            # CTRL-A
    {
        return if !requestCardID();
        while (getFileRequestState() > 0) { sleep(1); }
        return if getFileRequestState() != $FILE_STATE_COMPLETE;
        print "\nCARD_ID=".getFileRequestContent()."\n\n";
    }
    elsif ($lpart eq 'dir')
    {
        return if !requestDirectory($rpart);
        while (getFileRequestState() > 0) { sleep(1); }
        return if getFileRequestState() != $FILE_STATE_COMPLETE;
        print "\nDIRECTORY\n".getFileRequestContent()."\n\n";
    }
    elsif ($lpart eq 'size')
    {
        return if !requestSize($rpart);
        while (getFileRequestState() > 0) { sleep(1); }
        return if getFileRequestState() != $FILE_STATE_COMPLETE;
        print "\nSIZE=".getFileRequestContent()."\n\n";
    }
    elsif ($lpart eq 'file')
    {
        return if !requestSize($rpart);
        while (getFileRequestState() > 0) { sleep(1); }
        return if getFileRequestState() != $FILE_STATE_COMPLETE;
        print "\nFILE=".length(getFileRequestContent())."bytes\n\n";
    }
    elsif ($lpart eq 'filesys')
    {
        my @params = split(/,/,$rpart);
        sendFilesysRequest(@params);
    }
                    
}   #   handleCommand()



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


startSerialThread() if 1;


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