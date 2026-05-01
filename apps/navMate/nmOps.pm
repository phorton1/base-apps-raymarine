#!/usr/bin/perl
#---------------------------------------------
# nmOps.pm
#---------------------------------------------
# Context-menu operation dispatcher for navMate.
# E80-side operations are in nmOpsE80.pm.
# Browser-side (DB) operations are in nmOpsDB.pm.
# All three files share package nmOps.

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
require nmOpsE80;
require nmOpsDB;


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
# Common helpers
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
	return undef if !$dbh;
	my $uuid = newUUID($dbh);
	disconnectDB($dbh);
	return $uuid;
}

sub _parseColor
{
	my ($s) = @_;
	return 0 if !(defined $s && $s ne '');
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

	if (!($wpmgr && $track))
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

	my $progress = Pub::WX::ProgressDialog::newProgressData(0, 2);
	$progress->{active} = 1;

	$wpmgr->queueRefresh($progress);
	$track->queueRefresh($progress);

	Pub::WX::ProgressDialog->new(
		$parent // getAppFrame(),
		'Refreshing E80...',
		1,
		$progress);
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
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_TRACK)
	{
		$panel eq 'browser'
			? _deleteBrowserTrack($node, $tree)
			: _deleteE80Track($node, $tree);
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
		return if !$dbh;
		my $wp = getWaypoint($dbh, $uuid);
		disconnectDB($dbh);
		if (!$wp)
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
		return if !$dbh;
		my $track = getTrack($dbh, $uuid);
		if (!$track)
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
	if (!$cb)
	{
		Wx::MessageBox("Nothing to paste.", "Paste", wxOK | wxICON_INFORMATION, $tree);
		return;
	}

	my $intent = $cb->{intent};
	my $item   = ($cb->{items} // [])->[0];
	if (!$item)
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


1;
