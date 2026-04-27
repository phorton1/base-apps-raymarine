#!/usr/bin/perl
#-------------------------------------------------------------------------
# winBrowser.pm
#-------------------------------------------------------------------------
# Two-pane window: collection tree (left), detail text (right).
#
# Tree is loaded lazily: top-level collections appear on open; a dummy
# child is added to any node that has children so the expander arrow
# shows.  EVT_TREE_ITEM_EXPANDING fires the real load.  Leaf objects
# (waypoints, routes, tracks) appear under their containing collection.
#
# Detail pane: branch nodes show child counts; leaf nodes show
# type-specific fields.

package winBrowser;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_TREE_SEL_CHANGED
	EVT_TREE_ITEM_EXPANDING
	EVT_TREE_ITEM_RIGHT_CLICK
	EVT_LEFT_DCLICK
	EVT_MENU);
use POSIX qw(strftime);
use Pub::Utils qw(display warning error);
use Pub::WX::Window;
use Pub::WX::Menu;
use c_db;
use nmServer;
use nmUpload;
use w_resources;
use base qw(Wx::SplitterWindow Pub::WX::Window);

my $DUMMY = '__dummy__';

my %rendered_uuids;
my $last_clear_version = 0;


sub new
{
	my ($class, $frame, $book, $id, $data) = @_;
	my $this = $class->SUPER::new($book, $id);
	$this->MyWindow($frame, $book, $id, 'Browser', $data);

	$this->{tree} = Wx::TreeCtrl->new($this, -1, wxDefaultPosition, wxDefaultSize,
		wxTR_DEFAULT_STYLE | wxTR_HIDE_ROOT);

	$this->{detail} = Wx::TextCtrl->new($this, -1, '', wxDefaultPosition, wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY);

	my $font = Wx::Font->new(9, wxFONTFAMILY_MODERN, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL);
	$this->{detail}->SetFont($font);

	my $sash = ($data && ref($data) eq 'HASH' && $data->{sash}) ? $data->{sash} : 0;
	$this->SplitVertically($this->{tree}, $this->{detail}, $sash);
	$this->SetSashGravity(0.5);

	_loadTopLevel($this);

	EVT_TREE_SEL_CHANGED($this,        $this->{tree}, \&onTreeSelect);
	EVT_TREE_ITEM_EXPANDING($this,     $this->{tree}, \&onTreeExpanding);
	EVT_TREE_ITEM_RIGHT_CLICK($this,   $this->{tree}, \&onTreeRightClick);
	EVT_LEFT_DCLICK($this->{tree}, sub { _onTreeDblClick($this, @_) });

	EVT_MENU($this, $CMD_UPLOAD_E80, \&_onUploadE80);

	return $this;
}


#---------------------------------
# initial load — top-level only
#---------------------------------

sub _loadTopLevel
{
	my ($this) = @_;
	my $tree = $this->{tree};
	$tree->Freeze();
	$tree->DeleteAllItems();
	my $root = $tree->AddRoot('root');

	my $dbh = connectDB();
	unless ($dbh) { $tree->Thaw(); return; }
	my $top_colls = getCollectionChildren($dbh, undef);
	for my $coll (@$top_colls)
	{
		_addCollectionItem($dbh, $this, $root, $coll);
	}
	disconnectDB($dbh);
	$tree->Thaw();
}


sub refresh
{
	my ($this) = @_;
	$this->{detail}->SetValue('');
	_loadTopLevel($this);
}


#---------------------------------
# helpers
#---------------------------------

sub _collectionLabel
{
	my ($coll, $counts) = @_;
	my $name = $coll->{name};
	my ($nc, $nw, $nr, $nt) = @{$counts}{qw(collections waypoints routes tracks)};
	my $total = $nc + $nw + $nr + $nt;
	return "$name (empty)" unless $total;
	my @parts;
	push @parts, "$nc " . ($nc==1 ? 'folder'   : 'folders')   if $nc;
	push @parts, "$nw " . ($nw==1 ? 'waypoint' : 'waypoints') if $nw;
	push @parts, "$nr " . ($nr==1 ? 'route'    : 'routes')    if $nr;
	push @parts, "$nt " . ($nt==1 ? 'track'    : 'tracks')    if $nt;
	return "$name (" . join(', ', @parts) . ")";
}


sub _addCollectionItem
{
	my ($dbh, $this, $parent, $coll) = @_;
	my $tree   = $this->{tree};
	my $counts = getCollectionCounts($dbh, $coll->{uuid});
	my $label  = _collectionLabel($coll, $counts);

	my $item = $tree->AppendItem($parent, $label, -1, -1,
		Wx::TreeItemData->new({ type => 'collection', data => $coll }));

	my $total = $counts->{collections} + $counts->{waypoints}
	          + $counts->{routes}      + $counts->{tracks};
	$tree->AppendItem($item, $DUMMY) if $total;

	return $item;
}


sub _addObjectItem
{
	my ($dbh, $this, $parent, $obj) = @_;
	my $label;
	if ($obj->{obj_type} eq 'route')
	{
		my $n = getRouteWaypointCount($dbh, $obj->{uuid});
		$label = "$obj->{name} ($n pts)";
	}
	elsif ($obj->{obj_type} eq 'track')
	{
		my $n = $obj->{point_count} // 0;
		$label = "[track] $obj->{name} ($n pts)";
	}
	else
	{
		$label = "[waypoint] $obj->{name}";
	}
	$this->{tree}->AppendItem($parent, $label, -1, -1,
		Wx::TreeItemData->new({ type => 'object', data => $obj }));
}


#---------------------------------
# lazy expand
#---------------------------------

sub onTreeExpanding
{
	my ($this, $event) = @_;
	my $item = $event->GetItem();
	my $tree = $this->{tree};

	my ($first, $cookie) = $tree->GetFirstChild($item);
	return unless $first && $first->IsOk();
	return unless ($tree->GetItemText($first) // '') eq $DUMMY;

	$tree->Delete($first);

	my $item_data = $tree->GetItemData($item);
	return unless $item_data;
	my $node = $item_data->GetData();
	return unless ref $node eq 'HASH' && $node->{type} eq 'collection';

	my $dbh = connectDB();
	_populateNode($dbh, $this, $item, $node->{data});
	disconnectDB($dbh);
}


sub _populateNode
{
	my ($dbh, $this, $parent_item, $coll) = @_;
	my $coll_uuid = $coll->{uuid};

	my $children = getCollectionChildren($dbh, $coll_uuid);
	for my $child (@$children)
	{
		_addCollectionItem($dbh, $this, $parent_item, $child);
	}

	my $objects = getCollectionObjects($dbh, $coll_uuid);
	for my $obj (@$objects)
	{
		_addObjectItem($dbh, $this, $parent_item, $obj);
	}
}


#---------------------------------
# selection → detail
#---------------------------------

sub onTreeSelect
{
	my ($this, $event) = @_;
	my $item = $event->GetItem();
	return unless $item->IsOk();
	my $item_data = $this->{tree}->GetItemData($item);
	return unless $item_data;
	my $node = $item_data->GetData();
	return unless ref $node eq 'HASH';

	my $dbh = connectDB();
	if ($node->{type} eq 'collection')
	{
		_showCollection($dbh, $this, $node->{data});
	}
	elsif ($node->{type} eq 'object')
	{
		_showObject($dbh, $this, $node->{data});
	}
	disconnectDB($dbh);
}


sub _fmt
{
	my ($label, $value) = @_;
	return sprintf("%-18s%s\n", "$label:", $value // '');
}


sub _showCollection
{
	my ($dbh, $this, $coll_stub) = @_;
	my $coll   = getCollection($dbh, $coll_stub->{uuid});
	my $counts = getCollectionCounts($dbh, $coll->{uuid});
	my $text   = '';
	$text .= _fmt('uuid',        $coll->{uuid});
	$text .= _fmt('name',        $coll->{name});
	$text .= _fmt('node_type',   $coll->{node_type});
	$text .= _fmt('parent_uuid', $coll->{parent_uuid});
	$text .= _fmt('comment',     $coll->{comment});
	$text .= "\n";
	$text .= _fmt('collections', $counts->{collections});
	$text .= _fmt('waypoints',   $counts->{waypoints});
	$text .= _fmt('routes',      $counts->{routes});
	$text .= _fmt('tracks',      $counts->{tracks});
	$this->{detail}->SetValue($text);
}


sub _showObject
{
	my ($dbh, $this, $obj_stub) = @_;
	my $text = '';

	if ($obj_stub->{obj_type} eq 'track')
	{
		my $t = getTrack($dbh, $obj_stub->{uuid});
		my $ts_start = $t->{ts_start}
			? strftime("%Y-%m-%d %H:%M UTC", gmtime($t->{ts_start}))
			: '(none)';
		my $ts_end = $t->{ts_end}
			? strftime("%Y-%m-%d %H:%M UTC", gmtime($t->{ts_end}))
			: '(none)';
		$text .= _fmt('uuid',            $t->{uuid});
		$text .= _fmt('name',            $t->{name});
		$text .= _fmt('color',           $t->{color});
		$text .= _fmt('ts_start',        $ts_start);
		$text .= _fmt('ts_end',          $ts_end);
		$text .= _fmt('ts_source',       $t->{ts_source});
		$text .= _fmt('point_count',     $t->{point_count});
		$text .= _fmt('collection_uuid', $t->{collection_uuid});
	}
	elsif ($obj_stub->{obj_type} eq 'waypoint')
	{
		my $w = getWaypoint($dbh, $obj_stub->{uuid});
		my $ts = $w->{created_ts}
			? strftime("%Y-%m-%d %H:%M UTC", gmtime($w->{created_ts}))
			: '(none)';
		$text .= _fmt('uuid',            $w->{uuid});
		$text .= _fmt('name',            $w->{name});
		$text .= _fmt('comment',         $w->{comment});
		$text .= _fmt('lat',             sprintf("%.6f", $w->{lat}));
		$text .= _fmt('lon',             sprintf("%.6f", $w->{lon}));
		$text .= _fmt('wp_type',         $w->{wp_type});
		$text .= _fmt('color',           $w->{color});
		$text .= _fmt('sym',             $w->{sym});
		$text .= _fmt('depth_cm',        $w->{depth_cm});
		$text .= _fmt('created_ts',      $ts);
		$text .= _fmt('ts_source',       $w->{ts_source});
		$text .= _fmt('source',          $w->{source});
		$text .= _fmt('collection_uuid', $w->{collection_uuid});
	}
	elsif ($obj_stub->{obj_type} eq 'route')
	{
		my $r   = getRoute($dbh, $obj_stub->{uuid});
		my $wps = getRouteWaypoints($dbh, $r->{uuid});
		$text .= _fmt('uuid',            $r->{uuid});
		$text .= _fmt('name',            $r->{name});
		$text .= _fmt('comment',         $r->{comment});
		$text .= _fmt('color',           $r->{color});
		$text .= _fmt('collection_uuid', $r->{collection_uuid});
		$text .= "\n";
		for my $i (0 .. $#$wps)
		{
			$text .= sprintf("  %2d. %-24s  %.5f, %.5f\n",
				$i + 1, $wps->[$i]{name} // '', $wps->[$i]{lat}, $wps->[$i]{lon});
		}
	}

	$this->{detail}->SetValue($text);
}


#---------------------------------
# double-click → render in Leaflet
#---------------------------------
# Single click on +/- expands/collapses as normal.
# Double-click on item label sends that collection to the map.
# NOT calling $event->Skip() suppresses the default expand/collapse.

sub _onTreeDblClick
{
	my ($this, $tree, $event) = @_;
	my $pt = $event->GetPosition();
	my ($item, $flags) = $tree->HitTest($pt);

	unless ($item && $item->IsOk() && ($flags & wxTREE_HITTEST_ONITEMLABEL))
	{
		$event->Skip();
		return;
	}

	my $item_data = $tree->GetItemData($item);
	return unless $item_data;
	my $node = $item_data->GetData();
	return unless ref $node eq 'HASH';

	my $dbh = connectDB();
	if ($node->{type} eq 'collection')
	{
		_renderCollection($dbh, $this, $node->{data}{uuid});
	}
	elsif ($node->{type} eq 'object')
	{
		_renderObject($dbh, $this, $node->{data});
	}
	disconnectDB($dbh);
}


sub _renderCollection
{
	my ($dbh, $this, $uuid) = @_;

	my $cv = getClearVersion();
	if ($cv != $last_clear_version)
	{
		%rendered_uuids    = ();
		$last_clear_version = $cv;
	}

	my $wrgt = getCollectionWRGTs($dbh, $uuid);
	my @features;

	for my $wp (@{$wrgt->{waypoints}})
	{
		next if $rendered_uuids{$wp->{uuid}};
		$rendered_uuids{$wp->{uuid}} = 1;
		push @features, {
			type       => 'Feature',
			properties => {
				uuid            => $wp->{uuid},
				name            => $wp->{name} // '',
				obj_type        => 'waypoint',
				wp_type         => $wp->{wp_type} // 'nav',
				color           => $wp->{color},
				depth_cm        => ($wp->{depth_cm}   // 0) + 0,
				sym             => ($wp->{sym}         // 0) + 0,
				lat             => ($wp->{lat}         // 0) + 0,
				lon             => ($wp->{lon}         // 0) + 0,
				comment         => $wp->{comment}      // '',
				created_ts      => ($wp->{created_ts}  // 0) + 0,
				ts_source       => $wp->{ts_source}    // '',
				source          => $wp->{source}       // '',
				collection_uuid => $wp->{collection_uuid} // '',
			},
			geometry => {
				type        => 'Point',
				coordinates => [$wp->{lon} + 0, $wp->{lat} + 0],
			},
		};
	}

	for my $t (@{$wrgt->{tracks}})
	{
		next if $rendered_uuids{$t->{uuid}};
		my $pts = getTrackPoints($dbh, $t->{uuid});
		next unless @$pts;
		$rendered_uuids{$t->{uuid}} = 1;
		my @coords = map { [$_->{lon} + 0, $_->{lat} + 0] } @$pts;
		push @features, {
			type       => 'Feature',
			properties => {
				uuid            => $t->{uuid},
				name            => $t->{name} // '',
				obj_type        => 'track',
				color           => ($t->{color}       // 0) + 0,
				point_count     => ($t->{point_count} // 0) + 0,
				ts_start        => ($t->{ts_start}    // 0) + 0,
				ts_end          => ($t->{ts_end}      // 0) + 0,
				ts_source       => $t->{ts_source}    // '',
				collection_uuid => $t->{collection_uuid} // '',
			},
			geometry => {
				type        => 'LineString',
				coordinates => \@coords,
			},
		};
	}

	for my $r (@{$wrgt->{routes}})
	{
		next if $rendered_uuids{$r->{uuid}};
		my $pts = getRouteWaypoints($dbh, $r->{uuid});
		next unless @$pts;
		$rendered_uuids{$r->{uuid}} = 1;
		my @coords   = map { [$_->{lon} + 0, $_->{lat} + 0] } @$pts;
		my @rp_names = map { $_->{name} // '' } @$pts;
		push @features, {
			type       => 'Feature',
			properties => {
				uuid            => $r->{uuid},
				name            => $r->{name} // '',
				obj_type        => 'route',
				color           => ($r->{color} // 0) + 0,
				wp_count        => scalar(@$pts) + 0,
				rp_names        => \@rp_names,
				comment         => $r->{comment} // '',
				collection_uuid => $r->{collection_uuid} // '',
			},
			geometry => {
				type        => 'LineString',
				coordinates => \@coords,
			},
		};
	}

	addRenderFeatures(\@features) if @features;

	openMapBrowser() unless isBrowserConnected();
}


sub _renderObject
{
	my ($dbh, $this, $obj) = @_;

	my $cv = getClearVersion();
	if ($cv != $last_clear_version)
	{
		%rendered_uuids    = ();
		$last_clear_version = $cv;
	}

	return if $rendered_uuids{$obj->{uuid}};

	my @features;

	if ($obj->{obj_type} eq 'waypoint')
	{
		my $w = getWaypoint($dbh, $obj->{uuid});
		return unless $w;
		$rendered_uuids{$w->{uuid}} = 1;
		push @features, {
			type       => 'Feature',
			properties => {
				uuid            => $w->{uuid},
				name            => $w->{name} // '',
				obj_type        => 'waypoint',
				wp_type         => $w->{wp_type}  // 'nav',
				color           => $w->{color},
				depth_cm        => ($w->{depth_cm}   // 0) + 0,
				sym             => ($w->{sym}         // 0) + 0,
				lat             => ($w->{lat}         // 0) + 0,
				lon             => ($w->{lon}         // 0) + 0,
				comment         => $w->{comment}      // '',
				created_ts      => ($w->{created_ts}  // 0) + 0,
				ts_source       => $w->{ts_source}    // '',
				source          => $w->{source}       // '',
				collection_uuid => $w->{collection_uuid} // '',
			},
			geometry => {
				type        => 'Point',
				coordinates => [$w->{lon} + 0, $w->{lat} + 0],
			},
		};
	}
	elsif ($obj->{obj_type} eq 'track')
	{
		my $t   = getTrack($dbh, $obj->{uuid});
		my $pts = getTrackPoints($dbh, $obj->{uuid});
		if ($t && @$pts)
		{
			$rendered_uuids{$t->{uuid}} = 1;
			my @coords = map { [$_->{lon} + 0, $_->{lat} + 0] } @$pts;
			push @features, {
				type       => 'Feature',
				properties => {
					uuid            => $t->{uuid},
					name            => $t->{name} // '',
					obj_type        => 'track',
					color           => ($t->{color}       // 0) + 0,
					point_count     => ($t->{point_count} // 0) + 0,
					ts_start        => ($t->{ts_start}    // 0) + 0,
					ts_end          => ($t->{ts_end}      // 0) + 0,
					ts_source       => $t->{ts_source}    // '',
						collection_uuid => $t->{collection_uuid} // '',
				},
				geometry => {
					type        => 'LineString',
					coordinates => \@coords,
				},
			};
		}
	}
	elsif ($obj->{obj_type} eq 'route')
	{
		my $r   = getRoute($dbh, $obj->{uuid});
		my $pts = getRouteWaypoints($dbh, $obj->{uuid});
		if ($r && @$pts)
		{
			$rendered_uuids{$r->{uuid}} = 1;
			my @coords   = map { [$_->{lon} + 0, $_->{lat} + 0] } @$pts;
			my @rp_names = map { $_->{name} // '' } @$pts;
			push @features, {
				type       => 'Feature',
				properties => {
					uuid            => $r->{uuid},
					name            => $r->{name} // '',
					obj_type        => 'route',
					color           => ($r->{color} // 0) + 0,
					wp_count        => scalar(@$pts) + 0,
					rp_names        => \@rp_names,
					comment         => $r->{comment} // '',
					collection_uuid => $r->{collection_uuid} // '',
				},
				geometry => {
					type        => 'LineString',
					coordinates => \@coords,
				},
			};
		}
	}

	addRenderFeatures(\@features) if @features;

	openMapBrowser() unless isBrowserConnected();
}


#---------------------------------
# right-click context menu
#---------------------------------

sub onTreeRightClick
{
	my ($this, $event) = @_;
	my $item = $event->GetItem();
	return unless $item->IsOk();
	my $item_data = $this->{tree}->GetItemData($item);
	return unless $item_data;
	my $node = $item_data->GetData();
	return unless ref $node eq 'HASH';
	return unless isWPMGRConnected();

	my $type = $node->{type};
	my $data = $node->{data};

	if ($type eq 'collection')
	{
		$this->{_upload_target} = { kind => 'collection', data => $data };
	}
	elsif ($type eq 'object' && $data->{obj_type} eq 'route')
	{
		$this->{_upload_target} = { kind => 'route', data => $data };
	}
	elsif ($type eq 'object' && $data->{obj_type} eq 'waypoint')
	{
		$this->{_upload_target} = { kind => 'waypoint', data => $data };
	}
	else
	{
		return;
	}

	my $menu = Pub::WX::Menu::createMenu('collection_context_menu');
	$this->PopupMenu($menu, [-1,-1]);
}


sub _onUploadE80
{
	my ($this) = @_;
	my $target = $this->{_upload_target};
	return unless $target;
	my $kind = $target->{kind};
	my $data = $target->{data};

	if ($kind eq 'collection')
	{
		uploadCollectionToE80($data->{uuid}, $data->{name});
	}
	elsif ($kind eq 'route')
	{
		uploadRouteToE80($data->{uuid}, $data->{name}, $data->{color});
	}
	elsif ($kind eq 'waypoint')
	{
		uploadWaypointToE80($data);
	}
}


#---------------------------------
# ini persistence
#---------------------------------

sub getDataForIniFile
{
	my ($this) = @_;
	return { sash => $this->GetSashPosition() };
}


1;
