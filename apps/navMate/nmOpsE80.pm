#!/usr/bin/perl
#---------------------------------------------
# nmOpsE80.pm
#---------------------------------------------
# E80-side context-menu operations for navMate.
# Continuation of package nmOps (loaded by nmOps.pm).

package nmOps;
use strict;
use warnings;
use Wx qw(:everything);
use Pub::Utils qw(display warning error getAppFrame);
use Pub::WX::Dialogs;
use a_utils;
use nmDialogs;


our $dbg_e80_ops;	# declared in nmOps.pm


#----------------------------------------------------
# E80 low-level helpers
#----------------------------------------------------

sub _e80WPRoutes
	# Returns list of route UUIDs from WPMGR memory that contain $wp_uuid.
	# Excludes $exclude (undef = include all).
{
	my ($wpmgr, $wp_uuid, $exclude) = @_;
	my @routes;
	for my $r_uuid (keys %{$wpmgr->{routes}})
	{
		next if defined $exclude && $r_uuid eq $exclude;
		for my $u (@{$wpmgr->{routes}{$r_uuid}{uuids} // []})
		{
			if ($u eq $wp_uuid) { push @routes, $r_uuid; last; }
		}
	}
	return @routes;
}


sub _e80WPGroup
	# Returns the group UUID that contains $wp_uuid, or undef.
{
	my ($wpmgr, $wp_uuid) = @_;
	my $wp = $wpmgr->{waypoints}{$wp_uuid};
	return undef unless $wp;
	for my $u (@{$wp->{uuids} // []})
	{
		return $u if $wpmgr->{groups}{$u};
	}
	return undef;
}


sub _treeFindItem
{
	my ($tree, $item, $target) = @_;
	return undef unless $item && $item->IsOk();
	my $d = $tree->GetItemData($item);
	return $item if $d && $d->GetData() == $target;
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		my $found = _treeFindItem($tree, $child, $target);
		return $found if $found;
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
	return undef;
}


sub _treeChildNodes
{
	my ($tree, $node) = @_;
	my $item = _treeFindItem($tree, $tree->GetRootItem(), $node);
	return [] unless $item && $item->IsOk();
	my @children;
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		my $d = $tree->GetItemData($child);
		push @children, $d->GetData() if $d;
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
	return \@children;
}


sub _openE80Progress
{
	my ($title, $total) = @_;
	return undef unless $total;
	display(0,0,"nmOps::_openE80Progress '$title' total=$total");
	my $progress = Pub::WX::ProgressDialog::newProgressData($total);
	$progress->{active} = 1;
	Pub::WX::ProgressDialog->new(getAppFrame(), $title, 1, $progress);
	return $progress;
}


sub _e80CountWPDeleteOps
	# Count E80 ops needed to fully delete $wp_uuid:
	# one mod_route per route (excluding $skip_route), optional mod_group, one del_wp.
{
	my ($wpmgr, $wp_uuid, $skip_route) = @_;
	return scalar(_e80WPRoutes($wpmgr, $wp_uuid, $skip_route))
	     + (_e80WPGroup($wpmgr, $wp_uuid) ? 1 : 0)
	     + 1;
}


sub _e80DeleteWP
	# Queue direct API calls to fully remove $wp_uuid from E80:
	# modifyRoute for each containing route (excluding $skip_route),
	# modifyGroup if in a group, then deleteWaypoint.
{
	my ($wpmgr, $wp_uuid, $skip_route, $progress) = @_;
	for my $r_uuid (_e80WPRoutes($wpmgr, $wp_uuid, $skip_route))
	{
		my $route = $wpmgr->{routes}{$r_uuid};
		my @new   = grep { $_ ne $wp_uuid } @{$route->{uuids} // []};
		$wpmgr->modifyRoute({uuid => $r_uuid, waypoints => \@new, progress => $progress});
	}
	my $g = _e80WPGroup($wpmgr, $wp_uuid);
	if ($g)
	{
		my $group = $wpmgr->{groups}{$g};
		my @new   = grep { $_ ne $wp_uuid } @{$group->{uuids} // []};
		$wpmgr->modifyGroup({uuid => $g, members => \@new, progress => $progress});
	}
	$wpmgr->deleteWaypoint($wp_uuid, $progress, 1);
}


#----------------------------------------------------
# New items
#----------------------------------------------------

sub _newE80Group
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "New Group", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $data = nmDialogs::showNewGroup($tree);
	return unless defined $data;

	my $uuid = _newNavUUID();
	return unless $uuid;

	$wpmgr->createGroup({ name => $data->{name}, uuid => $uuid, comment => $data->{comment}, members => [] });
}


sub _newE80Waypoint
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "New Waypoint", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $data = nmDialogs::showNewWaypoint($tree);
	return unless defined $data;

	my $lat = parseLatLon($data->{lat});
	my $lon = parseLatLon($data->{lon});
	unless (defined $lat && defined $lon)
	{
		Wx::MessageBox(
			"Could not parse Latitude or Longitude.\n" .
			"Use decimal degrees (9.3617 N) or degrees and minutes (9 21.702 N).",
			"New Waypoint", wxOK | wxICON_WARNING, $tree);
		return;
	}

	my $node_type  = $node->{type} // '';
	my $group_uuid =
		($node_type eq 'group')    ? $node->{uuid}       :
		($node_type eq 'waypoint') ? $node->{group_uuid} : undef;

	my $uuid = _newNavUUID();
	return unless $uuid;

	$wpmgr->createWaypoint({
		name    => $data->{name},
		uuid    => $uuid,
		lat     => $lat,
		lon     => $lon,
		sym     => ($data->{sym} // 0) + 0,
		ts      => time(),
		comment => $data->{comment} // '',
	});
	if ($group_uuid)
	{
		my $group = $wpmgr->{groups}{$group_uuid};
		if ($group)
		{
			my @new = (@{$group->{uuids} // []}, $uuid);
			$wpmgr->modifyGroup({uuid => $group_uuid, members => \@new});
		}
	}
}


sub _newE80Route
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "New Route", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $data = nmDialogs::showNewRoute($tree);
	return unless defined $data;

	my $uuid = _newNavUUID();
	return unless $uuid;

	$wpmgr->createRoute({
		name      => $data->{name},
		uuid      => $uuid,
		comment   => $data->{comment},
		color     => _parseColor($data->{color}),
		waypoints => [],
	});
}


#----------------------------------------------------
# Remove / Delete
#----------------------------------------------------

sub _removeE80RoutePoint
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Remove RoutePoint", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $wp         = $node->{data};
	my $name       = $wp ? ($wp->{name} // $node->{uuid}) : $node->{uuid};
	my $route_uuid = $node->{route_uuid};
	my $route      = $wpmgr->{routes}{$route_uuid};
	my $route_name = $route ? ($route->{name} // $route_uuid) : $route_uuid;

	my $rc = Wx::MessageBox("Remove '$name' from route '$route_name'?", "Remove RoutePoint",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;

	my @new_uuids = grep { $_ ne $node->{uuid} } @{$route->{uuids} // []};
	$wpmgr->modifyRoute({uuid => $route_uuid, waypoints => \@new_uuids});
}


sub _deleteE80Waypoint
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Waypoint", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $uuid = $node->{uuid};
	my $name = $node->{data}{name};

	my $rc = Wx::MessageBox("Delete waypoint '$name' from E80?", "Confirm Delete",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;

	$wpmgr->deleteWaypoint($uuid);
}


sub _deleteE80Track
{
	my ($node, $tree) = @_;

	my $track = _track();
	unless ($track)
	{
		Wx::MessageBox("E80 not connected.", "Delete Track", wxOK | wxICON_WARNING, $tree);
		return;
	}

	my $uuid    = $node->{uuid};
	my $name    = $node->{data}{name} // $uuid;
	my $pts     = $node->{data}{cnt1} // 0;
	my $pts_str = $pts ? " ($pts points)" : '';

	my $rc = Wx::MessageBox("Delete track '$name'$pts_str from E80?", "Confirm Delete",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;

	$track->queueTRACKCommand(
		$apps::raymarine::NET::d_TRACK::API_GENERAL_CMD,
		$uuid, 'erase');
}


sub _deleteE80Group
{
	my ($node, $tree) = @_;

	if (($node->{type} // '') eq 'my_waypoints')
	{
		Wx::MessageBox("'My Waypoints' is synthesized and cannot be deleted.",
			"Delete Group", wxOK | wxICON_INFORMATION, $tree);
		return;
	}

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Group", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $uuid = $node->{uuid};
	my $name = $node->{data}{name};
	my $n    = scalar @{$node->{data}{uuids} // []};

	my $msg = $n > 0
		? "Delete group '$name' from E80? Its $n member(s) will remain in My Waypoints. Cannot be undone."
		: "Delete group '$name' from E80? Cannot be undone.";
	my $rc = Wx::MessageBox($msg, "Delete Group",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;

	my $progress = _openE80Progress("Delete Group", 1 + $n);
	$progress->{_track_get_items} = 1;
	$wpmgr->deleteGroup($uuid, $progress);
}


sub _deleteE80Route
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Route", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $uuid = $node->{uuid};
	my $name = $node->{data}{name};
	my $n    = scalar @{$node->{data}{uuids} // []};

	my $msg = $n > 0
		? "Delete route '$name' from E80? Its $n waypoint(s) will remain. Cannot be undone."
		: "Delete route '$name' from E80? Cannot be undone.";
	my $rc = Wx::MessageBox($msg, "Delete Route",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;

	my $progress = _openE80Progress("Delete Route", 1 + $n);
	$progress->{_track_get_items} = 1;
	$wpmgr->deleteRoute($uuid, $progress);
}


sub _deleteE80WaypointAndRPs
{
	my ($node, $tree) = @_;
	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Waypoint + RoutePoints",
			wxOK | wxICON_ERROR, $tree);
		return;
	}
	my $uuid = $node->{uuid};
	my $name = $node->{data}{name};
	my $nr   = scalar _e80WPRoutes($wpmgr, $uuid);
	my $msg  = $nr > 0
		? "Delete waypoint '$name' from E80 and remove it from $nr route(s)? Cannot be undone."
		: "Delete waypoint '$name' from E80? Cannot be undone.";
	my $rc = Wx::MessageBox($msg, "Delete Waypoint + RoutePoints",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;
	my $total = _e80CountWPDeleteOps($wpmgr, $uuid, undef);
	my $progress = _openE80Progress("Delete Waypoint + RoutePoints", $total);
	_e80DeleteWP($wpmgr, $uuid, undef, $progress);
}


sub _deleteE80RouteAndWPs
{
	my ($node, $tree) = @_;
	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Route + Waypoints",
			wxOK | wxICON_ERROR, $tree);
		return;
	}
	my $uuid       = $node->{uuid};
	my $name       = $node->{data}{name};
	my $all_wps    = $node->{data}{uuids} // [];
	my $n          = scalar @$all_wps;
	my $cross_refs = scalar grep { _e80WPRoutes($wpmgr, $_, $uuid) } @$all_wps;
	my $msg;
	if ($n == 0)
	{
		$msg = "Delete route '$name' from E80? Cannot be undone.";
	}
	elsif ($cross_refs > 0)
	{
		$msg = "Delete route '$name' and its $n waypoint(s) from E80? " .
		       "($cross_refs also appear in other routes and will be removed from them.) Cannot be undone.";
	}
	else
	{
		$msg = "Delete route '$name' and its $n waypoint(s) from E80? Cannot be undone.";
	}
	my $rc = Wx::MessageBox($msg, "Delete Route + Waypoints",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;
	display($dbg_e80_ops,0,"nmOps::_deleteE80RouteAndWPs '$name' n=$n cross_refs=$cross_refs");
	my $total = 1;
	$total += _e80CountWPDeleteOps($wpmgr, $_, $uuid) for @$all_wps;
	display($dbg_e80_ops+1,0,"nmOps::_deleteE80RouteAndWPs total ops=$total");
	my $progress = _openE80Progress("Delete Route + Waypoints", $total);
	$wpmgr->deleteRoute($uuid, $progress);
	_e80DeleteWP($wpmgr, $_, $uuid, $progress) for @$all_wps;
}


sub _deleteE80GroupAndWPs
{
	my ($node, $tree) = @_;
	if (($node->{type} // '') eq 'my_waypoints')
	{
		my $wpmgr = _wpmgr();
		unless ($wpmgr)
		{
			Wx::MessageBox("WPMGR not connected.", "Delete My Waypoints",
				wxOK | wxICON_ERROR, $tree);
			return;
		}
		my @members = map { $_->{uuid} } @{_treeChildNodes($tree, $node)};
		unless (@members)
		{
			Wx::MessageBox("My Waypoints is empty.", "Delete My Waypoints",
				wxOK | wxICON_INFORMATION, $tree);
			return;
		}
		if (grep { _e80WPRoutes($wpmgr, $_) } @members)
		{
			Wx::MessageBox(
				"My Waypoints has waypoints in routes — use 'Delete My Waypoints + RoutePoints'.",
				"Delete My Waypoints", wxOK | wxICON_WARNING, $tree);
			return;
		}
		my $n  = scalar @members;
		my $rc = Wx::MessageBox(
			"Delete all $n ungrouped waypoint(s) from E80? Cannot be undone.",
			"Delete My Waypoints", wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
		return unless $rc == wxYES;
		my $progress = _openE80Progress("Delete My Waypoints", scalar @members);
		$wpmgr->deleteWaypoint($_, $progress, 1) for @members;
		return;
	}
	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Group + Waypoints",
			wxOK | wxICON_ERROR, $tree);
		return;
	}
	my $uuid    = $node->{uuid};
	my $name    = $node->{data}{name};
	my $members = $node->{data}{uuids} // [];
	my $in_route = 0;
	for my $wp_uuid (@$members)
	{
		if (_e80WPRoutes($wpmgr, $wp_uuid)) { $in_route = 1; last; }
	}
	if ($in_route)
	{
		Wx::MessageBox(
			"Group '$name' has waypoints used in routes — use 'Delete Group + Waypoints + RoutePoints'.",
			"Delete Group + Waypoints", wxOK | wxICON_WARNING, $tree);
		return;
	}
	my $n   = scalar @$members;
	my $msg = $n > 0
		? "Delete group '$name' and its $n waypoint(s) from E80? Cannot be undone."
		: "Delete group '$name' from E80? Cannot be undone.";
	my $rc = Wx::MessageBox($msg, "Delete Group + Waypoints",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;
	display($dbg_e80_ops,0,"nmOps::_deleteE80GroupAndWPs '$name' n=$n");
	my $total = 2 * scalar(@$members) + 1;
	my $progress = _openE80Progress("Delete Group + Waypoints", $total);
	for my $wp_uuid (@$members)
	{
		my $group = $wpmgr->{groups}{$uuid};
		my @new   = grep { $_ ne $wp_uuid } @{$group->{uuids} // []};
		$wpmgr->modifyGroup({uuid => $uuid, members => \@new, progress => $progress});
		$wpmgr->deleteWaypoint($wp_uuid, $progress, 1);
	}
	$wpmgr->deleteGroup($uuid, $progress);
}


sub _deleteE80GroupNuclear
{
	my ($node, $tree) = @_;
	if (($node->{type} // '') eq 'my_waypoints')
	{
		my $wpmgr = _wpmgr();
		unless ($wpmgr)
		{
			Wx::MessageBox("WPMGR not connected.", "Delete My Waypoints + RoutePoints",
				wxOK | wxICON_ERROR, $tree);
			return;
		}
		my @members = map { $_->{uuid} } @{_treeChildNodes($tree, $node)};
		unless (@members)
		{
			Wx::MessageBox("My Waypoints is empty.", "Delete My Waypoints + RoutePoints",
				wxOK | wxICON_INFORMATION, $tree);
			return;
		}
		my $n  = scalar @members;
		my $rc = Wx::MessageBox(
			"Delete all $n ungrouped waypoint(s) from E80, removing from any routes? Cannot be undone.",
			"Delete My Waypoints + RoutePoints",
			wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
		return unless $rc == wxYES;
		my $total = 0;
		$total += _e80CountWPDeleteOps($wpmgr, $_, undef) for @members;
		my $progress = _openE80Progress("Delete My Waypoints + RoutePoints", $total);
		_e80DeleteWP($wpmgr, $_, undef, $progress) for @members;
		return;
	}
	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Group + Waypoints + RoutePoints",
			wxOK | wxICON_ERROR, $tree);
		return;
	}
	my $uuid    = $node->{uuid};
	my $name    = $node->{data}{name};
	my $members = $node->{data}{uuids} // [];
	my $n       = scalar @$members;
	my $msg = $n > 0
		? "Delete group '$name' and its $n waypoint(s) from E80, removing them from any routes? Cannot be undone."
		: "Delete group '$name' from E80? Cannot be undone.";
	my $rc = Wx::MessageBox($msg, "Delete Group + Waypoints + RoutePoints",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;
	display($dbg_e80_ops,0,"nmOps::_deleteE80GroupNuclear '$name' n=$n");
	my $total = 1;
	$total += _e80CountWPDeleteOps($wpmgr, $_, undef) for @$members;
	display($dbg_e80_ops+1,0,"nmOps::_deleteE80GroupNuclear total ops=$total");
	my $progress = _openE80Progress("Delete Group + Waypoints + RoutePoints", $total);
	_e80DeleteWP($wpmgr, $_, undef, $progress) for @$members;
	$wpmgr->deleteGroup($uuid, $progress);
}


#----------------------------------------------------
# Paste
#----------------------------------------------------

sub _pasteWaypointToE80
{
	my ($node, $tree, $item) = @_;

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Paste Waypoint", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $wp        = $item->{data};
	my $uuid      = $item->{uuid};
	my $node_type = $node->{type} // '';

	my $group_uuid =
		($node_type eq 'group')       ? $node->{uuid}       :
		($node_type eq 'waypoint')    ? $node->{group_uuid} :
		($node_type eq 'route_point') ? $node->{group_uuid} : undef;

	$wpmgr->createWaypoint({
		name    => $wp->{name}    // '',
		uuid    => $uuid,
		lat     => $wp->{lat},
		lon     => $wp->{lon},
		sym     => $wp->{sym}     // 0,
		ts      => $wp->{created_ts} // $wp->{ts} // 0,
		comment => $wp->{comment} // '',
		depth   => $wp->{depth_cm} // $wp->{depth} // 0,
	});
	if ($group_uuid)
	{
		my $group = $wpmgr->{groups}{$group_uuid};
		if ($group)
		{
			my @new = (@{$group->{uuids} // []}, $uuid);
			$wpmgr->modifyGroup({uuid => $group_uuid, members => \@new});
		}
	}
}


1;
