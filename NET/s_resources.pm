#!/usr/bin/perl
#-------------------------------------------------------------------------
# s_resources.pm
#-------------------------------------------------------------------------

package apps::raymarine::NET::s_resources;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::WX::Resources;
use Pub::WX::AppConfig;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
		$appName
        $resources

        $WIN_RAYDP
		$WIN_FILESYS
		$CMD_DOWNLOAD
    );
}

our $appName = "shark";

# derived class decides if wants viewNotebook
# commands added to the view menu, by setting
# the 'command_id' member on the notebook info.

our ($WIN_RAYDP,
	 $WIN_FILESYS,

	 $CMD_DOWNLOAD ) = (10000..11000);


# Pane data that allows looking up of notebook for windows
# This is a bit archaic and the first field is not used

my $pane_data = {
	$WIN_RAYDP		=> ['Unused String1',		'content'	],
	$WIN_FILESYS	=> ['Unused String1',		'content'	],
};


# Command data for this application.
# Notice the merging that takes place
# with the base appResources

my $command_data = {
	%{$resources->{command_data}},
	$WIN_RAYDP     => ['RayDP', 	'Raynet Discover Protocol'],
	$WIN_FILESYS   => ['FileSys', 	'Removable Media Fiile System'],
	$CMD_DOWNLOAD  => ['Download',	'Download Selected Items'],
};


# Notebook data includes an array "in order",
# and a lookup by id for notebooks to be opened by
# command id's

my $notebook_data = {
	content  => {
        name => 'content',
        row => 1,
        pos => 1,
        position => '',
        title => 'Content Notebook' },
};
my $notebooks = [$notebook_data->{content}];
my $notebook_name = {};


# Menus

my $main_menu = [
	'file_menu,&File',
	'view_menu,&View',
];

my $file_menu = [];

# Build our view menu (panes that can be opened)
# on top of the baae class view menu

my $view_menu = [
	$WIN_RAYDP,
	$WIN_FILESYS,
	$ID_SEPARATOR,
	@{$resources->{view_menu}}
];

my $filesys_context_menu = [
	$CMD_DOWNLOAD ];


# Merge and reset the single public object

$resources = { %$resources,
    app_title       => $appName,
    # temp_dir        => '/base/apps/minimum/temp',
    # ini_file        => '/base/apps/minimum/data/minimum.ini',
    # logfile         => '/base/apps/minimum/data/minimum.log',

    command_data    => $command_data,
    notebooks       => $notebooks,
    notebook_data   => $notebook_data,
    notebook_name   => $notebook_name,
    pane_data       => $pane_data,
    main_menu       => $main_menu,
    file_menu       => $file_menu,
	view_menu       => $view_menu,
	filesys_context_menu => $filesys_context_menu,

};



1;
