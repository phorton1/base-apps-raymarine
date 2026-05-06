#!/usr/bin/perl
#-------------------------------------------------------------------------
# winDatabase.pm
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

package winDatabase;
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
	EVT_RIGHT_DOWN
	EVT_MENU
	EVT_TEXT
	EVT_BUTTON
	EVT_CHOICE);
use Pub::WX::Dialogs;
use POSIX qw(strftime);
use Pub::Utils qw(display warning error);
use Pub::WX::Window;
use Pub::WX::Menu;
use c_db;
use a_defs;
use a_utils;
use nmPrefs;
use nmServer;
use nmUpload;
use nmClipboard;
use nmOps;
use w_resources;
use base qw(Wx::SplitterWindow Pub::WX::Window);

my $DUMMY = '__dummy__';

my $CTX_CMD_SHOW_MAP = 10560;
my $CTX_CMD_HIDE_MAP = 10561;

my %rendered_uuids;
my $last_clear_version = 0;


sub new
{
	my ($class, $frame, $book, $id, $data) = @_;
	my $this = $class->SUPER::new($book, $id);
	$this->MyWindow($frame, $book, $id, 'Database', $data);

	$this->{tree} = Wx::TreeCtrl->new($this, -1, wxDefaultPosition, wxDefaultSize,
		wxTR_DEFAULT_STYLE | wxTR_HIDE_ROOT | wxTR_MULTIPLE);

	# inner splitter: editor panel (top) + detail panel (bottom)
	my $right_split = Wx::SplitterWindow->new($this, -1);
	$this->{right_split} = $right_split;

	# --- editor panel ---
	my $editor_panel = Wx::Panel->new($right_split, -1);
	$this->{editor_panel} = $editor_panel;

	$this->{ed_title} = Wx::StaticText->new($editor_panel, -1, '');
	$this->{ed_title}->SetFont(
		Wx::Font->new(-1, wxFONTFAMILY_DEFAULT, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_BOLD));

	my $ed_sizer = Wx::FlexGridSizer->new(0, 2, 4, 8);
	$ed_sizer->AddGrowableCol(1);
	$this->{ed_sizer} = $ed_sizer;

	# name row
	$this->{ed_lbl_name} = Wx::StaticText->new($editor_panel, -1, 'Name');
	$this->{ed_name}     = Wx::TextCtrl->new($editor_panel, -1, '');
	$ed_sizer->Add($this->{ed_lbl_name}, 0, wxALIGN_CENTER_VERTICAL);
	$ed_sizer->Add($this->{ed_name},     1, wxEXPAND);

	# comment row
	$this->{ed_lbl_comment} = Wx::StaticText->new($editor_panel, -1, 'Comment');
	$this->{ed_comment}     = Wx::TextCtrl->new($editor_panel, -1, '');
	$ed_sizer->Add($this->{ed_lbl_comment}, 0, wxALIGN_CENTER_VERTICAL);
	$ed_sizer->Add($this->{ed_comment},     1, wxEXPAND);

	# lat row: TextCtrl + DDM static label
	$this->{ed_lbl_lat} = Wx::StaticText->new($editor_panel, -1, 'Lat');
	my $lat_panel = Wx::Panel->new($editor_panel, -1);
	$this->{ed_lat_panel} = $lat_panel;
	my $lat_hsizer = Wx::BoxSizer->new(wxHORIZONTAL);
	$this->{ed_lat}     = Wx::TextCtrl->new($lat_panel, -1, '', wxDefaultPosition, [110, -1]);
	$this->{ed_lat_ddm} = Wx::StaticText->new($lat_panel, -1, '');
	$lat_hsizer->Add($this->{ed_lat},     0, wxRIGHT, 8);
	$lat_hsizer->Add($this->{ed_lat_ddm}, 1, wxALIGN_CENTER_VERTICAL);
	$lat_panel->SetSizer($lat_hsizer);
	$ed_sizer->Add($this->{ed_lbl_lat}, 0, wxALIGN_CENTER_VERTICAL);
	$ed_sizer->Add($lat_panel,          1, wxEXPAND);

	# lon row: TextCtrl + DDM static label
	$this->{ed_lbl_lon} = Wx::StaticText->new($editor_panel, -1, 'Lon');
	my $lon_panel = Wx::Panel->new($editor_panel, -1);
	$this->{ed_lon_panel} = $lon_panel;
	my $lon_hsizer = Wx::BoxSizer->new(wxHORIZONTAL);
	$this->{ed_lon}     = Wx::TextCtrl->new($lon_panel, -1, '', wxDefaultPosition, [110, -1]);
	$this->{ed_lon_ddm} = Wx::StaticText->new($lon_panel, -1, '');
	$lon_hsizer->Add($this->{ed_lon},     0, wxRIGHT, 8);
	$lon_hsizer->Add($this->{ed_lon_ddm}, 1, wxALIGN_CENTER_VERTICAL);
	$lon_panel->SetSizer($lon_hsizer);
	$ed_sizer->Add($this->{ed_lbl_lon}, 0, wxALIGN_CENTER_VERTICAL);
	$ed_sizer->Add($lon_panel,          1, wxEXPAND);

	# wp_type row: Choice
	$this->{ed_lbl_wp_type} = Wx::StaticText->new($editor_panel, -1, 'Type');
	$this->{ed_wp_type}     = Wx::Choice->new($editor_panel, -1, wxDefaultPosition, wxDefaultSize,
		[$WP_TYPE_NAV, $WP_TYPE_LABEL, $WP_TYPE_SOUNDING]);
	$ed_sizer->Add($this->{ed_lbl_wp_type}, 0, wxALIGN_CENTER_VERTICAL);
	$ed_sizer->Add($this->{ed_wp_type},     0);

	# color row: swatch panel + Pick button
	$this->{ed_lbl_color} = Wx::StaticText->new($editor_panel, -1, 'Color');
	my $color_row = Wx::Panel->new($editor_panel, -1);
	$this->{ed_color_panel} = $color_row;
	my $color_row_sizer = Wx::BoxSizer->new(wxHORIZONTAL);
	$this->{ed_color_swatch} = Wx::Panel->new($color_row, -1, wxDefaultPosition, [28, 20],
		wxSIMPLE_BORDER);
	my $pick_btn = Wx::Button->new($color_row, -1, 'Pick...');
	$this->{ed_pick_btn} = $pick_btn;
	$color_row_sizer->Add($this->{ed_color_swatch}, 0, wxALIGN_CENTER_VERTICAL | wxRIGHT, 6);
	$color_row_sizer->Add($pick_btn,                0, wxALIGN_CENTER_VERTICAL);
	$color_row->SetSizer($color_row_sizer);
	$ed_sizer->Add($this->{ed_lbl_color}, 0, wxALIGN_CENTER_VERTICAL);
	$ed_sizer->Add($color_row,            0);

	# depth row: TextCtrl + unit label (ft or m per pref)
	$this->{ed_lbl_depth} = Wx::StaticText->new($editor_panel, -1, 'Depth');
	my $depth_panel = Wx::Panel->new($editor_panel, -1);
	$this->{ed_depth_panel} = $depth_panel;
	my $depth_hsizer = Wx::BoxSizer->new(wxHORIZONTAL);
	$this->{ed_depth} = Wx::TextCtrl->new($depth_panel, -1, '', wxDefaultPosition, [70, -1]);
	my $depth_unit = getPref($PREF_DEPTH_DISPLAY) == $DEPTH_DISPLAY_FEET ? 'ft' : 'm';
	$this->{ed_depth_unit} = Wx::StaticText->new($depth_panel, -1, $depth_unit);
	$depth_hsizer->Add($this->{ed_depth},      0, wxRIGHT, 6);
	$depth_hsizer->Add($this->{ed_depth_unit}, 0, wxALIGN_CENTER_VERTICAL);
	$depth_panel->SetSizer($depth_hsizer);
	$ed_sizer->Add($this->{ed_lbl_depth}, 0, wxALIGN_CENTER_VERTICAL);
	$ed_sizer->Add($depth_panel,          0);

	# save button, right-aligned below the grid
	$this->{ed_save} = Wx::Button->new($editor_panel, -1, 'Save');
	$this->{ed_save}->Enable(0);
	my $save_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$save_row->AddStretchSpacer(1);
	$save_row->Add($this->{ed_save}, 0);

	my $ed_outer = Wx::BoxSizer->new(wxVERTICAL);
	$ed_outer->Add($this->{ed_title}, 0, wxLEFT | wxTOP | wxRIGHT, 8);
	$ed_outer->Add($ed_sizer,         0, wxEXPAND | wxALL, 8);
	$ed_outer->AddStretchSpacer(1);
	$ed_outer->Add($save_row,         0, wxEXPAND | wxBOTTOM | wxRIGHT, 8);
	$editor_panel->SetSizer($ed_outer);

	_clearEditor($this);

	# --- detail panel (read-only monospaced) ---
	my $detail_panel = Wx::Panel->new($right_split, -1);
	$this->{detail_panel} = $detail_panel;
	$this->{detail} = Wx::TextCtrl->new($detail_panel, -1, '', wxDefaultPosition, wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
	my $font = Wx::Font->new(9, wxFONTFAMILY_MODERN, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL);
	$this->{detail}->SetFont($font);
	my $detail_vsizer = Wx::BoxSizer->new(wxVERTICAL);
	$detail_vsizer->Add($this->{detail}, 1, wxEXPAND);
	$detail_panel->SetSizer($detail_vsizer);

	$right_split->SplitHorizontally($editor_panel, $detail_panel, 0);
	$right_split->SetSashGravity(0.5);

	my $sash = ($data && ref($data) eq 'HASH' && $data->{sash}) ? $data->{sash} : 250;
	$this->SplitVertically($this->{tree}, $right_split, $sash);
	$this->SetSashGravity(0);

	my %init_expanded;
	if ($data && ref($data) eq 'HASH' && $data->{expanded})
	{
		$init_expanded{$_} = 1 for split(/,/, $data->{expanded});
	}
	$this->{_expanded_uuids} = \%init_expanded;
	$this->{_selected_uuids} = {};

	# Bind events BEFORE _loadTopLevel so that Expand() calls in _restoreExpanded
	# fire EVT_TREE_ITEM_EXPANDING synchronously with the handler already active.
	EVT_TREE_SEL_CHANGED($this,        $this->{tree}, \&onTreeSelect);
	EVT_TREE_ITEM_EXPANDING($this,     $this->{tree}, \&onTreeExpanding);
	EVT_TREE_ITEM_RIGHT_CLICK($this,   $this->{tree}, \&onTreeRightClick);
	EVT_RIGHT_DOWN($this->{tree},      sub { _onTreeRightDown($this, @_) });
	EVT_LEFT_DCLICK($this->{tree}, sub { _onTreeDblClick($this, @_) });

	EVT_MENU($this, $COMMAND_UPLOAD_E80, \&_onUploadE80);   # vestigial
	EVT_MENU($this, $_, \&_onContextMenuCommand)
		for (allCopyCmds(), allCutCmds(), $CTX_CMD_PASTE, $CTX_CMD_PASTE_NEW, allDeleteCmds(), allNewCmds());
	EVT_MENU($this, $CTX_CMD_SHOW_MAP, \&_onShowMap);
	EVT_MENU($this, $CTX_CMD_HIDE_MAP, \&_onHideMap);
	EVT_TEXT($this,   $this->{ed_name},    \&_onFieldChanged);
	EVT_TEXT($this,   $this->{ed_comment}, \&_onFieldChanged);
	EVT_TEXT($this,   $this->{ed_lat},     \&_onLatEdit);
	EVT_TEXT($this,   $this->{ed_lon},     \&_onLonEdit);
	EVT_TEXT($this,   $this->{ed_depth},   \&_onFieldChanged);
	EVT_CHOICE($this, $this->{ed_wp_type}, \&_onFieldChanged);
	EVT_BUTTON($this, $this->{ed_save},    \&_onSave);
	EVT_BUTTON($this, $this->{ed_pick_btn}, \&_onColorPick);

	_loadTopLevel($this);

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

	my $db_item = $tree->AppendItem($root, 'Database', -1, -1,
		Wx::TreeItemData->new({ type => 'root', data => { uuid => undef, name => 'Database' } }));
	$tree->SetItemBold($db_item, 1);

	my $dbh = connectDB();
	if (!$dbh) { $tree->Thaw(); return; }
	my $top_colls = getCollectionChildren($dbh, undef);
	for my $coll (@$top_colls)
	{
		_addCollectionItem($dbh, $this, $root, $coll);
	}
	disconnectDB($dbh);
	$tree->Thaw();

	# Expand/select restoration must run outside Freeze so that Expand() fires
	# EVT_TREE_ITEM_EXPANDING synchronously, allowing onTreeExpanding to replace
	# dummy children before the recursion descends into them.
	_restoreExpanded($tree, $root, $this->{_expanded_uuids});
	_restoreSelected($tree, $root, $this->{_selected_uuids});
}


sub refresh
{
	my ($this) = @_;
	if ($this->{tree}->GetCount() > 0)
	{
		_captureExpandedInto($this);
		_captureSelectedInto($this);
	}
	_clearEditor($this);
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
	return "$name (empty)" if !$total;
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
	my $n = 0;
	if ($obj->{obj_type} eq 'route')
	{
		$n     = getRouteWaypointCount($dbh, $obj->{uuid});
		$label = "$obj->{name} ($n pts)";
	}
	elsif ($obj->{obj_type} eq 'track')
	{
		$label = "[track] $obj->{name} (${\($obj->{point_count} // 0)} pts)";
	}
	else
	{
		$label = "[waypoint] $obj->{name}";
	}
	my $item = $this->{tree}->AppendItem($parent, $label, -1, -1,
		Wx::TreeItemData->new({ type => 'object', data => $obj }));
	$this->{tree}->AppendItem($item, $DUMMY) if $obj->{obj_type} eq 'route' && $n > 0;
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
	return if !($first && $first->IsOk());
	return if (($tree->GetItemText($first) // '') ne $DUMMY);

	$tree->Delete($first);

	my $item_data = $tree->GetItemData($item);
	return if !$item_data;
	my $node = $item_data->GetData();
	return if ref $node ne 'HASH';

	my $dbh = connectDB();
	if ($node->{type} eq 'collection')
	{
		_populateNode($dbh, $this, $item, $node->{data});
	}
	elsif ($node->{type} eq 'object' && ($node->{data}{obj_type} // '') eq 'route')
	{
		_populateRoutePoints($dbh, $this, $item, $node->{data});
	}
	disconnectDB($dbh);
}


sub _populateRoutePoints
{
	my ($dbh, $this, $parent_item, $route) = @_;
	my $wps = getRouteWaypoints($dbh, $route->{uuid});
	for my $i (0 .. $#$wps)
	{
		my $wp    = $wps->[$i];
		my $label = sprintf('%d. %s', $i + 1, $wp->{name} // '');
		$this->{tree}->AppendItem($parent_item, $label, -1, -1,
			Wx::TreeItemData->new({
				type       => 'route_point',
				route_uuid => $route->{uuid},
				position   => $wp->{position},
				uuid       => $wp->{uuid},
				data       => $wp,
			}));
	}
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
	return if !$item->IsOk();
	my $item_data = $this->{tree}->GetItemData($item);
	return if !$item_data;
	my $node = $item_data->GetData();
	return if ref $node ne 'HASH';

	if ($node->{type} eq 'root')
	{
		_clearEditor($this);
		$this->{detail}->SetValue('');
		return;
	}

	my $dbh = connectDB();
	if ($node->{type} eq 'collection')
	{
		_loadEditor($this, $dbh, $node);
		_showCollection($dbh, $this, $node->{data});
	}
	elsif ($node->{type} eq 'object')
	{
		_loadEditor($this, $dbh, $node);
		_showObject($dbh, $this, $node->{data});
	}
	elsif ($node->{type} eq 'route_point')
	{
		_clearEditor($this);
		_showRoutePoint($this, $node);
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
		$text .= _fmt('lat',             formatLatLon($w->{lat}, 1));
		$text .= _fmt('lon',             formatLatLon($w->{lon}, 0));
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
			my $wp = $wps->[$i];
			$text .= sprintf("  %2d. %s\n", $i + 1, $wp->{name} // '');
			$text .= sprintf("      %s\n", formatLatLon($wp->{lat}, 1));
			$text .= sprintf("      %s\n", formatLatLon($wp->{lon}, 0));
		}
	}

	$this->{detail_panel}->Layout();
	$this->{detail}->SetValue($text);
}


sub _showRoutePoint
{
	my ($this, $node) = @_;
	my $wp   = $node->{data};
	my $text = '';
	$text .= _fmt('position',   $node->{position});
	$text .= _fmt('route_uuid', $node->{route_uuid});
	$text .= _fmt('uuid',       $node->{uuid});
	$text .= _fmt('name',       $wp->{name});
	$text .= _fmt('lat',        formatLatLon($wp->{lat} // 0, 1));
	$text .= _fmt('lon',        formatLatLon($wp->{lon} // 0, 0));
	$this->{detail}->SetValue($text);
}


#---------------------------------
# editor panel
#---------------------------------

sub _ed_show_row
{
	my ($sizer, $label, $ctrl, $show) = @_;
	$sizer->Show($label, $show ? 1 : 0);
	$sizer->Show($ctrl,  $show ? 1 : 0);
}


sub _clearEditor
{
	my ($this) = @_;
	$this->{_edit_uuid}     = undef;
	$this->{_edit_type}     = undef;
	$this->{_edit_obj_type} = undef;
	$this->{_edit_color}    = undef;
	$this->{_editor_dirty}  = 0;
	$this->{ed_title}->SetLabel('');
	my $ed = $this->{ed_sizer};
	_ed_show_row($ed, $this->{ed_lbl_name},    $this->{ed_name},        0);
	_ed_show_row($ed, $this->{ed_lbl_comment}, $this->{ed_comment},     0);
	_ed_show_row($ed, $this->{ed_lbl_lat},     $this->{ed_lat_panel},   0);
	_ed_show_row($ed, $this->{ed_lbl_lon},     $this->{ed_lon_panel},   0);
	_ed_show_row($ed, $this->{ed_lbl_wp_type}, $this->{ed_wp_type},     0);
	_ed_show_row($ed, $this->{ed_lbl_color},   $this->{ed_color_panel}, 0);
	_ed_show_row($ed, $this->{ed_lbl_depth},   $this->{ed_depth_panel}, 0);
	$this->{editor_panel}->Layout();
	$this->{ed_save}->Enable(0);
}


sub _loadEditor
{
	my ($this, $dbh, $node) = @_;
	my $type     = $node->{type};
	my $obj_type = ($node->{data} // {})->{obj_type} // '';
	my $uuid     = ($node->{data} // {})->{uuid};

	my $show_name    = ($type eq 'collection' || $type eq 'object');
	my $show_comment = ($type eq 'collection'
		|| $obj_type eq 'waypoint' || $obj_type eq 'route');
	my $show_latlon  = ($obj_type eq 'waypoint');
	my $show_wptype  = ($obj_type eq 'waypoint');
	my $show_color   = ($obj_type eq 'waypoint'
		|| $obj_type eq 'route' || $obj_type eq 'track');
	my $show_depth   = ($obj_type eq 'waypoint');

	my $data;
	if    ($type eq 'collection')             { $data = getCollection($dbh, $uuid); }
	elsif ($obj_type eq 'waypoint')           { $data = getWaypoint($dbh, $uuid);   }
	elsif ($obj_type eq 'route')              { $data = getRoute($dbh, $uuid);      }
	elsif ($obj_type eq 'track')              { $data = getTrack($dbh, $uuid);      }
	$data //= $node->{data} // {};

	$this->{_edit_uuid}     = $uuid;
	$this->{_edit_type}     = $type;
	$this->{_edit_obj_type} = $obj_type;
	$this->{_edit_color}    = undef;
	$this->{_editor_dirty}  = 0;

	my $title = $type eq 'collection'
		? ($data->{node_type} // '' eq $NODE_TYPE_GROUP ? 'Group' : 'Branch')
		: ucfirst($obj_type);
	$this->{ed_title}->SetLabel($title);

	my $ed = $this->{ed_sizer};
	_ed_show_row($ed, $this->{ed_lbl_name},    $this->{ed_name},        $show_name);
	_ed_show_row($ed, $this->{ed_lbl_comment}, $this->{ed_comment},     $show_comment);
	_ed_show_row($ed, $this->{ed_lbl_lat},     $this->{ed_lat_panel},   $show_latlon);
	_ed_show_row($ed, $this->{ed_lbl_lon},     $this->{ed_lon_panel},   $show_latlon);
	_ed_show_row($ed, $this->{ed_lbl_wp_type}, $this->{ed_wp_type},     $show_wptype);
	_ed_show_row($ed, $this->{ed_lbl_color},   $this->{ed_color_panel}, $show_color);
	_ed_show_row($ed, $this->{ed_lbl_depth},   $this->{ed_depth_panel}, $show_depth);

	$this->{_loading_editor} = 1;

	$this->{ed_name}->SetValue($data->{name} // '')       if $show_name;
	$this->{ed_comment}->SetValue($data->{comment} // '') if $show_comment;

	if ($show_latlon)
	{
		$this->{ed_lat}->SetValue(defined $data->{lat} ? sprintf('%.6f', $data->{lat}) : '');
		$this->{ed_lon}->SetValue(defined $data->{lon} ? sprintf('%.6f', $data->{lon}) : '');
		_updateLatDDM($this);
		_updateLonDDM($this);
	}

	if ($show_wptype)
	{
		my $wp_type = $data->{wp_type} // $WP_TYPE_NAV;
		my $idx = $wp_type eq $WP_TYPE_LABEL    ? 1
		        : $wp_type eq $WP_TYPE_SOUNDING  ? 2
		        :                                  0;
		$this->{ed_wp_type}->SetSelection($idx);
	}

	_setColorSwatch($this, $data->{color}) if $show_color;

	if ($show_depth)
	{
		my $cm   = $data->{depth_cm} // 0;
		my $disp = '';
		if ($cm)
		{
			my $pref = getPref($PREF_DEPTH_DISPLAY);
			$disp = $pref == $DEPTH_DISPLAY_FEET
				? sprintf('%.1f', $cm / 30.48)
				: sprintf('%.2f', $cm / 100);
		}
		$this->{ed_depth}->SetValue($disp);
	}

	$this->{_loading_editor} = 0;
	$this->{editor_panel}->Layout();
	$this->{ed_save}->Enable(0);
}


sub _onFieldChanged
{
	my ($this, $event) = @_;
	return if $this->{_loading_editor};
	$this->{_editor_dirty} = 1;
	$this->{ed_save}->Enable(1);
}


sub _onLatEdit
{
	my ($this, $event) = @_;
	return if $this->{_loading_editor};
	$this->{_editor_dirty} = 1;
	$this->{ed_save}->Enable(1);
	_updateLatDDM($this);
}


sub _onLonEdit
{
	my ($this, $event) = @_;
	return if $this->{_loading_editor};
	$this->{_editor_dirty} = 1;
	$this->{ed_save}->Enable(1);
	_updateLonDDM($this);
}


sub _updateLatDDM
{
	my ($this) = @_;
	my $dd = parseLatLon($this->{ed_lat}->GetValue());
	$this->{ed_lat_ddm}->SetLabel(defined $dd ? _ddm_label($dd, 1) : '');
}


sub _updateLonDDM
{
	my ($this) = @_;
	my $dd = parseLatLon($this->{ed_lon}->GetValue());
	$this->{ed_lon_ddm}->SetLabel(defined $dd ? _ddm_label($dd, 0) : '');
}


sub _ddm_label
{
	my ($dd, $is_lat) = @_;
	my $abs = abs($dd);
	my $dir = $is_lat ? ($dd >= 0 ? 'N' : 'S') : ($dd >= 0 ? 'E' : 'W');
	my $deg = int($abs);
	my $min = ($abs - $deg) * 60;
	return sprintf("%d\x{00b0}%06.3f' %s", $deg, $min, $dir);
}


sub _setColorSwatch
{
	my ($this, $color) = @_;
	$this->{_edit_color} = $color;
	if (defined $color && $color =~ /^[0-9a-fA-F]{8}$/)
	{
		my $rr = hex(substr($color, 6, 2));
		my $gg = hex(substr($color, 4, 2));
		my $bb = hex(substr($color, 2, 2));
		$this->{ed_color_swatch}->SetBackgroundColour(Wx::Colour->new($rr, $gg, $bb));
	}
	else
	{
		$this->{ed_color_swatch}->SetBackgroundColour(Wx::Colour->new(192, 192, 192));
	}
	$this->{ed_color_swatch}->Refresh();
}


sub _onColorPick
{
	my ($this, $event) = @_;
	my $current = $this->{_edit_color} // 'FF0000FF';
	my $aa = substr($current, 0, 2);
	my $rr = hex(substr($current, 6, 2));
	my $gg = hex(substr($current, 4, 2));
	my $bb = hex(substr($current, 2, 2));

	my $cd = Wx::ColourData->new();
	$cd->SetColour(Wx::Colour->new($rr, $gg, $bb));
	$cd->SetChooseFull(1);

	my $dlg = Wx::ColourDialog->new($this, $cd);
	if ($dlg->ShowModal() == wxID_OK)
	{
		my $c = $dlg->GetColourData()->GetColour();
		_setColorSwatch($this, sprintf('%s%02x%02x%02x', $aa, $c->Blue(), $c->Green(), $c->Red()));
		return if $this->{_loading_editor};
		$this->{_editor_dirty} = 1;
		$this->{ed_save}->Enable(1);
	}
	$dlg->Destroy();
}


sub _onSave
{
	my ($this, $event) = @_;
	return if !$this->{_edit_uuid};

	my $uuid     = $this->{_edit_uuid};
	my $type     = $this->{_edit_type};
	my $obj_type = $this->{_edit_obj_type} // '';

	my $dbh = connectDB();

	if ($type eq 'collection')
	{
		$dbh->do("UPDATE collections SET name=?, comment=? WHERE uuid=?",
			[$this->{ed_name}->GetValue(),
			 $this->{ed_comment}->GetValue() || undef,
			 $uuid]);
	}
	elsif ($type eq 'object' && $obj_type eq 'waypoint')
	{
		my $lat = parseLatLon($this->{ed_lat}->GetValue());
		my $lon = parseLatLon($this->{ed_lon}->GetValue());
		if (!defined $lat || !defined $lon)
		{
			disconnectDB($dbh);
			warning(0, 0, "invalid lat/lon — save aborted");
			return;
		}
		my @types   = ($WP_TYPE_NAV, $WP_TYPE_LABEL, $WP_TYPE_SOUNDING);
		my $wp_type = $types[$this->{ed_wp_type}->GetSelection()] // $WP_TYPE_NAV;
		my $depth_str = $this->{ed_depth}->GetValue();
		my $depth_cm  = 0;
		if ($depth_str ne '')
		{
			my $pref = getPref($PREF_DEPTH_DISPLAY);
			$depth_cm = int($depth_str * ($pref == $DEPTH_DISPLAY_FEET ? 30.48 : 100) + 0.5);
		}
		my $w = getWaypoint($dbh, $uuid);
		updateWaypoint($dbh, $uuid,
			name       => $this->{ed_name}->GetValue(),
			comment    => $this->{ed_comment}->GetValue() || undef,
			lat        => $lat,
			lon        => $lon,
			wp_type    => $wp_type,
			color      => $this->{_edit_color},
			depth_cm   => $depth_cm,
			sym        => $w->{sym},
			created_ts => $w->{created_ts},
			ts_source  => $w->{ts_source},
			source     => $w->{source});
	}
	elsif ($type eq 'object' && $obj_type eq 'route')
	{
		updateRoute($dbh, $uuid,
			$this->{ed_name}->GetValue(),
			$this->{_edit_color},
			$this->{ed_comment}->GetValue() || undef);
	}
	elsif ($type eq 'object' && $obj_type eq 'track')
	{
		$dbh->do("UPDATE tracks SET name=?, color=? WHERE uuid=?",
			[$this->{ed_name}->GetValue(), $this->{_edit_color}, $uuid]);
	}

	disconnectDB($dbh);
	$this->refresh();
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

	if (!($item && $item->IsOk() && ($flags & wxTREE_HITTEST_ONITEMLABEL)))
	{
		$event->Skip();
		return;
	}

	my $item_data = $tree->GetItemData($item);
	return if !$item_data;
	my $node = $item_data->GetData();
	return if ref $node ne 'HASH';

	my $dbh = connectDB();
	if ($node->{type} eq 'collection')
	{
		_renderCollection($dbh, $this, $node->{data}{uuid});
	}
	elsif ($node->{type} eq 'object')
	{
		_renderObject($dbh, $this, $node->{data});
	}
	elsif ($node->{type} eq 'route_point')
	{
		_renderObject($dbh, $this, { obj_type => 'waypoint', uuid => $node->{uuid} });
	}
	disconnectDB($dbh);
	openMapBrowser() if !isBrowserConnected();
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

	if ($rendered_uuids{$uuid})
	{
		my @children = ref($rendered_uuids{$uuid}) eq 'ARRAY' ? @{$rendered_uuids{$uuid}} : ();
		my @remove = ($uuid, @children);
		delete $rendered_uuids{$_} for @remove;
		removeRenderFeatures(\@remove);
		return;
	}

	my $wrgt = getCollectionWRGTs($dbh, $uuid);
	my @features;
	my @rendered_objects;

	for my $wp (@{$wrgt->{waypoints}})
	{
		next if $rendered_uuids{$wp->{uuid}};
		$rendered_uuids{$wp->{uuid}} = 1;
		push @rendered_objects, $wp->{uuid};
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
		next if !@$pts;
		$rendered_uuids{$t->{uuid}} = 1;
		push @rendered_objects, $t->{uuid};
		my @coords = map { [$_->{lon} + 0, $_->{lat} + 0] } @$pts;
		push @features, {
			type       => 'Feature',
			properties => {
				uuid            => $t->{uuid},
				name            => $t->{name} // '',
				obj_type        => 'track',
				color           => $t->{color},
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
		next if !@$pts;
		$rendered_uuids{$r->{uuid}} = 1;
		push @rendered_objects, $r->{uuid};
		my @coords   = map { [$_->{lon} + 0, $_->{lat} + 0] } @$pts;
		my @rp_names = map { $_->{name} // '' } @$pts;
		push @features, {
			type       => 'Feature',
			properties => {
				uuid            => $r->{uuid},
				name            => $r->{name} // '',
				obj_type        => 'route',
				color           => $r->{color},
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

	$rendered_uuids{$uuid} = \@rendered_objects;
	addRenderFeatures(\@features) if @features;
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

	if ($rendered_uuids{$obj->{uuid}})
	{
		delete $rendered_uuids{$obj->{uuid}};
		removeRenderFeatures([$obj->{uuid}]);
		return;
	}

	my @features;

	if ($obj->{obj_type} eq 'waypoint')
	{
		my $w = getWaypoint($dbh, $obj->{uuid});
		return if !$w;
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
					color           => $t->{color},
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
					color           => $r->{color},
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
	my $menu = Wx::Menu->new();
	$menu->Append($CTX_CMD_NEW_BRANCH, 'New Branch');
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

	my $menu = Wx::Menu->new();

	my @copy_items = getCopyMenuItems('database', @nodes);
	my @cut_items  = getCutMenuItems('database', @nodes);
	$menu->Append($_->{id}, $_->{label}) for @copy_items;
	$menu->Append($_->{id}, $_->{label}) for @cut_items;
	$menu->AppendSeparator() if @copy_items || @cut_items;

	$menu->Append($CTX_CMD_PASTE, 'Paste');
	$menu->Enable($CTX_CMD_PASTE, canPaste($right_click_node, 'database') ? 1 : 0);
	$menu->Append($CTX_CMD_PASTE_NEW, 'Paste New');
	$menu->Enable($CTX_CMD_PASTE_NEW, canPasteNew($right_click_node, 'database') ? 1 : 0);

	my @delete_items = getDeleteMenuItems('database', $right_click_node, @nodes);
	if (@delete_items)
	{
		$menu->AppendSeparator();
		$menu->Append($_->{id}, $_->{label}) for @delete_items;
	}

	my @new_items = getNewMenuItems('database', $right_click_node);
	if (@new_items)
	{
		$menu->AppendSeparator();
		$menu->Append($_->{id}, $_->{label}) for @new_items;
	}

	my $node_type = $right_click_node->{type} // '';
	if ($node_type eq 'collection')
	{
		$this->{_upload_target} = { kind => 'collection', data => $right_click_node->{data} };
		$menu->AppendSeparator();
		$menu->Append($COMMAND_UPLOAD_E80, 'Upload to E80');
	}

	if ($node_type ne 'root')
	{
		$menu->AppendSeparator();
		$menu->Append($CTX_CMD_SHOW_MAP, 'Show on Map');
		$menu->Append($CTX_CMD_HIDE_MAP, 'Hide on Map');
	}

	return $menu;
}


sub _onContextMenuCommand
{
	my ($this, $event) = @_;
	onContextMenuCommand(
		$event->GetId(), 'database', $this->{_right_click_node}, $this->{tree},
		@{$this->{_context_nodes} // []});
}


sub _onShowMap
{
	my ($this, $event) = @_;
	my @nodes = @{$this->{_context_nodes} // []};
	return if !@nodes;
	my $dbh = connectDB();
	for my $node (@nodes)
	{
		if ($node->{type} eq 'collection')
		{
			my $uuid = $node->{data}{uuid};
			next if $rendered_uuids{$uuid};
			_renderCollection($dbh, $this, $uuid);
		}
		elsif ($node->{type} eq 'object')
		{
			next if $rendered_uuids{$node->{data}{uuid}};
			_renderObject($dbh, $this, $node->{data});
		}
		elsif ($node->{type} eq 'route_point')
		{
			next if $rendered_uuids{$node->{uuid}};
			_renderObject($dbh, $this, { obj_type => 'waypoint', uuid => $node->{uuid} });
		}
	}
	disconnectDB($dbh);
	openMapBrowser() if !isBrowserConnected();
}


sub _onHideMap
{
	my ($this, $event) = @_;
	my @nodes = @{$this->{_context_nodes} // []};
	return if !@nodes;
	my @remove;
	for my $node (@nodes)
	{
		if ($node->{type} eq 'collection')
		{
			my $uuid = $node->{data}{uuid};
			next if !$rendered_uuids{$uuid};
			my @children = ref($rendered_uuids{$uuid}) eq 'ARRAY' ? @{$rendered_uuids{$uuid}} : ();
			push @remove, $uuid, @children;
			delete $rendered_uuids{$_} for ($uuid, @children);
		}
		elsif ($node->{type} eq 'object')
		{
			my $uuid = $node->{data}{uuid};
			next if !$rendered_uuids{$uuid};
			push @remove, $uuid;
			delete $rendered_uuids{$uuid};
		}
		elsif ($node->{type} eq 'route_point')
		{
			my $uuid = $node->{uuid};
			next if !$rendered_uuids{$uuid};
			push @remove, $uuid;
			delete $rendered_uuids{$uuid};
		}
	}
	removeRenderFeatures(\@remove) if @remove;
}


sub _onUploadE80
{
	my ($this) = @_;
	my $progress = $this->{_progress_data};
	return if $progress && $progress->{active};

	my $target = $this->{_upload_target};
	return if !$target;
	my $kind = $target->{kind};
	my $data = $target->{data};

	my $progress_data = Pub::WX::ProgressDialog::newProgressData(0);

	my $total = 0;
	if ($kind eq 'collection')
	{
		$total = uploadCollectionToE80($data->{uuid}, $data->{name}, $progress_data);
	}
	elsif ($kind eq 'route')
	{
		$total = uploadRouteToE80($data->{uuid}, $data->{name}, $data->{color}, $progress_data);
	}
	elsif ($kind eq 'waypoint')
	{
		$total = uploadWaypointToE80($data, $progress_data);
	}

	if ($total > 0)
	{
		$this->{_progress_data} = $progress_data;
		Pub::WX::ProgressDialog->new(
			$this->{frame},
			'Upload to E80',
			1,
			$progress_data,
			'Uploading...');
	}
}


#---------------------------------
# ini persistence
#---------------------------------

sub getDataForIniFile
{
	my ($this) = @_;
	_captureExpandedInto($this) if $this->{tree}->GetCount() > 0;
	return {
		sash     => $this->GetSashPosition(),
		expanded => join(',', sort keys %{$this->{_expanded_uuids}}),
	};
}


#---------------------------------
# tree state — expand / select
#---------------------------------

sub _nodeKey
{
	my ($node) = @_;
	return undef if ref $node ne 'HASH';
	return $node->{uuid} // ($node->{data} // {})->{uuid};
}


sub _captureExpandedInto
{
	my ($this) = @_;
	my %keys;
	my $tree = $this->{tree};
	my $root = $tree->GetRootItem();
	if ($root && $root->IsOk())
	{
		my ($child, $cookie) = $tree->GetFirstChild($root);
		while ($child && $child->IsOk())
		{
			_walkExpandedCapture($tree, $child, \%keys);
			($child, $cookie) = $tree->GetNextChild($root, $cookie);
		}
	}
	$this->{_expanded_uuids} = \%keys;
}

sub _walkExpandedCapture
{
	my ($tree, $item, $result) = @_;
	return if !$item->IsOk();
	return if !$tree->IsExpanded($item);
	my $d = $tree->GetItemData($item);
	if ($d)
	{
		my $node = $d->GetData();
		if (ref $node eq 'HASH')
		{
			my $key = _nodeKey($node);
			$result->{$key} = 1 if $key;
		}
	}
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		_walkExpandedCapture($tree, $child, $result);
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
}


sub _captureSelectedInto
{
	my ($this) = @_;
	my %keys;
	for my $item ($this->{tree}->GetSelections())
	{
		my $d = $this->{tree}->GetItemData($item);
		next if !$d;
		my $node = $d->GetData();
		next if ref $node ne 'HASH';
		my $key = _nodeKey($node);
		$keys{$key} = 1 if $key;
	}
	$this->{_selected_uuids} = \%keys;
}


sub _restoreExpanded
{
	my ($tree, $item, $expanded) = @_;
	return if !($item && $item->IsOk());
	my $d = $tree->GetItemData($item);
	if ($d)
	{
		my $node = $d->GetData();
		if (ref $node eq 'HASH')
		{
			my $key = _nodeKey($node);
			# Expand fires onTreeExpanding synchronously, populating children
			# before the recursion below descends into them.
			$tree->Expand($item) if $key && $expanded->{$key};
		}
	}
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		_restoreExpanded($tree, $child, $expanded);
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
}


sub _restoreSelected
{
	my ($tree, $item, $selected) = @_;
	return if !($item && $item->IsOk());
	my $d = $tree->GetItemData($item);
	if ($d)
	{
		my $node = $d->GetData();
		if (ref $node eq 'HASH')
		{
			my $key = _nodeKey($node);
			$tree->SelectItem($item, 1) if $key && $selected->{$key};
		}
	}
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		_restoreSelected($tree, $child, $selected);
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
}


1;
