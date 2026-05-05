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
	return undef if !$wp;
	for my $u (@{$wp->{uuids} // []})
	{
		return $u if $wpmgr->{groups}{$u};
	}
	return undef;
}


sub _treeFindItem
{
	my ($tree, $item, $target) = @_;
	return undef if !($item && $item->IsOk());
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
	return [] if !($item && $item->IsOk());
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


sub _deconflictE80Name
	# Returns a name that won't clash with existing E80 names or $pending_names.
	# $hash_name: 'waypoints' (default), 'groups', or 'routes' — which WPMGR hash to check.
	# Appends " (2)", " (3)", ... until the name is unique. Logs any rename.
	# Always records the chosen name in $pending_names if provided.
{
	my ($wpmgr, $name, $pending_names, $hash_name) = @_;
	$hash_name    //= 'waypoints';
	$pending_names //= {};
	my %existing;
	$existing{lc($_->{name} // '')} = 1 for values %{$wpmgr->{$hash_name} // {}};
	my $base      = $name // '';
	my $candidate = $base;
	my $n         = 2;
	while ($existing{lc($candidate)} || $pending_names->{lc($candidate)})
	{
		$candidate = "$base ($n)";
		$n++;
	}
	if ($candidate ne $base)
	{
		display(0, 0, "_deconflictE80Name: renamed '$base' to '$candidate'");
	}
	$pending_names->{lc($candidate)} = 1;
	return $candidate;
}


sub _openE80Progress
{
	my ($title, $total, $opts) = @_;
	return undef if !$total;
	display(0,0,"nmOps::_openE80Progress '$title' total=$total");
	my $progress = Pub::WX::ProgressDialog::newProgressData($total);
	$progress->{label}        = $title;
	$progress->{cancel_label} = $opts->{cancel_label} if $opts && $opts->{cancel_label};
	$progress->{cancel_msg}   = $opts->{cancel_msg}   if $opts && $opts->{cancel_msg};
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

sub _newE80Waypoint
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		error("_newE80Waypoint: WPMGR not connected");
		return;
	}

	my $data = nmDialogs::showNewWaypoint($tree);
	return if !defined($data);

	my $lat = parseLatLon($data->{lat});
	my $lon = parseLatLon($data->{lon});
	if (!(defined $lat && defined $lon))
	{
		okDialog($tree,
			"Could not parse Latitude or Longitude.\n" .
			"Use decimal degrees (9.3617 N) or degrees and minutes (9 21.702 N).",
			"New Waypoint");
		return;
	}

	my $node_type  = $node->{type} // '';
	my $group_uuid =
		($node_type eq 'group')    ? $node->{uuid}       :
		($node_type eq 'waypoint') ? $node->{group_uuid} : undef;

	my $uuid = _newNavUUID();
	return if !$uuid;

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


sub _newE80Group
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		error("_newE80Group: WPMGR not connected");
		return;
	}

	my $data = nmDialogs::showNewGroup($tree);
	return if !defined($data);

	my $uuid = _newNavUUID();
	return if !$uuid;

	$wpmgr->createGroup({ name => $data->{name}, uuid => $uuid, comment => $data->{comment}, members => [] });
}


sub _newE80Route
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		error("_newE80Route: WPMGR not connected");
		return;
	}

	my $data = nmDialogs::showNewRoute($tree);
	return if !defined($data);

	my $uuid = _newNavUUID();
	return if !$uuid;

	$wpmgr->createRoute({
		name      => $data->{name},
		uuid      => $uuid,
		comment   => $data->{comment},
		color     => abgrToE80Index($data->{color}),
		waypoints => [],
	});
}


#----------------------------------------------------
# Remove / Delete
#----------------------------------------------------

sub _deleteE80Waypoints
{
	my ($nodes, $tree) = @_;
	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		error("_deleteE80Waypoints: WPMGR not connected");
		return;
	}
	my $n   = scalar @$nodes;
	my $msg = $n == 1
		? "Delete waypoint '$nodes->[0]{data}{name}' from E80?"
		: "Delete $n waypoints from E80?";
	return if !confirmDialog($tree, $msg, "Confirm Delete");
	$wpmgr->deleteWaypoint($_->{uuid}) for @$nodes;
}


sub _deleteE80Groups
{
	my ($nodes, $tree) = @_;
	if (grep { ($_->{type} // '') eq 'my_waypoints' } @$nodes)
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _deleteE80Groups: my_waypoints node reached CMD_DELETE_GROUP handler");
		return;
	}
	my $wpmgr = _wpmgr();

	my @expanded;
	for my $n (@$nodes)
	{
		if (($n->{type} // '') eq 'header')
		{
			push @expanded, map { { type => 'group', uuid => $_, data => $wpmgr->{groups}{$_} } }
			                sort keys %{$wpmgr->{groups} // {}};
		}
		else { push @expanded, $n; }
	}
	$nodes = \@expanded;
	if (!$wpmgr)
	{
		error("_deleteE80Groups: WPMGR not connected");
		return;
	}
	my $n         = scalar @$nodes;
	my $total_wps = 0;
	$total_wps   += scalar @{$_->{data}{uuids} // []} for @$nodes;
	my $msg;
	if ($n == 1)
	{
		my $wc = scalar @{$nodes->[0]{data}{uuids} // []};
		$msg = $wc > 0
			? "Delete group '$nodes->[0]{data}{name}' from E80? Its $wc member(s) will remain in My Waypoints. Cannot be undone."
			: "Delete group '$nodes->[0]{data}{name}' from E80? Cannot be undone.";
	}
	else
	{
		$msg = $total_wps > 0
			? "Delete $n groups from E80? Their $total_wps member(s) will remain in My Waypoints. Cannot be undone."
			: "Delete $n groups from E80? Cannot be undone.";
	}
	return if !confirmDialog($tree, $msg, "Delete Group");
	my $total_ops = $n + $total_wps;
	my $progress  = _openE80Progress("Delete Group", $total_ops);
	$progress->{_counting_get_items} = 1;
	$wpmgr->deleteGroup($_->{uuid}, $progress) for @$nodes;
}


sub _deleteE80GroupsAndWPs
{
	my ($nodes, $tree) = @_;

	if (grep { ($_->{type} // '') eq 'header' } @$nodes)
	{
		my $wpmgr = _wpmgr();
		my @expanded;
		for my $n (@$nodes)
		{
			if (($n->{type} // '') eq 'header')
			{
				push @expanded, map { { type => 'group', uuid => $_, data => $wpmgr->{groups}{$_} } }
				                sort keys %{$wpmgr->{groups} // {}};
			}
			else { push @expanded, $n; }
		}
		$nodes = \@expanded;
	}

	my @mw   = grep { ($_->{type} // '') eq 'my_waypoints' } @$nodes;
	my @grps = grep { ($_->{type} // '') ne 'my_waypoints' } @$nodes;

	if (@mw && @grps)
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _deleteE80GroupsAndWPs: mixed my_waypoints and named groups in selection");
		return;
	}

	if (@mw)
	{
		my $wpmgr = _wpmgr();
		if (!$wpmgr)
		{
			error("_deleteE80GroupsAndWPs: WPMGR not connected (my_waypoints path)");
			return;
		}
		my @members = map { $_->{uuid} } @{_treeChildNodes($tree, $mw[0])};
		if (!@members)
		{
			okDialog($tree, "My Waypoints is empty.", "Delete Group + Waypoints");
			return;
		}
		if (grep { _e80WPRoutes($wpmgr, $_) } @members)
		{
			warning(0, 0, "IMPLEMENTATION ERROR: _deleteE80GroupsAndWPs: my_waypoints member in route reached handler");
			return;
		}
		my $n = scalar @members;
		return if !confirmDialog($tree,
			"Delete all $n ungrouped waypoint(s) from E80? Cannot be undone.",
			"Delete Group + Waypoints");
		my $progress = _openE80Progress("Delete Group + Waypoints", scalar @members);
		$wpmgr->deleteWaypoint($_, $progress, 1) for @members;
		return;
	}

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		error("_deleteE80GroupsAndWPs: WPMGR not connected");
		return;
	}
	for my $node (@grps)
	{
		for my $wp_uuid (@{$node->{data}{uuids} // []})
		{
			if (_e80WPRoutes($wpmgr, $wp_uuid))
			{
				warning(0, 0, "IMPLEMENTATION ERROR: _deleteE80GroupsAndWPs: group '$node->{data}{name}' member in route reached handler");
				return;
			}
		}
	}
	my $n         = scalar @grps;
	my $total_wps = 0;
	$total_wps   += scalar @{$_->{data}{uuids} // []} for @grps;
	my $msg;
	if ($n == 1)
	{
		$msg = $total_wps > 0
			? "Delete group '$grps[0]{data}{name}' and its $total_wps waypoint(s) from E80? Cannot be undone."
			: "Delete group '$grps[0]{data}{name}' from E80? Cannot be undone.";
	}
	else
	{
		$msg = $total_wps > 0
			? "Delete $n groups and their $total_wps waypoint(s) from E80? Cannot be undone."
			: "Delete $n groups from E80? Cannot be undone.";
	}
	return if !confirmDialog($tree, $msg, "Delete Groups + Waypoints");
	display($dbg_e80_ops,0,"nmOps::_deleteE80GroupsAndWPs n=$n total_wps=$total_wps");
	my $total_ops = (2 * $total_wps) + $n;
	my $progress  = _openE80Progress("Delete Groups + Waypoints", $total_ops);
	$progress->{_counting_get_items} = 1;
	$wpmgr->deleteGroup($_->{uuid}, $progress) for @grps;
	for my $node (@grps)
	{
		$wpmgr->deleteWaypoint($_, $progress, 1) for @{$node->{data}{uuids} // []};
	}
}


sub _removeE80RoutePoint
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		error("_removeE80RoutePoint: WPMGR not connected");
		return;
	}

	my $wp         = $node->{data};
	my $name       = $wp ? ($wp->{name} // $node->{uuid}) : $node->{uuid};
	my $route_uuid = $node->{route_uuid};
	my $route      = $wpmgr->{routes}{$route_uuid};
	my $route_name = $route ? ($route->{name} // $route_uuid) : $route_uuid;

	return if !confirmDialog($tree, "Remove '$name' from route '$route_name'?", "Remove RoutePoint");

	my @new_uuids = grep { $_ ne $node->{uuid} } @{$route->{uuids} // []};
	$wpmgr->modifyRoute({uuid => $route_uuid, waypoints => \@new_uuids});
}


sub _deleteE80Routes
{
	my ($nodes, $tree) = @_;
	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		error("_deleteE80Routes: WPMGR not connected");
		return;
	}

	my @route_nodes;
	for my $n (@$nodes)
	{
		if (($n->{type} // '') eq 'header')
		{
			push @route_nodes, map { { type => 'route', uuid => $_, data => $wpmgr->{routes}{$_} } }
			                   sort keys %{$wpmgr->{routes}};
		}
		else
		{
			push @route_nodes, $n;
		}
	}
	$nodes = \@route_nodes;

	my $n         = scalar @$nodes;
	my $total_pts = 0;
	$total_pts   += scalar @{($_->{data} // {})->{uuids} // []} for @$nodes;
	my $msg;
	if ($n == 1)
	{
		$msg = $total_pts > 0
			? "Delete route '$nodes->[0]{data}{name}' from E80? Its $total_pts waypoint(s) will remain. Cannot be undone."
			: "Delete route '$nodes->[0]{data}{name}' from E80? Cannot be undone.";
	}
	else
	{
		$msg = "Delete $n routes from E80? Their waypoints will remain. Cannot be undone.";
	}
	return if !confirmDialog($tree, $msg, "Delete Route");
	my $total_ops = $n + $total_pts;
	my $progress  = _openE80Progress("Delete Route", $total_ops);
	$progress->{_counting_get_items} = 1;
	$wpmgr->deleteRoute($_->{uuid}, $progress) for @$nodes;
}


sub _deleteE80Tracks
{
	my ($nodes, $tree) = @_;
	my $track = _track();
	if (!$track)
	{
		error("_deleteE80Tracks: TRACK service not connected");
		return;
	}
	my $n   = scalar @$nodes;
	my $msg = $n == 1
		? "Delete track '$nodes->[0]{data}{name}' from E80?"
		: "Delete $n tracks from E80?";
	return if !confirmDialog($tree, $msg, "Confirm Delete");
	for my $node (@$nodes)
	{
		$track->queueTRACKCommand(
			$apps::raymarine::NET::d_TRACK::API_GENERAL_CMD,
			$node->{uuid}, 'erase');
	}
}


#----------------------------------------------------
# Paste
#----------------------------------------------------

sub _pasteOneWaypointToE80
	# UUID-preserving inner helper for paste-to-E80.
	# Returns: 'created', 'replaced', 'skipped', 'no_change', 'aborted'.
	# $pending_uuids: hashref — UUIDs queued in this pass; avoids double-queue in _pasteAllToE80.
	# $pending_names: hashref — lc(name)=>1 for names already used; avoids E80 dup-name reject.
{
	my ($wpmgr, $tree, $item, $policy_ref, $title, $progress, $pending_uuids, $pending_names) = @_;
	my $wp   = $item->{data};
	my $uuid = $item->{uuid};

	return 'aborted' if $$policy_ref && $$policy_ref eq 'abort';
	return 'aborted' if $progress && $progress->{cancelled};

	if ($pending_uuids && $pending_uuids->{$uuid})
	{
		$progress->{done}++ if $progress;
		return 'no_change';
	}

	my $existing = $wpmgr->{waypoints}{$uuid};

	if (!$existing)
	{
		my $wp_name = defined($pending_names)
			? _deconflictE80Name($wpmgr, $wp->{name}, $pending_names)
			: ($wp->{name} // '');
		$pending_uuids->{$uuid} = 1 if $pending_uuids;
		$wpmgr->createWaypoint({
			name     => $wp_name,
			uuid     => $uuid,
			lat      => $wp->{lat},
			lon      => $wp->{lon},
			sym      => $wp->{sym}     // 0,
			ts       => $wp->{created_ts} // $wp->{ts} // time(),
			comment  => $wp->{comment} // '',
			depth    => $wp->{depth_cm} // $wp->{depth} // 0,
			progress => $progress,
		});
		return 'created';
	}

	my $diff = _wpFieldsDiffer($existing, $wp, 'e80');
	if (!$diff)
	{
		$progress->{done}++ if $progress;
		return 'no_change';
	}
	display($dbg_e80_ops, 2, "conflict wp '${\($wp->{name}//$uuid)}': $diff");

	my $action;
	if ($$policy_ref && $$policy_ref eq 'replace_all')
	{
		$action = 'replace';
	}
	elsif ($$policy_ref && $$policy_ref eq 'skip_all')
	{
		$action = 'skip';
	}
	else
	{
		$action = _resolveConflict($tree, $title, $wp->{name} // $uuid, $diff);
		$$policy_ref = $action if $action eq 'replace_all' || $action eq 'skip_all' || $action eq 'abort';
	}

	if ($action eq 'abort')
	{
		$progress->{cancelled} = 1 if $progress;
		return 'aborted';
	}

	if ($action eq 'replace' || $action eq 'replace_all')
	{
		$wpmgr->modifyWaypoint({
			uuid     => $uuid,
			name     => $wp->{name}    // '',
			lat      => $wp->{lat},
			lon      => $wp->{lon},
			sym      => $wp->{sym}     // 0,
			ts       => $wp->{created_ts} // $wp->{ts} // time(),
			comment  => $wp->{comment} // '',
			depth    => $wp->{depth_cm} // $wp->{depth} // 0,
			progress => $progress,
		});
		return 'replaced';
	}

	$progress->{done}++ if $progress;
	return 'skipped';
}


sub _pasteWaypointToE80
{
	my ($node, $tree, $item, $cb, $pending_uuids, $pending_names) = @_;

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		error("_pasteWaypointToE80: WPMGR not connected");
		return;
	}

	my $uuid      = $item->{uuid};
	my $node_type = $node->{type} // '';
	my $group_uuid =
		($node_type eq 'group')       ? $node->{uuid}       :
		($node_type eq 'waypoint')    ? $node->{group_uuid} :
		($node_type eq 'route_point') ? $node->{group_uuid} : undef;

	my $total    = 1 + ($group_uuid ? 1 : 0);
	my $progress = _openE80Progress("Paste Waypoint", $total,
		{cancel_label => 'Abort', cancel_msg => 'Aborted by user'});

	my $policy = undef;
	my $result = _pasteOneWaypointToE80($wpmgr, $tree, $item, \$policy, 'Paste Waypoint', $progress, $pending_uuids, $pending_names);
	return if $result eq 'aborted';

	if ($group_uuid)
	{
		if ($result eq 'created')
		{
			my $group = $wpmgr->{groups}{$group_uuid};
			if ($group)
			{
				my @new = (@{$group->{uuids} // []}, $uuid);
				$wpmgr->modifyGroup({uuid => $group_uuid, members => \@new, progress => $progress});
			}
			else
			{
				$progress->{done}++ if $progress;
			}
		}
		else
		{
			$progress->{done}++ if $progress;
		}
	}

	if ($cb && $cb->{cut} && ($result eq 'created' || $result eq 'replaced'))
	{
		$cb->{source} eq 'database'
			? _cutDatabaseWaypoint($uuid, $tree)
			: _cutE80Waypoint($uuid, $tree);
	}
}


sub _pasteNewWaypointToE80
{
	my ($node, $tree, $item, $cb) = @_;

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		error("_pasteNewWaypointToE80: WPMGR not connected");
		return;
	}

	my $wp        = $item->{data};
	my $node_type = $node->{type} // '';
	my $group_uuid =
		($node_type eq 'group')       ? $node->{uuid}       :
		($node_type eq 'waypoint')    ? $node->{group_uuid} :
		($node_type eq 'route_point') ? $node->{group_uuid} : undef;

	my $total    = 1 + ($group_uuid ? 1 : 0);
	my $progress = _openE80Progress("Paste New Waypoint", $total,
		{cancel_label => 'Abort', cancel_msg => 'Aborted by user'});

	my $new_uuid = _newNavUUID();
	if (!$new_uuid)
	{
		error("_pasteNewWaypointToE80: UUID generation failed");
		return;
	}

	my %pending_names;
	my $wp_name = _deconflictE80Name($wpmgr, $wp->{name}, \%pending_names);
	$wpmgr->createWaypoint({
		name     => $wp_name,
		uuid     => $new_uuid,
		lat      => $wp->{lat},
		lon      => $wp->{lon},
		sym      => $wp->{sym}     // 0,
		ts       => $wp->{created_ts} // $wp->{ts} // time(),
		comment  => $wp->{comment} // '',
		depth    => $wp->{depth_cm} // $wp->{depth} // 0,
		progress => $progress,
	});

	if ($group_uuid && !($progress && $progress->{cancelled}))
	{
		my $group = $wpmgr->{groups}{$group_uuid};
		if ($group)
		{
			my @new = (@{$group->{uuids} // []}, $new_uuid);
			$wpmgr->modifyGroup({uuid => $group_uuid, members => \@new, progress => $progress});
		}
		else
		{
			$progress->{done}++ if $progress;
		}
	}
}


sub _pasteGroupToE80
{
	my ($node, $tree, $item, $cb, $shared_progress, $pending_uuids, $pending_names) = @_;

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		error("_pasteGroupToE80: WPMGR not connected");
		return;
	}

	my $group_uuid = $item->{uuid};
	my $group_data = $item->{data};
	my $members    = $item->{members} // [];
	display($dbg_e80_ops, 0, "_pasteGroupToE80: '${\($group_data->{name}//'')}' wps=" . scalar(@$members));
	my $progress;
	if ($shared_progress)
	{
		$progress = $shared_progress;
		$progress->{label} = $group_data->{name} // 'Paste Group';
	}
	else
	{
		my $total = scalar(@$members) + ($group_uuid ? 1 : 0);
		$progress = _openE80Progress("Paste Group", $total,
			{cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
	}

	my $policy      = undef;
	my $any_skipped = 0;
	my @placed_uuids;
	for my $member (@$members)
	{
		last if $progress && $progress->{cancelled};
		my $result = _pasteOneWaypointToE80($wpmgr, $tree, $member, \$policy, 'Paste Group', $progress, $pending_uuids, $pending_names);
		last if $result eq 'aborted';
		push @placed_uuids, $member->{uuid};
		$any_skipped = 1 if $result eq 'skipped';
		if ($cb->{cut} && $result ne 'skipped' && $result ne 'aborted')
		{
			$cb->{source} eq 'database'
				? _cutDatabaseWaypoint($member->{uuid}, $tree)
				: _cutE80Waypoint($member->{uuid}, $tree);
		}
	}

	my $aborted = ($policy && $policy eq 'abort') || ($progress && $progress->{cancelled});

	if (!$aborted && $group_uuid)
	{
		my $existing_grp = $wpmgr->{groups}{$group_uuid};
		if ($existing_grp)
		{
			my %already   = map { $_ => 1 } @{$existing_grp->{uuids} // []};
			my @additions = grep { !$already{$_} } @placed_uuids;
			if (@additions)
			{
				my @new_members = (@{$existing_grp->{uuids} // []}, @additions);
				$wpmgr->modifyGroup({
					uuid     => $group_uuid,
					members  => \@new_members,
					progress => $progress,
				});
			}
			else
			{
				$progress->{done}++ if $progress;
			}
		}
		else
		{
			$wpmgr->createGroup({
				name     => $group_data->{name}    // '',
				uuid     => $group_uuid,
				comment  => $group_data->{comment} // '',
				members  => \@placed_uuids,
				progress => $progress,
			});
		}
		if ($cb->{cut} && !$any_skipped)
		{
			$cb->{source} eq 'database'
				? _cutDatabaseGroup($group_uuid, $tree)
				: _cutE80Group($group_uuid, $tree);
		}
	}
}


sub _pasteRouteToE80
{
	my ($node, $tree, $item, $cb, $shared_progress, $pending_uuids, $pending_names) = @_;

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		error("_pasteRouteToE80: WPMGR not connected");
		return;
	}

	my $route_uuid = $item->{uuid};
	my $route_data = $item->{data};
	my $members    = $item->{members} // [];
	display($dbg_e80_ops, 0, "_pasteRouteToE80: '${\($route_data->{name}//'')}' wps=" . scalar(@$members));
	my $progress;
	if ($shared_progress)
	{
		$progress = $shared_progress;
		$progress->{label} = $route_data->{name} // 'Paste Route';
	}
	else
	{
		my $total = (2 * scalar(@$members)) + 1;
		$progress = _openE80Progress("Paste Route", $total,
			{cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
	}
	$progress->{_counting_get_items} = 1 if $progress;

	my $policy = undef;
	for my $member (@$members)
	{
		last if $progress && $progress->{cancelled};
		my $result = _pasteOneWaypointToE80($wpmgr, $tree, $member, \$policy, 'Paste Route', $progress, $pending_uuids, $pending_names);
		last if $result eq 'aborted';
		if ($cb->{cut} && $result ne 'skipped' && $result ne 'aborted')
		{
			$cb->{source} eq 'database'
				? _cutDatabaseWaypoint($member->{uuid}, $tree)
				: _cutE80Waypoint($member->{uuid}, $tree);
		}
	}

	my $aborted = ($policy && $policy eq 'abort') || ($progress && $progress->{cancelled});

	unless ($aborted)
	{
		my @wp_uuids = map { $_->{uuid} } @$members;
		if ($wpmgr->{routes}{$route_uuid})
		{
			$wpmgr->modifyRoute({
				uuid      => $route_uuid,
				waypoints => \@wp_uuids,
				progress  => $progress,
			});
		}
		else
		{
			$wpmgr->createRoute({
				name      => $route_data->{name}    // '',
				uuid      => $route_uuid,
				comment   => $route_data->{comment} // '',
				color     => $cb->{source} eq 'database'
					? abgrToE80Index($route_data->{color})
					: ($route_data->{color} // 0),
				waypoints => \@wp_uuids,
				progress  => $progress,
			});
		}
		if ($cb->{cut})
		{
			$cb->{source} eq 'database'
				? _cutDatabaseRoute($route_uuid, $tree)
				: _cutE80Route($route_uuid, $tree);
		}
	}
}


sub _pasteAllToE80
{
	my ($node, $tree, $cb) = @_;
	my @items = @{$cb->{items} // []};

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		error("_pasteAllToE80: WPMGR not connected");
		return;
	}

	my %pending_uuids;
	my %pending_names;

	for my $item (@items)
	{
		my $type = $item->{type} // '';
		if ($type eq 'waypoint')
		{
			_pasteWaypointToE80($node, $tree, $item, $cb, \%pending_uuids, \%pending_names);
		}
		elsif ($type eq 'group')
		{
			_pasteGroupToE80($node, $tree, $item, $cb, undef, \%pending_uuids, \%pending_names);
		}
		elsif ($type eq 'route')
		{
			_pasteRouteToE80($node, $tree, $item, $cb, undef, \%pending_uuids, \%pending_names);
		}
		elsif ($type eq 'track')
		{
			display($dbg_e80_ops, 0, "_pasteAllToE80: skipping track '${\($item->{data}{name}//$item->{uuid})}'");
		}
		else
		{
			warning(0, 0, "_pasteAllToE80: unknown item type '$type'");
		}
	}
}


#----------------------------------------------------
# Paste New
#----------------------------------------------------

sub _pasteNewGroupToE80
{
	my ($node, $tree, $item, $cb, $shared_progress) = @_;

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		error("_pasteNewGroupToE80: WPMGR not connected");
		return;
	}

	my $group_data = $item->{data};
	my $members    = $item->{members} // [];
	my $progress;
	if ($shared_progress)
	{
		$progress = $shared_progress;
		$progress->{label} = $group_data->{name} // 'Paste New Group';
	}
	else
	{
		$progress = _openE80Progress("Paste New Group", scalar(@$members) + 1,
			{cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
	}

	my %pending_names;
	my @new_wp_uuids;
	for my $member (@$members)
	{
		last if $progress && $progress->{cancelled};
		my $wp       = $member->{data};
		my $new_uuid = _newNavUUID();
		if (!$new_uuid)
		{
			error("_pasteNewGroupToE80: UUID generation failed");
			$progress->{error} = 'UUID generation failed' if $progress;
			last;
		}
		my $wp_name = _deconflictE80Name($wpmgr, $wp->{name}, \%pending_names);
		$wpmgr->createWaypoint({
			name     => $wp_name,
			uuid     => $new_uuid,
			lat      => $wp->{lat},
			lon      => $wp->{lon},
			sym      => $wp->{sym}     // 0,
			ts       => $wp->{created_ts} // $wp->{ts} // time(),
			comment  => $wp->{comment} // '',
			depth    => $wp->{depth_cm} // $wp->{depth} // 0,
			progress => $progress,
		});
		push @new_wp_uuids, $new_uuid;
	}

	unless ($progress && ($progress->{cancelled} || $progress->{error}))
	{
		my $new_group_uuid = _newNavUUID();
		if (!$new_group_uuid)
		{
			error("_pasteNewGroupToE80: UUID generation failed for group");
			$progress->{error} = 'UUID generation failed' if $progress;
		}
		else
		{
			my %pending_group_names;
			my $group_name = _deconflictE80Name($wpmgr, $group_data->{name} // '', \%pending_group_names, 'groups');
			$wpmgr->createGroup({
				name     => $group_name,
				uuid     => $new_group_uuid,
				comment  => $group_data->{comment} // '',
				members  => \@new_wp_uuids,
				progress => $progress,
			});
		}
	}
}


sub _pasteNewRouteToE80
{
	my ($node, $tree, $item, $cb, $shared_progress) = @_;

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		error("_pasteNewRouteToE80: WPMGR not connected");
		return;
	}

	my $route_data = $item->{data};
	my $members    = $item->{members} // [];
	my $progress;
	if ($shared_progress)
	{
		$progress = $shared_progress;
		$progress->{label} = $route_data->{name} // 'Paste New Route';
	}
	else
	{
		$progress = _openE80Progress("Paste New Route", scalar(@$members) + 1,
			{cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
	}

	my %pending_names;
	my @new_wp_uuids;
	for my $member (@$members)
	{
		last if $progress && $progress->{cancelled};
		my $wp       = $member->{data};
		my $new_uuid = _newNavUUID();
		if (!$new_uuid)
		{
			error("_pasteNewRouteToE80: UUID generation failed");
			$progress->{error} = 'UUID generation failed' if $progress;
			last;
		}
		my $wp_name = _deconflictE80Name($wpmgr, $wp->{name}, \%pending_names);
		$wpmgr->createWaypoint({
			name     => $wp_name,
			uuid     => $new_uuid,
			lat      => $wp->{lat},
			lon      => $wp->{lon},
			sym      => $wp->{sym}     // 0,
			ts       => $wp->{created_ts} // $wp->{ts} // time(),
			comment  => $wp->{comment} // '',
			depth    => $wp->{depth_cm} // $wp->{depth} // 0,
			progress => $progress,
		});
		push @new_wp_uuids, $new_uuid;
	}

	unless ($progress && ($progress->{cancelled} || $progress->{error}))
	{
		my $new_route_uuid = _newNavUUID();
		if (!$new_route_uuid)
		{
			error("_pasteNewRouteToE80: UUID generation failed for route");
			$progress->{error} = 'UUID generation failed' if $progress;
		}
		else
		{
			my %pending_route_names;
			my $route_name = _deconflictE80Name($wpmgr, $route_data->{name} // '', \%pending_route_names, 'routes');
			$wpmgr->createRoute({
				name      => $route_name,
				uuid      => $new_route_uuid,
				comment   => $route_data->{comment} // '',
				color     => $cb->{source} eq 'database'
					? abgrToE80Index($route_data->{color})
					: ($route_data->{color} // 0),
				waypoints => \@new_wp_uuids,
				progress  => $progress,
			});
		}
	}
}


#----------------------------------------------------
# Cut — source deletion after successful paste
#----------------------------------------------------

sub _cutE80Waypoint
{
	my ($uuid, $tree) = @_;
	my $wpmgr = _wpmgr();
	return if !$wpmgr;
	_e80DeleteWP($wpmgr, $uuid, undef, undef);
}


sub _cutE80Group
{
	my ($uuid, $tree) = @_;
	return if !defined $uuid;
	my $wpmgr = _wpmgr();
	return if !$wpmgr;
	$wpmgr->deleteGroup($uuid);
}


sub _cutE80Route
{
	my ($uuid, $tree) = @_;
	my $wpmgr = _wpmgr();
	return if !$wpmgr;
	$wpmgr->deleteRoute($uuid);
}


sub _cutE80Track
{
	my ($uuid, $tree) = @_;
	my $track = _track();
	return if !$track;
	$track->queueTRACKCommand(
		$apps::raymarine::NET::d_TRACK::API_GENERAL_CMD,
		$uuid, 'erase');
}


1;
