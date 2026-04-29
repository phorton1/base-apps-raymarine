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

	if ($cmd_id == $nmClipboard::CMD_DELETE_WAYPOINT)
	{
		$panel eq 'browser'
			? _deleteBrowserWaypoint($node, $tree)
			: _deleteE80Waypoint($node, $tree);
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
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_ROUTE)
	{
		$panel eq 'browser'
			? _deleteBrowserRoute($node, $tree)
			: _deleteE80Route($node, $tree);
	}
	else
	{
		warning(0,0,"nmOps::doDelete: unimplemented cmd=$cmd_id panel=$panel");
	}
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

	if ($n > 0)
	{
		Wx::MessageBox("Route '$name' has $n waypoint(s) — use 'Delete Route + Waypoints'.",
			"Delete Route", wxOK | wxICON_WARNING, $tree);
		return;
	}

	my $rc = Wx::MessageBox("Delete route '$name'?", "Confirm Delete",
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

	my $uuid    = $node->{uuid};
	my $name    = $node->{data}{name};
	my $members = $node->{data}{uuids} // [];

	if (@$members > 0)
	{
		Wx::MessageBox("Group '$name' has " . scalar(@$members) .
			" member(s) — use 'Delete Group + Waypoints'.",
			"Delete Group", wxOK | wxICON_WARNING, $tree);
		return;
	}

	my $rc = Wx::MessageBox("Delete group '$name' from E80?", "Confirm Delete",
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
	my $wps  = $node->{data}{uuids} // [];

	if (@$wps > 0)
	{
		Wx::MessageBox("Route '$name' has " . scalar(@$wps) .
			" waypoint(s) — use 'Delete Route + Waypoints'.",
			"Delete Route", wxOK | wxICON_WARNING, $tree);
		return;
	}

	my $rc = Wx::MessageBox("Delete route '$name' from E80?", "Confirm Delete",
		wxYES_NO | wxNO_DEFAULT | wxICON_QUESTION, $tree);
	return unless $rc == wxYES;

	$wpmgr->deleteRoute($uuid);
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
		($node_type eq 'group')    ? $node->{uuid}       :
		($node_type eq 'waypoint') ? $node->{group_uuid} : undef;

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
