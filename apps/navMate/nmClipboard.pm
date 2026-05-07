#!/usr/bin/perl
#---------------------------------------------
# nmClipboard.pm
#---------------------------------------------

package nmClipboard;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils qw(warning error getAppFrame);
use a_defs;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(

		$clipboard

		setCopy
		setCut
		clearClipboard
		getClipboardText

		allCopyCmds
		allCutCmds
		allPasteCmds
		allNewCmds
		allDeleteCmds

		getNewMenuItems
		getDeleteMenuItems
		getCopyMenuItems
		getCutMenuItems
		getPasteMenuItems

	);
}


our $clipboard = undef;

my @ALL_COPY_CMDS  = ($CTX_CMD_COPY);
my @ALL_CUT_CMDS   = ($CTX_CMD_CUT);
my @ALL_PASTE_CMDS = (
	$CTX_CMD_PASTE,
	$CTX_CMD_PASTE_NEW,
	$CTX_CMD_PASTE_BEFORE,
	$CTX_CMD_PASTE_AFTER,
	$CTX_CMD_PASTE_NEW_BEFORE,
	$CTX_CMD_PASTE_NEW_AFTER,
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
);


sub allCopyCmds   { return @ALL_COPY_CMDS   }
sub allCutCmds    { return @ALL_CUT_CMDS    }
sub allPasteCmds  { return @ALL_PASTE_CMDS  }
sub allNewCmds    { return @ALL_NEW_CMDS    }
sub allDeleteCmds { return @ALL_DELETE_CMDS }


#----------------------------------------------------
# clipboard state
#----------------------------------------------------

sub setCopy
{
	my ($source, $items) = @_;
	$clipboard = { source => $source, cut_flag => 0, items => $items // [] };
	_updateStatusBar();
}

sub setCut
{
	my ($source, $items) = @_;
	$clipboard = { source => $source, cut_flag => 1, items => $items // [] };
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
	my $src  = $clipboard->{source};
	my $verb = $clipboard->{cut_flag} ? 'cut' : 'copy';
	return "[$src] $verb ($n)";
}

sub _updateStatusBar
{
	my $frame = getAppFrame();
	return if !($frame && $frame->can('setClipboardStatus'));
	$frame->setClipboardStatus(getClipboardText());
}


#----------------------------------------------------
# getNewMenuItems (SS11)
#----------------------------------------------------

sub getNewMenuItems
{
	my ($panel, $right_click_node) = @_;
	my $t    = $right_click_node->{type} // '';
	my $kind = $right_click_node->{kind} // '';
	my $nt   = ($right_click_node->{data} // {})->{node_type} // '';
	my $ot   = ($right_click_node->{data} // {})->{obj_type}  // '';

	if ($panel eq 'database')
	{
		return (
			{ id => $CTX_CMD_NEW_BRANCH,   label => 'New Branch'   },
			{ id => $CTX_CMD_NEW_GROUP,    label => 'New Group'    },
			{ id => $CTX_CMD_NEW_ROUTE,    label => 'New Route'    },
			{ id => $CTX_CMD_NEW_WAYPOINT, label => 'New Waypoint' },
		) if $t eq 'root' || ($t eq 'collection' && $nt ne 'group');

		return ({ id => $CTX_CMD_NEW_WAYPOINT, label => 'New Waypoint' })
			if ($t eq 'collection' && $nt eq 'group') || ($t eq 'object' && $ot eq 'waypoint');

		return ({ id => $CTX_CMD_NEW_ROUTE, label => 'New Route' })
			if $t eq 'object' && $ot eq 'route';

		return ();  # track, route_point
	}

	# e80
	return (
		{ id => $CTX_CMD_NEW_GROUP,    label => 'New Group'    },
		{ id => $CTX_CMD_NEW_WAYPOINT, label => 'New Waypoint' },
	) if $t eq 'header' && $kind eq 'groups';

	return ({ id => $CTX_CMD_NEW_WAYPOINT, label => 'New Waypoint' })
		if $t eq 'my_waypoints' || $t eq 'group' || $t eq 'waypoint';

	return ({ id => $CTX_CMD_NEW_ROUTE, label => 'New Route' })
		if $t eq 'header' && $kind eq 'routes';

	return ();  # tracks header, track, route, route_point
}


#----------------------------------------------------
# getDeleteMenuItems (SS8)
# Route-ref and branch-safety checks are deferred to pre-flight in nmOps.pm.
#----------------------------------------------------

sub getDeleteMenuItems
{
	my ($panel, $right_click_node, @nodes) = @_;
	my $t    = $right_click_node->{type}  // '';
	my $kind = $right_click_node->{kind}  // '';
	my $nt   = ($right_click_node->{data} // {})->{node_type} // '';
	my $ot   = ($right_click_node->{data} // {})->{obj_type}  // '';
	my $n    = @nodes ? scalar(@nodes) : 1;

	if ($panel eq 'database')
	{
		return () if $t eq 'root';

		return ({ id => $CTX_CMD_REMOVE_ROUTEPOINT, label => 'Delete' })
			if $t eq 'route_point';

		if ($t eq 'object')
		{
			return ({ id => $CTX_CMD_DELETE_WAYPOINT,
			          label => $n > 1 ? 'Delete Waypoints' : 'Delete Waypoint' })
				if $ot eq 'waypoint';
			return ({ id => $CTX_CMD_DELETE_ROUTE,
			          label => $n > 1 ? 'Delete Routes' : 'Delete Route' })
				if $ot eq 'route';
			return ({ id => $CTX_CMD_DELETE_TRACK,
			          label => $n > 1 ? 'Delete Tracks' : 'Delete Track' })
				if $ot eq 'track';
			return ();
		}

		if ($t eq 'collection')
		{
			return (
				{ id => $CTX_CMD_DELETE_GROUP,
				  label => $n > 1 ? 'Delete Groups' : 'Delete Group' },
				{ id => $CTX_CMD_DELETE_GROUP_WPS,
				  label => $n > 1 ? 'Delete Groups + Waypoints' : 'Delete Group + Waypoints' },
			) if $nt eq 'group';

			return ({ id => $CTX_CMD_DELETE_BRANCH, label => 'Delete Branch' });
		}

		return ();
	}

	# e80
	return ({ id => $CTX_CMD_REMOVE_ROUTEPOINT, label => 'Delete' })
		if $t eq 'route_point';

	return ({ id => $CTX_CMD_DELETE_WAYPOINT,
	          label => $n > 1 ? 'Delete Waypoints' : 'Delete Waypoint' })
		if $t eq 'waypoint';

	return ({ id => $CTX_CMD_DELETE_ROUTE,
	          label => $n > 1 ? 'Delete Routes' : 'Delete Route' })
		if $t eq 'route';

	return ({ id => $CTX_CMD_DELETE_TRACK,
	          label => $n > 1 ? 'Delete Tracks' : 'Delete Track' })
		if $t eq 'track';

	if ($t eq 'header' && $kind eq 'routes')
	{
		return ({ id => $CTX_CMD_DELETE_ROUTE, label => 'Delete Routes' });
	}

	if ($t eq 'header' && $kind eq 'tracks')
	{
		return ({ id => $CTX_CMD_DELETE_TRACK, label => 'Delete Tracks' });
	}

	if ($t eq 'header' && $kind eq 'groups')
	{
		return (
			{ id => $CTX_CMD_DELETE_GROUP,     label => 'Delete Groups'             },
			{ id => $CTX_CMD_DELETE_GROUP_WPS, label => 'Delete Groups + Waypoints' },
		);
	}

	return ({ id => $CTX_CMD_DELETE_GROUP_WPS, label => 'Delete Group + Waypoints' })
		if $t eq 'my_waypoints';

	if ($t eq 'group')
	{
		return (
			{ id => $CTX_CMD_DELETE_GROUP,
			  label => $n > 1 ? 'Delete Groups' : 'Delete Group' },
			{ id => $CTX_CMD_DELETE_GROUP_WPS,
			  label => $n > 1 ? 'Delete Groups + Waypoints' : 'Delete Group + Waypoints' },
		);
	}

	return ();
}


#----------------------------------------------------
# getCopyMenuItems / getCutMenuItems (SS9)
# Maximally permissive: offer for any non-empty selection of real nodes.
#----------------------------------------------------

sub getCopyMenuItems
{
	my ($panel, @nodes) = @_;
	return () if !@nodes;
	return () if grep { ($_->{type}//'') eq 'header' || ($_->{type}//'') eq 'root' } @nodes;
	return ({ id => $CTX_CMD_COPY, label => 'Copy' });
}

sub getCutMenuItems
{
	my ($panel, @nodes) = @_;
	return () if !@nodes;
	return () if grep { ($_->{type}//'') eq 'header' || ($_->{type}//'') eq 'root' } @nodes;
	return ({ id => $CTX_CMD_CUT, label => 'Cut' });
}


#----------------------------------------------------
# getPasteMenuItems (SS10)
# Coarse destination check; full validation runs in pre-flight.
#----------------------------------------------------

sub getPasteMenuItems
{
	my ($panel, $right_click_node) = @_;
	return () if !$clipboard;

	my $t    = $right_click_node->{type} // '';
	my $kind = $right_click_node->{kind} // '';
	my $nt   = ($right_click_node->{data} // {})->{node_type} // '';
	my $cut  = $clipboard->{cut_flag};

	if ($panel eq 'e80')
	{
		return () if $t eq 'track' || $t eq 'track_point';
		return () if $t eq 'header' && $kind eq 'tracks';
	}

	# Positional: destinations that support PASTE_BEFORE/AFTER.
	# DB: object nodes, groups (member nodes per SS6.5), and route_points.
	# E80: route_point only (SS10.9).
	my $positional = ($panel eq 'e80')
		? ($t eq 'route_point')
		: ($t eq 'object' || $t eq 'route_point' || ($t eq 'collection' && $nt eq 'group'));

	my @items;
	push @items, { id => $CTX_CMD_PASTE,     label => 'Paste'     };
	push @items, { id => $CTX_CMD_PASTE_NEW, label => 'Paste New' } if !$cut;

	if ($positional)
	{
		push @items, { id => $CTX_CMD_PASTE_BEFORE, label => 'Paste Before' };
		push @items, { id => $CTX_CMD_PASTE_AFTER,  label => 'Paste After'  };
		if (!$cut)
		{
			push @items, { id => $CTX_CMD_PASTE_NEW_BEFORE, label => 'Paste New Before' };
			push @items, { id => $CTX_CMD_PASTE_NEW_AFTER,  label => 'Paste New After'  };
		}
	}

	return @items;
}


1;
