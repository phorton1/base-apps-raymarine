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
#     source  => 'database'|'e80',
#     items   => [ { type=>'waypoint'|'route'|'track'|'group',
#                    uuid=>'...', data=>{...} }, ... ] }

package nmClipboard;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils qw(display warning error getAppFrame $UTILS_COLOR_LIGHT_MAGENTA);
use c_db;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(

		$CTX_CMD_COPY_WAYPOINT
		$CTX_CMD_COPY_WAYPOINTS
		$CTX_CMD_COPY_GROUP
		$CTX_CMD_COPY_GROUPS
		$CTX_CMD_COPY_ROUTE
		$CTX_CMD_COPY_ROUTES
		$CTX_CMD_COPY_TRACK
		$CTX_CMD_COPY_TRACKS
		$CTX_CMD_COPY_ALL

		$CTX_CMD_CUT_WAYPOINT
		$CTX_CMD_CUT_WAYPOINTS
		$CTX_CMD_CUT_GROUP
		$CTX_CMD_CUT_GROUPS
		$CTX_CMD_CUT_ROUTE
		$CTX_CMD_CUT_ROUTES
		$CTX_CMD_CUT_TRACK
		$CTX_CMD_CUT_TRACKS
		$CTX_CMD_CUT_ALL

		$CTX_CMD_PASTE
		$CTX_CMD_PASTE_NEW

		$CTX_CMD_DELETE_WAYPOINT
		$CTX_CMD_DELETE_GROUP
		$CTX_CMD_DELETE_GROUP_WPS
		$CTX_CMD_DELETE_ROUTE
		$CTX_CMD_REMOVE_ROUTEPOINT
		$CTX_CMD_DELETE_TRACK
		$CTX_CMD_DELETE_BRANCH
		$CTX_CMD_DELETE_ALL

		$CTX_CMD_NEW_WAYPOINT
		$CTX_CMD_NEW_GROUP
		$CTX_CMD_NEW_ROUTE
		$CTX_CMD_NEW_BRANCH

		allCopyCmds
		allCutCmds
		allNewCmds
		allDeleteCmds
		getNewMenuItems
		getDeleteMenuItems
		getCopyMenuItems
		getCutMenuItems
		canPaste
		canPasteNew
		setCopy
		setCut
		clearClipboard
		getClipboardText
		onContextMenuCommand

	);
}


our $CTX_CMD_COPY_WAYPOINT  = 10010;
our $CTX_CMD_COPY_WAYPOINTS = 10011;
our $CTX_CMD_COPY_GROUP     = 10020;
our $CTX_CMD_COPY_GROUPS    = 10021;
our $CTX_CMD_COPY_ROUTE     = 10030;
our $CTX_CMD_COPY_ROUTES    = 10031;
our $CTX_CMD_COPY_TRACK     = 10040;
our $CTX_CMD_COPY_TRACKS    = 10041;
our $CTX_CMD_COPY_ALL       = 10099;

our $CTX_CMD_CUT_WAYPOINT  = 10110;
our $CTX_CMD_CUT_WAYPOINTS = 10111;
our $CTX_CMD_CUT_GROUP     = 10120;
our $CTX_CMD_CUT_GROUPS    = 10121;
our $CTX_CMD_CUT_ROUTE     = 10130;
our $CTX_CMD_CUT_ROUTES    = 10131;
our $CTX_CMD_CUT_TRACK     = 10140;
our $CTX_CMD_CUT_TRACKS    = 10141;
our $CTX_CMD_CUT_ALL       = 10199;

our $CTX_CMD_PASTE          = 10300;
our $CTX_CMD_PASTE_NEW      = 10301;

our $CTX_CMD_DELETE_WAYPOINT   = 10410;
our $CTX_CMD_DELETE_GROUP      = 10420;
our $CTX_CMD_DELETE_GROUP_WPS  = 10421;
our $CTX_CMD_DELETE_ROUTE      = 10430;
our $CTX_CMD_REMOVE_ROUTEPOINT = 10431;
our $CTX_CMD_DELETE_TRACK      = 10440;
our $CTX_CMD_DELETE_BRANCH     = 10450;
our $CTX_CMD_DELETE_ALL        = 10499;

our $CTX_CMD_NEW_WAYPOINT   = 10510;
our $CTX_CMD_NEW_GROUP      = 10520;
our $CTX_CMD_NEW_ROUTE      = 10530;
our $CTX_CMD_NEW_BRANCH     = 10550;


my %CMD_COPY_INTENT = (
	$CTX_CMD_COPY_WAYPOINT  => 'waypoint',
	$CTX_CMD_COPY_WAYPOINTS => 'waypoints',
	$CTX_CMD_COPY_GROUP     => 'group',
	$CTX_CMD_COPY_GROUPS    => 'groups',
	$CTX_CMD_COPY_ROUTE     => 'route',
	$CTX_CMD_COPY_ROUTES    => 'routes',
	$CTX_CMD_COPY_TRACK     => 'track',
	$CTX_CMD_COPY_TRACKS    => 'tracks',
	$CTX_CMD_COPY_ALL       => 'all',
);

my %CMD_CUT_INTENT = (
	$CTX_CMD_CUT_WAYPOINT  => 'waypoint',
	$CTX_CMD_CUT_WAYPOINTS => 'waypoints',
	$CTX_CMD_CUT_GROUP     => 'group',
	$CTX_CMD_CUT_GROUPS    => 'groups',
	$CTX_CMD_CUT_ROUTE     => 'route',
	$CTX_CMD_CUT_ROUTES    => 'routes',
	$CTX_CMD_CUT_TRACK     => 'track',
	$CTX_CMD_CUT_TRACKS    => 'tracks',
	$CTX_CMD_CUT_ALL       => 'all',
);

my @ALL_COPY_CMDS = (
	$CTX_CMD_COPY_WAYPOINT,  $CTX_CMD_COPY_WAYPOINTS,
	$CTX_CMD_COPY_GROUP,     $CTX_CMD_COPY_GROUPS,
	$CTX_CMD_COPY_ROUTE,     $CTX_CMD_COPY_ROUTES,
	$CTX_CMD_COPY_TRACK,     $CTX_CMD_COPY_TRACKS,
	$CTX_CMD_COPY_ALL,
);

my @ALL_CUT_CMDS = (
	$CTX_CMD_CUT_WAYPOINT,  $CTX_CMD_CUT_WAYPOINTS,
	$CTX_CMD_CUT_GROUP,     $CTX_CMD_CUT_GROUPS,
	$CTX_CMD_CUT_ROUTE,     $CTX_CMD_CUT_ROUTES,
	$CTX_CMD_CUT_TRACK,     $CTX_CMD_CUT_TRACKS,
	$CTX_CMD_CUT_ALL,
);

my @ALL_NEW_CMDS = (
	$CTX_CMD_NEW_WAYPOINT, $CTX_CMD_NEW_GROUP, $CTX_CMD_NEW_ROUTE, $CTX_CMD_NEW_BRANCH,
);

my @ALL_DELETE_CMDS = (
	$CTX_CMD_DELETE_WAYPOINT,
	$CTX_CMD_DELETE_GROUP,
	$CTX_CMD_DELETE_GROUP_WPS,
	$CTX_CMD_DELETE_ROUTE,
	$CTX_CMD_REMOVE_ROUTEPOINT,
	$CTX_CMD_DELETE_TRACK,
	$CTX_CMD_DELETE_BRANCH,
	$CTX_CMD_DELETE_ALL,
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
	my $src  = $clipboard->{source} eq 'database' ? 'DB' : 'E80';
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
	my %c = map { $_ => 0 } qw(wp route track group branch header header_groups header_routes header_tracks);
	for my $n (@nodes)
	{
		my $t = $n->{type} // '';
		if ($panel eq 'database')
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
			if ($t eq 'header')
			{
				my $k = $n->{kind} // '';
				$c{header}++;
				$c{header_groups}++ if $k eq 'groups';
				$c{header_routes}++ if $k eq 'routes';
				$c{header_tracks}++ if $k eq 'tracks';
			}
		}
	}
	return %c;
}


#----------------------------------------------------
# getNewMenuItems
#----------------------------------------------------
# Returns list of { id, label } for New-object operations.
# winDatabase always offers all four; winE80 is context-sensitive
# (tracks header and track nodes offer nothing — TRACK API is read-only).

sub getNewMenuItems
{
	my ($panel, $right_click_node) = @_;

	if ($panel eq 'database')
	{
		return (
			{ id => $CTX_CMD_NEW_BRANCH, label => 'New Branch' },
		) if ($right_click_node->{type} // '') eq 'root';

		return (
			{ id => $CTX_CMD_NEW_BRANCH,   label => 'New Branch'   },
			{ id => $CTX_CMD_NEW_GROUP,    label => 'New Group'    },
			{ id => $CTX_CMD_NEW_ROUTE,    label => 'New Route'    },
			{ id => $CTX_CMD_NEW_WAYPOINT, label => 'New Waypoint' },
		);
	}

	# e80 — context-sensitive
	my $t    = $right_click_node->{type} // '';
	my $kind = $right_click_node->{kind} // '';

	return (
		{ id => $CTX_CMD_NEW_GROUP,    label => 'New Group'    },
		{ id => $CTX_CMD_NEW_WAYPOINT, label => 'New Waypoint' },
	) if $t eq 'header' && $kind eq 'groups';

	return (
		{ id => $CTX_CMD_NEW_WAYPOINT, label => 'New Waypoint' },
	) if $t eq 'my_waypoints' || $t eq 'group';

	return (
		{ id => $CTX_CMD_NEW_ROUTE, label => 'New Route' },
	) if $t eq 'header' && $kind eq 'routes';

	return (
		{ id => $CTX_CMD_NEW_ROUTE,    label => 'New Route'    },
		{ id => $CTX_CMD_NEW_WAYPOINT, label => 'New Waypoint' },
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
	my ($panel, $right_click_node, @nodes) = @_;
	my $n    = @nodes > 0 ? scalar(@nodes) : 1;
	my $t    = $right_click_node->{type}  // '';
	my $kind = $right_click_node->{kind}  // '';
	my $ot   = ($right_click_node->{data} // {})->{obj_type}  // '';
	my $nt   = ($right_click_node->{data} // {})->{node_type} // '';

	if ($panel eq 'database')
	{
		return () if ($t // '') eq 'root';

		return ({ id => $CTX_CMD_REMOVE_ROUTEPOINT, label => 'Remove RoutePoint' })
			if $t eq 'route_point';

		my $dbh = connectDB();

		if ($t eq 'object')
		{
			if ($ot eq 'waypoint')
			{
				my $in_routes = 0;
				if ($dbh)
				{
					for my $node (@nodes)
					{
						my $uuid = ($node->{data} // {})->{uuid};
						next if !$uuid;
						if (getWaypointRouteRefCount($dbh, $uuid) > 0)
						{
							$in_routes = 1;
							last;
						}
					}
				}
				disconnectDB($dbh) if $dbh;
				return () if $in_routes;
				return ({ id => $CTX_CMD_DELETE_WAYPOINT,
				          label => $n > 1 ? 'Delete Waypoints' : 'Delete Waypoint' });
			}
			disconnectDB($dbh) if $dbh;
			return ({ id => $CTX_CMD_DELETE_ROUTE, label => $n > 1 ? 'Delete Routes' : 'Delete Route' })
				if $ot eq 'route';
			return ({ id => $CTX_CMD_DELETE_TRACK, label => $n > 1 ? 'Delete Tracks' : 'Delete Track' })
				if $ot eq 'track';
			return ();
		}

		if ($t eq 'collection')
		{
			if ($nt eq 'group')
			{
				my ($all_empty, $any_in_routes) = (1, 0);
				if ($dbh)
				{
					for my $node (@nodes)
					{
						my $uuid = ($node->{data} // {})->{uuid};
						next if !$uuid;
						my $counts = getCollectionCounts($dbh, $uuid);
						my $total  = $counts->{collections} + $counts->{waypoints}
						           + $counts->{routes}      + $counts->{tracks};
						$all_empty = 0 if $total > 0;
						next if $any_in_routes;
						for my $wp (@{getGroupWaypoints($dbh, $uuid) // []})
						{
							if (getWaypointRouteRefCount($dbh, $wp->{uuid}) > 0)
							{
								$any_in_routes = 1;
								last;
							}
						}
					}
				}
				disconnectDB($dbh) if $dbh;
				my @result;
				push @result, { id => $CTX_CMD_DELETE_GROUP,
				                label => $n > 1 ? 'Delete Groups' : 'Delete Group' }
					if $all_empty;
				push @result, { id => $CTX_CMD_DELETE_GROUP_WPS,
				                label => $n > 1 ? 'Delete Groups + Waypoints' : 'Delete Group + Waypoints' }
					unless $any_in_routes;
				return @result;
			}
			else  # branch
			{
				my $uuid = ($right_click_node->{data} // {})->{uuid};
				my $show  = 1;
				if ($uuid && $dbh)
				{
					my $counts = getCollectionCounts($dbh, $uuid);
					my $total  = $counts->{collections} + $counts->{waypoints}
					           + $counts->{routes}      + $counts->{tracks};
					$show = 0 if $total > 0;
				}
				disconnectDB($dbh) if $dbh;
				return $show ? ({ id => $CTX_CMD_DELETE_BRANCH, label => 'Delete Branch' }) : ();
			}
		}

		disconnectDB($dbh) if $dbh;
	}
	else  # e80
	{
		return (
			{ id => $CTX_CMD_REMOVE_ROUTEPOINT, label => 'Remove RoutePoint' },
			{ id => $CTX_CMD_DELETE_WAYPOINT,   label => 'Delete Waypoint'   },
		) if $t eq 'route_point';

		return ({ id => $CTX_CMD_DELETE_WAYPOINT, label => $n > 1 ? 'Delete Waypoints' : 'Delete Waypoint' })
			if $t eq 'waypoint';

		return ({ id => $CTX_CMD_DELETE_ROUTE, label => $n > 1 ? 'Delete Routes' : 'Delete Route' })
			if $t eq 'route';

		return (
			{ id => $CTX_CMD_DELETE_GROUP,     label => $n > 1 ? 'Delete Groups'             : 'Delete Group'             },
			{ id => $CTX_CMD_DELETE_GROUP_WPS, label => $n > 1 ? 'Delete Groups + Waypoints' : 'Delete Group + Waypoints' },
		) if $t eq 'group';

		return ({ id => $CTX_CMD_DELETE_GROUP_WPS, label => 'Delete Group + Waypoints' })
			if $t eq 'my_waypoints';

		return ({ id => $CTX_CMD_DELETE_TRACK, label => $n > 1 ? 'Delete Tracks' : 'Delete Track' })
			if $t eq 'track';

		return ({ id => $CTX_CMD_DELETE_ROUTE, label => 'Delete Routes' })
			if $t eq 'header' && $kind eq 'routes';

		return (
			{ id => $CTX_CMD_DELETE_GROUP,     label => 'Delete Groups'             },
			{ id => $CTX_CMD_DELETE_GROUP_WPS, label => 'Delete Groups + Waypoints' },
		) if $t eq 'header' && $kind eq 'groups';
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
			? { id => $CTX_CMD_COPY_WAYPOINT,  label => 'Copy Waypoint'  }
			: { id => $CTX_CMD_COPY_WAYPOINTS, label => 'Copy Waypoints' };
	}
	elsif ($only_track && $panel eq 'e80')
	{
		push @items, $c{track} == 1
			? { id => $CTX_CMD_COPY_TRACK,  label => 'Copy Track'  }
			: { id => $CTX_CMD_COPY_TRACKS, label => 'Copy Tracks' };
	}
	elsif ($only_route)
	{
		push @items, $c{route} == 1
			? { id => $CTX_CMD_COPY_ROUTE,  label => 'Copy Route'  }
			: { id => $CTX_CMD_COPY_ROUTES, label => 'Copy Routes' };
		push @items, { id => $CTX_CMD_COPY_WAYPOINTS, label => 'Copy Waypoints' };
	}
	elsif ($only_group)
	{
		push @items, $c{group} == 1
			? { id => $CTX_CMD_COPY_GROUP,  label => 'Copy Group'  }
			: { id => $CTX_CMD_COPY_GROUPS, label => 'Copy Groups' };
		push @items, { id => $CTX_CMD_COPY_WAYPOINTS, label => 'Copy Waypoints' };
	}
	elsif ($c{branch} || $c{header_groups})
	{
		push @items, { id => $CTX_CMD_COPY_ALL,       label => 'Copy All'       };
		push @items, { id => $CTX_CMD_COPY_GROUPS,    label => 'Copy Groups'    };
		push @items, { id => $CTX_CMD_COPY_ROUTES,    label => 'Copy Routes'    };
		push @items, { id => $CTX_CMD_COPY_WAYPOINTS, label => 'Copy Waypoints' };
		push @items, { id => $CTX_CMD_COPY_TRACKS,    label => 'Copy Tracks'    } if $panel eq 'e80';
	}
	elsif ($c{header_routes})
	{
		push @items, { id => $CTX_CMD_COPY_ROUTES,    label => 'Copy Routes'    };
		push @items, { id => $CTX_CMD_COPY_WAYPOINTS, label => 'Copy Waypoints' };
	}
	elsif ($c{header_tracks})
	{
		push @items, { id => $CTX_CMD_COPY_TRACKS, label => 'Copy Tracks' };
	}
	elsif ($c{wp})
	{
		push @items, { id => $CTX_CMD_COPY_WAYPOINTS, label => 'Copy Waypoints' };
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
			? { id => $CTX_CMD_CUT_WAYPOINT,  label => 'Cut Waypoint'  }
			: { id => $CTX_CMD_CUT_WAYPOINTS, label => 'Cut Waypoints' };
	}
	elsif ($only_track)
	{
		push @items, $c{track} == 1
			? { id => $CTX_CMD_CUT_TRACK,  label => 'Cut Track'  }
			: { id => $CTX_CMD_CUT_TRACKS, label => 'Cut Tracks' };
	}
	elsif ($only_route)
	{
		push @items, $c{route} == 1
			? { id => $CTX_CMD_CUT_ROUTE,  label => 'Cut Route'  }
			: { id => $CTX_CMD_CUT_ROUTES, label => 'Cut Routes' };
		push @items, { id => $CTX_CMD_CUT_WAYPOINTS, label => 'Cut Waypoints' };
	}
	elsif ($only_group)
	{
		push @items, $c{group} == 1
			? { id => $CTX_CMD_CUT_GROUP,  label => 'Cut Group'  }
			: { id => $CTX_CMD_CUT_GROUPS, label => 'Cut Groups' };
		push @items, { id => $CTX_CMD_CUT_WAYPOINTS, label => 'Cut Waypoints' };
	}
	elsif ($c{branch} || $c{header_groups})
	{
		push @items, { id => $CTX_CMD_CUT_ALL,       label => 'Cut All'       };
		push @items, { id => $CTX_CMD_CUT_GROUPS,    label => 'Cut Groups'    };
		push @items, { id => $CTX_CMD_CUT_ROUTES,    label => 'Cut Routes'    };
		push @items, { id => $CTX_CMD_CUT_WAYPOINTS, label => 'Cut Waypoints' };
		push @items, { id => $CTX_CMD_CUT_TRACKS,    label => 'Cut Tracks'    };
	}
	elsif ($c{header_routes})
	{
		push @items, { id => $CTX_CMD_CUT_ROUTES,    label => 'Cut Routes'    };
		push @items, { id => $CTX_CMD_CUT_WAYPOINTS, label => 'Cut Waypoints' };
	}
	elsif ($c{header_tracks})
	{
		push @items, { id => $CTX_CMD_CUT_TRACKS, label => 'Cut Tracks' };
	}
	elsif ($c{wp})
	{
		push @items, { id => $CTX_CMD_CUT_WAYPOINTS, label => 'Cut Waypoints' };
	}

	return @items;
}


#----------------------------------------------------
# _canPasteBase / canPaste / canPasteNew
#----------------------------------------------------
# _canPasteBase: pure target-type compatibility, no source guard.
# canPaste:      adds source guard (database->database non-cut = no-op, disabled).
# canPasteNew:   calls _canPasteBase directly so it stays enabled for intra-database
#                copy (Paste New is the correct duplication path there).

sub _canPasteBase
{
	my ($target_node, $panel) = @_;
	my $intent = $clipboard->{intent};
	my $t      = $target_node->{type} // '';

	return 0 if $panel eq 'e80' && $intent =~ /^tracks?$/;

	if ($intent =~ /^waypoints?$/)
	{
		return 1 if $panel eq 'database';
		return 1 if $panel eq 'e80'
			&& ($t =~ /^(my_waypoints|group|route|waypoint|route_point)$/
				|| ($t eq 'header' && ($target_node->{kind} // '') eq 'groups'));
	}
	elsif ($intent =~ /^groups?$/)
	{
		return 1 if $panel eq 'database' && ($t eq 'collection' || $t eq 'root');
		return 1 if $panel eq 'e80'
			&& $t eq 'header' && ($target_node->{kind} // '') eq 'groups';
	}
	elsif ($intent =~ /^routes?$/)
	{
		return 1 if $panel eq 'database' && ($t eq 'collection' || $t eq 'root');
		return 1 if $panel eq 'e80'
			&& $t eq 'header' && ($target_node->{kind} // '') eq 'routes';
	}
	elsif ($intent =~ /^tracks?$/)
	{
		return 1 if $panel eq 'database' && ($t eq 'collection' || $t eq 'root');
	}
	elsif ($intent eq 'all')
	{
		return 1 if $panel eq 'database' && ($t eq 'collection' || $t eq 'root');
		return 1 if $panel eq 'e80' && $t eq 'root';
	}

	return 0;
}


sub canPaste
{
	my ($target_node, $panel) = @_;
	return 0 if !$clipboard;
	return 0 if $clipboard->{source} eq 'database' && $panel eq 'database' && !$clipboard->{cut};
	# D-CT-ALL → DB: only allow for non-root collection targets (move branch contents)
	return 0 if $clipboard->{intent} eq 'all' && $clipboard->{source} eq 'database' && $panel eq 'database'
		     && ($target_node->{type} // '') ne 'collection';
	return _canPasteBase($target_node, $panel);
}


sub canPasteNew
{
	my ($target_node, $panel) = @_;
	return 0 if !$clipboard;
	return 0 if $clipboard->{cut};
	return 0 if $clipboard->{intent} =~ /^tracks?$/;
	# D-CP-ALL → non-root DB collection: allow (duplicate branch contents with fresh UUIDs).
	# All other ALL intent combinations: block.
	if ($clipboard->{intent} eq 'all')
	{
		return 0 if $clipboard->{source} ne 'database' || $panel ne 'database';
		return 0 if ($target_node->{type} // '') ne 'collection';
	}
	return _canPasteBase($target_node, $panel);
}


#----------------------------------------------------
# _cmdLabel / onContextMenuCommand
#----------------------------------------------------

sub _cmdLabel
{
	my ($cmd_id) = @_;
	return "PASTE"           if $cmd_id == $CTX_CMD_PASTE;
	return "PASTE NEW"       if $cmd_id == $CTX_CMD_PASTE_NEW;
	my $ci = $CMD_COPY_INTENT{$cmd_id};
	return "COPY " . uc($ci) if $ci;
	my $xi = $CMD_CUT_INTENT{$cmd_id};
	return "CUT " . uc($xi)  if $xi;
	return "DELETE WAYPOINT"   if $cmd_id == $CTX_CMD_DELETE_WAYPOINT;
	return "DELETE GROUP"      if $cmd_id == $CTX_CMD_DELETE_GROUP;
	return "DELETE GROUP+WPS"  if $cmd_id == $CTX_CMD_DELETE_GROUP_WPS;
	return "DELETE ROUTE"      if $cmd_id == $CTX_CMD_DELETE_ROUTE;
	return "REMOVE ROUTEPOINT" if $cmd_id == $CTX_CMD_REMOVE_ROUTEPOINT;
	return "DELETE TRACK"      if $cmd_id == $CTX_CMD_DELETE_TRACK;
	return "DELETE BRANCH"     if $cmd_id == $CTX_CMD_DELETE_BRANCH;
	return "NEW WAYPOINT"      if $cmd_id == $CTX_CMD_NEW_WAYPOINT;
	return "NEW GROUP"         if $cmd_id == $CTX_CMD_NEW_GROUP;
	return "NEW ROUTE"         if $cmd_id == $CTX_CMD_NEW_ROUTE;
	return "NEW BRANCH"        if $cmd_id == $CTX_CMD_NEW_BRANCH;
	return "CMD_$cmd_id";
}


sub onContextMenuCommand
{
	my ($cmd_id, $panel, $right_click_node, $tree, @nodes) = @_;

	my $label = _cmdLabel($cmd_id);
	display(-1, 0, "===== $label ($panel) STARTED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);

	if ($cmd_id == $CTX_CMD_PASTE)
	{
		nmOps::doPaste($panel, $right_click_node, $tree);
	}
	elsif ($cmd_id == $CTX_CMD_PASTE_NEW)
	{
		nmOps::doPasteNew($panel, $right_click_node, $tree);
	}
	elsif (grep { $cmd_id == $_ } @ALL_DELETE_CMDS)
	{
		nmOps::doDelete($cmd_id, $panel, $right_click_node, $tree, @nodes);
	}
	elsif (my $copy_intent = $CMD_COPY_INTENT{$cmd_id})
	{
		nmOps::doCopy($copy_intent, $panel, $right_click_node, $tree, @nodes);
	}
	elsif (my $cut_intent = $CMD_CUT_INTENT{$cmd_id})
	{
		nmOps::doCut($cut_intent, $panel, $right_click_node, $tree, @nodes);
	}
	elsif (grep { $cmd_id == $_ } @ALL_NEW_CMDS)
	{
		nmOps::doNew($cmd_id, $panel, $right_click_node, $tree);
	}
	else
	{
		warning(0, 0, "nmClipboard: unknown cmd_id=$cmd_id");
	}

	display(-1, 0, "===== $label ($panel) FINISHED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
}


1;
