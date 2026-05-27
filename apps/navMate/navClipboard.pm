#!/usr/bin/perl
#---------------------------------------------
# navClipboard.pm
#---------------------------------------------

package navClipboard;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils qw(warning error getAppFrame);
use navDB;
use navFSH qw(fshToNavUUID navToFSHUUID);
use n_defs;


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
		getPushMenuItems

		_pasteRuleAllows
		_deleteRuleAllows
		_newRuleAllows
		_pasteTracksToE80Allows

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
	$CTX_CMD_PUSH,
	$CTX_CMD_PUSH_FSH,
	$CTX_CMD_PUSH_E80,
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

# Source-presence classification: walk the items and check each UUID
# against the navMate DB.  Used by setCopy to mark E80- and FSH-source
# clipboards as paste / push / mixed so paste pre-flight can choose
# between the two operations at a DB destination.
#
# The clipboard items always carry navMate no-dash lowercase UUIDs
# at this point (the spoke snapshot seam normalizes them), so the same
# DB lookup applies regardless of whether the source was E80 or FSH.

sub _classifyAgainstDB
{
	my ($items) = @_;
	return undef if !$items || !@$items;
	my $dbh = connectDB();
	return undef if !$dbh;
	my ($n_present, $n_absent) = (0, 0);
	for my $item (@$items)
	{
		my $uuid = $item->{uuid} // '';
		next if !$uuid;
		my $t = $item->{type} // '';
		my $found;
		if    ($t eq 'waypoint')    { $found = getWaypoint($dbh, $uuid);    }
		elsif ($t eq 'group')       { $found = getCollection($dbh, $uuid);  }
		elsif ($t eq 'route')       { $found = getRoute($dbh, $uuid);       }
		elsif ($t eq 'track')       { $found = getTrack($dbh, $uuid);       }
		elsif ($t eq 'route_point') { $found = getWaypoint($dbh, $uuid);    }
		$found ? $n_present++ : $n_absent++;
	}
	disconnectDB($dbh);
	return 'paste' if $n_present == 0;
	return 'push'  if $n_absent  == 0;
	return 'mixed';
}

sub setCopy
{
	my ($source, $items) = @_;
	my $class = ($source eq 'e80' || $source eq 'fsh')
		? (_classifyAgainstDB($items) // 'paste')
		: undef;
	$clipboard = { source => $source, cut_flag => 0, items => $items // [],
	               clipboard_class => $class };
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
	my $text = "[$src] $verb ($n)";
	if (($clipboard->{clipboard_class} // '') eq 'mixed')
	{
		$text .= " -- Paste/Push not available: clipboard contains both new and existing items -- use Paste New";
	}
	return $text;
}

sub _updateStatusBar
{
	my $frame = getAppFrame();
	return if !($frame && $frame->can('setClipboardStatus'));
	$frame->setClipboardStatus(getClipboardText());
}


#----------------------------------------------------
# Rule predicates -- silent, side-effect-free
#----------------------------------------------------
# Shared by the menu builders (filter what to offer) and by the
# preflight in navOps.pm (gate execution).  Each returns either
# (1) when the operation is allowed, or
# (0, $reason_token, $detail_msg, $emit_as) on rejection.
# $emit_as is 'impl_error' (use implementationError) or 'user_error'
# (use error directly).  The token is for stable test matching;
# the detail is the message body.

sub _pasteRuleAllows
{
	my ($cmd_id, $panel, $right_click_node) = @_;
	return (1) if !$clipboard;
	return (1) if !$right_click_node;

	my $source   = $clipboard->{source}   // '';
	my $cut_flag = $clipboard->{cut_flag} // 0;
	my $items    = $clipboard->{items}    // [];
	my $fresh    = ($cmd_id == $CTX_CMD_PASTE_NEW
	             || $cmd_id == $CTX_CMD_PASTE_NEW_BEFORE
	             || $cmd_id == $CTX_CMD_PASTE_NEW_AFTER);
	my $positional = ($cmd_id == $CTX_CMD_PASTE_BEFORE
	               || $cmd_id == $CTX_CMD_PASTE_AFTER
	               || $cmd_id == $CTX_CMD_PASTE_NEW_BEFORE
	               || $cmd_id == $CTX_CMD_PASTE_NEW_AFTER);

	my $rt    = $right_click_node->{type} // '';
	my $rkind = $right_click_node->{kind} // '';
	my $rd    = $right_click_node->{data} // {};
	my $ruuid = $rd->{uuid} // '';
	my $rot   = $rd->{obj_type} // '';

	# Reference-vs-record destination classification.  A "ref-only"
	# destination accepts waypoint / route_point clipboard items as new
	# rows in route_waypoints (no record creation, no UUID-uniqueness
	# concern).  Three shapes:
	#   - route_point anchor          (positional, any panel)
	#   - e80/fsh route object node   (panel-side type='route')
	#   - DB     route object node    (type='object', obj_type='route')
	my $dest_is_route_point = ($rt eq 'route_point');
	my $dest_is_route_obj   = ($rt eq 'route')
	                       || ($panel eq 'database' && $rt eq 'object' && $rot eq 'route');
	my $dest_is_ref_only    = $dest_is_route_point || $dest_is_route_obj;

	# DB-cut to spoke is rejected (would lose canonical state).
	if (($panel eq 'e80' || $panel eq 'fsh') && $cut_flag && $source eq 'database')
	{
		return (0, 'db_cut_to_spoke',
		        'Cannot paste a database Cut to ' . uc($panel),
		        'user_error');
	}

	# Individual E80 waypoint node is not a paste destination.
	if ($panel eq 'e80' && $rt eq 'waypoint')
	{
		return (0, 'e80_individual_wp_paste',
		        'Cannot paste at an individual E80 waypoint node -- pick a header or group',
		        'user_error');
	}

	# Tracks-to-E80: now supported at the tracks header (via the
	# TRACK writer-session protocol, NET/docs/notes/TRACK_writing.md).
	# Any other E80 destination still rejects tracks: pasting a track
	# onto a group / route / my_waypoints / non-tracks-header target
	# is structurally meaningless, and the D6 spoke-content check
	# below also rejects, but this earlier check produces a clearer
	# user_error sentinel.
	if ($panel eq 'e80')
	{
		my $dest_is_tracks_header = ($rt eq 'header' && $rkind eq 'tracks');
		if (!$dest_is_tracks_header)
		{
			for my $item (@$items)
			{
				if (($item->{type} // '') eq 'track')
				{
					return (0, 'tracks_to_non_tracks_header_e80',
					        'Tracks can only be pasted to the E80 tracks header',
					        'user_error');
				}
			}
		}
	}

	# D4: spoke-side positive-list paste destination.  The earlier rules
	# above catch the more specific cases (individual E80 waypoint,
	# tracks at non-tracks-header destinations) with friendlier
	# user_error sentinels; this rule is the backstop for shapes the
	# executor doesn't support and that would otherwise silently no-op.
	# Tracks header is now a valid paste destination (writer-session
	# protocol, TRACK_writing.md, confirmed live 2026-05-27).
	if ($panel eq 'e80')
	{
		my $ok_e80 = $rt eq 'header'
		          || $rt eq 'my_waypoints'
		          || $rt eq 'group'
		          || $rt eq 'route'
		          || $rt eq 'route_point';
		if (!$ok_e80)
		{
			return (0, 'e80_invalid_paste_dest',
			        "paste at E80 destination type '$rt' not supported",
			        'impl_error');
		}
	}
	elsif ($panel eq 'fsh')
	{
		# FSH writes tracks too, so all three header kinds are valid.
		my $ok_fsh = ($rt eq 'header')
		          || $rt eq 'my_waypoints'
		          || $rt eq 'group'
		          || $rt eq 'route'
		          || $rt eq 'route_point';
		if (!$ok_fsh)
		{
			return (0, 'fsh_invalid_paste_dest',
			        "paste at FSH destination type '$rt' not supported",
			        'impl_error');
		}
	}

	# Before/After on a root-level branch has no parent to insert into.
	if ($positional && $panel eq 'database' && $rt eq 'collection' && $ruuid)
	{
		my $dbh = connectDB();
		if ($dbh)
		{
			my $rec = getCollection($dbh, $ruuid);
			disconnectDB($dbh);
			if ($rec && !defined $rec->{parent_uuid})
			{
				return (0, 'root_branch_before_after',
				        'Cannot paste before/after a root-level branch -- use Paste to add items to it',
				        'user_error');
			}
		}
	}

	# D2: a route_point clipboard item is meaningful only at a route or
	# route_point destination -- everywhere else it would either be lumped
	# in with waypoints by the executor (latent bug) or silently skipped.
	# Reject explicitly across all panels.
	if (!$dest_is_ref_only)
	{
		for my $item (@$items)
		{
			if (($item->{type} // '') eq 'route_point')
			{
				return (0, 'route_point_at_non_route',
				        'route_point items can only be pasted at a route or route_point destination',
				        'impl_error');
			}
		}
	}

	# DB target must be a collection (or, per D3, a route object) for
	# non-positional paste.  PASTE_BEFORE/AFTER (positional) accept other
	# node shapes by anchoring on the node and inserting into its parent.
	if ($panel eq 'database' && !$positional && $rt ne 'root' && $rt ne 'collection'
	    && !($rt eq 'object' && $rot eq 'route'))
	{
		return (0, 'db_paste_non_collection',
		        "paste target type '$rt' is not a collection",
		        'impl_error');
	}

	# Before/After at a route_point anchor accepts only waypoint/route_point items.
	if ($positional && $rt eq 'route_point')
	{
		for my $item (@$items)
		{
			my $t = $item->{type} // '';
			if ($t ne 'waypoint' && $t ne 'route_point')
			{
				return (0, 'route_point_paste_non_wp',
				        'PASTE_BEFORE/AFTER at route_point requires waypoint or route_point items only',
				        'impl_error');
			}
		}
	}

	# D6: spoke content-vs-destination compatibility.  D4 establishes that
	# the destination is a structurally valid spoke node; this narrows
	# further by item type.  Without it the executors silently mis-place
	# items at top level (e.g. a group pasted at my_waypoints becomes a
	# new sibling top-level group; a waypoint pasted at the routes header
	# becomes an ungrouped wp via createWaypoint with no group_uuid).
	# Positional PASTE_BEFORE/AFTER is gated by route_point_paste_non_wp
	# above and is not re-checked here.
	#
	# Absorbed-aware: an item whose UUID appears in another clipboard
	# item's members / route_points is dropped by _resolveAncestorWins
	# (in _doPaste) before the executor runs, so it must not be
	# evaluated here either.  This lets the natural wp+group multi-
	# select case (a group plus one of its own member WPs) survive D6
	# at a header:groups paste -- only the group item is checked.
	if (!$positional && ($panel eq 'e80' || $panel eq 'fsh'))
	{
		my %accepts = (
			'header:groups' => { group       => 1 },
			'header:routes' => { route       => 1 },
			'header:tracks' => { track       => 1 },
			'my_waypoints'  => { waypoint    => 1 },
			'group'         => { waypoint    => 1 },
			'route'         => { waypoint    => 1, route_point => 1 },
		);
		my $dest_key = ($rt eq 'header') ? "header:$rkind" : $rt;
		my $ok_set   = $accepts{$dest_key};

		my %absorbed;
		for my $item (@$items)
		{
			my $uuid = $item->{uuid} // '';
			next if !$uuid;
			for my $other (@$items)
			{
				next if ($other->{uuid} // '') eq $uuid;
				my @sub = (@{$other->{members} // []}, @{$other->{route_points} // []});
				if (grep { ($_->{uuid} // '') eq $uuid } @sub)
				{
					$absorbed{$uuid} = 1;
					last;
				}
			}
		}

		for my $item (@$items)
		{
			my $t = $item->{type} // '';
			my $u = $item->{uuid} // '';
			next if $u && $absorbed{$u};
			next if $ok_set && $ok_set->{$t};
			my $tok = "spoke_${t}_at_${dest_key}";
			$tok =~ s/:/_/g;
			return (0, $tok,
			        "Cannot paste $t clipboard item at $panel '$dest_key' destination",
			        'impl_error');
		}
	}

	# D1: DB-to-DB non-fresh non-cut paste creates an INDEPENDENT RECORD
	# at the clipboard UUID; with the DB's UUID-unique tables that's a
	# guaranteed conflict.  REF-only destinations (route_point anchor,
	# route object) carve out waypoint / route_point items -- those become
	# new route_waypoints rows (no record creation, no uniqueness issue).
	if ($panel eq 'database' && $source eq 'database' && !$fresh && !$cut_flag)
	{
		my $kind = $positional ? 'PASTE_BEFORE/AFTER' : 'PASTE';
		for my $item (@$items)
		{
			my $t = $item->{type} // '';
			next if $dest_is_ref_only && ($t eq 'waypoint' || $t eq 'route_point');
			if ($t eq 'track')
			{
				return (0, 'db_to_db_track_copy',
				        "DB-to-DB track copy via $kind not implemented",
				        'impl_error');
			}
			if ($t eq 'waypoint' || $t eq 'group' || $t eq 'route' || $t eq 'branch')
			{
				return (0, "db_to_db_${t}_copy",
				        "DB-to-DB $t copy via $kind not implemented (use Paste New)",
				        'impl_error');
			}
		}
	}

	return (1);
}


#----------------------------------------------------
# _pasteTracksToE80Allows
#----------------------------------------------------
# Precise per-item preflight for PASTE/PASTE_NEW of tracks to the
# E80 tracks header.  Called by the executor after _pasteRuleAllows
# has cleared the coarse structural rules (panel = e80, destination =
# tracks header, item types acceptable).
#
# Returns one of:
#   'paste'              -- all tracks pass all rules; the caller may
#                           proceed with PASTE (writer uses each track's
#                           own mta_uuid)
#   'paste_new_required' -- one or more tracks has an mta_uuid that
#                           already exists on the E80; PASTE is not
#                           allowed (E80 transport rejects duplicate
#                           UUIDs with success=0x80040f07), but
#                           PASTE_NEW with fresh UUIDs is the alternative
#   'reject:<message>'   -- a hard rule failed (no points, missing
#                           mta_uuid); the entire batch is rejected per
#                           the halt-on-any-failure policy.  Name length
#                           and color drift are NOT hard rules: name is
#                           silently truncated at the wire seam by
#                           _truncForE80; color is closest-snapped to
#                           the E80 palette by abgrToE80Index.  Both are
#                           reported through the lossy-transform warning
#                           dialog as advisory consent.
#
# The PASTE-vs-PASTE_NEW menu state is derived from this:
#   'paste'              -> PASTE enabled,  PASTE_NEW visible+disabled
#   'paste_new_required' -> PASTE disabled, PASTE_NEW enabled (with confirm)
#   'reject:*'           -> both disabled
#
# $track_service is the d_TRACK live service hash (passed by caller
# from navOpsE80::_track() so this module stays peer-agnostic).
# May be undef if TRACK service is not connected; in that case we
# fail open on collision detection (no E80 cache to check against)
# but still apply hard rules.

sub _pasteTracksToE80Allows
{
	my ($items, $track_service) = @_;
	$items ||= [];

	# Hard rules per track.  Name length and color drift are NOT hard
	# rules -- they are lossy transforms (silent truncation by
	# _truncForE80, closest-snap by abgrToE80Index) reported through the
	# lossy-warn dialog as advisory consent.  See [[feedback-never-dedup]]
	# for the systemic policy.
	#
	# What IS a hard rule:
	#   - Point count > 0 -- cnt1 = 0 + actual_points > 0 = "behavior past
	#     the cnt1-th point is undefined" per TRACK_writing.md, crashed
	#     an E80 during writer-protocol bring-up on 2026-05-27.
	#   - mta_uuid present -- the writer-session protocol requires a
	#     non-empty source UUID in the CONTEXT body group.
	for my $item (@$items)
	{
		my $t = $item->{type} // '';
		next if $t ne 'track';

		my $d        = $item->{data}  // {};
		my $name     = $d->{name}     // $item->{name} // '';
		my $points   = $item->{points} // $d->{points} // [];
		my $pt_count = ref($points) eq 'ARRAY' ? scalar @$points : 0;
		my $uuid     = $item->{uuid}  // $d->{mta_uuid} // $d->{uuid} // '';

		if ($pt_count <= 0)
		{
			return ('reject:track "' . $name . '" has no points');
		}
		if (!$uuid)
		{
			return ('reject:track "' . $name . '" has no mta_uuid');
		}
	}

	# Collision detection: if the TRACK service hash is available
	# (navOpsE80 connected), check each track's mta_uuid against
	# the live E80-db cache.  Any collision flips us to
	# 'paste_new_required'.  This is the empirical finding from
	# 2026-05-27: E80 rejects writer-session RECORD with an existing
	# UUID via success=0x80040f07 in the SAVED reply.
	if ($track_service && ref($track_service->{tracks}) eq 'HASH')
	{
		my $e80_tracks = $track_service->{tracks};
		for my $item (@$items)
		{
			my $t = $item->{type} // '';
			next if $t ne 'track';
			my $uuid = $item->{uuid} // $item->{data}{mta_uuid} // $item->{data}{uuid} // '';
			next if !$uuid;
			if (exists $e80_tracks->{$uuid})
			{
				return 'paste_new_required';
			}
		}
	}

	return 'paste';
}


sub _deleteRuleAllows
{
	my ($cmd_id, $panel, $right_click_node, @nodes) = @_;
	@nodes = ($right_click_node) if !@nodes && $right_click_node;
	return (1) if !@nodes;

	# E80 my_waypoints node is not a valid CMD_DELETE_GROUP target.
	if ($panel eq 'e80' && $cmd_id == $CTX_CMD_DELETE_GROUP)
	{
		for my $n (@nodes)
		{
			if (($n->{type} // '') eq 'my_waypoints')
			{
				return (0, 'e80_delete_group_my_waypoints',
				        'delete-group on E80 my_waypoints node not supported',
				        'impl_error');
			}
		}
	}

	# E80 CMD_DELETE_GROUP_WPS rejects mixed my_waypoints + named groups.
	if ($panel eq 'e80' && $cmd_id == $CTX_CMD_DELETE_GROUP_WPS)
	{
		my $has_mw  = scalar grep { ($_->{type} // '') eq 'my_waypoints' } @nodes;
		my $has_grp = scalar grep { ($_->{type} // '') ne 'my_waypoints' } @nodes;
		if ($has_mw && $has_grp)
		{
			return (0, 'e80_delete_mixed_my_waypoints',
			        'delete-group-and-WPs mixes my_waypoints with named groups',
			        'impl_error');
		}
	}

	# DB DELETE_BRANCH safety: descendant WPs referenced by external routes.
	if ($panel eq 'database' && $cmd_id == $CTX_CMD_DELETE_BRANCH)
	{
		my $uuid = ($right_click_node->{data} // {})->{uuid};
		my $name = ($right_click_node->{data} // {})->{name} // '?';
		if ($uuid)
		{
			my $dbh = connectDB();
			if ($dbh)
			{
				my $safe = isBranchDeleteSafe($dbh, $uuid);
				disconnectDB($dbh);
				if (!$safe)
				{
					return (0, 'branch_wp_in_external_route',
					        "Cannot delete '$name': waypoints are referenced by external routes",
					        'user_error');
				}
			}
		}
	}

	# DB DELETE_WAYPOINT: WP must not be referenced by any route.
	if ($panel eq 'database' && $cmd_id == $CTX_CMD_DELETE_WAYPOINT)
	{
		my $dbh = connectDB();
		if ($dbh)
		{
			for my $n (@nodes)
			{
				my $uuid = ($n->{data} // {})->{uuid};
				next if !$uuid;
				if (getWaypointRouteRefCount($dbh, $uuid) > 0)
				{
					disconnectDB($dbh);
					return (0, 'wp_in_route',
					        'waypoint is referenced by a route',
					        'impl_error');
				}
			}
			disconnectDB($dbh);
		}
	}

	# DB DELETE_GROUP_WPS: no member WP may be referenced by any route.
	if ($panel eq 'database' && $cmd_id == $CTX_CMD_DELETE_GROUP_WPS)
	{
		my $dbh = connectDB();
		if ($dbh)
		{
			for my $n (@nodes)
			{
				my $uuid = ($n->{data} // {})->{uuid};
				next if !$uuid;
				my $wps = getGroupWaypoints($dbh, $uuid);
				for my $wp (@$wps)
				{
					if (getWaypointRouteRefCount($dbh, $wp->{uuid}) > 0)
					{
						disconnectDB($dbh);
						return (0, 'group_member_in_route',
						        'group member waypoint is referenced by a route',
						        'impl_error');
					}
				}
			}
			disconnectDB($dbh);
		}
	}

	return (1);
}


sub _newRuleAllows
{
	my ($cmd_id, $panel, $right_click_node) = @_;
	return (1) if !$right_click_node;

	# DB NEW_WAYPOINT and NEW_ROUTE require a collection target.
	if ($panel eq 'database'
	 && ($cmd_id == $CTX_CMD_NEW_WAYPOINT || $cmd_id == $CTX_CMD_NEW_ROUTE))
	{
		my $rt = $right_click_node->{type} // '';
		if ($rt ne 'collection' && $rt ne 'root')
		{
			my $verb = ($cmd_id == $CTX_CMD_NEW_WAYPOINT) ? 'waypoint' : 'route';
			return (0, "db_new_${verb}_non_collection",
			        "new $verb target is not a collection",
			        'impl_error');
		}
	}

	return (1);
}


#----------------------------------------------------
# getNewMenuItems (SS11)
#----------------------------------------------------

sub getNewMenuItems
{
	my ($panel, $right_click_node) = @_;
	my @items = _getNewMenuItemsRaw($panel, $right_click_node);
	return grep {
		my ($ok) = _newRuleAllows($_->{id}, $panel, $right_click_node);
		$ok
	} @items;
}

sub _getNewMenuItemsRaw
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

	# e80 and fsh share the same New menu shape (no Branch concept on either)
	return (
		{ id => $CTX_CMD_NEW_GROUP,    label => 'New Group'    },
		{ id => $CTX_CMD_NEW_WAYPOINT, label => 'New Waypoint' },
	) if $t eq 'header' && $kind eq 'groups';

	return ({ id => $CTX_CMD_NEW_WAYPOINT, label => 'New Waypoint' })
		if $t eq 'my_waypoints' || $t eq 'group' || $t eq 'waypoint';

	return ({ id => $CTX_CMD_NEW_ROUTE, label => 'New Route' })
		if $t eq 'header' && $kind eq 'routes';

	return ();  # tracks header, track, route, route_point, track_group
}


#----------------------------------------------------
# getDeleteMenuItems (SS8)
# Route-ref and branch-safety checks are deferred to pre-flight in navOps.pm.
#----------------------------------------------------

sub getDeleteMenuItems
{
	my ($panel, $right_click_node, @nodes) = @_;
	my @items = _getDeleteMenuItemsRaw($panel, $right_click_node, @nodes);
	return grep {
		my ($ok) = _deleteRuleAllows($_->{id}, $panel, $right_click_node, @nodes);
		$ok
	} @items;
}

sub _getDeleteMenuItemsRaw
{
	my ($panel, $right_click_node, @nodes) = @_;
	my $t    = $right_click_node->{type}  // '';
	my $kind = $right_click_node->{kind}  // '';
	my $nt   = ($right_click_node->{data} // {})->{node_type} // '';
	my $ot   = ($right_click_node->{data} // {})->{obj_type}  // '';
	my $n    = @nodes ? scalar(@nodes) : 1;

	# track_group is a winFSH visual-only artifact -- a name-prefix
	# rollup of segmented tracks.  It has no storage identity and no
	# delete semantics; the user must delete the individual tracks.
	return () if $t eq 'track_group';

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

	# e80 and fsh share the same Delete menu shape -- both transports
	# have the same shallow hierarchy (Groups/Routes/Tracks headers,
	# named Groups, My Waypoints pseudo-group, route_points within
	# routes) and the same per-type delete semantics.
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
	return () if grep { my $t = $_->{type} // ''; $t eq 'root' || $t eq 'track_group' } @nodes;
	return ({ id => $CTX_CMD_COPY, label => 'Copy' });
}

sub getCutMenuItems
{
	my ($panel, @nodes) = @_;
	return () if !@nodes;
	return () if grep { my $t = $_->{type} // ''; $t eq 'root' || $t eq 'track_group' } @nodes;
	return ({ id => $CTX_CMD_CUT, label => 'Cut' });
}


#----------------------------------------------------
# getPasteMenuItems (SS10)
# Coarse destination check; full validation runs in pre-flight.
#----------------------------------------------------

sub getPasteMenuItems
{
	my ($panel, $right_click_node) = @_;
	my @items = _getPasteMenuItemsRaw($panel, $right_click_node);
	return grep {
		my ($ok) = _pasteRuleAllows($_->{id}, $panel, $right_click_node);
		$ok
	} @items;
}

sub _getPasteMenuItemsRaw
{
	my ($panel, $right_click_node) = @_;
	return () if !$clipboard;

	my $t    = $right_click_node->{type} // '';
	my $kind = $right_click_node->{kind} // '';
	my $nt   = ($right_click_node->{data} // {})->{node_type} // '';
	my $ot   = ($right_click_node->{data} // {})->{obj_type}  // '';
	my $cut  = $clipboard->{cut_flag};

	# E80 and FSH share the track_group exclusion (winFSH-only visual
	# artifact, no paste target).  Clicking on a specific track node is
	# also not a paste destination (use the tracks header instead).
	# Tracks-header is NOW a paste destination on both E80 and FSH
	# (E80 added 2026-05-28 via the TRACK writer-session protocol;
	# FSH was always a writer).
	if ($panel eq 'e80' || $panel eq 'fsh')
	{
		return () if $t eq 'track';
		return () if $t eq 'track_group';
	}

	# PASTE/PASTE_NEW: destination must be a collection (receives items into itself).
	# E80/FSH: header folders, my_waypoints, groups, and routes (route = ordered WP collection).
	# DB:      root, collection nodes (branch/group), and route object nodes (REF append).
	my $is_collection;
	if ($panel eq 'e80' || $panel eq 'fsh')
	{
		$is_collection = $t eq 'header'
		              || $t eq 'my_waypoints'
		              || $t eq 'group'
		              || $t eq 'route';
	}
	else
	{
		$is_collection = $t eq 'root'
		              || $t eq 'collection'
		              || ($t eq 'object' && $ot eq 'route');
	}

	# PASTE_BEFORE/AFTER: destination supports positional insertion (adjacent to, not into).
	# E80/FSH: route_point only. DB: any item or collection node except root.
	my $positional = ($panel eq 'e80' || $panel eq 'fsh')
		? ($t eq 'route_point')
		: ($t eq 'object' || $t eq 'route_point' || $t eq 'collection');

	my @items;
	if ($is_collection)
	{
		my $source             = $clipboard->{source} // '';
		my $class              = $clipboard->{clipboard_class} // '';
		# Source-spoke copy to DB uses class-driven paste-vs-push semantics
		# (paste = none on DB; push = all on DB; mixed = neither).  Applies
		# to E80-source and FSH-source clipboards alike.
		my $is_spoke_copy_to_db = ($panel eq 'database'
		                        && ($source eq 'e80' || $source eq 'fsh')
		                        && !$cut);

		if (!$is_spoke_copy_to_db)
		{
			push @items, { id => $CTX_CMD_PASTE, label => 'Paste' };
		}
		elsif ($class eq 'paste')
		{
			push @items, { id => $CTX_CMD_PASTE, label => 'Paste' };
		}
		elsif ($class eq 'push')
		{
			push @items, { id => $CTX_CMD_PUSH, label => 'Push' };
		}
		# mixed: no PASTE, no PUSH offered

		push @items, { id => $CTX_CMD_PASTE_NEW, label => 'Paste New' } if !$cut;
	}

	if ($positional)
	{
		# Non-NEW positional paste on a route_point anchor is only valid when the
		# entire clipboard consists of route_points (a within-route reorder). Any
		# non-route_point content must use PASTE_NEW to avoid collection/ownership confusion.
		my $allow_non_new = 1;
		if ($t eq 'route_point')
		{
			my @cb    = @{$clipboard->{items} // []};
			$allow_non_new = !grep { my $ct = $_->{type}//''; $ct ne 'route_point' && $ct ne 'waypoint' } @cb;
		}
		if ($allow_non_new)
		{
			push @items, { id => $CTX_CMD_PASTE_BEFORE, label => 'Paste Before' };
			push @items, { id => $CTX_CMD_PASTE_AFTER,  label => 'Paste After'  };
		}
		if (!$cut && $t ne 'route_point')
		{
			push @items, { id => $CTX_CMD_PASTE_NEW_BEFORE, label => 'Paste New Before' };
			push @items, { id => $CTX_CMD_PASTE_NEW_AFTER,  label => 'Paste New After'  };
		}
	}

	return @items;
}


#----------------------------------------------------
# getPushMenuItems
# Direct selection-based push (no clipboard required).
# Three-panel signature:
#   $peers = { wpmgr => $wpmgr_service_hash, fsh_db => $navFSH::fsh_db }
# Returns one menu item per available push direction.  Each spoke panel
# offers push to every OTHER panel where the selected items have matching
# UUIDs.  Phase 3A landed: panel->DB always; DB->{E80,FSH} when peers
# present.  Phase 3B added: E80->FSH and FSH->E80 cross-spoke pushes.
#
# Cmd-ID disambiguation:
#   CTX_CMD_PUSH      -> "the other side" when there is only one
#                        (E80 panel -> DB; FSH panel -> DB; DB panel -> E80)
#   CTX_CMD_PUSH_FSH  -> explicitly push to FSH (from DB or E80)
#   CTX_CMD_PUSH_E80  -> explicitly push to E80 (from FSH; DB uses CTX_CMD_PUSH)
#----------------------------------------------------

sub getPushMenuItems
{
	my ($panel, $peers, @nodes) = @_;
	$peers //= {};
	return () if !@nodes;
	return () if grep { my $t = $_->{type} // ''; $t eq 'root' || $t eq 'track_group' } @nodes;

	if ($panel eq 'e80')
	{
		my @items;
		push @items, { id => $CTX_CMD_PUSH,     label => 'Push to DB'  }
			if _e80NodesAllInDB(\@nodes);
		push @items, { id => $CTX_CMD_PUSH_FSH, label => 'Push to FSH' }
			if $peers->{fsh_db} && _e80NodesAllInFSH($peers->{fsh_db}, \@nodes);
		return @items;
	}

	if ($panel eq 'fsh')
	{
		my @items;
		push @items, { id => $CTX_CMD_PUSH,     label => 'Push to DB'  }
			if _fshNodesAllInDB(\@nodes);
		push @items, { id => $CTX_CMD_PUSH_E80, label => 'Push to E80' }
			if $peers->{wpmgr} && _fshNodesAllInE80($peers->{wpmgr}, \@nodes);
		return @items;
	}

	# database panel
	my @items;
	if ($peers->{wpmgr} && _dbNodesAllInE80($peers->{wpmgr}, \@nodes))
	{
		push @items, { id => $CTX_CMD_PUSH, label => 'Push to E80' };
	}
	if ($peers->{fsh_db} && _dbNodesAllInFSH($peers->{fsh_db}, \@nodes))
	{
		push @items, { id => $CTX_CMD_PUSH_FSH, label => 'Push to FSH' };
	}
	return @items;
}


sub _e80NodesAllInDB
{
	# E80 tree-node UUIDs are already navMate no-dash form (the NET
	# layer decodes them that way), so the DB lookup is direct.
	# Tracks are accepted as of 2026-05-27 with the writer-session
	# protocol enabling the reverse direction (DB->E80 PASTE/PASTE_NEW);
	# E80->DB PUSH for tracks updates the DB row's name/color/trk_uuid
	# from the E80-db state.
	my ($nodes) = @_;
	my $dbh = connectDB();
	return 0 if !$dbh;
	my $ok = 1;
	for my $node (@$nodes)
	{
		my $t    = $node->{type} // '';
		my $uuid = $node->{uuid} // '';
		if (!$uuid || $t eq 'header'
		           || $t eq 'my_waypoints' || $t eq 'route_point')
		{
			$ok = 0; last;
		}
		my $found;
		if    ($t eq 'waypoint') { $found = getWaypoint($dbh, $uuid);   }
		elsif ($t eq 'group')    { $found = getCollection($dbh, $uuid); }
		elsif ($t eq 'route')    { $found = getRoute($dbh, $uuid);      }
		elsif ($t eq 'track')    { $found = getTrack($dbh, $uuid);      }
		else                     { $ok = 0; last; }
		if (!$found) { $ok = 0; last; }
	}
	disconnectDB($dbh);
	return $ok;
}


sub _fshNodesAllInDB
{
	# FSH tree-node UUIDs are dashed-upper (the FSH key form).  Convert
	# to navMate no-dash form before DB lookup at the seam.
	my ($nodes) = @_;
	my $dbh = connectDB();
	return 0 if !$dbh;
	my $ok = 1;
	for my $node (@$nodes)
	{
		my $t        = $node->{type} // '';
		my $fsh_uuid = $node->{uuid} // '';
		if (!$fsh_uuid || $t eq 'track' || $t eq 'header'
		               || $t eq 'my_waypoints' || $t eq 'route_point')
		{
			$ok = 0; last;
		}
		my $uuid = fshToNavUUID($fsh_uuid);
		my $found;
		if    ($t eq 'waypoint') { $found = getWaypoint($dbh, $uuid);   }
		elsif ($t eq 'group')    { $found = getCollection($dbh, $uuid); }
		elsif ($t eq 'route')    { $found = getRoute($dbh, $uuid);      }
		else                     { $ok = 0; last; }
		if (!$found) { $ok = 0; last; }
	}
	disconnectDB($dbh);
	return $ok;
}


sub _dbNodesAllInE80
{
	# DB selection nodes carry navMate-form UUIDs; $wpmgr's per-type
	# hashes are keyed by the same form.  Direct lookup.
	# Track presence is checked against the TRACK service's live hash
	# (navOps::_track()->{tracks}), enabling "Push to E80" on DB tracks
	# whose mta_uuid is already on the E80.  (For tracks NOT on E80,
	# the menu won't show Push -- the user uses PASTE instead.)
	my ($wpmgr, $nodes) = @_;
	my $track_svc;   # lazy-loaded only if a track node appears
	for my $node (@$nodes)
	{
		my $t  = $node->{type}  // '';
		my $d  = $node->{data}  // {};
		my $ot = $d->{obj_type}  // '';
		my $nt = $d->{node_type} // '';
		my $uuid = $d->{uuid} // '';
		return 0 if !$uuid || $t eq 'root' || $t eq 'route_point';
		my $found;
		if ($t eq 'object')
		{
			if    ($ot eq 'waypoint') { $found = $wpmgr->{waypoints}{$uuid}; }
			elsif ($ot eq 'route')    { $found = $wpmgr->{routes}{$uuid};    }
			elsif ($ot eq 'track')
			{
				$track_svc //= navOps::_track();
				$found = $track_svc && $track_svc->{tracks}{$uuid};
			}
			else                      { return 0; }
		}
		elsif ($t eq 'collection')
		{
			if ($nt eq 'group') { $found = $wpmgr->{groups}{$uuid}; }
			else                { return 0; }
		}
		else { return 0; }
		return 0 if !$found;
	}
	return 1;
}


sub _dbNodesAllInFSH
{
	# DB selection nodes carry navMate-form UUIDs; FSH-db per-type
	# hashes are keyed by FSH dashed-upper.  Convert at the seam.
	my ($fsh_db, $nodes) = @_;
	for my $node (@$nodes)
	{
		my $t  = $node->{type}  // '';
		my $d  = $node->{data}  // {};
		my $ot = $d->{obj_type}  // '';
		my $nt = $d->{node_type} // '';
		my $uuid = $d->{uuid} // '';
		return 0 if !$uuid || $t eq 'root' || $t eq 'route_point';
		my $fsh_uuid = navToFSHUUID($uuid);
		my $found;
		if ($t eq 'object')
		{
			if    ($ot eq 'waypoint') { $found = $fsh_db->{waypoints}{$fsh_uuid}; }
			elsif ($ot eq 'route')    { $found = $fsh_db->{routes}{$fsh_uuid};    }
			else                      { return 0; }
		}
		elsif ($t eq 'collection')
		{
			if ($nt eq 'group') { $found = $fsh_db->{groups}{$fsh_uuid}; }
			else                { return 0; }
		}
		else { return 0; }
		return 0 if !$found;
	}
	return 1;
}


sub _e80NodesAllInFSH
{
	# E80 tree-node UUIDs are navMate no-dash form; FSH-db is keyed by
	# FSH dashed-upper.  Convert at the seam.  Walks group-embedded WPs
	# too since FSH stores group members as embedded records, not as
	# references to standalone WPT blocks.
	my ($fsh_db, $nodes) = @_;
	# Cache the union of standalone + embedded WP UUIDs as nav-form
	# strings (we will be checking 1..N of them).
	my %fsh_wp_have;
	for my $fu (keys %{$fsh_db->{waypoints} // {}})
	{
		$fsh_wp_have{fshToNavUUID($fu)} = 1;
	}
	for my $grp (values %{$fsh_db->{groups} // {}})
	{
		for my $wp (@{$grp->{wpts} // []})
		{
			$fsh_wp_have{fshToNavUUID($wp->{uuid})} = 1 if $wp->{uuid};
		}
	}
	for my $node (@$nodes)
	{
		my $t    = $node->{type} // '';
		my $uuid = $node->{uuid} // '';
		if (!$uuid || $t eq 'track' || $t eq 'header'
		           || $t eq 'my_waypoints' || $t eq 'route_point')
		{
			return 0;
		}
		my $fsh_uuid = navToFSHUUID($uuid);
		my $found;
		if    ($t eq 'waypoint') { $found = $fsh_wp_have{$uuid}; }
		elsif ($t eq 'group')    { $found = $fsh_db->{groups}{$fsh_uuid}; }
		elsif ($t eq 'route')    { $found = $fsh_db->{routes}{$fsh_uuid}; }
		else                     { return 0; }
		return 0 if !$found;
	}
	return 1;
}


sub _fshNodesAllInE80
{
	# FSH tree-node UUIDs are FSH dashed-upper; E80 WPMGR hashes are
	# keyed by navMate no-dash form.  Convert at the seam.
	# Track presence is checked against the TRACK service hash, enabling
	# "Push to E80" on FSH tracks whose mta_uuid is already on the E80
	# (cross-spoke PUSH semantics, parallel to the DB-side branch in
	# _dbNodesAllInE80).
	my ($wpmgr, $nodes) = @_;
	my $track_svc;   # lazy-loaded only if a track node appears
	for my $node (@$nodes)
	{
		my $t        = $node->{type} // '';
		my $fsh_uuid = $node->{uuid} // '';
		if (!$fsh_uuid || $t eq 'header'
		               || $t eq 'my_waypoints' || $t eq 'route_point')
		{
			return 0;
		}
		my $uuid = fshToNavUUID($fsh_uuid);
		my $found;
		if    ($t eq 'waypoint') { $found = $wpmgr->{waypoints}{$uuid}; }
		elsif ($t eq 'group')    { $found = $wpmgr->{groups}{$uuid};    }
		elsif ($t eq 'route')    { $found = $wpmgr->{routes}{$uuid};    }
		elsif ($t eq 'track')
		{
			$track_svc //= navOps::_track();
			$found = $track_svc && $track_svc->{tracks}{$uuid};
		}
		else                     { return 0; }
		return 0 if !$found;
	}
	return 1;
}


1;
