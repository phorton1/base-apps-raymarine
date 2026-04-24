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
	);
}


our $appName = "navMate";


my $pane_data    = {};
my $command_data = { %{$resources->{command_data}} };

my $main_menu = [
	'file_menu,&File',
	'view_menu,&View',
];

my $file_menu = [];

my $view_menu = [
	@{$resources->{view_menu}}
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
