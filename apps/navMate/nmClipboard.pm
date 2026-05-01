#!/usr/bin/perl
#---------------------------------------------
# nmClipboard.pm
#---------------------------------------------
# App-level object clipboard for navMate.
# Encapsulates clipboard state, copy-intent menu generation,
# paste compatibility checking, and command dispatch (stubbed).
#
# Clipboard contents:
#   undef = empty
#   { intent  => 'waypoint'|'waypoints'|'track'|'tracks'|
#                'group'|'groups'|'route'|'routes'|'all',
#     source  => 'browser'|'e80',
#     items   => [ { type=>'waypoint'|'route'|'track'|'group',
#                    uuid=>'...', data=>{...} }, ... ] }

package nmClipboard;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils qw(display warning error getAppFrame);


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(

		$CMD_COPY_WAYPOINT
		$CMD_COPY_WAYPOINTS
		$CMD_COPY_GROUP
		$CMD_COPY_GROUPS
		$CMD_COPY_ROUTE
		$CMD_COPY_ROUTES
		$CMD_COPY_TRACK
		$CMD_COPY_TRACKS
		$CMD_COPY_ALL

		$CMD_CUT_WAYPOINT
		$CMD_CUT_WAYPOINTS
		$CMD_CUT_GROUP
		$CMD_CUT_GROUPS
		$CMD_CUT_ROUTE
		$CMD_CUT_ROUTES
		$CMD_CUT_TRACK
		$CMD_CUT_TRACKS
		$CMD_CUT_ALL

		$CMD_PASTE

		$CMD_DELETE_WAYPOINT
		$CMD_DELETE_GROUP
		$CMD_DELETE_GROUP_WPS
		$CMD_DELETE_ROUTE
		$CMD_REMOVE_ROUTEPOINT
		$CMD_DELETE_TRACK
		$CMD_DELETE_BRANCH
		$CMD_DELETE_ALL

		$CMD_NEW_WAYPOINT
		$CMD_NEW_GROUP
		$CMD_NEW_ROUTE
		$CMD_NEW_BRANCH

		allCopyCmds
		allCutCmds
		allNewCmds
		allDeleteCmds
		getNewMenuItems
		getDeleteMenuItems
		getCopyMenuItems
		getCutMenuItems
		canPaste
		setCopy
		setCut
		clearClipboard
		getClipboardText
		onContextMenuCommand

	);
}


our $CMD_COPY_WAYPOINT  = 10010;
our $CMD_COPY_WAYPOINTS = 10011;
our $CMD_COPY_GROUP     = 10020;
our $CMD_COPY_GROUPS    = 10021;
our $CMD_COPY_ROUTE     = 10030;
our $CMD_COPY_ROUTES    = 10031;
our $CMD_COPY_TRACK     = 10040;
our $CMD_COPY_TRACKS    = 10041;
our $CMD_COPY_ALL       = 10099;

our $CMD_CUT_WAYPOINT  = 10110;
our $CMD_CUT_WAYPOINTS = 10111;
our $CMD_CUT_GROUP     = 10120;
our $CMD_CUT_GROUPS    = 10121;
our $CMD_CUT_ROUTE     = 10130;
our $CMD_CUT_ROUTES    = 10131;
our $CMD_CUT_TRACK     = 10140;
our $CMD_CUT_TRACKS    = 10141;
our $CMD_CUT_ALL       = 10199;

our $CMD_PASTE          = 10300;

our $CMD_DELETE_WAYPOINT   = 10410;
our $CMD_DELETE_GROUP      = 10420;
our $CMD_DELETE_GROUP_WPS  = 10421;
our $CMD_DELETE_ROUTE      = 10430;
our $CMD_REMOVE_ROUTEPOINT = 10431;
our $CMD_DELETE_TRACK      = 10440;
our $CMD_DELETE_BRANCH     = 10450;
our $CMD_DELETE_ALL        = 10499;

our $CMD_NEW_WAYPOINT   = 10510;
our $CMD_NEW_GROUP      = 10520;
our $CMD_NEW_ROUTE      = 10530;
our $CMD_NEW_BRANCH     = 10550;


my %CMD_COPY_INTENT = (
	$CMD_COPY_WAYPOINT  => 'waypoint',
	$CMD_COPY_WAYPOINTS => 'waypoints',
	$CMD_COPY_GROUP     => 'group',
	$CMD_COPY_GROUPS    => 'groups',
	$CMD_COPY_ROUTE     => 'route',
	$CMD_COPY_ROUTES    => 'routes',
	$CMD_COPY_TRACK     => 'track',
	$CMD_COPY_TRACKS    => 'tracks',
	$CMD_COPY_ALL       => 'all',
);

my %CMD_CUT_INTENT = (
	$CMD_CUT_WAYPOINT  => 'waypoint',
	$CMD_CUT_WAYPOINTS => 'waypoints',
	$CMD_CUT_GROUP     => 'group',
	$CMD_CUT_GROUPS    => 'groups',
	$CMD_CUT_ROUTE     => 'route',
	$CMD_CUT_ROUTES    => 'routes',
	$CMD_CUT_TRACK     => 'track',
	$CMD_CUT_TRACKS    => 'tracks',
	$CMD_CUT_ALL       => 'all',
);

my @ALL_COPY_CMDS = (
	$CMD_COPY_WAYPOINT,  $CMD_COPY_WAYPOINTS,
	$CMD_COPY_GROUP,     $CMD_COPY_GROUPS,
	$CMD_COPY_ROUTE,     $CMD_COPY_ROUTES,
	$CMD_COPY_TRACK,     $CMD_COPY_TRACKS,
	$CMD_COPY_ALL,
);

my @ALL_CUT_CMDS = (
	$CMD_CUT_WAYPOINT,  $CMD_CUT_WAYPOINTS,
	$CMD_CUT_GROUP,     $CMD_CUT_GROUPS,
	$CMD_CUT_ROUTE,     $CMD_CUT_ROUTES,
	$CMD_CUT_TRACK,     $CMD_CUT_TRACKS,
	$CMD_CUT_ALL,
);

my @ALL_NEW_CMDS = (
	$CMD_NEW_WAYPOINT, $CMD_NEW_GROUP, $CMD_NEW_ROUTE, $CMD_NEW_BRANCH,
);

my @ALL_DELETE_CMDS = (
	$CMD_DELETE_WAYPOINT,
	$CMD_DELETE_GROUP,
	$CMD_DELETE_GROUP_WPS,
	$CMD_DELETE_ROUTE,
	$CMD_REMOVE_ROUTEPOINT,
	$CMD_DELETE_TRACK,
	$CMD_DELETE_BRANCH,
	$CMD_DELETE_ALL,
);

our $clipboard = undef;


#----------------------------------------------------
# allCopyCmds — for EVT_MENU binding loops
#----------------------------------------------------

sub allCopyCmds   { return @ALL_COPY_CMDS   }
sub allCutCmds    { return @ALL_CUT_CMDS    }
sub allNewCmds    { return @ALL_NEW_CMDS    }
sub allDeleteCmds { return @ALL_DELETE_CMDS }


#----------------------------------------------------
# clipboard state
#----------------------------------------------------

sub setCopy
{
	my ($intent, $source, $items) = @_;
	$clipboard = { intent => $intent, source => $source, items => $items // [] };
	_updateStatusBar();
}

sub setCut
{
	my ($intent, $source, $items) = @_;
	$clipboard = { intent => $intent, source => $source, items => $items // [], cut => 1 };
	_updateStatusBar();
}

sub clearClipboard
{
	$clipboard = undef;
	_updateStatusBar();
}

sub getClipboardText
{
	return '' if !$clipboard;
	my $n    = scalar @{$clipboard->{items}};
	my $src  = $clipboard->{source} eq 'browser' ? 'B' : 'E80';
	my $verb = $clipboard->{cut} ? "cut:$clipboard->{intent}" : $clipboard->{intent};
	return "[$src] $verb ($n)";
}

sub _updateStatusBar
{
	my $frame = getAppFrame();
	return if !($frame && $frame->can('setClipboardStatus'));
	$frame->setClipboardStatus(getClipboardText());
}


#----------------------------------------------------
# _analyzeNodes — categorize a selection
#----------------------------------------------------

sub _analyzeNodes
{
	my ($panel, @nodes) = @_;
	my %c = map { $_ => 0 } qw(wp route track group branch header);
	for my $n (@nodes)
	{
		my $t = $n->{type} // '';
		if ($panel eq 'browser')
		{
			if ($t eq 'route_point')
			{
				$c{wp}++;
			}
			elsif ($t eq 'object')
			{
				my $ot = $n->{data}{obj_type} // '';
				$c{wp}++    if $ot eq 'waypoint';
				$c{route}++ if $ot eq 'route';
				$c{track}++ if $ot eq 'track';
			}
			elsif ($t eq 'collection')
			{
				my $nt = $n->{data}{node_type} // '';
				$c{group}++  if $nt eq 'group';
				$c{branch}++ if $nt ne 'group';
			}
		}
		else  # e80
		{
			$c{wp}++     if $t eq 'waypoint' || $t eq 'route_point';
			$c{route}++  if $t eq 'route';
			$c{track}++  if $t eq 'track';
			$c{group}++  if $t eq 'group' || $t eq 'my_waypoints';
			$c{header}++ if $t eq 'header';
		}
	}
	return %c;
}


#----------------------------------------------------
# getNewMenuItems
#----------------------------------------------------
# Returns list of { id, label } for New-object operations.
# winBrowser always offers all four; winE80 is context-sensitive
# (tracks header and track nodes offer nothing — TRACK API is read-only).

sub getNewMenuItems
{
	my ($panel, $right_click_node) = @_;

	if ($panel eq 'browser')
	{
		return (
			{ id => $CMD_NEW_BRANCH,   label => 'New Branch'   },
			{ id => $CMD_NEW_GROUP,    label => 'New Group'    },
			{ id => $CMD_NEW_ROUTE,    label => 'New Route'    },
			{ id => $CMD_NEW_WAYPOINT, label => 'New Waypoint' },
		);
	}

	# e80 — context-sensitive
	my $t    = $right_click_node->{type} // '';
	my $kind = $right_click_node->{kind} // '';

	return (
		{ id => $CMD_NEW_GROUP,    label => 'New Group'    },
		{ id => $CMD_NEW_WAYPOINT, label => 'New Waypoint' },
	) if $t eq 'header' && $kind eq 'groups';

	return (
		{ id => $CMD_NEW_WAYPOINT, label => 'New Waypoint' },
	) if $t eq 'my_waypoints' || $t eq 'group';

	return (
		{ id => $CMD_NEW_ROUTE, label => 'New Route' },
	) if $t eq 'header' && $kind eq 'routes';

	return (
		{ id => $CMD_NEW_ROUTE,    label => 'New Route'    },
		{ id => $CMD_NEW_WAYPOINT, label => 'New Waypoint' },
	) if $t eq 'route';

	return ();  # tracks header, track nodes — read-only
}


#----------------------------------------------------
# getDeleteMenuItems
#----------------------------------------------------
# Returns list of { id, label } for Delete/Remove operations.
# Context is determined by the right-click node type alone.
# Tracks on E80 are read-only — no delete offered there.

sub getDeleteMenuItems
{
	my ($panel, $right_click_node) = @_;
	my $t  = $right_click_node->{type}  // '';
	my $ot = ($right_click_node->{data} // {})->{obj_type}  // '';
	my $nt = ($right_click_node->{data} // {})->{node_type} // '';

	if ($panel eq 'browser')
	{
		return ({ id => $CMD_REMOVE_ROUTEPOINT, label => 'Remove RoutePoint' })
			if $t eq 'route_point';

		if ($t eq 'object')
		{
			return ({ id => $CMD_DELETE_WAYPOINT, label => 'Delete Waypoint' })
				if $ot eq 'waypoint';

			return ({ id => $CMD_DELETE_ROUTE, label => 'Delete Route' })
				if $ot eq 'route';

			return ({ id => $CMD_DELETE_TRACK, label => 'Delete Track' })
				if $ot eq 'track';
		}

		if ($t eq 'collection')
		{
			return (
				{ id => $CMD_DELETE_GROUP,     label => 'Delete Group'             },
				{ id => $CMD_DELETE_GROUP_WPS, label => 'Delete Group + Waypoints' },
			) if $nt eq 'group';

			return ({ id => $CMD_DELETE_BRANCH, label => 'Delete Branch' });
		}
	}
	else  # e80
	{
		return (
			{ id => $CMD_REMOVE_ROUTEPOINT, label => 'Remove RoutePoint' },
			{ id => $CMD_DELETE_WAYPOINT,   label => 'Delete Waypoint'   },
		) if $t eq 'route_point';

		return ({ id => $CMD_DELETE_WAYPOINT, label => 'Delete Waypoint' })
			if $t eq 'waypoint';

		return ({ id => $CMD_DELETE_ROUTE, label => 'Delete Route' })
			if $t eq 'route';

		return (
			{ id => $CMD_DELETE_GROUP,     label => 'Delete Group'             },
			{ id => $CMD_DELETE_GROUP_WPS, label => 'Delete Group + Waypoints' },
		) if $t eq 'group';

		return ({ id => $CMD_DELETE_GROUP_WPS, label => 'Delete Group + Waypoints' })
			if $t eq 'my_waypoints';

		return ({ id => $CMD_DELETE_TRACK, label => 'Delete Track' })
			if $t eq 'track';
	}

	return ();
}


#----------------------------------------------------
# getCopyMenuItems
#----------------------------------------------------
# Returns list of { id => $CMD_ID, label => '...' }.
# Copy options appear only when applicable to the selection;
# empty list means no copy is available.

sub getCopyMenuItems
{
	my ($panel, @nodes) = @_;
	return () if !@nodes;

	my %c = _analyzeNodes($panel, @nodes);

	my $only_wp    = $c{wp}    && !$c{route} && !$c{track} && !$c{group} && !$c{branch} && !$c{header};
	my $only_route = $c{route} && !$c{wp}    && !$c{track} && !$c{group} && !$c{branch} && !$c{header};
	my $only_track = $c{track} && !$c{wp}    && !$c{route} && !$c{group} && !$c{branch} && !$c{header};
	my $only_group = $c{group} && !$c{wp}    && !$c{route} && !$c{track} && !$c{branch} && !$c{header};

	my @items;

	if ($only_wp)
	{
		push @items, $c{wp} == 1
			? { id => $CMD_COPY_WAYPOINT,  label => 'Copy Waypoint'  }
			: { id => $CMD_COPY_WAYPOINTS, label => 'Copy Waypoints' };
	}
	elsif ($only_track)
	{
		push @items, $c{track} == 1
			? { id => $CMD_COPY_TRACK,  label => 'Copy Track'  }
			: { id => $CMD_COPY_TRACKS, label => 'Copy Tracks' };
	}
	elsif ($only_route)
	{
		push @items, $c{route} == 1
			? { id => $CMD_COPY_ROUTE,  label => 'Copy Route'  }
			: { id => $CMD_COPY_ROUTES, label => 'Copy Routes' };
		push @items, { id => $CMD_COPY_WAYPOINTS, label => 'Copy Waypoints' };
	}
	elsif ($only_group)
	{
		push @items, $c{group} == 1
			? { id => $CMD_COPY_GROUP,  label => 'Copy Group'  }
			: { id => $CMD_COPY_GROUPS, label => 'Copy Groups' };
		push @items, { id => $CMD_COPY_WAYPOINTS, label => 'Copy Waypoints' };
	}
	elsif ($c{branch} || $c{header})
	{
		push @items, { id => $CMD_COPY_ALL,       label => 'Copy All'       };
		push @items, { id => $CMD_COPY_GROUPS,    label => 'Copy Groups'    };
		push @items, { id => $CMD_COPY_ROUTES,    label => 'Copy Routes'    };
		push @items, { id => $CMD_COPY_WAYPOINTS, label => 'Copy Waypoints' };
		push @items, { id => $CMD_COPY_TRACKS,    label => 'Copy Tracks'    };
	}
	elsif ($c{wp})
	{
		push @items, { id => $CMD_COPY_WAYPOINTS, label => 'Copy Waypoints' };
	}

	return @items;
}


#----------------------------------------------------
# getCutMenuItems
#----------------------------------------------------
# Returns list of { id => $CMD_ID, label => '...' }.
# Cut options mirror copy options; empty list means no cut is available.

sub getCutMenuItems
{
	my ($panel, @nodes) = @_;
	return () if !@nodes;

	my %c = _analyzeNodes($panel, @nodes);

	my $only_wp    = $c{wp}    && !$c{route} && !$c{track} && !$c{group} && !$c{branch} && !$c{header};
	my $only_route = $c{route} && !$c{wp}    && !$c{track} && !$c{group} && !$c{branch} && !$c{header};
	my $only_track = $c{track} && !$c{wp}    && !$c{route} && !$c{group} && !$c{branch} && !$c{header};
	my $only_group = $c{group} && !$c{wp}    && !$c{route} && !$c{track} && !$c{branch} && !$c{header};

	my @items;

	if ($only_wp)
	{
		push @items, $c{wp} == 1
			? { id => $CMD_CUT_WAYPOINT,  label => 'Cut Waypoint'  }
			: { id => $CMD_CUT_WAYPOINTS, label => 'Cut Waypoints' };
	}
	elsif ($only_track)
	{
		push @items, $c{track} == 1
			? { id => $CMD_CUT_TRACK,  label => 'Cut Track'  }
			: { id => $CMD_CUT_TRACKS, label => 'Cut Tracks' };
	}
	elsif ($only_route)
	{
		push @items, $c{route} == 1
			? { id => $CMD_CUT_ROUTE,  label => 'Cut Route'  }
			: { id => $CMD_CUT_ROUTES, label => 'Cut Routes' };
		push @items, { id => $CMD_CUT_WAYPOINTS, label => 'Cut Waypoints' };
	}
	elsif ($only_group)
	{
		push @items, $c{group} == 1
			? { id => $CMD_CUT_GROUP,  label => 'Cut Group'  }
			: { id => $CMD_CUT_GROUPS, label => 'Cut Groups' };
		push @items, { id => $CMD_CUT_WAYPOINTS, label => 'Cut Waypoints' };
	}
	elsif ($c{branch} || $c{header})
	{
		push @items, { id => $CMD_CUT_ALL,       label => 'Cut All'       };
		push @items, { id => $CMD_CUT_GROUPS,    label => 'Cut Groups'    };
		push @items, { id => $CMD_CUT_ROUTES,    label => 'Cut Routes'    };
		push @items, { id => $CMD_CUT_WAYPOINTS, label => 'Cut Waypoints' };
		push @items, { id => $CMD_CUT_TRACKS,    label => 'Cut Tracks'    };
	}
	elsif ($c{wp})
	{
		push @items, { id => $CMD_CUT_WAYPOINTS, label => 'Cut Waypoints' };
	}

	return @items;
}


#----------------------------------------------------
# canPaste
#----------------------------------------------------
# Paste is always shown in the menu but enabled only when
# the clipboard intent is compatible with the target node.
# Tracks cannot be pasted to E80 (read-only TRACK API).

sub canPaste
{
	my ($target_node, $panel) = @_;
	return 0 if !$clipboard;

	my $intent = $clipboard->{intent};
	my $t      = $target_node->{type} // '';

	return 0 if $panel eq 'e80' && $intent =~ /^tracks?$/;

	if ($intent =~ /^waypoints?$/)
	{
		return 1 if $panel eq 'browser';
		return 1 if $panel eq 'e80'
			&& $t =~ /^(header|my_waypoints|group|route|waypoint|route_point)$/;
	}
	elsif ($intent =~ /^groups?$/)
	{
		return 1 if $panel eq 'browser' && $t eq 'collection';
		return 1 if $panel eq 'e80'
			&& $t eq 'header' && ($target_node->{kind} // '') eq 'groups';
	}
	elsif ($intent =~ /^routes?$/)
	{
		return 1 if $panel eq 'browser' && $t eq 'collection';
		return 1 if $panel eq 'e80'
			&& $t eq 'header' && ($target_node->{kind} // '') eq 'routes';
	}
	elsif ($intent =~ /^tracks?$/)
	{
		return 1 if $panel eq 'browser' && $t eq 'collection';
	}
	elsif ($intent eq 'all')
	{
		return 1 if $panel eq 'browser' && $t eq 'collection';
	}

	return 0;
}


#----------------------------------------------------
# onContextMenuCommand — STUB
#----------------------------------------------------

sub onContextMenuCommand
{
	my ($cmd_id, $panel, $right_click_node, $tree) = @_;

	if ($cmd_id == $CMD_PASTE)
	{
		nmOps::doPaste($panel, $right_click_node, $tree);
		return;
	}

	if (grep { $cmd_id == $_ } @ALL_DELETE_CMDS)
	{
		nmOps::doDelete($cmd_id, $panel, $right_click_node, $tree);
		return;
	}

	my $copy_intent = $CMD_COPY_INTENT{$cmd_id};
	if ($copy_intent)
	{
		nmOps::doCopy($copy_intent, $panel, $right_click_node, $tree);
		return;
	}

	my $cut_intent = $CMD_CUT_INTENT{$cmd_id};
	if ($cut_intent)
	{
		nmOps::doCut($cut_intent, $panel, $right_click_node, $tree);
		return;
	}

	if (grep { $cmd_id == $_ } @ALL_NEW_CMDS)
	{
		nmOps::doNew($cmd_id, $panel, $right_click_node, $tree);
		return;
	}

	warning(0,0,"nmClipboard: unknown cmd_id=$cmd_id");
}


1;
