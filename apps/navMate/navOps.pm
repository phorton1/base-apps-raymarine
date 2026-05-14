#!/usr/bin/perl
#---------------------------------------------
# navOps.pm
#---------------------------------------------
# Context-menu operation orchestrator for navMate.
# navOpsDB.pm (DB operations) and navOpsE80.pm (E80 operations)
# are in package navOps and are loaded at the bottom of this file.

package navOps;
use strict;
use warnings;
use threads;
use threads::shared;
use Scalar::Util qw(looks_like_number);
use Wx qw(:everything);
use Pub::Utils qw(display warning error getAppFrame $UTILS_COLOR_LIGHT_MAGENTA);
use Pub::WX::Dialogs;
use apps::raymarine::NET::a_defs qw($SCALE_LATLON $E80_MAX_NAME $E80_MAX_COMMENT);
use apps::raymarine::NET::c_RAYDP;
use navDB;
use n_defs;
use n_utils;
use nmResources;
use navClipboard;
use nmDialogs;

require navOpsDB;
require navOpsE80;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		buildContextMenu
		onContextMenuCommand
		doClearE80DB
	);
}


our $dbg_ops     = 0;
our $dbg_e80_ops = 0;


#----------------------------------------------------
# Private service helpers
#----------------------------------------------------

sub _wpmgr
{
	return $raydp ? $raydp->findImplementedService('WPMGR', 1) : undef;
}

sub _track
{
	return $raydp ? $raydp->findImplementedService('TRACK', 1) : undef;
}

sub _e80WpClipData
{
	# E80 wpmgr records carry lat/lon as 1e7 scaled ints; convert to decimal degrees.
	my ($data) = @_;
	my $d = { %$data };
	$d->{lat} = ($d->{lat} // 0) / $SCALE_LATLON;
	$d->{lon} = ($d->{lon} // 0) / $SCALE_LATLON;
	return $d;
}

sub _refreshDatabase
{
	my $frame = getAppFrame();
	return if !$frame;
	$_->refresh() for $frame->_findDatabasePanes();
}

sub _newNavUUID
{
	my $dbh = connectDB();
	return undef if !$dbh;
	my $uuid = newUUID($dbh);
	disconnectDB($dbh);
	return $uuid;
}


#----------------------------------------------------
# buildContextMenu
#----------------------------------------------------

sub buildContextMenu
{
	my ($panel, $right_click_node, @nodes) = @_;
	my $menu = Wx::Menu->new();

	my @del   = getDeleteMenuItems($panel, $right_click_node, @nodes);
	my @new   = getNewMenuItems($panel, $right_click_node);
	my @copy  = getCopyMenuItems($panel, @nodes);
	my @cut   = getCutMenuItems($panel, @nodes);
	my @push  = getPushMenuItems($panel, _wpmgr(), @nodes);
	my @paste = getPasteMenuItems($panel, $right_click_node);

	# SS10.10: suppress PASTE and PASTE_NEW when any route in clipboard has member WPs
	# absent from E80 -- user must paste the WPs first, then retry the route paste.
	if ($panel eq 'e80' && ((grep { $_->{id} == $CTX_CMD_PASTE     } @paste)
	                     ||  (grep { $_->{id} == $CTX_CMD_PASTE_NEW } @paste)))
	{
		my $wpmgr = _wpmgr();
		if ($wpmgr && $clipboard)
		{
			my $missing = 0;
			ROUTE_CHECK: for my $cb_item (@{$clipboard->{items} // []})
			{
				next if ($cb_item->{type} // '') ne 'route';
				for my $rp (@{$cb_item->{route_points} // []})
				{
					if (!$wpmgr->{waypoints}{$rp->{uuid}})
					{
						$missing = 1;
						last ROUTE_CHECK;
					}
				}
			}
			@paste = grep { $_->{id} != $CTX_CMD_PASTE && $_->{id} != $CTX_CMD_PASTE_NEW } @paste
				if $missing;
		}
	}

	for my $item (@del)
	{
		$menu->Append($item->{id}, $item->{label});
	}
	$menu->AppendSeparator() if @del && (@new || @copy || @cut || @push || @paste);

	for my $item (@new)
	{
		$menu->Append($item->{id}, $item->{label});
	}
	$menu->AppendSeparator() if @new && (@copy || @cut || @push || @paste);

	for my $item (@copy, @cut)
	{
		$menu->Append($item->{id}, $item->{label});
	}
	$menu->AppendSeparator() if (@copy || @cut) && (@push || @paste);

	for my $item (@push)
	{
		$menu->Append($item->{id}, $item->{label});
	}
	$menu->AppendSeparator() if @push && @paste;

	for my $item (@paste)
	{
		$menu->Append($item->{id}, $item->{label});
	}

	return $menu;
}


#----------------------------------------------------
# onContextMenuCommand - main dispatch
#----------------------------------------------------

sub onContextMenuCommand
{
	my ($cmd_id, $panel, $right_click_node, $tree, @nodes) = @_;
	my $label = _cmdLabel($cmd_id);
	display(-1, 0, "===== $label ($panel) STARTED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);

	if ($cmd_id == $CTX_CMD_COPY)
	{
		_doCopy($panel, $right_click_node, $tree, @nodes);
	}
	elsif ($cmd_id == $CTX_CMD_CUT)
	{
		_doCut($panel, $right_click_node, $tree, @nodes);
	}
	elsif ($cmd_id >= 10210 && $cmd_id <= 10215)
	{
		_doPaste($cmd_id, $panel, $right_click_node, $tree, @nodes);
	}
	elsif ($cmd_id >= 10220 && $cmd_id <= 10226)
	{
		_doDelete($cmd_id, $panel, $right_click_node, $tree, @nodes);
	}
	elsif ($cmd_id >= 10230 && $cmd_id <= 10233)
	{
		_doNew($cmd_id, $panel, $right_click_node, $tree);
	}
	elsif ($cmd_id == $CTX_CMD_PUSH)
	{
		_doPush($panel, $right_click_node, $tree, @nodes);
	}
	else
	{
		warning(0, 0, "navOps: unknown cmd_id=$cmd_id");
	}

	display(-1, 0, "===== $label ($panel) FINISHED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
}


#----------------------------------------------------
# _doCopy
#----------------------------------------------------

sub _doCopy
{
	my ($panel, $right_click_node, $tree, @nodes) = @_;

	if (!@nodes)
	{
		warning(0, 0, "_doCopy: empty selection");
		return;
	}

	my @items = _snapshotNodes($panel, @nodes);
	if (!@items)
	{
		warning(0, 0, "_doCopy: no items snapshotted");
		return;
	}

	setCopy($panel, \@items);
	display($dbg_ops, 0, "_doCopy: $panel " . scalar(@items) . " item(s)");
}


#----------------------------------------------------
# _doCut
#----------------------------------------------------

sub _doCut
{
	my ($panel, $right_click_node, $tree, @nodes) = @_;

	if (!@nodes)
	{
		warning(0, 0, "_doCut: empty selection");
		return;
	}

	my @items = _snapshotNodes($panel, @nodes);
	if (!@items)
	{
		warning(0, 0, "_doCut: no items snapshotted");
		return;
	}

	setCut($panel, \@items);
	display($dbg_ops, 0, "_doCut: $panel " . scalar(@items) . " item(s)");
}


#----------------------------------------------------
# _snapshotNodes / _snapshotDBNode / _snapshotE80Node
#----------------------------------------------------

sub _snapshotNodes
{
	my ($panel, @nodes) = @_;
	my @items;

	if ($panel eq 'e80')
	{
		my $wpmgr = _wpmgr();
		if (!$wpmgr)
		{
			error("_snapshotNodes: WPMGR not connected");
			return ();
		}
		for my $node (@nodes)
		{
			my $t = $node->{type} // '';
			if ($t eq 'header')
			{
				my $kind = $node->{kind} // '';
				if ($kind eq 'groups')
				{
					my $groups = $wpmgr->{groups} // {};
					for my $uuid (sort keys %$groups)
					{
						my $item = _snapshotE80Node($wpmgr, { type => 'group', uuid => $uuid, data => $groups->{$uuid} });
						push @items, $item if $item;
					}
				}
				elsif ($kind eq 'routes')
				{
					my $routes = $wpmgr->{routes} // {};
					for my $uuid (sort keys %$routes)
					{
						my $item = _snapshotE80Node($wpmgr, { type => 'route', uuid => $uuid, data => $routes->{$uuid} });
						push @items, $item if $item;
					}
				}
				elsif ($kind eq 'tracks')
				{
					my $track_svc = _track();
					my $tracks    = $track_svc ? ($track_svc->{tracks} // {}) : {};
					for my $uuid (sort keys %$tracks)
					{
						push @items, { type => 'track', uuid => $uuid, data => $tracks->{$uuid} };
					}
				}
			}
			else
			{
				my $item = _snapshotE80Node($wpmgr, $node);
				push @items, $item if $item;
			}
		}
	}
	else
	{
		my $dbh = connectDB();
		return () if !$dbh;
		for my $node (@nodes)
		{
			my $item = _snapshotDBNode($dbh, $node);
			push @items, $item if $item;
		}
		disconnectDB($dbh);
	}

	return @items;
}


sub _snapshotDBNode
{
	my ($dbh, $node) = @_;
	my $t    = $node->{type} // '';
	my $d    = $node->{data} // {};
	my $uuid = $d->{uuid} // $node->{uuid};

	if ($t eq 'route_point')
	{
		return {
			type       => 'route_point',
			uuid       => $node->{uuid},
			route_uuid => $node->{route_uuid},
			position   => $node->{position},
			data       => $d,
		};
	}

	if ($t eq 'object')
	{
		my $ot = $d->{obj_type} // '';
		if ($ot eq 'waypoint')
		{
			my $wp = getWaypoint($dbh, $uuid);
			return undef if !$wp;
			return { type => 'waypoint', uuid => $uuid, data => $wp };
		}
		if ($ot eq 'route')
		{
			my $r   = getRoute($dbh, $uuid);
			return undef if !$r;
			my $wps = getRouteWaypoints($dbh, $uuid) // [];
			my @rps = map {
				{
					type       => 'route_point',
					uuid       => $_->{uuid},
					route_uuid => $uuid,
					position   => $_->{position},
					data       => $_,
				}
			} @$wps;
			return { type => 'route', uuid => $uuid, data => $r, route_points => \@rps };
		}
		if ($ot eq 'track')
		{
			my $tr  = getTrack($dbh, $uuid);
			return undef if !$tr;
			my $pts = getTrackPoints($dbh, $uuid) // [];
			$tr->{points} = $pts;
			return { type => 'track', uuid => $uuid, data => $tr };
		}
		warning(0, 0, "_snapshotDBNode: unknown obj_type=$ot");
		return undef;
	}

	if ($t eq 'collection')
	{
		my $nt   = $d->{node_type} // '';
		my $coll = getCollection($dbh, $uuid);
		return undef if !$coll;
		if ($nt eq $NODE_TYPE_GROUP)
		{
			my $stubs   = getGroupWaypoints($dbh, $uuid) // [];
			my @members;
			for my $stub (@$stubs)
			{
				my $wp = getWaypoint($dbh, $stub->{uuid});
				push @members, { type => 'waypoint', uuid => $stub->{uuid}, data => $wp } if $wp;
			}
			return { type => 'group', uuid => $uuid, data => $coll, members => \@members };
		}
		else  # branch
		{
			my @members = _snapshotBranchContents($dbh, $uuid);
			return { type => 'branch', uuid => $uuid, data => $coll, members => \@members };
		}
	}

	warning(0, 0, "_snapshotDBNode: unhandled node type=$t");
	return undef;
}


sub _snapshotBranchContents
{
	my ($dbh, $branch_uuid) = @_;
	my @members;

	my $children = getCollectionChildren($dbh, $branch_uuid) // [];
	for my $child (@$children)
	{
		my $item = _snapshotDBNode($dbh, { type => 'collection', data => $child });
		push @members, $item if $item;
	}

	my $objects = getCollectionObjects($dbh, $branch_uuid) // [];
	for my $obj (@$objects)
	{
		my $item = _snapshotDBNode($dbh, { type => 'object', data => $obj });
		push @members, $item if $item;
	}

	return @members;
}


sub _snapshotE80Node
{
	my ($wpmgr, $node) = @_;
	my $t      = $node->{type} // '';
	my $uuid   = $node->{uuid};
	my $d      = $node->{data} // {};
	my $wps    = $wpmgr->{waypoints} // {};
	my $groups = $wpmgr->{groups}    // {};

	if ($t eq 'route_point')
	{
		return {
			type       => 'route_point',
			uuid       => $uuid,
			route_uuid => $node->{route_uuid},
			data       => _e80WpClipData($d),
		};
	}

	if ($t eq 'waypoint')
	{
		return { type => 'waypoint', uuid => $uuid, data => _e80WpClipData($d) };
	}

	if ($t eq 'group')
	{
		my @members;
		for my $wp_uuid (@{$d->{uuids} // []})
		{
			my $wp = $wps->{$wp_uuid};
			push @members, { type => 'waypoint', uuid => $wp_uuid, data => _e80WpClipData($wp) } if $wp;
		}
		return { type => 'group', uuid => $uuid, data => $d, members => \@members };
	}

	if ($t eq 'my_waypoints')
	{
		my %grouped;
		$grouped{$_} = 1 for map { @{$_->{uuids} // []} } values %$groups;
		my @members;
		for my $wp_uuid (grep { !$grouped{$_} } keys %$wps)
		{
			my $wp = $wps->{$wp_uuid};
			push @members, { type => 'waypoint', uuid => $wp_uuid, data => _e80WpClipData($wp) } if $wp;
		}
		return {
			type    => 'group',
			uuid    => undef,
			data    => { name => 'My Waypoints' },
			members => \@members,
		};
	}

	if ($t eq 'route')
	{
		my $routes = $wpmgr->{routes} // {};
		my $r = $routes->{$uuid} // $d;
		my @rps;
		my $pos = 0;
		for my $wp_uuid (@{$r->{uuids} // []})
		{
			my $wp = $wps->{$wp_uuid};
			push @rps, {
				type       => 'route_point',
				uuid       => $wp_uuid,
				route_uuid => $uuid,
				position   => $pos++,
				data       => ($wp ? _e80WpClipData($wp) : {}),
			};
		}
		return { type => 'route', uuid => $uuid, data => $r, route_points => \@rps };
	}

	if ($t eq 'track')
	{
		return { type => 'track', uuid => $uuid, data => $d };
	}

	warning(0, 0, "_snapshotE80Node: unhandled node type=$t");
	return undef;
}


#----------------------------------------------------
# _doDelete
#----------------------------------------------------

sub _doDelete
{
	my ($cmd_id, $panel, $right_click_node, $tree, @nodes) = @_;
	@nodes = ($right_click_node) if !@nodes;

	# Pre-flight SS8: branch-safety check
	if ($panel eq 'database' && $cmd_id == $CTX_CMD_DELETE_BRANCH)
	{
		my $uuid = ($right_click_node->{data} // {})->{uuid};
		my $name = ($right_click_node->{data} // {})->{name} // '?';
		my $dbh  = connectDB();
		return if !$dbh;
		my $safe = isBranchDeleteSafe($dbh, $uuid);
		disconnectDB($dbh);
		if (!$safe)
		{
			error("Cannot delete '$name': waypoints are referenced by external routes");
			return;
		}
	}

	if ($panel eq 'e80')
	{
		navOps::_deleteE80($cmd_id, $right_click_node, $tree, @nodes);
	}
	else
	{
		navOps::_deleteDB($cmd_id, $right_click_node, $tree, @nodes);
	}
	clearClipboard();
}


#----------------------------------------------------
# _doPaste - full pre-flight (SS6, SS10) then dispatch
#----------------------------------------------------

sub _doPaste
{
	my ($cmd_id, $panel, $right_click_node, $tree, @nodes) = @_;

	my $cb = $clipboard;
	if (!$cb || !@{$cb->{items} // []})
	{
		warning(0, 0, "_doPaste: clipboard is empty");
		return;
	}

	my $source = $cb->{source} // '';

	# PASTE_BEFORE/AFTER on a root-level collection has no parent to insert into
	if (($cmd_id == $CTX_CMD_PASTE_BEFORE    || $cmd_id == $CTX_CMD_PASTE_AFTER ||
	     $cmd_id == $CTX_CMD_PASTE_NEW_BEFORE || $cmd_id == $CTX_CMD_PASTE_NEW_AFTER)
	 && ($right_click_node->{type} // '') eq 'collection')
	{
		my $dbh = connectDB();
		if ($dbh)
		{
			my $rec = getCollection($dbh, ($right_click_node->{data} // {})->{uuid} // '');
			disconnectDB($dbh);
			if ($rec && !defined $rec->{parent_uuid})
			{
				error("Cannot paste before/after a root-level branch -- use Paste to add items to it");
				return;
			}
		}
	}

	# D-CT-DB => E80 is always rejected
	if ($panel eq 'e80' && $cb->{cut_flag} && $source eq 'database')
	{
		error("Cannot paste a database Cut to E80");
		return;
	}

	# SS10.8: E80 tracks header is not a valid paste destination
	if ($panel eq 'e80'
	 && ($right_click_node->{type} // '') eq 'header'
	 && ($right_click_node->{kind} // '') eq 'tracks')
	{
		error("Cannot paste to E80 tracks header -- tracks are read-only");
		return;
	}

	# Step 1: Ancestor-wins resolution (SS6.2)
	my @orig_items = @{$cb->{items}};
	my @resolved   = _resolveAncestorWins(\@orig_items);
	if (scalar(@resolved) != scalar(@orig_items))
	{
		my $absorbed = scalar(@orig_items) - scalar(@resolved);
		my $msg = "$absorbed item(s) were absorbed by an ancestor also in the clipboard.\n"
		        . "Proceeding with " . scalar(@resolved) . " item(s).";
		my $proceed = $nmDialogs::suppress_confirm
			? ($nmDialogs::suppress_outcome eq 'reject' ? 0 : 1)
			: confirmDialog($tree, $msg, 'Clipboard Resolution');
		return if !$proceed;
	}

	# Step 2: Empty guard
	if (!@resolved)
	{
		error("No items to paste after clipboard resolution");
		return;
	}

	# Step 3: Recursive paste check (SS1.5) -- walk full ancestor chain.
	# For PASTE_BEFORE/AFTER the right_click_node is the anchor, not the destination;
	# skip the self-uuid check so a node can be pasted before/after its own clipboard copy.
	# Ancestor walk still runs to block truly circular pastes (e.g. branch copied, then
	# pasted before/after one of its own descendants).
	my %clip_uuids = map { ($_->{uuid} // '') => 1 } grep { $_->{uuid} } @resolved;
	my $skip_self  = ($cmd_id == $CTX_CMD_PASTE_BEFORE    || $cmd_id == $CTX_CMD_PASTE_AFTER ||
	                  $cmd_id == $CTX_CMD_PASTE_NEW_BEFORE || $cmd_id == $CTX_CMD_PASTE_NEW_AFTER) ? 1 : 0;
	if (($right_click_node->{type} // '') ne 'route_point'
	 && _destIsDescendantOfClipboard($right_click_node, $panel, \%clip_uuids, $skip_self))
	{
		error("Cannot paste: destination is a descendant of an item in the clipboard");
		return;
	}

	# Step 4: Route dependency check (SS10.1 Step 4)
	my @routes_in_clip = grep { ($_->{type} // '') eq 'route' } @resolved;
	if (@routes_in_clip)
	{
		my %clip_wp_uuids;
		for my $ci (@resolved)
		{
			my $ct = $ci->{type} // '';
			if ($ct eq 'waypoint')
			{
				$clip_wp_uuids{$ci->{uuid}} = 1 if $ci->{uuid};
			}
			elsif ($ct eq 'group')
			{
				$clip_wp_uuids{$_->{uuid}} = 1 for grep { $_->{uuid} } @{$ci->{members} // []};
			}
		}
		if ($panel eq 'e80')
		{
			my $wpmgr_dep = _wpmgr();
			for my $route (@routes_in_clip)
			{
				my @missing;
				for my $rp (@{$route->{route_points} // []})
				{
					my $u = $rp->{uuid} // '';
					push @missing, $u if !$clip_wp_uuids{$u} && !($wpmgr_dep && $wpmgr_dep->{waypoints}{$u});
				}
				if (@missing)
				{
					my $rname = ($route->{data} // {})->{name} // $route->{uuid};
					error("Route '$rname': member waypoint(s) not on E80 and not in clipboard: "
					    . join(', ', @missing));
					return;
				}
			}
		}
		else
		{
			my $dep_dbh = connectDB();
			return if !$dep_dbh;
			for my $route (@routes_in_clip)
			{
				my @missing;
				for my $rp (@{$route->{route_points} // []})
				{
					my $u = $rp->{uuid} // '';
					if (!$clip_wp_uuids{$u})
					{
						my $wp = getWaypoint($dep_dbh, $u);
						push @missing, $u if !$wp;
					}
				}
				if (@missing)
				{
					disconnectDB($dep_dbh);
					my $rname = ($route->{data} // {})->{name} // $route->{uuid};
					error("Route '$rname': member waypoint(s) not in database and not in clipboard: "
					    . join(', ', @missing));
					return;
				}
			}
			disconnectDB($dep_dbh);
		}
	}

	if ($panel eq 'e80')
	{
		# Step 5: Branch dissolution (SS6.3)
		my @effective;
		for my $item (@resolved)
		{
			if (($item->{type} // '') eq 'branch')
			{
				push @effective, @{$item->{members} // []};
			}
			else
			{
				push @effective, $item;
			}
		}

		# Step 6: Homogeneity check
		my %types = map { ($_->{type} // '') => 1 } @effective;
		my @type_list = keys %types;
		if (@type_list > 1)
		{
			my $mixed_wp_group = (scalar(@type_list) == 2 && $types{waypoint} && $types{group});
			if (!$mixed_wp_group)
			{
				error("E80 paste requires homogeneous content (cannot mix routes, tracks, and waypoints)");
				return;
			}
		}

		# Step 7: Intra-clipboard name collision
		my %seen;
		for my $item (@effective)
		{
			my $t    = $item->{type} // '';
			my $name = ($item->{data} // {})->{name} // '';
			my $key  = "$t:$name";
			if ($seen{$key})
			{
				error("Clipboard contains duplicate $t name '$name' -- aborting");
				return;
			}
			$seen{$key} = 1;
		}

		# Step 8: E80-wide name collision
		my $wpmgr = _wpmgr();
		if ($wpmgr)
		{
			my $e80_wps    = $wpmgr->{waypoints} // {};
			my $e80_groups = $wpmgr->{groups}    // {};
			my $e80_routes = $wpmgr->{routes}    // {};
			for my $item (@effective)
			{
				my $t    = $item->{type} // '';
				my $name = ($item->{data} // {})->{name} // '';
				next if !$name;
				if ($t eq 'waypoint' && grep { ($_->{name} // '') eq $name } values %$e80_wps)
				{
					# Inserting into a route (or before/after a route_point) uses the existing
					# WP UUID by reference -- no new WP is created, so the name check is moot.
					my $dest_type = $right_click_node->{type} // '';
					next if ($dest_type eq 'route' || $dest_type eq 'route_point')
					     && $wpmgr->{waypoints}{$item->{uuid} // ''};
					error("E80 already has a waypoint named '$name' -- aborting");
					return;
				}
				if ($t eq 'group' && grep { ($_->{name} // '') eq $name } values %$e80_groups)
				{
					error("E80 already has a group named '$name' -- aborting");
					return;
				}
				if ($t eq 'route' && grep { ($_->{name} // '') eq $name } values %$e80_routes)
				{
					error("E80 already has a route named '$name' -- aborting");
					return;
				}
			}
		}

		if (($cb->{source} // '') eq 'database')
		{
			my $paste_issues = _preflightLossyTransform(\@effective, 'db_to_e80');
			if (_hasLossyIssues($paste_issues))
			{
				return if !nmDialogs::lossyTransformWarning($tree, $paste_issues);
			}
		}
		navOps::_pasteE80($cmd_id, $right_click_node, $tree, \@effective, $cb);
	}
	else
	{
		navOps::_pasteDB($cmd_id, $right_click_node, $tree, \@resolved, $cb);
	}
	clearClipboard() if $cb->{cut_flag};
}


sub _resolveAncestorWins
{
	my ($items) = @_;
	my @result;
	for my $item (@$items)
	{
		my $uuid     = $item->{uuid} // '';
		my $absorbed = 0;
		if ($uuid)
		{
			for my $other (@$items)
			{
				next if ($other->{uuid} // '') eq $uuid;
				my @sub = (@{$other->{members} // []}, @{$other->{route_points} // []});
				if (grep { ($_->{uuid} // '') eq $uuid } @sub)
				{
					$absorbed = 1;
					last;
				}
			}
		}
		push @result, $item if !$absorbed;
	}
	return @result;
}


#----------------------------------------------------
# _doPush
#----------------------------------------------------

sub _doPush
{
	my ($panel, $right_click_node, $tree, @nodes) = @_;

	if ($panel eq 'e80')
	{
		# Direct push: E80 selection -> DB
		my @items = _snapshotNodes($panel, @nodes);
		if (!@items)
		{
			warning(0, 0, "_doPush: nothing to push");
			return;
		}
		my $n       = scalar @items;
		my $msg     = "Push $n item(s) from E80 to database?";
		my $proceed = $nmDialogs::suppress_confirm
			? 1
			: confirmDialog($tree, $msg, 'Push');
		return if !$proceed;
		my $issues = _preflightLossyTransform(\@items, 'e80_to_db');
		if (_hasLossyIssues($issues))
		{
			return if !nmDialogs::lossyTransformWarning($tree, $issues);
		}
		navOps::_pushFromE80($right_click_node, $tree, \@items);
		return;
	}

	# DB panel: check for clipboard-triggered push (E80->DB) first
	my $cb = $clipboard;
	if ($cb && ($cb->{clipboard_class} // '') eq 'push')
	{
		my @items = @{$cb->{items} // []};
		if (!@items)
		{
			warning(0, 0, "_doPush: empty clipboard");
			return;
		}
		my $n       = scalar @items;
		my $msg     = "Push $n item(s) from E80 to database?";
		my $proceed = $nmDialogs::suppress_confirm
			? 1
			: confirmDialog($tree, $msg, 'Push');
		return if !$proceed;
		my $cb_issues = _preflightLossyTransform(\@items, 'e80_to_db');
		if (_hasLossyIssues($cb_issues))
		{
			return if !nmDialogs::lossyTransformWarning($tree, $cb_issues);
		}
		navOps::_pushFromE80($right_click_node, $tree, \@items);
		clearClipboard();
		return;
	}

	# DB panel: direct push DB -> E80
	my @db_items = _snapshotNodes('database', @nodes);
	if (!@db_items)
	{
		warning(0, 0, "_doPush: nothing to push");
		return;
	}
	my $n2      = scalar @db_items;
	my $msg2    = "Push $n2 item(s) from database to E80?";
	my $proceed2 = $nmDialogs::suppress_confirm
		? 1
		: confirmDialog($tree, $msg2, 'Push');
	return if !$proceed2;
	my $db_issues = _preflightLossyTransform(\@db_items, 'db_to_e80');
	if (_hasLossyIssues($db_issues))
	{
		return if !nmDialogs::lossyTransformWarning($tree, $db_issues);
	}
	navOps::_pushToE80($right_click_node, $tree, \@db_items);
}


#----------------------------------------------------
# _destIsDescendantOfClipboard
#----------------------------------------------------

sub _destIsDescendantOfClipboard
{
	my ($node, $panel, $clip_uuids, $skip_self) = @_;
	return 0 if !$node;

	# Collection tree nodes store uuid only in data->{uuid}, not at top level.
	my $node_uuid = $node->{uuid} // ($node->{data} // {})->{uuid} // '';
	return 1 if !$skip_self && $clip_uuids->{$node_uuid};

	if ($panel eq 'database')
	{
		return 0 if !$node_uuid;

		my $dbh = connectDB();
		return 0 if !$dbh;

		# getCollectionChildren omits parent_uuid from its SELECT, so tree node data
		# never carries parent_uuid.  Fetch the full record to start the ancestor walk.
		my $coll        = getCollection($dbh, $node_uuid);
		my $parent_uuid = $coll ? $coll->{parent_uuid} : undef;

		while ($parent_uuid)
		{
			if ($clip_uuids->{$parent_uuid})
			{
				disconnectDB($dbh);
				return 1;
			}
			$coll = getCollection($dbh, $parent_uuid);
			last if !$coll;
			$parent_uuid = $coll->{parent_uuid};
		}
		disconnectDB($dbh);
	}
	else  # e80 -- shallow hierarchy
	{
		my $group_uuid = $node->{group_uuid} // '';
		return 1 if $group_uuid && $clip_uuids->{$group_uuid};
	}
	return 0;
}


#----------------------------------------------------
# _doNew
#----------------------------------------------------

sub _doNew
{
	my ($cmd_id, $panel, $right_click_node, $tree) = @_;
	my $parent_uuid = ($right_click_node->{data} // {})->{uuid};

	if ($cmd_id == $CTX_CMD_NEW_BRANCH)
	{
		# Branch only valid in database panel
		my $dlg = Wx::TextEntryDialog->new($tree // getAppFrame(), 'Branch name:', 'New Branch', '');
		if ($dlg->ShowModal() == wxID_OK)
		{
			my $name = $dlg->GetValue() // '';
			if ($name ne '')
			{
				my $dbh = connectDB();
				if ($dbh)
				{
					my @new_pos = computePushDownPositions($dbh, $parent_uuid, 1);
					insertCollection($dbh, $name, $parent_uuid, $NODE_TYPE_BRANCH, '', $new_pos[0]);
					disconnectDB($dbh);
					_refreshDatabase();
				}
			}
		}
		$dlg->Destroy();
	}
	elsif ($cmd_id == $CTX_CMD_NEW_GROUP)
	{
		if ($panel eq 'database')
		{
			my $dlg = Wx::TextEntryDialog->new($tree // getAppFrame(), 'Group name:', 'New Group', '');
			if ($dlg->ShowModal() == wxID_OK)
			{
				my $name = $dlg->GetValue() // '';
				if ($name ne '')
				{
					my $dbh = connectDB();
					if ($dbh)
					{
						my @new_pos = computePushDownPositions($dbh, $parent_uuid, 1);
						insertCollection($dbh, $name, $parent_uuid, $NODE_TYPE_GROUP, '', $new_pos[0]);
						disconnectDB($dbh);
						_refreshDatabase();
					}
				}
			}
			$dlg->Destroy();
		}
		else
		{
			navOps::_newE80Group($right_click_node, $tree);
		}
	}
	elsif ($cmd_id == $CTX_CMD_NEW_ROUTE)
	{
		if ($panel eq 'database')
		{
			navOps::_newDatabaseRoute($right_click_node, $tree);
		}
		else
		{
			navOps::_newE80Route($right_click_node, $tree);
		}
	}
	elsif ($cmd_id == $CTX_CMD_NEW_WAYPOINT)
	{
		if ($panel eq 'database')
		{
			navOps::_newDatabaseWaypoint($right_click_node, $tree);
		}
		else
		{
			navOps::_newE80Waypoint($right_click_node, $tree);
		}
	}
	else
	{
		warning(0, 0, "_doNew: unhandled cmd_id=$cmd_id");
	}
}


#----------------------------------------------------
# Color conversion helpers
#----------------------------------------------------

sub e80ColorIndexToAbgr { $E80_ROUTE_COLOR_ABGR[$_[0] // 0] // $E80_ROUTE_COLOR_ABGR[0] }


#----------------------------------------------------
# _preflightLossyTransform / _hasLossyIssues
#----------------------------------------------------

sub _hasLossyIssues
{
	my ($issues) = @_;
	return @{$issues->{truncated_names}    // []}
	    || @{$issues->{truncated_comments} // []}
	    || @{$issues->{color_mismatch}     // []};
}

sub _preflightLossyTransform
{
	my ($items, $direction) = @_;
	my (@trunc_names, @trunc_comments, @color_mismatch);

	my $dbh = ($direction eq 'e80_to_db') ? connectDB() : undef;

	for my $item (@$items)
	{
		my $t    = $item->{type} // '';
		my $d    = $item->{data} // {};
		my $name = $d->{name}   // '';

		if ($direction eq 'db_to_e80')
		{
			push @trunc_names, $name
				if length($name) > $E80_MAX_NAME;
			push @trunc_comments, $name
				if length($d->{comment} // '') > $E80_MAX_COMMENT;

			if ($t eq 'group')
			{
				for my $m (@{$item->{members} // []})
				{
					my $md = $m->{data} // {};
					my $mn = $md->{name} // '';
					push @trunc_names, $mn
						if length($mn) > $E80_MAX_NAME;
					push @trunc_comments, $mn
						if length($md->{comment} // '') > $E80_MAX_COMMENT;
				}
			}

			push @color_mismatch, $name
				if $t eq 'route' && !isExactE80Color($d->{color} // '');
		}
		elsif ($direction eq 'e80_to_db' && $dbh)
		{
			if ($t eq 'route' || $t eq 'track')
			{
				my $new_abgr = e80ColorIndexToAbgr($d->{color} // 0);
				my $existing = ($t eq 'route')
					? getRoute($dbh, $item->{uuid} // '')
					: getTrack($dbh, $item->{uuid} // '');
				if ($existing)
				{
					my $db_color = lc($existing->{color} // '');
					push @color_mismatch, $name
						if $db_color ne '' && $db_color ne lc($new_abgr);
				}
			}
		}
	}

	disconnectDB($dbh) if $dbh;

	return {
		truncated_names    => \@trunc_names,
		truncated_comments => \@trunc_comments,
		color_mismatch     => \@color_mismatch,
	};
}


#----------------------------------------------------
# _cmdLabel
#----------------------------------------------------

sub _cmdLabel
{
	my ($cmd_id) = @_;
	return 'COPY'              if $cmd_id == $CTX_CMD_COPY;
	return 'CUT'               if $cmd_id == $CTX_CMD_CUT;
	return 'PASTE'             if $cmd_id == $CTX_CMD_PASTE;
	return 'PASTE NEW'         if $cmd_id == $CTX_CMD_PASTE_NEW;
	return 'PASTE BEFORE'      if $cmd_id == $CTX_CMD_PASTE_BEFORE;
	return 'PASTE AFTER'       if $cmd_id == $CTX_CMD_PASTE_AFTER;
	return 'PASTE NEW BEFORE'  if $cmd_id == $CTX_CMD_PASTE_NEW_BEFORE;
	return 'PASTE NEW AFTER'   if $cmd_id == $CTX_CMD_PASTE_NEW_AFTER;
	return 'DELETE WAYPOINT'   if $cmd_id == $CTX_CMD_DELETE_WAYPOINT;
	return 'DELETE GROUP'      if $cmd_id == $CTX_CMD_DELETE_GROUP;
	return 'DELETE GROUP+WPS'  if $cmd_id == $CTX_CMD_DELETE_GROUP_WPS;
	return 'DELETE ROUTE'      if $cmd_id == $CTX_CMD_DELETE_ROUTE;
	return 'REMOVE ROUTEPOINT' if $cmd_id == $CTX_CMD_REMOVE_ROUTEPOINT;
	return 'DELETE TRACK'      if $cmd_id == $CTX_CMD_DELETE_TRACK;
	return 'DELETE BRANCH'     if $cmd_id == $CTX_CMD_DELETE_BRANCH;
	return 'NEW WAYPOINT'      if $cmd_id == $CTX_CMD_NEW_WAYPOINT;
	return 'NEW GROUP'         if $cmd_id == $CTX_CMD_NEW_GROUP;
	return 'NEW ROUTE'         if $cmd_id == $CTX_CMD_NEW_ROUTE;
	return 'NEW BRANCH'        if $cmd_id == $CTX_CMD_NEW_BRANCH;
	return 'PUSH'              if $cmd_id == $CTX_CMD_PUSH;
	return "CMD_$cmd_id";
}


1;
