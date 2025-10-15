#---------------------------------------------
# shark.pm
#---------------------------------------------

package shark;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);

# use Socket;
# use Win32::Console;
# use IO::Handle;
# use IO::Socket::INET;
# use IO::Select;
# use r_utils;

# use r_DBNAV;
# use r_FILESYS;
# use r_WPMGR;
# use r_TRACK;
# use wp_api;

# use tcpListener;
# use tcpBase;

# use tcpScanner;

use Pub::Utils;
use Pub::WX::Resources;
use Pub::WX::Main;
use r_defs;
use r_utils;
use s_serial;
use s_sniffer;
use r_RAYSYS;
use r_TRACK;		# passive include; started by r_RAYSYS
use r_server;
use s_resources;
use s_frame;
use base 'Wx::App';

my $dbg_shark = 0;


my $WITH_SERIAL			= 1;
my $WITH_RAYSYS			= 1;
my $WITH_HTTP_SERVER	= 1;
my $WITH_SNIFFER 		= 0;
my $WITH_WX				= 1;



#-----------------------------------------
# handleSerialCommand()
#-----------------------------------------

sub handleSerialCommand
{
    my ($lpart,$rpart) = @_;
    display(0,0,"handleSerialCommand left($lpart) right($rpart)");

	# TRACK and WPMGR
	
	if ($lpart eq 't')
	{
		my $track = findServicePortByName('TRACK');
		$track->trackUICommand($rpart) if $track;
	}
	elsif ($lpart eq 'q')
    {
        queryWaypoints();
    }

	# http r_server

	elsif ($lpart eq 'db')
	{
		showLocalDatabase();
	}
	elsif ($lpart eq 'kml')
	{
		my $kml = kml_RAYSYS();
		print "\n------------------------------------------------------\n";
		print "RAYSYS kml\n";
		print "\n------------------------------------------------------\n";
		print "$kml\n";
	}

	# Not retested yet
	
	elsif ($lpart eq 'p')
	{
		my ($name,$ident) = split(/\s+/,$rpart);
		doProbe('TRACK',$rpart);	# $name,$ident);
	}
	elsif ($lpart eq 'scan')
	{
		my ($low,$high) = split(/\s+/,$rpart);
		scanRange($low,$high);
		# tcpNumberedProbe($rpart);
	}
	elsif ($lpart eq 'w')
	{
		wakeup_e80();
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

    #	if ($lpart eq 'cardid')            # CTRL-A
    #	{
    #	    return if !requestCardID();
    #	    while (getFileRequestState() > 0) { sleep(1); }
    #	    return if getFileRequestState() != $FILE_STATE_COMPLETE;
    #	    print "\nCARD_ID=".getFileRequestContent()."\n\n";
    #	}
    #	elsif ($lpart eq 'dir')
    #	{
    #	    return if !requestDirectory($rpart);
    #	    while (getFileRequestState() > 0) { sleep(1); }
    #	    return if getFileRequestState() != $FILE_STATE_COMPLETE;
    #	    print "\nDIRECTORY\n".getFileRequestContent()."\n\n";
    #	}
    #	elsif ($lpart eq 'size')
    #	{
    #	    return if !requestSize($rpart);
    #	    while (getFileRequestState() > 0) { sleep(1); }
    #	    return if getFileRequestState() != $FILE_STATE_COMPLETE;
    #	    print "\nSIZE=".getFileRequestContent()."\n\n";
    #	}
    #	elsif ($lpart eq 'file')
    #	{
    #	    return if !requestSize($rpart);
    #	    while (getFileRequestState() > 0) { sleep(1); }
    #	    return if getFileRequestState() != $FILE_STATE_COMPLETE;
    #	    print "\nFILE=".length(getFileRequestContent())."bytes\n\n";
    #	}
    #	elsif ($lpart eq 'filesys')
    #	{
    #	    my @params = split(/,/,$rpart);
    #	    sendFilesysRequest(@params);
    #	}

}   #   handleCommand()



#-----------------------------------------
# handleSniffPacket
#-----------------------------------------

sub handleSniffPacket
{
	my ($packet) = @_;

   # my $rayport_raysys = findServicePortByName('RAYSYS');
   # my $rayport_my_file = findServicePortByName('MY_FILE');
   # my $rayport_file_rns = findServicePortByName('FILE_RNS');

	my $len = length($packet->{raw_data});
	# display($dbg_shark+1,1,"got $packet->{proto} packet len($len)");
	if ($packet->{udp} &&
		$packet->{dest_port} == $RAYSYS_PORT)
	{
		 my $header = 'RAYSYS <-- ';
		 print parse_dwords($header,$packet->{raw_data},1);

		# decodeRAYSYS($packet);
		  #if ($rayport_raysys &&
		#     $rayport_raysys->{mon_to})
		# {
		#     # one time monitoring of new RAYSYS ports
		#     showPacket($rayport_raysys,$packet,0);
		# }
	}

	#	my $ray_src = findRayPort($packet->{src_ip},$packet->{src_port});
	#	my $ray_dest = findRayPort($packet->{dest_ip},$packet->{dest_port});
	#
	#	if ($ray_src && $ray_src->{mon_from})
	#	{
	#	    showPacket($ray_src,$packet,0);
	#	}
	#	elsif ($ray_dest && $ray_dest->{mon_to})
	#	{
	#	    showPacket($ray_dest,$packet,1);
	#	    if (1 && $ray_dest->{name} eq "DBNAV")
	#	    {
	#	        decodeDBNAV($packet);
	#	    }
	#	}
}





#---------------------------------------------------------
# main
#---------------------------------------------------------

display(0,0,"shark.pm initializing");


if ($WITH_SERIAL)
{
	my $serial = s_serial->new(\&handleSerialCommand);
	$serial->start();
}

if ($WITH_RAYSYS)
{
	wakeup_e80();
		# Must be called, perhaps because MSWindows,
		# before attempting to open the RAYSYS multicast socket
		
	my $raysys = r_RAYSYS->new();
	$raysys->start();
}


# if ($WITH_FILESYS)  # filesysThread())
# {
#     display(0,0,"initing filesysThread");
#     my $filesys_thread = threads->create(\&filesysThread);
#     display(0,0,"filesysThread created");
#     $filesys_thread->detach();
#     display(0,0,"filesysThread detached");
# }


startHTTPServer() if $WITH_HTTP_SERVER;

# the sniffer is started last because it has a blocking
# read in the thread which, for some reason, will cause
# threads->create() to block unless the E80 is turned on
# or there is ethernet traffice.

if ($WITH_SNIFFER)
{
	my $sniffer = s_sniffer->new(\&handleSniffPacket);
	$sniffer->start();
}





#----------------
# WX
#----------------

if ($WITH_WX)
{
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
}
else
{
	display(0,0,"starting null console loop");
	while (1)
	{
		sleep(10);
	}
}


display(0,0,"shark.pm exiting");

1;