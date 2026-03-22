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
	our @EXPORT = qw (
		$appName
        $resources

        $WIN_RAYSYS
		$WIN_SNIFFER
		$WIN_SHARK
		$WIN_FILESYS
		$WIN_DBNAV
		$CMD_DOWNLOAD
    );
}

our $appName = "shark";

# derived class decides if wants viewNotebook
# commands added to the view menu, by setting
# the 'command_id' member on the notebook info.

our ($WIN_RAYSYS,
	 $WIN_SHARK,
	 $WIN_SNIFFER,
	 $WIN_FILESYS,
	 $WIN_DBNAV,

	 $CMD_DOWNLOAD ) = (10000..11000);


# Pane data that allows looking up of notebook for windows
# This is a bit archaic and the first field is not used

my $pane_data = {
	$WIN_RAYSYS		=> ['Unused String1',		'content'	],
	$WIN_SHARK		=> ['Unused String1',		'content'	],
	$WIN_SNIFFER	=> ['Unused String1',		'content'	],
	$WIN_FILESYS	=> ['Unused String1',		'content'	],
	$WIN_DBNAV		=> ['Unused String1',		'content'	],
};


# Command data for this application.
# Notice the merging that takes place
# with the base appResources

my $command_data = {
	%{$resources->{command_data}},
	$WIN_RAYSYS  	=> ['RaySys', 	'The Raynet Discover Protocol'],
	$WIN_SHARK   	=> ['Shark', 	'Shark monitoring preferences'],
	$WIN_SNIFFER 	=> ['Sniffer', 	'tshark based packet sniffer with parsers'],
	$WIN_FILESYS 	=> ['FileSys', 	'Removable Media Fiile System'],
	$WIN_DBNAV	 	=> ['DBNav', 	'Navigation Data'],
	$CMD_DOWNLOAD	=> ['Download',	'Download Selected Items'],
};


# Menus

my $main_menu = [
	'file_menu,&File',
	'view_menu,&View',
];

my $file_menu = [];

# Build our view menu (panes that can be opened)
# on top of the baae class view menu

my $view_menu = [
	$WIN_RAYSYS,
	$WIN_SHARK,
	$WIN_SNIFFER,
	$ID_SEPARATOR,
	$WIN_FILESYS,
	$WIN_DBNAV,
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
    pane_data       => $pane_data,
    main_menu       => $main_menu,
    file_menu       => $file_menu,
	view_menu       => $view_menu,
	filesys_context_menu => $filesys_context_menu,

};



1;
