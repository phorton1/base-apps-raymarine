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
use rayports;
use r_serial;
use r_sniffer;
use r_RAYSYS;
use r_DBNAV;
use r_FILESYS;
use r_WPMGR;
use r_TRACK;
use wp_api;
use wp_server;
use tcpListener;
use s_resources;
use s_frame;
use tcpScanner;
use base 'Wx::App';


my $dbg_shark = 0;

my $WITH_FILESYS 	= 1;
my $WITH_WPMGR		= 1;
my $WITH_WP_SERVER	= 1;
my $WITH_IDENT		= 0;
my $WITH_TRACK		= 1;


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

	if ($lpart eq 'scan')
	{
		my ($low,$high) = split(/\s+/,$rpart);
		scanRange($low,$high);
		# tcpNumberedProbe($rpart);
	}
	elsif ($lpart eq 'alive')
	{
		showAliveScans();
	}

	elsif ($lpart eq 'w')
	{
		wakeup_e80
	}

	#-----------------------------------------------------
	# new 2nd E80 above
	#-----------------------------------------------------
	# TRCACK

	elsif ($lpart eq 'tracks')
	{
		getTracks();
	}

	# WPMGR

	elsif ($lpart eq 'db')
	{
		showLocalDatabase();
	}
	elsif ($lpart eq 'q')
    {
        queryWaypoints();
    }

	elsif ($lpart eq 'kml')
	{
		my $kml = kml_WPMGR();
		print "\n------------------------------------------------------\n";
		print "WPMGR kml\n";
		print "\n------------------------------------------------------\n";
		print "$kml\n";
	}
	elsif ($lpart eq 'c')
	{
		display(0,0,"Clear Shark Log File");
		clearLog("shark.log");
	}
	elsif ($lpart eq 'd')
	{
		display(0,0,"Clear RNS Log File");
		clearLog("rns.log");
	}
    elsif ($lpart eq 'create' || $lpart eq 'delete')
    {
        my ($what,$num,@rest) = split(/\s+/,$rpart);
    	$what = lc($what);
        createWaypoint($num) 	if $lpart eq 'create' && $what eq 'wp';
        createRoute($num,@rest) if $lpart eq 'create' && $what eq 'route';
        createGroup($num) 	 	if $lpart eq 'create' && $what eq 'group';
        deleteWaypoint($num) 	if $lpart eq 'delete' && $what eq 'wp';
        deleteRoute($num) 	 	if $lpart eq 'delete' && $what eq 'route';
        deleteGroup($num) 	 	if $lpart eq 'delete' && $what eq 'group';
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
	elsif ($lpart eq 'wp')
	{
        my ($wp_num,$group_num) = split(/\s+/,$rpart);
		setWaypointGroup($wp_num,$group_num);
	}
	elsif ($lpart eq 'log')
	{
		my $msg =
			"\n=======================================================================\n".
			"# $rpart\n".
			"========================================================================\n\n";
		navQueryLog($msg,'rns.log');
		navQueryLog($msg,'shark.log');
	}

    # showCharacterizedCommands(0);
    # showCharacterizedCommands(1);
    # clearCharacterizedCommands();


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

    my $rayport_raysys = findRayPortByName('RAYSYS');
    my $rayport_my_file = findRayPortByName('MY_FILE');
    my $rayport_file_rns = findRayPortByName('FILE_RNS');

    while (1)
    {
        my $packet = nextSniffPacket();
        if ($packet)
        {
            my $len = length($packet->{raw_data});
            # display($dbg_shark+1,1,"got $packet->{proto} packet len($len)");
            if ($packet->{udp} &&
                $packet->{dest_port} == $RAYDP_PORT)
            {
                decodeRAYSYS($packet);
				if ($rayport_raysys &&
                    $rayport_raysys->{mon_to})
                {
                    # one time monitoring of new RAYSYS ports
                    showPacket($rayport_raysys,$packet,0);
                }
                next;
            }


            my $ray_src = findRayPort($packet->{src_ip},$packet->{src_port});
            my $ray_dest = findRayPort($packet->{dest_ip},$packet->{dest_port});

            if ($ray_src && $ray_src->{mon_from})
            {
                showPacket($ray_src,$packet,0);
            }
            elsif ($ray_dest && $ray_dest->{mon_to})
            {
                showPacket($ray_dest,$packet,1);
                if (1 && $ray_dest->{name} eq "DBNAV")
                {
                    decodeDBNAV($packet);
                }
            }
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

initRAYSYS();

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


if ($WITH_FILESYS)  # filesysThread())
{
    display(0,0,"initing filesysThread");
    my $filesys_thread = threads->create(\&filesysThread);
    display(0,0,"filesysThread created");
    $filesys_thread->detach();
    display(0,0,"filesysThread detached");
}


r_WPMGR->startWPMGR() if $WITH_WPMGR;
startWPServer() if $WITH_WP_SERVER;


r_TRACK->startTRACK() if $WITH_TRACK;

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



#---------------------------
# FAKE IDENT inline
#---------------------------

my $SEND_IDENTS = 0;


use IO::Socket::Multicast;

my $FAKE_RNS_2  = '01000000 03000000'.$SHARK_DEVICE_ID.'76020000 018e7680 00000000 00000000 00000000 00000000 00000000 00000000 00000000 00000000 0000';
my $FAKE_E80_3  = '01000000 00000000'.$SHARK_DEVICE_ID.'39020000 53f0000a 0033cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 cc33cc33 02000000';


my $ident_sock;

if ($WITH_IDENT)
{
	$ident_sock = IO::Socket::Multicast->new(
		LocalPort => $RAYDP_PORT,
		ReuseAddr => 1,
		Proto     => 'udp',
	) or die "Couldn't create multicast socket: $!";

	$ident_sock->mcast_add($RAYDP_IP) or die "Couldn't join multicast group: $!";

	my $thr = threads->create(\&identThread,$ident_sock);
	$thr->detach();
}


sub identThread
{
	my ($sock) = @_;
	while (1)
	{
		# print "[IDENT] Send IDENT packet\n";

		my $packet = $FAKE_E80_3;
		$packet =~ s/\s+//g;
		$packet = pack('H*',$packet);

		$sock->send($packet, 0, pack_sockaddr_in($RAYDP_PORT, inet_aton($RAYDP_IP)));
		sleep 1;
    }
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