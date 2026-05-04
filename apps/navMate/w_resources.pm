#!/usr/bin/perl
#-------------------------------------------------------------------------
# w_resources.pm
#-------------------------------------------------------------------------

package w_resources;
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
		$COMMAND_IMPORT_KML
		$COMMAND_UPLOAD_E80
		$COMMAND_REFRESH_E80
		$COMMAND_REFRESH_DB
		$COMMAND_IMPORT_OLDE80
		$COMMAND_EXPORT_DB_TEXT
		$COMMAND_IMPORT_DB_TEXT
		$COMMAND_REFRESH_E80_DATA
	);
}


our $appName = "navMate";

our $WIN_DATABASE = 10001;
our $WIN_E80     = 10005;
our $WIN_MONITOR = 10006;
our $COMMAND_OPEN_MAP    = 10002;
our $COMMAND_IMPORT_KML  = 10003;
our $COMMAND_UPLOAD_E80  = 10004;
our $COMMAND_REFRESH_E80      = 10023;
our $COMMAND_REFRESH_E80_DATA = 10027;
our $COMMAND_REFRESH_DB    = 10022;
our $COMMAND_IMPORT_OLDE80 = 10024;
our $COMMAND_EXPORT_DB_TEXT = 10025;
our $COMMAND_IMPORT_DB_TEXT = 10026;


my $pane_data = {
	$WIN_DATABASE => ['Unused String1', 'content'],
	$WIN_E80     => ['Unused String2', 'content'],
	$WIN_MONITOR => ['Unused String3', 'content'],
};

my $command_data = {
	%{$resources->{command_data}},
	$WIN_DATABASE => ['Database',    'navMate database browser'],
	$WIN_E80     => ['E80',        'Live E80 contents'],
	$WIN_MONITOR => ['Monitor',    'Monitor and control service monitoring bits'],
	$COMMAND_OPEN_MAP    => ['Open Map',    'Open the Leaflet map in a browser'],
	$COMMAND_IMPORT_KML  => ['OneTimeImportKML',  'Delete and rebuild database from KML files'],
	$COMMAND_UPLOAD_E80  => ['Upload to E80', 'Upload collection to E80 plotter'],
	$COMMAND_REFRESH_E80      => ['Refresh Window', 'Reload E80 window from in-memory data'],
	$COMMAND_REFRESH_DB       => ['Refresh Window', 'Reload database window from current navMate.db'],
	$COMMAND_REFRESH_E80_DATA => ['Refresh E80',    'Re-query all waypoints, routes, groups, and tracks from E80'],
	$COMMAND_IMPORT_OLDE80  => ['Import oldE80 Residue', 'Analyze oldE80 tracks and insert novel runs into DB'],
	$COMMAND_EXPORT_DB_TEXT => ['ExportToText', 'Export navMate database to a text backup file'],
	$COMMAND_IMPORT_DB_TEXT => ['ImportFromText', 'Replace navMate database from a text backup file'],
};

my @collection_context_menu = (
	$COMMAND_UPLOAD_E80,
);

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
	$ID_SEPARATOR,
	@{$resources->{view_menu}},
];

my $database_menu = [
	$COMMAND_REFRESH_DB,
	$ID_SEPARATOR,
	$COMMAND_EXPORT_DB_TEXT,
	$COMMAND_IMPORT_DB_TEXT,
];

my $e80_menu = [
	$COMMAND_REFRESH_E80,
	$COMMAND_REFRESH_E80_DATA,
];

my $utils_menu = [
	$COMMAND_IMPORT_KML,
	$COMMAND_IMPORT_OLDE80,
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
	collection_context_menu  => \@collection_context_menu,
};


1;
