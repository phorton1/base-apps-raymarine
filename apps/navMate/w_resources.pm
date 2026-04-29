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
		$WIN_BROWSER
		$WIN_E80
		$WIN_MONITOR
		$CMD_OPEN_MAP
		$CMD_IMPORT_KML
		$CMD_UPLOAD_E80
		$CMD_REFRESH_E80
	);
}


our $appName = "navMate";

our $WIN_BROWSER = 10001;
our $WIN_E80     = 10005;
our $WIN_MONITOR = 10006;
our $CMD_OPEN_MAP    = 10002;
our $CMD_IMPORT_KML  = 10003;
our $CMD_UPLOAD_E80  = 10004;
our $CMD_REFRESH_E80 = 10021;


my $pane_data = {
	$WIN_BROWSER => ['Unused String1', 'content'],
	$WIN_E80     => ['Unused String2', 'content'],
	$WIN_MONITOR => ['Unused String3', 'content'],
};

my $command_data = {
	%{$resources->{command_data}},
	$WIN_BROWSER => ['Browser',    'Navigation data browser'],
	$WIN_E80     => ['E80',        'Live E80 contents'],
	$WIN_MONITOR => ['Monitor',    'Monitor and control service monitoring bits'],
	$CMD_OPEN_MAP    => ['Open Map',    'Open the Leaflet map in a browser'],
	$CMD_IMPORT_KML  => ['Import KML',  'Delete and rebuild database from KML files'],
	$CMD_UPLOAD_E80  => ['Upload to E80', 'Upload collection to E80 plotter'],
	$CMD_REFRESH_E80 => ['Refresh E80', 'Re-query all waypoints, routes, groups, and tracks from E80'],
};

my @collection_context_menu = (
	$CMD_UPLOAD_E80,
);

my $main_menu = [
	'file_menu,&File',
	'edit_menu,&Edit',
	'view_menu,&View',
];

my $edit_menu = [
	$CMD_REFRESH_E80,
];

my $file_menu = [
	$CMD_IMPORT_KML,
];

my $view_menu = [
	$WIN_BROWSER,
	$WIN_E80,
	$WIN_MONITOR,
	$CMD_OPEN_MAP,
	$ID_SEPARATOR,
	@{$resources->{view_menu}},
];


$resources = { %$resources,
	app_title                => $appName,
	command_data             => $command_data,
	pane_data                => $pane_data,
	main_menu                => $main_menu,
	file_menu                => $file_menu,
	edit_menu                => $edit_menu,
	view_menu                => $view_menu,
	collection_context_menu  => \@collection_context_menu,
};


1;
