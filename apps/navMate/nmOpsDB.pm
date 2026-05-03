#!/usr/bin/perl
#---------------------------------------------
# nmOpsDB.pm
#---------------------------------------------
# Database-side (DB) context-menu operations for navMate.
# Continuation of package nmOps (loaded by nmOps.pm).

package nmOps;
use strict;
use warnings;
use Wx qw(:everything);
use Pub::Utils qw(display warning error);
use Pub::WX::Dialogs;
use c_db;
use a_defs;
use a_utils;
use nmDialogs;


#----------------------------------------------------
# New items
#----------------------------------------------------

sub _newDatabaseWaypoint
{
	my ($node, $tree) = @_;

	if (($node->{type} // '') ne 'collection')
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _newDatabaseWaypoint: target is not a collection");
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

	my $dbh = connectDB();
	return if !$dbh;
	insertWaypoint($dbh,
		name            => $data->{name},
		comment         => $data->{comment} // '',
		lat             => $lat,
		lon             => $lon,
		sym             => ($data->{sym} // 0) + 0,
		wp_type         => $WP_TYPE_NAV,
		color           => undef,
		depth_cm        => 0,
		created_ts      => time(),
		ts_source       => 'user',
		source          => undef,
		collection_uuid => $node->{data}{uuid},
	);
	disconnectDB($dbh);
	_refreshDatabase();
}


sub _newCollection
{
	my ($node, $tree, $label, $node_type) = @_;

	if (($node->{type} // '') !~ /^(collection|root)$/)
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _newCollection: target is neither collection nor root");
		return;
	}

	my $data = $node_type eq $NODE_TYPE_GROUP
		? nmDialogs::showNewGroup($tree)
		: nmDialogs::showNewBranch($tree);
	return if !defined($data);

	my $dbh = connectDB();
	return if !$dbh;
	insertCollection($dbh, $data->{name}, $node->{data}{uuid}, $node_type, $data->{comment});
	disconnectDB($dbh);
	_refreshDatabase();
}


sub _newDatabaseRoute
{
	my ($node, $tree) = @_;

	if (($node->{type} // '') ne 'collection')
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _newDatabaseRoute: target is not a collection");
		return;
	}

	my $data = nmDialogs::showNewRoute($tree);
	return if !defined($data);

	my $dbh = connectDB();
	return if !$dbh;
	insertRoute($dbh, $data->{name}, _parseColor($data->{color}), $data->{comment}, $node->{data}{uuid});
	disconnectDB($dbh);
	_refreshDatabase();
}


#----------------------------------------------------
# Remove / Delete
#----------------------------------------------------

sub _deleteDatabaseWaypoints
{
	my ($nodes, $tree) = @_;
	my $dbh = connectDB();
	return if !$dbh;
	for my $node (@$nodes)
	{
		if (getWaypointRouteRefCount($dbh, $node->{data}{uuid}) > 0)
		{
			disconnectDB($dbh);
			warning(0, 0, "IMPLEMENTATION ERROR: _deleteDatabaseWaypoints: waypoint in route reached delete handler");
			return;
		}
	}
	disconnectDB($dbh);
	my $n   = scalar @$nodes;
	my $msg = $n == 1
		? "Delete waypoint '$nodes->[0]{data}{name}'?"
		: "Delete $n waypoints?";
	return if !confirmDialog($tree, $msg, "Confirm Delete");
	$dbh = connectDB();
	return if !$dbh;
	deleteWaypoint($dbh, $_->{data}{uuid}) for @$nodes;
	disconnectDB($dbh);
	_refreshDatabase();
}


sub _deleteDatabaseCollection
{
	my ($node, $tree, $label) = @_;

	my $uuid = $node->{data}{uuid};
	my $name = $node->{data}{name};

	my $dbh = connectDB();
	return if !$dbh;
	my $counts = getCollectionCounts($dbh, $uuid);
	disconnectDB($dbh);

	my $total = $counts->{collections} + $counts->{waypoints}
	          + $counts->{routes}      + $counts->{tracks};
	if ($total > 0)
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _deleteDatabaseCollection: non-empty collection reached delete handler");
		return;
	}

	return if !confirmDialog($tree, "Delete $label '$name'?", "Confirm Delete");

	$dbh = connectDB();
	return if !$dbh;
	deleteCollection($dbh, $uuid);
	disconnectDB($dbh);
	_refreshDatabase();
}


sub _deleteDatabaseBranch
{
	my ($node, $tree) = @_;
	my $uuid = $node->{data}{uuid};
	my $name = $node->{data}{name};
	my $dbh  = connectDB();
	return if !$dbh;
	if (!isBranchDeleteSafe($dbh, $uuid))
	{
		disconnectDB($dbh);
		warning(0, 0, "DELETE BRANCH '$name': blocked — member waypoint(s) referenced by external route(s)");
		return;
	}
	disconnectDB($dbh);
	return if !confirmDialog($tree,
		"Delete branch '$name' and all its contents? Cannot be undone.",
		"Confirm Delete Branch");
	$dbh = connectDB();
	return if !$dbh;
	deleteBranch($dbh, $uuid);
	disconnectDB($dbh);
	_refreshDatabase();
}


sub _deleteDatabaseGroups
{
	my ($nodes, $tree) = @_;
	my $dbh = connectDB();
	return if !$dbh;
	my %group_info;
	my $total_wps = 0;
	for my $node (@$nodes)
	{
		my $uuid = $node->{data}{uuid};
		my $coll = getCollection($dbh, $uuid);
		my $wps  = getGroupWaypoints($dbh, $uuid);
		$group_info{$uuid} = { parent_uuid => $coll->{parent_uuid}, wps => $wps };
		$total_wps += scalar @$wps;
	}
	disconnectDB($dbh);
	my $n   = scalar @$nodes;
	my $msg;
	if ($n == 1)
	{
		my $name = $nodes->[0]{data}{name};
		$msg = $total_wps > 0
			? "Delete group '$name'? Its $total_wps waypoint(s) will be moved to the parent collection."
			: "Delete group '$name'?";
	}
	else
	{
		$msg = $total_wps > 0
			? "Delete $n groups? Their $total_wps waypoint(s) will be moved to the parent collection."
			: "Delete $n groups?";
	}
	return if !confirmDialog($tree, $msg, "Confirm Delete");
	$dbh = connectDB();
	return if !$dbh;
	for my $node (@$nodes)
	{
		my $uuid = $node->{data}{uuid};
		my $info = $group_info{$uuid};
		moveWaypoint($dbh, $_->{uuid}, $info->{parent_uuid}) for @{$info->{wps}};
		deleteCollection($dbh, $uuid);
	}
	disconnectDB($dbh);
	_refreshDatabase();
}


sub _deleteDatabaseGroupsAndWPs
{
	my ($nodes, $tree) = @_;
	my $dbh = connectDB();
	return if !$dbh;
	my %group_wps;
	my $total_wps = 0;
	for my $node (@$nodes)
	{
		my $uuid = $node->{data}{uuid};
		my $wps  = getGroupWaypoints($dbh, $uuid);
		for my $wp (@$wps)
		{
			if (getWaypointRouteRefCount($dbh, $wp->{uuid}) > 0)
			{
				disconnectDB($dbh);
				warning(0, 0, "IMPLEMENTATION ERROR: _deleteDatabaseGroupsAndWPs: waypoint in route reached delete handler");
				return;
			}
		}
		$group_wps{$uuid} = $wps;
		$total_wps += scalar @$wps;
	}
	disconnectDB($dbh);
	my $n   = scalar @$nodes;
	my $msg;
	if ($n == 1)
	{
		$msg = $total_wps > 0
			? "Delete group '$nodes->[0]{data}{name}' and its $total_wps waypoint(s)? Cannot be undone."
			: "Delete group '$nodes->[0]{data}{name}'? Cannot be undone.";
	}
	else
	{
		$msg = $total_wps > 0
			? "Delete $n groups and their $total_wps waypoint(s)? Cannot be undone."
			: "Delete $n groups? Cannot be undone.";
	}
	return if !confirmDialog($tree, $msg, "Delete Groups + Waypoints");
	$dbh = connectDB();
	return if !$dbh;
	for my $node (@$nodes)
	{
		my $uuid = $node->{data}{uuid};
		deleteWaypoint($dbh, $_->{uuid}) for @{$group_wps{$uuid}};
		deleteCollection($dbh, $uuid);
	}
	disconnectDB($dbh);
	_refreshDatabase();
}


sub _removeDatabaseRoutePoint
{
	my ($node, $tree) = @_;

	my $wp   = $node->{data};
	my $name = $wp ? ($wp->{name} // $node->{uuid}) : $node->{uuid};

	return if !confirmDialog($tree, "Remove '$name' from route?", "Remove RoutePoint");

	my $dbh = connectDB();
	return if !$dbh;
	removeRoutePoint($dbh, $node->{route_uuid}, $node->{position});
	disconnectDB($dbh);
	_refreshDatabase();
}


sub _deleteDatabaseRoutes
{
	my ($nodes, $tree) = @_;
	my $n = scalar @$nodes;
	my $msg;
	if ($n == 1)
	{
		my $dbh = connectDB();
		return if !$dbh;
		my $wpc = getRouteWaypointCount($dbh, $nodes->[0]{data}{uuid});
		disconnectDB($dbh);
		$msg = $wpc > 0
			? "Delete route '$nodes->[0]{data}{name}'? Its $wpc waypoint(s) will remain. Cannot be undone."
			: "Delete route '$nodes->[0]{data}{name}'? Cannot be undone.";
	}
	else
	{
		$msg = "Delete $n routes? Their waypoints will remain. Cannot be undone.";
	}
	return if !confirmDialog($tree, $msg, "Delete Route");
	my $dbh = connectDB();
	return if !$dbh;
	deleteRoute($dbh, $_->{data}{uuid}) for @$nodes;
	disconnectDB($dbh);
	_refreshDatabase();
}


sub _deleteDatabaseTracks
{
	my ($nodes, $tree) = @_;
	my $n   = scalar @$nodes;
	my $msg = $n == 1
		? "Delete track '$nodes->[0]{data}{name}'?"
		: "Delete $n tracks?";
	return if !confirmDialog($tree, $msg, "Confirm Delete");
	my $dbh = connectDB();
	return if !$dbh;
	deleteTrack($dbh, $_->{data}{uuid}) for @$nodes;
	disconnectDB($dbh);
	_refreshDatabase();
}


#----------------------------------------------------
# Paste
#----------------------------------------------------

sub _pasteOneWaypointToDB
	# UUID-preserving inner helper used by all database paste handlers.
	# Returns: 'created', 'replaced', 'skipped', 'no_change', 'aborted'.
{
	my ($dbh, $coll_uuid, $tree, $item, $source, $policy_ref, $title) = @_;
	my $wp   = $item->{data};
	my $uuid = $item->{uuid};

	return 'aborted' if $$policy_ref && $$policy_ref eq 'abort';

	my $ts     = $wp->{created_ts} // $wp->{ts} // time();
	my $ts_src = $source eq 'e80' ? 'e80' : ($wp->{ts_source} // 'user');

	my $existing = getWaypoint($dbh, $uuid);

	if (!$existing)
	{
		insertWaypoint($dbh,
			uuid            => $uuid,
			name            => $wp->{name}    // '',
			comment         => $wp->{comment} // '',
			lat             => $wp->{lat},
			lon             => $wp->{lon},
			sym             => $wp->{sym}     // 0,
			wp_type         => $wp->{wp_type} // $WP_TYPE_NAV,
			color           => $wp->{color},
			depth_cm        => $wp->{depth_cm} // $wp->{depth} // 0,
			created_ts      => $ts,
			ts_source       => $ts_src,
			source          => $wp->{source},
			collection_uuid => $coll_uuid,
		);
		return 'created';
	}

	return 'no_change' if !_wpFieldsDiffer($existing, $wp, $source);

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
		$action = _resolveConflict($tree, $title, $wp->{name} // $uuid);
		$$policy_ref = $action if $action eq 'replace_all' || $action eq 'skip_all' || $action eq 'abort';
	}

	return 'aborted' if $action eq 'abort';

	if ($action eq 'replace' || $action eq 'replace_all')
	{
		updateWaypoint($dbh, $uuid,
			name      => $wp->{name}    // '',
			comment   => $wp->{comment} // '',
			lat       => $wp->{lat},
			lon       => $wp->{lon},
			sym       => $wp->{sym}     // 0,
			wp_type   => $wp->{wp_type} // $WP_TYPE_NAV,
			color     => $wp->{color},
			depth_cm  => $wp->{depth_cm} // $wp->{depth} // 0,
			created_ts => $ts,
			ts_source => $ts_src,
			source    => $wp->{source},
		);
		return 'replaced';
	}

	return 'skipped';
}


sub _pasteWaypointToDatabase
{
	my ($node, $tree, $item, $cb) = @_;

	if (($node->{type} // '') !~ /^(collection|root)$/)
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _pasteWaypointToDatabase: target is neither collection nor root");
		return;
	}

	if ($cb->{source} eq 'database' && $cb->{cut})
	{
		my $dbh = connectDB();
		return if !$dbh;
		moveWaypoint($dbh, $item->{uuid}, $node->{data}{uuid});
		disconnectDB($dbh);
		_refreshDatabase();
		return;
	}

	my $dbh = connectDB();
	return if !$dbh;
	my $policy = undef;
	my $result = _pasteOneWaypointToDB($dbh, $node->{data}{uuid}, $tree, $item,
		$cb->{source}, \$policy, 'Paste Waypoint');
	disconnectDB($dbh);
	if ($cb->{cut} && $result ne 'skipped' && $result ne 'aborted')
	{
		$cb->{source} eq 'e80'
			? _cutE80Waypoint($item->{uuid}, $tree)
			: _cutDatabaseWaypoint($item->{uuid}, $tree);
	}
	_refreshDatabase();
}


sub _pasteGroupToDatabase
{
	my ($node, $tree, $item, $cb) = @_;

	if (($node->{type} // '') !~ /^(collection|root)$/)
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _pasteGroupToDatabase: target is neither collection nor root");
		return;
	}

	if ($cb->{source} eq 'database' && $cb->{cut})
	{
		return if !$item->{uuid};
		my $dbh = connectDB();
		return if !$dbh;
		moveCollection($dbh, $item->{uuid}, $node->{data}{uuid});
		disconnectDB($dbh);
		_refreshDatabase();
		return;
	}

	my $target_uuid = $node->{data}{uuid};
	my $group_uuid  = $item->{uuid};
	my $group_data  = $item->{data};
	my $members     = $item->{members} // [];
	my $source      = $cb->{source};

	my $dbh = connectDB();
	return if !$dbh;

	# Ensure group collection exists under target; group=merge keeps existing members.
	if ($group_uuid && !getCollection($dbh, $group_uuid))
	{
		insertCollectionUUID($dbh, $group_uuid,
			$group_data->{name}    // '',
			$target_uuid,
			$NODE_TYPE_GROUP,
			$group_data->{comment} // '');
	}

	# Paste member WPs into the group collection (or target if no group UUID).
	my $dest_uuid = $group_uuid // $target_uuid;
	my $policy      = undef;
	my $any_skipped = 0;
	for my $member (@$members)
	{
		my $result = _pasteOneWaypointToDB($dbh, $dest_uuid, $tree, $member, $source, \$policy, 'Paste Group');
		last if $policy && $policy eq 'abort';
		$any_skipped = 1 if $result eq 'skipped';
		if ($cb->{cut} && $result ne 'skipped' && $result ne 'aborted')
		{
			$source eq 'e80'
				? _cutE80Waypoint($member->{uuid}, $tree)
				: _cutDatabaseWaypoint($member->{uuid}, $tree);
		}
	}

	my $aborted = ($policy && $policy eq 'abort');
	if ($cb->{cut} && !$aborted && !$any_skipped && $group_uuid)
	{
		$source eq 'e80'
			? _cutE80Group($group_uuid, $tree)
			: _cutDatabaseGroup($group_uuid, $tree);
	}

	disconnectDB($dbh);
	_refreshDatabase();
}


sub _pasteRouteToDatabase
{
	my ($node, $tree, $item, $cb) = @_;

	if (($node->{type} // '') !~ /^(collection|root)$/)
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _pasteRouteToDatabase: target is neither collection nor root");
		return;
	}

	if ($cb->{source} eq 'database' && $cb->{cut})
	{
		my $dbh = connectDB();
		return if !$dbh;
		moveRoute($dbh, $item->{uuid}, $node->{data}{uuid});
		disconnectDB($dbh);
		_refreshDatabase();
		return;
	}

	my $target_uuid = $node->{data}{uuid};
	my $route_uuid  = $item->{uuid};
	my $route_data  = $item->{data};
	my $members     = $item->{members} // [];
	my $source      = $cb->{source};

	my $dbh = connectDB();
	return if !$dbh;

	# Paste member WPs into the target collection (UUID-preserving).
	my $policy = undef;
	for my $member (@$members)
	{
		my $result = _pasteOneWaypointToDB($dbh, $target_uuid, $tree, $member, $source, \$policy, 'Paste Route');
		last if $policy && $policy eq 'abort';
		if ($cb->{cut} && $result ne 'skipped' && $result ne 'aborted')
		{
			$source eq 'e80'
				? _cutE80Waypoint($member->{uuid}, $tree)
				: _cutDatabaseWaypoint($member->{uuid}, $tree);
		}
	}

	if ($policy && $policy eq 'abort')
	{
		disconnectDB($dbh);
		_refreshDatabase();
		return;
	}

	# Insert or update the route record; route=set replaces the waypoint list.
	my $existing_route = getRoute($dbh, $route_uuid);
	if (!$existing_route)
	{
		insertRouteUUID($dbh, $route_uuid,
			$route_data->{name}    // '',
			$route_data->{color}   // 0,
			$route_data->{comment} // '',
			$target_uuid);
	}
	else
	{
		updateRoute($dbh, $route_uuid,
			$route_data->{name}    // '',
			$route_data->{color}   // 0,
			$route_data->{comment} // '');
	}

	clearRouteWaypoints($dbh, $route_uuid);
	my $pos = 0;
	for my $member (@$members)
	{
		appendRouteWaypoint($dbh, $route_uuid, $member->{uuid}, $pos++);
	}

	if ($cb->{cut})
	{
		$source eq 'e80'
			? _cutE80Route($route_uuid, $tree)
			: _cutDatabaseRoute($route_uuid, $tree);
	}

	disconnectDB($dbh);
	_refreshDatabase();
}


sub _pasteTrackToDatabase
{
	my ($node, $tree, $item, $cb) = @_;

	if (($node->{type} // '') !~ /^(collection|root)$/)
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _pasteTrackToDatabase: target is neither collection nor root");
		return;
	}

	my $coll_uuid = $node->{data}{uuid};

	if ($cb->{source} eq 'database' && $cb->{cut})
	{
		my $dbh = connectDB();
		return if !$dbh;
		moveTrack($dbh, $item->{uuid}, $coll_uuid);
		disconnectDB($dbh);
		_refreshDatabase();
		return;
	}

	if ($cb->{source} eq 'database' && !$cb->{cut})
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _pasteTrackToDatabase: UUID-preserving DB-to-DB copy would create a duplicate; canPaste should have blocked this");
		return;
	}

	my $track     = $item->{data};
	my $pts       = $track->{points} // [];
	my $ts_start  = $track->{ts_start} // (@$pts ? ($pts->[0]{ts}  // 0) : 0);
	my $ts_end    = $track->{ts_end}   // (@$pts ? $pts->[-1]{ts}  : undef);
	my $ts_source = ($cb->{source} eq 'e80') ? 'e80' : ($track->{ts_source} // 'user');

	my $dbh = connectDB();
	return if !$dbh;
	my $track_uuid = insertTrack($dbh,
		name            => $track->{name} // '',
		color           => $track->{color} // 0,
		ts_start        => $ts_start,
		ts_end          => $ts_end,
		ts_source       => $ts_source,
		point_count     => scalar @$pts,
		collection_uuid => $coll_uuid,
	);
	if (@$pts)
	{
		my @db_pts = map {{
			lat      => $_->{lat},
			lon      => $_->{lon},
			depth_cm => $_->{depth_cm} // $_->{depth},
			temp_k   => $_->{temp_k}   // $_->{tempr},
			ts       => $_->{ts},
		}} @$pts;
		insertTrackPoints($dbh, $track_uuid, \@db_pts);
	}
	disconnectDB($dbh);
	if ($cb->{cut})
	{
		$cb->{source} eq 'e80'
			? _cutE80Track($item->{uuid}, $tree)
			: _cutDatabaseTrack($item->{uuid}, $tree);
	}
	_refreshDatabase();
}


#----------------------------------------------------
# Paste New — always fresh UUIDs, no conflict check
#----------------------------------------------------

sub _insertFreshWaypoint
	# Inserts a WP with a fresh UUID. Returns the new UUID.
{
	my ($dbh, $coll_uuid, $wp, $source) = @_;
	my $ts     = $wp->{created_ts} // $wp->{ts} // time();
	my $ts_src = $source eq 'e80' ? 'e80' : ($wp->{ts_source} // 'user');
	return insertWaypoint($dbh,
		name            => $wp->{name}    // '',
		comment         => $wp->{comment} // '',
		lat             => $wp->{lat},
		lon             => $wp->{lon},
		sym             => $wp->{sym}     // 0,
		wp_type         => $wp->{wp_type} // $WP_TYPE_NAV,
		color           => $wp->{color},
		depth_cm        => $wp->{depth_cm} // $wp->{depth} // 0,
		created_ts      => $ts,
		ts_source       => $ts_src,
		source          => $wp->{source},
		collection_uuid => $coll_uuid,
	);
}


sub _pasteNewWaypointToDatabase
{
	my ($node, $tree, $item, $cb) = @_;

	if (($node->{type} // '') !~ /^(collection|root)$/)
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _pasteNewWaypointToDatabase: target is neither collection nor root");
		return;
	}

	my $dbh = connectDB();
	return if !$dbh;
	_insertFreshWaypoint($dbh, $node->{data}{uuid}, $item->{data}, $cb->{source});
	disconnectDB($dbh);
	_refreshDatabase();
}


sub _pasteNewGroupToDatabase
{
	my ($node, $tree, $item, $cb) = @_;

	if (($node->{type} // '') !~ /^(collection|root)$/)
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _pasteNewGroupToDatabase: target is neither collection nor root");
		return;
	}

	my $target_uuid = $node->{data}{uuid};
	my $group_data  = $item->{data};
	my $members     = $item->{members} // [];

	my $dbh = connectDB();
	return if !$dbh;

	my $new_group_uuid = insertCollection($dbh,
		$group_data->{name}    // '',
		$target_uuid,
		$NODE_TYPE_GROUP,
		$group_data->{comment} // '');

	for my $member (@$members)
	{
		_insertFreshWaypoint($dbh, $new_group_uuid, $member->{data}, $cb->{source});
	}

	disconnectDB($dbh);
	_refreshDatabase();
}


sub _pasteNewRouteToDatabase
{
	my ($node, $tree, $item, $cb) = @_;

	if (($node->{type} // '') !~ /^(collection|root)$/)
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _pasteNewRouteToDatabase: target is neither collection nor root");
		return;
	}

	my $target_uuid = $node->{data}{uuid};
	my $route_data  = $item->{data};
	my $members     = $item->{members} // [];

	my $dbh = connectDB();
	return if !$dbh;

	# Insert member WPs with fresh UUIDs; collect them for the route waypoint list.
	my @new_wp_uuids;
	for my $member (@$members)
	{
		push @new_wp_uuids,
			_insertFreshWaypoint($dbh, $target_uuid, $member->{data}, $cb->{source});
	}

	my $new_route_uuid = insertRoute($dbh,
		$route_data->{name}    // '',
		$route_data->{color}   // 0,
		$route_data->{comment} // '',
		$target_uuid);

	my $pos = 0;
	for my $new_uuid (@new_wp_uuids)
	{
		appendRouteWaypoint($dbh, $new_route_uuid, $new_uuid, $pos++);
	}

	disconnectDB($dbh);
	_refreshDatabase();
}


#----------------------------------------------------
# Cut — source deletion after successful paste
#----------------------------------------------------

sub _cutDatabaseWaypoint
{
	my ($uuid, $tree) = @_;
	my $dbh = connectDB();
	return if !$dbh;
	if (getWaypointRouteRefCount($dbh, $uuid) > 0)
	{
		disconnectDB($dbh);
		warning(0,0,"_cutDatabaseWaypoint $uuid: in route(s) — not removed from source");
		return;
	}
	deleteWaypoint($dbh, $uuid);
	disconnectDB($dbh);
	_refreshDatabase();
}


sub _cutDatabaseGroup
{
	my ($uuid, $tree) = @_;
	return if !defined $uuid;
	my $dbh = connectDB();
	return if !$dbh;
	my $counts    = getCollectionCounts($dbh, $uuid);
	my $remaining = ($counts->{waypoints} // 0) + ($counts->{routes} // 0) + ($counts->{tracks} // 0);
	if ($remaining > 0)
	{
		disconnectDB($dbh);
		warning(0, 0, "_cutDatabaseGroup $uuid: $remaining member(s) still present (in route?) — group not removed from source");
		return;
	}
	deleteCollection($dbh, $uuid);
	disconnectDB($dbh);
	_refreshDatabase();
}


sub _cutDatabaseRoute
{
	my ($uuid, $tree) = @_;
	my $dbh = connectDB();
	return if !$dbh;
	deleteRoute($dbh, $uuid);
	disconnectDB($dbh);
	_refreshDatabase();
}


sub _cutDatabaseTrack
{
	my ($uuid, $tree) = @_;
	my $dbh = connectDB();
	return if !$dbh;
	deleteTrack($dbh, $uuid);
	disconnectDB($dbh);
	_refreshDatabase();
}


1;
