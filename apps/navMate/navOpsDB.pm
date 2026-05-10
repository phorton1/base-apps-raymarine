#!/usr/bin/perl
#---------------------------------------------
# navOpsDB.pm
#---------------------------------------------
# Database-side operations for navMate context menu.
# Continues as package navOps (loaded via require from navOps.pm).

package navOps;
use strict;
use warnings;
use Wx qw(:everything);
use Pub::Utils qw(display warning error getAppFrame);
use Pub::WX::Dialogs;
use navDB;
use n_defs;
use n_utils;
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
# _resolveConflict - Replace/Skip/Abort dialog
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
# _pasteOneWaypointToDB - UUID-preserving paste
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

	if ($source eq 'e80')
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
# Cut helpers - source deletion after successful paste
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
# _deleteDB - main delete dispatch
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
		# Branch-safety check was done in navOps::_doDelete pre-flight
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
			(map { $_->{uuid} } @{$wrgt->{waypoints}}),
			(map { $_->{uuid} } @{$wrgt->{routes}}),
			(map { $_->{uuid} } @{$wrgt->{tracks}}),
		);
		deleteBranch($dbh, $uuid);
		disconnectDB($dbh);
		_refreshDatabaseWithDelete(@uuids);
		return;
	}

	warning(0, 0, "_deleteDB: unhandled cmd_id=$cmd_id");
}


#----------------------------------------------------
# _pasteItemsToCollection - recursive paste helper
# Pastes items[] into target_uuid. Called by _pasteDB
# and recursively for groups and branches.
#----------------------------------------------------

sub _pasteItemsToCollection
{
	my ($dbh, $items, $target_uuid, $source, $fresh, $cut_flag, $tree, $policy_ref) = @_;

	# SS12.1: E80-source pastes must process waypoints/groups before routes.
	my @ordered_items;
	if ($source eq 'e80')
	{
		push @ordered_items, grep { ($_->{type}//'') ne 'route' } @$items;
		push @ordered_items, grep { ($_->{type}//'') eq 'route' } @$items;
	}
	else
	{
		@ordered_items = @$items;
	}

	for my $item (@ordered_items)
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
						? navOps::_cutE80Waypoint($item->{uuid}, $tree)
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
							? navOps::_cutE80Waypoint($member->{uuid}, $tree)
							: _cutDatabaseWaypoint($member->{uuid}, $tree);
					}
				}
				if ($cut_flag && !($$policy_ref && $$policy_ref eq 'abort') && !$any_skipped && $group_uuid)
				{
					$source eq 'e80'
						? navOps::_cutE80Group($group_uuid, $tree)
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
				my $new_route_uuid = insertRoute($dbh,
					$route_data->{name}    // '',
					$route_color,
					$route_data->{comment} // '',
					$target_uuid);
				my $pos = 0;
				appendRouteWaypoint($dbh, $new_route_uuid, $_->{uuid}, $pos++) for @$route_points;
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
				my $route_color  = $source eq 'e80'
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
				appendRouteWaypoint($dbh, $route_uuid, $_->{uuid}, $pos++) for @$route_points;
				if ($cut_flag)
				{
					$source eq 'e80'
						? navOps::_cutE80Route($route_uuid, $tree)
						: _cutDatabaseRoute($route_uuid, $tree);
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
					($source eq 'e80' && !$fresh ? (uuid => $item->{uuid}) : ()),
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
						? navOps::_cutE80Track($item->{uuid}, $tree)
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
# _pasteDB - main paste dispatch
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
			# Collection-member path: anchor is any item in a container
			# (waypoint, route, track, group, or branch). Supports the full
			# real-number position ordering scheme across all item types.
			my $anchor_uuid = $right_click_node ? ($right_click_node->{data} // {})->{uuid} : undef;
			my $anchor_type = $right_click_node ? ($right_click_node->{type} // '')          : '';
			my $anchor_ot   = ($right_click_node->{data} // {})->{obj_type} // '';

			if (!$anchor_uuid)
			{
				warning(0, 0, "_pasteDB: PASTE_BEFORE/AFTER: no anchor uuid in right_click_node");
				return;
			}

			my $dbh = connectDB();
			return if !$dbh;

			# Look up anchor's container (coll_uuid) and its position within it.
			my ($coll_uuid, $anchor_pos);
			if ($anchor_type eq 'object' && $anchor_ot eq 'waypoint')
			{
				my $rec = getWaypoint($dbh, $anchor_uuid);
				if (!$rec) { disconnectDB($dbh); warning(0, 0, "_pasteDB: PASTE_BEFORE/AFTER anchor waypoint $anchor_uuid not found"); return; }
				$coll_uuid  = $rec->{collection_uuid};
				$anchor_pos = $rec->{position} // 0;
			}
			elsif ($anchor_type eq 'object' && $anchor_ot eq 'route')
			{
				my $rec = getRoute($dbh, $anchor_uuid);
				if (!$rec) { disconnectDB($dbh); warning(0, 0, "_pasteDB: PASTE_BEFORE/AFTER anchor route $anchor_uuid not found"); return; }
				$coll_uuid  = $rec->{collection_uuid};
				$anchor_pos = $rec->{position} // 0;
			}
			elsif ($anchor_type eq 'object' && $anchor_ot eq 'track')
			{
				my $rec = getTrack($dbh, $anchor_uuid);
				if (!$rec) { disconnectDB($dbh); warning(0, 0, "_pasteDB: PASTE_BEFORE/AFTER anchor track $anchor_uuid not found"); return; }
				$coll_uuid  = $rec->{collection_uuid};
				$anchor_pos = $rec->{position} // 0;
			}
			elsif ($anchor_type eq 'collection')
			{
				my $rec = getCollection($dbh, $anchor_uuid);
				if (!$rec) { disconnectDB($dbh); warning(0, 0, "_pasteDB: PASTE_BEFORE/AFTER anchor collection $anchor_uuid not found"); return; }
				$coll_uuid  = $rec->{parent_uuid};
				$anchor_pos = $rec->{position} // 0;
			}
			else
			{
				disconnectDB($dbh);
				warning(0, 0, "_pasteDB: PASTE_BEFORE/AFTER: unhandled anchor type=$anchor_type ot=$anchor_ot");
				return;
			}

			# Cross-table neighbor query: find the nearest occupied position across
			# all item types in the same container.
			my $is_before = ($cmd_id == $CTX_CMD_PASTE_BEFORE || $cmd_id == $CTX_CMD_PASTE_NEW_BEFORE);
			my ($cmp, $agg) = $is_before ? ('<', 'MAX') : ('>', 'MIN');
			my $nbr_rec = $dbh->get_record(
				"SELECT $agg(p) AS position FROM ("
				. "SELECT position AS p FROM waypoints   WHERE collection_uuid=? AND position$cmp?"
				. " UNION ALL "
				. "SELECT position AS p FROM routes      WHERE collection_uuid=? AND position$cmp?"
				. " UNION ALL "
				. "SELECT position AS p FROM tracks      WHERE collection_uuid=? AND position$cmp?"
				. " UNION ALL "
				. "SELECT position AS p FROM collections WHERE parent_uuid=?    AND position$cmp?"
				. ")",
				[$coll_uuid, $anchor_pos, $coll_uuid, $anchor_pos,
				 $coll_uuid, $anchor_pos, $coll_uuid, $anchor_pos]);
			my $nbr_pos = (defined $nbr_rec && defined $nbr_rec->{position})
				? $nbr_rec->{position}
				: ($is_before ? $anchor_pos - 2.0 : $anchor_pos + 2.0);
			my ($low, $high) = $is_before ? ($nbr_pos, $anchor_pos) : ($anchor_pos, $nbr_pos);

			# Accept any positionable item type from the clipboard.
			my @coll_items;
			for my $item (@$items)
			{
				my $t = $item->{type} // '';
				push @coll_items, $item
					if $t eq 'waypoint' || $t eq 'route_point'
					|| $t eq 'route'    || $t eq 'track'
					|| $t eq 'group'    || $t eq 'branch';
			}
			if (!@coll_items)
			{
				disconnectDB($dbh);
				warning(0, 0, "_pasteDB: PASTE_BEFORE/AFTER collection: no items in clipboard");
				return;
			}

			my $n = scalar @coll_items;
			my @to_cut;

			for my $i (0 .. $#coll_items)
			{
				my $item = $coll_items[$i];
				my $t    = $item->{type} // '';
				my $pos  = $low + ($high - $low) * ($i + 1) / ($n + 1);

				if ($t eq 'waypoint' || $t eq 'route_point')
				{
					if ($fresh)
					{
						my $new_uuid = _insertFreshWaypoint($dbh, $coll_uuid, $item->{data}, $source);
						$dbh->do("UPDATE waypoints SET position=? WHERE uuid=?", [$pos, $new_uuid]);
					}
					elsif ($cut_flag && $source eq 'database')
					{
						# Move: UPDATE is the entire operation; no separate delete.
						$dbh->do("UPDATE waypoints SET collection_uuid=?, position=? WHERE uuid=?",
							[$coll_uuid, $pos, $item->{uuid}]);
					}
					else
					{
						my $wp_policy = undef;
						my $result = _pasteOneWaypointToDB($dbh, $coll_uuid, $tree, $item,
							$source, \$wp_policy, 'Paste Before/After');
						if ($result ne 'skipped' && $result ne 'aborted')
						{
							$dbh->do("UPDATE waypoints SET position=? WHERE uuid=?",
								[$pos, $item->{uuid}]);
							push @to_cut, $item if $cut_flag;
						}
					}
				}
				elsif ($t eq 'route')
				{
					my $rd    = $item->{data};
					my $color = $source eq 'e80' ? e80RouteIndexToAbgr($rd->{color}) : $rd->{color};
					if ($fresh)
					{
						my $new_uuid = insertRoute($dbh, $rd->{name} // '', $color, $rd->{comment} // '', $coll_uuid);
						$dbh->do("UPDATE routes SET position=? WHERE uuid=?", [$pos, $new_uuid]);
						my $rpos = 0;
						appendRouteWaypoint($dbh, $new_uuid, $_->{uuid}, $rpos++) for @{$item->{route_points} // []};
					}
					elsif ($cut_flag && $source eq 'database')
					{
						$dbh->do("UPDATE routes SET collection_uuid=?, position=? WHERE uuid=?",
							[$coll_uuid, $pos, $item->{uuid}]);
					}
					else
					{
						my $existing = getRoute($dbh, $item->{uuid});
						if (!$existing)
						{
							insertRouteUUID($dbh, $item->{uuid}, $rd->{name} // '', $color,
								$rd->{comment} // '', $coll_uuid);
						}
						else
						{
							updateRoute($dbh, $item->{uuid}, $rd->{name} // '', $color, $rd->{comment} // '');
							$dbh->do("UPDATE routes SET collection_uuid=? WHERE uuid=?",
								[$coll_uuid, $item->{uuid}]);
						}
						$dbh->do("UPDATE routes SET position=? WHERE uuid=?", [$pos, $item->{uuid}]);
						clearRouteWaypoints($dbh, $item->{uuid});
						my $rpos = 0;
						for my $rp (@{$item->{route_points} // []})
						{
							appendRouteWaypoint($dbh, $item->{uuid}, $rp->{uuid}, $rpos++)
								if $rp->{uuid};
						}
						push @to_cut, $item if $cut_flag;
					}
				}
				elsif ($t eq 'track')
				{
					my $tr       = $item->{data};
					my $pts      = $tr->{points} // [];
					my $ts_src   = $source eq 'e80' ? 'e80' : ($tr->{ts_source} // 'user');
					my $color    = $source eq 'e80' ? e80TrackIndexToAbgr($tr->{color}) : $tr->{color};
					my $ts_start = $tr->{ts_start} // (@$pts ? ($pts->[0]{ts} // 0) : 0);
					my $ts_end   = $tr->{ts_end}   // (@$pts ? $pts->[-1]{ts}       : undef);
					if ($cut_flag && $source eq 'database' && !$fresh)
					{
						$dbh->do("UPDATE tracks SET collection_uuid=?, position=? WHERE uuid=?",
							[$coll_uuid, $pos, $item->{uuid}]);
					}
					elsif ($source eq 'database' && !$fresh)
					{
						warning(0, 0, "IMPLEMENTATION ERROR: _pasteDB PASTE_BEFORE/AFTER: UUID-preserving DB-to-DB track copy not supported");
					}
					else
					{
						my $new_uuid = insertTrack($dbh,
							name            => $tr->{name}   // '',
							color           => $color,
							ts_start        => $ts_start,
							ts_end          => $ts_end,
							ts_source       => $ts_src,
							point_count     => scalar @$pts,
							collection_uuid => $coll_uuid,
						);
						$dbh->do("UPDATE tracks SET position=? WHERE uuid=?", [$pos, $new_uuid]);
						if (@$pts)
						{
							my @db_pts = map {{
								lat      => $_->{lat},
								lon      => $_->{lon},
								depth_cm => $_->{depth_cm} // $_->{depth},
								temp_k   => $_->{temp_k}   // $_->{tempr},
								ts       => $_->{ts},
							}} @$pts;
							insertTrackPoints($dbh, $new_uuid, \@db_pts);
						}
						push @to_cut, $item if $cut_flag;
					}
				}
				elsif ($t eq 'group' || $t eq 'branch')
				{
					my $node_type = $t eq 'group' ? $NODE_TYPE_GROUP : $NODE_TYPE_BRANCH;
					if ($fresh)
					{
						my $new_uuid = insertCollection($dbh,
							$item->{data}{name}    // '',
							$coll_uuid,
							$node_type,
							$item->{data}{comment} // '');
						$dbh->do("UPDATE collections SET position=? WHERE uuid=?", [$pos, $new_uuid]);
						my $inner = undef;
						_pasteItemsToCollection($dbh, $item->{members} // [], $new_uuid,
							$source, 1, 0, $tree, \$inner);
					}
					elsif ($cut_flag && $source eq 'database')
					{
						# Move: repoint parent_uuid and set position in one step.
						$dbh->do("UPDATE collections SET parent_uuid=?, position=? WHERE uuid=?",
							[$coll_uuid, $pos, $item->{uuid}]);
					}
					else
					{
						my $uuid     = $item->{uuid};
						my $existing = $uuid ? getCollection($dbh, $uuid) : undef;
						if ($uuid && !$existing)
						{
							insertCollectionUUID($dbh, $uuid,
								$item->{data}{name}    // '',
								$coll_uuid,
								$node_type,
								$item->{data}{comment} // '');
						}
						elsif ($existing)
						{
							$dbh->do("UPDATE collections SET parent_uuid=? WHERE uuid=?",
								[$coll_uuid, $uuid]);
						}
						else
						{
							$uuid = insertCollection($dbh,
								$item->{data}{name}    // '',
								$coll_uuid,
								$node_type,
								$item->{data}{comment} // '');
						}
						$dbh->do("UPDATE collections SET position=? WHERE uuid=?", [$pos, $uuid])
							if $uuid;
						my $inner = undef;
						_pasteItemsToCollection($dbh, $item->{members} // [], $uuid,
							$source, 0, $cut_flag, $tree, \$inner);
					}
				}
			}

			disconnectDB($dbh);

			for my $item (@to_cut)
			{
				my $t = $item->{type} // '';
				if ($t eq 'waypoint' || $t eq 'route_point')
				{
					$source eq 'e80'
						? navOps::_cutE80Waypoint($item->{uuid}, $tree)
						: _cutDatabaseWaypoint($item->{uuid}, $tree);
				}
				elsif ($t eq 'route')
				{
					$source eq 'e80'
						? navOps::_cutE80Route($item->{uuid}, $tree)
						: _cutDatabaseRoute($item->{uuid}, $tree);
				}
				elsif ($t eq 'track')
				{
					$source eq 'e80'
						? navOps::_cutE80Track($item->{uuid}, $tree)
						: _cutDatabaseTrack($item->{uuid}, $tree);
				}
				# groups/branches from DB are already repositioned in-place; no separate cut
			}

			_refreshDatabase();
			return;
		}

		my $pos        = $right_click_node->{position} // 0;
		my $insert_pos = ($cmd_id == $CTX_CMD_PASTE_BEFORE || $cmd_id == $CTX_CMD_PASTE_NEW_BEFORE)
			? $pos
			: $pos + 1;

		# Flatten items to route-sequence-eligible items (route_point and waypoint per SS6.4)
		my @wp_items;
		if (!$fresh)
		{
			# PASTE_BEFORE/AFTER: accept route_point and waypoint items only (SS6.4)
			my @invalid = grep { my $t = $_->{type}//''; $t ne 'route_point' && $t ne 'waypoint' } @$items;
			if (@invalid)
			{
				warning(0, 0, "IMPLEMENTATION ERROR: _pasteDB: PASTE_BEFORE/AFTER route_point: clipboard has non-route_point/waypoint items");
				return;
			}
			@wp_items = @$items;
		}
		else
		{
			# PASTE_NEW_BEFORE/AFTER: route_point and waypoint items eligible; others filtered (SS6.4)
			for my $item (@$items)
			{
				my $t = $item->{type} // '';
				push @wp_items, $item if $t eq 'route_point' || $t eq 'waypoint';
			}
		}
		if (!@wp_items)
		{
			warning(0, 0, "_pasteDB: PASTE_BEFORE/AFTER route_point: no route_point items in clipboard");
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

		# Shift existing route points to make room.
		# Two-step to avoid PRIMARY KEY (route_uuid,position) collision during increment:
		# step 1 moves to a safe large-offset range, step 2 brings back to target.
		my $TEMP = 2_000_000;
		$dbh->do(
			"UPDATE route_waypoints SET position=position+? WHERE route_uuid=? AND position>=?",
			[$TEMP, $route_uuid, $insert_pos]);
		$dbh->do(
			"UPDATE route_waypoints SET position=position+? WHERE route_uuid=? AND position>=?",
			[$n - $TEMP, $route_uuid, $TEMP + $insert_pos]);

		# Insert or paste waypoints, collect resulting UUIDs
		my $policy = undef;
		my @new_uuids;
		my @to_cut;
		for my $item (@wp_items)
		{
			my $wp_uuid;
			if ($fresh)
			{
				my $itype = $item->{type} // '';
				if ($itype eq 'route_point' || $itype eq 'waypoint')
				{
					# Insert as route_waypoints reference using existing WP UUID.
					# "New" means a new sequence position, not a new waypoint record (SS6.4).
					$wp_uuid = $item->{uuid};
				}
				else
				{
					$wp_uuid = _insertFreshWaypoint($dbh, $coll_uuid, $item->{data}, $source);
				}
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

		# Remove source route_waypoints entries for cut route_points while DB is open.
		# The shift applied above means entries at positions >= insert_pos are now at
		# position + n, so adjust the original snapshot position before removing.
		if ($cut_flag && $source eq 'database')
		{
			for my $item (@to_cut)
			{
				next unless ($item->{type} // '') eq 'route_point' && $item->{route_uuid};
				my $orig = $item->{position} // 0;
				my $adj  = ($orig >= $insert_pos) ? $orig + $n : $orig;
				removeRoutePoint($dbh, $item->{route_uuid}, $adj);
			}
		}

		disconnectDB($dbh);

		# Cut cleanup for non-database sources (DB route_points handled above).
		for my $item (@to_cut)
		{
			next if ($item->{type} // '') eq 'route_point' && $source eq 'database';
			$source eq 'e80'
				? navOps::_cutE80Waypoint($item->{uuid}, $tree)
				: _cutDatabaseWaypoint($item->{uuid}, $tree);
		}

		_refreshDatabase();
		return;
	}

	# Standard paste into a collection
	my $rcn_type = $right_click_node ? ($right_click_node->{type} // '') : '';
	unless ($rcn_type eq 'collection' || $rcn_type eq 'root')
	{
		warning(0, 0, "IMPLEMENTATION ERROR: _pasteDB: non-collection destination '$rcn_type' reached paste handler");
		return;
	}
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


#----------------------------------------------------
# _pushFromE80 -- E80->DB push down
#----------------------------------------------------

sub _pushFromE80
{
	my ($right_click_node, $tree, $items) = @_;

	my $dbh = connectDB();
	return unless $dbh;

	for my $item (@$items)
	{
		my $t    = $item->{type} // '';
		my $uuid = $item->{uuid} // '';
		next unless $uuid;

		if ($t eq 'waypoint')
		{
			my $wp  = $item->{data} // {};
			my $rec = getWaypoint($dbh, $uuid);
			next unless $rec;
			updateWaypoint($dbh, $uuid,
				name       => $wp->{name}    // '',
				comment    => $wp->{comment} // '',
				lat        => $wp->{lat},
				lon        => $wp->{lon},
				wp_type    => $rec->{wp_type}  // $WP_TYPE_NAV,
				color      => $rec->{color},
				depth_cm   => $wp->{depth_cm} // $wp->{depth} // 0,
				created_ts => $wp->{created_ts} // $wp->{ts} // $rec->{created_ts},
				ts_source  => $rec->{ts_source} // 'e80',
				source     => $rec->{source},
			);
		}
		elsif ($t eq 'route')
		{
			my $rd  = $item->{data} // {};
			my $rps = $item->{route_points} // [];
			my $rec = getRoute($dbh, $uuid);
			next unless $rec;
			updateRoute($dbh, $uuid,
				$rd->{name}    // '',
				e80RouteIndexToAbgr($rd->{color} // 0),
				$rd->{comment} // '');
			clearRouteWaypoints($dbh, $uuid);
			my $pos = 0;
			appendRouteWaypoint($dbh, $uuid, $_->{uuid}, $pos++) for @$rps;
		}
		elsif ($t eq 'group')
		{
			my $gd  = $item->{data} // {};
			my $rec = getCollection($dbh, $uuid);
			next unless $rec;
			if (($rec->{name} // '') ne ($gd->{name} // ''))
			{
				$dbh->do("UPDATE collections SET name=? WHERE uuid=?",
					[$gd->{name} // '', $uuid]);
			}
			for my $member (@{$item->{members} // []})
			{
				my $mu   = $member->{uuid} // '';
				my $md   = $member->{data} // {};
				next unless $mu;
				my $mrec = getWaypoint($dbh, $mu);
				next unless $mrec;
				updateWaypoint($dbh, $mu,
					name       => $md->{name}    // '',
					comment    => $md->{comment} // '',
					lat        => $md->{lat},
					lon        => $md->{lon},
					wp_type    => $mrec->{wp_type}  // $WP_TYPE_NAV,
					color      => $mrec->{color},
					depth_cm   => $md->{depth_cm} // $md->{depth} // 0,
					created_ts => $md->{created_ts} // $md->{ts} // $mrec->{created_ts},
					ts_source  => $mrec->{ts_source} // 'e80',
					source     => $mrec->{source},
				);
			}
		}
		# tracks: read-only on E80; push-down not applicable
	}

	disconnectDB($dbh);
	_refreshDatabase();
}


1;
