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
		doCut
		doPaste
		doPasteNew
		doRefresh
	);
}


our $dbg_e80_ops = 0;
our $dbg_ops     = 0;


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
	my ($cmd_id, $panel, $node, $tree, @nodes) = @_;
	@nodes = ($node) if !@nodes;

	if ($cmd_id == $nmClipboard::CMD_REMOVE_ROUTEPOINT)
	{
		$panel eq 'browser'
			? _removeBrowserRoutePoint($node, $tree)
			: _removeE80RoutePoint($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_WAYPOINT)
	{
		$panel eq 'browser'
			? _deleteBrowserWaypoints(\@nodes, $tree)
			: _deleteE80Waypoints(\@nodes, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_TRACK)
	{
		$panel eq 'browser'
			? _deleteBrowserTracks(\@nodes, $tree)
			: _deleteE80Tracks(\@nodes, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_BRANCH)
	{
		_deleteBrowserCollection($node, $tree, 'Branch');
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_GROUP)
	{
		$panel eq 'browser'
			? _deleteBrowserGroups(\@nodes, $tree)
			: _deleteE80Groups(\@nodes, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_GROUP_WPS)
	{
		$panel eq 'browser'
			? _deleteBrowserGroupsAndWPs(\@nodes, $tree)
			: _deleteE80GroupsAndWPs(\@nodes, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CMD_DELETE_ROUTE)
	{
		$panel eq 'browser'
			? _deleteBrowserRoutes(\@nodes, $tree)
			: _deleteE80Routes(\@nodes, $tree);
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
	my ($intent, $panel, $node, $tree, @nodes) = @_;
	@nodes = ($node) if !@nodes;
	display($dbg_ops, 0, "nmOps::doCopy: intent=$intent panel=$panel nodes=" . scalar(@nodes));

	if ($intent =~ /^waypoints?$/)
	{
		_copyWaypoint($intent, $panel, $node, $tree, @nodes);
	}
	elsif ($intent =~ /^tracks?$/)
	{
		_copyTrack($intent, $panel, $node, $tree);
	}
	elsif ($intent =~ /^groups?$/)
	{
		_copyGroup($intent, $panel, $node, $tree, @nodes);
	}
	elsif ($intent =~ /^routes?$/)
	{
		_copyRoute($intent, $panel, $node, $tree, @nodes);
	}
	else
	{
		display(0, 0, "nmOps::doCopy: intent '$intent' not yet implemented");
	}
}


sub _copyWaypoint
{
	my ($intent, $panel, $node, $tree, @nodes) = @_;
	@nodes = ($node) if !@nodes;

	if ($panel eq 'e80')
	{
		nmClipboard::setCopy($intent, 'e80', [
			map { { type => 'waypoint', uuid => $_->{uuid}, data => $_->{data} } } @nodes
		]);
	}
	else
	{
		my $dbh = connectDB();
		return if !$dbh;
		my @items;
		for my $n (@nodes)
		{
			my $uuid = $n->{data}{uuid};
			my $wp   = getWaypoint($dbh, $uuid);
			push @items, { type => 'waypoint', uuid => $uuid, data => $wp } if $wp;
		}
		disconnectDB($dbh);
		if (!@items)
		{
			Wx::MessageBox("Could not load waypoint.", "Copy Waypoint", wxOK | wxICON_ERROR, $tree);
			return;
		}
		nmClipboard::setCopy($intent, 'browser', \@items);
	}
}


sub _copyTrack
{	my ($intent, $panel, $node, $tree) = @_;

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


sub _copyGroup
{
	my ($intent, $panel, $node, $tree, @nodes) = @_;
	@nodes = ($node) if !@nodes;

	if ($panel eq 'e80')
	{
		my $wpmgr = _wpmgr();
		if (!$wpmgr)
		{
			Wx::MessageBox("E80 not connected.", "Copy Group", wxOK | wxICON_ERROR, $tree);
			return;
		}
		my $wps    = $wpmgr->{waypoints} // {};
		my $groups = $wpmgr->{groups}    // {};
		my @items;

		for my $n (@nodes)
		{
			my $ntype = $n->{type} // '';
			if ($ntype eq 'header')
			{
				for my $g_uuid (sort keys %$groups)
				{
					my $grp_data = $groups->{$g_uuid};
					my @members;
					for my $wp_uuid (@{$grp_data->{uuids} // []})
					{
						push @members, { type => 'waypoint', uuid => $wp_uuid, data => $wps->{$wp_uuid} };
					}
					push @items, { type => 'group', uuid => $g_uuid, data => $grp_data, members => \@members };
				}
			}
			elsif ($ntype eq 'my_waypoints')
			{
				my %grouped;
				$grouped{$_} = 1 for map { @{$_->{uuids} // []} } values %$groups;
				my @members;
				for my $wp_uuid (grep { !$grouped{$_} } keys %$wps)
				{
					push @members, { type => 'waypoint', uuid => $wp_uuid, data => $wps->{$wp_uuid} };
				}
				push @items, { type => 'group', uuid => undef, data => { name => 'My Waypoints' }, members => \@members };
			}
			else
			{
				my $uuid     = $n->{uuid};
				my $grp_data = $n->{data};
				my @members;
				for my $wp_uuid (@{$grp_data->{uuids} // []})
				{
					push @members, { type => 'waypoint', uuid => $wp_uuid, data => $wps->{$wp_uuid} };
				}
				push @items, { type => 'group', uuid => $uuid, data => $grp_data, members => \@members };
			}
		}
		display($dbg_ops, 0, "nmOps::_copyGroup e80: " . scalar(@items) . " group(s)");
		nmClipboard::setCopy($intent, 'e80', \@items);
	}
	else
	{
		my $dbh = connectDB();
		return if !$dbh;
		my @items;

		for my $n (@nodes)
		{
			my $node_type = ($n->{data} // {})->{node_type} // '';
			if ($node_type ne 'group')
			{
				my $branch_uuid = ($n->{data} // {})->{uuid};
				my $children    = getCollectionChildren($dbh, $branch_uuid);
				for my $child (@{$children // []})
				{
					next if ($child->{node_type} // '') ne 'group';
					my $grp   = getCollection($dbh, $child->{uuid});
					next if !$grp;
					my $stubs = getGroupWaypoints($dbh, $child->{uuid});
					my @members;
					for my $stub (@{$stubs // []})
					{
						my $wp = getWaypoint($dbh, $stub->{uuid});
						push @members, { type => 'waypoint', uuid => $stub->{uuid}, data => $wp } if $wp;
					}
					push @items, { type => 'group', uuid => $child->{uuid}, data => $grp, members => \@members };
				}
			}
			else
			{
				my $uuid  = ($n->{data} // {})->{uuid};
				my $grp   = getCollection($dbh, $uuid);
				if (!$grp)
				{
					warning(0, 0, "_copyGroup: could not load group $uuid");
					next;
				}
				my $stubs = getGroupWaypoints($dbh, $uuid);
				my @members;
				for my $stub (@{$stubs // []})
				{
					my $wp = getWaypoint($dbh, $stub->{uuid});
					push @members, { type => 'waypoint', uuid => $stub->{uuid}, data => $wp } if $wp;
				}
				push @items, { type => 'group', uuid => $uuid, data => $grp, members => \@members };
			}
		}
		disconnectDB($dbh);

		if (!@items)
		{
			Wx::MessageBox("No groups found to copy.", "Copy Groups", wxOK | wxICON_INFORMATION, $tree);
			return;
		}
		display($dbg_ops, 0, "nmOps::_copyGroup browser: " . scalar(@items) . " group(s)");
		nmClipboard::setCopy($intent, 'browser', \@items);
	}
}


sub _copyRoute
{
	my ($intent, $panel, $node, $tree, @nodes) = @_;
	@nodes = ($node) if !@nodes;

	if ($panel eq 'e80')
	{
		my $wpmgr = _wpmgr();
		if (!$wpmgr)
		{
			Wx::MessageBox("E80 not connected.", "Copy Route", wxOK | wxICON_ERROR, $tree);
			return;
		}
		my $wps    = $wpmgr->{waypoints} // {};
		my $routes = $wpmgr->{routes}    // {};
		my @items;

		for my $n (@nodes)
		{
			if (($n->{type} // '') eq 'header')
			{
				for my $r_uuid (sort keys %$routes)
				{
					my $route = $routes->{$r_uuid};
					my @members;
					my $pos = 0;
					for my $wp_uuid (@{$route->{uuids} // []})
					{
						push @members, { type => 'waypoint', uuid => $wp_uuid, data => $wps->{$wp_uuid}, position => $pos++ };
					}
					push @items, { type => 'route', uuid => $r_uuid, data => $route, members => \@members };
				}
			}
			else
			{
				my $uuid  = $n->{uuid};
				my $route = $n->{data};
				my @members;
				my $pos = 0;
				for my $wp_uuid (@{$route->{uuids} // []})
				{
					push @members, { type => 'waypoint', uuid => $wp_uuid, data => $wps->{$wp_uuid}, position => $pos++ };
				}
				push @items, { type => 'route', uuid => $uuid, data => $route, members => \@members };
			}
		}
		display($dbg_ops, 0, "nmOps::_copyRoute e80: " . scalar(@items) . " route(s)");
		nmClipboard::setCopy($intent, 'e80', \@items);
	}
	else
	{
		my $dbh = connectDB();
		return if !$dbh;
		my @items;

		for my $n (@nodes)
		{
			if (($n->{type} // '') eq 'collection')
			{
				my $coll_uuid = ($n->{data} // {})->{uuid};
				my $objs      = getCollectionObjects($dbh, $coll_uuid);
				for my $obj (grep { ($_->{obj_type} // '') eq 'route' } @{$objs // []})
				{
					my $r_uuid = $obj->{uuid};
					my $route  = getRoute($dbh, $r_uuid);
					next if !$route;
					my $stubs  = getRouteWaypoints($dbh, $r_uuid);
					my @members;
					for my $stub (@{$stubs // []})
					{
						my $wp = getWaypoint($dbh, $stub->{uuid});
						push @members, { type => 'waypoint', uuid => $stub->{uuid}, data => $wp, position => $stub->{position} } if $wp;
					}
					push @items, { type => 'route', uuid => $r_uuid, data => $route, members => \@members };
				}
			}
			else
			{
				my $uuid  = ($n->{data} // {})->{uuid};
				my $route = getRoute($dbh, $uuid);
				if (!$route)
				{
					warning(0, 0, "_copyRoute: could not load route $uuid");
					next;
				}
				my $stubs = getRouteWaypoints($dbh, $uuid);
				my @members;
				for my $stub (@{$stubs // []})
				{
					my $wp = getWaypoint($dbh, $stub->{uuid});
					push @members, { type => 'waypoint', uuid => $stub->{uuid}, data => $wp, position => $stub->{position} } if $wp;
				}
				push @items, { type => 'route', uuid => $uuid, data => $route, members => \@members };
			}
		}
		disconnectDB($dbh);

		if (!@items)
		{
			Wx::MessageBox("No routes found to copy.", "Copy Routes", wxOK | wxICON_INFORMATION, $tree);
			return;
		}
		display($dbg_ops, 0, "nmOps::_copyRoute browser: " . scalar(@items) . " route(s)");
		nmClipboard::setCopy($intent, 'browser', \@items);
	}
}


#----------------------------------------------------
# doCut
#----------------------------------------------------

sub doCut
{
	my ($intent, $panel, $node, $tree, @nodes) = @_;
	@nodes = ($node) if !@nodes;
	display($dbg_ops, 0, "nmOps::doCut: intent=$intent panel=$panel nodes=" . scalar(@nodes));

	if ($intent =~ /^waypoints?$/)
	{
		_copyWaypoint($intent, $panel, $node, $tree, @nodes);
		$nmClipboard::clipboard->{cut} = 1 if $nmClipboard::clipboard;
	}
	elsif ($intent =~ /^tracks?$/)
	{
		_copyTrack($intent, $panel, $node, $tree);
		$nmClipboard::clipboard->{cut} = 1 if $nmClipboard::clipboard;
	}
	elsif ($intent =~ /^groups?$/)
	{
		_copyGroup($intent, $panel, $node, $tree, @nodes);
		$nmClipboard::clipboard->{cut} = 1 if $nmClipboard::clipboard;
	}
	elsif ($intent =~ /^routes?$/)
	{
		_copyRoute($intent, $panel, $node, $tree, @nodes);
		$nmClipboard::clipboard->{cut} = 1 if $nmClipboard::clipboard;
	}
	else
	{
		display(0, 0, "nmOps::doCut: intent '$intent' not yet implemented");
	}
}


#----------------------------------------------------
# Conflict resolution helpers
#----------------------------------------------------

my $ID_REPLACE     = 10901;
my $ID_SKIP        = 10902;
my $ID_REPLACE_ALL = 10903;
my $ID_SKIP_ALL    = 10904;
my $ID_ABORT       = 10905;

sub _resolveConflict
{
	my ($tree, $title, $item_name, $detail) = @_;

	my $dlg = Wx::Dialog->new($tree // getAppFrame(), -1, $title,
		wxDefaultPosition, [-1, -1],
		wxDEFAULT_DIALOG_STYLE);

	my $vsizer    = Wx::BoxSizer->new(wxVERTICAL);
	my $btn_sizer = Wx::BoxSizer->new(wxHORIZONTAL);

	my $msg = "Waypoint '$item_name' already exists at the destination.\nReplace with the clipboard version?";
	$msg .= "\n\n$detail" if $detail;
	$vsizer->Add(
		Wx::StaticText->new($dlg, -1, $msg),
		0, wxALL, 12);

	$btn_sizer->Add(Wx::Button->new($dlg, $ID_REPLACE,     'Replace'),     0, wxRIGHT, 6);
	$btn_sizer->Add(Wx::Button->new($dlg, $ID_SKIP,        'Skip'),        0, wxRIGHT, 6);
	$btn_sizer->Add(Wx::Button->new($dlg, $ID_REPLACE_ALL, 'Replace All'), 0, wxRIGHT, 6);
	$btn_sizer->Add(Wx::Button->new($dlg, $ID_SKIP_ALL,    'Skip All'),    0, wxRIGHT, 6);
	$btn_sizer->Add(Wx::Button->new($dlg, $ID_ABORT,       'Abort'),       0);
	$vsizer->Add($btn_sizer, 0, wxALL | wxALIGN_CENTER, 12);

	$dlg->SetSizerAndFit($vsizer);
	$dlg->Centre();

	Wx::Event::EVT_BUTTON($dlg, -1, sub { $_[0]->EndModal($_[1]->GetId()) });
	Wx::Event::EVT_CLOSE($dlg, sub { $_[1]->Veto() });

	my $result = $dlg->ShowModal();
	$dlg->Destroy();

	return 'replace'     if $result == $ID_REPLACE;
	return 'replace_all' if $result == $ID_REPLACE_ALL;
	return 'skip_all'    if $result == $ID_SKIP_ALL;
	return 'abort'       if $result == $ID_ABORT;
	return 'skip';
}


sub _wpFieldsDiffer
{
	my ($existing, $new_data, $source) = @_;
	my @fields = qw(name comment lat lon sym);
	push @fields, qw(wp_type color depth_cm) if $source eq 'browser';
	my @diffs;
	for my $f (@fields)
	{
		my $a = $existing->{$f} // '';
		my $b = $new_data->{$f}  // '';
		if ($f eq 'lat' || $f eq 'lon')
		{
			my $an = abs($a + 0) > 900 ? ($a + 0) / 1e7 : $a + 0;
			my $bn = abs($b + 0) > 900 ? ($b + 0) / 1e7 : $b + 0;
			push @diffs, "$f: existing=$a new=$b" if abs($an - $bn) > 1e-7;
		}
		elsif ("$a" ne "$b")
		{
			push @diffs, "$f: existing='$a' new='$b'";
		}
	}
	return '' unless @diffs;
	display($dbg_e80_ops, 2, "wp conflict: " . join("; ", @diffs));
	return $diffs[0];
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
	my @items  = @{$cb->{items} // []};
	if (!@items)
	{
		Wx::MessageBox("Clipboard is empty.", "Paste", wxOK | wxICON_INFORMATION, $tree);
		return;
	}
	display($dbg_ops, 0, "nmOps::doPaste: intent=$intent panel=$panel items=" . scalar(@items));

	if ($panel eq 'browser')
	{
		if ($intent =~ /^waypoints?$/)
		{
			_pasteWaypointToBrowser($node, $tree, $_, $cb) for @items;
		}
		elsif ($intent =~ /^tracks?$/)
		{
			_pasteTrackToBrowser($node, $tree, $_, $cb) for @items;
		}
		elsif ($intent =~ /^groups?$/)
		{
			_pasteGroupToBrowser($node, $tree, $_, $cb) for @items;
		}
		elsif ($intent =~ /^routes?$/)
		{
			_pasteRouteToBrowser($node, $tree, $_, $cb) for @items;
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
			_pasteWaypointToE80($node, $tree, $_, $cb) for @items;
		}
		elsif ($intent =~ /^groups?$/)
		{
			my $progress = undef;
			if (@items > 1)
			{
				my $total = 0;
				$total += scalar(@{$_->{members} // []}) + ($_->{uuid} ? 1 : 0) for @items;
				$progress = _openE80Progress("Paste Groups", $total,
					{cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
			}
			_pasteGroupToE80($node, $tree, $_, $cb, $progress) for @items;
		}
		elsif ($intent =~ /^routes?$/)
		{
			my $progress = undef;
			if (@items > 1)
			{
				my $total = 0;
				$total += (2 * scalar(@{$_->{members} // []})) + 1 for @items;
				$progress = _openE80Progress("Paste Routes", $total,
					{cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
				$progress->{_counting_get_items} = 1 if $progress;
			}
			_pasteRouteToE80($node, $tree, $_, $cb, $progress) for @items;
		}
		else
		{
			_unimplementedPaste($intent, $panel, $tree);
		}
	}
}


#----------------------------------------------------
# doPasteNew
#----------------------------------------------------

sub doPasteNew
{
	my ($panel, $node, $tree) = @_;

	my $cb = $nmClipboard::clipboard;
	if (!$cb)
	{
		Wx::MessageBox("Nothing to paste.", "Paste New", wxOK | wxICON_INFORMATION, $tree);
		return;
	}

	my $intent = $cb->{intent};
	my @items  = @{$cb->{items} // []};
	if (!@items)
	{
		Wx::MessageBox("Clipboard is empty.", "Paste New", wxOK | wxICON_INFORMATION, $tree);
		return;
	}
	display($dbg_ops, 0, "nmOps::doPasteNew: intent=$intent panel=$panel items=" . scalar(@items));

	if ($panel eq 'browser')
	{
		if ($intent =~ /^waypoints?$/)
		{
			_pasteNewWaypointToBrowser($node, $tree, $_, $cb) for @items;
		}
		elsif ($intent =~ /^groups?$/)
		{
			_pasteNewGroupToBrowser($node, $tree, $_, $cb) for @items;
		}
		elsif ($intent =~ /^routes?$/)
		{
			_pasteNewRouteToBrowser($node, $tree, $_, $cb) for @items;
		}
		else
		{
			_unimplementedPaste($intent, $panel, $tree);
		}
	}
	else
	{
		if ($intent =~ /^waypoints?$/)
		{
			_pasteNewWaypointToE80($node, $tree, $_, $cb) for @items;
		}
		elsif ($intent =~ /^groups?$/)
		{
			my $progress = undef;
			if (@items > 1)
			{
				my $total = 0;
				$total += scalar(@{$_->{members} // []}) + 1 for @items;
				$progress = _openE80Progress("Paste New Groups", $total,
					{cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
			}
			_pasteNewGroupToE80($node, $tree, $_, $cb, $progress) for @items;
		}
		elsif ($intent =~ /^routes?$/)
		{
			my $progress = undef;
			if (@items > 1)
			{
				my $total = 0;
				$total += (2 * scalar(@{$_->{members} // []})) + 1 for @items;
				$progress = _openE80Progress("Paste New Routes", $total,
					{cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
				$progress->{_counting_get_items} = 1 if $progress;
			}
			_pasteNewRouteToE80($node, $tree, $_, $cb, $progress) for @items;
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
