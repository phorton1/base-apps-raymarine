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
use navFSH qw(fshToNavUUID navToFSHUUID);
use n_defs;
use n_utils;
use nmResources;
use navClipboard;
use nmDialogs;

require navOpsDB;
require navOpsE80;
require navOpsFSH;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		buildContextMenu
		onContextMenuCommand
		dispatchNavOpsCommand
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

sub _fshDb
{
	return $navFSH::fsh_db;
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

sub _refreshFSH
{
	# Single chokepoint called by all FSH-side mutation handlers in
	# navOpsFSH.pm after a successful mutation.  Marks the FSH document
	# dirty here so every navOps path participates uniformly.
	navFSH::markDirty();
	my $frame = getAppFrame();
	return if !$frame;
	my $fsh = $frame->findPane($WIN_FSH);
	$fsh->refresh() if $fsh;
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

	my $peers = { wpmgr => _wpmgr(), fsh_db => _fshDb() };
	my @del   = getDeleteMenuItems($panel, $right_click_node, @nodes);
	my @new   = getNewMenuItems($panel, $right_click_node);
	my @copy  = getCopyMenuItems($panel, @nodes);
	my @cut   = getCutMenuItems($panel, @nodes);
	my @push  = getPushMenuItems($panel, $peers, @nodes);
	my @paste = getPasteMenuItems($panel, $right_click_node);

	# SS10.10: suppress PASTE and PASTE_NEW when any route in clipboard has member WPs
	# absent from the destination spoke -- user must paste the WPs first, then retry.
	if (($panel eq 'e80' || $panel eq 'fsh')
	 && ((grep { $_->{id} == $CTX_CMD_PASTE     } @paste)
	  || (grep { $_->{id} == $CTX_CMD_PASTE_NEW } @paste)))
	{
		my $missing = _routeMembersMissingAtSpoke($panel);
		@paste = grep { $_->{id} != $CTX_CMD_PASTE && $_->{id} != $CTX_CMD_PASTE_NEW } @paste
			if $missing;
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
	my %context = (
		panel            => $panel,
		right_click_node => $right_click_node,
		tree             => $tree,
		nodes            => \@nodes,
	);
	dispatchNavOpsCommand(\%context, $cmd_id);
}


sub dispatchNavOpsCommand
{
	my ($context, $cmd_id) = @_;
	my $panel            = $context->{panel};
	my $right_click_node = $context->{right_click_node};
	my $tree             = $context->{tree};
	my @nodes            = @{ $context->{nodes} // [] };

	my $label = _cmdLabel($cmd_id);

	# UI-layer markers -- magenta start/finish lines that the testplan
	# and monitoring tooling observe to bound an operation in the log.
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
	elsif ($cmd_id == $CTX_CMD_PUSH
	    || $cmd_id == $CTX_CMD_PUSH_FSH
	    || $cmd_id == $CTX_CMD_PUSH_E80)
	{
		_doPush($cmd_id, $panel, $right_click_node, $tree, @nodes);
	}
	else
	{
		warning(0, 0, "navOps: unknown cmd_id=$cmd_id");
	}

	display(-1, 0, "===== $label ($panel) FINISHED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
}


#----------------------------------------------------
# _routeMembersMissingAtSpoke -- SS10.10 helper
#----------------------------------------------------
# Returns 1 iff the clipboard contains a route whose member waypoint
# UUIDs are not all present at the destination spoke.  Used by
# buildContextMenu to suppress PASTE / PASTE_NEW when a route can't
# be created because its WPs aren't there yet.  Clipboard item UUIDs
# are always navMate no-dash form; this function converts at the seam
# when checking the FSH spoke.

sub _routeMembersMissingAtSpoke
{
	my ($panel) = @_;
	return 0 if !$clipboard;
	if ($panel eq 'e80')
	{
		my $wpmgr = _wpmgr();
		return 0 if !$wpmgr;
		for my $cb_item (@{$clipboard->{items} // []})
		{
			next if ($cb_item->{type} // '') ne 'route';
			for my $rp (@{$cb_item->{route_points} // []})
			{
				return 1 if !$wpmgr->{waypoints}{$rp->{uuid}};
			}
		}
		return 0;
	}
	if ($panel eq 'fsh')
	{
		my $db = _fshDb();
		return 0 if !$db;
		my $wps = $db->{waypoints} // {};
		# A WP in FSH-db is either a standalone BLK_WPT or embedded in
		# a group's wpts array.  Build the full set of available UUIDs.
		my %have;
		$have{$_} = 1 for keys %$wps;
		for my $grp (values %{$db->{groups} // {}})
		{
			$have{$_->{uuid}} = 1 for grep { $_->{uuid} } @{$grp->{wpts} // []};
		}
		for my $cb_item (@{$clipboard->{items} // []})
		{
			next if ($cb_item->{type} // '') ne 'route';
			for my $rp (@{$cb_item->{route_points} // []})
			{
				my $fsh_uuid = navToFSHUUID($rp->{uuid});
				return 1 if !$have{$fsh_uuid};
			}
		}
		return 0;
	}
	return 0;
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
	elsif ($panel eq 'fsh')
	{
		my $db = _fshDb();
		if (!$db)
		{
			error("_snapshotNodes: FSH-db not loaded");
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
					my $groups = $db->{groups} // {};
					for my $uuid (sort keys %$groups)
					{
						my $item = _snapshotFSHNode($db, { type => 'group', uuid => $uuid, data => $groups->{$uuid} });
						push @items, $item if $item;
					}
				}
				elsif ($kind eq 'routes')
				{
					my $routes = $db->{routes} // {};
					for my $uuid (sort keys %$routes)
					{
						my $item = _snapshotFSHNode($db, { type => 'route', uuid => $uuid, data => $routes->{$uuid} });
						push @items, $item if $item;
					}
				}
				elsif ($kind eq 'tracks')
				{
					my $tracks = $db->{tracks} // {};
					for my $uuid (sort keys %$tracks)
					{
						my $item = _snapshotFSHNode($db, { type => 'track', uuid => $uuid, data => $tracks->{$uuid} });
						push @items, $item if $item;
					}
				}
			}
			elsif ($t eq 'track_group')
			{
				# Expand a winFSH visual rollup (e.g. "TrackName" containing
				# TrackName-001 .. TrackName-NNN) into its constituent tracks.
				my $tracks = $db->{tracks} // {};
				for my $tuuid (@{$node->{uuids} // []})
				{
					my $td = $tracks->{$tuuid};
					next if !$td;
					my $item = _snapshotFSHNode($db, { type => 'track', uuid => $tuuid, data => $td });
					push @items, $item if $item;
				}
			}
			else
			{
				my $item = _snapshotFSHNode($db, $node);
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


sub _snapshotFSHNode
{
	# UUID normalization seam:  FSH-db hashes are keyed by FSH-form
	# (dashed-uppercase) UUIDs; clipboard items always carry navMate-
	# form (no-dash lowercase).  This function converts at the seam.
	# Field shapes (decimal-degree lat/lon, timestamps, depth, temp_k
	# on waypoints) are already canonical in FSH-db.
	my ($db, $node) = @_;
	my $t        = $node->{type} // '';
	my $fsh_uuid = $node->{uuid};
	my $d        = $node->{data} // {};
	my $uuid     = $fsh_uuid ? fshToNavUUID($fsh_uuid) : undef;

	if ($t eq 'route_point')
	{
		my $route_uuid = $node->{route_uuid} ? fshToNavUUID($node->{route_uuid}) : undef;
		return {
			type       => 'route_point',
			uuid       => $uuid,
			route_uuid => $route_uuid,
			data       => _fshWpClipData($d),
		};
	}

	if ($t eq 'waypoint')
	{
		return { type => 'waypoint', uuid => $uuid, data => _fshWpClipData($d) };
	}

	if ($t eq 'group')
	{
		my @members;
		for my $wp (@{$d->{wpts} // []})
		{
			my $mu = $wp->{uuid} ? fshToNavUUID($wp->{uuid}) : undef;
			push @members, { type => 'waypoint', uuid => $mu, data => _fshWpClipData($wp) };
		}
		# Group's own data carries the FSH-form uuid; convert for the
		# snapshot.  Name field is canonical (FSH writer/reader strip
		# Z16 padding per fsh-name-comment-limits memory).
		my $group_data = { %$d, uuid => $uuid };
		return { type => 'group', uuid => $uuid, data => $group_data, members => \@members };
	}

	if ($t eq 'my_waypoints')
	{
		# Standalone WPs only (those keyed in $db->{waypoints}); group
		# members are NOT under My Waypoints in the FSH model.
		my $wps = $db->{waypoints} // {};
		my @members;
		for my $wp_fsh_uuid (sort keys %$wps)
		{
			my $wp = $wps->{$wp_fsh_uuid};
			my $mu = fshToNavUUID($wp_fsh_uuid);
			push @members, { type => 'waypoint', uuid => $mu, data => _fshWpClipData($wp) };
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
		my @rps;
		my $pos = 0;
		for my $wp (@{$d->{wpts} // []})
		{
			my $wp_uuid = $wp->{uuid} ? fshToNavUUID($wp->{uuid}) : undef;
			push @rps, {
				type       => 'route_point',
				uuid       => $wp_uuid,
				route_uuid => $uuid,
				position   => $pos++,
				data       => _fshWpClipData($wp),
			};
		}
		my $route_data = { %$d, uuid => $uuid };
		return { type => 'route', uuid => $uuid, data => $route_data, route_points => \@rps };
	}

	if ($t eq 'track')
	{
		# FSH tracks carry mta_uuid as the identity UUID; trk_uuid is
		# secondary.  Both convert to navMate form.  Points already
		# carry decimal-degree lat/lon.
		my $track_data = { %$d };
		$track_data->{uuid}     = $uuid if defined $uuid;
		$track_data->{mta_uuid} = fshToNavUUID($d->{mta_uuid}) if $d->{mta_uuid};
		$track_data->{trk_uuid} = fshToNavUUID($d->{trk_uuid}) if $d->{trk_uuid};
		return { type => 'track', uuid => $uuid, data => $track_data };
	}

	warning(0, 0, "_snapshotFSHNode: unhandled node type=$t");
	return undef;
}


sub _fshWpClipData
{
	# Normalize an FSH waypoint record to clipboard shape:
	# - UUID in navMate no-dash lowercase form
	# - keep canonical fields (lat, lon, sym, name, comment, depth,
	#   temp_k, date, time, color) intact -- FSH stores them in the
	#   same scales as the canonical clipboard form (no E80-style
	#   1e7 lat/lon conversion needed; depth in cm; temp_k in K*100).
	my ($d) = @_;
	$d //= {};
	my $clip = { %$d };
	$clip->{uuid} = fshToNavUUID($d->{uuid}) if $d->{uuid};
	return $clip;
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
	elsif ($panel eq 'fsh')
	{
		navOps::_deleteFSH($cmd_id, $right_click_node, $tree, @nodes);
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

	my $is_spoke = ($panel eq 'e80' || $panel eq 'fsh');

	# DB Cut -> spoke is always rejected: removing the DB record loses
	# canonical state.  Same rule for E80 and FSH destinations.
	if ($is_spoke && $cb->{cut_flag} && $source eq 'database')
	{
		error("Cannot paste a database Cut to " . uc($panel));
		return;
	}

	# SS10.8: tracks header is not a valid paste destination on E80
	# (tracks are E80-assigned UUIDs, read-only via WPMGR/TRACK).  FSH
	# allows track writes via _pasteTrackToFSH (FSH is a file archive,
	# not a service).
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
		elsif ($panel eq 'fsh')
		{
			# FSH spoke: clipboard items carry navMate-form UUIDs.  Build the
			# set of nav-form WP UUIDs present at the FSH destination
			# (standalone $db->{waypoints} keys plus group-embedded WPs,
			# both converted out of FSH dashed-upper form).
			my $db = _fshDb();
			my %fsh_have;
			if ($db)
			{
				$fsh_have{fshToNavUUID($_)} = 1 for keys %{$db->{waypoints} // {}};
				for my $grp (values %{$db->{groups} // {}})
				{
					for my $wp (@{$grp->{wpts} // []})
					{
						$fsh_have{fshToNavUUID($wp->{uuid})} = 1 if $wp->{uuid};
					}
				}
			}
			for my $route (@routes_in_clip)
			{
				my @missing;
				for my $rp (@{$route->{route_points} // []})
				{
					my $u = $rp->{uuid} // '';
					push @missing, $u if !$clip_wp_uuids{$u} && !$fsh_have{$u};
				}
				if (@missing)
				{
					my $rname = ($route->{data} // {})->{name} // $route->{uuid};
					error("Route '$rname': member waypoint(s) not in FSH and not in clipboard: "
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

	if ($is_spoke)
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
				error(uc($panel) . " paste requires homogeneous content (cannot mix routes, tracks, and waypoints)");
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

		# Step 8: Spoke-wide name collision.  The *_names hashes are
		# name -> UUID maps (navMate canonical form).  Skip the collision
		# when the matching name on the spoke is already at the SAME UUID
		# as the clipboard item (in-place update / no-op same-UUID round-
		# trip).  Real collision = same name at a different UUID.  Also
		# preserves the WP-already-present-as-route-member exception for
		# WP pastes targeted at a route or route_point destination.
		my ($spoke_wp_names, $spoke_grp_names, $spoke_rte_names, $spoke_have_uuid)
			= _spokeNameAndUUIDSets($panel);
		if ($spoke_wp_names)
		{
			for my $item (@effective)
			{
				my $t         = $item->{type} // '';
				my $name      = ($item->{data} // {})->{name} // '';
				my $clip_uuid = $item->{uuid} // '';
				next if !$name;
				if ($t eq 'waypoint' && exists $spoke_wp_names->{$name})
				{
					my $exist_uuid = $spoke_wp_names->{$name} // '';
					next if $exist_uuid eq $clip_uuid;
					my $dest_type = $right_click_node->{type} // '';
					next if ($dest_type eq 'route' || $dest_type eq 'route_point')
					     && $spoke_have_uuid->{$clip_uuid};
					error(uc($panel) . " already has a waypoint named '$name' -- aborting");
					return;
				}
				if ($t eq 'group' && exists $spoke_grp_names->{$name})
				{
					my $exist_uuid = $spoke_grp_names->{$name} // '';
					next if $exist_uuid eq $clip_uuid;
					error(uc($panel) . " already has a group named '$name' -- aborting");
					return;
				}
				if ($t eq 'route' && exists $spoke_rte_names->{$name})
				{
					my $exist_uuid = $spoke_rte_names->{$name} // '';
					next if $exist_uuid eq $clip_uuid;
					error(uc($panel) . " already has a route named '$name' -- aborting");
					return;
				}
			}
		}

		if (($cb->{source} // '') eq 'database')
		{
			my $direction = ($panel eq 'e80') ? 'db_to_e80' : 'db_to_fsh';
			my $paste_issues = _preflightLossyTransform(\@effective, $direction);
			if (_hasLossyIssues($paste_issues))
			{
				return if !nmDialogs::lossyTransformWarning($tree, $paste_issues);
			}
		}
		if ($panel eq 'e80')
		{
			navOps::_pasteE80($cmd_id, $right_click_node, $tree, \@effective, $cb);
		}
		else
		{
			navOps::_pasteFSH($cmd_id, $right_click_node, $tree, \@effective, $cb);
		}
	}
	else
	{
		navOps::_pasteDB($cmd_id, $right_click_node, $tree, \@resolved, $cb);
	}
	clearClipboard() if $cb->{cut_flag};
}


#----------------------------------------------------
# _spokeNameAndUUIDSets -- helper for SS10.2 step 8
#----------------------------------------------------
# Returns (\%wp_names, \%grp_names, \%rte_names, \%have_uuid) for the
# named spoke.  Names are per-type sets keyed by name string.  have_uuid
# is a set of UUIDs present at the spoke (navMate no-dash form),
# combining standalone WPs and group-embedded WPs.
# Returns four undef values if the spoke is not currently connected /
# loaded (caller treats that as "no collision possible").

sub _spokeNameAndUUIDSets
{
	# Returns (\%wp_names, \%grp_names, \%rte_names, \%have_uuid) for the
	# named spoke.  As of the hub-alpha fix, the *_names hashes are
	# name -> UUID maps (navMate canonical no-dash form) rather than
	# name -> 1 presence sets, so the SS10.2 collision check at the call
	# site can distinguish "same UUID, in-place update" (skip) from
	# "different UUID, real name collision" (error).  Names that are not
	# unique on the spoke record one representative UUID; uniqueness is
	# enforced by the spoke's own deconflict policy so multiplicity here
	# is an invariant violation, not a normal state.
	my ($panel) = @_;
	if ($panel eq 'e80')
	{
		my $wpmgr = _wpmgr();
		return (undef, undef, undef, undef) if !$wpmgr;
		my %wp_names;
		for my $u (keys %{$wpmgr->{waypoints} // {}})
		{
			my $n = $wpmgr->{waypoints}{$u}{name} // '';
			$wp_names{$n} = $u;
		}
		my %grp_names;
		for my $u (keys %{$wpmgr->{groups} // {}})
		{
			my $n = $wpmgr->{groups}{$u}{name} // '';
			$grp_names{$n} = $u;
		}
		my %rte_names;
		for my $u (keys %{$wpmgr->{routes} // {}})
		{
			my $n = $wpmgr->{routes}{$u}{name} // '';
			$rte_names{$n} = $u;
		}
		my %have_uuid = map { $_ => 1 } keys %{$wpmgr->{waypoints} // {}};
		return (\%wp_names, \%grp_names, \%rte_names, \%have_uuid);
	}
	if ($panel eq 'fsh')
	{
		my $db = _fshDb();
		return (undef, undef, undef, undef) if !$db;
		my %wp_names;
		my %have_uuid;
		# Standalone WPs.
		for my $fsh_uuid (keys %{$db->{waypoints} // {}})
		{
			my $wp      = $db->{waypoints}{$fsh_uuid};
			my $nav_uuid = fshToNavUUID($fsh_uuid);
			$wp_names{$wp->{name} // ''} = $nav_uuid;
			$have_uuid{$nav_uuid} = 1;
		}
		# Group-embedded WPs (names participate in uniqueness).
		for my $grp (values %{$db->{groups} // {}})
		{
			for my $wp (@{$grp->{wpts} // []})
			{
				next if !defined $wp->{name} || !$wp->{uuid};
				my $nav_uuid = fshToNavUUID($wp->{uuid});
				$wp_names{$wp->{name}} = $nav_uuid;
				$have_uuid{$nav_uuid} = 1;
			}
		}
		my %grp_names;
		for my $fsh_uuid (keys %{$db->{groups} // {}})
		{
			my $n = $db->{groups}{$fsh_uuid}{name} // '';
			$grp_names{$n} = fshToNavUUID($fsh_uuid);
		}
		my %rte_names;
		for my $fsh_uuid (keys %{$db->{routes} // {}})
		{
			my $n = $db->{routes}{$fsh_uuid}{name} // '';
			$rte_names{$n} = fshToNavUUID($fsh_uuid);
		}
		return (\%wp_names, \%grp_names, \%rte_names, \%have_uuid);
	}
	return (undef, undef, undef, undef);
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
	my ($cmd_id, $panel, $right_click_node, $tree, @nodes) = @_;

	if ($panel eq 'e80')
	{
		# E80 selection -> DB (CTX_CMD_PUSH) or -> FSH (CTX_CMD_PUSH_FSH).
		# Snapshot once; route by cmd_id.
		my @items = _snapshotNodes($panel, @nodes);
		if (!@items)
		{
			warning(0, 0, "_doPush: nothing to push");
			return;
		}
		my $n = scalar @items;
		if ($cmd_id == $CTX_CMD_PUSH_FSH)
		{
			my $msg = "Push $n item(s) from E80 to FSH?";
			return if !($nmDialogs::suppress_confirm || confirmDialog($tree, $msg, 'Push'));
			# E80<->FSH share identical name/comment limits + color palette;
			# no lossy transform check needed.
			navOps::_pushToFSH($right_click_node, $tree, \@items);
		}
		else
		{
			my $msg = "Push $n item(s) from E80 to database?";
			return if !($nmDialogs::suppress_confirm || confirmDialog($tree, $msg, 'Push'));
			my $issues = _preflightLossyTransform(\@items, 'e80_to_db');
			if (_hasLossyIssues($issues))
			{
				return if !nmDialogs::lossyTransformWarning($tree, $issues);
			}
			navOps::_pushFromE80($right_click_node, $tree, \@items);
		}
		return;
	}

	if ($panel eq 'fsh')
	{
		# FSH selection -> DB (CTX_CMD_PUSH) or -> E80 (CTX_CMD_PUSH_E80).
		my @items = _snapshotNodes($panel, @nodes);
		if (!@items)
		{
			warning(0, 0, "_doPush: nothing to push");
			return;
		}
		my $n = scalar @items;
		if ($cmd_id == $CTX_CMD_PUSH_E80)
		{
			my $msg = "Push $n item(s) from FSH to E80?";
			return if !($nmDialogs::suppress_confirm || confirmDialog($tree, $msg, 'Push'));
			# E80<->FSH symmetric; no lossy transform check needed.
			navOps::_pushToE80($right_click_node, $tree, \@items);
		}
		else
		{
			my $msg = "Push $n item(s) from FSH to database?";
			return if !($nmDialogs::suppress_confirm || confirmDialog($tree, $msg, 'Push'));
			my $issues = _preflightLossyTransform(\@items, 'fsh_to_db');
			if (_hasLossyIssues($issues))
			{
				return if !nmDialogs::lossyTransformWarning($tree, $issues);
			}
			navOps::_pushFromFSH($right_click_node, $tree, \@items);
		}
		return;
	}

	# DB panel: CTX_CMD_PUSH_FSH is unambiguous -- direct push DB -> FSH.
	if ($cmd_id == $CTX_CMD_PUSH_FSH)
	{
		my @db_items = _snapshotNodes('database', @nodes);
		if (!@db_items)
		{
			warning(0, 0, "_doPush: nothing to push");
			return;
		}
		my $n2      = scalar @db_items;
		my $msg2    = "Push $n2 item(s) from database to FSH?";
		my $proceed2 = $nmDialogs::suppress_confirm
			? 1
			: confirmDialog($tree, $msg2, 'Push');
		return if !$proceed2;
		my $db_issues = _preflightLossyTransform(\@db_items, 'db_to_fsh');
		if (_hasLossyIssues($db_issues))
		{
			return if !nmDialogs::lossyTransformWarning($tree, $db_issues);
		}
		navOps::_pushToFSH($right_click_node, $tree, \@db_items);
		return;
	}

	# DB panel CTX_CMD_PUSH: check for clipboard-triggered push (spoke->DB) first.
	# This handles both E80-source (existing) and FSH-source (added in 3A)
	# push-classified clipboards pasted to DB.
	my $cb = $clipboard;
	if ($cb && ($cb->{clipboard_class} // '') eq 'push')
	{
		my @items = @{$cb->{items} // []};
		if (!@items)
		{
			warning(0, 0, "_doPush: empty clipboard");
			return;
		}
		my $source = $cb->{source} // 'e80';
		my $n      = scalar @items;
		my $msg    = "Push $n item(s) from " . uc($source) . " to database?";
		my $proceed = $nmDialogs::suppress_confirm
			? 1
			: confirmDialog($tree, $msg, 'Push');
		return if !$proceed;
		my $direction = ($source eq 'fsh') ? 'fsh_to_db' : 'e80_to_db';
		my $cb_issues = _preflightLossyTransform(\@items, $direction);
		if (_hasLossyIssues($cb_issues))
		{
			return if !nmDialogs::lossyTransformWarning($tree, $cb_issues);
		}
		if ($source eq 'fsh')
		{
			navOps::_pushFromFSH($right_click_node, $tree, \@items);
		}
		else
		{
			navOps::_pushFromE80($right_click_node, $tree, \@items);
		}
		clearClipboard();
		return;
	}

	# DB panel: direct push DB -> E80 (default CTX_CMD_PUSH semantic)
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
	# Clipboard UUIDs are navMate no-dash form; FSH tree-node UUIDs are
	# FSH dashed-upper form -- convert at the seam.
	my $node_uuid = $node->{uuid} // ($node->{data} // {})->{uuid} // '';
	$node_uuid = fshToNavUUID($node_uuid) if $panel eq 'fsh' && $node_uuid;
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
	else  # e80 or fsh -- shallow hierarchy
	{
		# Clipboard UUIDs are navMate no-dash form.  E80 group_uuid is
		# already in that form; FSH group_uuid is dashed-upper -- convert
		# at the seam.
		my $group_uuid = $node->{group_uuid} // '';
		$group_uuid = fshToNavUUID($group_uuid) if $panel eq 'fsh' && $group_uuid;
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
		elsif ($panel eq 'fsh')
		{
			navOps::_newFSHGroup($right_click_node, $tree);
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
		elsif ($panel eq 'fsh')
		{
			navOps::_newFSHRoute($right_click_node, $tree);
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
		elsif ($panel eq 'fsh')
		{
			navOps::_newFSHWaypoint($right_click_node, $tree);
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

	# FSH spoke shares the E80 name/comment field-length limits
	# (Z16/Z32) and the same 0-5 color palette index.  db_to_fsh and
	# fsh_to_db therefore reuse the same constraint logic as the
	# matching E80 directions.  See [[fsh-name-comment-limits]].
	my $is_db_to_spoke = ($direction eq 'db_to_e80' || $direction eq 'db_to_fsh');
	my $is_spoke_to_db = ($direction eq 'e80_to_db' || $direction eq 'fsh_to_db');

	my $dbh = $is_spoke_to_db ? connectDB() : undef;

	for my $item (@$items)
	{
		my $t    = $item->{type} // '';
		my $d    = $item->{data} // {};
		my $name = $d->{name}   // '';

		if ($is_db_to_spoke)
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
		elsif ($is_spoke_to_db && $dbh)
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
	return 'PUSH TO FSH'       if $cmd_id == $CTX_CMD_PUSH_FSH;
	return 'PUSH TO E80'       if $cmd_id == $CTX_CMD_PUSH_E80;
	return "CMD_$cmd_id";
}


1;
