#!/usr/bin/perl
#---------------------------------------------
# nmOps.pm
#---------------------------------------------
# Context-menu operation dispatcher for navMate.
# E80-side operations are in nmOpsE80.pm.
# Database-side (DB) operations are in nmOpsDB.pm.
# All three files share package nmOps.

package nmOps;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Pub::Utils qw(display warning error getAppFrame);
use Pub::WX::Dialogs;
use apps::raymarine::NET::a_defs;
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
		abgrToE80Index
	);
}


our $dbg_e80_ops = 0;
our $dbg_ops     = 0;


#----------------------------------------------------
# Common helpers
#----------------------------------------------------

sub _refreshDatabase
{
	my $frame = getAppFrame();
	my $pane  = $frame ? $frame->findPane($WIN_DATABASE) : undef;
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
	return undef if !(defined($s) && $s ne '');
	return $s;
}

sub abgrToE80Index
{
	my ($abgr) = @_;
	return 0 if !($abgr && length($abgr) >= 8);
	my $rr = hex(substr($abgr, 6, 2));
	my $gg = hex(substr($abgr, 4, 2));
	my $bb = hex(substr($abgr, 2, 2));
	my @targets = (
		[255,   0,   0],   # 0 RED
		[255, 255,   0],   # 1 YELLOW
		[  0, 255,   0],   # 2 GREEN
		[  0,   0, 255],   # 3 BLUE
		[255,   0, 255],   # 4 PURPLE
		[255, 255, 255],   # 5 WHITE
	);
	my ($best_idx, $best_dist) = (0, 9e99);
	for my $i (0 .. $#targets)
	{
		my $d = ($rr - $targets[$i][0])**2
		      + ($gg - $targets[$i][1])**2
		      + ($bb - $targets[$i][2])**2;
		$best_idx = $i if $d < $best_dist and do { $best_dist = $d; 1 };
	}
	return $best_idx;
}

my @E80_ROUTE_INDEX_TO_ABGR = qw(ff0000ff ff00ffff ff00ff00 ffff0000 ffff00ff ffffffff);
my @E80_TRACK_INDEX_TO_ABGR = qw(ff0000ff ff00ffff ff00ff00 ffff0000 ffff00ff ff000000);

sub e80RouteIndexToAbgr { $E80_ROUTE_INDEX_TO_ABGR[$_[0] // 0] // $E80_ROUTE_INDEX_TO_ABGR[0] }
sub e80TrackIndexToAbgr { $E80_TRACK_INDEX_TO_ABGR[$_[0] // 0] // $E80_TRACK_INDEX_TO_ABGR[0] }

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
		okDialog($parent, "E80 not connected — cannot refresh.", "Refresh E80");
		return;
	}

	if ($apps::raymarine::NET::d_WPMGR::query_in_progress ||
	    $apps::raymarine::NET::d_TRACK::query_in_progress)
	{
		okDialog($parent, "A query is already in progress — please wait.", "Refresh E80");
		return;
	}

	my $progress = Pub::WX::ProgressDialog::newProgressData(4, 2);
	$progress->{active} = 1;

	my $dlg = Pub::WX::ProgressDialog->new(
		$parent // getAppFrame(),
		'Refreshing E80...',
		1,
		$progress);
	return if !$dlg;

	$wpmgr->queueRefresh($progress);
	$track->queueRefresh($progress);
}


#----------------------------------------------------
# doNew
#----------------------------------------------------

sub doNew
{
	my ($cmd_id, $panel, $node, $tree) = @_;

	if ($cmd_id == $nmClipboard::CTX_CMD_NEW_BRANCH)
	{
		_newCollection($node, $tree, 'Branch', $NODE_TYPE_BRANCH);
	}
	elsif ($cmd_id == $nmClipboard::CTX_CMD_NEW_GROUP)
	{
		$panel eq 'database'
			? _newCollection($node, $tree, 'Group', $NODE_TYPE_GROUP)
			: _newE80Group($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CTX_CMD_NEW_ROUTE)
	{
		$panel eq 'database'
			? _newDatabaseRoute($node, $tree)
			: _newE80Route($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CTX_CMD_NEW_WAYPOINT)
	{
		$panel eq 'database'
			? _newDatabaseWaypoint($node, $tree)
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

	if ($cmd_id == $nmClipboard::CTX_CMD_REMOVE_ROUTEPOINT)
	{
		$panel eq 'database'
			? _removeDatabaseRoutePoint($node, $tree)
			: _removeE80RoutePoint($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CTX_CMD_DELETE_WAYPOINT)
	{
		$panel eq 'database'
			? _deleteDatabaseWaypoints(\@nodes, $tree)
			: _deleteE80Waypoints(\@nodes, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CTX_CMD_DELETE_TRACK)
	{
		$panel eq 'database'
			? _deleteDatabaseTracks(\@nodes, $tree)
			: _deleteE80Tracks(\@nodes, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CTX_CMD_DELETE_BRANCH)
	{
		_deleteDatabaseBranch($node, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CTX_CMD_DELETE_GROUP)
	{
		$panel eq 'database'
			? _deleteDatabaseGroups(\@nodes, $tree)
			: _deleteE80Groups(\@nodes, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CTX_CMD_DELETE_GROUP_WPS)
	{
		$panel eq 'database'
			? _deleteDatabaseGroupsAndWPs(\@nodes, $tree)
			: _deleteE80GroupsAndWPs(\@nodes, $tree);
	}
	elsif ($cmd_id == $nmClipboard::CTX_CMD_DELETE_ROUTE)
	{
		$panel eq 'database'
			? _deleteDatabaseRoutes(\@nodes, $tree)
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
	elsif ($intent eq 'all')
	{
		_copyAll($intent, $panel, $node, $tree, @nodes);
	}
	else
	{
		display(0, 0, "nmOps::doCopy: intent '$intent' not yet implemented");
	}
}


sub _e80WpClipData
	# E80 wpmgr records carry lat/lon as 1e7 scaled ints.
	# Clipboard and API layer use decimal degrees.
	# Call this on every E80 waypoint data hash before putting it in the clipboard.
{
	my ($data) = @_;
	my $d = { %$data };
	$d->{lat} = ($d->{lat} // 0) / $SCALE_LATLON;
	$d->{lon} = ($d->{lon} // 0) / $SCALE_LATLON;
	return $d;
}


sub _copyWaypoint
{
	my ($intent, $panel, $node, $tree, @nodes) = @_;
	@nodes = ($node) if !@nodes;

	if ($panel eq 'e80')
	{
		nmClipboard::setCopy($intent, 'e80', [
			map { { type => 'waypoint', uuid => $_->{uuid}, data => _e80WpClipData($_->{data}) } } @nodes
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
			error("_copyWaypoint: could not load waypoint(s) from database");
			return;
		}
		nmClipboard::setCopy($intent, 'database', \@items);
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
			error("_copyTrack: could not load track $uuid from database");
			return;
		}
		my $pts = getTrackPoints($dbh, $uuid);
		disconnectDB($dbh);
		$track->{points} = $pts // [];
		nmClipboard::setCopy($intent, 'database', [{
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
			error("_copyGroup: WPMGR not connected");
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
						push @members, { type => 'waypoint', uuid => $wp_uuid, data => _e80WpClipData($wps->{$wp_uuid}) };
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
					push @members, { type => 'waypoint', uuid => $wp_uuid, data => _e80WpClipData($wps->{$wp_uuid}) };
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
					push @members, { type => 'waypoint', uuid => $wp_uuid, data => _e80WpClipData($wps->{$wp_uuid}) };
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
			warning(0, 0, "IMPLEMENTATION ERROR: _copyGroup: no groups found in database selection");
			return;
		}
		display($dbg_ops, 0, "nmOps::_copyGroup database: " . scalar(@items) . " group(s)");
		nmClipboard::setCopy($intent, 'database', \@items);
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
			error("_copyRoute: WPMGR not connected");
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
						push @members, { type => 'waypoint', uuid => $wp_uuid, data => _e80WpClipData($wps->{$wp_uuid}), position => $pos++ };
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
					push @members, { type => 'waypoint', uuid => $wp_uuid, data => _e80WpClipData($wps->{$wp_uuid}), position => $pos++ };
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
			warning(0, 0, "IMPLEMENTATION ERROR: _copyRoute: no routes found in database selection");
			return;
		}
		display($dbg_ops, 0, "nmOps::_copyRoute database: " . scalar(@items) . " route(s)");
		nmClipboard::setCopy($intent, 'database', \@items);
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
	elsif ($intent eq 'all')
	{
		_copyAll($intent, $panel, $node, $tree, @nodes);
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
	my @fields = qw(name comment lat lon);
	push @fields, qw(wp_type color depth_cm) if $source eq 'database';
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
		warning(0, 0, "doPaste: clipboard is empty");
		return;
	}

	my $intent = $cb->{intent};
	my @items  = @{$cb->{items} // []};
	if (!@items)
	{
		warning(0, 0, "doPaste: no items in clipboard");
		return;
	}
	display($dbg_ops, 0, "nmOps::doPaste: intent=$intent panel=$panel items=" . scalar(@items));

	if ($panel eq 'database')
	{
		if ($intent =~ /^waypoints?$/)
		{
			_pasteWaypointToDatabase($node, $tree, $_, $cb) for @items;
		}
		elsif ($intent =~ /^tracks?$/)
		{
			_pasteTrackToDatabase($node, $tree, $_, $cb) for @items;
		}
		elsif ($intent =~ /^groups?$/)
		{
			_pasteGroupToDatabase($node, $tree, $_, $cb) for @items;
		}
		elsif ($intent =~ /^routes?$/)
		{
			_pasteRouteToDatabase($node, $tree, $_, $cb) for @items;
		}
		elsif ($intent eq 'all')
		{
			_pasteAllToDatabase($node, $tree, $cb);
		}
		else
		{
			_unimplementedPaste($intent, $panel, $tree);
		}
	}
	elsif ($panel eq 'e80')
	{
		if ($cb->{cut} && ($cb->{source} // '') eq 'database')
		{
			warning(0, 0, "IMPLEMENTATION ERROR: D-CT-DB->E80 paste reached doPaste; canPaste should have blocked this");
			return;
		}
		if ($intent =~ /^waypoints?$/)
		{
			my %pending_names;
			my $progress = undef;
			if (@items > 1)
			{
				my $node_type  = $node->{type} // '';
				my $group_uuid =
					($node_type eq 'group')       ? $node->{uuid}       :
					($node_type eq 'waypoint')    ? $node->{group_uuid} :
					($node_type eq 'route_point') ? $node->{group_uuid} : undef;
				my $total = scalar(@items) * (1 + ($group_uuid ? 1 : 0));
				$progress = _openE80Progress("Paste Waypoints", $total,
					{cancel_label => 'Abort', cancel_msg => 'Aborted by user'});
				return if !$progress;
			}
			_pasteWaypointToE80($node, $tree, $_, $cb, undef, \%pending_names, $progress) for @items;
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
				return if !$progress;
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
				return if !$progress;
				$progress->{_counting_get_items} = 1;
			}
			_pasteRouteToE80($node, $tree, $_, $cb, $progress) for @items;
		}
		elsif ($intent eq 'all')
		{
			_pasteAllToE80($node, $tree, $cb);
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
		warning(0, 0, "doPasteNew: clipboard is empty");
		return;
	}

	my $intent = $cb->{intent};
	my @items  = @{$cb->{items} // []};
	if (!@items)
	{
		warning(0, 0, "doPasteNew: no items in clipboard");
		return;
	}
	display($dbg_ops, 0, "nmOps::doPasteNew: intent=$intent panel=$panel items=" . scalar(@items));

	if ($panel eq 'database')
	{
		if ($intent =~ /^waypoints?$/)
		{
			_pasteNewWaypointToDatabase($node, $tree, $_, $cb) for @items;
		}
		elsif ($intent =~ /^groups?$/)
		{
			_pasteNewGroupToDatabase($node, $tree, $_, $cb) for @items;
		}
		elsif ($intent =~ /^routes?$/)
		{
			_pasteNewRouteToDatabase($node, $tree, $_, $cb) for @items;
		}
		elsif ($intent eq 'all')
		{
			_pasteNewAllToDatabase($node, $tree, $cb);
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
				return if !$progress;
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
				return if !$progress;
				$progress->{_counting_get_items} = 1;
			}
			_pasteNewRouteToE80($node, $tree, $_, $cb, $progress) for @items;
		}
		else
		{
			_unimplementedPaste($intent, $panel, $tree);
		}
	}
}


sub _copyAll
{
	my ($intent, $panel, $node, $tree, @nodes) = @_;
	@nodes = ($node) if !@nodes;

	if ($panel eq 'e80')
	{
		my $wpmgr = _wpmgr();
		if (!$wpmgr)
		{
			error("_copyAll: WPMGR not connected");
			return;
		}
		my $wps    = $wpmgr->{waypoints} // {};
		my $groups = $wpmgr->{groups}    // {};
		my $routes = $wpmgr->{routes}    // {};
		my @items;

		for my $g_uuid (sort keys %$groups)
		{
			my $grp = $groups->{$g_uuid};
			my @members;
			for my $wp_uuid (@{$grp->{uuids} // []})
			{
				push @members, { type => 'waypoint', uuid => $wp_uuid, data => _e80WpClipData($wps->{$wp_uuid}) };
			}
			push @items, { type => 'group', uuid => $g_uuid, data => $grp, members => \@members };
		}

		for my $r_uuid (sort keys %$routes)
		{
			my $route = $routes->{$r_uuid};
			my @members;
			my $pos = 0;
			for my $wp_uuid (@{$route->{uuids} // []})
			{
				push @members, { type => 'waypoint', uuid => $wp_uuid, data => _e80WpClipData($wps->{$wp_uuid}), position => $pos++ };
			}
			push @items, { type => 'route', uuid => $r_uuid, data => $route, members => \@members };
		}

		my %grouped;
		$grouped{$_} = 1 for map { @{$_->{uuids} // []} } values %$groups;
		for my $wp_uuid (sort grep { !$grouped{$_} } keys %$wps)
		{
			push @items, { type => 'waypoint', uuid => $wp_uuid, data => _e80WpClipData($wps->{$wp_uuid}) };
		}

		display($dbg_ops, 0, "nmOps::_copyAll e80: " . scalar(@items) . " item(s)");
		nmClipboard::setCopy($intent, 'e80', \@items);
	}
	else
	{
		my $dbh = connectDB();
		return if !$dbh;
		my @items;

		for my $n (@nodes)
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

			my $objs = getCollectionObjects($dbh, $branch_uuid);
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

			for my $obj (grep { ($_->{obj_type} // '') eq 'track' } @{$objs // []})
			{
				my $t_uuid = $obj->{uuid};
				my $track  = getTrack($dbh, $t_uuid);
				next if !$track;
				my $pts    = getTrackPoints($dbh, $t_uuid);
				$track->{points} = $pts // [];
				push @items, { type => 'track', uuid => $t_uuid, data => $track };
			}

			for my $obj (grep { ($_->{obj_type} // '') eq 'waypoint' } @{$objs // []})
			{
				my $wp = getWaypoint($dbh, $obj->{uuid});
				push @items, { type => 'waypoint', uuid => $obj->{uuid}, data => $wp } if $wp;
			}
		}

		disconnectDB($dbh);
		display($dbg_ops, 0, "nmOps::_copyAll database: " . scalar(@items) . " item(s)");
		nmClipboard::setCopy($intent, 'database', \@items);
	}
}


sub _pasteAllToDatabase
{
	my ($node, $tree, $cb) = @_;
	my @items = @{$cb->{items} // []};

	for my $item (@items)
	{
		my $type = $item->{type} // '';
		if ($type eq 'waypoint')
		{
			_pasteWaypointToDatabase($node, $tree, $item, $cb);
		}
		elsif ($type eq 'group')
		{
			_pasteGroupToDatabase($node, $tree, $item, $cb);
		}
		elsif ($type eq 'route')
		{
			_pasteRouteToDatabase($node, $tree, $item, $cb);
		}
		elsif ($type eq 'track')
		{
			_pasteTrackToDatabase($node, $tree, $item, $cb);
		}
		else
		{
			warning(0, 0, "_pasteAllToDatabase: unknown item type '$type'");
		}
	}
}


sub _pasteNewAllToDatabase
{
	my ($node, $tree, $cb) = @_;
	my @items = @{$cb->{items} // []};

	for my $item (@items)
	{
		my $type = $item->{type} // '';
		if ($type eq 'waypoint')
		{
			_pasteNewWaypointToDatabase($node, $tree, $item, $cb);
		}
		elsif ($type eq 'group')
		{
			_pasteNewGroupToDatabase($node, $tree, $item, $cb);
		}
		elsif ($type eq 'route')
		{
			_pasteNewRouteToDatabase($node, $tree, $item, $cb);
		}
		elsif ($type eq 'track')
		{
			display($dbg_ops, 0, "_pasteNewAllToDatabase: skipping track (Paste New not supported for tracks)");
		}
		else
		{
			warning(0, 0, "_pasteNewAllToDatabase: unknown item type '$type'");
		}
	}
}


sub _unimplementedPaste
{
	my ($intent, $panel, $tree) = @_;
	warning(0, 0, "IMPLEMENTATION WARNING: paste intent='$intent' panel='$panel' not implemented; canPaste/canPasteNew should have blocked this");
}


1;
