#---------------------------------------------
# navPrefs.pm
#---------------------------------------------

package navPrefs;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Prefs;

BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		init_prefs
		$DEPTH_DISPLAY_METERS
		$DEPTH_DISPLAY_FEET
		$PREF_DEPTH_DISPLAY
		$PREF_FAHRENHEIT
	);
	push @EXPORT, grep { $_ ne 'initPrefs' } @Pub::Prefs::EXPORT;
}

our $DEPTH_DISPLAY_METERS = 0;
our $DEPTH_DISPLAY_FEET   = 1;
our $PREF_DEPTH_DISPLAY   = 'DEPTH_DISPLAY';
our $PREF_FAHRENHEIT      = 'FAHRENHEIT';

sub init_prefs
{
	Pub::Prefs::initPrefs(
		"$data_dir/navMate.prefs",
		{
			$PREF_DEPTH_DISPLAY => $DEPTH_DISPLAY_FEET,
			$PREF_FAHRENHEIT    => 1,
		});
}

1;
