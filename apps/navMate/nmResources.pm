#!/usr/bin/perl
#-------------------------------------------------------------------------
# nmResources.pm
#-------------------------------------------------------------------------

package nmResources;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::WX::Resources;
use Pub::WX::AppConfig;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		$appName
		$resources

		$WIN_DATABASE
		$WIN_E80
		$WIN_MONITOR

		$COMMAND_OPEN_MAP
		$COMMAND_CLEAR_MAP
		$COMMAND_IMPORT_KML_NM
		$COMMAND_IMPORT_KML
		$COMMAND_EXPORT_KML
		$COMMAND_REFRESH_DB
		$COMMAND_REFRESH_E80_DB
		$COMMAND_CLEAR_E80_DB
		$COMMAND_REFRESH_WIN_E80
		$COMMAND_IMPORT_DB_TEXT
		$COMMAND_EXPORT_DB_TEXT
		$COMMAND_SAVE_OUTLINE
		$COMMAND_RESTORE_OUTLINE
		$COMMAND_SAVE_SELECTION
		$COMMAND_RESTORE_SELECTION
		$COMMAND_REVERT_DB
		$COMMAND_COMMIT_DB
		$COMMAND_COMPACT_DB_POSITIONS

		$WIN_FSH
		$COMMAND_OPEN_FSH_FILE
		$COMMAND_SAVE_FSH_FILE
		$COMMAND_SAVE_FSH_FILE_AS
		$COMMAND_SAVE_FSH_OUTLINE
		$COMMAND_RESTORE_FSH_OUTLINE
	);
}


our $appName = "navMate";

our $WIN_DATABASE				= 10011;
our $WIN_E80					= 10012;
our $WIN_MONITOR				= 10013;
our $WIN_FSH					= 10014;

our $COMMAND_OPEN_MAP			= 10021;
our $COMMAND_CLEAR_MAP			= 10022;
our $COMMAND_IMPORT_KML_NM		= 10030;
our $COMMAND_IMPORT_KML			= 10031;
our $COMMAND_EXPORT_KML			= 10032;
our $COMMAND_REFRESH_DB			= 10041;
our $COMMAND_REFRESH_E80_DB		= 10042;
our $COMMAND_CLEAR_E80_DB		= 10043;
our $COMMAND_REFRESH_WIN_E80	= 10050;
our $COMMAND_IMPORT_DB_TEXT		= 10061;
our $COMMAND_EXPORT_DB_TEXT		= 10062;
our $COMMAND_SAVE_OUTLINE		= 10071;
our $COMMAND_RESTORE_OUTLINE	= 10072;
our $COMMAND_SAVE_SELECTION		= 10073;
our $COMMAND_RESTORE_SELECTION	= 10074;
our $COMMAND_REVERT_DB			= 10091;
our $COMMAND_COMMIT_DB			= 10092;
our $COMMAND_COMPACT_DB_POSITIONS = 10093;

our $COMMAND_OPEN_FSH_FILE		= 10081;
our $COMMAND_SAVE_FSH_FILE		= 10082;
our $COMMAND_SAVE_FSH_FILE_AS	= 10083;
our $COMMAND_SAVE_FSH_OUTLINE	= 10084;
our $COMMAND_RESTORE_FSH_OUTLINE = 10085;


my $pane_data = {
	$WIN_DATABASE	=> ['Unused String1', 'content'],
	$WIN_E80		=> ['Unused String2', 'content'],
	$WIN_MONITOR	=> ['Unused String3', 'content'],
	$WIN_FSH		=> ['Unused String4', 'content'],
};

my $command_data = {
	%{$resources->{command_data}},
	$WIN_DATABASE				=> ['Database',				'navMate database browser'],
	$WIN_E80					=> ['E80',					'Live E80 contents'],
	$WIN_MONITOR				=> ['Monitor',				'Monitor and control service monitoring bits'],
	$WIN_FSH					=> ['FSH',					'FSH file browser'],
	$COMMAND_OPEN_FSH_FILE		=> ['Open File...',			'Load an FSH archive file into the FSH browser'],
	$COMMAND_SAVE_FSH_FILE		=> ['Save File',			'Save FSH data back to the current file (round-trip rewrite)'],
	$COMMAND_SAVE_FSH_FILE_AS	=> ['Save As...',			'Save FSH data to a new file and switch to that filename'],
	$COMMAND_SAVE_FSH_OUTLINE	=> ['Save Outline',			'Save FSH tree expansion state to nmFSHOutline.json'],
	$COMMAND_RESTORE_FSH_OUTLINE => ['Restore Outline',		'Restore FSH tree expansion state from nmFSHOutline.json'],
	$COMMAND_OPEN_MAP			=> ['Open Map',				'Open the Leaflet map in a browser'],
	$COMMAND_CLEAR_MAP			=> ['Clear Map',			'Set all visible=0 and clear the Leaflet map'],
	$COMMAND_IMPORT_KML_NM		=> ['Import KML',			'Additive re-import from a navMate KML file'],
	$COMMAND_IMPORT_KML			=> ['OneTimeImportKML',		'Delete and rebuild database from KML files'],
	$COMMAND_EXPORT_KML			=> ['Export KML',			'Export navMate database to a KML file for Google Earth'],
	$COMMAND_REFRESH_DB			=> ['Refresh Window',		'Reload database window from current navMate.db'],
	$COMMAND_REFRESH_E80_DB		=> ['Refresh E80-DB',		'Re-query all waypoints, routes, groups, and tracks from E80'],
	$COMMAND_CLEAR_E80_DB		=> ['Clear',				'Delete all waypoints, routes, groups, and tracks from E80'],
	$COMMAND_REFRESH_WIN_E80	=> ['Refresh Window',		'Reload E80 window from in-memory data'],
	$COMMAND_IMPORT_DB_TEXT		=> ['Import from Text',		'Replace navMate database from a text backup file'],
	$COMMAND_EXPORT_DB_TEXT		=> ['Export to Text',		'Export navMate database to a text backup file'],
	$COMMAND_SAVE_OUTLINE		=> ['Save Outline',			'Save database tree expansion state to nmDBOutline.json'],
	$COMMAND_RESTORE_OUTLINE	=> ['Restore Outline',		'Restore database tree expansion state from nmDBOutline.json'],
	$COMMAND_SAVE_SELECTION		=> ['Save Selection...',	'Save current tree selection to a named set'],
	$COMMAND_RESTORE_SELECTION	=> ['Restore Selection',	'Restore a named selection set in the tree'],
	$COMMAND_REVERT_DB			=> ['Revert',				'Revert navMate.db to last git-committed version'],
	$COMMAND_COMMIT_DB			=> ['Commit',				'Commit navMate.db to git with a message'],
	$COMMAND_COMPACT_DB_POSITIONS => ['Compact Positions',	'Renumber every container\'s child positions to 1.0, 2.0, 3.0...'],
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
];

my $fsh_menu = [
	$COMMAND_OPEN_FSH_FILE,
	$COMMAND_SAVE_FSH_FILE,
	$COMMAND_SAVE_FSH_FILE_AS,
	$ID_SEPARATOR,
	$COMMAND_SAVE_FSH_OUTLINE,
	$COMMAND_RESTORE_FSH_OUTLINE,
];

my $utils_menu = [
	$COMMAND_IMPORT_KML,
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
};


1;
