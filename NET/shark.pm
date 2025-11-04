#---------------------------------------------
# shark.pm
#---------------------------------------------
# I'm moving in a lot of directions at once.
#   - angling to directly read encryped navionics card
#   - thinking of ripping the card with sniffer as a fallback
#   - porting FILESYS to new parser architecture with bifurcation and all that entails for the quirks
#   - gotta do DBNAV too, at least minimally
#   - incorporate new parser arch into b_sock and existing services
#
#   - simplify new parser (monitoring) arch
#   - implement user interfaces for controlling monitoring
#   - possibly UI's for WPMGR and TRACK
#   - possible UI for sniffer
#   - still wanting to probe and learn Database
#	- still want generalized record and playback capabilities for spoofing


package shark;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use Pub::WX::Resources;
use Pub::WX::Main;

use a_defs;
use a_utils;
use b_sock;
use b_probe;

use c_RAYSYS;
use d_DB;
use d_TRACK;
use d_WPMGR;
use d_FILESYS;
use d_DBNAV;

use e_WPMGR;
use e_TRACK;
use e_FILESYS;

use e_wp_api;
use h_server;
use s_serial;
use s_sniffer;
use w_resources;
use w_frame;
use tcpScanner;
use udpScanner;
use base 'Wx::App';

my $dbg_shark = 0;


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
		b_sock::wakeup_e80();
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

	# DB

	elsif ($lpart eq 'i')
	{
		my $db = $raysys->findImplementedService('DB');
		display(0,0,"db="._def($db));
		$db->uiInit() if $db;
	}
	elsif ($lpart eq 'fids')
	{
		my $db = $raysys->findImplementedService('DB');
		my $db_parser = $db ? $db->{parser} : 0;
		display(0,0,"db="._def($db)." db_parser="._def($db_parser));
		$db_parser->showFids() if $db_parser;
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

	elsif ($lpart eq 's')
	{
		display(0,0,"Clear Shark Log File");
		clearLog("shark.log");
	}
	elsif ($lpart eq 'r')
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

	# PORT SCANS and PROBES

	elsif ($lpart eq 'scan')
	{
		my ($low,$high) = split(/\s+/,$rpart);
		return error("No tcpScanner!") if !$tcp_scanner;
		$rpart ?
			$tcp_scanner->scanRange($low,$high) :
			$tcp_scanner->showAliveScans();
	}
	elsif ($lpart eq 'udp')
	{
		my $aggresive = $rpart =~ s/a// ? 1 : 0;
		$rpart =~ s/^\s+|\s$//g;
		my ($low,$high) = split(/\s+/,$rpart);
		return error("No udpScanner!") if !$udp_scanner;
		$rpart ?
			$udp_scanner->scanRange($low,$high,$aggresive) :
			$udp_scanner->showAliveScans();
	}
	elsif ($lpart eq 'p')
	{
		my ($name,@params) = split(/\s+/,$rpart);
		my $params = join(' ',@params) || '';
		$name = 'TRACK' 	if $name eq 't';
		$name = 'WPMGR' 	if $name eq 'w';
		$name = 'FILESYS'	if $name eq 'f';
		$name = 'DB'		if $name eq 'd';

		my $service_port =
			$raysys->findImplementedService($name,1) ||
			$raysys->findServicePortByName($name,1);
		return error("service $name("._def($service_port).") doesn't exist or is not connected")
			if !$service_port || !$service_port->{connected};
		$service_port->doProbe($params);
	}

}   #   handleCommand()




#---------------------------------------------------------
# main
#---------------------------------------------------------

display(0,0,"shark.pm initializing");


if ($WITH_SERIAL)
{
	my $serial = s_serial->new(\&handleSerialCommand);
	$serial->start();
}

c_RAYSYS->new();
if ($WITH_RAYSYS)
{
	$raysys->start();
}

if ($WITH_TCP_SCANNER)
{
	tcpScanner->new();
}
if ($WITH_TCP_SCANNER)
{
	udpScanner->new();
}


startHTTPServer() if $WITH_HTTP_SERVER;

# the sniffer is started last because it has a blocking
# read in the thread which, for some reason, will cause
# threads->create() to block unless the E80 is turned on
# or there is ethernet traffice.

if ($WITH_SNIFFER)
{
	my $sniffer = s_sniffer->new();
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