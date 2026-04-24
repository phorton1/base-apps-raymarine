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
		$WIN_COLLECTIONS
	);
}


our $appName = "navMate";

our $WIN_COLLECTIONS = 10001;


my $pane_data = {
	$WIN_COLLECTIONS => ['Unused String1', 'content'],
};

my $command_data = {
	%{$resources->{command_data}},
	$WIN_COLLECTIONS => ['Collections', 'Navigation data collections tree'],
};

my $main_menu = [
	'file_menu,&File',
	'view_menu,&View',
];

my $file_menu = [];

my $view_menu = [
	$WIN_COLLECTIONS,
	$ID_SEPARATOR,
	@{$resources->{view_menu}},
];


$resources = { %$resources,
	app_title    => $appName,
	command_data => $command_data,
	pane_data    => $pane_data,
	main_menu    => $main_menu,
	file_menu    => $file_menu,
	view_menu    => $view_menu,
};


1;
