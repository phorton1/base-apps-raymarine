#!/usr/bin/perl
#---------------------------------------------
# navOpsFSH.pm
#---------------------------------------------
# FSH-side operations for navMate context menu -- the third spoke.
# Continues package navOps (loaded via require from navOps.pm).
#
# FSH is the first SYNCHRONOUS spoke.  All operations mutate the
# in-memory shared $navFSH::fsh_db hash directly; nothing is sent to
# the network and the .fsh file on disk is NOT touched.  The user
# saves the archive explicitly via the existing 'Save FSH' menu
# command in winFSH.  See [[navops_phase3_plan]] Phase 3A locked
# decisions for the rationale.
#
# UUID NORMALIZATION SEAM
# -----------------------
# Clipboard items always carry navMate no-dash lowercase UUIDs.  FSH
# stores them as 16-char uppercase hex with dashes (the FSH binary
# format's encoding).  Conversion happens:
#   - clipboard-in to FSH: navToFSHUUID(...) before keying/storing
#   - clipboard-out from FSH: fshToNavUUID(...) at _snapshotFSHNode
#     (in navOps.pm)
# This file does the inbound conversion at every paste/push site.
#
# FIELD-LENGTH LIMITS
# -------------------
# FSH name <= 15 chars, comment <= 31 chars.  The FSH writer errors
# on oversize (per [[fsh-name-comment-limits]]), so the truncate-with-
# warning policy lives at this layer: _truncForFSH enforces.
#
# NAME UNIQUENESS
# ---------------
# FSH (like E80) enforces uniqueness of waypoint, group, and route
# names within type.  _deconflictFSHName picks a non-colliding name
# when minting; pre-flight in _doPaste catches paste-time collisions
# via _spokeNameAndUUIDSets in navOps.pm.
#
# PROGRESS DIALOG
# ---------------
# FSH operations do not open a ProgressDialog -- they are synchronous
# hash mutations and complete within a single wx idle tick.  Only the
# legacy magenta "===== <op> STARTED / FINISHED =====" markers
# emitted by dispatchNavOpsCommand bracket the operation in the log.

package navOps;	# continued ...
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Pub::Utils qw(display warning error getAppFrame);
use Pub::WX::Dialogs;
use apps::raymarine::FSH::fshUtils qw($FSH_MAX_NAME $FSH_MAX_COMMENT latLonToNorthEast);
use navFSH qw(fshToNavUUID navToFSHUUID);
use n_defs;
use n_utils;
use nmDialogs;


our $dbg_fsh_ops = 0;


#----------------------------------------------------
# FSH low-level helpers
#----------------------------------------------------

sub _fshWPGroup
	# Returns the FSH group UUID (dashed-upper) that contains $wp_fsh_uuid
	# as an embedded member, or undef.  FSH groups embed full WP records
	# in their {wpts} array rather than referencing standalone WPT blocks.
{
	my ($db, $wp_fsh_uuid) = @_;
	return undef if !$db || !$wp_fsh_uuid;
	for my $g_uuid (keys %{$db->{groups} // {}})
	{
		my $grp = $db->{groups}{$g_uuid};
		for my $wp (@{$grp->{wpts} // []})
		{
			return $g_uuid if ($wp->{uuid} // '') eq $wp_fsh_uuid;
		}
	}
	return undef;
}


sub _fshWPRoutes
	# Returns list of FSH route UUIDs (dashed-upper) that reference
	# $wp_fsh_uuid in their embedded {wpts} list.  Excludes $exclude
	# (undef = include all).
{
	my ($db, $wp_fsh_uuid, $exclude) = @_;
	my @routes;
	return @routes if !$db || !$wp_fsh_uuid;
	for my $r_uuid (keys %{$db->{routes} // {}})
	{
		next if defined $exclude && $r_uuid eq $exclude;
		for my $wp (@{$db->{routes}{$r_uuid}{wpts} // []})
		{
			if (($wp->{uuid} // '') eq $wp_fsh_uuid)
			{
				push @routes, $r_uuid;
				last;
			}
		}
	}
	return @routes;
}


sub _deconflictFSHName
	# Pick a name that doesn't collide with existing FSH names in the
	# requested hash ($hash_name = 'waypoints', 'groups', or 'routes')
	# or in $pending_names (lc-name keys queued earlier in this paste
	# pass).  Appends ' (2)', ' (3)', ... and re-checks length after
	# each append (final name must fit in 15 chars).
{
	my ($db, $name, $pending_names, $hash_name) = @_;
	$hash_name     //= 'waypoints';
	$pending_names //= {};
	$name          //= '';
	my %existing;
	$existing{lc($_->{name} // '')} = 1 for values %{$db->{$hash_name} // {}};
	# Group-embedded WP names participate in the global WP-name space.
	if ($hash_name eq 'waypoints')
	{
		for my $grp (values %{$db->{groups} // {}})
		{
			for my $wp (@{$grp->{wpts} // []})
			{
				$existing{lc($wp->{name} // '')} = 1 if defined $wp->{name};
			}
		}
	}
	my $base      = $name;
	my $candidate = $base;
	my $n         = 2;
	while ($existing{lc($candidate)} || $pending_names->{lc($candidate)})
	{
		$candidate = "$base ($n)";
		$n++;
		# Bail if we cannot fit any further suffix within the field limit.
		last if length($candidate) > $FSH_MAX_NAME && $n > 999;
	}
	if ($candidate ne $base)
	{
		display(0, 0, "_deconflictFSHName: renamed '$base' to '$candidate'");
	}
	$pending_names->{lc($candidate)} = 1;
	return $candidate;
}


sub _truncForFSH
	# Enforce FSH field-length limits at the spoke boundary.
	# Truncate-with-warning matches the E80 spoke's policy.
{
	my ($name, $comment) = @_;
	$name    //= '';
	$comment //= '';
	if (length($name) > $FSH_MAX_NAME)
	{
		warning(0, 0, "_truncForFSH: name truncated to $FSH_MAX_NAME chars: '$name'");
		$name = substr($name, 0, $FSH_MAX_NAME);
	}
	if (length($comment) > $FSH_MAX_COMMENT)
	{
		warning(0, 0, "_truncForFSH: comment truncated to $FSH_MAX_COMMENT chars");
		$comment = substr($comment, 0, $FSH_MAX_COMMENT);
	}
	return ($name, $comment);
}


sub _buildFSHWpRecord
	# Construct a shared FSH waypoint record from clipboard-shape data.
	# $clip carries navMate-form UUID, decimal lat/lon, and the canonical
	# field set (name, comment, sym, depth, temp_k, date, time).
	# Returns a shared hash keyable into $fsh_db->{waypoints} or
	# embeddable in a group's {wpts} array.
{
	my ($clip, $opts) = @_;
	$opts //= {};
	my $name    = $opts->{name};
	$name       = $clip->{name} // '' if !defined $name;
	my $comment = $opts->{comment};
	$comment    = $clip->{comment} // '' if !defined $comment;
	my $nav_uuid = $opts->{uuid} // $clip->{uuid} // '';
	my $fsh_uuid = $nav_uuid ? navToFSHUUID($nav_uuid) : '';

	my $rec = &threads::shared::share({});
	$rec->{uuid}     = $fsh_uuid;
	$rec->{name}     = $name;
	$rec->{comment}  = $comment;
	$rec->{lat}      = ($clip->{lat} // 0) + 0;
	$rec->{lon}      = ($clip->{lon} // 0) + 0;
	$rec->{sym}      = $clip->{sym}    // 0;
	$rec->{depth}    = $clip->{depth}  // $clip->{depth_cm} // 0;
	$rec->{temp_k}   = $clip->{temp_k} // 0;
	$rec->{date}     = $clip->{date}   // 0;
	$rec->{time}     = $clip->{time}   // 0;
	# FSH binary-format fields the writer needs:
	$rec->{name_len} = length($name);
	$rec->{cmt_len}  = length($comment);
	$rec->{north}    = 0;
	$rec->{east}     = 0;
	$rec->{k1_0x12}  = chr(0) x 12;
	$rec->{k2_0}     = 0;
	$rec->{k3_0}     = 0;
	$rec->{active}   = 1;
	return $rec;
}


#----------------------------------------------------
# _deleteFSH -- main delete dispatcher
#----------------------------------------------------

sub _deleteFSH
{
	my ($cmd_id, $right_click_node, $tree, @nodes) = @_;
	if    ($cmd_id == $CTX_CMD_DELETE_WAYPOINT)   { _deleteFSHWaypoints(\@nodes, $right_click_node, $tree); }
	elsif ($cmd_id == $CTX_CMD_DELETE_GROUP)      { _deleteFSHGroups(\@nodes, $tree); }
	elsif ($cmd_id == $CTX_CMD_DELETE_GROUP_WPS)  { _deleteFSHGroupsAndWPs(\@nodes, $tree); }
	elsif ($cmd_id == $CTX_CMD_DELETE_ROUTE)      { _deleteFSHRoutes(\@nodes, $tree); }
	elsif ($cmd_id == $CTX_CMD_REMOVE_ROUTEPOINT) { _removeFSHRoutePoint(\@nodes, $right_click_node, $tree); }
	elsif ($cmd_id == $CTX_CMD_DELETE_TRACK)      { _deleteFSHTracks(\@nodes, $tree); }
	else { warning(0, 0, "_deleteFSH: unhandled cmd_id=$cmd_id"); }
}


sub _deleteFSHWaypoints
{
	my ($nodes, $right_click_node, $tree) = @_;
	my $db = _fshDb();
	if (!$db) { error("_deleteFSHWaypoints: no FSH-db loaded"); return; }

	my $n   = scalar @$nodes;
	my $msg = $n == 1
		? "Delete waypoint '" . ($nodes->[0]{data}{name} // '?') . "' from FSH?"
		: "Delete $n waypoints from FSH?";
	return if !confirmDialog($tree, $msg, "Confirm Delete");

	for my $node (@$nodes)
	{
		my $fsh_uuid = $node->{uuid} // '';
		next if !$fsh_uuid;
		# Route-membership safety: removing a route's referenced WP
		# would leave a dangling reference.
		my @routes = _fshWPRoutes($db, $fsh_uuid);
		if (@routes)
		{
			my $name = $node->{data}{name} // $fsh_uuid;
			error("Cannot delete FSH waypoint '$name': referenced by "
			    . scalar(@routes) . " route(s).  Remove from routes first.");
			next;
		}
		# Remove from standalone WPs and from any group's {wpts} array.
		delete $db->{waypoints}{$fsh_uuid};
		for my $grp (values %{$db->{groups} // {}})
		{
			my @new_wpts = grep { ($_->{uuid} // '') ne $fsh_uuid } @{$grp->{wpts} // []};
			# threads::shared array reassign idiom (splice unsupported).
			$grp->{wpts} = shared_clone(\@new_wpts);
		}
	}
	_refreshFSH();
}


sub _deleteFSHGroups
	# Dissolve groups: re-parent member WPs to My Waypoints (standalone
	# $db->{waypoints}); remove the group shell.  Member WPs survive.
{
	my ($nodes, $tree) = @_;
	my $db = _fshDb();
	if (!$db) { error("_deleteFSHGroups: no FSH-db loaded"); return; }

	# Expand a Groups-header right-click to all named groups.
	my @expanded;
	for my $n (@$nodes)
	{
		if (($n->{type} // '') eq 'header')
		{
			push @expanded, map { { type => 'group', uuid => $_, data => $db->{groups}{$_} } }
			                sort keys %{$db->{groups} // {}};
		}
		else { push @expanded, $n; }
	}
	$nodes = \@expanded;

	my $n         = scalar @$nodes;
	my $total_wps = 0;
	$total_wps   += scalar @{$_->{data}{wpts} // []} for @$nodes;
	my $msg;
	if ($n == 1)
	{
		my $wc = scalar @{$nodes->[0]{data}{wpts} // []};
		$msg = $wc > 0
			? "Delete group '$nodes->[0]{data}{name}' from FSH? Its $wc member(s) will move to My Waypoints."
			: "Delete group '$nodes->[0]{data}{name}' from FSH?";
	}
	else
	{
		$msg = $total_wps > 0
			? "Delete $n groups from FSH? Their $total_wps member(s) will move to My Waypoints."
			: "Delete $n groups from FSH?";
	}
	return if !confirmDialog($tree, $msg, "Delete Group");

	for my $node (@$nodes)
	{
		my $g_uuid = $node->{uuid} // '';
		next if !$g_uuid;
		my $grp = $db->{groups}{$g_uuid};
		next if !$grp;
		for my $wp (@{$grp->{wpts} // []})
		{
			# Re-parent: promote embedded WP to a standalone $db->{waypoints}
			# entry under its own FSH UUID.  No new UUID minted; the WP
			# keeps its identity.
			my $u = $wp->{uuid} // '';
			$db->{waypoints}{$u} = $wp if $u;
		}
		delete $db->{groups}{$g_uuid};
	}
	_refreshFSH();
}


sub _deleteFSHGroupsAndWPs
{
	my ($nodes, $tree) = @_;
	my $db = _fshDb();
	if (!$db) { error("_deleteFSHGroupsAndWPs: no FSH-db loaded"); return; }

	# Expand Groups-header right-click.
	my @expanded;
	for my $n (@$nodes)
	{
		if (($n->{type} // '') eq 'header')
		{
			push @expanded, map { { type => 'group', uuid => $_, data => $db->{groups}{$_} } }
			                sort keys %{$db->{groups} // {}};
		}
		else { push @expanded, $n; }
	}
	$nodes = \@expanded;

	my @mw   = grep { ($_->{type} // '') eq 'my_waypoints' } @$nodes;
	my @grps = grep { ($_->{type} // '') ne 'my_waypoints' } @$nodes;

	if (@mw && @grps)
	{
		warning(0, 0, "_deleteFSHGroupsAndWPs: mixed my_waypoints and named groups -- aborting");
		return;
	}

	if (@mw)
	{
		# Delete all standalone WPs (My Waypoints contents).
		my @members = keys %{$db->{waypoints} // {}};
		if (!@members)
		{
			okDialog($tree, "FSH My Waypoints is empty.", "Delete Group + Waypoints");
			return;
		}
		# Route-membership check across all standalones.
		my @blocked = grep { my $u = $_; my @r = _fshWPRoutes($db, $u); scalar @r } @members;
		if (@blocked)
		{
			my $err = "Cannot delete FSH My Waypoints: "
			        . scalar(@blocked) . " waypoint(s) are referenced by routes. "
			        . "Remove from routes first.";
			$nmDialogs::suppress_confirm ? error($err) : okDialog($tree, $err, "Delete Group + Waypoints");
			return;
		}
		my $n = scalar @members;
		return if !confirmDialog($tree,
			"Delete all $n ungrouped waypoint(s) from FSH?",
			"Delete Group + Waypoints");
		delete $db->{waypoints}{$_} for @members;
		_refreshFSH();
		return;
	}

	# Per-group: check route membership of each embedded WP first.
	for my $node (@grps)
	{
		for my $wp (@{$node->{data}{wpts} // []})
		{
			my $u = $wp->{uuid} // '';
			next if !$u;
			if (_fshWPRoutes($db, $u))
			{
				my $err = "Cannot delete FSH group '"
				        . ($node->{data}{name} // '?')
				        . "' and its waypoints: one or more members are referenced by routes. "
				        . "Use Delete Group to dissolve without deleting members, or remove from routes first.";
				$nmDialogs::suppress_confirm ? error($err) : okDialog($tree, $err, "Delete Group + Waypoints");
				return;
			}
		}
	}

	my $n         = scalar @grps;
	my $total_wps = 0;
	$total_wps   += scalar @{$_->{data}{wpts} // []} for @grps;
	my $msg = $n == 1
		? ($total_wps > 0
			? "Delete group '$grps[0]{data}{name}' and its $total_wps waypoint(s) from FSH?"
			: "Delete group '$grps[0]{data}{name}' from FSH?")
		: "Delete $n groups and their $total_wps waypoint(s) from FSH?";
	return if !confirmDialog($tree, $msg, "Delete Groups + Waypoints");

	for my $node (@grps)
	{
		my $g_uuid = $node->{uuid} // '';
		delete $db->{groups}{$g_uuid} if $g_uuid;
	}
	_refreshFSH();
}


sub _deleteFSHRoutes
{
	my ($nodes, $tree) = @_;
	my $db = _fshDb();
	if (!$db) { error("_deleteFSHRoutes: no FSH-db loaded"); return; }

	# Expand Routes-header right-click to all routes.
	my @expanded;
	for my $n (@$nodes)
	{
		if (($n->{type} // '') eq 'header')
		{
			push @expanded, map { { type => 'route', uuid => $_, data => $db->{routes}{$_} } }
			                sort keys %{$db->{routes} // {}};
		}
		else { push @expanded, $n; }
	}
	$nodes = \@expanded;

	my $n   = scalar @$nodes;
	my $msg = $n == 1
		? "Delete route '" . ($nodes->[0]{data}{name} // '?') . "' from FSH?"
		: "Delete $n routes from FSH?";
	return if !confirmDialog($tree, $msg, "Delete Route");

	for my $node (@$nodes)
	{
		my $r_uuid = $node->{uuid} // '';
		delete $db->{routes}{$r_uuid} if $r_uuid;
	}
	_refreshFSH();
}


sub _deleteFSHTracks
{
	my ($nodes, $tree) = @_;
	my $db = _fshDb();
	if (!$db) { error("_deleteFSHTracks: no FSH-db loaded"); return; }

	# Expand Tracks-header right-click to all tracks.
	my @expanded;
	for my $n (@$nodes)
	{
		if (($n->{type} // '') eq 'header')
		{
			push @expanded, map { { type => 'track', uuid => $_, data => $db->{tracks}{$_} } }
			                sort keys %{$db->{tracks} // {}};
		}
		else { push @expanded, $n; }
	}
	$nodes = \@expanded;

	my $n   = scalar @$nodes;
	return if !$n;
	my $msg = $n == 1
		? "Delete track '" . ($nodes->[0]{data}{name} // '?') . "' from FSH?"
		: "Delete $n tracks from FSH?";
	return if !confirmDialog($tree, $msg, "Confirm Delete");

	for my $node (@$nodes)
	{
		my $t_uuid = $node->{uuid} // '';
		delete $db->{tracks}{$t_uuid} if $t_uuid;
	}
	_refreshFSH();
}


sub _removeFSHRoutePoint
{
	my ($nodes, $right_click_node, $tree) = @_;
	my $db = _fshDb();
	if (!$db) { error("_removeFSHRoutePoint: no FSH-db loaded"); return; }

	my $route_uuid = $right_click_node->{route_uuid};
	my $route      = $db->{routes}{$route_uuid};
	if (!$route)
	{
		error("_removeFSHRoutePoint: route $route_uuid not found");
		return;
	}
	my $route_name = $route->{name} // $route_uuid;

	my $n = scalar @$nodes;
	my $msg = $n == 1
		? "Remove '" . ($nodes->[0]{data}{name} // $nodes->[0]{uuid}) . "' from route '$route_name'?"
		: "Remove $n waypoints from route '$route_name'?";
	return if !confirmDialog($tree, $msg, "Remove RoutePoint");

	my %to_remove = map { ($_->{uuid} // '') => 1 } @$nodes;
	my @new_wpts  = grep { !$to_remove{$_->{uuid} // ''} } @{$route->{wpts} // []};
	$route->{wpts} = shared_clone(\@new_wpts);
	_refreshFSH();
}


#----------------------------------------------------
# New item handlers
#----------------------------------------------------

sub _newFSHWaypoint
{
	my ($node, $tree) = @_;
	my $db = _fshDb();
	if (!$db) { error("_newFSHWaypoint: no FSH-db loaded"); return; }

	my $data = nmDialogs::showNewWaypoint($tree);
	return if !defined $data;

	my $lat = parseLatLon($data->{lat});
	my $lon = parseLatLon($data->{lon});
	if (!(defined $lat && defined $lon))
	{
		okDialog($tree,
			"Could not parse Latitude or Longitude.\n"
			. "Use decimal degrees (9.3617 N) or degrees and minutes (9 21.702 N).",
			"New Waypoint");
		return;
	}

	my $node_type     = $node->{type} // '';
	my $group_fsh_uid =
		($node_type eq 'group')    ? $node->{uuid}       :
		($node_type eq 'waypoint') ? $node->{group_uuid} : undef;

	my $nav_uuid = _newNavUUID();
	return if !$nav_uuid;

	my %pending_names;
	my $hash_name = $group_fsh_uid ? 'waypoints' : 'waypoints';
	my $name_raw  = _deconflictFSHName($db, $data->{name} // '', \%pending_names, $hash_name);
	my ($name, $comment) = _truncForFSH($name_raw, $data->{comment} // '');

	my $rec = _buildFSHWpRecord({
		uuid    => $nav_uuid,
		name    => $name,
		comment => $comment,
		lat     => $lat,
		lon     => $lon,
		sym     => 0,
		date    => 0,
		time    => 0,
	});

	if ($group_fsh_uid && $db->{groups}{$group_fsh_uid})
	{
		my $grp = $db->{groups}{$group_fsh_uid};
		my @new = (@{$grp->{wpts} // []}, $rec);
		$grp->{wpts} = shared_clone(\@new);
	}
	else
	{
		$db->{waypoints}{$rec->{uuid}} = $rec;
	}
	_refreshFSH();
}


sub _newFSHGroup
{
	my ($node, $tree) = @_;
	my $db = _fshDb();
	if (!$db) { error("_newFSHGroup: no FSH-db loaded"); return; }

	my $data = nmDialogs::showNewGroup($tree);
	return if !defined $data;

	my $nav_uuid = _newNavUUID();
	return if !$nav_uuid;

	my %pending_names;
	my $name_raw  = _deconflictFSHName($db, $data->{name} // '', \%pending_names, 'groups');
	my ($name, $unused_cmt) = _truncForFSH($name_raw, '');

	my $rec = &threads::shared::share({});
	$rec->{uuid}   = navToFSHUUID($nav_uuid);
	$rec->{name}   = $name;
	$rec->{wpts}   = shared_clone([]);
	$rec->{active} = 1;
	$db->{groups}{$rec->{uuid}} = $rec;
	_refreshFSH();
}


sub _newFSHRoute
{
	my ($node, $tree) = @_;
	my $db = _fshDb();
	if (!$db) { error("_newFSHRoute: no FSH-db loaded"); return; }

	my $data = nmDialogs::showNewRoute($tree);
	return if !defined $data;

	my $nav_uuid = _newNavUUID();
	return if !$nav_uuid;

	my %pending_names;
	my $name_raw  = _deconflictFSHName($db, $data->{name} // '', \%pending_names, 'routes');
	my ($name, $comment) = _truncForFSH($name_raw, $data->{comment} // '');

	my $rec = &threads::shared::share({});
	$rec->{uuid}    = navToFSHUUID($nav_uuid);
	$rec->{name}    = $name;
	$rec->{comment} = $comment;
	$rec->{color}   = abgrToE80Index($data->{color}) // 0;
	$rec->{wpts}    = shared_clone([]);
	$rec->{active}  = 1;
	$db->{routes}{$rec->{uuid}} = $rec;
	_refreshFSH();
}


#----------------------------------------------------
# Paste helpers -- UUID-preserving (PASTE)
#----------------------------------------------------

sub _pasteFSH
	# Top-level FSH paste dispatcher.  $items has already been
	# pre-flighted by _doPaste in navOps.pm (ancestor-wins, branch
	# dissolution, homogeneity, name collision, lossy transform).
{
	my ($cmd_id, $right_click_node, $tree, $items, $cb) = @_;

	# FSH allows track writes (unlike E80) -- paste-to-tracks-header is
	# valid and routes through _pasteAllToFSH's per-type dispatch to
	# _pasteTrackToFSH.  No SS10.8 guard here; the guard remains on the
	# E80 side in navOps.pm.

	if ($cmd_id == $CTX_CMD_PASTE_BEFORE    || $cmd_id == $CTX_CMD_PASTE_AFTER
	 || $cmd_id == $CTX_CMD_PASTE_NEW_BEFORE || $cmd_id == $CTX_CMD_PASTE_NEW_AFTER)
	{
		_pasteBeforeAfterFSH($cmd_id, $right_click_node, $tree, $items, $cb);
		return;
	}

	if ($cmd_id == $CTX_CMD_PASTE_NEW)
	{
		_pasteNewAllToFSH($right_click_node, $tree, $items, $cb);
	}
	else
	{
		_pasteAllToFSH($right_click_node, $tree, $items, $cb);
	}
}


sub _pasteAllToFSH
	# UUID-preserving multi-item paste to FSH.  Each clipboard item
	# arrives with a navMate-form UUID; we convert at the seam and
	# store with FSH-form keys.  No new UUIDs are minted.
{
	my ($node, $tree, $items, $cb) = @_;
	my $db = _fshDb();
	if (!$db) { error("_pasteAllToFSH: no FSH-db loaded"); return; }

	# Pasting waypoints into an existing FSH route: append by reference
	# to existing WP records (do not duplicate the WP record itself).
	if (($node->{type} // '') eq 'route')
	{
		my $r_fsh_uuid = $node->{uuid};
		my $route      = $db->{routes}{$r_fsh_uuid};
		if (!$route) { error("_pasteAllToFSH: route $r_fsh_uuid not found"); return; }
		my @existing_wpts = @{$route->{wpts} // []};
		for my $item (@$items)
		{
			next if ($item->{type} // '') ne 'waypoint';
			my $u = $item->{uuid};
			next if !$u;
			my $fu = navToFSHUUID($u);
			my $wp_rec = _findFSHWPRecord($db, $fu) // _buildFSHWpRecord($item->{data}, { uuid => $u });
			push @existing_wpts, $wp_rec;
		}
		$route->{wpts} = shared_clone(\@existing_wpts);
		_refreshFSH();
		return;
	}

	# Per-type pending name trackers -- FSH (like E80) has separate
	# uniqueness namespaces for waypoints, groups, and routes; sharing
	# a single tracker would cause cross-type false collisions.
	my %pending_wp_names;
	my %pending_grp_names;
	my %pending_rte_names;
	for my $item (@$items)
	{
		my $type = $item->{type} // '';
		if    ($type eq 'waypoint') { _pasteWaypointToFSH($node, $tree, $item, $cb, \%pending_wp_names); }
		elsif ($type eq 'group')    { _pasteGroupToFSH($node, $tree, $item, $cb, \%pending_grp_names); }
		elsif ($type eq 'route')    { _pasteRouteToFSH($node, $tree, $item, $cb, \%pending_rte_names); }
		elsif ($type eq 'track')    { _pasteTrackToFSH($node, $tree, $item, $cb); }
		else { warning(0, 0, "_pasteAllToFSH: unknown item type '$type'"); }
	}
	_refreshFSH();
}


sub _findFSHWPRecord
	# Look up an FSH waypoint record by FSH-form UUID.  Returns the
	# record from standalone $db->{waypoints} first, then walks groups
	# to find an embedded copy.  Returns undef if not found.
{
	my ($db, $fsh_uuid) = @_;
	return undef if !$db || !$fsh_uuid;
	return $db->{waypoints}{$fsh_uuid} if $db->{waypoints}{$fsh_uuid};
	for my $grp (values %{$db->{groups} // {}})
	{
		for my $wp (@{$grp->{wpts} // []})
		{
			return $wp if ($wp->{uuid} // '') eq $fsh_uuid;
		}
	}
	return undef;
}


sub _pasteWaypointToFSH
{
	my ($node, $tree, $item, $cb, $pending_names) = @_;
	my $db = _fshDb();
	return if !$db;

	my $nav_uuid = $item->{uuid};
	my $fsh_uuid = navToFSHUUID($nav_uuid);

	# Destination semantics:  group node / waypoint-in-group -> embed
	# in that group's {wpts}.  Otherwise -> standalone in {waypoints}.
	my $node_type     = $node->{type} // '';
	my $group_fsh_uid =
		($node_type eq 'group')    ? $node->{uuid}       :
		($node_type eq 'waypoint') ? $node->{group_uuid} : undef;

	my $existing = _findFSHWPRecord($db, $fsh_uuid);
	my $created  = 0;
	if ($existing)
	{
		# UUID already present -> in-place update (PASTE = UUID-preserving).
		my ($name, $comment) = _truncForFSH($item->{data}{name} // '', $item->{data}{comment} // '');
		_updateFSHWpFields($existing, $item->{data}, $name, $comment);
		display($dbg_fsh_ops, 0, "_pasteWaypointToFSH: updated existing $fsh_uuid '$name'");
	}
	else
	{
		my $name_raw = _deconflictFSHName($db, $item->{data}{name} // '', $pending_names, 'waypoints');
		my ($name, $comment) = _truncForFSH($name_raw, $item->{data}{comment} // '');
		my $rec = _buildFSHWpRecord($item->{data}, { uuid => $nav_uuid, name => $name, comment => $comment });

		if ($group_fsh_uid && $db->{groups}{$group_fsh_uid})
		{
			my $grp = $db->{groups}{$group_fsh_uid};
			my @new = (@{$grp->{wpts} // []}, $rec);
			$grp->{wpts} = shared_clone(\@new);
		}
		else
		{
			$db->{waypoints}{$rec->{uuid}} = $rec;
		}
		$created = 1;
	}

	_cutPasteCleanupWp($cb, $nav_uuid, $tree) if $cb && $cb->{cut_flag};
}


sub _cutPasteCleanupWp
{
	# After a successful paste with cut_flag set, delete the source-side
	# waypoint.  Dispatch on $cb->{source}.  Centralizes what used to be
	# inline 2-way ternaries in navOpsE80.pm so they handle the third
	# source spoke without duplicated logic.  DB cut to spoke is rejected
	# at pre-flight so 'database' only reaches here for DB->DB cut-paste.
	my ($cb, $nav_uuid, $tree) = @_;
	my $src = $cb->{source} // '';
	if    ($src eq 'database') { _cutDatabaseWaypoint($nav_uuid, $tree); }
	elsif ($src eq 'e80')      { _cutE80Waypoint($nav_uuid, $tree); }
	elsif ($src eq 'fsh')      { _cutFSHWaypoint($nav_uuid, $tree); }
}


sub _cutPasteCleanupGroup
{
	my ($cb, $nav_uuid, $tree) = @_;
	my $src = $cb->{source} // '';
	if    ($src eq 'database') { _cutDatabaseGroup($nav_uuid, $tree); }
	elsif ($src eq 'e80')      { _cutE80Group($nav_uuid, $tree); }
	elsif ($src eq 'fsh')      { _cutFSHGroup($nav_uuid, $tree); }
}


sub _cutPasteCleanupRoute
{
	my ($cb, $nav_uuid, $tree) = @_;
	my $src = $cb->{source} // '';
	if    ($src eq 'database') { _cutDatabaseRoute($nav_uuid, $tree); }
	elsif ($src eq 'e80')      { _cutE80Route($nav_uuid, $tree); }
	elsif ($src eq 'fsh')      { _cutFSHRoute($nav_uuid, $tree); }
}


sub _updateFSHWpFields
{
	my ($rec, $clip, $name, $comment) = @_;
	$rec->{name}    = $name    if defined $name;
	$rec->{comment} = $comment if defined $comment;
	$rec->{lat}     = ($clip->{lat} // 0) + 0;
	$rec->{lon}     = ($clip->{lon} // 0) + 0;
	$rec->{sym}     = $clip->{sym}    // 0;
	$rec->{depth}   = $clip->{depth}  // $clip->{depth_cm} // 0;
	$rec->{temp_k}  = $clip->{temp_k} // 0;
	$rec->{date}    = $clip->{date}   // 0 if defined $clip->{date};
	$rec->{time}    = $clip->{time}   // 0 if defined $clip->{time};
	$rec->{name_len} = length($rec->{name}    // '');
	$rec->{cmt_len}  = length($rec->{comment} // '');
}


sub _pasteGroupToFSH
{
	my ($node, $tree, $item, $cb, $pending_names) = @_;
	my $db = _fshDb();
	return if !$db;

	my $nav_uuid     = $item->{uuid};
	my $fsh_uuid     = navToFSHUUID($nav_uuid);
	my $group_data   = $item->{data} // {};
	my $members      = $item->{members} // [];

	if ($db->{groups}{$fsh_uuid})
	{
		# UUID-preserving in-place update of existing group.  Merge
		# clipboard members into the existing group by UUID: if a
		# member's FSH UUID matches an existing wpt, update its fields
		# in-place; otherwise deconflict its name + append.  Idempotent
		# for unchanged data; counts do NOT inflate on a same-UUID
		# round-trip.  Group name is replaced with the clipboard's value
		# when non-empty.
		my $grp = $db->{groups}{$fsh_uuid};
		my $gname_raw = $group_data->{name} // '';
		if ($gname_raw ne '')
		{
			my ($gname) = _truncForFSH($gname_raw, '');
			$grp->{name} = $gname;
		}

		my %by_fsh_uuid;
		for my $w (@{$grp->{wpts} // []})
		{
			$by_fsh_uuid{$w->{uuid} // ''} = $w if $w->{uuid};
		}

		my %wp_pending;
		my @final  = @{$grp->{wpts} // []};
		my $merged = 0;
		my $added  = 0;
		for my $member (@$members)
		{
			my $wp_data    = $member->{data} // {};
			my $wp_nav     = $member->{uuid};
			next if !$wp_nav;
			my $wp_fsh     = navToFSHUUID($wp_nav);
			my $existing_w = $by_fsh_uuid{$wp_fsh};
			if ($existing_w)
			{
				# Same-UUID -- preserve the existing name (it IS our name)
				# rather than deconflicting against ourselves.
				my ($wn, $wc) = _truncForFSH($wp_data->{name} // '', $wp_data->{comment} // '');
				_updateFSHWpFields($existing_w, $wp_data, $wn, $wc);
				$merged++;
			}
			else
			{
				my $wn_raw = _deconflictFSHName($db, $wp_data->{name} // '', \%wp_pending, 'waypoints');
				my ($wn, $wc) = _truncForFSH($wn_raw, $wp_data->{comment} // '');
				push @final, _buildFSHWpRecord($wp_data, { uuid => $wp_nav, name => $wn, comment => $wc });
				$added++;
			}
		}
		$grp->{wpts} = shared_clone(\@final);
		display($dbg_fsh_ops, 0, "_pasteGroupToFSH: in-place update of $fsh_uuid merged=$merged added=$added");
	}
	else
	{
		my %wp_pending;
		my @embedded;
		for my $member (@$members)
		{
			my $wp_data = $member->{data} // {};
			my $wp_nav  = $member->{uuid};
			my $wn_raw  = _deconflictFSHName($db, $wp_data->{name} // '', \%wp_pending, 'waypoints');
			my ($wn, $wc) = _truncForFSH($wn_raw, $wp_data->{comment} // '');
			push @embedded, _buildFSHWpRecord($wp_data, { uuid => $wp_nav, name => $wn, comment => $wc });
		}
		my $gname_raw = _deconflictFSHName($db, $group_data->{name} // '', $pending_names, 'groups');
		my ($gname) = _truncForFSH($gname_raw, '');

		my $grp = &threads::shared::share({});
		$grp->{uuid}   = $fsh_uuid;
		$grp->{name}   = $gname;
		$grp->{wpts}   = shared_clone(\@embedded);
		$grp->{active} = 1;
		$db->{groups}{$fsh_uuid} = $grp;
	}

	if ($cb && $cb->{cut_flag})
	{
		# Cut-paste cross-spoke: remove the source group + members from
		# the source spoke.  For source=e80, mirror the _clearE80_DB
		# ordering: delete the group SHELL first so member WPs become
		# orphans, then delete each WP (E80 rejects deleting a WP that
		# is still a group member).  skip_group=1 on the per-WP cleanup
		# avoids redundant modifyGroup calls that would fail anyway since
		# the group is gone.  modifyRoute (route-detach) still runs so
		# any routes referencing these WPs stay consistent.
		my $src = $cb->{source} // '';
		if ($src eq 'e80')
		{
			navOps::_cutE80Group($nav_uuid, $tree);
			navOps::_cutE80Waypoint($_->{uuid}, $tree, 1) for @$members;
		}
		else
		{
			# Source=database / source=fsh: original ordering -- members
			# first (so their group-detach happens while group still
			# exists locally), then the group shell.
			_cutPasteCleanupWp($cb, $_->{uuid}, $tree) for @$members;
			_cutPasteCleanupGroup($cb, $nav_uuid, $tree);
		}
	}
}


sub _pasteRouteToFSH
{
	my ($node, $tree, $item, $cb, $pending_names) = @_;
	my $db = _fshDb();
	return if !$db;

	my $nav_uuid     = $item->{uuid};
	my $fsh_uuid     = navToFSHUUID($nav_uuid);
	my $route_data   = $item->{data} // {};
	my $route_points = $item->{route_points} // [];

	# SS10.10 has already verified each member WP exists at FSH or in the
	# current clipboard.  Resolve each rp's record from FSH-db (preferred)
	# or build from the embedded clipboard data.
	my @route_wpts;
	for my $rp (@$route_points)
	{
		my $rp_nav = $rp->{uuid};
		next if !$rp_nav;
		my $rp_fsh = navToFSHUUID($rp_nav);
		my $wp_rec = _findFSHWPRecord($db, $rp_fsh);
		if (!$wp_rec)
		{
			# Route members carrying their own snapshotted WP data; build
			# an embedded record so the route is self-contained.
			my ($n, $c) = _truncForFSH($rp->{data}{name} // '', $rp->{data}{comment} // '');
			$wp_rec = _buildFSHWpRecord($rp->{data}, { uuid => $rp_nav, name => $n, comment => $c });
		}
		push @route_wpts, $wp_rec;
	}

	if ($db->{routes}{$fsh_uuid})
	{
		# UUID-preserving update: replace member list.
		my $rec = $db->{routes}{$fsh_uuid};
		$rec->{wpts} = shared_clone(\@route_wpts);
		display($dbg_fsh_ops, 0, "_pasteRouteToFSH: replaced wpts of existing $fsh_uuid");
	}
	else
	{
		my $rname_raw = _deconflictFSHName($db, $route_data->{name} // '', $pending_names, 'routes');
		my ($rname, $rcomment) = _truncForFSH($rname_raw, $route_data->{comment} // '');

		my $rec = &threads::shared::share({});
		$rec->{uuid}    = $fsh_uuid;
		$rec->{name}    = $rname;
		$rec->{comment} = $rcomment;
		$rec->{color}   = $cb && ($cb->{source} // '') eq 'database'
			? (abgrToE80Index($route_data->{color}) // 0)
			: ($route_data->{color} // 0);
		$rec->{wpts}    = shared_clone(\@route_wpts);
		$rec->{active}  = 1;
		$db->{routes}{$fsh_uuid} = $rec;
	}

	_cutPasteCleanupRoute($cb, $nav_uuid, $tree) if $cb && $cb->{cut_flag};
}


sub _pasteTrackToFSH
	# Build an in-memory FSH track record from a navMate-canonical track
	# clipboard item.  Computes FSH-native Mercator north/east from each
	# point's lat/lon via latLonToNorthEast.  Round-trip to FSH file
	# (Save FSH) is not yet exercised; that path may need additional
	# segmentation/sentinel fields when implemented.
{
	my ($node, $tree, $item, $cb) = @_;
	my $db = _fshDb();
	if (!$db) { error("_pasteTrackToFSH: no FSH-db loaded"); return; }

	my $nav_uuid = $item->{uuid};
	my $fsh_uuid = navToFSHUUID($nav_uuid);
	my $data     = $item->{data} // {};
	my ($name, $comment) = _truncForFSH($data->{name} // '', $data->{comment} // '');

	my $pts_in  = $data->{points} // [];
	my $pts_out = shared_clone([]);
	for my $pt (@$pts_in)
	{
		my $lat = $pt->{lat} // 0;
		my $lon = $pt->{lon} // 0;
		my $ne  = latLonToNorthEast($lat, $lon);
		my $rec = &threads::shared::share({});
		$rec->{lat}    = $lat;
		$rec->{lon}    = $lon;
		$rec->{north}  = $ne->{north} // 0;
		$rec->{east}   = $ne->{east}  // 0;
		$rec->{depth}  = $pt->{depth_cm} // 0;
		$rec->{temp_k} = $pt->{temp_k}   // 0;
		push @$pts_out, $rec;
	}
	my $cnt = scalar @$pts_out;

	my $rec = &threads::shared::share({});
	$rec->{mta_uuid}     = $fsh_uuid;
	$rec->{trk_uuid}     = $fsh_uuid;
	$rec->{name}         = $name;
	$rec->{comment}      = $comment;
	$rec->{color}        = abgrToE80Index($data->{color}) // 0;
	$rec->{points}       = $pts_out;
	$rec->{cnt}          = $cnt;
	$rec->{_cnt}         = $cnt;
	$rec->{uuid_cnt}     = 1;
	$rec->{active}       = 1;
	$rec->{north_start}  = $cnt ? $pts_out->[0]{north}  : 0;
	$rec->{north_end}    = $cnt ? $pts_out->[-1]{north} : 0;
	$rec->{east_start}   = $cnt ? $pts_out->[0]{east}   : 0;
	$rec->{east_end}     = $cnt ? $pts_out->[-1]{east}  : 0;
	$rec->{depth_start}  = $cnt ? $pts_out->[0]{depth}  : 0;
	$rec->{depth_end}    = $cnt ? $pts_out->[-1]{depth} : 0;
	$rec->{temp_k_start} = $cnt ? $pts_out->[0]{temp_k} : 0;
	$rec->{temp_k_end}   = $cnt ? $pts_out->[-1]{temp_k}: 0;
	$rec->{length}       = 0;
	$rec->{u1}           = 0;
	$rec->{k1_1}         = 1;
	$rec->{k2_0}         = 0;

	$db->{tracks}{$fsh_uuid} = $rec;
	display($dbg_fsh_ops, 0, "_pasteTrackToFSH: stored '$name' uuid=$fsh_uuid points=$cnt");
}


#----------------------------------------------------
# Paste helpers -- fresh UUIDs (PASTE_NEW)
#----------------------------------------------------

sub _pasteNewAllToFSH
{
	my ($node, $tree, $items, $cb) = @_;
	my $db = _fshDb();
	if (!$db) { error("_pasteNewAllToFSH: no FSH-db loaded"); return; }

	# Pasting into an existing FSH route with PASTE_NEW: just append
	# references (clone is at the WP level only -- routes link WPs).
	if (($node->{type} // '') eq 'route')
	{
		my $r_fsh_uuid = $node->{uuid};
		my $route      = $db->{routes}{$r_fsh_uuid};
		if (!$route) { error("_pasteNewAllToFSH: route $r_fsh_uuid not found"); return; }
		my @existing = @{$route->{wpts} // []};
		for my $item (@$items)
		{
			my $t = $item->{type} // '';
			next if $t ne 'waypoint' && $t ne 'route_point';
			my $u = $item->{uuid};
			next if !$u;
			my $fu = navToFSHUUID($u);
			my $wp_rec = _findFSHWPRecord($db, $fu) // _buildFSHWpRecord($item->{data}, { uuid => $u });
			push @existing, $wp_rec;
		}
		$route->{wpts} = shared_clone(\@existing);
		_refreshFSH();
		return;
	}

	# WP-name pending only -- _pasteNewGroupToFSH and _pasteNewRouteToFSH
	# create their own local trackers for the new group/route names they
	# mint (a single per-paste-pass batch of PASTE_NEW won't usually create
	# two groups or two routes; the per-helper local tracker is fine).
	my %pending_wp_names;
	for my $item (@$items)
	{
		my $type = $item->{type} // '';
		if    ($type eq 'waypoint') { _pasteNewWaypointToFSH($node, $tree, $item, $cb, \%pending_wp_names); }
		elsif ($type eq 'group')    { _pasteNewGroupToFSH($node, $tree, $item, $cb); }
		elsif ($type eq 'route')    { _pasteNewRouteToFSH($node, $tree, $item, $cb); }
		elsif ($type eq 'track')    { _pasteTrackToFSH($node, $tree, $item, $cb); }
		else { warning(0, 0, "_pasteNewAllToFSH: unknown item type '$type'"); }
	}
	_refreshFSH();
}


sub _pasteNewWaypointToFSH
{
	my ($node, $tree, $item, $cb, $pending_names) = @_;
	my $db = _fshDb();
	return if !$db;

	my $new_nav = _newNavUUID();
	if (!$new_nav) { error("_pasteNewWaypointToFSH: UUID minting failed"); return; }

	my $node_type     = $node->{type} // '';
	my $group_fsh_uid =
		($node_type eq 'group')    ? $node->{uuid}       :
		($node_type eq 'waypoint') ? $node->{group_uuid} : undef;

	my $name_raw = _deconflictFSHName($db, $item->{data}{name} // '', $pending_names, 'waypoints');
	my ($name, $comment) = _truncForFSH($name_raw, $item->{data}{comment} // '');
	my $rec = _buildFSHWpRecord($item->{data}, { uuid => $new_nav, name => $name, comment => $comment });

	if ($group_fsh_uid && $db->{groups}{$group_fsh_uid})
	{
		my $grp = $db->{groups}{$group_fsh_uid};
		my @new = (@{$grp->{wpts} // []}, $rec);
		$grp->{wpts} = shared_clone(\@new);
	}
	else
	{
		$db->{waypoints}{$rec->{uuid}} = $rec;
	}
}


sub _pasteNewGroupToFSH
{
	my ($node, $tree, $item, $cb) = @_;
	my $db = _fshDb();
	return if !$db;

	my $group_data = $item->{data} // {};
	my $members    = $item->{members} // [];

	my %wp_pending;
	my @embedded;
	for my $member (@$members)
	{
		my $wp_data = $member->{data} // {};
		my $wp_new  = _newNavUUID();
		if (!$wp_new) { error("_pasteNewGroupToFSH: WP UUID minting failed"); return; }
		my $wn_raw  = _deconflictFSHName($db, $wp_data->{name} // '', \%wp_pending, 'waypoints');
		my ($wn, $wc) = _truncForFSH($wn_raw, $wp_data->{comment} // '');
		push @embedded, _buildFSHWpRecord($wp_data, { uuid => $wp_new, name => $wn, comment => $wc });
	}

	my $g_new = _newNavUUID();
	if (!$g_new) { error("_pasteNewGroupToFSH: group UUID minting failed"); return; }
	my %g_pending;
	my $gname_raw = _deconflictFSHName($db, $group_data->{name} // '', \%g_pending, 'groups');
	my ($gname) = _truncForFSH($gname_raw, '');

	my $grp = &threads::shared::share({});
	$grp->{uuid}   = navToFSHUUID($g_new);
	$grp->{name}   = $gname;
	$grp->{wpts}   = shared_clone(\@embedded);
	$grp->{active} = 1;
	$db->{groups}{$grp->{uuid}} = $grp;
}


sub _pasteNewRouteToFSH
{
	my ($node, $tree, $item, $cb) = @_;
	my $db = _fshDb();
	return if !$db;

	my $route_data = $item->{data} // {};
	my $members    = $item->{route_points} // [];

	# PASTE_NEW for a route mints a fresh route UUID but keeps the
	# member WP UUIDs (per SS1.6 invariant -- route paste preserves
	# WP UUID references).  Resolve members from FSH-db if present,
	# else construct from clipboard data.
	my @route_wpts;
	for my $rp (@$members)
	{
		my $rp_nav = $rp->{uuid};
		next if !$rp_nav;
		my $rp_fsh = navToFSHUUID($rp_nav);
		my $wp_rec = _findFSHWPRecord($db, $rp_fsh);
		if (!$wp_rec)
		{
			my ($n, $c) = _truncForFSH($rp->{data}{name} // '', $rp->{data}{comment} // '');
			$wp_rec = _buildFSHWpRecord($rp->{data}, { uuid => $rp_nav, name => $n, comment => $c });
		}
		push @route_wpts, $wp_rec;
	}

	my $r_new = _newNavUUID();
	if (!$r_new) { error("_pasteNewRouteToFSH: route UUID minting failed"); return; }
	my %r_pending;
	my $rname_raw = _deconflictFSHName($db, $route_data->{name} // '', \%r_pending, 'routes');
	my ($rname, $rcomment) = _truncForFSH($rname_raw, $route_data->{comment} // '');

	my $rec = &threads::shared::share({});
	$rec->{uuid}    = navToFSHUUID($r_new);
	$rec->{name}    = $rname;
	$rec->{comment} = $rcomment;
	$rec->{color}   = $cb && ($cb->{source} // '') eq 'database'
		? (abgrToE80Index($route_data->{color}) // 0)
		: ($route_data->{color} // 0);
	$rec->{wpts}    = shared_clone(\@route_wpts);
	$rec->{active}  = 1;
	$db->{routes}{$rec->{uuid}} = $rec;
}


#----------------------------------------------------
# Paste Before / After route point
#----------------------------------------------------

sub _pasteBeforeAfterFSH
{
	my ($cmd_id, $right_click_node, $tree, $items, $cb) = @_;
	my $db = _fshDb();
	if (!$db) { error("_pasteBeforeAfterFSH: no FSH-db loaded"); return; }

	my $r_fsh_uuid = $right_click_node->{route_uuid};
	my $route      = $db->{routes}{$r_fsh_uuid};
	if (!$route) { error("_pasteBeforeAfterFSH: route $r_fsh_uuid not found"); return; }

	# Flatten clipboard items to waypoints (group dissolution: members).
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

	# Find pivot position in the route's wpts list.
	my @cur = @{$route->{wpts} // []};
	my $pivot_fsh = $right_click_node->{uuid};
	my ($pos) = grep { ($cur[$_]{uuid} // '') eq $pivot_fsh } 0 .. $#cur;
	$pos //= scalar @cur;
	$pos++ if $cmd_id == $CTX_CMD_PASTE_AFTER || $cmd_id == $CTX_CMD_PASTE_NEW_AFTER;

	my %pending_names;
	my @new_wps;
	for my $item (@flat_wps)
	{
		my $wp_data = $item->{data} // {};
		my $wp_nav  = $fresh ? _newNavUUID() : $item->{uuid};
		if (!$wp_nav) { error("_pasteBeforeAfterFSH: UUID handling failed"); return; }
		my $wp_fsh  = navToFSHUUID($wp_nav);

		my $rec = $fresh ? undef : _findFSHWPRecord($db, $wp_fsh);
		if (!$rec)
		{
			my $name_raw = _deconflictFSHName($db, $wp_data->{name} // '', \%pending_names, 'waypoints');
			my ($name, $comment) = _truncForFSH($name_raw, $wp_data->{comment} // '');
			$rec = _buildFSHWpRecord($wp_data, { uuid => $wp_nav, name => $name, comment => $comment });
			$db->{waypoints}{$rec->{uuid}} = $rec if $fresh;
		}
		push @new_wps, $rec;
	}

	splice(@cur, $pos, 0, @new_wps);
	$route->{wpts} = shared_clone(\@cur);
	_refreshFSH();
}


#----------------------------------------------------
# Push helpers
#----------------------------------------------------

sub _pushToFSH
	# DB selection -> FSH: items have already passed _preflightLossyTransform
	# in the db_to_fsh direction.  For each item, find the matching FSH
	# record (by converted UUID) and update its fields.
{
	my ($right_click_node, $tree, $items) = @_;
	my $db = _fshDb();
	if (!$db) { error("_pushToFSH: no FSH-db loaded"); return; }

	for my $item (@$items)
	{
		my $t  = $item->{type} // '';
		my $u  = $item->{uuid} // '';
		my $d  = $item->{data} // {};
		next if !$u;
		my $fu = navToFSHUUID($u);

		if ($t eq 'waypoint')
		{
			my $rec = _findFSHWPRecord($db, $fu);
			if (!$rec)
			{
				warning(0, 0, "_pushToFSH: waypoint $u not on FSH -- skipping");
				next;
			}
			my ($name, $comment) = _truncForFSH($d->{name} // '', $d->{comment} // '');
			_updateFSHWpFields($rec, $d, $name, $comment);
		}
		elsif ($t eq 'group')
		{
			my $grp = $db->{groups}{$fu};
			if (!$grp)
			{
				warning(0, 0, "_pushToFSH: group $u not on FSH -- skipping");
				next;
			}
			my ($name) = _truncForFSH($d->{name} // '', '');
			$grp->{name} = $name;
			# Update embedded WPs.
			for my $member (@{$item->{members} // []})
			{
				my $mu  = $member->{uuid} // '';
				next if !$mu;
				my $mfu = navToFSHUUID($mu);
				my $mwp;
				for my $w (@{$grp->{wpts} // []})
				{
					if (($w->{uuid} // '') eq $mfu) { $mwp = $w; last; }
				}
				next if !$mwp;
				my ($mn, $mc) = _truncForFSH($member->{data}{name} // '', $member->{data}{comment} // '');
				_updateFSHWpFields($mwp, $member->{data}, $mn, $mc);
			}
		}
		elsif ($t eq 'route')
		{
			my $rec = $db->{routes}{$fu};
			if (!$rec)
			{
				warning(0, 0, "_pushToFSH: route $u not on FSH -- skipping");
				next;
			}
			my ($name, $comment) = _truncForFSH($d->{name} // '', $d->{comment} // '');
			$rec->{name}    = $name;
			$rec->{comment} = $comment;
			$rec->{color}   = abgrToE80Index($d->{color} // '') // 0;
		}
	}
	_refreshFSH();
}


sub _pushFromFSH
	# FSH selection -> DB: items are already snapshotted from FSH at
	# the seam (navMate-form UUIDs, canonical fields).  Walk each
	# item type and update or insert in the DB matching by UUID.
	# Uses the navOpsDB layer's matching helpers parallel to
	# _pushFromE80.
{
	my ($right_click_node, $tree, $items) = @_;
	# Delegate to the existing E80-mirror push handler in navOpsDB.pm
	# (same identity-match-and-update semantics; the canonical-form
	# clipboard items make E80 and FSH sources interchangeable at this
	# point).  Reuses navOps::_pushFromE80's DB write path.
	navOps::_pushFromE80($right_click_node, $tree, $items);
}


#----------------------------------------------------
# Cut -- source deletion after successful cross-spoke paste
#----------------------------------------------------
# Called by paste handlers in navOpsE80 / navOpsFSH when the clipboard
# has cut_flag set AND the source spoke is FSH.  Takes a navMate-form
# UUID (clipboard canonical form) and removes the corresponding FSH
# record from $navFSH::fsh_db.  Same role _cutE80Waypoint /
# _cutDatabaseWaypoint play for the other source spokes.

sub _cutFSHWaypoint
{
	my ($uuid, $tree) = @_;
	my $db = _fshDb();
	return if !$db || !$uuid;
	my $fsh_uuid = navToFSHUUID($uuid);
	delete $db->{waypoints}{$fsh_uuid};
	# Also strip from any group's embedded wpts array; an FSH WP can
	# live either standalone or inside a group, and the cut should
	# remove all instances.
	for my $grp (values %{$db->{groups} // {}})
	{
		my @new = grep { ($_->{uuid} // '') ne $fsh_uuid } @{$grp->{wpts} // []};
		$grp->{wpts} = shared_clone(\@new);
	}
	_refreshFSH();
}


sub _cutFSHGroup
{
	my ($uuid, $tree) = @_;
	my $db = _fshDb();
	return if !$db || !$uuid;
	my $fsh_uuid = navToFSHUUID($uuid);
	delete $db->{groups}{$fsh_uuid};
	_refreshFSH();
}


sub _cutFSHRoute
{
	my ($uuid, $tree) = @_;
	my $db = _fshDb();
	return if !$db || !$uuid;
	my $fsh_uuid = navToFSHUUID($uuid);
	delete $db->{routes}{$fsh_uuid};
	_refreshFSH();
}


sub _cutFSHTrack
{
	my ($uuid, $tree) = @_;
	my $db = _fshDb();
	return if !$db || !$uuid;
	my $fsh_uuid = navToFSHUUID($uuid);
	delete $db->{tracks}{$fsh_uuid};
	_refreshFSH();
}


1;
