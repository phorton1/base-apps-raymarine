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
	EVT_KEY_DOWN
	EVT_SIZE);
use Pub::WX::Dialogs;
use POSIX qw(strftime);
use Pub::Utils qw(display warning error);
use Pub::WX::AppConfig qw(readConfig writeConfig);
use Pub::WX::Window;
use Pub::WX::Menu;
use navDB;
use navVisibility qw(getDbVisible setDbVisible);
use navOutline;
use navSelection;
use n_defs;
use n_utils;
use navPrefs;
use navServer;
use navOps qw(buildContextMenu onContextMenuCommand);
use winRename qw($CTX_CMD_RENAME);
use nmResources;
use base 'winTreeBase';
use winDatabase2;

my $DUMMY = '__dummy__';

# Context-menu IDs.  `our` (not `my`) so winDatabase2.pm sees them via
# the shared `package winDatabase;` symbol table.
our $CTX_CMD_SHOW_MAP   = 10560;
our $CTX_CMD_HIDE_MAP   = 10561;
our $CTX_CMD_DELETE     = 10562;
our $CTX_CMD_NEW_BRANCH = 10563;
our $CTX_CMD_NEW_GROUP  = 10564;
our $CTX_CMD_IMPORT_GPS = 10565;
our $CTX_CMD_IMPORT_KML = 10566;
our $CTX_CMD_EXPORT_KML = 10567;
our $CTX_CMD_FIND_THIS  = 10570;
our $CTX_CMD_MULTI_EDIT = 10571;

# Declared and populated in winDatabase2.pm by the Leaflet sync code.
# Re-declared here (no assignment) so `use strict` resolves the
# unqualified reference in _onSave.
our %rendered_uuids;


sub new
{
	my ($class, $frame, $book, $id, $data, $instance) = @_;
	$instance ||= 1;
	my $this = $class->SUPER::new($book, $id);
	$this->MyWindow($frame, $book, $id, "Database $instance", $data, $instance);

	$this->{tree} = Wx::TreeCtrl->new($this, -1, wxDefaultPosition, wxDefaultSize,
		wxTR_DEFAULT_STYLE | wxTR_HIDE_ROOT | wxTR_MULTIPLE);

	# checkbox state images: index 0=unchecked(state 1), 1=checked(state 2), 2=indeterminate(state 3)
	my $state_imgs = Wx::ImageList->new(13, 13);
	$state_imgs->Add(winTreeBase::_makeCheckBitmap(0));
	$state_imgs->Add(winTreeBase::_makeCheckBitmap(1));
	$state_imgs->Add(winTreeBase::_makeCheckBitmap(2));
	$this->{tree}->SetStateImageList($state_imgs);
	$this->{_state_imgs} = $state_imgs;

	# right side is one grey panel: editor widgets at top (packed by the
	# winTreeBase layout walker), single detail TextCtrl below filling
	# the rest.  No inner splitter.
	my $right_panel = Wx::Panel->new($this, -1);
	$right_panel->SetBackgroundColour(
		Wx::SystemSettings::GetColour(wxSYS_COLOUR_BTNFACE));
	$this->{right_panel} = $right_panel;

	# --- editor layout constants ---
	my $ED_MARGIN      = 8;
	my $ED_LABEL_W     = 60;
	my $ED_COL_GAP     = 8;
	my $ED_CTRL_X      = $ED_MARGIN + $ED_LABEL_W + $ED_COL_GAP;
	my $ED_CTRL_H      = 23;
	my $ED_ROW_GAP     = 2;
	my $ED_ROW_H       = $ED_CTRL_H + $ED_ROW_GAP;
	my $ED_HEADER_SIZE = $ED_MARGIN + $ED_ROW_H;
	my $ED_TITLE_W     = 80;
	my $ED_VIS_X       = $ED_CTRL_X + $ED_TITLE_W + 8;
	$this->{_ed_ctrl_x}      = $ED_CTRL_X;
	$this->{_ed_ctrl_h}      = $ED_CTRL_H;
	$this->{_ed_margin}      = $ED_MARGIN;
	$this->{_ed_header_size} = $ED_HEADER_SIZE;
	$this->{_ed_row_h}       = $ED_ROW_H;
	$this->{_ed_bottom_pad}  = $ED_ROW_H;

	# helper: y position of row N (0-based) -- seed coordinates only;
	# the layout walker repositions widgets per item type at load time.
	my $ey = sub { $ED_HEADER_SIZE + $_[0] * $ED_ROW_H };

	# header row: Save button (label col) + bold type title (ctrl col)
	$this->{ed_save} = Wx::Button->new($right_panel, -1, 'Save',
		[$ED_MARGIN, $ED_MARGIN], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_save}->Enable(0);

	$this->{ed_title} = Wx::StaticText->new($right_panel, -1, '',
		[$ED_CTRL_X, $ED_MARGIN], [$ED_TITLE_W, $ED_CTRL_H]);
	$this->{ed_title}->SetFont(
		Wx::Font->new(-1, wxFONTFAMILY_DEFAULT, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_BOLD));

	$this->{ed_visible} = Wx::CheckBox->new($right_panel, -1, 'Visible',
		[$ED_VIS_X, $ED_MARGIN], [-1, $ED_CTRL_H], wxCHK_3STATE);
	$this->{ed_visible}->Show(0);

	$this->{ed_lbl_name} = Wx::StaticText->new($right_panel, -1, 'Name',
		[$ED_MARGIN, $ey->(0)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_name} = Wx::TextCtrl->new($right_panel, -1, '',
		[$ED_CTRL_X, $ey->(0)], [200, $ED_CTRL_H]);

	$this->{ed_lbl_comment} = Wx::StaticText->new($right_panel, -1, 'Comment',
		[$ED_MARGIN, $ey->(1)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_comment} = Wx::TextCtrl->new($right_panel, -1, '',
		[$ED_CTRL_X, $ey->(1)], [200, $ED_CTRL_H]);

	$this->{ed_lbl_lat} = Wx::StaticText->new($right_panel, -1, 'Lat',
		[$ED_MARGIN, $ey->(2)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_lat} = Wx::TextCtrl->new($right_panel, -1, '',
		[$ED_CTRL_X, $ey->(2)], [110, $ED_CTRL_H]);
	$this->{ed_lat_ddm} = Wx::StaticText->new($right_panel, -1, '',
		[$ED_CTRL_X + 110 + 6, $ey->(2)], [-1, $ED_CTRL_H]);

	$this->{ed_lbl_lon} = Wx::StaticText->new($right_panel, -1, 'Lon',
		[$ED_MARGIN, $ey->(3)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_lon} = Wx::TextCtrl->new($right_panel, -1, '',
		[$ED_CTRL_X, $ey->(3)], [110, $ED_CTRL_H]);
	$this->{ed_lon_ddm} = Wx::StaticText->new($right_panel, -1, '',
		[$ED_CTRL_X + 110 + 6, $ey->(3)], [-1, $ED_CTRL_H]);

	$this->{ed_lbl_wp_type} = Wx::StaticText->new($right_panel, -1, 'Type',
		[$ED_MARGIN, $ey->(4)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_wp_type} = Wx::Choice->new($right_panel, -1,
		[$ED_CTRL_X, $ey->(4)], [-1, $ED_CTRL_H],
		[$WP_TYPE_NAV, $WP_TYPE_LABEL, $WP_TYPE_SOUNDING]);

	# color row: E80 named-color choice (primary) + swatch + Pick button
	$this->{ed_lbl_color} = Wx::StaticText->new($right_panel, -1, 'Color',
		[$ED_MARGIN, $ey->(5)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_e80_color} = Wx::Choice->new($right_panel, -1,
		[$ED_CTRL_X, $ey->(5)], [160, $ED_CTRL_H],
		[@E80_ROUTE_COLOR_NAMES, 'Custom']);
	$this->{ed_color_swatch} = Wx::Panel->new($right_panel, -1,
		[$ED_CTRL_X + 160 + 6, $ey->(5)], [28, 20], wxSIMPLE_BORDER);
	$this->{ed_pick_btn} = Wx::Button->new($right_panel, -1, 'Pick...',
		[$ED_CTRL_X + 160 + 6 + 28 + 6, $ey->(5)], [-1, $ED_CTRL_H]);

	$this->{ed_lbl_depth} = Wx::StaticText->new($right_panel, -1, 'Depth',
		[$ED_MARGIN, $ey->(6)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_depth} = Wx::TextCtrl->new($right_panel, -1, '',
		[$ED_CTRL_X, $ey->(6)], [70, $ED_CTRL_H]);
	my $depth_unit = getPref($PREF_DEPTH_DISPLAY) == $DEPTH_DISPLAY_FEET ? 'ft' : 'm';
	$this->{ed_depth_unit} = Wx::StaticText->new($right_panel, -1, $depth_unit,
		[$ED_CTRL_X + 70 + 6, $ey->(6)], [-1, $ED_CTRL_H]);

	# For winDatabase the color row's primary widget is ed_e80_color;
	# ed_color_swatch and ed_pick_btn ride alongside to the right.
	$this->{_ed_field_widgets} = {
		name    => [ 'ed_lbl_name',    'ed_name',         []                                ],
		comment => [ 'ed_lbl_comment', 'ed_comment',      []                                ],
		lat     => [ 'ed_lbl_lat',     'ed_lat',          ['ed_lat_ddm']                    ],
		lon     => [ 'ed_lbl_lon',     'ed_lon',          ['ed_lon_ddm']                    ],
		wp_type => [ 'ed_lbl_wp_type', 'ed_wp_type',      []                                ],
		color   => [ 'ed_lbl_color',   'ed_e80_color',    ['ed_color_swatch', 'ed_pick_btn'] ],
		depth   => [ 'ed_lbl_depth',   'ed_depth',        ['ed_depth_unit']                 ],
	};

	$this->{detail} = Wx::TextCtrl->new($right_panel, -1, '',
		wxDefaultPosition, wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
	$this->{detail}->SetFont(
		Wx::Font->new(9, wxFONTFAMILY_MODERN, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL));

	EVT_SIZE($right_panel, sub {
		my ($panel, $event) = @_;
		$event->Skip();
		my $w = $panel->GetSize()->GetWidth();
		my $ctrl_w = $w - $this->{_ed_ctrl_x} - $this->{_ed_margin};
		$ctrl_w = 80 if $ctrl_w < 80;
		$this->{ed_name}->SetSize($ctrl_w, $this->{_ed_ctrl_h});
		$this->{ed_comment}->SetSize($ctrl_w, $this->{_ed_ctrl_h});
		winTreeBase::_resizeRightPanel($this);
	});

	my $sash = ($data && ref($data) eq 'HASH' && $data->{sash}) ? $data->{sash} : 250;
	$this->SplitVertically($this->{tree}, $right_panel, $sash);
	$this->SetSashGravity(0);

	_clearEditor($this);

	my @outline_uuids = navOutline::getExpanded('db');
	$this->{_expanded_keys} = { map { $_ => 1 } @outline_uuids };
	$this->{_selected_keys} = {};

	# Bind events BEFORE _loadTopLevel so that Expand() calls in _walkRestoreExpanded
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
	EVT_MENU($this, $CTX_CMD_IMPORT_GPS, \&_onImportGPS);
	EVT_MENU($this, $CTX_CMD_IMPORT_KML, \&_onImportKML);
	EVT_MENU($this, $CTX_CMD_EXPORT_KML, \&_onExportKML);
	EVT_MENU($this, $CTX_CMD_FIND_THIS,  \&_onFindThis);
	EVT_MENU($this, $CTX_CMD_MULTI_EDIT, \&_onMultiEdit);
	EVT_MENU($this, $CTX_CMD_RENAME,     \&_onRename);
	EVT_MENU_RANGE($this, 10200, 10299,  \&_onNmOpsCmd);
	EVT_TEXT($this,   $this->{ed_name},    $this->can('_onFieldChanged'));
	EVT_TEXT($this,   $this->{ed_comment}, $this->can('_onFieldChanged'));
	EVT_TEXT($this,   $this->{ed_lat},     $this->can('_onLatEdit'));
	EVT_TEXT($this,   $this->{ed_lon},     $this->can('_onLonEdit'));
	EVT_TEXT($this,   $this->{ed_depth},   $this->can('_onFieldChanged'));
	EVT_CHOICE($this, $this->{ed_wp_type}, $this->can('_onFieldChanged'));
	EVT_CHOICE($this, $this->{ed_e80_color}, \&_onE80ColorChoice);
	EVT_BUTTON($this,   $this->{ed_save},    \&_onSave);
	EVT_BUTTON($this,   $this->{ed_pick_btn}, \&_onColorPick);
	EVT_CHECKBOX($this, $this->{ed_visible},  \&_onEdVisibleChanged);
	EVT_LEFT_DOWN($this->{tree}, sub { $this->_onTreeLeftDown(@_) });
	EVT_KEY_DOWN($this->{tree},  sub { _onTreeKeyDown($this, @_) });

	_loadTopLevel($this);

	$this->installVisibilityObserver();

	return $this;
}


#---------------------------------
# visibility observer overrides
#---------------------------------
# winDatabase's tree shape and container-state model differ from the base:
#   - node uuid lives at $node->{data}{uuid}, not $node->{uuid}
#   - containers are 'collection' nodes, possibly lazy-loaded
#   - container state comes from the DB via getCollectionVisibleState, not
#     from walking the loaded tree (would be wrong when children aren't yet
#     loaded)
#
# Also: the base observer body's editor-checkbox sync only matches when
# _edit_uuid is in the delta directly.  For a DB collection edit, the delta
# carries the collection's descendant UUIDs, not the collection's own UUID.
# We override _onVisibilityDelta to add a "re-band edited collection" pass
# at the end.

sub _wpDataSource { 'db' }


sub _visObserverNodeUuid
{
	my ($this, $node) = @_;
	return ($node->{data} // {})->{uuid};
}


sub _visObserverIsContainer
{
	my ($this, $node) = @_;
	return ($node->{type} // '') eq 'collection';
}


sub _visObserverComputeContainerState
{
	my ($this, $item, $node) = @_;
	my $uuid = ($node->{data} // {})->{uuid};
	return 0 if !$uuid;
	my $dbh = connectDB();
	return 0 if !$dbh;
	my $vs = getCollectionVisibleState($dbh, $uuid);
	disconnectDB($dbh);
	return $vs;
}


sub _onVisibilityDelta
{
	my ($this, $delta) = @_;
	my $changes = $delta->{db};
	return if !$changes;
	my $tree = $this->{tree};
	return if !$tree || $tree->GetCount() <= 0;

	$tree->Freeze();
	eval {
		winTreeBase::_walkApplyVisDelta($this, $tree, $tree->GetRootItem(), $changes);

		# Editor checkbox sync.  Two cases:
		#   - edited item is a leaf in the delta -> set from delta value
		#   - edited item is a collection whose descendants are in the delta
		#     -> recompute via getCollectionVisibleState
		my $edit_uuid = $this->{_edit_uuid} // '';
		my $edit_type = $this->{_edit_type} // '';
		if ($edit_uuid && $this->{ed_visible})
		{
			$this->{_loading_editor} = 1;
			if (exists $changes->{$edit_uuid})
			{
				$this->{ed_visible}->Set3StateValue(
					$changes->{$edit_uuid} ? wxCHK_CHECKED : wxCHK_UNCHECKED);
			}
			elsif ($edit_type eq 'collection')
			{
				my $dbh = connectDB();
				if ($dbh)
				{
					my $vs = getCollectionVisibleState($dbh, $edit_uuid);
					disconnectDB($dbh);
					$this->{ed_visible}->Set3StateValue(
						$vs == 1 ? wxCHK_CHECKED :
						$vs == 2 ? wxCHK_UNDETERMINED :
						           wxCHK_UNCHECKED);
				}
			}
			$this->{_loading_editor} = 0;
		}
	};
	my $err = $@;
	$tree->Thaw();
	error("winDatabase::_onVisibilityDelta: $err") if $err;
}


#---------------------------------
# focusOnObject override (lazy expand on the way down)
#---------------------------------
# The base implementation walks the currently-loaded tree only.  DB
# collections are lazy-loaded -- their children appear only after the
# collection's EVT_TREE_ITEM_EXPANDING fires.  So for a freshly-opened
# winDatabase the target leaf isn't in the tree yet.  We resolve the
# leaf's parent chain via the DB (collection_uuid + parent_uuid links),
# expand each ancestor top-down (Expand triggers lazy-load synchronously),
# then re-run the base finder on the now-populated subtree.

sub focusOnObject
{
	my ($this, $uuid, $obj_type) = @_;
	return 0 if !$uuid;
	my $tree = $this->{tree};
	return 0 if !$tree;

	# Fast path: if the item is already loaded, just select it.
	my $found = winTreeBase::_findItemByUuid($tree, $tree->GetRootItem(), $uuid);
	if (!($found && $found->IsOk()))
	{
		# Resolve parent chain via DB.
		my $dbh = connectDB();
		return 0 if !$dbh;

		my $parent_uuid;
		if    ($obj_type eq 'waypoint') { my $r = $dbh->get_record("SELECT collection_uuid FROM waypoints WHERE uuid=?", [$uuid]); $parent_uuid = $r ? $r->{collection_uuid} : undef; }
		elsif ($obj_type eq 'track')    { my $r = $dbh->get_record("SELECT collection_uuid FROM tracks    WHERE uuid=?", [$uuid]); $parent_uuid = $r ? $r->{collection_uuid} : undef; }
		elsif ($obj_type eq 'route')    { my $r = $dbh->get_record("SELECT collection_uuid FROM routes    WHERE uuid=?", [$uuid]); $parent_uuid = $r ? $r->{collection_uuid} : undef; }

		my @chain;
		my $cur = $parent_uuid;
		my %seen;
		while ($cur && !$seen{$cur})
		{
			$seen{$cur} = 1;
			unshift @chain, $cur;
			my $rec = $dbh->get_record("SELECT parent_uuid FROM collections WHERE uuid=?", [$cur]);
			last if !$rec;
			$cur = $rec->{parent_uuid};
		}
		disconnectDB($dbh);

		# Walk down, expanding each ancestor in turn.  Expand() fires
		# EVT_TREE_ITEM_EXPANDING synchronously, which lazy-loads the
		# direct children.  After each expand, the next ancestor is
		# guaranteed loaded as a direct child of $cur_item.
		my $cur_item = $tree->GetRootItem();
		$tree->Freeze();
		eval {
			for my $coll_uuid (@chain)
			{
				my $next = winTreeBase::_findItemByUuid($tree, $cur_item, $coll_uuid);
				last if !$next || !$next->IsOk();
				$tree->Expand($next);
				$cur_item = $next;
			}
		};
		my $err = $@;
		$tree->Thaw();
		error("focusOnObject expand walk: $err") if $err;

		$found = winTreeBase::_findItemByUuid($tree, $cur_item, $uuid);
	}

	return 0 if !$found || !$found->IsOk();

	$tree->UnselectAll();
	$tree->SelectItem($found, 1);
	$tree->EnsureVisible($found);

	my $book = $this->{book};
	if ($book)
	{
		for my $i (0 .. $book->GetPageCount() - 1)
		{
			if ($book->GetPage($i) == $this)
			{
				$book->SetSelection($i);
				last;
			}
		}
	}
	return 1;
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

	# Expand() fires EVT_TREE_ITEM_EXPANDING synchronously regardless of Freeze
	# state (wx Freeze suspends repaints, not event delivery), so onTreeExpanding
	# replaces the DUMMY child with real entries before the recursion descends
	# into them. Keeping the restoration inside Freeze avoids per-Expand
	# repaints; the outer Freeze in refresh() guarantees a single repaint at
	# the end. When _loadTopLevel is called from new() with no outer Freeze,
	# our own Freeze/Thaw here still covers the restoration.
	winTreeBase::_walkRestoreExpanded($tree, $root, $this->{_expanded_keys});
	winTreeBase::_walkRestoreSelected($tree, $root, $this->{_selected_keys});
	winTreeBase::_walkRestoreFirstVisible($tree, $root, $this->{_first_visible_key});
	$tree->Thaw();
}


sub refresh
{
	my ($this) = @_;
	my $tree = $this->{tree};
	# Suspend repaints across the entire refresh -- capture, clear, rebuild,
	# expand restoration, select restoration, and cut styling. Without this,
	# every Expand() call during _walkRestoreExpanded fires its own repaint as
	# each lazy-loaded sub-branch's children appear, producing the visible
	# flicker and scrolling that automated tests provoke. Freeze/Thaw is a
	# refcount in wx, so the inner Freeze in _loadTopLevel nests harmlessly.
	$tree->Freeze();
	eval {
		if ($tree->GetCount() > 0)
		{
			$this->_captureExpandedInto();
			$this->_captureSelectedInto();
			$this->_captureFirstVisibleInto();
		}
		_clearEditor($this);
		$this->{detail}->SetValue('');
		_loadTopLevel($this);
		_applyCutStyle($this);
	};
	my $err = $@;
	$tree->Thaw();
	error("winDatabase::refresh: $err") if $err;
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
	my $vis = getDbVisible($obj->{uuid});
	$obj->{visible} = $vis;
	my $item = $this->{tree}->AppendItem($parent, $label, -1, -1,
		Wx::TreeItemData->new({ type => 'object', data => $obj }));
	$this->{tree}->SetItemState($item, $vis ? 1 : 0);
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
	_applyCutStyle($this);
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

	# DB renderer: render sub-collections and direct objects in a single
	# position-sorted list. The schema's per-row position is the unified
	# ordering axis; collections-first / objects-after is the E80 panel's
	# rule, not the DB's. (winE80 keeps its own type-segregated renderer
	# since the E80 has no positions to honor.)
	my $children = getContainerChildren($dbh, $coll_uuid);
	for my $child (@$children)
	{
		if (($child->{kind} // '') eq 'collection')
		{
			_addCollectionItem($dbh, $this, $parent_item, $child);
		}
		else
		{
			_addObjectItem($dbh, $this, $parent_item, $child);
		}
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


sub _fmt_ts
{
	my ($ts) = @_;
	return $ts
		? strftime("%Y-%m-%d %H:%M UTC", gmtime($ts))
		: '(none)';
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
	$text .= _fmt('source',      $coll->{source});
	$text .= _fmt('created_ts',  _fmt_ts($coll->{created_ts}));
	$text .= _fmt('modified_ts', _fmt_ts($coll->{modified_ts}));
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
		$text .= _fmt('uuid',            ($t->{uuid} // '') . '  {mta_uuid}');
		$text .= _fmt('companion_uuid',  $t->{companion_uuid}) if $t->{companion_uuid};
		$text .= _fmt('name',            $t->{name});
		$text .= _fmt('color',           $t->{color});
		$text .= _fmt('ts_start',        $ts_start);
		$text .= _fmt('ts_end',          $ts_end);
		$text .= _fmt('ts_source',       $t->{ts_source});
		$text .= _fmt('point_count',     $t->{point_count});
		$text .= _fmt('collection_uuid', $t->{collection_uuid});
		$text .= _fmt('position',        $t->{position});
		$text .= _fmt('source',          $t->{source});
		$text .= _fmt('created_ts',      _fmt_ts($t->{created_ts}));
		$text .= _fmt('modified_ts',     _fmt_ts($t->{modified_ts}));
		my $pts = getTrackPoints($dbh, $t->{uuid});
		if (@$pts)
		{
			$text .= "\n";
			for my $i (0 .. $#$pts)
			{
				my $pt   = $pts->[$i];
				my $d_ft = ($pt->{depth_cm} // 0) ? sprintf('%.1fft', $pt->{depth_cm} / 30.48) : '-';
				my $t_f  = ($pt->{temp_k}   // 0) ? sprintf('%.1fF', ($pt->{temp_k} / 100 - 273) * 9 / 5 + 32) : '-';
				my $ts_s = ($pt->{ts} // 0) ? strftime("%Y-%m-%d %H:%M:%S UTC", gmtime($pt->{ts})) : '-';
				$text .= sprintf("  %2d  %9.6f  %10.6f  %7s  %6s  %s\n",
					$i + 1, $pt->{lat} // 0, $pt->{lon} // 0, $d_ft, $t_f, $ts_s);
			}
		}
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
		$text .= _fmt('temp_k', sprintf('%d  (%.1f F)', $w->{temp_k}, ($w->{temp_k} / 100 - 273) * 9 / 5 + 32))
			if $w->{temp_k};
		$text .= _fmt('created_ts',      $ts);
		$text .= _fmt('ts_source',       $w->{ts_source});
		$text .= _fmt('source',          $w->{source});
		$text .= _fmt('collection_uuid', $w->{collection_uuid});
		$text .= _fmt('position',        $w->{position});
		$text .= _fmt('modified_ts',     _fmt_ts($w->{modified_ts}));
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
		$text .= _fmt('source',          $r->{source});
		$text .= _fmt('created_ts',      _fmt_ts($r->{created_ts}));
		$text .= _fmt('modified_ts',     _fmt_ts($r->{modified_ts}));
		$text .= "\n";
		for my $i (0 .. $#$wps)
		{
			my $wp = $wps->[$i];
			$text .= sprintf("  %2d. %s\n", $i + 1, $wp->{name} // '');
			$text .= sprintf("      %s\n", formatLatLon($wp->{lat}, 1));
			$text .= sprintf("      %s\n", formatLatLon($wp->{lon}, 0));
		}
	}

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

#---------------------------------
# tree checkbox handling
#---------------------------------
# _makeCheckBitmap and _onTreeLeftDown are inherited from winTreeBase.

sub _onCheckboxClick
{
	my ($this, $item) = @_;
	my $item_data = $this->{tree}->GetItemData($item);
	return if !$item_data;
	my $node = $item_data->GetData();
	return if ref $node ne 'HASH';
	return if $node->{type} eq 'root' || $node->{type} eq 'route_point';

	my $cur_state   = $this->{tree}->GetItemState($item);
	# Click cycle on a tristate container: none -> all -> none -> all,
	# mixed -> none -> all.  See matching comment in winTreeBase::_onCheckboxClick.
	my $new_visible = ($cur_state == 0) ? 1 : 0;

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
	$this->_layoutEditor( []);
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
	my $show_color    = ($obj_type eq 'waypoint'
		|| $obj_type eq 'route' || $obj_type eq 'track');
	my $show_e80_color = ($obj_type eq 'route' || $obj_type eq 'track');
	my $show_depth    = ($obj_type eq 'waypoint');

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

	my @fields;
	push @fields, 'name'    if $show_name;
	push @fields, 'comment' if $show_comment;
	push @fields, 'lat'     if $show_latlon;
	push @fields, 'lon'     if $show_latlon;
	push @fields, 'wp_type' if $show_wptype;
	push @fields, 'color'   if $show_color;
	push @fields, 'depth'   if $show_depth;
	$this->_layoutEditor( \@fields);
	# ed_e80_color is a companion of 'color' but is hidden for waypoints
	# (route/track use the named-color choice; waypoint uses Pick... only).
	$this->{ed_e80_color}->Show(0) if !$show_e80_color;

	$this->{_loading_editor} = 1;

	$this->{ed_name}->SetValue($data->{name} // '')       if $show_name;
	$this->{ed_comment}->SetValue($data->{comment} // '') if $show_comment;

	if ($show_latlon)
	{
		$this->{ed_lat}->SetValue(defined $data->{lat} ? sprintf('%.6f', $data->{lat}) : '');
		$this->{ed_lon}->SetValue(defined $data->{lon} ? sprintf('%.6f', $data->{lon}) : '');
		$this->_updateLatDDM();
		$this->_updateLonDDM();
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
			getDbVisible($data->{uuid} // '') ? wxCHK_CHECKED : wxCHK_UNCHECKED);
	}

	$this->{_loading_editor} = 0;
	$this->{ed_save}->Enable(0);
}


# _onFieldChanged, _onLatEdit, _onLonEdit, _updateLatDDM, _updateLonDDM,
# _ddm_label are inherited from winTreeBase.

sub _setColorSwatch
{
	my ($this, $color) = @_;
	$this->{_edit_color} = $color;
	if (defined $color && $color =~ /^[0-9a-fA-F]{8}$/)
	{
		my $rr = hex(substr($color, 6, 2));
		my $gg = hex(substr($color, 4, 2));
		my $bb = hex(substr($color, 2, 2));
		# E80 index 5 is named BLACK in the protocol but its ABGR is ffffffff
		# (rendered white-on-map). Display the swatch as literal black to
		# match the protocol name.
		if (lc($color) eq 'ffffffff') { ($rr, $gg, $bb) = (0, 0, 0); }
		$this->{ed_color_swatch}->SetBackgroundColour(Wx::Colour->new($rr, $gg, $bb));
	}
	else
	{
		$this->{ed_color_swatch}->SetBackgroundColour(Wx::Colour->new(192, 192, 192));
	}
	$this->{ed_color_swatch}->Refresh();
	if ($this->{ed_e80_color}->IsShown())
	{
		my $sel = (defined $color && isExactE80Color($color))
			? abgrToE80Index($color)
			: scalar(@E80_ROUTE_COLOR_NAMES);  # Custom
		$this->{ed_e80_color}->SetSelection($sel);
	}
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


sub _onE80ColorChoice
{
	my ($this, $event) = @_;
	return if $this->{_loading_editor};
	my $sel = $this->{ed_e80_color}->GetSelection();
	return if $sel >= scalar(@E80_ROUTE_COLOR_NAMES);  # Custom
	_setColorSwatch($this, $E80_ROUTE_COLOR_ABGR[$sel]);
	$this->{_editor_dirty} = 1;
	$this->{ed_save}->Enable(1);
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
# ini persistence
#---------------------------------

sub getDataForIniFile
{
	my ($this) = @_;
	return { sash => $this->GetSashPosition() };
}


#---------------------------------
# tree state - expand / select
#---------------------------------
# _nodeKey, _captureExpandedInto, _walkExpCapture, _captureSelectedInto,
# _walkRestoreExpanded, _walkRestoreSelected are inherited from winTreeBase.
# winTreeBase::_nodeKey's fallback handles DB nodes via $node->{data}{uuid}.


#---------------------------------
# outline / selection persistence
#---------------------------------

sub doSaveOutline
{
	my ($this) = @_;
	$this->_captureExpandedInto();
	my @uuids = sort keys %{$this->{_expanded_keys}};
	navOutline::setExpanded('db', \@uuids);
	navOutline::saveOutline('db');
}


sub doRestoreOutline
{
	my ($this) = @_;
	my @uuids = navOutline::getExpanded('db');
	$this->{_expanded_keys} = { map { $_ => 1 } @uuids };
	_clearEditor($this);
	$this->{detail}->SetValue('');
	_loadTopLevel($this);
}


sub doSaveSelection
{
	my ($this, $name) = @_;
	$this->_captureSelectedInto();
	my @uuids = sort keys %{$this->{_selected_keys}};
	navSelection::putSelectionSet($name, \@uuids);
}


sub doRestoreSelection
{
	my ($this, $name) = @_;
	my $uuids_ref = navSelection::getSelectionSet($name);
	return if !@$uuids_ref;
	$this->{_selected_keys} = { map { $_ => 1 } @$uuids_ref };
	my $tree = $this->{tree};
	$tree->UnselectAll();
	winTreeBase::_walkRestoreSelected($tree, $tree->GetRootItem(), $this->{_selected_keys});
}


1;

