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
	EVT_TREE_ITEM_ACTIVATED
	EVT_TREE_ITEM_RIGHT_CLICK
	EVT_RIGHT_DOWN
	EVT_MENU
	EVT_MENU_RANGE
	EVT_TEXT
	EVT_BUTTON
	EVT_CHOICE
	EVT_CHECKBOX
	EVT_LEFT_DOWN
	EVT_SIZE);
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
use nmOps qw(buildContextMenu onContextMenuCommand);
use w_resources;
use base qw(Wx::SplitterWindow Pub::WX::Window);

my $DUMMY = '__dummy__';

my $CTX_CMD_SHOW_MAP   = 10560;
my $CTX_CMD_HIDE_MAP   = 10561;
my $CTX_CMD_DELETE     = 10562;
my $CTX_CMD_NEW_BRANCH = 10563;
my $CTX_CMD_NEW_GROUP  = 10564;

my %rendered_uuids;
my $last_clear_version = 0;


sub new
{
	my ($class, $frame, $book, $id, $data) = @_;
	my $this = $class->SUPER::new($book, $id);
	$this->MyWindow($frame, $book, $id, 'Database', $data);

	$this->{tree} = Wx::TreeCtrl->new($this, -1, wxDefaultPosition, wxDefaultSize,
		wxTR_DEFAULT_STYLE | wxTR_HIDE_ROOT | wxTR_MULTIPLE);

	# checkbox state images: index 0=unchecked(state 1), 1=checked(state 2), 2=indeterminate(state 3)
	my $state_imgs = Wx::ImageList->new(13, 13);
	$state_imgs->Add(_makeCheckBitmap(0));
	$state_imgs->Add(_makeCheckBitmap(1));
	$state_imgs->Add(_makeCheckBitmap(2));
	$this->{tree}->SetStateImageList($state_imgs);
	$this->{_state_imgs} = $state_imgs;

	# inner splitter: editor panel (top) + detail panel (bottom)
	my $right_split = Wx::SplitterWindow->new($this, -1);
	$this->{right_split} = $right_split;

	# --- editor panel layout constants ---
	my $ED_MARGIN        = 8;
	my $ED_LABEL_W       = 60;
	my $ED_COL_GAP       = 8;
	my $ED_CTRL_X        = $ED_MARGIN + $ED_LABEL_W + $ED_COL_GAP;
	my $ED_CTRL_H        = 23;
	my $ED_ROW_GAP       = 2;
	my $ED_ROW_H         = $ED_CTRL_H + $ED_ROW_GAP;
	my $ED_HEADER_SIZE   = $ED_MARGIN + $ED_ROW_H;
	my $ED_BOTTOM_MARGIN = 8;
	my $ED_MAX_ROWS      = 7;
	my $ED_TITLE_W       = 80;
	my $ED_VIS_X         = $ED_CTRL_X + $ED_TITLE_W + 8;
	$this->{_ed_ctrl_x}  = $ED_CTRL_X;
	$this->{_ed_ctrl_h}  = $ED_CTRL_H;
	$this->{_ed_margin}  = $ED_MARGIN;

	my $ED_INITIAL_SASH  = $ED_HEADER_SIZE + $ED_MAX_ROWS * $ED_ROW_H + $ED_BOTTOM_MARGIN;

	# helper: y position of row N (0-based)
	my $ey = sub { $ED_HEADER_SIZE + $_[0] * $ED_ROW_H };

	# --- editor panel ---
	my $editor_panel = Wx::Panel->new($right_split, -1);
	$this->{editor_panel} = $editor_panel;

	# header row: Save button (label col) + bold type title (ctrl col)
	$this->{ed_save} = Wx::Button->new($editor_panel, -1, 'Save',
		[$ED_MARGIN, $ED_MARGIN], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_save}->Enable(0);

	$this->{ed_title} = Wx::StaticText->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ED_MARGIN], [$ED_TITLE_W, $ED_CTRL_H]);
	$this->{ed_title}->SetFont(
		Wx::Font->new(-1, wxFONTFAMILY_DEFAULT, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_BOLD));

	$this->{ed_visible} = Wx::CheckBox->new($editor_panel, -1, 'Visible',
		[$ED_VIS_X, $ED_MARGIN], [-1, $ED_CTRL_H], wxCHK_3STATE);
	$this->{ed_visible}->Show(0);

	# name row (row 0)
	$this->{ed_lbl_name} = Wx::StaticText->new($editor_panel, -1, 'Name',
		[$ED_MARGIN, $ey->(0)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_name} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(0)], [200, $ED_CTRL_H]);

	# comment row (row 1)
	$this->{ed_lbl_comment} = Wx::StaticText->new($editor_panel, -1, 'Comment',
		[$ED_MARGIN, $ey->(1)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_comment} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(1)], [200, $ED_CTRL_H]);

	# lat row (row 2): TextCtrl + DDM label
	$this->{ed_lbl_lat} = Wx::StaticText->new($editor_panel, -1, 'Lat',
		[$ED_MARGIN, $ey->(2)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_lat} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(2)], [110, $ED_CTRL_H]);
	$this->{ed_lat_ddm} = Wx::StaticText->new($editor_panel, -1, '',
		[$ED_CTRL_X + 110 + 6, $ey->(2)], [-1, $ED_CTRL_H]);

	# lon row (row 3): TextCtrl + DDM label
	$this->{ed_lbl_lon} = Wx::StaticText->new($editor_panel, -1, 'Lon',
		[$ED_MARGIN, $ey->(3)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_lon} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(3)], [110, $ED_CTRL_H]);
	$this->{ed_lon_ddm} = Wx::StaticText->new($editor_panel, -1, '',
		[$ED_CTRL_X + 110 + 6, $ey->(3)], [-1, $ED_CTRL_H]);

	# wp_type row (row 4)
	$this->{ed_lbl_wp_type} = Wx::StaticText->new($editor_panel, -1, 'Type',
		[$ED_MARGIN, $ey->(4)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_wp_type} = Wx::Choice->new($editor_panel, -1,
		[$ED_CTRL_X, $ey->(4)], [-1, $ED_CTRL_H],
		[$WP_TYPE_NAV, $WP_TYPE_LABEL, $WP_TYPE_SOUNDING]);

	# color row (row 5): swatch + Pick button
	$this->{ed_lbl_color} = Wx::StaticText->new($editor_panel, -1, 'Color',
		[$ED_MARGIN, $ey->(5)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_color_swatch} = Wx::Panel->new($editor_panel, -1,
		[$ED_CTRL_X, $ey->(5) + 1], [28, 20], wxSIMPLE_BORDER);
	$this->{ed_pick_btn} = Wx::Button->new($editor_panel, -1, 'Pick...',
		[$ED_CTRL_X + 28 + 6, $ey->(5)], [-1, $ED_CTRL_H]);

	# depth row (row 6): TextCtrl + unit label
	$this->{ed_lbl_depth} = Wx::StaticText->new($editor_panel, -1, 'Depth',
		[$ED_MARGIN, $ey->(6)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_depth} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(6)], [70, $ED_CTRL_H]);
	my $depth_unit = getPref($PREF_DEPTH_DISPLAY) == $DEPTH_DISPLAY_FEET ? 'ft' : 'm';
	$this->{ed_depth_unit} = Wx::StaticText->new($editor_panel, -1, $depth_unit,
		[$ED_CTRL_X + 70 + 6, $ey->(6)], [-1, $ED_CTRL_H]);

	EVT_SIZE($editor_panel, sub {
		my ($panel, $event) = @_;
		$event->Skip();
		my $w = $panel->GetSize()->GetWidth();
		my $ctrl_w = $w - $this->{_ed_ctrl_x} - $this->{_ed_margin};
		$ctrl_w = 80 if $ctrl_w < 80;
		$this->{ed_name}->SetSize($ctrl_w, $this->{_ed_ctrl_h});
		$this->{ed_comment}->SetSize($ctrl_w, $this->{_ed_ctrl_h});
	});

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

	$right_split->SplitHorizontally($editor_panel, $detail_panel, $ED_INITIAL_SASH);
	$right_split->SetSashGravity(0);

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
	EVT_TREE_ITEM_ACTIVATED($this,     $this->{tree}, \&_onTreeActivated);
	EVT_TREE_ITEM_RIGHT_CLICK($this,   $this->{tree}, \&onTreeRightClick);
	EVT_RIGHT_DOWN($this->{tree},      sub { _onTreeRightDown($this, @_) });

	EVT_MENU($this, $CTX_CMD_DELETE,     \&_onDelete);
	EVT_MENU($this, $CTX_CMD_NEW_BRANCH, \&_onNewBranch);
	EVT_MENU($this, $CTX_CMD_NEW_GROUP,  \&_onNewGroup);
	EVT_MENU($this, $CTX_CMD_SHOW_MAP,   \&_onShowMap);
	EVT_MENU($this, $CTX_CMD_HIDE_MAP,   \&_onHideMap);
	EVT_MENU_RANGE($this, 10010, 10559,  \&_onNmOpsCmd);
	EVT_TEXT($this,   $this->{ed_name},    \&_onFieldChanged);
	EVT_TEXT($this,   $this->{ed_comment}, \&_onFieldChanged);
	EVT_TEXT($this,   $this->{ed_lat},     \&_onLatEdit);
	EVT_TEXT($this,   $this->{ed_lon},     \&_onLonEdit);
	EVT_TEXT($this,   $this->{ed_depth},   \&_onFieldChanged);
	EVT_CHOICE($this, $this->{ed_wp_type}, \&_onFieldChanged);
	EVT_BUTTON($this,   $this->{ed_save},    \&_onSave);
	EVT_BUTTON($this,   $this->{ed_pick_btn}, \&_onColorPick);
	EVT_CHECKBOX($this, $this->{ed_visible},  \&_onEdVisibleChanged);
	EVT_LEFT_DOWN($this->{tree}, sub { _onTreeLeftDown($this, @_) });

	_loadTopLevel($this);

	return $this;
}


#---------------------------------
# initial load - top-level only
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
	my ($ng, $nb, $nw, $nr, $nt) = @{$counts}{qw(groups branches waypoints routes tracks)};
	my $total = $ng + $nb + $nw + $nr + $nt;
	return "$name (empty)" if !$total;
	my @parts;
	push @parts, "$ng " . ($ng==1 ? 'group'  : 'groups')  if $ng;
	push @parts, "$nb " . ($nb==1 ? 'folder' : 'folders') if $nb;
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
	$tree->SetItemState($item, getCollectionVisibleState($dbh, $coll->{uuid}));

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
	$this->{tree}->SetItemState($item, ($obj->{visible} // 0) ? 1 : 0);
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
# selection -> detail
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
		$this->{_edit_item} = $item;
		_loadEditor($this, $dbh, $node);
		_showCollection($dbh, $this, $node->{data});
	}
	elsif ($node->{type} eq 'object')
	{
		$this->{_edit_item} = $item;
		_loadEditor($this, $dbh, $node);
		_showObject($dbh, $this, $node->{data});
	}
	elsif ($node->{type} eq 'route_point')
	{
		$this->{_edit_item} = undef;
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
	$text .= _fmt('position',    $coll->{position});
	$text .= "\n";
	$text .= _fmt('branches',    $counts->{branches});
	$text .= _fmt('groups',      $counts->{groups});
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
		$text .= _fmt('position',        $t->{position});
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
		$text .= _fmt('depth_cm',        $w->{depth_cm});
		$text .= _fmt('created_ts',      $ts);
		$text .= _fmt('ts_source',       $w->{ts_source});
		$text .= _fmt('source',          $w->{source});
		$text .= _fmt('collection_uuid', $w->{collection_uuid});
		$text .= _fmt('position',        $w->{position});
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
		$text .= _fmt('position',        $r->{position});
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
	my ($label, $ctrl, $show) = @_;
	$label->Show($show ? 1 : 0);
	$ctrl->Show($show ? 1 : 0);
}


#---------------------------------
# checkbox state bitmaps
#---------------------------------
# state: 0=unchecked, 1=checked, 2=indeterminate
# ImageList index 0->tree state 1, 1->state 2, 2->state 3

sub _makeCheckBitmap
{
	my ($state) = @_;
	my $bmp = Wx::Bitmap->new(13, 13);
	my $dc  = Wx::MemoryDC->new();
	$dc->SelectObject($bmp);
	$dc->SetBackground(Wx::Brush->new(Wx::Colour->new(255,255,255), wxSOLID));
	$dc->Clear();
	$dc->SetPen(Wx::Pen->new(Wx::Colour->new(100,100,100), 1, wxSOLID));
	$dc->SetBrush(Wx::Brush->new(Wx::Colour->new(255,255,255), wxSOLID));
	$dc->DrawRectangle(1, 1, 11, 11);
	if ($state == 1)
	{
		$dc->SetPen(Wx::Pen->new(Wx::Colour->new(0,0,180), 2, wxSOLID));
		$dc->DrawLine(2, 6, 5, 10);
		$dc->DrawLine(5, 10, 11, 2);
	}
	elsif ($state == 2)
	{
		$dc->SetPen(Wx::Pen->new(Wx::Colour->new(0,0,180), 1, wxSOLID));
		$dc->SetBrush(Wx::Brush->new(Wx::Colour->new(0,0,180), wxSOLID));
		$dc->DrawRectangle(3, 3, 7, 7);
	}
	$dc->SelectObject(wxNullBitmap);
	return $bmp;
}


#---------------------------------
# tree checkbox handling
#---------------------------------

sub _onTreeLeftDown
{
	my ($this, $tree, $event) = @_;
	my ($item, $flags) = $tree->HitTest($event->GetPosition());
	if ($item && $item->IsOk() && ($flags & wxTREE_HITTEST_ONITEMSTATEICON))
	{
		_onCheckboxClick($this, $item);
		return;
	}
	$event->Skip();
}


sub _onCheckboxClick
{
	my ($this, $item) = @_;
	my $item_data = $this->{tree}->GetItemData($item);
	return if !$item_data;
	my $node = $item_data->GetData();
	return if ref $node ne 'HASH';
	return if $node->{type} eq 'root' || $node->{type} eq 'route_point';

	my $cur_state   = $this->{tree}->GetItemState($item);
	my $new_visible = ($cur_state == 1) ? 0 : 1;

	my $dbh = connectDB();
	if ($node->{type} eq 'collection')
	{
		my $uuid = $node->{data}{uuid};
		setCollectionVisibleRecursive($dbh, $uuid, $new_visible);
		$this->{tree}->SetItemState($item, $new_visible ? 1 : 0);
		_refreshLoadedSubtree($this, $item, $new_visible);
		if ($new_visible)
		{
			_pushCollectionToLeaflet($dbh, $this, $uuid);
		}
		else
		{
			_pullCollectionFromLeaflet($dbh, $this, $uuid);
		}
	}
	elsif ($node->{type} eq 'object')
	{
		my $uuid     = $node->{data}{uuid};
		my $obj_type = $node->{data}{obj_type};
		setTerminalVisible($dbh, $uuid, $obj_type, $new_visible);
		$this->{tree}->SetItemState($item, $new_visible ? 1 : 0);
		$node->{data}{visible} = $new_visible;
		if ($new_visible)
		{
			_pushObjToLeaflet($dbh, $this, $node->{data});
		}
		else
		{
			_pullFromLeaflet($this, $uuid);
		}
	}
	_refreshAncestorStates($dbh, $this, $item);

	# sync editor visible checkbox if this item is currently loaded in the editor
	my $node_uuid = $node->{data}{uuid} // '';
	my $edit_uuid = $this->{_edit_uuid} // '';
	if ($node_uuid && $edit_uuid && $node_uuid eq $edit_uuid)
	{
		my $vs = ($node->{type} eq 'collection')
			? getCollectionVisibleState($dbh, $node->{data}{uuid})
			: $new_visible;
		$this->{ed_visible}->Set3StateValue(
			$vs == 1 ? wxCHK_CHECKED :
			$vs == 2 ? wxCHK_UNDETERMINED :
			           wxCHK_UNCHECKED);
	}
	disconnectDB($dbh);
}


sub _refreshAncestorStates
{
	my ($dbh, $this, $item) = @_;
	my $tree   = $this->{tree};
	my $parent = $tree->GetItemParent($item);
	while ($parent && $parent->IsOk())
	{
		my $d = $tree->GetItemData($parent);
		last if !$d;
		my $node = $d->GetData();
		last if ref $node ne 'HASH' || ($node->{type} // '') eq 'root';
		my $uuid = ($node->{data} // {})->{uuid};
		last if !$uuid;
		$tree->SetItemState($parent, getCollectionVisibleState($dbh, $uuid));
		$parent = $tree->GetItemParent($parent);
	}
}


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
	if ($accumulator) { push @$accumulator, @features } else { addRenderFeatures(\@features) if @features }
}


sub _pullFromLeaflet
{
	my ($this, $uuid) = @_;
	return if !$rendered_uuids{$uuid};
	my @children = ref($rendered_uuids{$uuid}) eq 'ARRAY' ? @{$rendered_uuids{$uuid}} : ();
	my @remove   = ($uuid, @children);
	delete $rendered_uuids{$_} for @remove;
	removeRenderFeatures(\@remove);
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
	removeRenderFeatures(\@accumulator) if @accumulator;
}


#---------------------------------
# browser connect / clear map
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
	removeRenderFeatures(\@remove) if @remove;
}


sub onBrowserConnect
{
	my ($this) = @_;
	clearRenderMap();
	$last_clear_version = getClearVersion();
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
# editor visible checkbox
#---------------------------------

sub _onEdVisibleChanged
{
	my ($this, $event) = @_;
	return if $this->{_loading_editor};
	my $uuid     = $this->{_edit_uuid};
	my $type     = $this->{_edit_type};
	my $obj_type = $this->{_edit_obj_type} // '';
	return if !$uuid;

	my $cb = $this->{ed_visible}->Get3StateValue();
	return if $cb == wxCHK_UNDETERMINED;
	my $new_visible = ($cb == wxCHK_CHECKED) ? 1 : 0;

	my $dbh = connectDB();
	if ($type eq 'collection')
	{
		setCollectionVisibleRecursive($dbh, $uuid, $new_visible);
		my $vs = getCollectionVisibleState($dbh, $uuid);
		$this->{ed_visible}->Set3StateValue(
			$vs == 1 ? wxCHK_CHECKED :
			$vs == 2 ? wxCHK_UNDETERMINED :
			           wxCHK_UNCHECKED);
		my $item = $this->{_edit_item};
		if ($item && $item->IsOk())
		{
			$this->{tree}->SetItemState($item, $vs);
			_refreshLoadedSubtree($this, $item, $new_visible);
			_refreshAncestorStates($dbh, $this, $item);
		}
		if ($new_visible) { _pushCollectionToLeaflet($dbh, $this, $uuid) }
		else              { _pullCollectionFromLeaflet($dbh, $this, $uuid) }
	}
	else
	{
		setTerminalVisible($dbh, $uuid, $obj_type, $new_visible);
		my $item = $this->{_edit_item};
		if ($item && $item->IsOk())
		{
			$this->{tree}->SetItemState($item, $new_visible ? 1 : 0);
			_refreshAncestorStates($dbh, $this, $item);
		}
		if ($new_visible) { _pushObjToLeaflet($dbh, $this, { uuid => $uuid, obj_type => $obj_type }) }
		else              { _pullFromLeaflet($this, $uuid) }
	}
	disconnectDB($dbh);
}


sub _clearEditor
{
	my ($this) = @_;
	$this->{_edit_uuid}     = undef;
	$this->{_edit_type}     = undef;
	$this->{_edit_obj_type} = undef;
	$this->{_edit_color}    = undef;
	$this->{_edit_item}     = undef;
	$this->{_editor_dirty}  = 0;
	$this->{ed_title}->SetLabel('');
	$this->{ed_visible}->Show(0);
	_ed_show_row($this->{ed_lbl_name},    $this->{ed_name},        0);
	_ed_show_row($this->{ed_lbl_comment}, $this->{ed_comment},     0);
	_ed_show_row($this->{ed_lbl_lat},     $this->{ed_lat},         0);
	$this->{ed_lat_ddm}->Show(0);
	_ed_show_row($this->{ed_lbl_lon},     $this->{ed_lon},         0);
	$this->{ed_lon_ddm}->Show(0);
	_ed_show_row($this->{ed_lbl_wp_type}, $this->{ed_wp_type},     0);
	_ed_show_row($this->{ed_lbl_color},   $this->{ed_color_swatch},0);
	$this->{ed_pick_btn}->Show(0);
	_ed_show_row($this->{ed_lbl_depth},   $this->{ed_depth},       0);
	$this->{ed_depth_unit}->Show(0);
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
		? (($data->{node_type} // '') eq $NODE_TYPE_GROUP ? 'Group' : 'Branch')
		: ucfirst($obj_type);
	$this->{ed_title}->SetLabel($title);

	_ed_show_row($this->{ed_lbl_name},    $this->{ed_name},         $show_name);
	_ed_show_row($this->{ed_lbl_comment}, $this->{ed_comment},      $show_comment);
	_ed_show_row($this->{ed_lbl_lat},     $this->{ed_lat},          $show_latlon);
	$this->{ed_lat_ddm}->Show($show_latlon ? 1 : 0);
	_ed_show_row($this->{ed_lbl_lon},     $this->{ed_lon},          $show_latlon);
	$this->{ed_lon_ddm}->Show($show_latlon ? 1 : 0);
	_ed_show_row($this->{ed_lbl_wp_type}, $this->{ed_wp_type},      $show_wptype);
	_ed_show_row($this->{ed_lbl_color},   $this->{ed_color_swatch}, $show_color);
	$this->{ed_pick_btn}->Show($show_color ? 1 : 0);
	_ed_show_row($this->{ed_lbl_depth},   $this->{ed_depth},        $show_depth);
	$this->{ed_depth_unit}->Show($show_depth ? 1 : 0);

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

	$this->{ed_visible}->Show(1);
	if ($type eq 'collection')
	{
		my $vs = getCollectionVisibleState($dbh, $uuid);
		$this->{ed_visible}->Set3StateValue(
			$vs == 1 ? wxCHK_CHECKED :
			$vs == 2 ? wxCHK_UNDETERMINED :
			           wxCHK_UNCHECKED);
	}
	else
	{
		$this->{ed_visible}->Set3StateValue(
			($data->{visible} // 0) ? wxCHK_CHECKED : wxCHK_UNCHECKED);
	}

	$this->{_loading_editor} = 0;
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
			warning(0, 0, "invalid lat/lon - save aborted");
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

	if ($type eq 'object' && $rendered_uuids{$uuid})
	{
		_pullFromLeaflet($this, $uuid);
		_pushObjToLeaflet($dbh, $this, { uuid => $uuid, obj_type => $obj_type });
	}

	disconnectDB($dbh);
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
			insertCollection($dbh, $name, $parent_uuid, $NODE_TYPE_BRANCH);
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
			insertCollection($dbh, $name, $parent_uuid, $NODE_TYPE_GROUP);
			disconnectDB($dbh);
			$this->refresh();
		}
	}
	$dlg->Destroy();
}


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
{
	my ($this, $new_visible) = @_;
	my ($case1_colls, $case2_colls, $leaf_nodes) = _analyzeShowHideSelection($this);
	return if !@$case1_colls && !@$case2_colls && !@$leaf_nodes;

	my $dbh = connectDB();
	return if !$dbh;

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
# tree state - expand / select
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

