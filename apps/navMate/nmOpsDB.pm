#!/usr/bin/perl
#---------------------------------------------
# nmOpsDB.pm
#---------------------------------------------
# Browser-side (DB) context-menu operations for navMate.
# Continuation of package nmOps (loaded by nmOps.pm).

package nmOps;
use strict;
use warnings;
use Wx qw(:everything);
use Pub::Utils qw(display warning error);
use c_db;
use a_defs;
use a_utils;
use nmDialogs;


#----------------------------------------------------
# New items
#----------------------------------------------------

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


#----------------------------------------------------
# Remove / Delete
#----------------------------------------------------

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
			"Group '$name' has waypoints used in routes — remove them from routes first.",
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


#----------------------------------------------------
# Paste
#----------------------------------------------------

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
