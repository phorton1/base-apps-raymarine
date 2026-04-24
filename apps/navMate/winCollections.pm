#!/usr/bin/perl
#-------------------------------------------------------------------------
# winCollections.pm
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

package winCollections;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_TREE_SEL_CHANGED
	EVT_TREE_ITEM_EXPANDING);
use POSIX qw(strftime);
use Pub::Utils qw(display warning error);
use Pub::WX::Window;
use c_db;
use w_resources;
use base qw(Wx::SplitterWindow Pub::WX::Window);

my $DUMMY = '__dummy__';


sub new
{
	my ($class, $frame, $book, $id, $data) = @_;
	my $this = $class->SUPER::new($book, $id);
	$this->MyWindow($frame, $book, $id, 'Collections', $data);

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

	EVT_TREE_SEL_CHANGED($this,   $this->{tree}, \&onTreeSelect);
	EVT_TREE_ITEM_EXPANDING($this, $this->{tree}, \&onTreeExpanding);

	return $this;
}


#---------------------------------
# initial load — top-level only
#---------------------------------

sub _loadTopLevel
{
	my ($this) = @_;
	my $tree = $this->{tree};
	$tree->DeleteAllItems();
	my $root = $tree->AddRoot('root');

	my $top_colls = getCollectionChildren(undef);
	for my $coll (@$top_colls)
	{
		_addCollectionItem($this, $root, $coll);
	}
}


#---------------------------------
# helpers
#---------------------------------

sub _collectionLabel
{
	my ($coll, $counts) = @_;
	my $n    = $coll->{node_type} // 'branch';
	my $name = $coll->{name};
	if ($n eq 'tracks')
	{
		my $c = $counts->{tracks};
		return "$name ($c " . ($c == 1 ? 'track' : 'tracks') . ")";
	}
	elsif ($n eq 'routes')
	{
		my $c = $counts->{routes};
		return "$name ($c " . ($c == 1 ? 'route' : 'routes') . ")";
	}
	elsif ($n eq 'group')
	{
		my $c = $counts->{waypoints};
		return "$name ($c " . ($c == 1 ? 'waypoint' : 'waypoints') . ")";
	}
	elsif ($n eq 'groups')
	{
		my $c = $counts->{collections};
		return "$name ($c " . ($c == 1 ? 'group' : 'groups') . ")";
	}
	else
	{
		my $c = $counts->{collections} + $counts->{waypoints}
		      + $counts->{routes}      + $counts->{tracks};
		return "$name ($c " . ($c == 1 ? 'child' : 'children') . ")";
	}
}


sub _addCollectionItem
{
	my ($this, $parent, $coll) = @_;
	my $tree   = $this->{tree};
	my $counts = getCollectionCounts($coll->{uuid});
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
	my ($this, $parent, $obj) = @_;
	my $label;
	if ($obj->{obj_type} eq 'route')
	{
		my $n = getRouteWaypointCount($obj->{uuid});
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

	_populateNode($this, $item, $node->{data});
}


sub _populateNode
{
	my ($this, $parent_item, $coll) = @_;
	my $coll_uuid = $coll->{uuid};
	my $node_type = $coll->{node_type} // 'branch';

	my $children = getCollectionChildren($coll_uuid);

	if ($node_type eq 'groups' && @$children)
	{
		my @floated = grep { ($_->{name} // '') =~ /^my\s+waypoints?$/i } @$children;
		my @rest    = grep { ($_->{name} // '') !~ /^my\s+waypoints?$/i } @$children;
		$children   = [@floated, @rest];
	}

	for my $child (@$children)
	{
		_addCollectionItem($this, $parent_item, $child);
	}

	my $objects = getCollectionObjects($coll_uuid);
	for my $obj (@$objects)
	{
		_addObjectItem($this, $parent_item, $obj);
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

	if ($node->{type} eq 'collection')
	{
		_showCollection($this, $node->{data});
	}
	elsif ($node->{type} eq 'object')
	{
		_showObject($this, $node->{data});
	}
}


sub _fmt
{
	my ($label, $value) = @_;
	return sprintf("%-18s%s\n", "$label:", $value // '');
}


sub _showCollection
{
	my ($this, $coll_stub) = @_;
	my $coll   = getCollection($coll_stub->{uuid});
	my $counts = getCollectionCounts($coll->{uuid});
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
	my ($this, $obj_stub) = @_;
	my $text = '';

	if ($obj_stub->{obj_type} eq 'track')
	{
		my $t = getTrack($obj_stub->{uuid});
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
		$text .= _fmt('source_file',     $t->{source_file});
		$text .= _fmt('collection_uuid', $t->{collection_uuid});
	}
	elsif ($obj_stub->{obj_type} eq 'waypoint')
	{
		my $w = getWaypoint($obj_stub->{uuid});
		my $ts = $w->{created_ts}
			? strftime("%Y-%m-%d %H:%M UTC", gmtime($w->{created_ts}))
			: '(none)';
		$text .= _fmt('uuid',            $w->{uuid});
		$text .= _fmt('name',            $w->{name});
		$text .= _fmt('comment',         $w->{comment});
		$text .= _fmt('lat',             sprintf("%.6f", $w->{lat}));
		$text .= _fmt('lon',             sprintf("%.6f", $w->{lon}));
		$text .= _fmt('sym',             $w->{sym});
		$text .= _fmt('depth_cm',        $w->{depth_cm});
		$text .= _fmt('created_ts',      $ts);
		$text .= _fmt('ts_source',       $w->{ts_source});
		$text .= _fmt('source_file',     $w->{source_file});
		$text .= _fmt('source',          $w->{source});
		$text .= _fmt('collection_uuid', $w->{collection_uuid});
	}
	elsif ($obj_stub->{obj_type} eq 'route')
	{
		my $r     = getRoute($obj_stub->{uuid});
		my $n_pts = getRouteWaypointCount($r->{uuid});
		$text .= _fmt('uuid',            $r->{uuid});
		$text .= _fmt('name',            $r->{name});
		$text .= _fmt('comment',         $r->{comment});
		$text .= _fmt('color',           $r->{color});
		$text .= _fmt('collection_uuid', $r->{collection_uuid});
		$text .= "\n";
		$text .= _fmt('route_points',    $n_pts);
	}

	$this->{detail}->SetValue($text);
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
