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

use apps::raymarine::NET::s_serial;
use s_sniffer;
use w_resources;
use w_frame;
use tcpScanner;
use udpScanner;
use base 'Wx::App';

$ini_file = "$temp_dir/$appName.ini";


my $dbg_shark = 0;

my $WITH_SERIAL      = 1;
my $WITH_RAYDP       = 1;
my $WITH_HTTP_SERVER = 1;
my $WITH_SNIFFER     = 1;
my $WITH_TCP_SCANNER = 0;
my $WITH_UDP_SCANNER = 0;
my $WITH_WX          = 1;


#-----------------------------------------
# handleSerialCommand
#-----------------------------------------

sub handleSerialCommand
{
	my ($lpart,$rpart) = @_;
	display(0,0,"handleSerialCommand left($lpart) right($rpart)");
	dispatchCommand($lpart,$rpart);
}


#---------------------------------------------------------
# main
#---------------------------------------------------------

display(0,0,"shark.pm initializing");


if ($WITH_SERIAL)
{
	my $serial = apps::raymarine::NET::s_serial->new(\&handleSerialCommand);
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
if ($WITH_UDP_SCANNER)
{
	udpScanner->new();
}


startHTTPServer() if $WITH_HTTP_SERVER;

# the sniffer is started last because it has a blocking
# read in the thread which, for some reason, will cause
# threads->create() to block unless the E80 is turned on
# or there is ethernet traffic.

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
		$frame->Show(1);
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
