#---------------------------------------------
# navMate.pm
#---------------------------------------------

package navMate;
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
use apps::raymarine::NET::a_mon;
use apps::raymarine::NET::a_utils;
use apps::raymarine::NET::a_parser;
use apps::raymarine::NET::b_sock;
use apps::raymarine::NET::b_records;
use apps::raymarine::NET::c_RAYDP;
use apps::raymarine::NET::d_WPMGR;
use apps::raymarine::NET::d_TRACK;
use apps::raymarine::NET::e_WPMGR;
use apps::raymarine::NET::e_TRACK;
use apps::raymarine::NET::e_wp_api;

use n_defs;
use n_utils;
use navPrefs;
use navDB;
use navVisibility;
use navOutline;
use navSelection;
use navServer;
use apps::raymarine::NET::s_serial;
use nmResources;
use nmFrame;

use base 'Wx::App';

$ini_file = "$temp_dir/$appName.ini";
$appClientName = 'navMate';
init_prefs();


#---------------------------------
# main
#---------------------------------

display(0,0,"navMate.pm initializing");

sub _handleSerialCommand
{
	my ($lpart, $rpart) = @_;
	dispatchNavMateCommand($lpart, $rpart);
}

my $serial = apps::raymarine::NET::s_serial->new(\&_handleSerialCommand);

loadOutlineState();
loadSelectionSets();
my $db_rc = navDB::openDB();
if ($db_rc == -1)
{
	display(0,0,"navMate: schema mismatch - use File->Import KML to rebuild database");
}
loadViewState();
if ($db_rc > 0)
{
	pruneDbVisibility();
	saveViewState();
}
navServer::startNavMateServer();

apps::raymarine::NET::a_defs::initServices(wpmgr => 1, track => 1, auto_query => 1);
apps::raymarine::NET::c_RAYDP->new();
$raydp->start();

$serial->start();

display(0,0,"starting app");

my $frame;

sub OnInit
{
	$frame = nmFrame->new();
	if (!$frame)
	{
		error("unable to create frame");
		return undef;
	}
	$frame->Show(1);
	display(0,0,"$$resources{app_title} started");
	return 1;
}

my $app = navMate->new();
Pub::WX::Main::run($app);

display(0,0,"ending $appName.pm frame=$frame");
$frame->DESTROY() if $frame;
$frame = undef;

