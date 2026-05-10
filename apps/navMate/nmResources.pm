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
	);
}


our $appName = "navMate";

our $WIN_DATABASE				= 10011;
our $WIN_E80					= 10012;
our $WIN_MONITOR				= 10013;

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


my $pane_data = {
	$WIN_DATABASE	=> ['Unused String1', 'content'],
	$WIN_E80		=> ['Unused String2', 'content'],
	$WIN_MONITOR	=> ['Unused String3', 'content'],
};

my $command_data = {
	%{$resources->{command_data}},
	$WIN_DATABASE				=> ['Database',				'navMate database browser'],
	$WIN_E80					=> ['E80',					'Live E80 contents'],
	$WIN_MONITOR				=> ['Monitor',				'Monitor and control service monitoring bits'],
	$COMMAND_OPEN_MAP			=> ['Open Map',				'Open the Leaflet map in a browser'],
	$COMMAND_CLEAR_MAP			=> ['Clear Map',			'Set all visible=0 and clear the Leaflet map'],
	$COMMAND_IMPORT_KML_NM		=> ['Import KML',			'Additive re-import from a navMate KML file'],
	$COMMAND_IMPORT_KML			=> ['OneTimeImportKML',		'Delete and rebuild database from KML files'],
	$COMMAND_EXPORT_KML			=> ['Export KML',			'Export navMate database to a KML file for Google Earth'],
	$COMMAND_REFRESH_DB			=> ['Refresh Window',		'Reload database window from current navMate.db'],
	$COMMAND_REFRESH_E80_DB		=> ['Refresh E80-DB',		'Re-query all waypoints, routes, groups, and tracks from E80'],
	$COMMAND_CLEAR_E80_DB		=> ['Clear E80 DB',			'Delete all waypoints, routes, groups, and tracks from E80'],
	$COMMAND_REFRESH_WIN_E80	=> ['Refresh winE80',		'Reload E80 window from in-memory data'],
	$COMMAND_IMPORT_DB_TEXT		=> ['ImportFromText',		'Replace navMate database from a text backup file'],
	$COMMAND_EXPORT_DB_TEXT		=> ['ExportToText',			'Export navMate database to a text backup file'],
	$COMMAND_SAVE_OUTLINE		=> ['Save Outline',			'Save tree expansion state to navMateOutline.json'],
	$COMMAND_RESTORE_OUTLINE	=> ['Restore Outline',		'Restore tree expansion state from navMateOutline.json'],
	$COMMAND_SAVE_SELECTION		=> ['Save Selection...',	'Save current tree selection to a named set'],
	$COMMAND_RESTORE_SELECTION	=> ['Restore Selection',	'Restore a named selection set in the tree'],
	$COMMAND_REVERT_DB			=> ['Revert DB',			'Revert navMate.db to last git-committed version'],
	$COMMAND_COMMIT_DB			=> ['Commit DB',			'Commit navMate.db to git with a message'],
};



my $main_menu = [
	'view_menu,&View',
	'database_menu,&Database',
	'e80_menu,&E80',
	'utils_menu,&Utils',
];

my $view_menu = [
	$WIN_DATABASE,
	$WIN_E80,
	$WIN_MONITOR,
	$ID_SEPARATOR,
	$COMMAND_OPEN_MAP,
	$COMMAND_CLEAR_MAP,
	$ID_SEPARATOR,
	@{$resources->{view_menu}},
];

my $database_menu = [
	$COMMAND_REFRESH_DB,
	$ID_SEPARATOR,
	$COMMAND_EXPORT_DB_TEXT,
	$COMMAND_IMPORT_DB_TEXT,
	$ID_SEPARATOR,
	$COMMAND_EXPORT_KML,
	$COMMAND_IMPORT_KML_NM,
];

my $e80_menu = [
	$COMMAND_REFRESH_WIN_E80,
	$COMMAND_REFRESH_E80_DB,
	$COMMAND_CLEAR_E80_DB,
];

my $utils_menu = [
	$COMMAND_IMPORT_KML,
	$ID_SEPARATOR,
	$COMMAND_REVERT_DB,
	$COMMAND_COMMIT_DB,
	$ID_SEPARATOR,
	$COMMAND_SAVE_OUTLINE,
	$COMMAND_RESTORE_OUTLINE,
	$ID_SEPARATOR,
	$COMMAND_SAVE_SELECTION,
	$COMMAND_RESTORE_SELECTION,
];


$resources = { %$resources,
	app_title                => $appName,
	command_data             => $command_data,
	pane_data                => $pane_data,
	main_menu                => $main_menu,
	view_menu                => $view_menu,
	database_menu            => $database_menu,
	e80_menu                 => $e80_menu,
	utils_menu               => $utils_menu,
};


1;
