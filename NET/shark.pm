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
# use a_utils;

# use r_DBNAV;
# use d_FILESYS;
# use d_WPMGR;
# use d_TRACK;
# use e_wp_api;

#
# use tcpBase;

# use tcpScanner;

use Pub::Utils;
use Pub::WX::Resources;
use Pub::WX::Main;
use a_defs;
use a_utils;
use b_probe;
use c_RAYSYS;
use d_TRACK;
use d_WPMGR;
use d_FILESYS;
use d_DBNAV;
use e_wp_api;
use h_server;
use s_serial;
use s_sniffer;
use w_resources;
use w_frame;
use tcpScanner;
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

	# WAKEUP

	if ($lpart eq 'wakeup')
	{
		wakeup_e80();
	}



	# HTTP server

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

	# DBNAV

	elsif ($lpart eq 'v')
	{
		my $dbnav = $raysys->findImplementedService('DBNAV');
		$dbnav->showValues() if $dbnav;
	}


    # FILESYS

	elsif ($lpart eq 'f')
	{
		my ($cmd,$path) = split(/\s+/,$rpart);
		my $filesys = $raysys->findImplementedService('FILESYS');
		$filesys->fileCommand($cmd,$path) if $filesys;
	}
	
	# TRACK

	if ($lpart eq 't')
	{
		my $track = $raysys->findImplementedService('TRACK');
		return if !$track;
		$track->trackUICommand($rpart) if $track;
	}

	# WPMGR

	elsif ($lpart =~ /^(q|create|delete|wp|route|group)$/)
	{
		my $wpmgr = $raysys->findImplementedService('WPMGR');
		return if !$wpmgr;

		if ($lpart eq 'q')
		{
			$wpmgr->queryWaypoints();
		}
		elsif ($lpart eq 'create' || $lpart eq 'delete')
		{
			my ($what,$num,@rest) = split(/\s+/,$rpart);
			$what = lc($what);
			$wpmgr->createWaypoint($num) 	if $lpart eq 'create' && $what eq 'wp';
			$wpmgr->createRoute($num,@rest) if $lpart eq 'create' && $what eq 'route';
			$wpmgr->createGroup($num) 	 	if $lpart eq 'create' && $what eq 'group';
			$wpmgr->deleteWaypoint($num) 	if $lpart eq 'delete' && $what eq 'wp';
			$wpmgr->deleteRoute($num) 	 	if $lpart eq 'delete' && $what eq 'route';
			$wpmgr->deleteGroup($num) 	 	if $lpart eq 'delete' && $what eq 'group';
		}
		elsif ($lpart eq "route")
		{
			my ($route_num,$op,$wp_num) = split(/\s+/,$rpart);
			if ($op && ($op eq '+' || $op eq '-'))
			{
				$wpmgr->routeWaypoint($route_num,$wp_num,$op eq '+');
			}
			else
			{
				$wpmgr->showItem('route',$rpart);
				# error("bad route command syntax");
			}
		}
		elsif ($lpart eq 'wp')
		{
			my ($wp_num,$group_num) = split(/\s+/,$rpart);
			if ($wp_num =~ /^\d+$/)
			{
				$wpmgr->setWaypointGroup($wp_num,$group_num);
			}
			else
			{
				$wpmgr->showItem('waypoint',$rpart);	
			}
		}
		elsif ($lpart eq 'group')
		{
			$wpmgr->showItem('group',$rpart);
		}


	}	# WPMGR


	# LOGFILES

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
	elsif ($lpart eq 'log')
	{
		my $msg =
			"\n=======================================================================\n".
			"# $rpart\n".
			"========================================================================\n\n";
		writeLog($msg,'rns.log');
		writeLog($msg,'shark.log');
	}

	# PORT SCANS and (track) PROBING

	elsif ($lpart eq 'scan')
	{
		my ($low,$high) = split(/\s+/,$rpart);
		scanRange($low,$high);
	}
	elsif ($lpart eq 'p')
	{
		my ($name,@params) = split(/\s+/,$rpart);
		my $params = join(' ',@params) || '';
		$name = 'TRACK' 	if $name eq 't';
		$name = 'WPMGR' 	if $name eq 'w';
		$name = 'FILESYS'	if $name eq 'f';
		my $service_port = $raysys->findImplementedService($name);
		return if !$service_port;
		$service_port->doProbe($params);
	}

}   #   handleCommand()



#-----------------------------------------
# handleSniffPacket
#-----------------------------------------

sub handleSniffPacket
{
	my ($packet) = @_;

   # my $rayport_raysys = findImplementedService('RAYSYS');
   # my $rayport_my_file = findImplementedService('MY_FILE');
   # my $rayport_file_rns = findImplementedService('FILE_RNS');

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
	my $raysys = c_RAYSYS->new();
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
		$frame = w_frame->new();
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