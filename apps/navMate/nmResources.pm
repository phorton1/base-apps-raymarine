#!/usr/bin/perl
#-------------------------------------------------------------------------
# nmResources.pm
#-------------------------------------------------------------------------

package nmResources;
use strict;
use warnings;
use threads;
use threads::shared;
use File::Basename;
use Wx qw(:everything);
use Pub::WX::Resources;
use Pub::WX::AppConfig;
use apps::raymarine::NET::a_utils qw(@E80_SYMS);
use n_utils qw($app_dir);


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		$appName
		$resources

		symBitmap
		makeSymComboBox
		ensureLeafletNative
		ensureLeafletMask
		leafletNativePath
		leafletMaskPath

		$WIN_DATABASE
		$WIN_E80
		$WIN_MONITOR
		$WIN_FILESYS
		$CMD_DOWNLOAD

		$COMMAND_OPEN_MAP
		$COMMAND_CLEAR_MAP
		$COMMAND_IMPORT_KML_NM
		$COMMAND_IMPORT_KML
		$COMMAND_EXPORT_KML
		$COMMAND_REFRESH_DB
		$COMMAND_REFRESH_E80_DB
		$COMMAND_CLEAR_E80_DB
		$COMMAND_REFRESH_WIN_E80
		$COMMAND_SAVE_E80_CONFIG
		$COMMAND_RESTORE_E80_CONFIG
		$COMMAND_CLEAR_E80_CONFIG
		$COMMAND_GRAB_E80_SCREEN
		$COMMAND_IMPORT_DB_TEXT
		$COMMAND_EXPORT_DB_TEXT
		$COMMAND_SAVE_OUTLINE
		$COMMAND_RESTORE_OUTLINE
		$COMMAND_SAVE_SELECTION
		$COMMAND_RESTORE_SELECTION
		$COMMAND_REVERT_DB
		$COMMAND_COMMIT_DB
		$COMMAND_COMPACT_DB_POSITIONS
		$COMMAND_SYM_MAPPING
		$COMMAND_FORCE_SYM_RESET

		$WIN_FSH
		$COMMAND_NEW_FSH
		$COMMAND_OPEN_FSH_FILE
		$COMMAND_SAVE_FSH_FILE
		$COMMAND_SAVE_FSH_FILE_AS
		$COMMAND_SAVE_FSH_OUTLINE
		$COMMAND_RESTORE_FSH_OUTLINE
		$COMMAND_CONVERT_FSH_TO_NAVMATE
	);
}


our $appName = "navMate";

our $WIN_DATABASE				= 10011;
our $WIN_E80					= 10012;
our $WIN_MONITOR				= 10013;
our $WIN_FSH					= 10014;
our $WIN_FILESYS				= 10015;

our $CMD_DOWNLOAD				= 10100;

our $COMMAND_OPEN_MAP			= 10021;
our $COMMAND_CLEAR_MAP			= 10022;
our $COMMAND_IMPORT_KML_NM		= 10030;
our $COMMAND_IMPORT_KML			= 10031;
our $COMMAND_EXPORT_KML			= 10032;
our $COMMAND_REFRESH_DB			= 10041;
our $COMMAND_REFRESH_E80_DB		= 10042;
our $COMMAND_CLEAR_E80_DB		= 10043;
our $COMMAND_REFRESH_WIN_E80	= 10050;
our $COMMAND_SAVE_E80_CONFIG	= 10051;
our $COMMAND_RESTORE_E80_CONFIG	= 10052;
our $COMMAND_CLEAR_E80_CONFIG	= 10053;
our $COMMAND_GRAB_E80_SCREEN	= 10054;
our $COMMAND_IMPORT_DB_TEXT		= 10061;
our $COMMAND_EXPORT_DB_TEXT		= 10062;
our $COMMAND_SAVE_OUTLINE		= 10071;
our $COMMAND_RESTORE_OUTLINE	= 10072;
our $COMMAND_SAVE_SELECTION		= 10073;
our $COMMAND_RESTORE_SELECTION	= 10074;
our $COMMAND_REVERT_DB			= 10091;
our $COMMAND_COMMIT_DB			= 10092;
our $COMMAND_COMPACT_DB_POSITIONS = 10093;

our $COMMAND_SYM_MAPPING		= 10094;
our $COMMAND_FORCE_SYM_RESET	= 10095;

our $COMMAND_NEW_FSH			= 10080;
our $COMMAND_OPEN_FSH_FILE		= 10081;
our $COMMAND_SAVE_FSH_FILE		= 10082;
our $COMMAND_SAVE_FSH_FILE_AS	= 10083;
our $COMMAND_SAVE_FSH_OUTLINE	= 10084;
our $COMMAND_RESTORE_FSH_OUTLINE = 10085;
our $COMMAND_CONVERT_FSH_TO_NAVMATE = 10086;


my $pane_data = {
	$WIN_DATABASE	=> ['Unused String1', 'content'],
	$WIN_E80		=> ['Unused String2', 'content'],
	$WIN_MONITOR	=> ['Unused String3', 'content'],
	$WIN_FSH		=> ['Unused String4', 'content'],
	$WIN_FILESYS	=> ['Unused String5', 'content'],
};

my $command_data = {
	%{$resources->{command_data}},
	$WIN_DATABASE				=> ['Database',				'navMate database browser'],
	$WIN_E80					=> ['E80',					'Live E80 contents'],
	$WIN_MONITOR				=> ['Monitor',				'Monitor and control service monitoring bits'],
	$WIN_FSH					=> ['FSH',					'FSH file browser'],
	$WIN_FILESYS				=> ['FileSys',				'E80 removable media file system'],
	$CMD_DOWNLOAD				=> ['Download',				'Download selected items'],
	$COMMAND_NEW_FSH			=> ['New',					'Create a new empty untitled FSH in memory'],
	$COMMAND_OPEN_FSH_FILE		=> ['Open File...',			'Load an FSH archive file into the FSH browser'],
	$COMMAND_SAVE_FSH_FILE		=> ['Save File',			'Save FSH data back to the current file (round-trip rewrite)'],
	$COMMAND_SAVE_FSH_FILE_AS	=> ['Save As...',			'Save FSH data to a new file and switch to that filename'],
	$COMMAND_SAVE_FSH_OUTLINE	=> ['Save Outline',			'Save FSH tree expansion state to nmFSHOutline.json'],
	$COMMAND_RESTORE_FSH_OUTLINE => ['Restore Outline',		'Restore FSH tree expansion state from nmFSHOutline.json'],
	$COMMAND_CONVERT_FSH_TO_NAVMATE => ['Convert to navMate Working Copy', 'Replace each multi-segment track with N real -NNN tracks (in-memory; Save File to persist)'],
	$COMMAND_OPEN_MAP			=> ['Open Map',				'Open the Leaflet map in a browser'],
	$COMMAND_CLEAR_MAP			=> ['Clear Map',			'Set all visible=0 and clear the Leaflet map'],
	$COMMAND_IMPORT_KML_NM		=> ['Import KML',			'Additive re-import from a navMate KML file'],
	$COMMAND_IMPORT_KML			=> ['OneTimeImportKML',		'Delete and rebuild database from KML files'],
	$COMMAND_EXPORT_KML			=> ['Export KML',			'Export navMate database to a KML file for Google Earth'],
	$COMMAND_REFRESH_DB			=> ['Refresh Window',		'Reload database window from current navMate.db'],
	$COMMAND_REFRESH_E80_DB		=> ['Refresh E80-DB',		'Re-query all waypoints, routes, groups, and tracks from E80'],
	$COMMAND_CLEAR_E80_DB		=> ['Clear',				'Delete all waypoints, routes, groups, and tracks from E80'],
	$COMMAND_REFRESH_WIN_E80	=> ['Refresh Window',		'Reload E80 window from in-memory data'],
	$COMMAND_SAVE_E80_CONFIG	=> ['Save Configuration...',	'Save the E80 display configuration to a folder'],
	$COMMAND_RESTORE_E80_CONFIG	=> ['Restore Configuration...',	'Restore a saved E80 display configuration from a folder'],
	$COMMAND_CLEAR_E80_CONFIG	=> ['Clear Configuration',	'Reset the E80 display configuration to factory defaults'],
	$COMMAND_GRAB_E80_SCREEN	=> ['Grab Screen...',		'Capture the live E80 screen to a PNG image'],
	$COMMAND_IMPORT_DB_TEXT		=> ['Import from Text',		'Replace navMate database from a text backup file'],
	$COMMAND_EXPORT_DB_TEXT		=> ['Export to Text',		'Export navMate database to a text backup file'],
	$COMMAND_SAVE_OUTLINE		=> ['Save Outline',			'Save database tree expansion state to nmDBOutline.json'],
	$COMMAND_RESTORE_OUTLINE	=> ['Restore Outline',		'Restore database tree expansion state from nmDBOutline.json'],
	$COMMAND_SAVE_SELECTION		=> ['Save Selection...',	'Save current tree selection to a named set'],
	$COMMAND_RESTORE_SELECTION	=> ['Restore Selection',	'Restore a named selection set in the tree'],
	$COMMAND_REVERT_DB			=> ['Revert',				'Revert navMate.db to last git-committed version'],
	$COMMAND_COMMIT_DB			=> ['Commit',				'Commit navMate.db to git with a message'],
	$COMMAND_COMPACT_DB_POSITIONS => ['Compact Positions',	'Renumber every container\'s child positions to 1.0, 2.0, 3.0...'],
	$COMMAND_SYM_MAPPING		=> ['Waypoint Sym Mapping...',	'View and edit the wp_type -> sym mapping; conservative update of mapped waypoints'],
	$COMMAND_FORCE_SYM_RESET	=> ['Force Reset Syms by Type...', 'Force every waypoint of a chosen wp_type to its mapped sym, overwriting hand-set syms'],
};



my $main_menu = [
	'view_menu,&View',
	'database_menu,&Database',
	'e80_menu,&E80',
	'fsh_menu,&FSH',
	'utils_menu,&Utils',
];

my $view_menu = [
	$WIN_DATABASE,
	$WIN_E80,
	$WIN_MONITOR,
	$WIN_FSH,
	$WIN_FILESYS,
	$ID_SEPARATOR,
	$COMMAND_OPEN_MAP,
	$COMMAND_CLEAR_MAP,
	$ID_SEPARATOR,
	@{$resources->{view_menu}},
];

my $database_menu = [
	$COMMAND_REFRESH_DB,
	$ID_SEPARATOR,
	$COMMAND_COMMIT_DB,
	$COMMAND_REVERT_DB,
	$ID_SEPARATOR,
	$COMMAND_SAVE_OUTLINE,
	$COMMAND_RESTORE_OUTLINE,
	$ID_SEPARATOR,
	$COMMAND_SAVE_SELECTION,
	$COMMAND_RESTORE_SELECTION,
	$ID_SEPARATOR,
	$COMMAND_IMPORT_DB_TEXT,
	$COMMAND_EXPORT_DB_TEXT,
	$ID_SEPARATOR,
	$COMMAND_IMPORT_KML_NM,
	$COMMAND_EXPORT_KML,
	$ID_SEPARATOR,
	$COMMAND_COMPACT_DB_POSITIONS,
];

my $e80_menu = [
	$COMMAND_REFRESH_WIN_E80,
	$COMMAND_REFRESH_E80_DB,
	$COMMAND_CLEAR_E80_DB,
	$ID_SEPARATOR,
	$WIN_FILESYS,
	$ID_SEPARATOR,
	$COMMAND_SAVE_E80_CONFIG,
	$COMMAND_RESTORE_E80_CONFIG,
	$COMMAND_CLEAR_E80_CONFIG,
	$ID_SEPARATOR,
	$COMMAND_GRAB_E80_SCREEN,
];

my $filesys_context_menu = [
	$CMD_DOWNLOAD,
];

my $fsh_menu = [
	$COMMAND_NEW_FSH,
	$COMMAND_OPEN_FSH_FILE,
	$COMMAND_SAVE_FSH_FILE,
	$COMMAND_SAVE_FSH_FILE_AS,
	$ID_SEPARATOR,
	$COMMAND_CONVERT_FSH_TO_NAVMATE,
	$ID_SEPARATOR,
	$COMMAND_SAVE_FSH_OUTLINE,
	$COMMAND_RESTORE_FSH_OUTLINE,
];

my $utils_menu = [
	$COMMAND_SYM_MAPPING,
	$COMMAND_FORCE_SYM_RESET,
];


$resources = { %$resources,
	app_title                => $appName,
	command_data             => $command_data,
	pane_data                => $pane_data,
	main_menu                => $main_menu,
	view_menu                => $view_menu,
	database_menu            => $database_menu,
	e80_menu                 => $e80_menu,
	fsh_menu                 => $fsh_menu,
	utils_menu               => $utils_menu,
	filesys_context_menu     => $filesys_context_menu,
};


#-------------------------------------------------------------------------
# sym icon helpers
#-------------------------------------------------------------------------
# sym{NN}.png sources live in sym_catalog/ (16x16 wall-to-wall, with
# the 0x00FF00 green sentinel marking transparent regions).  symBitmap
# returns a 20x20 picker bitmap built lazily into sym_catalog/cache/
# 20x20_NN.png by adding a 2-px white border around the source and
# resolving the green sentinel to white.  Stale cache files (older
# than their source) are rebuilt automatically on next access.
# makeSymComboBox builds a Wx::BitmapComboBox populated with all
# in-use syms (text + icon) from @E80_SYMS.  An optional $multi_label
# prepends a "(multi)" style entry for the multi-editor's mixed-
# selection case.

my %_sym_bitmaps;
my $_blank_bm;

sub _ensureCache20x20
{
	# Build sym_catalog/cache/20x20_NN.png from sym_catalog/symNN.png
	# if missing or older than the source.  20x20 = 16x16 source + 2 px
	# white border; green sentinel pixels in the source resolve to white.
	my ($src_path, $cache_path) = @_;
	my $src_mtime   = (stat($src_path))[9];
	my $cache_mtime = -f $cache_path ? (stat($cache_path))[9] : 0;
	return if defined $src_mtime && $cache_mtime >= $src_mtime;

	my $dir = $cache_path;
	$dir =~ s|/[^/]+$||;
	mkdir $dir if !-d $dir;

	my $src = Wx::Image->new($src_path, wxBITMAP_TYPE_PNG);
	return if !$src || !$src->IsOk();

	my $out = Wx::Image->new(20, 20);
	for my $y (0 .. 19)
	{
		for my $x (0 .. 19)
		{
			$out->SetRGB($x, $y, 255, 255, 255);
		}
	}
	for my $y (0 .. 15)
	{
		for my $x (0 .. 15)
		{
			my $r = $src->GetRed($x, $y);
			my $g = $src->GetGreen($x, $y);
			my $b = $src->GetBlue($x, $y);
			if ($r == 0 && $g == 255 && $b == 0)
			{
				$out->SetRGB($x + 2, $y + 2, 255, 255, 255);
			}
			else
			{
				$out->SetRGB($x + 2, $y + 2, $r, $g, $b);
			}
		}
	}
	$out->SaveFile($cache_path, wxBITMAP_TYPE_PNG);
}

sub symBitmap
{
	my ($i) = @_;
	return undef if !defined $i || $i < 0 || $i > $#E80_SYMS;
	return $_sym_bitmaps{$i} if exists $_sym_bitmaps{$i};
	my $src   = sprintf('%s/sym_catalog/sym%02d.png',          $app_dir, $i);
	my $cache = sprintf('%s/sym_catalog/cache/20x20_%02d.png', $app_dir, $i);
	_ensureCache20x20($src, $cache);
	$_sym_bitmaps{$i} = Wx::Bitmap->new($cache, wxBITMAP_TYPE_PNG);
	return $_sym_bitmaps{$i};
}

sub _blankBitmap
{
	$_blank_bm //= Wx::Bitmap->new(20, 20);
	return $_blank_bm;
}

sub makeSymComboBox
{
	my ($parent, $pos, $size, $multi_label) = @_;
	my $cb = Wx::BitmapComboBox->new($parent, -1, '',
		$pos  // wxDefaultPosition,
		$size // wxDefaultSize,
		[], wxCB_READONLY);
	if (defined $multi_label)
	{
		$cb->Append($multi_label, _blankBitmap());
	}
	for my $i (0 .. $#E80_SYMS)
	{
		$cb->Append(sprintf('%2d - %s', $i, $E80_SYMS[$i]), symBitmap($i) // _blankBitmap());
	}
	return $cb;
}


#-------------------------------------------------------------------------
# leaflet sym cache helpers
#-------------------------------------------------------------------------
# The Leaflet client renders waypoint markers with the sym art.  Two
# 16x16 RGBA variants live alongside the wx picker caches under
# sym_catalog/cache/:
#   leaflet_native_NN.png -- original RGB, green sentinel -> alpha 0.
#                            Used directly for E80 and FSH waypoints
#                            (native red/blue rendering).
#   leaflet_mask_NN.png   -- RGB collapsed to luminance (Rec 601),
#                            green sentinel -> alpha 0.  The browser
#                            tints this in a canvas per the WP's
#                            ABGR color for database waypoints.
# Both are built lazily, mtime-gated against the source symNN.png.

sub leafletNativePath
{
	my ($i) = @_;
	return sprintf('%s/sym_catalog/cache/leaflet_native_%02d.png', $app_dir, $i);
}

sub leafletMaskPath
{
	my ($i) = @_;
	return sprintf('%s/sym_catalog/cache/leaflet_mask_%02d.png', $app_dir, $i);
}

sub _buildLeafletVariant
{
	# Shared builder for both leaflet cache variants.  $to_grey controls
	# whether non-sentinel pixels keep their RGB or collapse to luminance.
	# Sentinel pixels (0, 255, 0) become transparent; everything else is
	# opaque.  Alpha is set via a single SetAlpha(buffer) call --
	# wxPerl's binding maps SetAlpha to SetAlphaData and rejects the
	# per-pixel (x, y, a) form.
	my ($src_path, $cache_path, $to_grey) = @_;
	my $src_mtime   = (stat($src_path))[9];
	my $cache_mtime = -f $cache_path ? (stat($cache_path))[9] : 0;
	return if defined $src_mtime && $cache_mtime >= $src_mtime;

	my $dir = $cache_path;
	$dir =~ s|/[^/]+$||;
	mkdir $dir if !-d $dir;

	my $src = Wx::Image->new($src_path, wxBITMAP_TYPE_PNG);
	return if !$src || !$src->IsOk();

	my $out   = Wx::Image->new(16, 16);
	my $alpha = '';
	for my $y (0 .. 15)
	{
		for my $x (0 .. 15)
		{
			my $r = $src->GetRed($x, $y);
			my $g = $src->GetGreen($x, $y);
			my $b = $src->GetBlue($x, $y);
			if ($r == 0 && $g == 255 && $b == 0)
			{
				# RGB at fully-transparent pixels is irrelevant once
				# alpha=0; white degrades better than black if the alpha
				# channel is ever stripped.
				$out->SetRGB($x, $y, 255, 255, 255);
				$alpha .= chr(0);
			}
			elsif ($to_grey)
			{
				# Chroma + lift encoding for HSV-style hue replacement:
				#   mask.R = chroma = max(r,g,b) - min(r,g,b)
				#   mask.G = lift   = min(r,g,b)
				# Client tints with:  out = userColor * chroma/255 + lift
				# This preserves the source palette's "lift toward white"
				# (e.g. native pixel (230,175,175) has chroma=55 and
				# lift=175 -- a heavily-white-lifted highlight that
				# reads as bright pink in red sym art and would still
				# read as a bright highlight when tinted to any hue).
				my $max = $r > $g ? ($r > $b ? $r : $b) : ($g > $b ? $g : $b);
				my $min = $r < $g ? ($r < $b ? $r : $b) : ($g < $b ? $g : $b);
				$out->SetRGB($x, $y, $max - $min, $min, 0);
				$alpha .= chr(255);
			}
			else
			{
				$out->SetRGB($x, $y, $r, $g, $b);
				$alpha .= chr(255);
			}
		}
	}
	$out->SetAlpha($alpha);
	$out->SaveFile($cache_path, wxBITMAP_TYPE_PNG);
}

sub ensureLeafletNative
{
	my ($i) = @_;
	return undef if !defined $i || $i < 0 || $i > $#E80_SYMS;
	my $src   = sprintf('%s/sym_catalog/sym%02d.png', $app_dir, $i);
	my $cache = leafletNativePath($i);
	_buildLeafletVariant($src, $cache, 0);
	return -f $cache ? $cache : undef;
}

sub ensureLeafletMask
{
	my ($i) = @_;
	return undef if !defined $i || $i < 0 || $i > $#E80_SYMS;
	my $src   = sprintf('%s/sym_catalog/sym%02d.png', $app_dir, $i);
	my $cache = leafletMaskPath($i);
	_buildLeafletVariant($src, $cache, 1);
	return -f $cache ? $cache : undef;
}


1;
