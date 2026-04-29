#!/usr/bin/perl
#---------------------------------------------
# nmOps.pm
#---------------------------------------------
# Context-menu operation implementations for navMate.
# New Waypoint is not yet implemented.
# Called by nmClipboard::onContextMenuCommand.

package nmOps;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Pub::Utils qw(display warning error getAppFrame);
use Pub::WX::Dialogs;
use apps::raymarine::NET::c_RAYDP;
use c_db;
use a_defs;
use a_utils;
use nmDialogs;
use w_resources;


BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(
		doNew
		doDelete
		doCopy
		doPaste
		doRefresh
	);
}


our $dbg_e80_ops = 0;


#----------------------------------------------------
# helpers
#----------------------------------------------------

sub _refreshBrowser
{
	my $frame = getAppFrame();
	my $pane  = $frame ? $frame->findPane($WIN_BROWSER) : undef;
	$pane->refresh() if $pane;
}

sub _newNavUUID
{
	my $dbh = connectDB();
	return undef unless $dbh;
	my $uuid = newUUID($dbh);
	disconnectDB($dbh);
	return $uuid;
}

sub _parseColor
{
	my ($s) = @_;
	return 0 unless defined $s && $s ne '';
	return ($s =~ /^0[xX]/) ? hex($s) : ($s + 0);
}

sub _wpmgr
{
	return $raydp ? $raydp->findImplementedService('WPMGR') : undef;
}

sub _track
{
	return $raydp ? $raydp->findImplementedService('TRACK') : undef;
}


#----------------------------------------------------
# doRefresh
#----------------------------------------------------

sub doRefresh
{
	my ($parent) = @_;

	my $wpmgr = _wpmgr();
	my $track = _track();

	unless ($wpmgr && $track)
	{
		Wx::MessageBox("E80 not connected — cannot refresh.",
			"Refresh E80", wxOK | wxICON_WARNING, $parent // getAppFrame());
		return;
	}

	if ($apps::raymarine::NET::d_WPMGR::query_in_progress ||
	    $apps::raymarine::NET::d_TRACK::query_in_progress)
	{
		Wx::MessageBox("A query is already in progress — please wait.",
			"Refresh E80", wxOK | wxICON_WARNING, $parent // getAppFrame());
		return;
	}

	my $prog = Pub::WX::ProgressDialog::newProgressData(0, 2);
	$prog->{active} = 1;

	$wpmgr->queueRefresh($prog);
	$track->queueRefresh($prog);

	Pub::WX::ProgressDialog->new(
		$parent // getAppFrame(),
		'Refreshing E80...',
		1,
		$prog);
}


#----------------------------------------------------
# doNew
#----------------------------------------------------

sub doNew
{
	my ($cmd_id, $panel, $node, $tree) = @_;

	if ($cmd_id == $nmClipboard::CMD_NEW_BRANCH)
	{
		_newCollection($node, $tree, 'Branch', $NODE_TYPE_BRANCH);
	}
	elsif ($cmd_id == $nmClipboard::CMD_NEW_GROUP)
	{
		$panel eq 'browser'
			? _newCollection($node, $tree, 'Group', $NODE_TYPE_GROUP)
			: _newE80Group($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_NEW_ROUTE)
	{
		$panel eq 'browser'
			? _newBrowserRoute($node, $tree)
			: _newE80Route($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_NEW_WAYPOINT)
	{
		$panel eq 'browser'
			? _newBrowserWaypoint($node, $tree)
			: _newE80Waypoint($node, $tree);
	}
}


sub _newCollection
{
	my ($node, $tree, $label, $node_type) = @_;

	unless (($node->{type} // '') eq 'collection')
	{
		Wx::MessageBox("Right-click a folder to create a new $label.",
			"New $label", wxOK | wxICON_INFORMATION, $tree);
		return;
	}

	my $data = $node_type eq $NODE_TYPE_GROUP
		? nmDialogs::showNewGroup($tree)
		: nmDialogs::showNewBranch($tree);
	return unless defined $data;

	my $dbh = connectDB();
	return unless $dbh;
	insertCollection($dbh, $data->{name}, $node->{data}{uuid}, $node_type, $data->{comment});
	disconnectDB($dbh);
	_refreshBrowser();
}


sub _newBrowserRoute
{
	my ($node, $tree) = @_;

	unless (($node->{type} // '') eq 'collection')
	{
		Wx::MessageBox("Right-click a folder to create a new Route.",
			"New Route", wxOK | wxICON_INFORMATION, $tree);
		return;
	}

	my $data = nmDialogs::showNewRoute($tree);
	return unless defined $data;

	my $dbh = connectDB();
	return unless $dbh;
	insertRoute($dbh, $data->{name}, _parseColor($data->{color}), $data->{comment}, $node->{data}{uuid});
	disconnectDB($dbh);
	_refreshBrowser();
}


sub _newE80Group
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "New Group", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $data = nmDialogs::showNewGroup($tree);
	return unless defined $data;

	my $uuid = _newNavUUID();
	return unless $uuid;

	$wpmgr->createGroup({ name => $data->{name}, uuid => $uuid, comment => $data->{comment}, members => [] });
}


sub _newBrowserWaypoint
{
	my ($node, $tree) = @_;

	unless (($node->{type} // '') eq 'collection')
	{
		Wx::MessageBox("Right-click a folder to create a new Waypoint.",
			"New Waypoint", wxOK | wxICON_INFORMATION, $tree);
		return;
	}

	my $data = nmDialogs::showNewWaypoint($tree);
	return unless defined $data;

	my $lat = parseLatLon($data->{lat});
	my $lon = parseLatLon($data->{lon});
	unless (defined $lat && defined $lon)
	{
		Wx::MessageBox(
			"Could not parse Latitude or Longitude.\n" .
			"Use decimal degrees (9.3617 N) or degrees and minutes (9 21.702 N).",
			"New Waypoint", wxOK | wxICON_WARNING, $tree);
		return;
	}

	my $dbh = connectDB();
	return unless $dbh;
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
	_refreshBrowser();
}


sub _newE80Waypoint
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "New Waypoint", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $data = nmDialogs::showNewWaypoint($tree);
	return unless defined $data;

	my $lat = parseLatLon($data->{lat});
	my $lon = parseLatLon($data->{lon});
	unless (defined $lat && defined $lon)
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
	return unless $uuid;

	my @ops = ({
		type    => 'new_wp',
		uuid    => $uuid,
		name    => $data->{name},
		lat     => $lat,
		lon     => $lon,
		sym     => ($data->{sym} // 0) + 0,
		ts      => time(),
		comment => $data->{comment} // '',
	});

	push @ops, { type => 'mod_group', uuid => $group_uuid, wp_uuid => $uuid }
		if $group_uuid;

	$wpmgr->submitBatch(\@ops);
}


sub _newE80Route
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "New Route", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $data = nmDialogs::showNewRoute($tree);
	return unless defined $data;

	my $uuid = _newNavUUID();
	return unless $uuid;

	$wpmgr->createRoute({
		name      => $data->{name},
		uuid      => $uuid,
		comment   => $data->{comment},
		color     => _parseColor($data->{color}),
		waypoints => [],
	});
}


#----------------------------------------------------
# doDelete
#----------------------------------------------------

sub doDelete
{
	my ($cmd_id, $panel, $node, $tree) = @_;

	if ($cmd_id == $nmClipboard::CMD_REMOVE_ROUTEPOINT)
	{
		$panel eq 'browser'
			? _removeBrowserRoutePoint($node, $tree)
			: _removeE80RoutePoint($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_WAYPOINT)
	{
		$panel eq 'browser'
			? _deleteBrowserWaypoint($node, $tree)
			: _deleteE80Waypoint($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_WAYPOINT_RPS)
	{
		$panel eq 'browser'
			? _deleteBrowserWaypointAndRPs($node, $tree)
			: _deleteE80WaypointAndRPs($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_TRACK)
	{
		_deleteBrowserTrack($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_BRANCH)
	{
		_deleteBrowserCollection($node, $tree, 'Branch');
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_GROUP)
	{
		$panel eq 'browser'
			? _deleteBrowserCollection($node, $tree, 'Group')
			: _deleteE80Group($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_GROUP_WPS)
	{
		$panel eq 'browser'
			? _deleteBrowserGroupAndWPs($node, $tree)
			: _deleteE80GroupAndWPs($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_GROUP_NUCLEAR)
	{
		$panel eq 'browser'
			? _deleteBrowserGroupNuclear($node, $tree)
			: _deleteE80GroupNuclear($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_ROUTE)
	{
		$panel eq 'browser'
			? _deleteBrowserRoute($node, $tree)
			: _deleteE80Route($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_ROUTE_WPS)
	{
		$panel eq 'browser'
			? _deleteBrowserRouteAndWPs($node, $tree)
			: _deleteE80RouteAndWPs($node, $tree);
	}
	else
	{
		warning(0,0,"nmOps::doDelete: unimplemented cmd=$cmd_id panel=$panel");
	}
}


sub _removeBrowserRoutePoint
{
	my ($node, $tree) = @_;

	my $wp   = $node->{data};
	my $name = $wp ? ($wp->{name} // $node->{uuid}) : $node->{uuid};

	my $rc = Wx::MessageBox("Remove '$name' from route?", "Remove RoutePoint",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;

	my $dbh = connectDB();
	return unless $dbh;
	removeRoutePoint($dbh, $node->{route_uuid}, $node->{position});
	disconnectDB($dbh);
	_refreshBrowser();
}


sub _removeE80RoutePoint
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
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
	return unless $rc == wxYES;

	$wpmgr->submitBatch([{
		type    => 'mod_route',
		uuid    => $route_uuid,
		wp_uuid => $node->{uuid},
	}]);
}


sub _deleteBrowserCollection
{
	my ($node, $tree, $label) = @_;

	my $uuid = $node->{data}{uuid};
	my $name = $node->{data}{name};

	my $dbh = connectDB();
	return unless $dbh;
	my $counts = getCollectionCounts($dbh, $uuid);
	disconnectDB($dbh);

	my $total = $counts->{collections} + $counts->{waypoints}
	          + $counts->{routes}      + $counts->{tracks};
	if ($total > 0)
	{
		Wx::MessageBox("'$name' is not empty — use a more specific delete command.",
			"Delete $label", wxOK | wxICON_WARNING, $tree);
		return;
	}

	my $rc = Wx::MessageBox("Delete $label '$name'?", "Confirm Delete",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;

	$dbh = connectDB();
	return unless $dbh;
	deleteCollection($dbh, $uuid);
	disconnectDB($dbh);
	_refreshBrowser();
}


sub _deleteBrowserRoute
{
	my ($node, $tree) = @_;

	my $uuid = $node->{data}{uuid};
	my $name = $node->{data}{name};

	my $dbh = connectDB();
	return unless $dbh;
	my $n = getRouteWaypointCount($dbh, $uuid);
	disconnectDB($dbh);

	my $msg = $n > 0
		? "Delete route '$name'? Its $n waypoint(s) will remain. Cannot be undone."
		: "Delete route '$name'? Cannot be undone.";
	my $rc = Wx::MessageBox($msg, "Delete Route",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;

	$dbh = connectDB();
	return unless $dbh;
	deleteRoute($dbh, $uuid);
	disconnectDB($dbh);
	_refreshBrowser();
}


sub _deleteBrowserWaypoint
{
	my ($node, $tree) = @_;

	my $uuid = $node->{data}{uuid};
	my $name = $node->{data}{name};

	my $dbh = connectDB();
	return unless $dbh;
	my $n = getWaypointRouteRefCount($dbh, $uuid);
	disconnectDB($dbh);

	if ($n > 0)
	{
		Wx::MessageBox("Waypoint '$name' is used in $n route(s) — use 'Delete Waypoint + RoutePoints'.",
			"Delete Waypoint", wxOK | wxICON_WARNING, $tree);
		return;
	}

	my $rc = Wx::MessageBox("Delete waypoint '$name'?", "Confirm Delete",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;

	$dbh = connectDB();
	return unless $dbh;
	deleteWaypoint($dbh, $uuid);
	disconnectDB($dbh);
	_refreshBrowser();
}


sub _deleteE80Waypoint
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Waypoint", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $uuid = $node->{uuid};
	my $name = $node->{data}{name};

	my $rc = Wx::MessageBox("Delete waypoint '$name' from E80?", "Confirm Delete",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;

	$wpmgr->deleteWaypoint($uuid);
}


sub _deleteBrowserTrack
{
	my ($node, $tree) = @_;

	my $uuid = $node->{data}{uuid};
	my $name = $node->{data}{name};
	my $n    = $node->{data}{point_count} // 0;
	my $pts  = $n ? " ($n points)" : '';

	my $rc = Wx::MessageBox("Delete track '$name'$pts?", "Confirm Delete",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;

	my $dbh = connectDB();
	return unless $dbh;
	deleteTrack($dbh, $uuid);
	disconnectDB($dbh);
	_refreshBrowser();
}


sub _deleteE80Group
{
	my ($node, $tree) = @_;

	if (($node->{type} // '') eq 'my_waypoints')
	{
		Wx::MessageBox("'My Waypoints' is synthesized and cannot be deleted.",
			"Delete Group", wxOK | wxICON_INFORMATION, $tree);
		return;
	}

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Group", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $uuid = $node->{uuid};
	my $name = $node->{data}{name};
	my $n    = scalar @{$node->{data}{uuids} // []};

	my $msg = $n > 0
		? "Delete group '$name' from E80? Its $n member(s) will remain in My Waypoints. Cannot be undone."
		: "Delete group '$name' from E80? Cannot be undone.";
	my $rc = Wx::MessageBox($msg, "Delete Group",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;

	$wpmgr->deleteGroup($uuid);
}


sub _deleteE80Route
{
	my ($node, $tree) = @_;

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Route", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $uuid = $node->{uuid};
	my $name = $node->{data}{name};
	my $n    = scalar @{$node->{data}{uuids} // []};

	my $msg = $n > 0
		? "Delete route '$name' from E80? Its $n waypoint(s) will remain. Cannot be undone."
		: "Delete route '$name' from E80? Cannot be undone.";
	my $rc = Wx::MessageBox($msg, "Delete Route",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;

	$wpmgr->deleteRoute($uuid);
}


#----------------------------------------------------
# E80 delete helpers
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
	return undef unless $wp;
	for my $u (@{$wp->{uuids} // []})
	{
		return $u if $wpmgr->{groups}{$u};
	}
	return undef;
}


sub _appendE80WPDeleteOps
	# Append batch ops that fully remove $wp_uuid from E80:
	#   mod_route for each route containing it (excluding $skip_route)
	#   mod_group remove (if in a group)
	#   del_wp
{
	my ($ops, $wpmgr, $wp_uuid, $skip_route) = @_;
	for my $r_uuid (_e80WPRoutes($wpmgr, $wp_uuid, $skip_route))
	{
		push @$ops, {type => 'mod_route', uuid => $r_uuid, wp_uuid => $wp_uuid};
	}
	my $g = _e80WPGroup($wpmgr, $wp_uuid);
	push @$ops, {type => 'mod_group', uuid => $g, wp_uuid => $wp_uuid, remove => 1} if $g;
	push @$ops, {type => 'del_wp', uuid => $wp_uuid};
}


sub _e80BatchSubmit
	# Submit @$ops as a single batch.  Shows a progress dialog.
{
	my ($wpmgr, $ops, $title) = @_;
	return unless @$ops;
	display(0,0,"nmOps::_e80BatchSubmit '$title' ops=".scalar(@$ops));
	my $prog = Pub::WX::ProgressDialog::newProgressData(scalar @$ops);
	$prog->{active} = 1;
	$wpmgr->submitBatch($ops, $prog);
	Pub::WX::ProgressDialog->new(getAppFrame(), $title, 1, $prog);
	my $done      = $prog->{done}      // 0;
	my $cancelled = $prog->{cancelled} // 0;
	my $err       = $prog->{error}     // '';
	display(0,0,"nmOps::_e80BatchSubmit '$title' done=$done cancelled=$cancelled err='$err'");
}


#----------------------------------------------------
# Delete Waypoint + RoutePoints
#----------------------------------------------------

sub _deleteBrowserWaypointAndRPs
{
	my ($node, $tree) = @_;
	my $uuid   = $node->{data}{uuid};
	my $name   = $node->{data}{name};
	my $dbh    = connectDB();
	return unless $dbh;
	my $routes = getWaypointRoutes($dbh, $uuid);
	disconnectDB($dbh);
	my $nr  = scalar @$routes;
	my $msg = $nr > 0
		? "Delete waypoint '$name' and remove it from $nr route(s)? Cannot be undone."
		: "Delete waypoint '$name'? Cannot be undone.";
	my $rc = Wx::MessageBox($msg, "Delete Waypoint + RoutePoints",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;
	$dbh = connectDB();
	return unless $dbh;
	for my $r (@$routes)
	{
		removeRoutePoint($dbh, $r->{route_uuid}, $r->{position});
	}
	deleteWaypoint($dbh, $uuid);
	disconnectDB($dbh);
	_refreshBrowser();
}


sub _deleteE80WaypointAndRPs
{
	my ($node, $tree) = @_;
	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Waypoint + RoutePoints",
			wxOK | wxICON_ERROR, $tree);
		return;
	}
	my $uuid = $node->{uuid};
	my $name = $node->{data}{name};
	my $nr   = scalar _e80WPRoutes($wpmgr, $uuid);
	my $msg  = $nr > 0
		? "Delete waypoint '$name' from E80 and remove it from $nr route(s)? Cannot be undone."
		: "Delete waypoint '$name' from E80? Cannot be undone.";
	my $rc = Wx::MessageBox($msg, "Delete Waypoint + RoutePoints",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;
	my @ops;
	_appendE80WPDeleteOps(\@ops, $wpmgr, $uuid, undef);
	_e80BatchSubmit($wpmgr, \@ops, "Delete Waypoint + RoutePoints");
}


#----------------------------------------------------
# Delete Route + Waypoints
#----------------------------------------------------

sub _deleteBrowserRouteAndWPs
{
	my ($node, $tree) = @_;
	my $uuid = $node->{data}{uuid};
	my $name = $node->{data}{name};
	my $dbh  = connectDB();
	return unless $dbh;
	my $all_wps = getRouteWaypoints($dbh, $uuid);
	my %other;
	for my $wp (@$all_wps)
	{
		my $refs = getWaypointRoutes($dbh, $wp->{uuid});
		for my $r (@$refs)
		{
			next if $r->{route_uuid} eq $uuid;
			push @{$other{$r->{route_uuid}}}, $r->{position};
		}
	}
	disconnectDB($dbh);
	my $n          = scalar @$all_wps;
	my $cross_refs = scalar keys %other;
	my $msg;
	if ($n == 0)
	{
		$msg = "Delete route '$name'? Cannot be undone.";
	}
	elsif ($cross_refs > 0)
	{
		$msg = "Delete route '$name' and its $n waypoint(s)? " .
		       "($cross_refs also appear in other routes and will be removed from them.) Cannot be undone.";
	}
	else
	{
		$msg = "Delete route '$name' and its $n waypoint(s)? Cannot be undone.";
	}
	my $rc = Wx::MessageBox($msg, "Delete Route + Waypoints",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;
	$dbh = connectDB();
	return unless $dbh;
	for my $r_uuid (keys %other)
	{
		removeRoutePoint($dbh, $r_uuid, $_)
			for sort { $b <=> $a } @{$other{$r_uuid}};
	}
	deleteRoute($dbh, $uuid);
	deleteWaypoint($dbh, $_->{uuid}) for @$all_wps;
	disconnectDB($dbh);
	_refreshBrowser();
}


sub _deleteE80RouteAndWPs
{
	my ($node, $tree) = @_;
	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Route + Waypoints",
			wxOK | wxICON_ERROR, $tree);
		return;
	}
	my $uuid       = $node->{uuid};
	my $name       = $node->{data}{name};
	my $all_wps    = $node->{data}{uuids} // [];
	my $n          = scalar @$all_wps;
	my $cross_refs = scalar grep { _e80WPRoutes($wpmgr, $_, $uuid) } @$all_wps;
	my $msg;
	if ($n == 0)
	{
		$msg = "Delete route '$name' from E80? Cannot be undone.";
	}
	elsif ($cross_refs > 0)
	{
		$msg = "Delete route '$name' and its $n waypoint(s) from E80? " .
		       "($cross_refs also appear in other routes and will be removed from them.) Cannot be undone.";
	}
	else
	{
		$msg = "Delete route '$name' and its $n waypoint(s) from E80? Cannot be undone.";
	}
	my $rc = Wx::MessageBox($msg, "Delete Route + Waypoints",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;
	display($dbg_e80_ops,0,"nmOps::_deleteE80RouteAndWPs '$name' n=$n cross_refs=$cross_refs");
	my @ops = ({type => 'del_route', uuid => $uuid});
	_appendE80WPDeleteOps(\@ops, $wpmgr, $_, $uuid) for @$all_wps;
	display($dbg_e80_ops+1,0,"nmOps::_deleteE80RouteAndWPs total ops=".scalar(@ops));
	_e80BatchSubmit($wpmgr, \@ops, "Delete Route + Waypoints");
}


#----------------------------------------------------
# Delete Group + Waypoints
#----------------------------------------------------

sub _deleteBrowserGroupAndWPs
{
	my ($node, $tree) = @_;
	my $uuid = $node->{data}{uuid};
	my $name = $node->{data}{name};
	my $dbh  = connectDB();
	return unless $dbh;
	my $wps  = getGroupWaypoints($dbh, $uuid);
	my $in_route = 0;
	for my $wp (@$wps)
	{
		if (getWaypointRouteRefCount($dbh, $wp->{uuid}) > 0) { $in_route = 1; last; }
	}
	disconnectDB($dbh);
	if ($in_route)
	{
		Wx::MessageBox(
			"Group '$name' has waypoints used in routes — use 'Delete Group + Waypoints + RoutePoints'.",
			"Delete Group + Waypoints", wxOK | wxICON_WARNING, $tree);
		return;
	}
	my $n   = scalar @$wps;
	my $msg = $n > 0
		? "Delete group '$name' and its $n waypoint(s)? Cannot be undone."
		: "Delete group '$name'? Cannot be undone.";
	my $rc = Wx::MessageBox($msg, "Delete Group + Waypoints",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;
	$dbh = connectDB();
	return unless $dbh;
	deleteWaypoint($dbh, $_->{uuid}) for @$wps;
	deleteCollection($dbh, $uuid);
	disconnectDB($dbh);
	_refreshBrowser();
}


sub _deleteE80GroupAndWPs
{
	my ($node, $tree) = @_;
	if (($node->{type} // '') eq 'my_waypoints')
	{
		Wx::MessageBox("'My Waypoints' is synthesized and cannot be deleted.",
			"Delete Group + Waypoints", wxOK | wxICON_INFORMATION, $tree);
		return;
	}
	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Group + Waypoints",
			wxOK | wxICON_ERROR, $tree);
		return;
	}
	my $uuid    = $node->{uuid};
	my $name    = $node->{data}{name};
	my $members = $node->{data}{uuids} // [];
	my $in_route = 0;
	for my $wp_uuid (@$members)
	{
		if (_e80WPRoutes($wpmgr, $wp_uuid)) { $in_route = 1; last; }
	}
	if ($in_route)
	{
		Wx::MessageBox(
			"Group '$name' has waypoints used in routes — use 'Delete Group + Waypoints + RoutePoints'.",
			"Delete Group + Waypoints", wxOK | wxICON_WARNING, $tree);
		return;
	}
	my $n   = scalar @$members;
	my $msg = $n > 0
		? "Delete group '$name' and its $n waypoint(s) from E80? Cannot be undone."
		: "Delete group '$name' from E80? Cannot be undone.";
	my $rc = Wx::MessageBox($msg, "Delete Group + Waypoints",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;
	display($dbg_e80_ops,0,"nmOps::_deleteE80GroupAndWPs '$name' n=$n");
	my @ops = ({type => 'del_group', uuid => $uuid});
	push @ops, {type => 'del_wp', uuid => $_} for @$members;
	_e80BatchSubmit($wpmgr, \@ops, "Delete Group + Waypoints");
}


#----------------------------------------------------
# Delete Group + Waypoints + RoutePoints (Nuclear)
#----------------------------------------------------

sub _deleteBrowserGroupNuclear
{
	my ($node, $tree) = @_;
	my $uuid = $node->{data}{uuid};
	my $name = $node->{data}{name};
	my $dbh  = connectDB();
	return unless $dbh;
	my $wps  = getGroupWaypoints($dbh, $uuid);
	disconnectDB($dbh);
	my $n   = scalar @$wps;
	my $msg = $n > 0
		? "Delete group '$name' and its $n waypoint(s), removing them from any routes? Cannot be undone."
		: "Delete group '$name'? Cannot be undone.";
	my $rc = Wx::MessageBox($msg, "Delete Group + Waypoints + RoutePoints",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;
	$dbh = connectDB();
	return unless $dbh;
	# Collect {route_uuid => [positions]}, remove in descending order
	my %other;
	for my $wp (@$wps)
	{
		my $refs = getWaypointRoutes($dbh, $wp->{uuid});
		push @{$other{$_->{route_uuid}}}, $_->{position} for @$refs;
	}
	for my $r_uuid (keys %other)
	{
		removeRoutePoint($dbh, $r_uuid, $_)
			for sort { $b <=> $a } @{$other{$r_uuid}};
	}
	deleteWaypoint($dbh, $_->{uuid}) for @$wps;
	deleteCollection($dbh, $uuid);
	disconnectDB($dbh);
	_refreshBrowser();
}


sub _deleteE80GroupNuclear
{
	my ($node, $tree) = @_;
	if (($node->{type} // '') eq 'my_waypoints')
	{
		Wx::MessageBox("'My Waypoints' is synthesized and cannot be deleted.",
			"Delete Group + Waypoints + RoutePoints", wxOK | wxICON_INFORMATION, $tree);
		return;
	}
	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Delete Group + Waypoints + RoutePoints",
			wxOK | wxICON_ERROR, $tree);
		return;
	}
	my $uuid    = $node->{uuid};
	my $name    = $node->{data}{name};
	my $members = $node->{data}{uuids} // [];
	my $n       = scalar @$members;
	my $msg = $n > 0
		? "Delete group '$name' and its $n waypoint(s) from E80, removing them from any routes? Cannot be undone."
		: "Delete group '$name' from E80? Cannot be undone.";
	my $rc = Wx::MessageBox($msg, "Delete Group + Waypoints + RoutePoints",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;
	display($dbg_e80_ops,0,"nmOps::_deleteE80GroupNuclear '$name' n=$n");
	my @ops = ({type => 'del_group', uuid => $uuid});
	for my $wp_uuid (@$members)
	{
		push @ops, {type => 'mod_route', uuid => $_, wp_uuid => $wp_uuid}
			for _e80WPRoutes($wpmgr, $wp_uuid);
		push @ops, {type => 'del_wp', uuid => $wp_uuid};
	}
	display($dbg_e80_ops+1,0,"nmOps::_deleteE80GroupNuclear total ops=".scalar(@ops));
	_e80BatchSubmit($wpmgr, \@ops, "Delete Group + Waypoints + RoutePoints");
}


#----------------------------------------------------
# doCopy
#----------------------------------------------------

sub doCopy
{
	my ($intent, $panel, $node, $tree) = @_;

	if ($intent =~ /^waypoints?$/)
	{
		_copyWaypoint($intent, $panel, $node, $tree);
	}
	elsif ($intent =~ /^tracks?$/)
	{
		_copyTrack($intent, $panel, $node, $tree);
	}
	else
	{
		display(0,0,"nmOps::doCopy: intent '$intent' not yet implemented");
	}
}


sub _copyWaypoint
{
	my ($intent, $panel, $node, $tree) = @_;

	if ($panel eq 'e80')
	{
		nmClipboard::setCopy($intent, 'e80', [{
			type => 'waypoint',
			uuid => $node->{uuid},
			data => $node->{data},
		}]);
	}
	else
	{
		my $uuid = $node->{data}{uuid};
		my $dbh = connectDB();
		return unless $dbh;
		my $wp = getWaypoint($dbh, $uuid);
		disconnectDB($dbh);
		unless ($wp)
		{
			Wx::MessageBox("Could not load waypoint.", "Copy Waypoint", wxOK | wxICON_ERROR, $tree);
			return;
		}
		nmClipboard::setCopy($intent, 'browser', [{
			type => 'waypoint',
			uuid => $uuid,
			data => $wp,
		}]);
	}
}


sub _copyTrack
{
	my ($intent, $panel, $node, $tree) = @_;

	if ($panel eq 'e80')
	{
		nmClipboard::setCopy($intent, 'e80', [{
			type => 'track',
			uuid => $node->{uuid},
			data => $node->{data},
		}]);
	}
	else
	{
		my $uuid = $node->{data}{uuid};
		my $dbh = connectDB();
		return unless $dbh;
		my $track = getTrack($dbh, $uuid);
		unless ($track)
		{
			disconnectDB($dbh);
			Wx::MessageBox("Could not load track.", "Copy Track", wxOK | wxICON_ERROR, $tree);
			return;
		}
		my $pts = getTrackPoints($dbh, $uuid);
		disconnectDB($dbh);
		$track->{points} = $pts // [];
		nmClipboard::setCopy($intent, 'browser', [{
			type => 'track',
			uuid => $uuid,
			data => $track,
		}]);
	}
}


#----------------------------------------------------
# doPaste
#----------------------------------------------------

sub doPaste
{
	my ($panel, $node, $tree) = @_;

	my $cb = $nmClipboard::clipboard;
	unless ($cb)
	{
		Wx::MessageBox("Nothing to paste.", "Paste", wxOK | wxICON_INFORMATION, $tree);
		return;
	}

	my $intent = $cb->{intent};
	my $item   = ($cb->{items} // [])->[0];
	unless ($item)
	{
		Wx::MessageBox("Clipboard is empty.", "Paste", wxOK | wxICON_INFORMATION, $tree);
		return;
	}

	if ($panel eq 'browser')
	{
		if ($intent =~ /^waypoints?$/)
		{
			_pasteWaypointToBrowser($node, $tree, $item, $cb);
		}
		elsif ($intent =~ /^tracks?$/)
		{
			_pasteTrackToBrowser($node, $tree, $item, $cb);
		}
		else
		{
			_unimplementedPaste($intent, $panel, $tree);
		}
	}
	elsif ($panel eq 'e80')
	{
		if ($intent =~ /^waypoints?$/)
		{
			_pasteWaypointToE80($node, $tree, $item);
		}
		else
		{
			_unimplementedPaste($intent, $panel, $tree);
		}
	}
}


sub _unimplementedPaste
{
	my ($intent, $panel, $tree) = @_;
	error(0,0,"nmOps::doPaste: '$intent' to $panel not implemented");
	Wx::MessageBox("Paste '$intent' to $panel is not yet implemented.",
		"Paste", wxOK | wxICON_ERROR, $tree);
}


sub _pasteWaypointToBrowser
{
	my ($node, $tree, $item, $cb) = @_;

	unless (($node->{type} // '') eq 'collection')
	{
		Wx::MessageBox("Right-click a folder to paste a waypoint.",
			"Paste Waypoint", wxOK | wxICON_INFORMATION, $tree);
		return;
	}

	my $coll_uuid = $node->{data}{uuid};
	my $wp        = $item->{data};
	my $ts        = $wp->{created_ts} // $wp->{ts} // time();
	my $ts_source = ($cb->{source} eq 'e80') ? 'e80' : ($wp->{ts_source} // 'user');

	my $dbh = connectDB();
	return unless $dbh;
	insertWaypoint($dbh,
		name            => $wp->{name}    // '',
		comment         => $wp->{comment} // '',
		lat             => $wp->{lat},
		lon             => $wp->{lon},
		sym             => $wp->{sym}     // 0,
		wp_type         => $wp->{wp_type} // $WP_TYPE_NAV,
		color           => $wp->{color},
		depth_cm        => $wp->{depth_cm} // $wp->{depth} // 0,
		created_ts      => $ts,
		ts_source       => $ts_source,
		source          => $wp->{source},
		collection_uuid => $coll_uuid,
	);
	disconnectDB($dbh);
	_refreshBrowser();
}


sub _pasteWaypointToE80
{
	my ($node, $tree, $item) = @_;

	my $wpmgr = _wpmgr();
	unless ($wpmgr)
	{
		Wx::MessageBox("WPMGR not connected.", "Paste Waypoint", wxOK | wxICON_ERROR, $tree);
		return;
	}

	my $wp        = $item->{data};
	my $uuid      = $item->{uuid};
	my $node_type = $node->{type} // '';

	my $group_uuid =
		($node_type eq 'group')       ? $node->{uuid}       :
		($node_type eq 'waypoint')    ? $node->{group_uuid} :
		($node_type eq 'route_point') ? $node->{group_uuid} : undef;

	my @ops = ({
		type    => 'new_wp',
		uuid    => $uuid,
		name    => $wp->{name}    // '',
		lat     => $wp->{lat},
		lon     => $wp->{lon},
		sym     => $wp->{sym}     // 0,
		ts      => $wp->{created_ts} // $wp->{ts} // 0,
		comment => $wp->{comment} // '',
		depth   => $wp->{depth_cm} // $wp->{depth} // 0,
	});

	push @ops, { type => 'mod_group', uuid => $group_uuid, wp_uuid => $uuid }
		if $group_uuid;

	$wpmgr->submitBatch(\@ops);
}


sub _pasteTrackToBrowser
{
	my ($node, $tree, $item, $cb) = @_;

	unless (($node->{type} // '') eq 'collection')
	{
		Wx::MessageBox("Right-click a folder to paste a track.",
			"Paste Track", wxOK | wxICON_INFORMATION, $tree);
		return;
	}

	my $coll_uuid = $node->{data}{uuid};
	my $track     = $item->{data};
	my $pts       = $track->{points} // [];
	my $ts_start  = $track->{ts_start} // (@$pts ? ($pts->[0]{ts}  // 0) : 0);
	my $ts_end    = $track->{ts_end}   // (@$pts ? $pts->[-1]{ts}  : undef);
	my $ts_source = ($cb->{source} eq 'e80') ? 'e80' : ($track->{ts_source} // 'user');

	my $dbh = connectDB();
	return unless $dbh;
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
	_refreshBrowser();
}


1;
