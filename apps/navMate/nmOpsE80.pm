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
		Wx::MessageBox("WPMGR not connected.", "New Waypoint", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $data = nmDialogs::showNewWaypoint($tree);
	return if !defined($data);

	my $lat = parseLatLon($data->{lat});
	my $lon = parseLatLon($data->{lon});
	if (!(defined $lat && defined $lon))
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
		Wx::MessageBox("WPMGR not connected.", "New Group", wxOK | wxICON_ERROR, $tree);
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
		Wx::MessageBox("WPMGR not connected.", "New Route", wxOK | wxICON_ERROR, $tree);
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
		color     => _parseColor($data->{color}),
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
		Wx::MessageBox("WPMGR not connected.", "Delete Waypoint", wxOK | wxICON_ERROR, $tree);
		return;
	}
	my $n   = scalar @$nodes;
	my $msg = $n == 1
		? "Delete waypoint '$nodes->[0]{data}{name}' from E80?"
		: "Delete $n waypoints from E80?";
	my $rc = Wx::MessageBox($msg, "Confirm Delete",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return if $rc != wxYES;
	$wpmgr->deleteWaypoint($_->{uuid}) for @$nodes;
}


sub _deleteE80Groups
{
	my ($nodes, $tree) = @_;
	if (grep { ($_->{type} // '') eq 'my_waypoints' } @$nodes)
	{
		Wx::MessageBox("'My Waypoints' is synthesized and cannot be deleted.",
			"Delete Group", wxOK | wxICON_INFORMATION, $tree);
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
		Wx::MessageBox("WPMGR not connected.", "Delete Group", wxOK | wxICON_ERROR, $tree);
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
	my $rc = Wx::MessageBox($msg, "Delete Group",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return if $rc != wxYES;
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
		Wx::MessageBox(
			"Cannot mix 'My Waypoints' with named groups — delete them separately.",
			"Delete Groups + Waypoints", wxOK | wxICON_WARNING, $tree);
		return;
	}

	if (@mw)
	{
		my $wpmgr = _wpmgr();
		if (!$wpmgr)
		{
			Wx::MessageBox("WPMGR not connected.", "Delete Group + Waypoints",
				wxOK | wxICON_ERROR, $tree);
			return;
		}
		my @members = map { $_->{uuid} } @{_treeChildNodes($tree, $mw[0])};
		if (!@members)
		{
			Wx::MessageBox("My Waypoints is empty.", "Delete Group + Waypoints",
				wxOK | wxICON_INFORMATION, $tree);
			return;
		}
		if (grep { _e80WPRoutes($wpmgr, $_) } @members)
		{
			Wx::MessageBox(
				"My Waypoints has waypoints in routes — remove them from routes first.",
				"Delete Group + Waypoints", wxOK | wxICON_WARNING, $tree);
			return;
		}
		my $n  = scalar @members;
		my $rc = Wx::MessageBox(
			"Delete all $n ungrouped waypoint(s) from E80? Cannot be undone.",
			"Delete Group + Waypoints", wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
		return if $rc != wxYES;
		my $progress = _openE80Progress("Delete Group + Waypoints", scalar @members);
		$wpmgr->deleteWaypoint($_, $progress, 1) for @members;
		return;
	}

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Groups + Waypoints",
			wxOK | wxICON_ERROR, $tree);
		return;
	}
	for my $node (@grps)
	{
		for my $wp_uuid (@{$node->{data}{uuids} // []})
		{
			if (_e80WPRoutes($wpmgr, $wp_uuid))
			{
				Wx::MessageBox(
					"'$node->{data}{name}' has waypoints in routes — remove them from routes first.",
					"Delete Groups + Waypoints", wxOK | wxICON_WARNING, $tree);
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
	my $rc = Wx::MessageBox($msg, "Delete Groups + Waypoints",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return if $rc != wxYES;
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
	return if $rc != wxYES;

	my @new_uuids = grep { $_ ne $node->{uuid} } @{$route->{uuids} // []};
	$wpmgr->modifyRoute({uuid => $route_uuid, waypoints => \@new_uuids});
}


sub _deleteE80Routes
{
	my ($nodes, $tree) = @_;
	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Route", wxOK | wxICON_ERROR, $tree);
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
	my $rc = Wx::MessageBox($msg, "Delete Route",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return if $rc != wxYES;
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
		Wx::MessageBox("E80 not connected.", "Delete Track", wxOK | wxICON_WARNING, $tree);
		return;
	}
	my $n   = scalar @$nodes;
	my $msg = $n == 1
		? "Delete track '$nodes->[0]{data}{name}' from E80?"
		: "Delete $n tracks from E80?";
	my $rc = Wx::MessageBox($msg, "Confirm Delete",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return if $rc != wxYES;
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
{
	my ($wpmgr, $tree, $item, $policy_ref, $title, $progress) = @_;
	my $wp   = $item->{data};
	my $uuid = $item->{uuid};

	return 'aborted' if $$policy_ref && $$policy_ref eq 'abort';
	return 'aborted' if $progress && $progress->{cancelled};

	my $existing = $wpmgr->{waypoints}{$uuid};

	if (!$existing)
	{
		$wpmgr->createWaypoint({
			name     => $wp->{name}    // '',
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
	my ($node, $tree, $item, $cb) = @_;

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Paste Waypoint", wxOK | wxICON_ERROR, $tree);
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
	my $result = _pasteOneWaypointToE80($wpmgr, $tree, $item, \$policy, 'Paste Waypoint', $progress);
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
		$cb->{source} eq 'browser'
			? _cutBrowserWaypoint($uuid, $tree)
			: _cutE80Waypoint($uuid, $tree);
	}
}


sub _pasteNewWaypointToE80
{
	my ($node, $tree, $item, $cb) = @_;

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Paste New Waypoint", wxOK | wxICON_ERROR, $tree);
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
		error(0,0,"_pasteNewWaypointToE80: UUID generation failed");
		return;
	}

	$wpmgr->createWaypoint({
		name     => $wp->{name}    // '',
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
	my ($node, $tree, $item, $cb, $shared_progress) = @_;

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Paste Group", wxOK | wxICON_ERROR, $tree);
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
		my $result = _pasteOneWaypointToE80($wpmgr, $tree, $member, \$policy, 'Paste Group', $progress);
		last if $result eq 'aborted';
		push @placed_uuids, $member->{uuid};
		$any_skipped = 1 if $result eq 'skipped';
		if ($cb->{cut} && $result ne 'skipped' && $result ne 'aborted')
		{
			$cb->{source} eq 'browser'
				? _cutBrowserWaypoint($member->{uuid}, $tree)
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
			$cb->{source} eq 'browser'
				? _cutBrowserGroup($group_uuid, $tree)
				: _cutE80Group($group_uuid, $tree);
		}
	}
}


sub _pasteRouteToE80
{
	my ($node, $tree, $item, $cb, $shared_progress) = @_;

	my $wpmgr = _wpmgr();
	if (!$wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Paste Route", wxOK | wxICON_ERROR, $tree);
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
		my $result = _pasteOneWaypointToE80($wpmgr, $tree, $member, \$policy, 'Paste Route', $progress);
		last if $result eq 'aborted';
		if ($cb->{cut} && $result ne 'skipped' && $result ne 'aborted')
		{
			$cb->{source} eq 'browser'
				? _cutBrowserWaypoint($member->{uuid}, $tree)
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
				color     => $route_data->{color}   // 0,
				waypoints => \@wp_uuids,
				progress  => $progress,
			});
		}
		if ($cb->{cut})
		{
			$cb->{source} eq 'browser'
				? _cutBrowserRoute($route_uuid, $tree)
				: _cutE80Route($route_uuid, $tree);
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
		Wx::MessageBox("WPMGR not connected.", "Paste New Group", wxOK | wxICON_ERROR, $tree);
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

	my @new_wp_uuids;
	for my $member (@$members)
	{
		last if $progress && $progress->{cancelled};
		my $wp       = $member->{data};
		my $new_uuid = _newNavUUID();
		if (!$new_uuid)
		{
			error(0,0,"_pasteNewGroupToE80: UUID generation failed");
			$progress->{error} = 'UUID generation failed' if $progress;
			last;
		}
		$wpmgr->createWaypoint({
			name     => $wp->{name}    // '',
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
			error(0,0,"_pasteNewGroupToE80: UUID generation failed for group");
			$progress->{error} = 'UUID generation failed' if $progress;
		}
		else
		{
			$wpmgr->createGroup({
				name     => $group_data->{name}    // '',
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
		Wx::MessageBox("WPMGR not connected.", "Paste New Route", wxOK | wxICON_ERROR, $tree);
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
		$progress = _openE80Progress("Paste New Route", (2 * scalar(@$members)) + 1,
			{cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
	}
	$progress->{_counting_get_items} = 1 if $progress;

	my @new_wp_uuids;
	for my $member (@$members)
	{
		last if $progress && $progress->{cancelled};
		my $wp       = $member->{data};
		my $new_uuid = _newNavUUID();
		if (!$new_uuid)
		{
			error(0,0,"_pasteNewRouteToE80: UUID generation failed");
			$progress->{error} = 'UUID generation failed' if $progress;
			last;
		}
		$wpmgr->createWaypoint({
			name     => $wp->{name}    // '',
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
			error(0,0,"_pasteNewRouteToE80: UUID generation failed for route");
			$progress->{error} = 'UUID generation failed' if $progress;
		}
		else
		{
			$wpmgr->createRoute({
				name      => $route_data->{name}    // '',
				uuid      => $new_route_uuid,
				comment   => $route_data->{comment} // '',
				color     => $route_data->{color}   // 0,
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
