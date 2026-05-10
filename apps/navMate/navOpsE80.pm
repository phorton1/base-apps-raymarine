#!/usr/bin/perl
#---------------------------------------------
# navOpsE80.pm
#---------------------------------------------
# E80-side operations for navMate context menu.
# Continues as package navOps (loaded via require from navOps.pm).

package navOps;
use strict;
use warnings;
use Wx qw(:everything);
use Pub::Utils qw(display warning error getAppFrame);
use Pub::WX::Dialogs;
use n_defs;
use n_utils;
use nmDialogs;


our $dbg_e80_ops;    # declared in navOps.pm


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
    # $hash_name: 'waypoints' (default), 'groups', or 'routes' - which WPMGR hash to check.
    # Appends " (2)", " (3)", ... until the name is unique.
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
    display(0, 0, "navOps::_openE80Progress '$title' total=$total");
    my $progress = Pub::WX::ProgressDialog::newProgressData($total);
    $progress->{label}        = $title;
    $progress->{cancel_label} = $opts->{cancel_label} if $opts && $opts->{cancel_label};
    $progress->{cancel_msg}   = $opts->{cancel_msg}   if $opts && $opts->{cancel_msg};
    $progress->{active} = 1;
    my $dlg = Pub::WX::ProgressDialog->new(getAppFrame(), $title, 1, $progress);
    return undef if !$dlg;
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
# Delete helpers
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
    if (!$wpmgr)
    {
        error("_deleteE80Groups: WPMGR not connected");
        return;
    }
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
    return if !$progress;
    $progress->{_counting_get_items} = 1;
    $wpmgr->deleteGroup($_->{uuid}, $progress) for @$nodes;
}


sub _deleteE80GroupsAndWPs
{
    my ($nodes, $tree) = @_;

    if (grep { ($_->{type} // '') eq 'header' } @$nodes)
    {
        my $wpmgr = _wpmgr();
        if (!$wpmgr)
        {
            error("_deleteE80GroupsAndWPs: WPMGR not connected");
            return;
        }
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
            my $err = "Cannot delete My Waypoints: one or more waypoints are used in a route. "
                    . "Remove them from routes first.";
            $nmDialogs::suppress_confirm ? error($err) : okDialog($tree, $err, "Delete Group + Waypoints");
            return;
        }
        my $n = scalar @members;
        return if !confirmDialog($tree,
            "Delete all $n ungrouped waypoint(s) from E80? Cannot be undone.",
            "Delete Group + Waypoints");
        my $progress = _openE80Progress("Delete Group + Waypoints", scalar @members);
        return if !$progress;
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
                my $err = "Cannot delete group '${\($node->{data}{name} // '?')}' and its waypoints: "
                        . "one or more members are used in a route. "
                        . "Remove them from routes first, or use Delete Group to dissolve the group without deleting its waypoints.";
                $nmDialogs::suppress_confirm ? error($err) : okDialog($tree, $err, "Delete Group + Waypoints");
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
    display($dbg_e80_ops, 0, "navOps::_deleteE80GroupsAndWPs n=$n total_wps=$total_wps");
    my $total_ops = (2 * $total_wps) + $n;
    my $progress  = _openE80Progress("Delete Groups + Waypoints", $total_ops);
    return if !$progress;
    $progress->{_counting_get_items} = 1;
    $wpmgr->deleteGroup($_->{uuid}, $progress) for @grps;
    for my $node (@grps)
    {
        $wpmgr->deleteWaypoint($_, $progress, 1) for @{$node->{data}{uuids} // []};
    }
}


sub _removeE80RoutePoint
{
    my ($nodes, $right_click_node, $tree) = @_;

    my $wpmgr = _wpmgr();
    if (!$wpmgr)
    {
        error("_removeE80RoutePoint: WPMGR not connected");
        return;
    }

    my $route_uuid = $right_click_node->{route_uuid};
    my $route      = $wpmgr->{routes}{$route_uuid};
    my $route_name = $route ? ($route->{name} // $route_uuid) : $route_uuid;

    my $n = scalar @$nodes;
    my $msg;
    if ($n == 1)
    {
        my $wp   = $nodes->[0]{data};
        my $name = $wp ? ($wp->{name} // $nodes->[0]{uuid}) : $nodes->[0]{uuid};
        $msg = "Remove '$name' from route '$route_name'?";
    }
    else
    {
        $msg = "Remove $n waypoints from route '$route_name'?";
    }
    return if !confirmDialog($tree, $msg, "Remove RoutePoint");

    my %to_remove = map { $_->{uuid} => 1 } @$nodes;
    my @new_uuids = grep { !$to_remove{$_} } @{$route->{uuids} // []};
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
    return if !$progress;
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

    my @track_nodes;
    for my $n (@$nodes)
    {
        if (($n->{type} // '') eq 'header')
        {
            push @track_nodes, map { { type => 'track', uuid => $_, data => $track->{tracks}{$_} } }
                               sort keys %{$track->{tracks}};
        }
        else
        {
            push @track_nodes, $n;
        }
    }
    $nodes = \@track_nodes;

    my $n = scalar @$nodes;
    return if !$n;
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


sub _deleteE80
{
    my ($cmd_id, $right_click_node, $tree, @nodes) = @_;
    if    ($cmd_id == $CTX_CMD_DELETE_WAYPOINT)   { _deleteE80Waypoints(\@nodes, $tree); }
    elsif ($cmd_id == $CTX_CMD_DELETE_GROUP)      { _deleteE80Groups(\@nodes, $tree); }
    elsif ($cmd_id == $CTX_CMD_DELETE_GROUP_WPS)  { _deleteE80GroupsAndWPs(\@nodes, $tree); }
    elsif ($cmd_id == $CTX_CMD_DELETE_ROUTE)      { _deleteE80Routes(\@nodes, $tree); }
    elsif ($cmd_id == $CTX_CMD_REMOVE_ROUTEPOINT) { _removeE80RoutePoint(\@nodes, $right_click_node, $tree); }
    elsif ($cmd_id == $CTX_CMD_DELETE_TRACK)      { _deleteE80Tracks(\@nodes, $tree); }
    else  { warning(0, 0, "_deleteE80: unhandled cmd_id=$cmd_id"); }
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
        sym     => 0,
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
# Paste helpers - UUID-preserving (PASTE)
#----------------------------------------------------

sub _pasteOneWaypointToE80
    # UUID-preserving inner helper. Returns: 'created'/'replaced'/'skipped'/'no_change'/'aborted'.
    # $pending_uuids: hashref - UUIDs queued this pass; avoids double-create.
    # $pending_names: hashref - lc(name)=>1 for names already used; avoids E80 dup-name reject.
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
            sym      => 0,
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
            sym      => 0,
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
    # UUID-preserving single-waypoint paste; handles group membership on target node.
{
    my ($node, $tree, $item, $cb, $pending_uuids, $pending_names, $shared_progress) = @_;

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

    my $progress;
    if ($shared_progress)
    {
        $progress = $shared_progress;
    }
    else
    {
        my $total = 1 + ($group_uuid ? 1 : 0);
        $progress = _openE80Progress("Paste Waypoint", $total,
            {cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
        return if !$progress;
    }

    my $policy = undef;
    my $result = _pasteOneWaypointToE80($wpmgr, $tree, $item, \$policy, 'Paste Waypoint',
        $progress, $pending_uuids, $pending_names);
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

    if ($cb->{cut_flag} && ($result eq 'created' || $result eq 'replaced'))
    {
        $cb->{source} eq 'database'
            ? _cutDatabaseWaypoint($uuid, $tree)
            : _cutE80Waypoint($uuid, $tree);
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
    return if !$progress;

    my $policy      = undef;
    my $any_skipped = 0;
    my @placed_uuids;
    for my $member (@$members)
    {
        last if $progress && $progress->{cancelled};
        my $result = _pasteOneWaypointToE80($wpmgr, $tree, $member, \$policy,
            'Paste Group', $progress, $pending_uuids, $pending_names);
        last if $result eq 'aborted';
        push @placed_uuids, $member->{uuid};
        $any_skipped = 1 if $result eq 'skipped';
        if ($cb->{cut_flag} && $result ne 'skipped' && $result ne 'aborted')
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
        if ($cb->{cut_flag} && !$any_skipped)
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

    my $route_uuid   = $item->{uuid};
    my $route_data   = $item->{data};
    my $route_points = $item->{route_points} // [];
    display($dbg_e80_ops, 0, "_pasteRouteToE80: '${\($route_data->{name}//'')}' rps=" . scalar(@$route_points));

    # SS10.10: every member WP UUID must already exist on E80 -- we do not auto-create
    my @wp_uuids;
    for my $rp (@$route_points)
    {
        my $uuid = $rp->{uuid};
        unless ($wpmgr->{waypoints}{$uuid})
        {
            error("_pasteRouteToE80: IMPLEMENTATION ERROR -- route member $uuid not on E80 (SS10.10)");
            return;
        }
        push @wp_uuids, $uuid;
    }

    my $progress;
    if ($shared_progress)
    {
        $progress = $shared_progress;
        $progress->{label} = $route_data->{name} // 'Paste Route';
    }
    else
    {
        $progress = _openE80Progress("Paste Route", 1,
            {cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
        return if !$progress;
    }

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

    if ($cb->{cut_flag})
    {
        $cb->{source} eq 'database'
            ? _cutDatabaseRoute($route_uuid, $tree)
            : _cutE80Route($route_uuid, $tree);
    }
}


sub _pasteAllToE80
    # UUID-preserving multi-item paste to E80. $items already pre-flighted.
{
    my ($node, $tree, $items, $cb) = @_;

    my $wpmgr = _wpmgr();
    if (!$wpmgr)
    {
        error("_pasteAllToE80: WPMGR not connected");
        return;
    }

    # Pasting waypoints into an existing E80 route: append by UUID reference, no WP creation.
    if (($node->{type} // '') eq 'route')
    {
        my $route_uuid = $node->{uuid};
        my $route      = $wpmgr->{routes}{$route_uuid};
        unless ($route)
        {
            error("_pasteAllToE80: route $route_uuid not found on E80");
            return;
        }
        my @add_uuids;
        for my $item (@$items)
        {
            next unless ($item->{type} // '') eq 'waypoint';
            my $uuid = $item->{uuid} // '';
            push @add_uuids, $uuid if $uuid && $wpmgr->{waypoints}{$uuid};
        }
        if (!@add_uuids)
        {
            warning(0, 0, "_pasteAllToE80: no valid waypoint UUIDs to append to route");
            return;
        }
        my $progress = _openE80Progress("Paste to Route", 1,
            {cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
        return if !$progress;
        $wpmgr->modifyRoute({
            uuid      => $route_uuid,
            waypoints => [@{$route->{uuids} // []}, @add_uuids],
            progress  => $progress,
        });
        return;
    }

    my $total = 0;
    for my $item (@$items)
    {
        my $type    = $item->{type} // '';
        my $members = $item->{members} // [];
        if    ($type eq 'waypoint') { $total += 1; }
        elsif ($type eq 'group')    { $total += scalar(@$members) + ($item->{uuid} ? 1 : 0); }
        elsif ($type eq 'route')    { $total += 1; }
    }

    my $progress = _openE80Progress("Paste", $total,
        {cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
    return if !$progress;

    my %pending_uuids;
    my %pending_names;

    for my $item (@$items)
    {
        last if $progress->{cancelled};
        my $type = $item->{type} // '';
        if ($type eq 'waypoint')
        {
            _pasteWaypointToE80($node, $tree, $item, $cb, \%pending_uuids, \%pending_names, $progress);
        }
        elsif ($type eq 'group')
        {
            _pasteGroupToE80($node, $tree, $item, $cb, $progress, \%pending_uuids, \%pending_names);
        }
        elsif ($type eq 'route')
        {
            _pasteRouteToE80($node, $tree, $item, $cb, $progress, \%pending_uuids, \%pending_names);
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
# Paste helpers - fresh UUIDs (PASTE_NEW)
#----------------------------------------------------

sub _pasteNewWaypointToE80
{
    my ($node, $tree, $item, $cb, $shared_progress) = @_;

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

    my $progress;
    if ($shared_progress)
    {
        $progress = $shared_progress;
    }
    else
    {
        my $total = 1 + ($group_uuid ? 1 : 0);
        $progress = _openE80Progress("Paste New Waypoint", $total,
            {cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
        return if !$progress;
    }

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
        sym      => 0,
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
    return if !$progress;

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
            sym      => 0,
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
            my $group_name = _deconflictE80Name($wpmgr, $group_data->{name} // '',
                \%pending_group_names, 'groups');
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
    my $members    = $item->{route_points} // [];

    my $progress;
    if ($shared_progress)
    {
        $progress = $shared_progress;
        $progress->{label} = $route_data->{name} // 'Paste New Route';
    }
    else
    {
        $progress = _openE80Progress("Paste New Route", 1,
            {cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
    }
    return if !$progress;

    return if $progress->{cancelled};

    my $new_route_uuid = _newNavUUID();
    if (!$new_route_uuid)
    {
        error("_pasteNewRouteToE80: UUID generation failed");
        $progress->{error} = 'UUID generation failed' if $progress;
        return;
    }

    my %pending_route_names;
    my $route_name = _deconflictE80Name($wpmgr, $route_data->{name} // '',
        \%pending_route_names, 'routes');
    my @wp_uuids = map { $_->{uuid} } @$members;
    $wpmgr->createRoute({
        name      => $route_name,
        uuid      => $new_route_uuid,
        comment   => $route_data->{comment} // '',
        color     => $cb->{source} eq 'database'
            ? abgrToE80Index($route_data->{color})
            : ($route_data->{color} // 0),
        waypoints => \@wp_uuids,
        progress  => $progress,
    });
}


sub _pasteNewAllToE80
    # Fresh-UUID multi-item paste to E80. $items already pre-flighted.
{
    my ($node, $tree, $items, $cb) = @_;

    my $wpmgr = _wpmgr();
    if (!$wpmgr)
    {
        error("_pasteNewAllToE80: WPMGR not connected");
        return;
    }

    # Pasting into an existing E80 route: append existing WPs by UUID reference.
    # WPs that already exist (duplicate route point case) bypass name-collision in
    # the pre-flight, so they arrive here and must be appended, not re-created.
    if (($node->{type} // '') eq 'route')
    {
        my $route_uuid = $node->{uuid};
        my $route      = $wpmgr->{routes}{$route_uuid};
        unless ($route)
        {
            error("_pasteNewAllToE80: route $route_uuid not found on E80");
            return;
        }
        my @add_uuids;
        for my $item (@$items)
        {
            my $t = $item->{type} // '';
            next unless $t eq 'waypoint' || $t eq 'route_point';
            my $uuid = $item->{uuid} // '';
            push @add_uuids, $uuid if $uuid && $wpmgr->{waypoints}{$uuid};
        }
        if (!@add_uuids)
        {
            warning(0, 0, "_pasteNewAllToE80: no valid waypoint UUIDs to append to route");
            return;
        }
        my $progress = _openE80Progress("Paste to Route", 1,
            {cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
        return if !$progress;
        $wpmgr->modifyRoute({
            uuid      => $route_uuid,
            waypoints => [@{$route->{uuids} // []}, @add_uuids],
            progress  => $progress,
        });
        return;
    }

    my $total = 0;
    for my $item (@$items)
    {
        my $type    = $item->{type} // '';
        my $members = $item->{members} // [];
        if    ($type eq 'waypoint') { $total += 1; }
        elsif ($type eq 'group')    { $total += scalar(@$members) + 1; }
        elsif ($type eq 'route')    { $total += 1; }
    }

    my $progress = _openE80Progress("Paste New", $total,
        {cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
    return if !$progress;

    for my $item (@$items)
    {
        last if $progress->{cancelled};
        my $type = $item->{type} // '';
        if ($type eq 'waypoint')
        {
            _pasteNewWaypointToE80($node, $tree, $item, $cb, $progress);
        }
        elsif ($type eq 'group')
        {
            _pasteNewGroupToE80($node, $tree, $item, $cb, $progress);
        }
        elsif ($type eq 'route')
        {
            _pasteNewRouteToE80($node, $tree, $item, $cb, $progress);
        }
        elsif ($type eq 'track')
        {
            display($dbg_e80_ops, 0, "_pasteNewAllToE80: skipping track '${\($item->{data}{name}//$item->{uuid})}'");
        }
        else
        {
            warning(0, 0, "_pasteNewAllToE80: unknown item type '$type'");
        }
    }
}


#----------------------------------------------------
# Paste Before / After route point
#----------------------------------------------------

sub _pasteBeforeAfterE80
    # Insert waypoints from $items at a position in an E80 route.
    # right_click_node is the route_point that is the insertion pivot.
    # PASTE_BEFORE/PASTE_NEW_BEFORE: insert before the pivot.
    # PASTE_AFTER/PASTE_NEW_AFTER: insert after the pivot.
{
    my ($cmd_id, $right_click_node, $tree, $items, $cb) = @_;

    my $wpmgr = _wpmgr();
    if (!$wpmgr)
    {
        error("_pasteBeforeAfterE80: WPMGR not connected");
        return;
    }

    my $route_uuid = $right_click_node->{route_uuid};
    my $route      = $wpmgr->{routes}{$route_uuid};
    if (!$route)
    {
        warning(0, 0, "_pasteBeforeAfterE80: route $route_uuid not found in E80 memory");
        return;
    }

    # Flatten items to waypoints (expand group members).
    my @flat_wps;
    for my $item (@$items)
    {
        my $type = $item->{type} // '';
        if    ($type eq 'waypoint')    { push @flat_wps, $item; }
        elsif ($type eq 'route_point') { push @flat_wps, $item; }
        elsif ($type eq 'group')       { push @flat_wps, @{$item->{members} // []}; }
    }
    return unless @flat_wps;

    my $fresh = ($cmd_id == $CTX_CMD_PASTE_NEW_BEFORE || $cmd_id == $CTX_CMD_PASTE_NEW_AFTER);

    # Find pivot position in route uuids array.
    my @cur_uuids = @{$route->{uuids} // []};
    my $pivot_uuid = $right_click_node->{uuid};
    my ($pos)      = grep { $cur_uuids[$_] eq $pivot_uuid } 0 .. $#cur_uuids;
    $pos //= scalar @cur_uuids;
    $pos++ if $cmd_id == $CTX_CMD_PASTE_AFTER || $cmd_id == $CTX_CMD_PASTE_NEW_AFTER;

    my $total    = scalar(@flat_wps) + 1;    # N WP creates + 1 modifyRoute
    my $progress = _openE80Progress("Paste Route Points", $total,
        {cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
    return if !$progress;

    my @new_wp_uuids;
    my %pending_names;
    my $policy = undef;

    for my $item (@flat_wps)
    {
        last if $progress && $progress->{cancelled};

        my $wp       = $item->{data};
        my $wp_uuid;

        if ($fresh)
        {
            $wp_uuid = _newNavUUID();
            if (!$wp_uuid)
            {
                error("_pasteBeforeAfterE80: UUID generation failed");
                $progress->{error} = 1 if $progress;
                last;
            }
            my $wp_name = _deconflictE80Name($wpmgr, $wp->{name}, \%pending_names);
            $wpmgr->createWaypoint({
                name     => $wp_name,
                uuid     => $wp_uuid,
                lat      => $wp->{lat},
                lon      => $wp->{lon},
                sym      => 0,
                ts       => $wp->{created_ts} // $wp->{ts} // time(),
                comment  => $wp->{comment} // '',
                depth    => $wp->{depth_cm} // $wp->{depth} // 0,
                progress => $progress,
            });
        }
        else
        {
            $wp_uuid = $item->{uuid};
            my $result = _pasteOneWaypointToE80($wpmgr, $tree, $item, \$policy,
                'Paste Route Points', $progress, undef, \%pending_names);
            last if $result eq 'aborted';
            if ($cb->{cut_flag} && ($result eq 'created' || $result eq 'replaced'))
            {
                $cb->{source} eq 'database'
                    ? _cutDatabaseWaypoint($wp_uuid, $tree)
                    : _cutE80Waypoint($wp_uuid, $tree);
            }
        }
        push @new_wp_uuids, $wp_uuid;
    }

    return if $progress && ($progress->{cancelled} || $progress->{error});

    splice(@cur_uuids, $pos, 0, @new_wp_uuids);
    $wpmgr->modifyRoute({
        uuid      => $route_uuid,
        waypoints => \@cur_uuids,
        progress  => $progress,
    });
}


#----------------------------------------------------
# Paste dispatcher
#----------------------------------------------------

sub _pasteE80
{
    my ($cmd_id, $right_click_node, $tree, $items, $cb) = @_;

    my $rn_type = $right_click_node ? ($right_click_node->{type} // '') : '';
    my $rn_kind = $right_click_node ? ($right_click_node->{kind} // '') : '';
    if ($rn_type eq 'track'
     || ($rn_type eq 'header' && $rn_kind eq 'tracks'))
    {
        warning(0, 0, "IMPLEMENTATION ERROR: _pasteE80: tracks destination reached paste handler (SS10.8)");
        return;
    }

    if ($rn_type eq 'waypoint')
    {
        warning(0, 0, "IMPLEMENTATION ERROR: _pasteE80: individual waypoint node destination reached paste handler");
        return;
    }

    if ($cmd_id == $CTX_CMD_PASTE_BEFORE    || $cmd_id == $CTX_CMD_PASTE_AFTER
     || $cmd_id == $CTX_CMD_PASTE_NEW_BEFORE || $cmd_id == $CTX_CMD_PASTE_NEW_AFTER)
    {
        _pasteBeforeAfterE80($cmd_id, $right_click_node, $tree, $items, $cb);
        return;
    }

    if ($cmd_id == $CTX_CMD_PASTE_NEW)
    {
        _pasteNewAllToE80($right_click_node, $tree, $items, $cb);
    }
    else
    {
        _pasteAllToE80($right_click_node, $tree, $items, $cb);
    }
}


#----------------------------------------------------
# Cut - source deletion after successful paste
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


#----------------------------------------------------
# _pushToE80 -- DB->E80 push up
#----------------------------------------------------

sub _pushToE80
{
    my ($right_click_node, $tree, $items) = @_;

    my $wpmgr = _wpmgr();
    if (!$wpmgr)
    {
        error("_pushToE80: WPMGR not connected");
        return;
    }

    my $total = 0;
    for my $item (@$items)
    {
        my $t = $item->{type} // '';
        if    ($t eq 'waypoint') { $total++;                                                  }
        elsif ($t eq 'group')    { $total += scalar(@{$item->{members} // []}) + 1;           }
        elsif ($t eq 'route')    { $total++;                                                  }
    }

    my $progress = _openE80Progress("Push to E80", $total,
        {cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
    return if !$progress;

    for my $item (@$items)
    {
        last if $progress->{cancelled};
        my $t    = $item->{type} // '';
        my $uuid = $item->{uuid} // '';
        my $d    = $item->{data} // {};
        next if !$uuid;

        if ($t eq 'waypoint')
        {
            if (!$wpmgr->{waypoints}{$uuid})
            {
                warning(0, 0, "_pushToE80: waypoint $uuid not on E80 -- skipping");
                $progress->{done}++;
                next;
            }
            $wpmgr->modifyWaypoint({
                uuid     => $uuid,
                name     => $d->{name}       // '',
                lat      => $d->{lat},
                lon      => $d->{lon},
                sym      => 0,
                ts       => $d->{created_ts} // $d->{ts} // time(),
                comment  => $d->{comment}    // '',
                depth    => $d->{depth_cm}   // 0,
                progress => $progress,
            });
        }
        elsif ($t eq 'group')
        {
            if (!$wpmgr->{groups}{$uuid})
            {
                warning(0, 0, "_pushToE80: group $uuid not on E80 -- skipping");
                $progress->{done} += scalar(@{$item->{members} // []}) + 1;
                next;
            }
            for my $member (@{$item->{members} // []})
            {
                last if $progress->{cancelled};
                my $mu = $member->{uuid} // '';
                my $md = $member->{data} // {};
                next if !$mu || !$wpmgr->{waypoints}{$mu};
                $wpmgr->modifyWaypoint({
                    uuid     => $mu,
                    name     => $md->{name}       // '',
                    lat      => $md->{lat},
                    lon      => $md->{lon},
                    sym      => 0,
                    ts       => $md->{created_ts} // $md->{ts} // time(),
                    comment  => $md->{comment}    // '',
                    depth    => $md->{depth_cm}   // 0,
                    progress => $progress,
                });
            }
            if (!$progress->{cancelled})
            {
                my @member_uuids = map { $_->{uuid} } grep { $_->{uuid} } @{$item->{members} // []};
                $wpmgr->modifyGroup({
                    uuid     => $uuid,
                    name     => $d->{name}    // '',
                    comment  => $d->{comment} // '',
                    members  => \@member_uuids,
                    progress => $progress,
                });
            }
        }
        elsif ($t eq 'route')
        {
            if (!$wpmgr->{routes}{$uuid})
            {
                warning(0, 0, "_pushToE80: route $uuid not on E80 -- skipping");
                $progress->{done}++;
                next;
            }
            my @wp_uuids = map { $_->{uuid} } grep { $_->{uuid} } @{$item->{route_points} // []};
            $wpmgr->modifyRoute({
                uuid      => $uuid,
                name      => $d->{name}    // '',
                comment   => $d->{comment} // '',
                color     => abgrToE80Index($d->{color} // ''),
                waypoints => \@wp_uuids,
                progress  => $progress,
            });
        }
    }
}


#----------------------------------------------------
# _clearE80_DB / doClearE80DB
#----------------------------------------------------

sub _clearE80_DB
{
    my ($parent) = @_;

    my $wpmgr = _wpmgr();
    my $track = _track();

    if (!$wpmgr)
    {
        error("_clearE80_DB: WPMGR not connected");
        return;
    }

    my @route_uuids  = sort keys %{$wpmgr->{routes}    // {}};
    my @group_uuids  = sort keys %{$wpmgr->{groups}    // {}};
    my @all_wp_uuids = sort keys %{$wpmgr->{waypoints} // {}};
    my @track_uuids  = $track ? sort keys %{$track->{tracks} // {}} : ();

    my %grouped_wp;
    for my $g_uuid (@group_uuids)
    {
        $grouped_wp{$_} = 1 for @{$wpmgr->{groups}{$g_uuid}{uuids} // []};
    }
    my @named_wps     = grep {  $grouped_wp{$_} } @all_wp_uuids;
    my @ungrouped_wps = grep { !$grouped_wp{$_} } @all_wp_uuids;

    unless (@route_uuids || @group_uuids || @all_wp_uuids || @track_uuids)
    {
        okDialog($parent, "E80 is already empty.", "Clear E80 DB");
        return;
    }

    my @parts;
    push @parts, scalar(@route_uuids)  . " route(s)"    if @route_uuids;
    push @parts, scalar(@group_uuids)  . " group(s)"    if @group_uuids;
    push @parts, scalar(@all_wp_uuids) . " waypoint(s)" if @all_wp_uuids;
    push @parts, scalar(@track_uuids)  . " track(s)"    if @track_uuids;
    my $summary = join(', ', @parts);

    return if !confirmDialog($parent,
        "Delete ALL E80 data ($summary)? Cannot be undone.",
        "Clear E80 DB");

    my $total_route_pts = 0;
    $total_route_pts += scalar @{($wpmgr->{routes}{$_} // {})->{uuids} // []}
        for @route_uuids;

    my $total_ops = ($total_route_pts + scalar @route_uuids)
                  + (scalar @group_uuids + scalar @named_wps)
                  + scalar @ungrouped_wps;
    $total_ops = 1 if !$total_ops;

    my $progress = _openE80Progress("Clear E80 DB", $total_ops);
    return if !$progress;
    $progress->{_counting_get_items} = 1;

    $wpmgr->deleteRoute($_, $progress) for @route_uuids;
    $wpmgr->deleteGroup($_, $progress) for @group_uuids;
    $wpmgr->deleteWaypoint($_, $progress, 1) for @named_wps;
    $wpmgr->deleteWaypoint($_, $progress, 1) for @ungrouped_wps;

    if ($track)
    {
        $track->queueTRACKCommand(
            $apps::raymarine::NET::d_TRACK::API_GENERAL_CMD,
            $_, 'erase') for @track_uuids;
    }
}


sub doClearE80DB
{
    my ($parent) = @_;
    display(-1, 0, "===== Clear E80 DB STARTED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
    _clearE80_DB($parent);
    display(-1, 0, "===== Clear E80 DB FINISHED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
}


1;
