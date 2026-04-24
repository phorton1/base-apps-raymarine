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
use a_defs;
use a_utils;
use c_db;
use w_resources;
use winMain;
use base 'Wx::App';

$ini_file = "$temp_dir/$appName.ini";


#---------------------------------
# main
#---------------------------------

display(0,0,"navMate.pm initializing");

c_db::openDB();

if ($WITH_WX)
{
	display(0,0,"starting app");

	my $frame;

	sub OnInit
	{
		$frame = winMain->new();
		if (!$frame)
		{
			error("unable to create frame");
			return undef;
		}
		$frame->Show(1);
		display(0,0,"$$resources{app_title} started");
		my $uuid = c_db::newUUID();
		display(0,0,"test UUID: $uuid");
		return 1;
	}

	my $app = navMate->new();
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
		sleep(1);
	}
}
