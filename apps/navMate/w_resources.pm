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
		$CMD_OPEN_MAP
		$CMD_IMPORT_KML
		$CMD_UPLOAD_E80
	);
}


our $appName = "navMate";

our $WIN_BROWSER = 10001;
our $CMD_OPEN_MAP    = 10002;
our $CMD_IMPORT_KML  = 10003;
our $CMD_UPLOAD_E80  = 10004;


my $pane_data = {
	$WIN_BROWSER => ['Unused String1', 'content'],
};

my $command_data = {
	%{$resources->{command_data}},
	$WIN_BROWSER => ['Browser', 'Navigation data browser'],
	$CMD_OPEN_MAP    => ['Open Map',    'Open the Leaflet map in a browser'],
	$CMD_IMPORT_KML  => ['Import KML',  'Delete and rebuild database from KML files'],
	$CMD_UPLOAD_E80  => ['Upload to E80', 'Upload collection to E80 plotter'],
};

my @collection_context_menu = (
	$CMD_UPLOAD_E80,
);

my $main_menu = [
	'file_menu,&File',
	'view_menu,&View',
];

my $file_menu = [
	$CMD_IMPORT_KML,
];

my $view_menu = [
	$WIN_BROWSER,
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
	view_menu                => $view_menu,
	collection_context_menu  => \@collection_context_menu,
};


1;
