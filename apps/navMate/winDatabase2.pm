#!/usr/bin/perl
#-------------------------------------------------------------------------
# winDatabase2.pm
#-------------------------------------------------------------------------
# Continuation of the winDatabase package (declared in winDatabase.pm),
# split out to keep individual Perl files under ~1100 lines.
#
# Contents:
#   - Leaflet sync (push/pull DB <-> map, resyncDbToLeaflet, onClearMap)
#   - Context menu + tree edit (right-click, key-down, cut, delete)
#   - Import / export + new branch / new group
#   - Show/hide map menu

package winDatabase;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Pub::WX::Dialogs;
use Pub::Utils qw(display warning error);
use navDB;
use navKML;
use navVisibility qw(getDbVisible setDbVisible);
use navOutline;
use navSelection;
use n_defs;
use n_utils;
use navPrefs;
use navServer;
use navOps qw(buildContextMenu onContextMenuCommand);
use nmResources;
use gpsImport qw(import_gps_file find_gpsbabel);
use navMatch;
use winFind;

# winDatabase.pm declares these CTX_CMD_* IDs with `our`.  Re-declared
# here (no assignment) so `use strict` resolves the unqualified
# references in the subs below.
our ($CTX_CMD_SHOW_MAP, $CTX_CMD_HIDE_MAP, $CTX_CMD_DELETE,
     $CTX_CMD_NEW_BRANCH, $CTX_CMD_NEW_GROUP,
     $CTX_CMD_IMPORT_GPS, $CTX_CMD_IMPORT_KML, $CTX_CMD_EXPORT_KML,
     $CTX_CMD_FIND_THIS);

# File-scoped state.  %rendered_uuids is `our` because winDatabase.pm's
# _onSave checks it to know whether an edited object is currently on
# the Leaflet map.
our %rendered_uuids;
my $last_clear_version = 0;
my $CUT_COLOR;


#---------------------------------
# Leaflet sync (push/pull DB <-> map)
#---------------------------------

sub _refreshLoadedSubtree
{
	my ($this, $item, $visible) = @_;
	my $tree  = $this->{tree};
	my $state = $visible ? 1 : 0;
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		my $d = $tree->GetItemData($child);
		if ($d)
		{
			my $node = $d->GetData();
			if (ref $node eq 'HASH')
			{
				if ($node->{type} eq 'object')
				{
					$tree->SetItemState($child, $state);
					$node->{data}{visible} = $visible;
				}
				elsif ($node->{type} eq 'collection')
				{
					$tree->SetItemState($child, $state);
					_refreshLoadedSubtree($this, $child, $visible);
				}
			}
		}
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
}


#---------------------------------
# Leaflet push/pull
#---------------------------------

sub _pushObjToLeaflet
{
	my ($dbh, $this, $obj, $accumulator) = @_;
	my $uuid     = $obj->{uuid};
	my $obj_type = $obj->{obj_type};
	my @features;

	if ($obj_type eq 'waypoint')
	{
		my $w = getWaypoint($dbh, $uuid);
		return if !$w;
		$rendered_uuids{$uuid} = 1;
		push @features, {
			type       => 'Feature',
			properties => {
				uuid            => $w->{uuid},
				name            => $w->{name}      // '',
				obj_type        => 'waypoint',
				data_source     => 'db',
				wp_type         => $w->{wp_type}   // 'nav',
				color           => $w->{color},
				depth_cm        => ($w->{depth_cm}  // 0) + 0,
				lat             => ($w->{lat}        // 0) + 0,
				lon             => ($w->{lon}        // 0) + 0,
				comment         => $w->{comment}    // '',
				created_ts      => ($w->{created_ts} // 0) + 0,
				ts_source       => $w->{ts_source}  // '',
				source          => $w->{source}     // '',
				collection_uuid => $w->{collection_uuid} // '',
			},
			geometry => { type => 'Point', coordinates => [$w->{lon}+0, $w->{lat}+0] },
		};
	}
	elsif ($obj_type eq 'track')
	{
		my $t   = getTrack($dbh, $uuid);
		my $pts = getTrackPoints($dbh, $uuid);
		return if !$t || !@$pts;
		$rendered_uuids{$uuid} = 1;
		push @features, {
			type       => 'Feature',
			properties => {
				uuid            => $t->{uuid},
				name            => $t->{name}        // '',
				obj_type        => 'track',
				data_source     => 'db',
				color           => $t->{color},
				point_count     => ($t->{point_count} // 0) + 0,
				ts_start        => ($t->{ts_start}    // 0) + 0,
				ts_end          => ($t->{ts_end}      // 0) + 0,
				ts_source       => $t->{ts_source}   // '',
				collection_uuid => $t->{collection_uuid} // '',
			},
			geometry => { type => 'LineString',
				coordinates => [map { [$_->{lon}+0, $_->{lat}+0] } @$pts] },
		};
	}
	elsif ($obj_type eq 'route')
	{
		my $r   = getRoute($dbh, $uuid);
		my $pts = getRouteWaypoints($dbh, $uuid);
		return if !$r || !@$pts;
		$rendered_uuids{$uuid} = 1;
		my @rp_names = map { $_->{name} // '' } @$pts;
		my @rp_uuids = map { $_->{uuid} // '' } @$pts;
		push @features, {
			type       => 'Feature',
			properties => {
				uuid            => $r->{uuid},
				name            => $r->{name}    // '',
				obj_type        => 'route',
				data_source     => 'db',
				color           => $r->{color},
				wp_count        => scalar(@$pts) + 0,
				rp_names        => \@rp_names,
				rp_uuids        => \@rp_uuids,
				comment         => $r->{comment} // '',
				collection_uuid => $r->{collection_uuid} // '',
			},
			geometry => { type => 'LineString',
				coordinates => [map { [$_->{lon}+0, $_->{lat}+0] } @$pts] },
		};
	}
	if ($accumulator) { push @$accumulator, @features } else { addRenderFeatures(\@features) if @features }
}


sub _pullFromLeaflet
{
	my ($this, $uuid) = @_;
	return if !$rendered_uuids{$uuid};
	my @children = ref($rendered_uuids{$uuid}) eq 'ARRAY' ? @{$rendered_uuids{$uuid}} : ();
	my @remove   = ($uuid, @children);
	delete $rendered_uuids{$_} for @remove;
	removeRenderFeatures('db', \@remove);
}


sub onLeafletTrackEdit
{
	my ($this, $edit) = @_;
	my $op   = $edit->{op}   // '';
	my $uuid = $edit->{uuid} // '';
	return if !$uuid;
	display(0,0,"winDatabase::onLeafletTrackEdit op=$op uuid=$uuid");
	my $dbh = connectDB();
	return if !$dbh;

	if ($op eq 'update')
	{
		my $coords = $edit->{coords} // [];
		if (!@$coords) { disconnectDB($dbh); return; }
		$dbh->do("DELETE FROM track_points WHERE track_uuid=?", [$uuid]);
		my @points = map { { lat => $_->[0], lon => $_->[1] } } @$coords;
		insertTrackPoints($dbh, $uuid, \@points);
		my $n = scalar @points;
		$dbh->do("UPDATE tracks SET db_version=db_version+1, point_count=? WHERE uuid=?",
			[$n, $uuid]);
		$this->_pullFromLeaflet($uuid);
		_pushObjToLeaflet($dbh, $this, { uuid => $uuid, obj_type => 'track' }, undef);
	}
	elsif ($op eq 'split')
	{
		my $split_idx = $edit->{split_idx} // -1;
		my $new_name  = $edit->{new_name}  // '';
		my $pts   = getTrackPoints($dbh, $uuid);
		my $track = getTrack($dbh, $uuid);
		if (!$track || !$pts || @$pts < 2 || $split_idx <= 0 || $split_idx >= $#$pts)
		{
			warning(0,0,"winDatabase::onLeafletTrackEdit split precondition failed uuid=$uuid idx=$split_idx");
			disconnectDB($dbh);
			return;
		}
		my @pts_a = @{$pts}[0 .. $split_idx];
		my @pts_b = @{$pts}[$split_idx .. $#$pts];
		$dbh->do("DELETE FROM track_points WHERE track_uuid=?", [$uuid]);
		insertTrackPoints($dbh, $uuid, \@pts_a);
		$dbh->do("UPDATE tracks SET db_version=db_version+1, point_count=? WHERE uuid=?",
			[scalar @pts_a, $uuid]);
		my $orig_pos  = $track->{position} // 0;
		my $next = $dbh->get_record(
			"SELECT position FROM tracks WHERE collection_uuid=? AND position > ? ORDER BY position ASC LIMIT 1",
			[$track->{collection_uuid}, $orig_pos]);
		my $new_pos = $next ? ($orig_pos + $next->{position}) / 2 : $orig_pos + 1;
		my $new_uuid = insertTrack($dbh,
			name            => $new_name,
			color           => $track->{color}     // 0,
			ts_source       => $track->{ts_source} // '',
			ts_start        => $track->{ts_start}  // 0,
			ts_end          => $track->{ts_end},
			collection_uuid => $track->{collection_uuid},
			point_count     => scalar @pts_b,
			position        => $new_pos,
		);
		setDbVisible($new_uuid, getDbVisible($uuid));
		insertTrackPoints($dbh, $new_uuid, \@pts_b);
		$this->_pullFromLeaflet($uuid);
		_pushObjToLeaflet($dbh, $this, { uuid => $uuid,     obj_type => 'track' }, undef);
		_pushObjToLeaflet($dbh, $this, { uuid => $new_uuid, obj_type => 'track' }, undef);
		$this->refresh();
	}
	elsif ($op eq 'join')
	{
		my $idx_a  = $edit->{idx_a}  // -1;
		my $uuid_b = $edit->{uuid_b} // '';
		my $idx_b  = $edit->{idx_b}  // -1;
		my $pts_a  = getTrackPoints($dbh, $uuid);
		my $pts_b  = getTrackPoints($dbh, $uuid_b);
		if (!$pts_a || !$pts_b || !$uuid_b
			|| $idx_a < 0 || $idx_a > $#$pts_a
			|| $idx_b < 0 || $idx_b > $#$pts_b)
		{
			warning(0,0,"winDatabase::onLeafletTrackEdit join precondition failed uuid=$uuid idx_a=$idx_a uuid_b=$uuid_b idx_b=$idx_b");
			disconnectDB($dbh);
			return;
		}
		my @merged = (@{$pts_a}[0 .. $idx_a], @{$pts_b}[$idx_b .. $#$pts_b]);
		$dbh->do("DELETE FROM track_points WHERE track_uuid=?", [$uuid]);
		insertTrackPoints($dbh, $uuid, \@merged);
		$dbh->do("UPDATE tracks SET db_version=db_version+1, point_count=? WHERE uuid=?",
			[scalar @merged, $uuid]);
		deleteTrack($dbh, $uuid_b);
		$this->_pullFromLeaflet($uuid);
		$this->_pullFromLeaflet($uuid_b);
		_pushObjToLeaflet($dbh, $this, { uuid => $uuid, obj_type => 'track' }, undef);
		$this->refresh();
	}
	else
	{
		warning(0,0,"winDatabase::onLeafletTrackEdit unknown op '$op' for uuid=$uuid");
	}
	disconnectDB($dbh);
}


sub onLeafletRouteEdit
{
	my ($this, $edit) = @_;
	my $op   = $edit->{op}   // '';
	my $uuid = $edit->{uuid} // '';
	display(0,0,"winDatabase::onLeafletRouteEdit op=$op uuid=$uuid");
	my $dbh = connectDB();
	return if !$dbh;

	if ($op eq 'full_update')
	{
		my $waypoints = $edit->{waypoints} // [];
		if (!@$waypoints || !$uuid)
		{
			warning(0,0,"winDatabase::onLeafletRouteEdit full_update: empty waypoints or uuid");
			disconnectDB($dbh);
			return;
		}
		my $route = getRoute($dbh, $uuid);
		if (!$route)
		{
			warning(0,0,"winDatabase::onLeafletRouteEdit full_update: route not found uuid=$uuid");
			disconnectDB($dbh);
			return;
		}
		my $coll_uuid = $route->{collection_uuid};
		my $route_pos = $route->{position} + 0;
		my $new_idx   = 0;

		clearRouteWaypoints($dbh, $uuid);
		for my $i (0 .. $#$waypoints)
		{
			my $wp   = $waypoints->[$i];
			my $wp_uuid = $wp->{uuid};
			if (!$wp_uuid)
			{
				$new_idx++;
				my $wp_pos = $route_pos + $new_idx * 0.001;
				$wp_uuid   = newUUID($dbh);
				my $wp_name = "RNP-" . uc(substr($wp_uuid, 0, 6));
				insertWaypoint($dbh,
					uuid            => $wp_uuid,
					name            => $wp_name,
					lat             => $wp->{lat} + 0,
					lon             => $wp->{lon} + 0,
					wp_type         => $WP_TYPE_NAV,
					color           => 0,
					depth_cm        => 0,
					created_ts      => time(),
					ts_source       => 'nav',
					source          => 'navMate',
					collection_uuid => $coll_uuid,
					position        => $wp_pos);
			}
			else
			{
				$dbh->do("UPDATE waypoints SET lat=?, lon=? WHERE uuid=?",
					[$wp->{lat} + 0, $wp->{lon} + 0, $wp_uuid]);
			}
			appendRouteWaypoint($dbh, $uuid, $wp_uuid, $i + 1);
		}
		$dbh->do("UPDATE routes SET db_version=db_version+1 WHERE uuid=?", [$uuid]);
		$this->_pullFromLeaflet($uuid);
		_pushObjToLeaflet($dbh, $this, { uuid => $uuid, obj_type => 'route' }, undef);
		$this->refresh();
	}
	elsif ($op eq 'split')
	{
		my $split_idx = $edit->{split_idx} // -1;
		my $new_name  = $edit->{new_name}  // '';
		my $route     = getRoute($dbh, $uuid);
		my $wps       = getRouteWaypoints($dbh, $uuid);
		if (!$route || !$wps || @$wps < 2 || $split_idx <= 0 || $split_idx >= $#$wps)
		{
			warning(0,0,"winDatabase::onLeafletRouteEdit split precondition failed uuid=$uuid idx=$split_idx");
			disconnectDB($dbh);
			return;
		}
		my @wps_a = @{$wps}[0 .. $split_idx];
		my @wps_b = @{$wps}[$split_idx .. $#$wps];
		my $orig_pos = $route->{position} + 0;
		my $next_pos = _nextCollItemPos($dbh, $route->{collection_uuid}, $orig_pos);
		my $new_pos  = ($next_pos && $next_pos > $orig_pos) ? ($orig_pos + $next_pos) / 2 : $orig_pos + 1;
		clearRouteWaypoints($dbh, $uuid);
		for my $i (0 .. $#wps_a)
		{
			appendRouteWaypoint($dbh, $uuid, $wps_a[$i]{uuid}, $i + 1);
		}
		$dbh->do("UPDATE routes SET db_version=db_version+1 WHERE uuid=?", [$uuid]);
		my $new_uuid = insertRoute($dbh, $new_name, $route->{color} // 0, $route->{comment} // '',
			$route->{collection_uuid}, $new_pos);
		setDbVisible($new_uuid, getDbVisible($uuid));
		for my $i (0 .. $#wps_b)
		{
			appendRouteWaypoint($dbh, $new_uuid, $wps_b[$i]{uuid}, $i + 1);
		}
		$this->_pullFromLeaflet($uuid);
		_pushObjToLeaflet($dbh, $this, { uuid => $uuid,     obj_type => 'route' }, undef);
		_pushObjToLeaflet($dbh, $this, { uuid => $new_uuid, obj_type => 'route' }, undef);
		$this->refresh();
	}
	elsif ($op eq 'create')
	{
		my $name      = $edit->{name}            // 'New Route';
		my $coll_uuid = $edit->{collection_uuid} // '';
		my $waypoints = $edit->{waypoints}       // [];
		if (!$coll_uuid || @$waypoints < 2)
		{
			warning(0,0,"winDatabase::onLeafletRouteEdit create: bad payload coll=$coll_uuid wps=" . scalar(@$waypoints));
			disconnectDB($dbh);
			return;
		}
		my $max_pos = _maxCollItemPos($dbh, $coll_uuid);
		my $route_pos = ($max_pos // 0) + 1;
		my $new_uuid = insertRoute($dbh, $name, 0, '', $coll_uuid, $route_pos);
		my $n = scalar @$waypoints;
		for my $i (0 .. $#$waypoints)
		{
			my $wp      = $waypoints->[$i];
			my $wp_pos  = $route_pos + ($i + 1) * 0.001;
			my $wp_uuid = newUUID($dbh);
			my $wp_name = "RNP-" . uc(substr($wp_uuid, 0, 6));
			insertWaypoint($dbh,
				uuid            => $wp_uuid,
				name            => $wp_name,
				lat             => $wp->{lat} + 0,
				lon             => $wp->{lon} + 0,
				wp_type         => $WP_TYPE_NAV,
				color           => 0,
				depth_cm        => 0,
				created_ts      => time(),
				ts_source       => 'nav',
				source          => 'navMate',
				collection_uuid => $coll_uuid,
				position        => $wp_pos);
			appendRouteWaypoint($dbh, $new_uuid, $wp_uuid, $i + 1);
		}
		_pushObjToLeaflet($dbh, $this, { uuid => $new_uuid, obj_type => 'route' }, undef);
		$this->refresh();
	}
	else
	{
		warning(0,0,"winDatabase::onLeafletRouteEdit unknown op '$op' uuid=$uuid");
	}
	disconnectDB($dbh);
}


sub _nextCollItemPos
{
	my ($dbh, $collection_uuid, $after_pos) = @_;
	my $rec = $dbh->get_record(qq{
		SELECT MIN(next_p) AS p FROM (
			SELECT position AS next_p FROM waypoints WHERE collection_uuid=? AND position > ?
			UNION ALL
			SELECT position AS next_p FROM routes    WHERE collection_uuid=? AND position > ?
			UNION ALL
			SELECT position AS next_p FROM tracks    WHERE collection_uuid=? AND position > ?
		) t},
		[$collection_uuid, $after_pos, $collection_uuid, $after_pos, $collection_uuid, $after_pos]);
	return $rec ? $rec->{p} : undef;
}


sub _maxCollItemPos
{
	my ($dbh, $collection_uuid) = @_;
	my $rec = $dbh->get_record(qq{
		SELECT MAX(max_p) AS p FROM (
			SELECT MAX(position) AS max_p FROM waypoints WHERE collection_uuid=?
			UNION ALL
			SELECT MAX(position) AS max_p FROM routes    WHERE collection_uuid=?
			UNION ALL
			SELECT MAX(position) AS max_p FROM tracks    WHERE collection_uuid=?
		) t},
		[$collection_uuid, $collection_uuid, $collection_uuid]);
	return $rec ? $rec->{p} : undef;
}


sub _pushCollectionToLeaflet
{
	my ($dbh, $this, $uuid) = @_;
	my $wrgt = getCollectionWRGTs($dbh, $uuid);
	my @accumulator;
	_pushObjToLeaflet($dbh, $this, { %$_, obj_type => 'waypoint' }, \@accumulator) for @{$wrgt->{waypoints}};
	_pushObjToLeaflet($dbh, $this, { %$_, obj_type => 'route'    }, \@accumulator) for @{$wrgt->{routes}};
	_pushObjToLeaflet($dbh, $this, { %$_, obj_type => 'track'    }, \@accumulator) for @{$wrgt->{tracks}};
	addRenderFeatures(\@accumulator) if @accumulator;
}


sub _pullCollectionFromLeaflet
{
	my ($dbh, $this, $uuid) = @_;
	my $wrgt = getCollectionWRGTs($dbh, $uuid);
	my @accumulator;
	for my $obj (@{$wrgt->{waypoints}}, @{$wrgt->{routes}}, @{$wrgt->{tracks}})
	{
		my $obj_uuid = $obj->{uuid};
		next if !$rendered_uuids{$obj_uuid};
		my @children = ref($rendered_uuids{$obj_uuid}) eq 'ARRAY' ? @{$rendered_uuids{$obj_uuid}} : ();
		push @accumulator, $obj_uuid, @children;
		delete $rendered_uuids{$_} for ($obj_uuid, @children);
	}
	removeRenderFeatures('db', \@accumulator) if @accumulator;
}


#---------------------------------
# leaflet sync entry points
#---------------------------------

sub onObjectsDeleted
{
	my ($this, @uuids) = @_;
	my @remove;
	for my $uuid (@uuids)
	{
		next if !$rendered_uuids{$uuid};
		push @remove, $uuid;
		delete $rendered_uuids{$uuid};
	}
	removeRenderFeatures('db', \@remove) if @remove;
}


sub resyncDbToLeaflet
	# Called after a DB swap (e.g. revert).  Previously-rendered DB UUIDs may
	# now reference rows that no longer exist, so we evict everything this
	# pane pushed and re-publish whatever the post-swap DB currently has
	# marked visible.  Scoped to source 'db' -- must NOT clearRenderMap()
	# because FSH and E80 features in the shared store belong to other panes.
{
	my ($this) = @_;
	removeRenderFeatures('db', [keys %rendered_uuids]) if %rendered_uuids;
	%rendered_uuids = ();
	my $dbh = connectDB();
	my $vis  = getAllVisibleFeatures($dbh);
	my @features;
	for my $w (@{$vis->{waypoints}})
	{
		$rendered_uuids{$w->{uuid}} = 1;
		push @features, {
			type       => 'Feature',
			properties => {
				uuid            => $w->{uuid},
				name            => $w->{name}        // '',
				obj_type        => 'waypoint',
				data_source     => 'db',
				wp_type         => $w->{wp_type}     // 'nav',
				color           => $w->{color},
				depth_cm        => ($w->{depth_cm}    // 0) + 0,
				lat             => ($w->{lat}          // 0) + 0,
				lon             => ($w->{lon}          // 0) + 0,
				comment         => $w->{comment}      // '',
				created_ts      => ($w->{created_ts}   // 0) + 0,
				ts_source       => $w->{ts_source}    // '',
				source          => $w->{source}       // '',
				collection_uuid => $w->{collection_uuid} // '',
			},
			geometry => { type => 'Point', coordinates => [$w->{lon}+0, $w->{lat}+0] },
		};
	}
	for my $r (@{$vis->{routes}})
	{
		my $pts = $r->{waypoints} // [];
		next if !@$pts;
		$rendered_uuids{$r->{uuid}} = 1;
		my @rp_names = map { $_->{name} // '' } @$pts;
		push @features, {
			type       => 'Feature',
			properties => {
				uuid            => $r->{uuid},
				name            => $r->{name}    // '',
				obj_type        => 'route',
				data_source     => 'db',
				color           => $r->{color},
				wp_count        => scalar(@$pts) + 0,
				rp_names        => \@rp_names,
				comment         => $r->{comment} // '',
				collection_uuid => $r->{collection_uuid} // '',
			},
			geometry => { type => 'LineString',
				coordinates => [map { [$_->{lon}+0, $_->{lat}+0] } @$pts] },
		};
	}
	for my $t (@{$vis->{tracks}})
	{
		my $pts = $t->{points} // [];
		next if !@$pts;
		$rendered_uuids{$t->{uuid}} = 1;
		push @features, {
			type       => 'Feature',
			properties => {
				uuid            => $t->{uuid},
				name            => $t->{name}        // '',
				obj_type        => 'track',
				data_source     => 'db',
				color           => $t->{color},
				point_count     => ($t->{point_count} // 0) + 0,
				ts_start        => ($t->{ts_start}    // 0) + 0,
				ts_end          => ($t->{ts_end}      // 0) + 0,
				ts_source       => $t->{ts_source}   // '',
				collection_uuid => $t->{collection_uuid} // '',
			},
			geometry => { type => 'LineString',
				coordinates => [map { [$_->{lon}+0, $_->{lat}+0] } @$pts] },
		};
	}
	disconnectDB($dbh);
	addRenderFeatures(\@features) if @features;
}


sub onClearMap
{
	my ($this) = @_;
	my $dbh = connectDB();
	clearAllVisible($dbh);
	disconnectDB($dbh);
	clearRenderMap();
	$last_clear_version = getClearVersion();
	%rendered_uuids = ();
	$this->refresh();
}

#---------------------------------
# right-click context menu
#---------------------------------

sub _onTreeRightDown
{
	my ($this, $tree, $event) = @_;
	my ($item, $flags) = $tree->HitTest($event->GetPosition());
	if ($item && $item->IsOk())
	{
		$event->Skip();
		return;
	}
	my $root_node = { type => 'root', data => { uuid => undef, name => 'Database' } };
	$this->{_right_click_node} = $root_node;
	$this->{_context_nodes}    = [];
	my $menu = _buildContextMenu($this, $root_node);
	$this->PopupMenu($menu, [-1, -1]);
}


sub onTreeRightClick
{
	my ($this, $event) = @_;
	my $item = $event->GetItem();
	return if !$item->IsOk();
	my $item_data = $this->{tree}->GetItemData($item);
	return if !$item_data;
	my $node = $item_data->GetData();
	return if ref $node ne 'HASH';

	if (!$this->{tree}->IsSelected($item))
	{
		$this->{tree}->UnselectAll();
		$this->{tree}->SelectItem($item, 1);
	}

	$this->{_right_click_node} = $node;
	my $menu = _buildContextMenu($this, $node);
	$this->PopupMenu($menu, [-1,-1]);
}


sub _buildContextMenu
{
	my ($this, $right_click_node) = @_;
	my $tree = $this->{tree};

	my @nodes;
	for my $item ($tree->GetSelections())
	{
		my $d = $tree->GetItemData($item);
		next if !$d;
		my $n = $d->GetData();
		push @nodes, $n if ref $n eq 'HASH';
	}
	$this->{_context_nodes} = \@nodes;

	my $menu      = buildContextMenu('database', $right_click_node, @nodes);
	my $node_type = $right_click_node->{type} // '';

	if ($node_type ne 'root')
	{
		$menu->AppendSeparator() if $menu->GetMenuItemCount() > 0;
		$menu->Append($CTX_CMD_SHOW_MAP, 'Show on Map');
		$menu->Append($CTX_CMD_HIDE_MAP, 'Hide on Map');

		# "Find This..." only for object nodes -- terminal items have
		# geographic identity worth searching for.  Collections, groups,
		# route_points etc. are aggregates or sub-objects and don't
		# stand alone as findable subjects.
		if ($node_type eq 'object')
		{
			$menu->Append($CTX_CMD_FIND_THIS, 'Find This...');
		}

		# Import/Export block.  Separator is unconditional within this branch
		# because Export KML applies to every non-root node, so there is
		# always at least one item below it.  Import KML is restricted to
		# branch collections (not groups, not leaf objects) to keep the
		# "import into container" semantics distinct from paste-before/after.
		$menu->AppendSeparator();
		$menu->Append($CTX_CMD_EXPORT_KML, 'Export KML file (.kml)...');

		my $sub_type = ($right_click_node->{data} // {})->{node_type} // '';
		if ($node_type eq 'collection' && $sub_type eq $NODE_TYPE_BRANCH)
		{
			$menu->Append($CTX_CMD_IMPORT_KML, 'Import KML file (.kml)...');
		}
		if ($node_type eq 'collection')
		{
			my $gbs       = find_gpsbabel();
			my $gps_label = $gbs ? 'Import GPS file (.gpx, .gdb)...' : 'Import GPS file (.gpx)...';
			$menu->Append($CTX_CMD_IMPORT_GPS, $gps_label);
		}
	}

	return $menu;
}


sub _onNmOpsCmd
{
	my ($this, $event) = @_;
	my $cmd_id      = $event->GetId();
	my $right_click = $this->{_right_click_node} // {};
	my @nodes       = @{$this->{_context_nodes} // []};
	onContextMenuCommand($cmd_id, 'database', $right_click, $this->{tree}, @nodes);
	_applyCutStyle($this);
}


sub _onFindThis
	# Extract the right-clicked object's geometry from the DB and open
	# winFind with that as the subject.  Only meaningful for object nodes;
	# the menu-build code already gates this.
{
	my ($this, $event) = @_;
	my $node = $this->{_right_click_node} // {};
	return if ($node->{type} // '') ne 'object';
	my $data     = $node->{data} // {};
	my $uuid     = $data->{uuid};
	my $obj_type = $data->{obj_type};
	return if !$uuid || !$obj_type;

	my $dbh = connectDB();
	return if !$dbh;
	my %args = (
		frame    => $this->{frame},
		source   => 'db',
		uuid     => $uuid,
		obj_type => $obj_type,
		name     => $data->{name} // '',
		hierarchy_path => navDB::getCollectionHierarchyPath($dbh, $data->{collection_uuid}),
	);
	if ($obj_type eq 'waypoint')
	{
		my $w = getWaypoint($dbh, $uuid);
		$args{lat} = $w->{lat} + 0;
		$args{lon} = $w->{lon} + 0;
		$args{bbox} = { min_lat => $args{lat}, max_lat => $args{lat},
		                min_lon => $args{lon}, max_lon => $args{lon} };
		$args{npts} = 1;
	}
	elsif ($obj_type eq 'track')
	{
		my $pts = getTrackPoints($dbh, $uuid) // [];
		$args{points} = $pts;
		$args{npts}   = scalar @$pts;
		$args{bbox}   = navMatch::bboxOfPoints($pts);
	}
	elsif ($obj_type eq 'route')
	{
		my $pts = getRoutePoints($dbh, $uuid) // [];
		$args{points} = $pts;
		$args{npts}   = scalar @$pts;
		$args{bbox}   = navMatch::bboxOfPoints($pts);
	}
	disconnectDB($dbh);

	winFind::openForSubject(%args);
}


sub _onTreeKeyDown
{
	# Ctrl+C / Ctrl+X: gated by getCopyMenuItems / getCutMenuItems (requires non-empty
	# selection with no root nodes).
	#
	# Ctrl+V: requires exactly one node selected.  Command chosen by destination type
	# and whether the clipboard holds a cut or a copy:
	#
	#   destination         cut      copy
	#   root / collection   PASTE    PASTE_NEW
	#   object / rte_point  PASTE_AFTER  PASTE_NEW_AFTER
	#
	# Cut maps to the identity-preserving variant (same UUID, i.e. a move).
	# Copy maps to the fresh-UUID variant (true duplication within the DB).
	# In both cases the chosen command is confirmed against getPasteMenuItems before
	# dispatch, so the same enable/disable logic as the context menu applies.

	my ($this, $tree, $event) = @_;
	if ($event->ControlDown())
	{
		my $key = $event->GetKeyCode();
		if ($key == ord('C') || $key == ord('X') || $key == ord('V'))
		{
			my @nodes;
			for my $item ($tree->GetSelections())
			{
				my $d = $tree->GetItemData($item);
				next if !$d;
				my $n = $d->GetData();
				push @nodes, $n if ref $n eq 'HASH';
			}
			my $right_click_node = @nodes ? $nodes[0] : {};

			my $cmd_id;
			if ($key == ord('C'))
			{
				$cmd_id = $CTX_CMD_COPY
					if navClipboard::getCopyMenuItems('database', @nodes);
			}
			elsif ($key == ord('X'))
			{
				$cmd_id = $CTX_CMD_CUT
					if navClipboard::getCutMenuItems('database', @nodes);
			}
			elsif (scalar(@nodes) == 1)
			{
				my $t    = $right_click_node->{type} // '';
				my $cut  = $navClipboard::clipboard ? ($navClipboard::clipboard->{cut_flag} // 0) : 0;
				my $want = ($t eq 'root' || $t eq 'collection')
				         ? ($cut ? $CTX_CMD_PASTE       : $CTX_CMD_PASTE_NEW)
				         : ($cut ? $CTX_CMD_PASTE_AFTER : $CTX_CMD_PASTE_NEW_AFTER);
				my @paste = navClipboard::getPasteMenuItems('database', $right_click_node);
				$cmd_id = $want if grep { $_->{id} == $want } @paste;
			}

			if ($cmd_id)
			{
				$this->{_right_click_node} = $right_click_node;
				$this->{_context_nodes}    = \@nodes;
				onContextMenuCommand($cmd_id, 'database', $right_click_node, $tree, @nodes);
				_applyCutStyle($this);
			}
			return;
		}
	}
	$event->Skip();
}


#---------------------------------
# cut-item grey styling
#---------------------------------

sub _applyCutStyle
{
	my ($this) = @_;
	$CUT_COLOR //= Wx::Colour->new(160, 160, 160);
	my $cb = $navClipboard::clipboard;
	my %cut;
	if ($cb && $cb->{cut_flag} && ($cb->{source} // '') eq 'database')
	{
		%cut = map { ($_->{uuid} // '') => 1 }
		       grep { $_->{uuid} } @{$cb->{items} // []};
	}
	my $tree = $this->{tree};
	my $root = $tree->GetRootItem();
	_applyStyleWalk($tree, $root, \%cut) if $root && $root->IsOk();
}

sub _applyStyleWalk
{
	my ($tree, $item, $cut) = @_;
	my $d = $tree->GetItemData($item);
	if ($d)
	{
		my $node = $d->GetData();
		if (ref $node eq 'HASH')
		{
			my $uuid = ($node->{type} // '') eq 'route_point'
			         ? ($node->{uuid} // '')
			         : (($node->{data} // {})->{uuid} // '');
			$tree->SetItemTextColour($item,
				($uuid && $cut->{$uuid}) ? $CUT_COLOR : wxNullColour);
		}
	}
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		_applyStyleWalk($tree, $child, $cut);
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
}


sub _onDelete
{
	my ($this, $event) = @_;
	my @nodes     = @{$this->{_context_nodes} // []};
	my @deletable = grep { my $t = $_->{type} // ''; $t eq 'object' || $t eq 'collection' } @nodes;
	return if !@deletable;

	my $n   = scalar @deletable;
	my $msg = $n == 1
		? "Delete '$deletable[0]{data}{name}'?"
		: "Delete $n items?";
	return if !confirmDialog($this->{tree}, $msg, 'Confirm Delete');

	my $dbh = connectDB();
	return if !$dbh;

	my @obj_uuids;
	for my $node (@deletable)
	{
		my $uuid     = $node->{data}{uuid};
		my $type     = $node->{type};
		my $obj_type = $node->{data}{obj_type} // '';
		if ($type eq 'collection')
		{
			if (!isBranchDeleteSafe($dbh, $uuid))
			{
				warning(0, 0, "Cannot delete '$node->{data}{name}': waypoints are referenced by external routes");
				next;
			}
			my $wrgt = getCollectionWRGTs($dbh, $uuid);
			push @obj_uuids, map { $_->{uuid} }
				@{$wrgt->{waypoints}}, @{$wrgt->{routes}}, @{$wrgt->{tracks}};
			deleteBranch($dbh, $uuid);
		}
		elsif ($obj_type eq 'waypoint') { push @obj_uuids, $uuid; deleteWaypoint($dbh, $uuid) }
		elsif ($obj_type eq 'route')    { push @obj_uuids, $uuid; deleteRoute($dbh, $uuid)    }
		elsif ($obj_type eq 'track')    { push @obj_uuids, $uuid; deleteTrack($dbh, $uuid)    }
	}

	disconnectDB($dbh);
	$this->onObjectsDeleted(@obj_uuids) if @obj_uuids;
	$this->refresh();
}

#---------------------------------
# Import / export + new branch / group
#---------------------------------

sub _onImportGPS
{
	my ($this, $event) = @_;
	my $coll_uuid = ($this->{_right_click_node}{data} // {})->{uuid};
	return unless $coll_uuid;

	my $gbs     = find_gpsbabel();
	my $wildcard = $gbs
		? 'GPS files (*.gpx;*.gdb)|*.gpx;*.gdb|GPX files (*.gpx)|*.gpx|All files (*.*)|*.*'
		: 'GPX files (*.gpx)|*.gpx|All files (*.*)|*.*';

	my $dlg = Wx::FileDialog->new($this, 'Import GPS file', '', '', $wildcard, wxFD_OPEN | wxFD_FILE_MUST_EXIST);
	if ($dlg->ShowModal() != wxID_OK)
	{
		$dlg->Destroy();
		return;
	}
	my $path = $dlg->GetPath();
	$dlg->Destroy();
	return unless $path;

	my $dbh    = connectDB();
	my $result = import_gps_file($dbh, $path, $coll_uuid);
	disconnectDB($dbh);

	if ($result->{error})
	{
		Wx::MessageBox($result->{error}, 'Import failed', wxOK | wxICON_ERROR, $this);
		return;
	}

	my $msg = "Imported from " . (split /[\/\\]/, $path)[-1] . ":\n"
		. "  Tracks:    $result->{tracks}\n"
		. "  Waypoints: $result->{waypoints}\n"
		. "  Routes:    $result->{routes}";
	Wx::MessageBox($msg, 'Import complete', wxOK | wxICON_INFORMATION, $this);
	$this->refresh();
}


sub _onImportKML
{
	my ($this, $event) = @_;
	my $target_uuid = ($this->{_right_click_node}{data} // {})->{uuid};
	return if !$target_uuid;

	my $default_dir = readConfig('kml_dir') || '';
	my $dlg = Wx::FileDialog->new($this, 'Import KML file', $default_dir, '',
		'KML files (*.kml)|*.kml|All files (*.*)|*.*',
		wxFD_OPEN | wxFD_FILE_MUST_EXIST);
	if ($dlg->ShowModal() != wxID_OK)
	{
		$dlg->Destroy();
		return;
	}
	my $path = $dlg->GetPath();
	writeConfig('kml_dir', $dlg->GetDirectory());
	$dlg->Destroy();
	return if !$path;

	eval { navKML::importKMLSubtree($path, $target_uuid) };
	if ($@)
	{
		Wx::MessageBox("Import KML failed: $@", 'Import failed', wxOK | wxICON_ERROR, $this);
		return;
	}
	$this->refresh();
}


sub _onExportKML
{
	my ($this, $event) = @_;
	my $node = $this->{_right_click_node} // {};
	my $type = $node->{type} // '';
	my $uuid = ($type eq 'route_point') ? $node->{uuid} : ($node->{data} // {})->{uuid};
	return if !$uuid;

	my $name = ($node->{data} // {})->{name} // '';
	$name =~ s/[^\w\-]+/_/g;
	$name = 'navMate' if $name eq '';

	my $default_dir = readConfig('kml_dir') || '';
	my $dlg = Wx::FileDialog->new($this, 'Export KML', $default_dir, "$name.kml",
		'KML files (*.kml)|*.kml|All files (*.*)|*.*',
		wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
	if ($dlg->ShowModal() != wxID_OK)
	{
		$dlg->Destroy();
		return;
	}
	my $path = $dlg->GetPath();
	writeConfig('kml_dir', $dlg->GetDirectory());
	$dlg->Destroy();
	return if !$path;

	eval { navKML::exportKMLSubtree($path, $uuid) };
	if ($@)
	{
		Wx::MessageBox("Export KML failed: $@", 'Export failed', wxOK | wxICON_ERROR, $this);
	}
}


sub _onNewBranch
{
	my ($this, $event) = @_;
	my $parent_uuid = ($this->{_right_click_node}{data} // {})->{uuid};
	my $dlg = Wx::TextEntryDialog->new($this, 'Branch name:', 'New Branch', '');
	if ($dlg->ShowModal() == wxID_OK)
	{
		my $name = $dlg->GetValue() // '';
		if ($name ne '')
		{
			my $dbh = connectDB();
			my @new_pos = computePushDownPositions($dbh, $parent_uuid, 1);
			insertCollection($dbh, $name, $parent_uuid, $NODE_TYPE_BRANCH, '', $new_pos[0]);
			disconnectDB($dbh);
			$this->refresh();
		}
	}
	$dlg->Destroy();
}


sub _onNewGroup
{
	my ($this, $event) = @_;
	my $parent_uuid = ($this->{_right_click_node}{data} // {})->{uuid};
	my $dlg = Wx::TextEntryDialog->new($this, 'Group name:', 'New Group', '');
	if ($dlg->ShowModal() == wxID_OK)
	{
		my $name = $dlg->GetValue() // '';
		if ($name ne '')
		{
			my $dbh = connectDB();
			my @new_pos = computePushDownPositions($dbh, $parent_uuid, 1);
			insertCollection($dbh, $name, $parent_uuid, $NODE_TYPE_GROUP, '', $new_pos[0]);
			disconnectDB($dbh);
			$this->refresh();
		}
	}
	$dlg->Destroy();
}

#---------------------------------
# Show/hide map menu
#---------------------------------

sub _onTreeActivated
{
	my ($this, $event) = @_;
	_onShowHideMap($this, 1);
}


sub _onShowMap
{
	my ($this, $event) = @_;
	_onShowHideMap($this, 1);
}


sub _onHideMap
{
	my ($this, $event) = @_;
	_onShowHideMap($this, 0);
}


sub _onShowHideMap
	# Wrapped with navVisibility::begin/endVisibilityBatch so that multi-
	# select Show/Hide-on-Map fires one observer notification with a complete
	# delta across both the case1 collection loop and the leaf-node loop.
	# Other DB pane instances and winFind see one update event total.
{
	my ($this, $new_visible) = @_;
	my ($case1_colls, $case2_colls, $leaf_nodes) = _analyzeShowHideSelection($this);
	return if !@$case1_colls && !@$case2_colls && !@$leaf_nodes;

	my $dbh = connectDB();
	return if !$dbh;

	navVisibility::beginVisibilityBatch();
	eval {

	for my $entry (@$case1_colls)
	{
		my $uuid = $entry->{node}{data}{uuid};
		my $item = $entry->{item};
		setCollectionVisibleRecursive($dbh, $uuid, $new_visible);
		$this->{tree}->SetItemState($item, $new_visible ? 1 : 0);
		_refreshLoadedSubtree($this, $item, $new_visible);
		if ($new_visible) { _pushCollectionToLeaflet($dbh, $this, $uuid) }
		else              { _pullCollectionFromLeaflet($dbh, $this, $uuid) }
	}

	for my $entry (@$leaf_nodes)
	{
		my $node     = $entry->{node};
		my $item     = $entry->{item};
		my $uuid     = $node->{type} eq 'route_point' ? $node->{uuid}           : $node->{data}{uuid};
		my $obj_type = $node->{type} eq 'route_point' ? 'waypoint'              : $node->{data}{obj_type};
		setTerminalVisible($dbh, $uuid, $obj_type, $new_visible);
		$this->{tree}->SetItemState($item, $new_visible ? 1 : 0);
		$node->{data}{visible} = $new_visible if $node->{type} eq 'object';
		if ($new_visible) { _pushObjToLeaflet($dbh, $this, { uuid => $uuid, obj_type => $obj_type }) }
		else              { _pullFromLeaflet($this, $uuid) }
	}

	};
	my $err = $@;
	navVisibility::endVisibilityBatch();
	error("_onShowHideMap: $err") if $err;
	return if $err;

	for my $entry (@$case2_colls)
	{
		my $vs = getCollectionVisibleState($dbh, $entry->{node}{data}{uuid});
		$this->{tree}->SetItemState($entry->{item}, $vs);
	}

	_refreshAncestorStates($dbh, $this, $_->{item})
		for (@$case1_colls, @$case2_colls, @$leaf_nodes);

	my $edit_uuid = $this->{_edit_uuid} // '';
	if ($edit_uuid)
	{
		for my $entry (@$case1_colls, @$leaf_nodes)
		{
			my $node = $entry->{node};
			my $uuid = $node->{type} eq 'route_point'
				? ($node->{uuid} // '')
				: (($node->{data} // {})->{uuid} // '');
			next if $uuid ne $edit_uuid;
			if (($this->{_edit_type} // '') eq 'collection')
			{
				my $vs = getCollectionVisibleState($dbh, $edit_uuid);
				$this->{ed_visible}->Set3StateValue(
					$vs == 1 ? wxCHK_CHECKED :
					$vs == 2 ? wxCHK_UNDETERMINED :
					           wxCHK_UNCHECKED);
			}
			else
			{
				$this->{ed_visible}->Set3StateValue(
					$new_visible ? wxCHK_CHECKED : wxCHK_UNCHECKED);
			}
			last;
		}
	}

	disconnectDB($dbh);
	openMapBrowser() if $new_visible && !isBrowserConnected();
}


sub _analyzeShowHideSelection
{
	my ($this) = @_;
	my $tree = $this->{tree};

	my %sel_uuids;
	my @all_entries;
	for my $item ($tree->GetSelections())
	{
		my $d = $tree->GetItemData($item);
		next if !$d;
		my $node = $d->GetData();
		next if ref $node ne 'HASH';
		my $type = $node->{type} // '';
		next if $type eq 'root';
		my $uuid = $type eq 'route_point'
			? ($node->{uuid} // '')
			: (($node->{data} // {})->{uuid} // '');
		next if !$uuid;
		$sel_uuids{$uuid} = 1;
		push @all_entries, { node => $node, item => $item, uuid => $uuid };
	}

	my (@case1_colls, @case2_colls, @leaf_nodes);
	for my $entry (@all_entries)
	{
		if (($entry->{node}{type} // '') eq 'collection')
		{
			if (_hasSelectedDescendant($tree, $entry->{item}, \%sel_uuids))
			{
				push @case2_colls, $entry;
			}
			else
			{
				push @case1_colls, $entry;
			}
		}
		else
		{
			push @leaf_nodes, $entry;
		}
	}

	return (\@case1_colls, \@case2_colls, \@leaf_nodes);
}


sub _hasSelectedDescendant
{
	my ($tree, $item, $sel_uuids) = @_;
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		my $d = $tree->GetItemData($child);
		if ($d)
		{
			my $node = $d->GetData();
			if (ref $node eq 'HASH')
			{
				my $type = $node->{type} // '';
				my $uuid = $type eq 'route_point'
					? ($node->{uuid} // '')
					: (($node->{data} // {})->{uuid} // '');
				return 1 if $uuid && $sel_uuids->{$uuid};
				return 1 if _hasSelectedDescendant($tree, $child, $sel_uuids);
			}
		}
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
	return 0;
}

1;
