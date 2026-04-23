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
use Pub::WX::AppConfig;
use Pub::WX::Main;

use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_utils;
use apps::raymarine::NET::b_sock;
use apps::raymarine::NET::b_probe;

use apps::raymarine::NET::c_RAYDP;
use apps::raymarine::NET::d_DB;
use apps::raymarine::NET::d_TRACK;
use apps::raymarine::NET::d_WPMGR;
use apps::raymarine::NET::d_FILESYS;
use apps::raymarine::NET::d_DBNAV;

use apps::raymarine::NET::e_WPMGR;
use apps::raymarine::NET::e_TRACK;
use apps::raymarine::NET::e_FILESYS;

use apps::raymarine::NET::fshWriter;

use apps::raymarine::NET::e_wp_api;
use s_server;

use s_serial;
use s_sniffer;
use w_resources;
use w_frame;
use tcpScanner;
use udpScanner;
use base 'Wx::App';

$ini_file = "$temp_dir/$appName.ini";


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
		apps::raymarine::NET::b_sock::wakeup_e80();
	}


	# HTTP server

	elsif ($lpart eq 'db')
	{
		showLocalDatabase();
	}
	elsif ($lpart eq 'kml')
	{
		my $kml = kml_RAYSYS();
		c_print("\n------------------------------------------------------\n");
		c_print("RAYSYS kml\n");
		c_print("\n------------------------------------------------------\n");
		c_print("$kml\n");
	}

	# DB

	elsif ($lpart eq 'i')
	{
		my $db = $raydp->findImplementedService('DB');
		display(0,0,"db="._def($db));
		$db->uiInit() if $db;
	}
	elsif ($lpart eq 'fids')
	{
		my $db = $raydp->findImplementedService('DB');
		my $db_parser = $db ? $db->{parser} : 0;
		display(0,0,"db="._def($db)." db_parser="._def($db_parser));
		$db_parser->showFids() if $db_parser;
	}


	# DBNAV

	elsif ($lpart eq 'v')
	{
		my $dbnav = $raydp->findImplementedService('DBNAV');
		$dbnav->showValues() if $dbnav;
	}


    # FILESYS

	elsif ($lpart eq 'f')
	{
		my ($cmd,$path) = split(/\s+/,$rpart);
		my $filesys = $raydp->findImplementedService('FILESYS');
		$filesys->fileCommand($cmd,$path) if $filesys;
	}
	
	# TRACK

	if ($lpart eq 't')
	{
		my $track = $raydp->findImplementedService('TRACK');
		return if !$track;
		$track->trackUICommand($rpart) if $track;
	}

	# WPMGR

	elsif ($lpart =~ /^(q|create|delete|wp|route|group|new|mod)$/)
	{
		my $wpmgr = $raydp->findImplementedService('WPMGR');
		return if !$wpmgr;

		if ($lpart eq 'q')
		{
			$wpmgr->queryWaypoints();
		}
		elsif ($lpart eq 'create' || $lpart eq 'delete')
		{
			my ($what,@rest) = split(/\s+/,$rpart);
			$what = lc($what // '');
			my $num  = $rest[0];          # create uses numeric index
			my $name = join(' ',@rest);   # delete uses full name (may contain spaces)

			$wpmgr->createWaypoint($num) 	if $lpart eq 'create' && $what eq 'wp';
			$wpmgr->createRoute($num,@rest[1..$#rest]) if $lpart eq 'create' && $what eq 'route';
			$wpmgr->createGroup($num) 	 	if $lpart eq 'create' && $what eq 'group';

			$wpmgr->deleteWaypoint($name) 	if $lpart eq 'delete' && $what eq 'wp';
			$wpmgr->deleteRoute($name) 	 	if $lpart eq 'delete' && $what eq 'route';
			$wpmgr->deleteGroup($name) 	 	if $lpart eq 'delete' && $what eq 'group';
		}
		elsif ($lpart eq "route")
		{
			my ($route_id,$op,$wp_id) = split(/\s+/,$rpart);
			if ($op && ($op eq '+' || $op eq '-'))
			{
				my $route_name = $route_id =~ /^\d+$/ ? "testRoute$route_id"   : $route_id;
				my $wp_name    = $wp_id    =~ /^\d+$/ ? "testWaypoint$wp_id"   : $wp_id;
				$wpmgr->routeWaypoint($route_name,$wp_name,$op eq '+');
			}
			else
			{
				$wpmgr->showItem('route',$rpart);
			}
		}
		elsif ($lpart eq 'wp')
		{
			my ($wp_id,$group_id) = split(/\s+/,$rpart);
			if (defined($group_id))
			{
				my $wp_name    = $wp_id   =~ /^\d+$/ ? "testWaypoint$wp_id"  : $wp_id;
				my $group_name = !$group_id || $group_id eq '0' ? 0 :
				                 $group_id  =~ /^\d+$/ ? "testGroup$group_id" : $group_id;
				$wpmgr->setWaypointGroup($wp_name,$group_name);
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
		elsif ($lpart eq 'mod')
		{
			my ($what,$item_name,@kvs) = split(/\s+/,$rpart);
			$what = lc($what) if $what;
			if (!$what || !$item_name || !@kvs)
			{
				error("usage: mod <wp> <name> key=val [key=val ...]");
			}
			elsif ($what eq 'wp')
			{
				my %changes;
				for my $kv (@kvs)
				{
					my ($k,$v) = split(/=/,$kv,2);
					$changes{$k} = $v;
				}
				$changes{sym} += 0 if exists $changes{sym};
				$wpmgr->modifyWaypoint($item_name,\%changes);
			}
			else
			{
				error("mod: unknown type '$what'");
			}
		}

		elsif ($lpart eq 'new')
		{
			my ($what,$name,$uuid,@rest) = split(/\s+/,$rpart);
			$what = lc($what) if $what;
			if (!$what || !$name || !$uuid)
			{
				error("usage: new <wp|group|route> <name> <uuid> [params]");
			}
			elsif ($what eq 'wp')
			{
				my ($lat,$lon,$sym) = @rest;
				return error("new wp requires lat and lon") if !defined($lat) || !defined($lon);
				$wpmgr->createNamedWaypoint($name,$uuid,$lat+0,$lon+0,$sym);
			}
			elsif ($what eq 'group')
			{
				$wpmgr->createNamedGroup($name,$uuid);
			}
			elsif ($what eq 'route')
			{
				my ($color) = @rest;
				$wpmgr->createNamedRoute($name,$uuid,defined($color) ? $color+0 : undef);
			}
			else
			{
				error("new: unknown type '$what'");
			}
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
			$raydp->findImplementedService($name,1) ||
			$raydp->findServicePortByName($name,1);
		return error("service $name("._def($service_port).") doesn't exist or is not connected")
			if !$service_port || !$service_port->{connected};
		$service_port->doProbe($params);
	}

	# fshWriter

	elsif ($lpart eq 'write')
	{
		apps::raymarine::NET::fshWriter::write();
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

apps::raymarine::NET::c_RAYDP->new();
if ($WITH_RAYDP)
{
	$raydp->start();
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