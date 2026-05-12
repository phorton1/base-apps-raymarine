#!/usr/bin/perl
#-------------------------------------------------------------------------
# winE80.pm
#-------------------------------------------------------------------------
# Read-only live view of the E80's WPMGR + TRACK contents.
#
# Tree structure mirrors the E80's own organization:
#   Groups
#     My Waypoints  (synthesized: waypoints not in any named group)
#       waypoint ...
#     named group ...
#       waypoint ...
#   Routes
#     route ...
#   Tracks
#     track ...
#
# Refresh is triggered by nmFrame::onIdle whenever the global NET version
# increments (i.e. any WPMGR or TRACK item changes).

package winE80;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::Local qw(timegm);
use Wx qw(:everything);
use Wx::DateTime;
use Wx::Calendar;
use Wx::Event qw(
	EVT_TREE_SEL_CHANGED
	EVT_TREE_ITEM_ACTIVATED
	EVT_TREE_ITEM_RIGHT_CLICK
	EVT_LEFT_DOWN
	EVT_KEY_DOWN
	EVT_MENU
	EVT_MENU_RANGE
	EVT_TEXT
	EVT_BUTTON
	EVT_CHOICE
	EVT_CHECKBOX
	EVT_DATE_CHANGED
	EVT_SIZE);
use Pub::Utils qw(display warning error);
use Pub::WX::Window;
use apps::raymarine::NET::b_records qw(wpmgrRecordToText);
use apps::raymarine::NET::c_RAYDP;
use n_defs;
use n_utils;
use navOps qw(buildContextMenu onContextMenuCommand doClearE80DB);
use navServer qw(addRenderFeatures removeRenderFeatures openMapBrowser isBrowserConnected);
use navVisibility qw(getE80Visible setE80Visible clearAllE80Visible getAllE80VisibleUUIDs batchRemoveE80Visible);
use nmResources;
use navPrefs;
use base 'winTreeBase';

our $dbg_wine80 = 0;
my $CUT_COLOR;

my $CTX_CMD_SHOW_MAP = 10560;
my $CTX_CMD_HIDE_MAP = 10561;


sub new
{
	my ($class, $frame, $book, $id, $data) = @_;
	my $this = $class->SUPER::new($book, $id);
	$this->MyWindow($frame, $book, $id, 'E80', $data);

	$this->{tree} = Wx::TreeCtrl->new($this, -1, wxDefaultPosition, wxDefaultSize,
		wxTR_DEFAULT_STYLE | wxTR_HIDE_ROOT | wxTR_MULTIPLE);

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
	my $ED_MAX_ROWS      = 6;
	my $ED_TITLE_W       = 80;
	my $ED_VIS_X         = $ED_CTRL_X + $ED_TITLE_W + 8;
	$this->{_ed_ctrl_x}  = $ED_CTRL_X;
	$this->{_ed_ctrl_h}  = $ED_CTRL_H;
	$this->{_ed_margin}  = $ED_MARGIN;

	my $ED_INITIAL_SASH  = $ED_HEADER_SIZE + $ED_MAX_ROWS * $ED_ROW_H + $ED_BOTTOM_MARGIN;
	my $ED_WP_ROWS       = 9;
	$this->{_ed_sash_other} = $ED_INITIAL_SASH;
	$this->{_ed_sash_wp}    = $ED_HEADER_SIZE + $ED_WP_ROWS * $ED_ROW_H + $ED_BOTTOM_MARGIN;

	my $ey = sub { $ED_HEADER_SIZE + $_[0] * $ED_ROW_H };

	# --- editor panel ---
	my $editor_panel = Wx::Panel->new($right_split, -1);
	$this->{editor_panel} = $editor_panel;

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
	$this->{ed_name}->SetMaxLength(15);

	# comment row (row 1) - waypoint, group, route
	$this->{ed_lbl_comment} = Wx::StaticText->new($editor_panel, -1, 'Comment',
		[$ED_MARGIN, $ey->(1)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_comment} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(1)], [200, $ED_CTRL_H]);
	$this->{ed_comment}->SetMaxLength(31);

	# lat row (row 2)
	$this->{ed_lbl_lat} = Wx::StaticText->new($editor_panel, -1, 'Lat',
		[$ED_MARGIN, $ey->(2)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_lat} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(2)], [110, $ED_CTRL_H]);
	$this->{ed_lat_ddm} = Wx::StaticText->new($editor_panel, -1, '',
		[$ED_CTRL_X + 110 + 6, $ey->(2)], [-1, $ED_CTRL_H]);

	# lon row (row 3)
	$this->{ed_lbl_lon} = Wx::StaticText->new($editor_panel, -1, 'Lon',
		[$ED_MARGIN, $ey->(3)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_lon} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(3)], [110, $ED_CTRL_H]);
	$this->{ed_lon_ddm} = Wx::StaticText->new($editor_panel, -1, '',
		[$ED_CTRL_X + 110 + 6, $ey->(3)], [-1, $ED_CTRL_H]);

	# sym row (row 4) - waypoint symbol index 0-39
	$this->{ed_lbl_sym} = Wx::StaticText->new($editor_panel, -1, 'Sym',
		[$ED_MARGIN, $ey->(4)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_sym} = Wx::Choice->new($editor_panel, -1,
		[$ED_CTRL_X, $ey->(4)], [-1, $ED_CTRL_H],
		[map { sprintf('%2d - %s', $_, $apps::raymarine::NET::a_utils::WPICON_TABLE[$_][0]) }
		 0..$#apps::raymarine::NET::a_utils::WPICON_TABLE]);

	# color row (row 5) - route color index 0-5
	$this->{ed_lbl_color} = Wx::StaticText->new($editor_panel, -1, 'Color',
		[$ED_MARGIN, $ey->(5)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_color_choice} = Wx::Choice->new($editor_panel, -1,
		[$ED_CTRL_X, $ey->(5)], [-1, $ED_CTRL_H],
		[@E80_ROUTE_COLOR_NAMES]);

	# depth row (row 5, same as color - mutually exclusive) - waypoint only; wire value is cm (int32)
	$this->{ed_lbl_depth} = Wx::StaticText->new($editor_panel, -1, 'Depth',
		[$ED_MARGIN, $ey->(5)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_depth} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(5)], [80, $ED_CTRL_H]);
	$this->{ed_depth_unit} = Wx::StaticText->new($editor_panel, -1, '',
		[$ED_CTRL_X + 86, $ey->(5)], [-1, $ED_CTRL_H]);

	# temp row (row 6) - waypoint only; wire value is Kelvin * 100 (uint16)
	$this->{ed_lbl_temp} = Wx::StaticText->new($editor_panel, -1, 'Temp',
		[$ED_MARGIN, $ey->(6)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_temp} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(6)], [80, $ED_CTRL_H]);
	$this->{ed_temp_unit} = Wx::StaticText->new($editor_panel, -1, '',
		[$ED_CTRL_X + 86, $ey->(6)], [-1, $ED_CTRL_H]);

	# date row (row 7) - waypoint only; wire value is days since 1970-01-01 (uint16)
	$this->{ed_lbl_date} = Wx::StaticText->new($editor_panel, -1, 'Date',
		[$ED_MARGIN, $ey->(7)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_date} = Wx::DatePickerCtrl->new($editor_panel, -1,
		Wx::DateTime::Today(), [$ED_CTRL_X, $ey->(7)], [-1, $ED_CTRL_H],
		wxDP_DROPDOWN | wxDP_SHOWCENTURY);

	# time row (row 8) - waypoint only; wire value is seconds since midnight (uint32)
	$this->{ed_lbl_time} = Wx::StaticText->new($editor_panel, -1, 'Time',
		[$ED_MARGIN, $ey->(8)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_time} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(8)], [80, $ED_CTRL_H]);

	EVT_SIZE($editor_panel, sub {
		my ($panel, $event) = @_;
		$event->Skip();
		my $w = $panel->GetSize()->GetWidth();
		my $ctrl_w = $w - $this->{_ed_ctrl_x} - $this->{_ed_margin};
		$ctrl_w = 80 if $ctrl_w < 80;
		$this->{ed_name}->SetSize($ctrl_w, $this->{_ed_ctrl_h});
		$this->{ed_comment}->SetSize($ctrl_w, $this->{_ed_ctrl_h});
	});

	$this->_clearEditor();

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

	my $state_imgs = Wx::ImageList->new(13, 13);
	$state_imgs->Add(winTreeBase::_makeCheckBitmap(0));
	$state_imgs->Add(winTreeBase::_makeCheckBitmap(1));
	$state_imgs->Add(winTreeBase::_makeCheckBitmap(2));
	$this->{tree}->SetStateImageList($state_imgs);
	$this->{_state_imgs} = $state_imgs;

	EVT_TREE_SEL_CHANGED($this,      $this->{tree}, \&onTreeSelect);
	EVT_TREE_ITEM_ACTIVATED($this,   $this->{tree}, \&_onTreeActivated);
	EVT_TREE_ITEM_RIGHT_CLICK($this, $this->{tree}, \&onTreeRightClick);
	EVT_LEFT_DOWN($this->{tree},     sub { $this->_onTreeLeftDown(@_) });
	EVT_KEY_DOWN($this->{tree},      sub { _onTreeKeyDown($this, @_) });
	EVT_MENU($this, $COMMAND_REFRESH_WIN_E80, sub { refresh($_[0]) });
	EVT_MENU($this, $COMMAND_CLEAR_E80_DB,   sub { doClearE80DB($_[0]->{tree}) });
	EVT_MENU($this, $CTX_CMD_SHOW_MAP,       \&_onShowMap);
	EVT_MENU($this, $CTX_CMD_HIDE_MAP,       \&_onHideMap);
	EVT_MENU_RANGE($this, 10200, 10299, \&_onNmOpsCmd);
	EVT_TEXT($this,   $this->{ed_name},         $this->can('_onFieldChanged'));
	EVT_TEXT($this,   $this->{ed_lat},          $this->can('_onLatEdit'));
	EVT_TEXT($this,   $this->{ed_lon},          $this->can('_onLonEdit'));
	EVT_CHOICE($this, $this->{ed_sym},          $this->can('_onFieldChanged'));
	EVT_CHOICE($this, $this->{ed_color_choice}, $this->can('_onFieldChanged'));
	EVT_TEXT($this,         $this->{ed_comment}, $this->can('_onFieldChanged'));
	EVT_TEXT($this,         $this->{ed_depth},   $this->can('_onFieldChanged'));
	EVT_TEXT($this,         $this->{ed_temp},    $this->can('_onFieldChanged'));
	EVT_TEXT($this,         $this->{ed_time},    $this->can('_onFieldChanged'));
	EVT_DATE_CHANGED($this, $this->{ed_date},    $this->can('_onFieldChanged'));
	EVT_BUTTON($this,   $this->{ed_save},       \&_onSave);
	EVT_CHECKBOX($this, $this->{ed_visible},    $this->can('_onEdVisibleChanged'));

	$this->{_expanded_keys} = {
		'header:groups' => 1,
		'header:routes' => 1,
		'header:tracks' => 1,
	};
	if ($data && ref($data) eq 'HASH' && $data->{expanded})
	{
		$this->{_expanded_keys}{$_} = 1 for split(/,/, $data->{expanded});
	}
	$this->{_selected_keys} = {};
	$this->{_e80_loaded}    = 0;

	return $this;
}


#---------------------------------
# build / refresh tree
#---------------------------------

sub onActivate
{
	my ($this) = @_;
	$this->onSessionStart() if !$this->{_e80_loaded};
}


sub onSessionStart
{
	my ($this) = @_;
	if ($this->{_e80_loaded} && $this->{tree}->GetCount() > 0)
	{
		$this->_captureExpandedInto();
		$this->_captureSelectedInto();
	}
	_buildAndRestore($this);
}


sub refresh
{
	my ($this) = @_;
	return if !$this->{_e80_loaded};
	display($dbg_wine80+1,0,"winE80::refresh triggered");
	if ($this->{tree}->GetCount() > 0)
	{
		$this->_captureExpandedInto();
		$this->_captureSelectedInto();
	}
	_buildAndRestore($this);
	_applyCutStyle($this);
}


sub _buildAndRestore
{
	my ($this) = @_;
	my $tree      = $this->{tree};
	my $wpmgr     = $raydp ? $raydp->findImplementedService('WPMGR', 1) : undef;
	my $track_mgr = $raydp ? $raydp->findImplementedService('TRACK', 1) : undef;

	return if !$tree;
	$tree->DeleteAllItems();
	$this->{detail}->SetValue('');

	if (!$wpmgr)
	{
		my $root = $tree->AddRoot('E80');
		my $e80_item = $tree->AppendItem($root, 'E80', -1, -1,
			Wx::TreeItemData->new({ type => 'root', data => { uuid => undef, name => 'E80' } }));
		$tree->SetItemBold($e80_item, 1);
		$tree->AppendItem($root, '(WPMGR not connected)');
		$this->{_e80_loaded} = 0;
		return;
	}

	my $wps    = $wpmgr->{waypoints} // {};
	my $groups = $wpmgr->{groups}    // {};
	my $routes = $wpmgr->{routes}    // {};
	display($dbg_wine80,0,"winE80::_buildAndRestore wps=".scalar(keys %$wps).
		" groups=".scalar(keys %$groups)." routes=".scalar(keys %$routes));

	my $root = $tree->AddRoot('E80');
	my $e80_item = $tree->AppendItem($root, 'E80', -1, -1,
		Wx::TreeItemData->new({ type => 'root', data => { uuid => undef, name => 'E80' } }));
	$tree->SetItemBold($e80_item, 1);
	_buildGroups($this, $tree, $root, $wpmgr);
	_buildRoutes($this, $tree, $root, $wpmgr);
	_buildTracks($this, $tree, $root, $track_mgr);

	$this->{_e80_loaded} = 1;
	$tree->Expand($root);
	winTreeBase::_walkRestoreExpanded($tree, $root, $this->{_expanded_keys});
	winTreeBase::_walkRestoreSelected($tree, $root, $this->{_selected_keys});
	winTreeBase::_walkRestoreStateImages($this, $tree, $root);
	$this->_syncLeafletAfterRebuild();
}


sub _buildGroups
{
	my ($this, $tree, $root, $wpmgr) = @_;
	my $wps    = $wpmgr->{waypoints} // {};
	my $groups = $wpmgr->{groups}    // {};

	# find which waypoint UUIDs are claimed by a named group
	my %grouped;
	for my $uuid (keys %$groups)
	{
		$grouped{$_} = 1 for @{$groups->{$uuid}{uuids} // []};
	}

	my @ungrouped = sort { winTreeBase::_name_sort_key($wps->{$a}{name}) cmp winTreeBase::_name_sort_key($wps->{$b}{name}) }
	                grep { !$grouped{$_} } keys %$wps;

	my $hdr = $tree->AppendItem($root, 'Groups', -1, -1,
		Wx::TreeItemData->new({ type => 'header', kind => 'groups' }));

	# My Waypoints -- synthesized, always first
	if (@ungrouped)
	{
		my $n = scalar @ungrouped;
		my $mw = $tree->AppendItem($hdr, "My Waypoints ($n)", -1, -1,
			Wx::TreeItemData->new({ type => 'my_waypoints' }));

		for my $uuid (@ungrouped)
		{
			my $wp = $wps->{$uuid};
			$tree->AppendItem($mw, $wp->{name} // $uuid, -1, -1,
				Wx::TreeItemData->new({ type => 'waypoint', uuid => $uuid, data => $wp }));
		}
	}

	# named groups, sorted by name
	for my $uuid (sort { winTreeBase::_name_sort_key($groups->{$a}{name}) cmp winTreeBase::_name_sort_key($groups->{$b}{name}) }
	              keys %$groups)
	{
		my $grp = $groups->{$uuid};
		my @member_uuids = sort {
			my $wa = $wps->{$a}; my $wb = $wps->{$b};
			winTreeBase::_name_sort_key($wa ? $wa->{name} : '') cmp winTreeBase::_name_sort_key($wb ? $wb->{name} : '')
		} @{$grp->{uuids} // []};
		my $n = scalar @member_uuids;
		my $grp_item = $tree->AppendItem($hdr, "$grp->{name} ($n wps)", -1, -1,
			Wx::TreeItemData->new({ type => 'group', uuid => $uuid, data => $grp }));

		for my $wp_uuid (@member_uuids)
		{
			my $wp = $wps->{$wp_uuid};
			my $label = $wp ? ($wp->{name} // $wp_uuid) : "($wp_uuid)";
			$tree->AppendItem($grp_item, $label, -1, -1,
				Wx::TreeItemData->new({ type => 'waypoint', uuid => $wp_uuid, data => $wp, group_uuid => $uuid }));
		}
	}

	return $hdr;
}


sub _buildRoutes
{
	my ($this, $tree, $root, $wpmgr) = @_;
	my $routes = $wpmgr->{routes}    // {};
	my $wps    = $wpmgr->{waypoints} // {};

	my $hdr = $tree->AppendItem($root, 'Routes', -1, -1,
		Wx::TreeItemData->new({ type => 'header', kind => 'routes' }));

	for my $uuid (sort { winTreeBase::_name_sort_key($routes->{$a}{name}) cmp winTreeBase::_name_sort_key($routes->{$b}{name}) }
	              keys %$routes)
	{
		my $r = $routes->{$uuid};
		my $n = $r->{num_wpts} // scalar(@{$r->{uuids} // []});
		my $route_item = $tree->AppendItem($hdr, "$r->{name} ($n pts)", -1, -1,
			Wx::TreeItemData->new({ type => 'route', uuid => $uuid, data => $r }));

		for my $wp_uuid (@{$r->{uuids} // []})
		{
			my $wp    = $wps->{$wp_uuid};
			my $label = $wp ? ($wp->{name} // $wp_uuid) : "($wp_uuid)";
			$tree->AppendItem($route_item, $label, -1, -1,
				Wx::TreeItemData->new({
					type       => 'route_point',
					uuid       => $wp_uuid,
					route_uuid => $uuid,
					data       => $wp,
				}));
		}
	}

	return $hdr;
}


sub _buildTracks
{
	my ($this, $tree, $root, $track_mgr) = @_;
	my $tracks = ($track_mgr && $track_mgr->{tracks}) ? $track_mgr->{tracks} : {};
	my $n      = scalar keys %$tracks;
	my $label  = $n ? "Tracks ($n)" : 'Tracks';
	my $hdr    = $tree->AppendItem($root, $label, -1, -1,
		Wx::TreeItemData->new({ type => 'header', kind => 'tracks' }));

	for my $uuid (sort { winTreeBase::_name_sort_key($tracks->{$a}{name}) cmp winTreeBase::_name_sort_key($tracks->{$b}{name}) }
	              keys %$tracks)
	{
		my $track = $tracks->{$uuid};
		my $pts   = $track->{cnt1} // (ref $track->{points} ? scalar @{$track->{points}} : 0);
		$tree->AppendItem($hdr, "$track->{name} ($pts pts)", -1, -1,
			Wx::TreeItemData->new({ type => 'track', uuid => $uuid, data => $track }));
	}

	return $hdr;
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

	my $type = $node->{type} // '';

	if ($type eq 'root')
	{
		$this->_clearEditor();
		$this->{detail}->SetValue('');
		return;
	}

	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR') : undef;
	my $text  = '';

	if ($type eq 'header')
	{
		$this->_clearEditor();
		$text = "($node->{kind})";
	}
	elsif ($type eq 'my_waypoints')
	{
		$this->_clearEditor();
		$text = "Synthesized node: waypoints not assigned to any named group.";
	}
	elsif ($type eq 'route_point' && $node->{data})
	{
		$this->_clearEditor();
		$text = wpmgrRecordToText($node->{data}, 'WAYPOINT', 2, 0, undef, $wpmgr);
		$text = sprintf("  %-10s = %s\n", 'uuid', $node->{uuid}) . $text if $node->{uuid};
	}
	elsif ($type eq 'waypoint' && $node->{data})
	{
		$this->{_edit_item} = $item;
		$this->_loadEditor($node);
		$text = wpmgrRecordToText($node->{data}, 'WAYPOINT', 2, 0, undef, $wpmgr);
		$text = sprintf("  %-10s = %s\n", 'uuid', $node->{uuid}) . $text if $node->{uuid};
	}
	elsif ($type eq 'group' && $node->{data})
	{
		$this->{_edit_item} = $item;
		$this->_loadEditor($node);
		$text = wpmgrRecordToText($node->{data}, 'GROUP', 2, 0, undef, $wpmgr);
		$text = sprintf("  %-10s = %s\n", 'uuid', $node->{uuid}) . $text if $node->{uuid};
	}
	elsif ($type eq 'route' && $node->{data})
	{
		$this->{_edit_item} = $item;
		$this->_loadEditor($node);
		$text = wpmgrRecordToText($node->{data}, 'ROUTE', 2, 0, undef, $wpmgr);
		$text = sprintf("  %-10s = %s\n", 'uuid', $node->{uuid}) . $text if $node->{uuid};
	}
	elsif ($type eq 'track' && $node->{data})
	{
		$this->{_edit_item} = $item;
		$this->_loadEditor($node);
		my $track = $node->{data};
		my $pts   = $track->{cnt1} // (ref $track->{points} ? scalar @{$track->{points}} : 0);
		$text  = "Track:  $track->{name}\n";
		$text .= "UUID:   $node->{uuid}\n";
		$text .= "Points: $pts\n";
		$text .= "Color:  $track->{color}\n" if defined $track->{color};
		my $point_list = ref $track->{points} eq 'ARRAY' ? $track->{points} : [];
		if (@$point_list)
		{
			$text .= "\n";
			for my $i (0 .. $#$point_list)
			{
				my $pt   = $point_list->[$i];
				my $d_ft = ($pt->{depth} // 0) ? sprintf('%.1fft', $pt->{depth} / 30.48) : '-';
				my $t_f  = ($pt->{tempr} // 0) ? sprintf('%.1fF', ($pt->{tempr} / 100 - 273) * 9 / 5 + 32) : '-';
				$text .= sprintf("  %2d  %9.6f  %10.6f  %7s  %s\n",
					$i + 1, ($pt->{lat} // 0) + 0, ($pt->{lon} // 0) + 0, $d_ft, $t_f);
			}
		}
	}
	else
	{
		$this->_clearEditor();
	}

	$this->{detail}->SetValue($text);
}


#---------------------------------
# save
#---------------------------------

sub _onSave
{
	my ($this, $event) = @_;
	my $uuid = $this->{_edit_uuid};
	my $type = $this->{_edit_type} // '';
	return if !$uuid;

	my $wpmgr     = $raydp ? $raydp->findImplementedService('WPMGR', 1) : undef;
	my $track_mgr = $raydp ? $raydp->findImplementedService('TRACK', 1) : undef;

	if ($type eq 'waypoint' && $wpmgr)
	{
		my $lat = parseLatLon($this->{ed_lat}->GetValue());
		my $lon = parseLatLon($this->{ed_lon}->GetValue());
		if (!defined($lat) || !defined($lon))
		{
			warning(0, 0, "invalid lat/lon - save aborted");
			return;
		}
		my $use_feet   = getPref($PREF_DEPTH_DISPLAY);
		my $use_fahr   = getPref($PREF_FAHRENHEIT);

		my $depth_disp = $this->{ed_depth}->GetValue() + 0;
		my $depth_cm   = int($use_feet ? $depth_disp / 0.0328084 : $depth_disp * 100);

		my $temp_disp  = $this->{ed_temp}->GetValue() + 0;
		my $temp_c     = $use_fahr ? ($temp_disp - 32) * 5 / 9 : $temp_disp;
		my $temp_k100  = int(($temp_c + 273.15) * 100);
		$temp_k100     = 0 if $temp_k100 < 0;

		my $wx_dt    = $this->{ed_date}->GetValue();
		my $date_val = int(timegm(0, 0, 12,
			$wx_dt->GetDay(), $wx_dt->GetMonth(), $wx_dt->GetYear() - 1900) / 86400);

		my $time_str   = $this->{ed_time}->GetValue();
		$time_str =~ /^(\d+):(\d+):(\d+)$/;
		my $time_sec   = ($1 // 0) * 3600 + ($2 // 0) * 60 + ($3 // 0);

		$wpmgr->modifyWaypoint({
			uuid    => $uuid,
			name    => $this->{ed_name}->GetValue(),
			lat     => $lat,
			lon     => $lon,
			sym     => $this->{ed_sym}->GetSelection(),
			comment => $this->{ed_comment}->GetValue(),
			depth   => $depth_cm,
			temp    => $temp_k100,
			date    => $date_val,
			time    => $time_sec,
		});
	}
	elsif ($type eq 'group' && $wpmgr)
	{
		$wpmgr->modifyGroup({
			uuid    => $uuid,
			name    => $this->{ed_name}->GetValue(),
			comment => $this->{ed_comment}->GetValue(),
		});
	}
	elsif ($type eq 'route' && $wpmgr)
	{
		$wpmgr->modifyRoute({
			uuid    => $uuid,
			name    => $this->{ed_name}->GetValue(),
			color   => $this->{ed_color_choice}->GetSelection(),
			comment => $this->{ed_comment}->GetValue(),
		});
	}
	elsif ($type eq 'track' && $track_mgr)
	{
		my $new_name = $this->{ed_name}->GetValue();
		$track_mgr->queueTRACKCommand(
			$apps::raymarine::NET::d_TRACK::API_GENERAL_CMD,
			$uuid, "rename $new_name");
	}
	else
	{
		warning(0, 0, "E80 save: no service available for type($type)");
		return;
	}

	$this->{ed_save}->Enable(0);
	$this->{_editor_dirty} = 0;
}


#---------------------------------
# right-click context menu
#---------------------------------

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

	my $menu = buildContextMenu('e80', $right_click_node, @nodes);

	if (($right_click_node->{type} // '') eq 'root')
	{
		my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR', 1) : undef;
		my $track = $raydp ? $raydp->findImplementedService('TRACK', 1) : undef;
		my $has_content = ($wpmgr && (%{$wpmgr->{routes}    // {}}
		                           || %{$wpmgr->{groups}    // {}}
		                           || %{$wpmgr->{waypoints} // {}}))
		               || ($track  &&  %{$track->{tracks}   // {}});
		if ($has_content)
		{
			$menu->AppendSeparator() if $menu->GetMenuItemCount() > 0;
			$menu->Append($COMMAND_CLEAR_E80_DB, 'Clear E80 DB');
		}
	}
	else
	{
		$menu->AppendSeparator() if $menu->GetMenuItemCount() > 0;
		$menu->Append($CTX_CMD_SHOW_MAP, 'Show on Map');
		$menu->Append($CTX_CMD_HIDE_MAP, 'Hide on Map');
	}

	$menu->AppendSeparator() if $menu->GetMenuItemCount() > 0;
	$menu->Append($COMMAND_REFRESH_WIN_E80, 'Refresh winE80');

	return $menu;
}


sub _onNmOpsCmd
{
	my ($this, $event) = @_;
	my $cmd_id      = $event->GetId();
	my $right_click = $this->{_right_click_node} // {};
	my @nodes       = @{$this->{_context_nodes} // []};
	onContextMenuCommand($cmd_id, 'e80', $right_click, $this->{tree}, @nodes);
	_applyCutStyle($this);
}


sub _onTreeKeyDown
{
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
					if navClipboard::getCopyMenuItems('e80', @nodes);
			}
			elsif ($key == ord('X'))
			{
				$cmd_id = $CTX_CMD_CUT
					if navClipboard::getCutMenuItems('e80', @nodes);
			}
			else
			{
				if (scalar(@nodes) == 1)
				{
					my @paste = navClipboard::getPasteMenuItems('e80', $right_click_node);
					$cmd_id = $CTX_CMD_PASTE
						if grep { $_->{id} == $CTX_CMD_PASTE } @paste;
				}
			}

			if ($cmd_id)
			{
				$this->{_right_click_node} = $right_click_node;
				$this->{_context_nodes}    = \@nodes;
				onContextMenuCommand($cmd_id, 'e80', $right_click_node, $tree, @nodes);
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
	if ($cb && $cb->{cut_flag} && ($cb->{source} // '') eq 'e80')
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


#---------------------------------
# ini persistence
#---------------------------------

sub getDataForIniFile
{
	my ($this) = @_;
	$this->_captureExpandedInto() if $this->{_e80_loaded} && $this->{tree}->GetCount() > 0;
	return {
		sash     => $this->GetSashPosition(),
		expanded => join(',', sort keys %{$this->{_expanded_keys}}),
	};
}


#---------------------------------
# map show/hide event handlers
#---------------------------------

sub _onTreeActivated
{
	my ($this, $event) = @_;
	_onShowHideE80Map($this, 1);
}


sub _onShowMap
{
	my ($this, $event) = @_;
	_onShowHideE80Map($this, 1);
}


sub _onHideMap
{
	my ($this, $event) = @_;
	_onShowHideE80Map($this, 0);
}


sub _onShowHideE80Map
{
	my ($this, $new_visible) = @_;
	my $tree = $this->{tree};

	my @items = $tree->GetSelections();
	return if !@items;

	for my $item (@items)
	{
		my $d = $tree->GetItemData($item);
		next if !$d;
		my $node = $d->GetData();
		next if ref $node ne 'HASH';
		$this->_applyNodeVisibility($item, $node, $new_visible);
	}

	$this->_refreshAncestorStates($_) for @items;
	openMapBrowser() if $new_visible && !isBrowserConnected();
}


#---------------------------------
# winTreeBase abstract overrides
#---------------------------------

sub _wpDataSource    { 'e80' }
sub _groupHasComment { 1 }

sub _wpLatLon
{
	my ($this, $wp) = @_;
	return ((($wp->{lat}//0)+0)/1e7, (($wp->{lon}//0)+0)/1e7);
}

sub _wpColor
{
	my ($this, $wp) = @_;
	return $wp->{color} // 'FF888888';
}

sub _trackColorABGR
{
	my ($this, $track) = @_;
	return $track->{color} // 'FF888888';
}

sub _getVisible         { getE80Visible($_[1]) }
sub _setVisible         { setE80Visible($_[1], $_[2]) }
sub _clearAllVisible    { clearAllE80Visible() }
sub _getAllVisibleUUIDs  { getAllE80VisibleUUIDs() }
sub _batchRemoveVisible { batchRemoveE80Visible($_[1]) }

sub _routeWpts
{
	my ($this, $r) = @_;
	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR', 1) : undef;
	my $wps   = $wpmgr ? ($wpmgr->{waypoints} // {}) : {};
	my @pts;
	for my $uuid (@{$r->{uuids} // []})
	{
		my $wp = $wps->{$uuid};
		push @pts, {
			lat  => (($wp->{lat}//0)+0)/1e7,
			lon  => (($wp->{lon}//0)+0)/1e7,
			name => $wp->{name} // '',
		} if $wp && defined($wp->{lat}) && defined($wp->{lon});
	}
	return @pts;
}

sub _groupMemberWpts
{
	my ($this, $data) = @_;
	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR', 1) : undef;
	my $wps   = $wpmgr ? ($wpmgr->{waypoints} // {}) : {};
	return map { [$_, $wps->{$_}] } @{$data->{uuids} // []};
}

sub _myWaypoints
{
	my ($this) = @_;
	my $wpmgr  = $raydp ? $raydp->findImplementedService('WPMGR', 1) : undef;
	my $wps    = $wpmgr ? ($wpmgr->{waypoints} // {}) : {};
	my $groups = $wpmgr ? ($wpmgr->{groups}    // {}) : {};
	my %grouped;
	$grouped{$_} = 1 for map { @{$groups->{$_}{uuids} // []} } keys %$groups;
	return { map { $_ => $wps->{$_} } grep { !$grouped{$_} } keys %$wps };
}

sub _allWaypoints
{
	my ($this) = @_;
	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR', 1) : undef;
	return $wpmgr ? ($wpmgr->{waypoints} // {}) : {};
}

sub _allRoutes
{
	my ($this) = @_;
	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR', 1) : undef;
	return $wpmgr ? ($wpmgr->{routes} // {}) : {};
}

sub _allTracks
{
	my ($this) = @_;
	my $track_mgr = $raydp ? $raydp->findImplementedService('TRACK', 1) : undef;
	return ($track_mgr && $track_mgr->{tracks}) ? $track_mgr->{tracks} : {};
}


1;
