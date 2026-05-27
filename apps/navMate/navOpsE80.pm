#!/usr/bin/perl
#---------------------------------------------
# navOpsE80.pm
#---------------------------------------------
# E80-side operations for navMate context menu.
# Continues as package navOps (loaded via require from navOps.pm).

package navOps;	# continued ...
use strict;
use warnings;
use Wx qw(:everything);
use Pub::Utils qw(display warning error getAppFrame);
use Pub::WX::Dialogs;
use apps::raymarine::NET::a_defs qw($E80_MAX_NAME $E80_MAX_COMMENT);
use apps::raymarine::NET::a_utils qw(latLonToNorthEast);
use apps::raymarine::NET::d_TRACK_writer;
use navClipboard qw(_pasteTracksToE80Allows);
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


sub _checkE80NameConflict
    # Detect a name conflict between $name and the live E80 state
    # ($hash_name = 'waypoints' (default), 'groups', or 'routes') or any
    # names already queued this batch in $pending_names.  Case-insensitive
    # match (mirrors E80 uniqueness enforcement).
    #
    # $name may be passed PRE-truncation (full DB name); the function
    # truncates internally to $E80_MAX_NAME before comparing.  This
    # mirrors the E80's own keying (the device stores truncated names)
    # and catches post-truncation collisions that pre-truncation
    # comparison would miss.  $pending_names is populated with the
    # truncated lc form so the intra-batch check is also
    # truncation-aware by construction.
    #
    # Per policy, navMate NEVER auto-renames.  Preflight in
    # navOps::_doPaste / navOps::_doPush is the primary gate; this
    # spoke-seam check is the defensive assert that catches preflight
    # regressions before any wire send.
    #
    # Returns undef on no-conflict (and claims the name in $pending_names),
    # or { name, where => 'spoke'|'pending', existing_uuid? } on conflict
    # (and leaves $pending_names untouched).
{
    my ($wpmgr, $name, $pending_names, $hash_name) = @_;
    $hash_name     //= 'waypoints';
    $pending_names //= {};
    my $lc = lc(substr($name // '', 0, $E80_MAX_NAME));

    for my $rec (values %{$wpmgr->{$hash_name} // {}})
    {
        my $rn = $rec->{name} // '';
        if (lc($rn) eq $lc)
        {
            return {
                name          => $name,
                where         => 'spoke',
                existing_uuid => $rec->{uuid} // '',
                hash          => $hash_name,
            };
        }
    }
    if ($pending_names->{$lc})
    {
        return { name => $name, where => 'pending', hash => $hash_name };
    }
    $pending_names->{$lc} = 1;
    return undef;
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
    # modifyGroup if in a group (unless $skip_group), then deleteWaypoint.
    # $skip_group is used by cross-spoke cut-paste cleanup of a whole group,
    # where the group is being deleted in the same batch so per-WP group
    # detachment is wasted work and adds queue pressure.
{
    my ($wpmgr, $wp_uuid, $skip_route, $progress, $skip_group) = @_;
    for my $r_uuid (_e80WPRoutes($wpmgr, $wp_uuid, $skip_route))
    {
        my $route = $wpmgr->{routes}{$r_uuid};
        my @new   = grep { $_ ne $wp_uuid } @{$route->{uuids} // []};
        $wpmgr->modifyRoute({uuid => $r_uuid, waypoints => \@new, progress => $progress});
    }
    if (!$skip_group)
    {
        my $g = _e80WPGroup($wpmgr, $wp_uuid);
        if ($g)
        {
            my $group = $wpmgr->{groups}{$g};
            my @new   = grep { $_ ne $wp_uuid } @{$group->{uuids} // []};
            $wpmgr->modifyGroup({uuid => $g, members => \@new, progress => $progress});
        }
    }
    $wpmgr->deleteWaypoint($wp_uuid, $progress, 1);
}


#----------------------------------------------------
# Delete helpers
#----------------------------------------------------

sub _deleteE80Waypoints
{
    # $progress: optional, supplied by an aggregator that has already
    # opened a ProgressDialog covering this call as part of a larger
    # navOperation.  When absent, this routine opens its own dialog
    # sized for $n waypoints.
    my ($nodes, $tree, $progress) = @_;
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
    if (!$progress)
    {
        $progress = _openE80Progress("Delete Waypoint", $n);
        return if !$progress;
    }
    $wpmgr->deleteWaypoint($_->{uuid}, $progress) for @$nodes;
}


sub _deleteE80Groups
{
    my ($nodes, $tree) = @_;
    if (grep { ($_->{type} // '') eq 'my_waypoints' } @$nodes)
    {
        implementationError("delete-group on E80 my_waypoints node not supported");
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
        implementationError("delete-group-and-WPs mixes my_waypoints with named groups");
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
            my $msg = "My Waypoints is empty.";
            $nmDialogs::suppress_confirm ? warning(0, 0, $msg) : okDialog($tree, $msg, "Delete Group + Waypoints");
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
    # Dedup uuids per route when sizing the progress dialog.
    # Each route delete generates one MODIFY event per UNIQUE member-WP UUID
    # (E80 sends one update per WP, not one per route_waypoint entry), and each
    # MODIFY -> GET_ITEM advances $progress->{done} once. Counting raw uuids[]
    # entries here would inflate total above the achievable done when a route
    # contains the same WP UUID more than once (legal after copy-splice route
    # point operations), and the dialog would never reach done==total and hang.
    for my $node (@$nodes)
    {
        my %seen;
        $total_pts += scalar(grep { !$seen{$_}++ } @{($node->{data} // {})->{uuids} // []});
    }
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
    my $progress = _openE80Progress("Delete Track", $n);
    return if !$progress;
    for my $node (@$nodes)
    {
        $track->queueTRACKCommand(
            $apps::raymarine::NET::d_TRACK::API_GENERAL_CMD,
            $node->{uuid}, 'erase', undef, $progress);
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
        sym     => symForWpType($WP_TYPE_NAV) // 0,
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
        if (defined($pending_names))
        {
            if (my $c = _checkE80NameConflict($wpmgr, $wp->{name}, $pending_names))
            {
                implementationError("E80 waypoint name '$c->{name}' collides with existing waypoint (where=$c->{where})");
                return 'aborted';
            }
        }
        $pending_uuids->{$uuid} = 1 if $pending_uuids;
        my ($pa_wp_name, $pa_wp_comment) = _truncForE80($wp->{name} // '', $wp->{comment} // '');
        $wpmgr->createWaypoint({
            name     => $pa_wp_name,
            uuid     => $uuid,
            lat      => $wp->{lat},
            lon      => $wp->{lon},
            sym      => $wp->{sym} // 0,
            ts       => $wp->{created_ts} // $wp->{ts} // time(),
            comment  => $pa_wp_comment,
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
            sym      => $wp->{sym} // 0,
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
        _cutPasteCleanupWp($cb, $uuid, $tree);
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
            _cutPasteCleanupWp($cb, $member->{uuid}, $tree);
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
            my ($pg_name, $pg_comment) = _truncForE80($group_data->{name} // '', $group_data->{comment} // '');
            $wpmgr->createGroup({
                name     => $pg_name,
                uuid     => $group_uuid,
                comment  => $pg_comment,
                members  => \@placed_uuids,
                progress => $progress,
            });
        }
        if ($cb->{cut_flag} && !$any_skipped)
        {
            _cutPasteCleanupGroup($cb, $group_uuid, $tree);
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
        if (!$wpmgr->{waypoints}{$uuid})
        {
            implementationError("route member $uuid not on E80 (SS10.10)");
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
        my ($pr_name, $pr_comment) = _truncForE80($route_data->{name} // '', $route_data->{comment} // '');
        $wpmgr->createRoute({
            name      => $pr_name,
            uuid      => $route_uuid,
            comment   => $pr_comment,
            color     => $cb->{source} eq 'database'
                ? abgrToE80Index($route_data->{color})
                : ($route_data->{color} // 0),
            waypoints => \@wp_uuids,
            progress  => $progress,
        });
    }

    if ($cb->{cut_flag})
    {
        _cutPasteCleanupRoute($cb, $route_uuid, $tree);
    }
}


#----------------------------------------------------
# Track-write helpers (DB / FSH -> E80 via TRACK writer-session)
#----------------------------------------------------
# These compose the per-track upload through
# apps::raymarine::NET::d_TRACK_writer (NET/d_TRACK_writer.pm), which
# implements the protocol in NET/docs/notes/TRACK_writing.md.  One
# TCP session per track upload.  No modify-in-place: E80 rejects
# RECORD with an existing UUID, so PASTE requires UUID-not-on-E80
# (predicate _pasteTracksToE80Allows enforces) and PASTE_NEW mints
# a fresh navMate UUID.

sub _normalizeTrackPointForWire
{
    # Returns a hashref with north/east/temp_k/depth populated, suitable
    # for buildTRKPoint.  Field-name normalization across sources:
    #
    #   - DB     (navDB::getTrackPoints): lat, lon, depth_cm, temp_k, ts
    #   - FSH    (navFSH /api/fsh):       lat, lon, north, east, depth, temp_k
    #   - E80    (in-memory parsed):      north, east, depth, temp_k, lat, lon
    #
    # Caller may pass any of these shapes; north/east take precedence over
    # lat/lon (cheaper, exact), and the depth field is read as either
    # 'depth' or 'depth_cm' (both are centimeters per
    # memory/track_point_fields.md).
    my ($pt) = @_;
    my %wire = (
        temp_k => $pt->{temp_k} // 0,
        depth  => $pt->{depth}  // $pt->{depth_cm} // 0,
    );
    if (defined $pt->{north} && defined $pt->{east})
    {
        $wire{north} = $pt->{north};
        $wire{east}  = $pt->{east};
    }
    elsif (defined $pt->{lat} && defined $pt->{lon})
    {
        my $coords = latLonToNorthEast($pt->{lat}, $pt->{lon});
        $wire{north} = $coords->{north};
        $wire{east}  = $coords->{east};
    }
    else
    {
        $wire{north} = 0;
        $wire{east}  = 0;
    }
    return \%wire;
}


sub _trackItemPoints
{
    # Returns the points arrayref for a track item, fetching from DB
    # if the item didn't bring them along (DB-tree right-click-Push
    # currently snapshots without the points blob).
    my ($item) = @_;
    return $item->{points} if ref($item->{points}) eq 'ARRAY' && @{$item->{points}};
    return $item->{data}{points} if ref($item->{data}{points}) eq 'ARRAY' && @{$item->{data}{points}};
    my $uuid = $item->{uuid} // $item->{data}{mta_uuid} // $item->{data}{uuid} // '';
    return [] if !$uuid;
    my $dbh = connectDB();
    return [] if !$dbh;
    my $points = getTrackPoints($dbh, $uuid) || [];
    disconnectDB($dbh);
    return $points;
}


sub _buildMtaRecForItem
{
    # Assembles the MTA hash that buildMTA consumes from a track item.
    # Source-agnostic: works for DB / FSH / E80-sourced items.  Caller
    # passes an explicit $name (post-truncate-for-E80), a $color (in
    # either source form -- DB ABGR string or FSH/E80 palette int),
    # and a $points arrayref of wire-normalized points so that
    # start/end anchors come from the actual points being delivered.
    # Color is normalized here: ABGR strings convert via abgrToE80Index;
    # integers in 0..5 pass through; anything else folds to 0 (red).
    my ($item, $name, $color, $points) = @_;
    my $d        = $item->{data}  // {};
    my $first_pt = $points->[0]   // {};
    my $last_pt  = $points->[-1]  // $first_pt;

    my $color_int = 0;
    if (defined $color)
    {
        if ($color =~ /^\d+$/)
        {
            $color_int = int($color);
            $color_int = 0 if $color_int < 0 || $color_int > 5;
        }
        else
        {
            $color_int = abgrToE80Index($color);
        }
    }

    return {
        name           => $name,
        color          => $color_int,
        length         => $d->{length} // $d->{distance} // 0,
        north_start    => $first_pt->{north} // 0,
        east_start     => $first_pt->{east}  // 0,
        temp_k_start   => $first_pt->{temp_k} // 0,
        depth_start    => $first_pt->{depth}  // 0,
        north_end      => $last_pt->{north} // 0,
        east_end       => $last_pt->{east}  // 0,
        temp_k_end     => $last_pt->{temp_k} // 0,
        depth_end      => $last_pt->{depth}  // 0,
    };
}


sub _writeTrackToE80
{
    # Core per-track writer invocation.  Used by both _pasteTrackToE80
    # and _pasteNewTrackToE80; the only difference between them is the
    # UUID that gets passed (caller's responsibility to mint fresh for
    # PASTE_NEW).
    #
    # Returns 1 on success, 0 on failure (with error already
    # displayed via Pub::Utils::error).
    my ($item, $uuid_hex, $progress) = @_;

    my $track_svc = _track();
    if (!$track_svc)
    {
        error("_writeTrackToE80: TRACK service not connected");
        return 0;
    }

    my $d        = $item->{data} // {};
    my $name_raw = $d->{name}    // $item->{name} // 'TRACK';
    my ($name, undef) = _truncForE80($name_raw, '');   # apply E80 15-char limit
    my $color    = $d->{color} // 0;

    my $raw_points = _trackItemPoints($item);
    if (!@$raw_points)
    {
        error("_writeTrackToE80: track '$name' has no points");
        return 0;
    }

    my @wire_points = map { _normalizeTrackPointForWire($_) } @$raw_points;
    my $mta_rec     = _buildMtaRecForItem($item, $name, $color, \@wire_points);

    display($dbg_e80_ops, 0, "_writeTrackToE80 name='$name' uuid=$uuid_hex points=".scalar(@wire_points));

    my $writer = apps::raymarine::NET::d_TRACK_writer->new(
        ip       => $track_svc->{ip},
        port     => $track_svc->{port},
        mta_rec  => $mta_rec,
        points   => \@wire_points,
        uuid_hex => $uuid_hex,
        progress => $progress,
    );
    if (!$writer)
    {
        error("_writeTrackToE80: failed to construct d_TRACK_writer");
        return 0;
    }

    my $ok = $writer->run();
    if (!$ok)
    {
        error("_writeTrackToE80: track '$name' write failed: " . ($writer->{error} // 'unknown'));
        return 0;
    }
    return 1;
}


sub _pasteTrackToE80
{
    # PASTE -- preserves the source item's mta_uuid as the MTA-CONTEXT
    # UUID on the wire (E80 saves under that UUID).  Caller must have
    # cleared collision via _pasteTracksToE80Allows; if a duplicate-
    # UUID slips through, E80 returns 0x80040f07 in SAVED.success and
    # the writer reports failure.
    my ($node, $tree, $item, $cb, $progress) = @_;
    my $uuid = $item->{uuid} // $item->{data}{mta_uuid} // $item->{data}{uuid} // '';
    if (!$uuid)
    {
        error("_pasteTrackToE80: item has no UUID");
        return;
    }
    my $ok = _writeTrackToE80($item, $uuid, $progress);
    $progress->{done}++ if $progress && $ok;
    return $ok;
}


sub _pasteNewTrackToE80
{
    # PASTE_NEW -- mints a fresh navMate UUID for the writer.  The
    # source item's UUID is discarded for the wire; the DB row is
    # unchanged (PASTE-family operations never touch DB).
    my ($node, $tree, $item, $cb, $progress) = @_;
    my $uuid = _newNavUUID();
    if (!$uuid)
    {
        error("_pasteNewTrackToE80: _newNavUUID returned undef");
        return;
    }
    display($dbg_e80_ops, 0, "_pasteNewTrackToE80: minted fresh uuid=$uuid for '"
        . ($item->{data}{name} // $item->{uuid} // '?') . "'");
    my $ok = _writeTrackToE80($item, $uuid, $progress);
    $progress->{done}++ if $progress && $ok;
    return $ok;
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

    # Track preflight: hard-rule and UUID-collision check before
    # opening the progress dialog.  Halt-on-any-failure: any reject
    # aborts the whole batch, and any UUID collision routes the user
    # to PASTE_NEW instead.
    my @track_items = grep { ($_->{type} // '') eq 'track' } @$items;
    if (@track_items)
    {
        my $track_svc = _track();
        my $verdict   = _pasteTracksToE80Allows(\@track_items, $track_svc);
        if ($verdict =~ /^reject:(.*)/)
        {
            error("_pasteAllToE80: track preflight rejected: $1");
            return;
        }
        if ($verdict eq 'paste_new_required')
        {
            error("_pasteAllToE80: one or more tracks already exist on E80 by UUID; use PASTE_NEW instead");
            return;
        }
    }

    # Pasting waypoints into an existing E80 route: append by UUID reference, no WP creation.
    if (($node->{type} // '') eq 'route')
    {
        my $route_uuid = $node->{uuid};
        my $route      = $wpmgr->{routes}{$route_uuid};
        if (!$route)
        {
            error("_pasteAllToE80: route $route_uuid not found on E80");
            return;
        }
        my @add_uuids;
        for my $item (@$items)
        {
            next if ($item->{type} // '') ne 'waypoint';
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
        elsif ($type eq 'track')    { $total += 1; }
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
            # PASTE-tracks: route to the writer-session.  Predicate
            # _pasteTracksToE80Allows should have ensured no UUID
            # collision before we got here; if one slips through,
            # the writer reports failure with the E80's status code
            # (typically 0x80040f07 for duplicate UUID).
            my $ok = _pasteTrackToE80($node, $tree, $item, $cb, $progress);
            last if !$ok;   # halt-on-any-failure policy
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
    if (my $c = _checkE80NameConflict($wpmgr, $wp->{name}, \%pending_names))
    {
        implementationError("E80 waypoint name '$c->{name}' collides with existing waypoint (where=$c->{where})");
        $progress->{error} = 'name collision' if $progress;
        return;
    }
    my ($pnw_name, $pnw_comment) = _truncForE80($wp->{name} // '', $wp->{comment} // '');
    $wpmgr->createWaypoint({
        name     => $pnw_name,
        uuid     => $new_uuid,
        lat      => $wp->{lat},
        lon      => $wp->{lon},
        sym      => $wp->{sym} // 0,
        ts       => $wp->{created_ts} // $wp->{ts} // time(),
        comment  => $pnw_comment,
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
        if (my $c = _checkE80NameConflict($wpmgr, $wp->{name}, \%pending_names))
        {
            implementationError("E80 waypoint name '$c->{name}' collides with existing waypoint (where=$c->{where})");
            $progress->{error} = 'name collision' if $progress;
            last;
        }
        my ($png_wp_name, $png_wp_comment) = _truncForE80($wp->{name} // '', $wp->{comment} // '');
        $wpmgr->createWaypoint({
            name     => $png_wp_name,
            uuid     => $new_uuid,
            lat      => $wp->{lat},
            lon      => $wp->{lon},
            sym      => $wp->{sym} // 0,
            ts       => $wp->{created_ts} // $wp->{ts} // time(),
            comment  => $png_wp_comment,
            depth    => $wp->{depth_cm} // $wp->{depth} // 0,
            progress => $progress,
        });
        push @new_wp_uuids, $new_uuid;
    }

    if (!$progress || (!$progress->{cancelled} && !$progress->{error}))
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
            if (my $c = _checkE80NameConflict($wpmgr, $group_data->{name} // '',
                \%pending_group_names, 'groups'))
            {
                implementationError("E80 group name '$c->{name}' collides with existing group (where=$c->{where})");
                $progress->{error} = 'name collision' if $progress;
            }
            else
            {
                my ($png_grp_name, $png_grp_comment) = _truncForE80($group_data->{name} // '', $group_data->{comment} // '');
                $wpmgr->createGroup({
                    name     => $png_grp_name,
                    uuid     => $new_group_uuid,
                    comment  => $png_grp_comment,
                    members  => \@new_wp_uuids,
                    progress => $progress,
                });
            }
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
    if (my $c = _checkE80NameConflict($wpmgr, $route_data->{name} // '',
        \%pending_route_names, 'routes'))
    {
        implementationError("E80 route name '$c->{name}' collides with existing route (where=$c->{where})");
        $progress->{error} = 'name collision' if $progress;
        return;
    }
    my ($pnr_name, $pnr_comment) = _truncForE80($route_data->{name} // '', $route_data->{comment} // '');
    my @wp_uuids = map { $_->{uuid} } @$members;
    $wpmgr->createRoute({
        name      => $pnr_name,
        uuid      => $new_route_uuid,
        comment   => $pnr_comment,
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

    # Track preflight + PASTE_NEW confirmation dialog.  Hard rules
    # (name length, point count, color) apply unconditionally;
    # UUID-collision is the REASON we're in PASTE_NEW so it's
    # informational, not a reject.  Confirmation dialog warns the
    # user that PASTE_NEW is unusual and they may not have meant it.
    my @track_items = grep { ($_->{type} // '') eq 'track' } @$items;
    if (@track_items)
    {
        my $verdict_hard = _pasteTracksToE80Allows(\@track_items, undef);
        if ($verdict_hard =~ /^reject:(.*)/)
        {
            error("_pasteNewAllToE80: track preflight rejected: $1");
            return;
        }
        # Count tracks that would collide with existing E80 UUIDs
        # (informational only; PASTE_NEW always mints fresh UUIDs).
        my $track_svc = _track();
        my $m = 0;
        if ($track_svc && ref($track_svc->{tracks}) eq 'HASH')
        {
            my $e80_tracks = $track_svc->{tracks};
            for my $item (@track_items)
            {
                my $uuid = $item->{uuid} // $item->{data}{mta_uuid} // '';
                $m++ if $uuid && exists $e80_tracks->{$uuid};
            }
        }
        my $n = scalar @track_items;
        if (!$nmDialogs::suppress_confirm)
        {
            my $msg = "Are you SURE you want to PASTE_NEW these track(s)?\n\n"
                    . "The need for this is highly unusual and creating new tracks on the UUID "
                    . "might not be your intention.  Caution is suggested.\n\n"
                    . "This operation will write $n new track(s), $m of which have existing UUIDs on the E80.";
            return if !confirmDialog($tree, $msg, 'PASTE_NEW');
        }
    }

    # Pasting into an existing E80 route: append existing WPs by UUID reference.
    # WPs that already exist (duplicate route point case) bypass name-collision in
    # the pre-flight, so they arrive here and must be appended, not re-created.
    if (($node->{type} // '') eq 'route')
    {
        my $route_uuid = $node->{uuid};
        my $route      = $wpmgr->{routes}{$route_uuid};
        if (!$route)
        {
            error("_pasteNewAllToE80: route $route_uuid not found on E80");
            return;
        }
        my @add_uuids;
        for my $item (@$items)
        {
            my $t = $item->{type} // '';
            next if $t ne 'waypoint' && $t ne 'route_point';
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
        elsif ($type eq 'track')    { $total += 1; }
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
            # PASTE_NEW-tracks: mint fresh navMate UUID per track.
            # E80 will never collide on a freshly-minted byte-1=0x4e UUID.
            my $ok = _pasteNewTrackToE80($node, $tree, $item, $cb, $progress);
            last if !$ok;   # halt-on-any-failure policy
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
    return if !@flat_wps;

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
            if (my $c = _checkE80NameConflict($wpmgr, $wp->{name}, \%pending_names))
            {
                implementationError("E80 waypoint name '$c->{name}' collides with existing waypoint (where=$c->{where})");
                $progress->{error} = 1 if $progress;
                last;
            }
            my ($pba_name, $pba_comment) = _truncForE80($wp->{name} // '', $wp->{comment} // '');
            $wpmgr->createWaypoint({
                name     => $pba_name,
                uuid     => $wp_uuid,
                lat      => $wp->{lat},
                lon      => $wp->{lon},
                sym      => $wp->{sym} // 0,
                ts       => $wp->{created_ts} // $wp->{ts} // time(),
                comment  => $pba_comment,
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
                _cutPasteCleanupWp($cb, $wp_uuid, $tree);
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

    # E80 tracks header is now a valid paste destination via the
    # TRACK writer-session protocol (NET/docs/notes/TRACK_writing.md,
    # confirmed live 2026-05-27).  Track items route through
    # _pasteAllToE80 / _pasteNewAllToE80, which preflights via
    # navClipboard::_pasteTracksToE80Allows and dispatches each
    # track to _pasteTrackToE80 / _pasteNewTrackToE80 -> d_TRACK_writer.
    # Pasting at an individual track node (a specific saved track)
    # is still not a meaningful destination -- use the tracks header.
    if ($rn_type eq 'track')
    {
        implementationError("paste at individual E80 track node not supported -- use tracks header");
        return;
    }

    if ($rn_type eq 'waypoint')
    {
        implementationError("paste at individual E80 waypoint node not supported");
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
    # $progress: optional, supplied by an aggregator that has already
    # opened a ProgressDialog covering this call.  When absent, opens
    # a single-op "Cut Cleanup" dialog so the operation has visible
    # progress under suppress=1 (mirrors _deleteE80Waypoints).
    my ($uuid, $tree, $skip_group, $progress) = @_;
    my $wpmgr = _wpmgr();
    return if !$wpmgr;
    if (!$progress)
    {
        $progress = _openE80Progress("Cut Cleanup", 1);
        return if !$progress;
    }
    _e80DeleteWP($wpmgr, $uuid, undef, $progress, $skip_group);
}


sub _cutE80Group
{
    my ($uuid, $tree, $progress) = @_;
    return if !defined $uuid;
    my $wpmgr = _wpmgr();
    return if !$wpmgr;
    if (!$progress)
    {
        $progress = _openE80Progress("Cut Cleanup", 1);
        return if !$progress;
    }
    $wpmgr->deleteGroup($uuid, $progress);
}


sub _cutE80Route
{
    my ($uuid, $tree, $progress) = @_;
    my $wpmgr = _wpmgr();
    return if !$wpmgr;
    if (!$progress)
    {
        $progress = _openE80Progress("Cut Cleanup", 1);
        return if !$progress;
    }
    $wpmgr->deleteRoute($uuid, $progress);
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
# _truncForE80
#----------------------------------------------------

sub _truncForE80
{
    my ($name, $comment) = @_;
    if (length($name) > $E80_MAX_NAME)
    {
        warning(0, 0, "_truncForE80: name truncated to $E80_MAX_NAME chars: '$name'");
        $name = substr($name, 0, $E80_MAX_NAME);
    }
    if (length($comment) > $E80_MAX_COMMENT)
    {
        warning(0, 0, "_truncForE80: comment truncated to $E80_MAX_COMMENT chars");
        $comment = substr($comment, 0, $E80_MAX_COMMENT);
    }
    return ($name, $comment);
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

    # Dependency reorder for the DB->E80 direction: waypoints and groups
    # must be pushed before routes so the E80 has every referenced WP
    # available when a route is created. The DB tree allows arbitrary
    # interleave, so a DB-sourced selection can carry routes ahead of
    # their referenced waypoints. (The E80->DB direction does not need
    # this reorder because the E80 tree is rendered in Groups->Routes->
    # Tracks order by construction.)
    my @ordered_items;
    push @ordered_items, grep { ($_->{type}//'') ne 'route' } @$items;
    push @ordered_items, grep { ($_->{type}//'') eq 'route' } @$items;

    my $total = 0;
    for my $item (@ordered_items)
    {
        my $t = $item->{type} // '';
        if    ($t eq 'waypoint') { $total++;                                                  }
        elsif ($t eq 'group')    { $total += scalar(@{$item->{members} // []}) + 1;           }
        elsif ($t eq 'route')    { $total++;                                                  }
        elsif ($t eq 'track')    { $total++;                                                  }
    }

    my $progress = _openE80Progress("Push to E80", $total,
        {cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
    return if !$progress;

    for my $item (@ordered_items)
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
            my ($wp_name, $wp_comment) = _truncForE80($d->{name} // '', $d->{comment} // '');
            $wpmgr->modifyWaypoint({
                uuid     => $uuid,
                name     => $wp_name,
                lat      => $d->{lat},
                lon      => $d->{lon},
                sym      => $d->{sym} // 0,
                ts       => $d->{created_ts} // $d->{ts} // time(),
                comment  => $wp_comment,
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
                my ($mw_name, $mw_comment) = _truncForE80($md->{name} // '', $md->{comment} // '');
                $wpmgr->modifyWaypoint({
                    uuid     => $mu,
                    name     => $mw_name,
                    lat      => $md->{lat},
                    lon      => $md->{lon},
                    sym      => $md->{sym} // 0,
                    ts       => $md->{created_ts} // $md->{ts} // time(),
                    comment  => $mw_comment,
                    depth    => $md->{depth_cm}   // 0,
                    progress => $progress,
                });
            }
            if (!$progress->{cancelled})
            {
                my @member_uuids = map { $_->{uuid} } grep { $_->{uuid} } @{$item->{members} // []};
                my ($grp_name, $grp_comment) = _truncForE80($d->{name} // '', $d->{comment} // '');
                $wpmgr->modifyGroup({
                    uuid     => $uuid,
                    name     => $grp_name,
                    comment  => $grp_comment,
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
            my ($rt_name, $rt_comment) = _truncForE80($d->{name} // '', $d->{comment} // '');
            $wpmgr->modifyRoute({
                uuid      => $uuid,
                name      => $rt_name,
                comment   => $rt_comment,
                color     => abgrToE80Index($d->{color} // ''),
                waypoints => \@wp_uuids,
                progress  => $progress,
            });
        }
        elsif ($t eq 'track')
        {
            # PUSH-track to E80: writer-session protocol creates the
            # track on the E80 with the DB's mta_uuid as identity.
            # E80 rejects duplicate UUIDs (status 0x80040f07);
            # preflight at the higher menu/predicate layer should have
            # already excluded tracks that already exist on E80.
            my $ok = _pasteTrackToE80(undef, undef, $item, undef, $progress);
            last if !$ok;   # halt-on-any-failure policy
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

    if (!@route_uuids && !@group_uuids && !@all_wp_uuids && !@track_uuids)
    {
        okDialog($parent, "E80 is already empty.", "Clear E80 DB") if !$nmDialogs::suppress_confirm;
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
    # Dedup uuids per route -- see the matching comment in _deleteE80Routes.
    # E80 emits one MODIFY per unique member-WP UUID per route deletion, so
    # progress total must count unique UUIDs (not raw uuids[] entries) or the
    # dialog will hang on routes that contain duplicate WP references.
    for my $rt_uuid (@route_uuids)
    {
        my %seen;
        $total_route_pts += scalar(grep { !$seen{$_}++ }
            @{($wpmgr->{routes}{$rt_uuid} // {})->{uuids} // []});
    }

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
