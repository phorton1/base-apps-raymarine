#!/usr/bin/perl
#---------------------------------------------
# nmOpsDB.pm
#---------------------------------------------
# Database-side operations for navMate context menu.
# Continues as package nmOps (loaded via require from nmOps.pm).

package nmOps;
use strict;
use warnings;
use Wx qw(:everything);
use Pub::Utils qw(display warning error getAppFrame);
use Pub::WX::Dialogs;
use c_db;
use a_defs;
use a_utils;
use nmDialogs;


my $ID_REPLACE     = 10901;
my $ID_SKIP        = 10902;
my $ID_REPLACE_ALL = 10903;
my $ID_SKIP_ALL    = 10904;
my $ID_ABORT       = 10905;


#----------------------------------------------------
# _refreshDatabaseWithDelete
#----------------------------------------------------

sub _refreshDatabaseWithDelete
{
	my (@uuids) = @_;
	my $frame = getAppFrame();
	my $pane  = $frame ? $frame->findPane($WIN_DATABASE) : undef;
	if ($pane)
	{
		$pane->onObjectsDeleted(@uuids) if @uuids;
		$pane->refresh();
	}
}


#----------------------------------------------------
# _resolveConflict — Replace/Skip/Abort dialog
#----------------------------------------------------

sub _resolveConflict
{
	my ($tree, $title, $item_name) = @_;

	if ($nmDialogs::suppress_confirm)
	{
		return ($nmDialogs::suppress_outcome eq 'reject') ? 'abort' : 'replace';
	}

	my $dlg = Wx::Dialog->new($tree // getAppFrame(), -1, $title,
		wxDefaultPosition, [-1, -1],
		wxDEFAULT_DIALOG_STYLE);

	my $vsizer    = Wx::BoxSizer->new(wxVERTICAL);
	my $btn_sizer = Wx::BoxSizer->new(wxHORIZONTAL);

	my $msg = "Waypoint '$item_name' already exists at the destination.\nReplace with the clipboard version?";
	$vsizer->Add(Wx::StaticText->new($dlg, -1, $msg), 0, wxALL, 12);

	$btn_sizer->Add(Wx::Button->new($dlg, $ID_REPLACE,     'Replace'),     0, wxRIGHT, 6);
	$btn_sizer->Add(Wx::Button->new($dlg, $ID_SKIP,        'Skip'),        0, wxRIGHT, 6);
	$btn_sizer->Add(Wx::Button->new($dlg, $ID_REPLACE_ALL, 'Replace All'), 0, wxRIGHT, 6);
	$btn_sizer->Add(Wx::Button->new($dlg, $ID_SKIP_ALL,    'Skip All'),    0, wxRIGHT, 6);
	$btn_sizer->Add(Wx::Button->new($dlg, $ID_ABORT,       'Abort'),       0);
	$vsizer->Add($btn_sizer, 0, wxALL | wxALIGN_CENTER, 12);

	$dlg->SetSizerAndFit($vsizer);
	$dlg->Centre();
	Wx::Event::EVT_BUTTON($dlg, -1, sub { $_[0]->EndModal($_[1]->GetId()) });
	Wx::Event::EVT_CLOSE($dlg,  sub { $_[1]->Veto() });

	my $result = $dlg->ShowModal();
	$dlg->Destroy();

	return 'replace'     if $result == $ID_REPLACE;
	return 'replace_all' if $result == $ID_REPLACE_ALL;
	return 'skip_all'    if $result == $ID_SKIP_ALL;
	return 'abort'       if $result == $ID_ABORT;
	return 'skip';
}


#----------------------------------------------------
# _wpFieldsDiffer
#----------------------------------------------------

sub _wpFieldsDiffer
{
	my ($existing, $new_data, $source) = @_;
	my @fields = qw(name comment lat lon);
	push @fields, qw(wp_type color depth_cm) if $source eq 'database';
	for my $f (@fields)
	{
		my $a = $existing->{$f} // '';
		my $b = $new_data->{$f} // '';
		if ($f eq 'lat' || $f eq 'lon')
		{
			my $an = abs($a + 0) > 900 ? ($a + 0) / 1e7 : $a + 0;
			my $bn = abs($b + 0) > 900 ? ($b + 0) / 1e7 : $b + 0;
			return 1 if abs($an - $bn) > 1e-7;
		}
		elsif ("$a" ne "$b")
		{
			return 1;
		}
	}
	return 0;
}


#----------------------------------------------------
# _insertFreshWaypoint
#----------------------------------------------------

sub _insertFreshWaypoint
{
	my ($dbh, $coll_uuid, $wp, $source) = @_;
	my $ts     = $wp->{created_ts} // $wp->{ts} // time();
	my $ts_src = $source eq 'e80' ? 'e80' : ($wp->{ts_source} // 'user');
	return insertWaypoint($dbh,
		name            => $wp->{name}    // '',
		comment         => $wp->{comment} // '',
		lat             => $wp->{lat},
		lon             => $wp->{lon},
		wp_type         => $wp->{wp_type} // $WP_TYPE_NAV,
		color           => $wp->{color},
		depth_cm        => $wp->{depth_cm} // $wp->{depth} // 0,
		created_ts      => $ts,
		ts_source       => $ts_src,
		source          => $wp->{source},
		collection_uuid => $coll_uuid,
	);
}


#----------------------------------------------------
# _pasteOneWaypointToDB — UUID-preserving paste
# Returns: 'created', 'replaced', 'skipped', 'no_change', 'aborted'
#----------------------------------------------------

sub _pasteOneWaypointToDB
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
		$$policy_ref = $action
			if $action eq 'replace_all' || $action eq 'skip_all' || $action eq 'abort';
	}

	return 'aborted' if $action eq 'abort';

	if ($action eq 'replace' || $action eq 'replace_all')
	{
		updateWaypoint($dbh, $uuid,
			name       => $wp->{name}    // '',
			comment    => $wp->{comment} // '',
			lat        => $wp->{lat},
			lon        => $wp->{lon},
			wp_type    => $wp->{wp_type} // $WP_TYPE_NAV,
			color      => $wp->{color},
			depth_cm   => $wp->{depth_cm} // $wp->{depth} // 0,
			created_ts => $ts,
			ts_source  => $ts_src,
			source     => $wp->{source},
		);
		return 'replaced';
	}

	return 'skipped';
}


#----------------------------------------------------
# Cut helpers — source deletion after successful paste
#----------------------------------------------------

sub _cutDatabaseWaypoint
{
	my ($uuid, $tree) = @_;
	my $dbh = connectDB();
	return if !$dbh;
	if (getWaypointRouteRefCount($dbh, $uuid) > 0)
	{
		disconnectDB($dbh);
		warning(0, 0, "_cutDatabaseWaypoint $uuid: in route(s) -- not removed from source");
		return;
	}
	deleteWaypoint($dbh, $uuid);
	disconnectDB($dbh);
	_refreshDatabaseWithDelete($uuid);
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
		warning(0, 0, "_cutDatabaseGroup $uuid: $remaining member(s) still present -- group not removed from source");
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
	_refreshDatabaseWithDelete($uuid);
}


sub _cutDatabaseTrack
{
	my ($uuid, $tree) = @_;
	my $dbh = connectDB();
	return if !$dbh;
	deleteTrack($dbh, $uuid);
	disconnectDB($dbh);
	_refreshDatabaseWithDelete($uuid);
}


#----------------------------------------------------
# _deleteDB — main delete dispatch
#----------------------------------------------------

sub _deleteDB
{
	my ($cmd_id, $right_click_node, $tree, @nodes) = @_;

	if ($cmd_id == $CTX_CMD_REMOVE_ROUTEPOINT)
	{
		my $node = $right_click_node;
		my $name = ($node->{data} // {})->{name} // $node->{uuid};
		return if !confirmDialog($tree, "Remove '$name' from route?", "Remove RoutePoint");
		my $dbh = connectDB();
		return if !$dbh;
		removeRoutePoint($dbh, $node->{route_uuid}, $node->{position});
		disconnectDB($dbh);
		_refreshDatabaseWithDelete($node->{uuid});
		return;
	}

	if ($cmd_id == $CTX_CMD_DELETE_WAYPOINT)
	{
		my $dbh = connectDB();
		return if !$dbh;
		for my $node (@nodes)
		{
			if (getWaypointRouteRefCount($dbh, $node->{data}{uuid}) > 0)
			{
				disconnectDB($dbh);
				warning(0, 0, "IMPLEMENTATION ERROR: _deleteDB: waypoint in route reached delete handler");
				return;
			}
		}
		disconnectDB($dbh);
		my $n   = scalar @nodes;
		my $msg = $n == 1
			? "Delete waypoint '$nodes[0]{data}{name}'?"
			: "Delete $n waypoints?";
		return if !confirmDialog($tree, $msg, "Confirm Delete");
		$dbh = connectDB();
		return if !$dbh;
		my @uuids = map { $_->{data}{uuid} } @nodes;
		deleteWaypoint($dbh, $_) for @uuids;
		disconnectDB($dbh);
		_refreshDatabaseWithDelete(@uuids);
		return;
	}

	if ($cmd_id == $CTX_CMD_DELETE_GROUP)
	{
		my $dbh = connectDB();
		return if !$dbh;
		my %group_info;
		my $total_wps = 0;
		for my $node (@nodes)
		{
			my $uuid = $node->{data}{uuid};
			my $coll = getCollection($dbh, $uuid);
			my $wps  = getGroupWaypoints($dbh, $uuid);
			$group_info{$uuid} = { parent_uuid => $coll->{parent_uuid}, wps => $wps };
			$total_wps += scalar @$wps;
		}
		disconnectDB($dbh);
		my $n = scalar @nodes;
		my $msg;
		if ($n == 1)
		{
			my $name = $nodes[0]{data}{name};
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
		for my $node (@nodes)
		{
			my $uuid = $node->{data}{uuid};
			my $info = $group_info{$uuid};
			moveWaypoint($dbh, $_->{uuid}, $info->{parent_uuid}) for @{$info->{wps}};
			deleteCollection($dbh, $uuid);
		}
		disconnectDB($dbh);
		_refreshDatabase();
		return;
	}

	if ($cmd_id == $CTX_CMD_DELETE_GROUP_WPS)
	{
		my $dbh = connectDB();
		return if !$dbh;
		my %group_wps;
		my $total_wps = 0;
		for my $node (@nodes)
		{
			my $uuid = $node->{data}{uuid};
			my $wps  = getGroupWaypoints($dbh, $uuid);
			for my $wp (@$wps)
			{
				if (getWaypointRouteRefCount($dbh, $wp->{uuid}) > 0)
				{
					disconnectDB($dbh);
					warning(0, 0, "IMPLEMENTATION ERROR: _deleteDB: group waypoint in route reached delete handler");
					return;
				}
			}
			$group_wps{$uuid} = $wps;
			$total_wps += scalar @$wps;
		}
		disconnectDB($dbh);
		my $n = scalar @nodes;
		my $msg;
		if ($n == 1)
		{
			$msg = $total_wps > 0
				? "Delete group '$nodes[0]{data}{name}' and its $total_wps waypoint(s)? Cannot be undone."
				: "Delete group '$nodes[0]{data}{name}'? Cannot be undone.";
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
		my @deleted_uuids;
		for my $node (@nodes)
		{
			my $uuid = $node->{data}{uuid};
			push @deleted_uuids, $_->{uuid} for @{$group_wps{$uuid}};
			deleteWaypoint($dbh, $_->{uuid}) for @{$group_wps{$uuid}};
			deleteCollection($dbh, $uuid);
		}
		disconnectDB($dbh);
		_refreshDatabaseWithDelete(@deleted_uuids);
		return;
	}

	if ($cmd_id == $CTX_CMD_DELETE_ROUTE)
	{
		my $n = scalar @nodes;
		my $msg;
		if ($n == 1)
		{
			my $dbh = connectDB();
			return if !$dbh;
			my $wpc = getRouteWaypointCount($dbh, $nodes[0]{data}{uuid});
			disconnectDB($dbh);
			$msg = $wpc > 0
				? "Delete route '$nodes[0]{data}{name}'? Its $wpc waypoint(s) will remain. Cannot be undone."
				: "Delete route '$nodes[0]{data}{name}'? Cannot be undone.";
		}
		else
		{
			$msg = "Delete $n routes? Their waypoints will remain. Cannot be undone.";
		}
		return if !confirmDialog($tree, $msg, "Delete Route");
		my $dbh = connectDB();
		return if !$dbh;
		my @uuids = map { $_->{data}{uuid} } @nodes;
		deleteRoute($dbh, $_) for @uuids;
		disconnectDB($dbh);
		_refreshDatabaseWithDelete(@uuids);
		return;
	}

	if ($cmd_id == $CTX_CMD_DELETE_TRACK)
	{
		my $n   = scalar @nodes;
		my $msg = $n == 1
			? "Delete track '$nodes[0]{data}{name}'?"
			: "Delete $n tracks?";
		return if !confirmDialog($tree, $msg, "Confirm Delete");
		my $dbh = connectDB();
		return if !$dbh;
		my @uuids = map { $_->{data}{uuid} } @nodes;
		deleteTrack($dbh, $_) for @uuids;
		disconnectDB($dbh);
		_refreshDatabaseWithDelete(@uuids);
		return;
	}

	if ($cmd_id == $CTX_CMD_DELETE_BRANCH)
	{
		# Branch-safety check was done in nmOps::_doDelete pre-flight
		my $node = $right_click_node;
		my $uuid = ($node->{data} // {})->{uuid};
		my $name = ($node->{data} // {})->{name} // '?';
		return if !confirmDialog($tree,
			"Delete branch '$name' and all its contents? Cannot be undone.",
			"Confirm Delete Branch");
		my $dbh = connectDB();
		return if !$dbh;
		my $wrgt  = getCollectionWRGTs($dbh, $uuid);
		my @uuids = (
			map { $_->{uuid} } @{$wrgt->{waypoints}},
			map { $_->{uuid} } @{$wrgt->{routes}},
			map { $_->{uuid} } @{$wrgt->{tracks}},
		);
		deleteBranch($dbh, $uuid);
		disconnectDB($dbh);
		_refreshDatabaseWithDelete(@uuids);
		return;
	}

	warning(0, 0, "_deleteDB: unhandled cmd_id=$cmd_id");
}


#----------------------------------------------------
# _pasteItemsToCollection — recursive paste helper
# Pastes items[] into target_uuid. Called by _pasteDB
# and recursively for groups and branches.
#----------------------------------------------------

sub _pasteItemsToCollection
{
	my ($dbh, $items, $target_uuid, $source, $fresh, $cut_flag, $tree, $policy_ref) = @_;

	for my $item (@$items)
	{
		last if $$policy_ref && $$policy_ref eq 'abort';
		my $t = $item->{type} // '';

		if ($t eq 'waypoint')
		{
			if ($fresh)
			{
				_insertFreshWaypoint($dbh, $target_uuid, $item->{data}, $source);
			}
			elsif ($cut_flag && $source eq 'database')
			{
				moveWaypoint($dbh, $item->{uuid}, $target_uuid);
			}
			else
			{
				my $result = _pasteOneWaypointToDB($dbh, $target_uuid, $tree, $item,
					$source, $policy_ref, 'Paste Waypoint');
				next if $$policy_ref && $$policy_ref eq 'abort';
				if ($cut_flag && $result ne 'skipped' && $result ne 'aborted')
				{
					$source eq 'e80'
						? nmOps::_cutE80Waypoint($item->{uuid}, $tree)
						: _cutDatabaseWaypoint($item->{uuid}, $tree);
				}
			}
		}
		elsif ($t eq 'group')
		{
			if ($fresh)
			{
				my $new_uuid = insertCollection($dbh,
					$item->{data}{name}    // '',
					$target_uuid,
					$NODE_TYPE_GROUP,
					$item->{data}{comment} // '');
				_pasteItemsToCollection($dbh, $item->{members} // [], $new_uuid,
					$source, 1, 0, $tree, $policy_ref);
			}
			elsif ($cut_flag && $source eq 'database' && $item->{uuid})
			{
				moveCollection($dbh, $item->{uuid}, $target_uuid);
			}
			else
			{
				my $group_uuid = $item->{uuid};
				if ($group_uuid && !getCollection($dbh, $group_uuid))
				{
					insertCollectionUUID($dbh, $group_uuid,
						$item->{data}{name}    // '',
						$target_uuid,
						$NODE_TYPE_GROUP,
						$item->{data}{comment} // '');
				}
				my $dest_uuid   = $group_uuid // $target_uuid;
				my $any_skipped = 0;
				for my $member (@{$item->{members} // []})
				{
					last if $$policy_ref && $$policy_ref eq 'abort';
					my $result = _pasteOneWaypointToDB($dbh, $dest_uuid, $tree, $member,
						$source, $policy_ref, 'Paste Group');
					$any_skipped = 1 if $result eq 'skipped';
					if ($cut_flag && $result ne 'skipped' && $result ne 'aborted')
					{
						$source eq 'e80'
							? nmOps::_cutE80Waypoint($member->{uuid}, $tree)
							: _cutDatabaseWaypoint($member->{uuid}, $tree);
					}
				}
				if ($cut_flag && !($$policy_ref && $$policy_ref eq 'abort') && !$any_skipped && $group_uuid)
				{
					$source eq 'e80'
						? nmOps::_cutE80Group($group_uuid, $tree)
						: _cutDatabaseGroup($group_uuid, $tree);
				}
			}
		}
		elsif ($t eq 'route')
		{
			if ($fresh)
			{
				my $route_data   = $item->{data};
				my $route_points = $item->{route_points} // [];
				my $route_color  = $source eq 'e80'
					? e80RouteIndexToAbgr($route_data->{color})
					: $route_data->{color};
				my @new_wp_uuids;
				for my $rp (@$route_points)
				{
					push @new_wp_uuids, _insertFreshWaypoint($dbh, $target_uuid, $rp->{data}, $source);
				}
				my $new_route_uuid = insertRoute($dbh,
					$route_data->{name}    // '',
					$route_color,
					$route_data->{comment} // '',
					$target_uuid);
				my $pos = 0;
				appendRouteWaypoint($dbh, $new_route_uuid, $_, $pos++) for @new_wp_uuids;
			}
			elsif ($cut_flag && $source eq 'database')
			{
				moveRoute($dbh, $item->{uuid}, $target_uuid);
			}
			else
			{
				my $route_uuid   = $item->{uuid};
				my $route_data   = $item->{data};
				my $route_points = $item->{route_points} // [];
				my $route_policy = undef;
				for my $rp (@$route_points)
				{
					last if $route_policy && $route_policy eq 'abort';
					my $result = _pasteOneWaypointToDB($dbh, $target_uuid, $tree, $rp,
						$source, \$route_policy, 'Paste Route');
					if ($cut_flag && $result ne 'skipped' && $result ne 'aborted')
					{
						$source eq 'e80'
							? nmOps::_cutE80Waypoint($rp->{uuid}, $tree)
							: _cutDatabaseWaypoint($rp->{uuid}, $tree);
					}
				}
				unless ($route_policy && $route_policy eq 'abort')
				{
					my $route_color = $source eq 'e80'
						? e80RouteIndexToAbgr($route_data->{color})
						: $route_data->{color};
					my $existing = getRoute($dbh, $route_uuid);
					if (!$existing)
					{
						insertRouteUUID($dbh, $route_uuid,
							$route_data->{name}    // '',
							$route_color,
							$route_data->{comment} // '',
							$target_uuid);
					}
					else
					{
						updateRoute($dbh, $route_uuid,
							$route_data->{name}    // '',
							$route_color,
							$route_data->{comment} // '');
					}
					clearRouteWaypoints($dbh, $route_uuid);
					my $pos = 0;
					for my $rp (@$route_points)
					{
						appendRouteWaypoint($dbh, $route_uuid, $rp->{uuid}, $pos++);
					}
					if ($cut_flag)
					{
						$source eq 'e80'
							? nmOps::_cutE80Route($route_uuid, $tree)
							: _cutDatabaseRoute($route_uuid, $tree);
					}
				}
			}
		}
		elsif ($t eq 'track')
		{
			if ($cut_flag && $source eq 'database' && !$fresh)
			{
				moveTrack($dbh, $item->{uuid}, $target_uuid);
			}
			elsif ($source eq 'database' && !$fresh)
			{
				warning(0, 0, "IMPLEMENTATION ERROR: _pasteItemsToCollection: UUID-preserving DB-to-DB track copy would create duplicate");
			}
			else
			{
				my $track       = $item->{data};
				my $pts         = $track->{points} // [];
				my $ts_start    = $track->{ts_start} // (@$pts ? ($pts->[0]{ts}  // 0) : 0);
				my $ts_end      = $track->{ts_end}   // (@$pts ? $pts->[-1]{ts}       : undef);
				my $ts_source   = $source eq 'e80' ? 'e80' : ($track->{ts_source} // 'user');
				my $track_color = $source eq 'e80'
					? e80TrackIndexToAbgr($track->{color})
					: $track->{color};
				my $track_uuid = insertTrack($dbh,
					name            => $track->{name} // '',
					color           => $track_color,
					ts_start        => $ts_start,
					ts_end          => $ts_end,
					ts_source       => $ts_source,
					point_count     => scalar @$pts,
					collection_uuid => $target_uuid,
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
				if ($cut_flag)
				{
					$source eq 'e80'
						? nmOps::_cutE80Track($item->{uuid}, $tree)
						: _cutDatabaseTrack($item->{uuid}, $tree);
				}
			}
		}
		elsif ($t eq 'branch')
		{
			if ($fresh)
			{
				my $new_uuid = insertCollection($dbh,
					$item->{data}{name}    // '',
					$target_uuid,
					$NODE_TYPE_BRANCH,
					$item->{data}{comment} // '');
				_pasteItemsToCollection($dbh, $item->{members} // [], $new_uuid,
					$source, 1, 0, $tree, $policy_ref);
			}
			elsif ($cut_flag && $source eq 'database' && $item->{uuid})
			{
				moveCollection($dbh, $item->{uuid}, $target_uuid);
			}
			else
			{
				my $branch_uuid = $item->{uuid};
				if ($branch_uuid && !getCollection($dbh, $branch_uuid))
				{
					insertCollectionUUID($dbh, $branch_uuid,
						$item->{data}{name}    // '',
						$target_uuid,
						$NODE_TYPE_BRANCH,
						$item->{data}{comment} // '');
				}
				my $dest_uuid = $branch_uuid // $target_uuid;
				_pasteItemsToCollection($dbh, $item->{members} // [], $dest_uuid,
					$source, 0, $cut_flag, $tree, $policy_ref);
			}
		}
		else
		{
			warning(0, 0, "_pasteItemsToCollection: unhandled item type=$t");
		}
	}
}


#----------------------------------------------------
# _pasteDB — main paste dispatch
#----------------------------------------------------

sub _pasteDB
{
	my ($cmd_id, $right_click_node, $tree, $items, $cb) = @_;
	my $source   = $cb->{source}   // '';
	my $cut_flag = $cb->{cut_flag} // 0;
	my $fresh    = ($cmd_id == $CTX_CMD_PASTE_NEW ||
	                $cmd_id == $CTX_CMD_PASTE_NEW_BEFORE ||
	                $cmd_id == $CTX_CMD_PASTE_NEW_AFTER);

	# PASTE_BEFORE/AFTER: insert clipboard waypoints as route points at a position
	if ($cmd_id == $CTX_CMD_PASTE_BEFORE    || $cmd_id == $CTX_CMD_PASTE_NEW_BEFORE ||
	    $cmd_id == $CTX_CMD_PASTE_AFTER     || $cmd_id == $CTX_CMD_PASTE_NEW_AFTER)
	{
		my $route_uuid = $right_click_node ? $right_click_node->{route_uuid} : undef;
		if (!$route_uuid)
		{
			warning(0, 0, "_pasteDB: PASTE_BEFORE/AFTER but no route_uuid in right_click_node");
			return;
		}

		my $pos        = $right_click_node->{position} // 0;
		my $insert_pos = ($cmd_id == $CTX_CMD_PASTE_BEFORE || $cmd_id == $CTX_CMD_PASTE_NEW_BEFORE)
			? $pos
			: $pos + 1;

		# Flatten items to waypoints
		my @wp_items;
		for my $item (@$items)
		{
			my $t = $item->{type} // '';
			if    ($t eq 'waypoint') { push @wp_items, $item }
			elsif ($t eq 'group')    { push @wp_items, @{$item->{members} // []} }
		}
		if (!@wp_items)
		{
			warning(0, 0, "_pasteDB: PASTE_BEFORE/AFTER: no waypoints to insert as route points");
			return;
		}

		my $n   = scalar @wp_items;
		my $dbh = connectDB();
		return if !$dbh;

		my $route_rec = getRoute($dbh, $route_uuid);
		my $coll_uuid = $route_rec ? $route_rec->{collection_uuid} : undef;
		if (!$coll_uuid)
		{
			disconnectDB($dbh);
			warning(0, 0, "_pasteDB: PASTE_BEFORE/AFTER: route $route_uuid not found");
			return;
		}

		# Shift existing route points to make room
		$dbh->do(
			"UPDATE route_waypoints SET position=position+? WHERE route_uuid=? AND position>=?",
			[$n, $route_uuid, $insert_pos]);

		# Insert or paste waypoints, collect resulting UUIDs
		my $policy = undef;
		my @new_uuids;
		my @to_cut;
		for my $item (@wp_items)
		{
			my $wp_uuid;
			if ($fresh)
			{
				$wp_uuid = _insertFreshWaypoint($dbh, $coll_uuid, $item->{data}, $source);
			}
			else
			{
				my $result = _pasteOneWaypointToDB($dbh, $coll_uuid, $tree, $item,
					$source, \$policy, 'Paste Route Point');
				if ($policy && $policy eq 'abort')
				{
					disconnectDB($dbh);
					_refreshDatabase();
					return;
				}
				$wp_uuid = $item->{uuid};
				push @to_cut, $item if $cut_flag && $result ne 'skipped' && $result ne 'aborted';
			}
			push @new_uuids, $wp_uuid if $wp_uuid;
		}

		# Append new route_waypoints at insert position
		for my $i (0 .. $#new_uuids)
		{
			appendRouteWaypoint($dbh, $route_uuid, $new_uuids[$i], $insert_pos + $i);
		}

		disconnectDB($dbh);

		# Cut source after DB work is done
		for my $item (@to_cut)
		{
			$source eq 'e80'
				? nmOps::_cutE80Waypoint($item->{uuid}, $tree)
				: _cutDatabaseWaypoint($item->{uuid}, $tree);
		}

		_refreshDatabase();
		return;
	}

	# Standard paste into a collection
	my $target_uuid = ($right_click_node->{data} // {})->{uuid};
	if (!$target_uuid)
	{
		warning(0, 0, "_pasteDB: no target collection uuid");
		return;
	}

	my $dbh = connectDB();
	return if !$dbh;
	my $policy = undef;
	_pasteItemsToCollection($dbh, $items, $target_uuid, $source, $fresh, $cut_flag, $tree, \$policy);
	disconnectDB($dbh);
	_refreshDatabase();
}


#----------------------------------------------------
# _newDatabaseWaypoint
#----------------------------------------------------

sub _newDatabaseWaypoint
{
	my ($right_click_node, $tree) = @_;

	if (($right_click_node->{type} // '') ne 'collection')
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _newDatabaseWaypoint: target is not a collection");
		return;
	}

	my $data = showNewWaypoint($tree);
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
		wp_type         => $WP_TYPE_NAV,
		color           => undef,
		depth_cm        => 0,
		created_ts      => time(),
		ts_source       => 'user',
		source          => undef,
		collection_uuid => $right_click_node->{data}{uuid},
	);
	disconnectDB($dbh);
	_refreshDatabase();
}


#----------------------------------------------------
# _newDatabaseRoute
#----------------------------------------------------

sub _newDatabaseRoute
{
	my ($right_click_node, $tree) = @_;

	if (($right_click_node->{type} // '') ne 'collection')
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _newDatabaseRoute: target is not a collection");
		return;
	}

	my $data = showNewRoute($tree);
	return if !defined($data);

	my $color = (defined $data->{color} && $data->{color} ne '') ? $data->{color} : undef;

	my $dbh = connectDB();
	return if !$dbh;
	insertRoute($dbh,
		$data->{name},
		$color,
		$data->{comment} // '',
		$right_click_node->{data}{uuid});
	disconnectDB($dbh);
	_refreshDatabase();
}


1;
