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
	);
	push @EXPORT, grep { $_ ne 'initPrefs' } @Pub::Prefs::EXPORT;
}

our $DEPTH_DISPLAY_METERS = 0;
our $DEPTH_DISPLAY_FEET   = 1;
our $PREF_DEPTH_DISPLAY   = 'DEPTH_DISPLAY';
our $PREF_FAHRENHEIT      = 'FAHRENHEIT';
our $PREF_DATABASE_PATH   = 'DATABASE_PATH';
our $PREF_HTTP_PORT       = 'HTTP_PORT';

# Installed builds must NOT default to the dev live database or the dev
# HTTP port, so a packaged navMate can run side by side with development.
# Packaged defaults derive from $data_dir (e.g. My Documents); dev keeps
# the live database and port 9883.  See docs/notes/build.md "Seam".
my $DEV_HTTP_PORT      = 9883;
my $PACKAGED_HTTP_PORT = 9873;

sub init_prefs
{
	my $packaged     = $Cava::Packager::PACKAGED ? 1 : 0;
	my $db_default   = $packaged ? "$data_dir/navMate.db" : $NAVMATE_DATABASE;
	my $port_default = $packaged ? $PACKAGED_HTTP_PORT : $DEV_HTTP_PORT;

	Pub::Prefs::initPrefs(
		"$data_dir/navMate.prefs",
		{
			$PREF_DEPTH_DISPLAY => $DEPTH_DISPLAY_FEET,
			$PREF_FAHRENHEIT    => 1,
			$PREF_DATABASE_PATH => $db_default,
			$PREF_HTTP_PORT     => $port_default,
		});

	_seedPrefsFile($db_default, $port_default);
}


sub _seedPrefsFile
	# On first run (no prefs file yet), write a barebones, human-editable
	# prefs file that spells out the database location and HTTP port, so the
	# values can be changed without guessing key names.  Never clobbers an
	# existing prefs file.
{
	my ($db_default, $port_default) = @_;
	my $file = "$data_dir/navMate.prefs";
	return if -f $file;

	my $text =
		"# navMate preferences\n".
		"# Lines beginning with # are comments.  Edit a value and restart navMate.\n".
		"\n".
		"# Full path to the navMate SQLite database.\n".
		"$PREF_DATABASE_PATH = $db_default\n".
		"\n".
		"# Port for the built-in HTTP / Leaflet map server.\n".
		"$PREF_HTTP_PORT = $port_default\n";

	printVarToFile(1, $file, $text, 1);
}

1;
