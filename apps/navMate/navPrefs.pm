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
use n_defs qw($NAVMATE_DATABASE);

BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		init_prefs
		$DEPTH_DISPLAY_METERS
		$DEPTH_DISPLAY_FEET
		$PREF_DEPTH_DISPLAY
		$PREF_FAHRENHEIT
		$PREF_DATABASE_PATH
		$PREF_HTTP_PORT
		$PREF_MAP_BROWSER
	);
	push @EXPORT, grep { $_ ne 'initPrefs' } @Pub::Prefs::EXPORT;
}

our $DEPTH_DISPLAY_METERS = 0;
our $DEPTH_DISPLAY_FEET   = 1;
our $PREF_DEPTH_DISPLAY   = 'DEPTH_DISPLAY';
our $PREF_FAHRENHEIT      = 'FAHRENHEIT';
our $PREF_DATABASE_PATH   = 'DATABASE_PATH';
our $PREF_HTTP_PORT       = 'HTTP_PORT';
our $PREF_MAP_BROWSER     = 'MAP_BROWSER';

sub init_prefs
	# navMate's changeable prefs are placed into the prefs hash as in-hash
	# non-defaults: they ARE the discoverable list, and a hand-made
	# navMate.prefs overrides any of them.  set-only-if-absent never clobbers
	# a user's file value.  No prefs file is written -- defaults live in code
	# (the DB default here; HTTP_PORT in navServer.pm's new()).
{
	my $packaged = $Cava::Packager::PACKAGED ? 1 : 0;

	Pub::Prefs::initPrefs("$data_dir/navMate.prefs", {});

	setPref($PREF_DATABASE_PATH, $packaged ? "$data_dir/navMate.db" : $NAVMATE_DATABASE)
		if !defined getPref($PREF_DATABASE_PATH);
	setPref($PREF_MAP_BROWSER, '')
		if !defined getPref($PREF_MAP_BROWSER);
	setPref($PREF_DEPTH_DISPLAY, $DEPTH_DISPLAY_FEET)
		if !defined getPref($PREF_DEPTH_DISPLAY);
	setPref($PREF_FAHRENHEIT, 1)
		if !defined getPref($PREF_FAHRENHEIT);
}

1;
