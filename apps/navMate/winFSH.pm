#!/usr/bin/perl
#-------------------------------------------------------------------------
# winFSH.pm
#-------------------------------------------------------------------------
# Browser for an FSH-db loaded by navFSH::loadFSH().
#
# Tree structure mirrors winE80:
#   Groups
#     My Waypoints  (BLK_WPT standalone waypoints)
#       waypoint ...
#     named group ...  (BLK_GRP)
#       waypoint ...
#   Routes
#     route ...
#   Tracks
#     track ...
#
# Checkboxes control Leaflet map visibility, parallel to winE80.
# Selecting a node populates the read-only detail TextCtrl on the right.

package winFSH;
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
	EVT_LEFT_DOWN
	EVT_TEXT
	EVT_BUTTON
	EVT_CHOICE
	EVT_CHECKBOX
	EVT_DATE_CHANGED
	EVT_SIZE);
use Pub::Utils qw(display warning error);
use Pub::WX::Window;
use apps::raymarine::FSH::fshUtils qw(fshDateTimeToStr);
use apps::raymarine::NET::a_utils;
use navFSH;
use navServer qw(addRenderFeatures removeRenderFeatures openMapBrowser isBrowserConnected);
use navVisibility qw(getFSHVisible setFSHVisible clearAllFSHVisible getAllFSHVisibleUUIDs batchRemoveFSHVisible);
use navOutline;
use n_defs;
use n_utils;
use navPrefs;
use nmResources;
use base 'winTreeBase';

my $dbg_wfsh = 0;


sub new
{
	my ($class, $frame, $book, $id, $data) = @_;
	my $this = $class->SUPER::new($book, $id);
	$this->MyWindow($frame, $book, $id, 'FSH', $data);

	$this->{tree} = Wx::TreeCtrl->new($this, -1, wxDefaultPosition, wxDefaultSize,
		wxTR_DEFAULT_STYLE | wxTR_HIDE_ROOT | wxTR_MULTIPLE);

	my $state_imgs = Wx::ImageList->new(13, 13);
	$state_imgs->Add(winTreeBase::_makeCheckBitmap(0));
	$state_imgs->Add(winTreeBase::_makeCheckBitmap(1));
	$state_imgs->Add(winTreeBase::_makeCheckBitmap(2));
	$this->{tree}->SetStateImageList($state_imgs);
	$this->{_state_imgs} = $state_imgs;

	# inner splitter: editor panel (top) + detail panel (bottom)
	my $right_split = Wx::SplitterWindow->new($this, -1);
	$this->{right_split} = $right_split;

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

	$this->{ed_lbl_name} = Wx::StaticText->new($editor_panel, -1, 'Name',
		[$ED_MARGIN, $ey->(0)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_name} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(0)], [200, $ED_CTRL_H]);

	$this->{ed_lbl_comment} = Wx::StaticText->new($editor_panel, -1, 'Comment',
		[$ED_MARGIN, $ey->(1)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_comment} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(1)], [200, $ED_CTRL_H]);

	$this->{ed_lbl_lat} = Wx::StaticText->new($editor_panel, -1, 'Lat',
		[$ED_MARGIN, $ey->(2)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_lat} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(2)], [110, $ED_CTRL_H]);
	$this->{ed_lat_ddm} = Wx::StaticText->new($editor_panel, -1, '',
		[$ED_CTRL_X + 110 + 6, $ey->(2)], [-1, $ED_CTRL_H]);

	$this->{ed_lbl_lon} = Wx::StaticText->new($editor_panel, -1, 'Lon',
		[$ED_MARGIN, $ey->(3)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_lon} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(3)], [110, $ED_CTRL_H]);
	$this->{ed_lon_ddm} = Wx::StaticText->new($editor_panel, -1, '',
		[$ED_CTRL_X + 110 + 6, $ey->(3)], [-1, $ED_CTRL_H]);

	$this->{ed_lbl_sym} = Wx::StaticText->new($editor_panel, -1, 'Sym',
		[$ED_MARGIN, $ey->(4)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_sym} = Wx::Choice->new($editor_panel, -1,
		[$ED_CTRL_X, $ey->(4)], [-1, $ED_CTRL_H],
		[map { sprintf('%2d - %s', $_, $apps::raymarine::NET::a_utils::WPICON_TABLE[$_][0]) }
		 0..$#apps::raymarine::NET::a_utils::WPICON_TABLE]);

	$this->{ed_lbl_color} = Wx::StaticText->new($editor_panel, -1, 'Color',
		[$ED_MARGIN, $ey->(5)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_color_choice} = Wx::Choice->new($editor_panel, -1,
		[$ED_CTRL_X, $ey->(5)], [-1, $ED_CTRL_H],
		[@E80_ROUTE_COLOR_NAMES]);

	$this->{ed_lbl_depth} = Wx::StaticText->new($editor_panel, -1, 'Depth',
		[$ED_MARGIN, $ey->(5)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_depth} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(5)], [80, $ED_CTRL_H]);
	$this->{ed_depth_unit} = Wx::StaticText->new($editor_panel, -1, '',
		[$ED_CTRL_X + 86, $ey->(5)], [-1, $ED_CTRL_H]);

	$this->{ed_lbl_temp} = Wx::StaticText->new($editor_panel, -1, 'Temp',
		[$ED_MARGIN, $ey->(6)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_temp} = Wx::TextCtrl->new($editor_panel, -1, '',
		[$ED_CTRL_X, $ey->(6)], [80, $ED_CTRL_H]);
	$this->{ed_temp_unit} = Wx::StaticText->new($editor_panel, -1, '',
		[$ED_CTRL_X + 86, $ey->(6)], [-1, $ED_CTRL_H]);

	$this->{ed_lbl_date} = Wx::StaticText->new($editor_panel, -1, 'Date',
		[$ED_MARGIN, $ey->(7)], [$ED_LABEL_W, $ED_CTRL_H]);
	$this->{ed_date} = Wx::DatePickerCtrl->new($editor_panel, -1,
		Wx::DateTime::Today(), [$ED_CTRL_X, $ey->(7)], [-1, $ED_CTRL_H],
		wxDP_DROPDOWN | wxDP_SHOWCENTURY);

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

	my $detail_panel = Wx::Panel->new($right_split, -1);
	$this->{detail_panel} = $detail_panel;
	$this->{detail} = Wx::TextCtrl->new($detail_panel, -1, '', wxDefaultPosition, wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);
	my $font = Wx::Font->new(9, wxFONTFAMILY_MODERN, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL);
	$this->{detail}->SetFont($font);
	my $detail_vsizer = Wx::BoxSizer->new(wxVERTICAL);
	$detail_vsizer->Add($this->{detail}, 1, wxEXPAND);
	$detail_panel->SetSizer($detail_vsizer);

	my $right_sash = ($data && ref($data) eq 'HASH' && $data->{right_sash}) ? $data->{right_sash} : $ED_INITIAL_SASH;
	$right_split->SplitHorizontally($editor_panel, $detail_panel, $right_sash);
	$right_split->SetSashGravity(0);

	my $sash = ($data && ref($data) eq 'HASH' && $data->{sash}) ? $data->{sash} : 250;
	$this->SplitVertically($this->{tree}, $right_split, $sash);
	$this->SetSashGravity(0);

	EVT_TREE_SEL_CHANGED($this, $this->{tree}, \&onTreeSelect);
	EVT_LEFT_DOWN($this->{tree}, sub { $this->_onTreeLeftDown(@_) });
	EVT_TEXT($this,         $this->{ed_name},         $this->can('_onFieldChanged'));
	EVT_TEXT($this,         $this->{ed_comment},       $this->can('_onFieldChanged'));
	EVT_TEXT($this,         $this->{ed_lat},           $this->can('_onLatEdit'));
	EVT_TEXT($this,         $this->{ed_lon},           $this->can('_onLonEdit'));
	EVT_CHOICE($this,       $this->{ed_sym},           $this->can('_onFieldChanged'));
	EVT_CHOICE($this,       $this->{ed_color_choice},  $this->can('_onFieldChanged'));
	EVT_TEXT($this,         $this->{ed_depth},         $this->can('_onFieldChanged'));
	EVT_TEXT($this,         $this->{ed_temp},          $this->can('_onFieldChanged'));
	EVT_TEXT($this,         $this->{ed_time},          $this->can('_onFieldChanged'));
	EVT_DATE_CHANGED($this, $this->{ed_date},          $this->can('_onFieldChanged'));
	EVT_BUTTON($this,       $this->{ed_save},          \&_onSave);
	EVT_CHECKBOX($this,     $this->{ed_visible},       $this->can('_onEdVisibleChanged'));

	$this->{_loaded}        = 0;
	my @outline_keys = navOutline::getExpanded('fsh');
	$this->{_expanded_keys} = @outline_keys
		? { map { $_ => 1 } @outline_keys }
		: ($data && $data->{expanded})
			? { map { $_ => 1 } split(/,/, $data->{expanded}) }
			: {};
	$this->{_selected_keys} = {};

	if (!defined($navFSH::fsh_db) && $data && $data->{fsh_filename} && -f $data->{fsh_filename})
	{
		navFSH::loadFSH($data->{fsh_filename});
	}

	if (defined $navFSH::fsh_db)
	{
		_buildAndRestore($this);
	}

	return $this;
}


sub getDataForIniFile
{
	my ($this) = @_;
	$this->_captureExpandedInto() if $this->{_loaded} && $this->{tree}->GetCount() > 0;
	return {
		sash         => $this->GetSashPosition(),
		right_sash   => $this->{right_split} ? $this->{right_split}->GetSashPosition() : 0,
		fsh_filename => $navFSH::fsh_filename // '',
	};
}


sub onFilenameChanged
{
	my ($this) = @_;
	_buildAndRestore($this);
}


sub doSaveFSHOutline
{
	my ($this) = @_;
	$this->_captureExpandedInto() if $this->{_loaded} && $this->{tree}->GetCount() > 0;
	navOutline::setExpanded('fsh', [ sort keys %{$this->{_expanded_keys}} ]);
	navOutline::saveOutline('fsh');
}


sub doRestoreFSHOutline
{
	my ($this) = @_;
	navOutline::loadOutline('fsh');
	my @keys = navOutline::getExpanded('fsh');
	$this->{_expanded_keys} = { map { $_ => 1 } @keys };
	_buildAndRestore($this) if $this->{_loaded};
}


sub refresh
{
	my ($this) = @_;
	return if !defined $navFSH::fsh_db;
	display($dbg_wfsh,0,"winFSH::refresh");
	if ($this->{tree}->GetCount() > 0)
	{
		$this->_captureExpandedInto();
		$this->_captureSelectedInto();
	}
	_buildAndRestore($this);
}


#---------------------------------
# tree build
#---------------------------------

sub _buildAndRestore
{
	my ($this) = @_;
	my $tree = $this->{tree};
	return if !$tree;

	$tree->DeleteAllItems();
	$this->{detail}->SetValue('');

	my @prev_visible = getAllFSHVisibleUUIDs();
	if (@prev_visible)
	{
		removeRenderFeatures(\@prev_visible);
		clearAllFSHVisible();
	}

	my $db = $navFSH::fsh_db;
	if (!$db)
	{
		my $root = $tree->AddRoot('FSH');
		$tree->AppendItem($root, '(no FSH file loaded)');
		$this->{_loaded} = 0;
		return;
	}

	my $root = $tree->AddRoot('FSH');
	my $filename = $navFSH::fsh_filename;
	$filename =~ s{.*[/\\]}{} if $filename;
	my $top = $tree->AppendItem($root, $filename || 'FSH', -1, -1,
		Wx::TreeItemData->new({ type => 'root', data => { name => $filename } }));
	$tree->SetItemBold($top, 1);

	_buildGroups($this, $tree, $root, $db);
	_buildRoutes($this, $tree, $root, $db);
	_buildTracks($this, $tree, $root, $db);

	$this->{_loaded} = 1;
	winTreeBase::_walkRestoreStateImages($this, $tree, $root);
	$this->_syncLeafletAfterRebuild();
	$tree->Expand($root);
	winTreeBase::_walkRestoreExpanded($tree, $root, $this->{_expanded_keys});
	winTreeBase::_walkRestoreSelected($tree, $root, $this->{_selected_keys});
}


sub _buildGroups
{
	my ($this, $tree, $root, $db) = @_;
	my $wps    = $db->{waypoints} // {};
	my $groups = $db->{groups}    // {};

	my $hdr = $tree->AppendItem($root, 'Groups', -1, -1,
		Wx::TreeItemData->new({ type => 'header', kind => 'groups' }));

	# BLK_WPT standalone waypoints -> My Waypoints
	my @wpt_uuids = sort { winTreeBase::_name_sort_key($wps->{$a}{name}) cmp winTreeBase::_name_sort_key($wps->{$b}{name}) }
	                keys %$wps;
	if (@wpt_uuids)
	{
		my $n  = scalar @wpt_uuids;
		my $mw = $tree->AppendItem($hdr, "My Waypoints ($n)", -1, -1,
			Wx::TreeItemData->new({ type => 'my_waypoints' }));
		for my $uuid (@wpt_uuids)
		{
			my $wp = $wps->{$uuid};
			$tree->AppendItem($mw, $wp->{name} // $uuid, -1, -1,
				Wx::TreeItemData->new({ type => 'waypoint', uuid => $uuid, data => $wp }));
		}
	}

	# BLK_GRP named groups
	for my $uuid (sort { winTreeBase::_name_sort_key($groups->{$a}{name}) cmp winTreeBase::_name_sort_key($groups->{$b}{name}) }
	              keys %$groups)
	{
		my $grp  = $groups->{$uuid};
		my $wpts = $grp->{wpts} // [];
		my $n    = scalar @$wpts;
		my $grp_item = $tree->AppendItem($hdr, "$grp->{name} ($n wps)", -1, -1,
			Wx::TreeItemData->new({ type => 'group', uuid => $uuid, data => $grp }));

		my @sorted = sort { winTreeBase::_name_sort_key($a->{name}) cmp winTreeBase::_name_sort_key($b->{name}) } @$wpts;
		for my $wp (@sorted)
		{
			$tree->AppendItem($grp_item, $wp->{name} // $wp->{uuid} // '?', -1, -1,
				Wx::TreeItemData->new({ type => 'waypoint', uuid => $wp->{uuid}, data => $wp,
				                       group_uuid => $uuid }));
		}
	}

	return $hdr;
}


sub _buildRoutes
{
	my ($this, $tree, $root, $db) = @_;
	my $routes = $db->{routes} // {};

	my $hdr = $tree->AppendItem($root, 'Routes', -1, -1,
		Wx::TreeItemData->new({ type => 'header', kind => 'routes' }));

	for my $uuid (sort { winTreeBase::_name_sort_key($routes->{$a}{name}) cmp winTreeBase::_name_sort_key($routes->{$b}{name}) }
	              keys %$routes)
	{
		my $r    = $routes->{$uuid};
		my $wpts = $r->{wpts} // [];
		my $n    = scalar @$wpts;
		my $route_item = $tree->AppendItem($hdr, "$r->{name} ($n pts)", -1, -1,
			Wx::TreeItemData->new({ type => 'route', uuid => $uuid, data => $r }));

		for my $wp (@$wpts)
		{
			my $label = $wp->{name} // $wp->{uuid} // '?';
			$tree->AppendItem($route_item, $label, -1, -1,
				Wx::TreeItemData->new({
					type       => 'route_point',
					uuid       => $wp->{uuid},
					route_uuid => $uuid,
					data       => $wp,
				}));
		}
	}

	return $hdr;
}


sub _buildTracks
{
	my ($this, $tree, $root, $db) = @_;
	my $tracks = $db->{tracks} // {};
	my $n      = scalar keys %$tracks;
	my $label  = $n ? "Tracks ($n)" : 'Tracks';
	my $hdr    = $tree->AppendItem($root, $label, -1, -1,
		Wx::TreeItemData->new({ type => 'header', kind => 'tracks' }));

	for my $uuid (sort { winTreeBase::_name_sort_key($tracks->{$a}{name}) cmp winTreeBase::_name_sort_key($tracks->{$b}{name}) }
	              keys %$tracks)
	{
		my $track = $tracks->{$uuid};
		my $pts   = $track->{cnt} // (ref $track->{points} eq 'ARRAY' ? scalar @{$track->{points}} : 0);
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
	my $text = '';

	if ($type eq 'root')
	{
		$this->_clearEditor();
		$text = "FSH file: $navFSH::fsh_filename\n";
	}
	elsif ($type eq 'header')
	{
		$this->_clearEditor();
		$text = "($node->{kind})";
	}
	elsif ($type eq 'my_waypoints')
	{
		$this->_clearEditor();
		$text = "Standalone waypoints (BLK_WPT) not assigned to any named group.";
	}
	elsif ($type eq 'route_point' && $node->{data})
	{
		$this->_clearEditor();
		$text = _fshWaypointText($node);
	}
	elsif ($type eq 'waypoint' && $node->{data})
	{
		$this->{_edit_item} = $item;
		$this->_loadEditor($node);
		$text = _fshWaypointText($node);
	}
	elsif ($type eq 'group' && $node->{data})
	{
		$this->{_edit_item} = $item;
		$this->_loadEditor($node);
		my $grp  = $node->{data};
		my $wpts = $grp->{wpts} // [];
		$text  = "Group: $grp->{name}\n";
		$text .= sprintf("  %-12s = %s\n", 'uuid', $node->{uuid}) if $node->{uuid};
		$text .= sprintf("  %-12s = %d\n", 'waypoints', scalar @$wpts);
	}
	elsif ($type eq 'route' && $node->{data})
	{
		$this->{_edit_item} = $item;
		$this->_loadEditor($node);
		$text = _fshRouteText($node);
	}
	elsif ($type eq 'track' && $node->{data})
	{
		$this->{_edit_item} = $item;
		$this->_loadEditor($node);
		$text = _fshTrackText($node);
	}

	$this->{detail}->SetValue($text);
}


sub _fshWaypointText
{
	my ($node) = @_;
	my $wp   = $node->{data};
	my $text = "\nWaypoint\n";
	$text .= sprintf("  %-12s = %s\n", 'uuid',    $node->{uuid} // '') if $node->{uuid};
	$text .= sprintf("  %-12s = %s\n", 'name',    $wp->{name}    // '');
	$text .= sprintf("  %-12s = %s\n", 'comment', $wp->{comment} // '') if $wp->{comment};
	$text .= sprintf("  %-12s = %.6f\n", 'lat',   $wp->{lat}  // 0);
	$text .= sprintf("  %-12s = %.6f\n", 'lon',   $wp->{lon}  // 0);
	$text .= sprintf("  %-12s = %d\n",  'sym',    $wp->{sym}  // 0) if defined $wp->{sym};
	if ($wp->{depth})
	{
		my $d_ft = sprintf('%.1f ft', $wp->{depth} / 30.48);
		$text .= sprintf("  %-12s = %d cm  (%s)\n", 'depth', $wp->{depth}, $d_ft);
	}
	if ($wp->{temp_k})
	{
		my $t_f = sprintf('%.1f F', ($wp->{temp_k} / 100 - 273) * 9 / 5 + 32);
		$text .= sprintf("  %-12s = %d  (%s)\n", 'temp_k', $wp->{temp_k}, $t_f);
	}
	if ($wp->{date} || $wp->{time})
	{
		$text .= sprintf("  %-12s = %s\n", 'datetime',
			fshDateTimeToStr($wp->{date} // 0, $wp->{time} // 0));
	}
	return $text;
}


sub _fshRouteText
{
	my ($node) = @_;
	my $r    = $node->{data};
	my $wpts = $r->{wpts} // [];
	my $text = "\nRoute\n";
	$text .= sprintf("  %-12s = %s\n", 'uuid',    $node->{uuid} // '') if $node->{uuid};
	$text .= sprintf("  %-12s = %s\n", 'name',    $r->{name}    // '');
	$text .= sprintf("  %-12s = %s\n", 'comment', $r->{comment} // '') if $r->{comment};
	$text .= sprintf("  %-12s = %d\n", 'color',   $r->{color}   // 0)  if defined $r->{color};
	$text .= sprintf("  %-12s = %d\n", 'points',  scalar @$wpts);
	if (@$wpts)
	{
		$text .= "\n";
		for my $i (0 .. $#$wpts)
		{
			my $wp = $wpts->[$i];
			$text .= sprintf("  %2d  %9.6f  %10.6f  %s\n",
				$i + 1, $wp->{lat} // 0, $wp->{lon} // 0, $wp->{name} // '');
		}
	}
	return $text;
}


sub _fshTrackText
{
	my ($node) = @_;
	my $track  = $node->{data};
	my $points = ref $track->{points} eq 'ARRAY' ? $track->{points} : [];
	my $pts    = $track->{cnt} // scalar @$points;
	my $text   = "Track:  $track->{name}\n";
	$text .= "UUID:     $track->{mta_uuid}  {mta_uuid}\n" if $track->{mta_uuid};
	$text .= "trk_uuid: $track->{trk_uuid}\n" if $track->{trk_uuid};
	$text .= "Points: $pts\n";
	$text .= "Color:  $track->{color}\n" if defined $track->{color};
	if (@$points)
	{
		$text .= "\n";
		for my $i (0 .. $#$points)
		{
			my $pt   = $points->[$i];
			my $d_ft = ($pt->{depth} // 0) ? sprintf('%.1fft', $pt->{depth} / 30.48) : '-';
			my $t_f  = ($pt->{temp_k}  // 0) ? sprintf('%.1fF',  ($pt->{temp_k}  / 100 - 273) * 9 / 5 + 32) : '-';
			$text .= sprintf("  %2d  %9.6f  %10.6f  %7s  %s\n",
				$i + 1, ($pt->{lat} // 0) + 0, ($pt->{lon} // 0) + 0, $d_ft, $t_f);
		}
	}
	return $text;
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

	my $db = $navFSH::fsh_db;
	return if !$db;

	if ($type eq 'waypoint')
	{
		my $lat = parseLatLon($this->{ed_lat}->GetValue());
		my $lon = parseLatLon($this->{ed_lon}->GetValue());
		if (!defined($lat) || !defined($lon))
		{
			warning(0, 0, "winFSH: invalid lat/lon - save aborted");
			return;
		}
		my $use_feet  = getPref($PREF_DEPTH_DISPLAY);
		my $use_fahr  = getPref($PREF_FAHRENHEIT);

		my $depth_disp = $this->{ed_depth}->GetValue() + 0;
		my $depth_cm   = int($use_feet ? $depth_disp / 0.0328084 : $depth_disp * 100);

		my $temp_disp  = $this->{ed_temp}->GetValue() + 0;
		my $temp_c     = $use_fahr ? ($temp_disp - 32) * 5 / 9 : $temp_disp;
		my $temp_k100  = int(($temp_c + 273.15) * 100);
		$temp_k100     = 0 if $temp_k100 < 0;

		my $wx_dt    = $this->{ed_date}->GetValue();
		my $date_val = int(timegm(0, 0, 12,
			$wx_dt->GetDay(), $wx_dt->GetMonth(), $wx_dt->GetYear() - 1900) / 86400);

		my $time_str = $this->{ed_time}->GetValue();
		$time_str =~ /^(\d+):(\d+):(\d+)$/;
		my $time_sec = ($1 // 0) * 3600 + ($2 // 0) * 60 + ($3 // 0);

		my $name    = $this->{ed_name}->GetValue();
		my $comment = $this->{ed_comment}->GetValue();
		my $sym     = $this->{ed_sym}->GetSelection();

		my $nd       = $this->{tree}->GetItemData($this->{_edit_item});
		my $n        = ($nd && $nd->GetData()) ? $nd->GetData() : {};
		my $grp_uuid = $n->{group_uuid};

		my $wp_rec;
		if ($grp_uuid && $db->{groups}{$grp_uuid})
		{
			for my $wp (@{$db->{groups}{$grp_uuid}{wpts} // []})
			{
				if ($wp->{uuid} && $wp->{uuid} eq $uuid)
				{
					$wp_rec = $wp;
					last;
				}
			}
		}
		else
		{
			$wp_rec = $db->{waypoints}{$uuid};
		}

		if ($wp_rec)
		{
			$wp_rec->{name}    = $name;
			$wp_rec->{comment} = $comment;
			$wp_rec->{lat}     = $lat;
			$wp_rec->{lon}     = $lon;
			$wp_rec->{sym}     = $sym;
			$wp_rec->{depth}   = $depth_cm;
			$wp_rec->{temp_k}    = $temp_k100;
			$wp_rec->{date}    = $date_val;
			$wp_rec->{time}    = $time_sec;
		}

		$this->{tree}->SetItemText($this->{_edit_item}, $name) if $this->{_edit_item};
		if (getFSHVisible($uuid))
		{
			removeRenderFeatures([$uuid]);
			addRenderFeatures([$this->_buildWpFeature($uuid, $wp_rec)]) if $wp_rec;
		}
	}
	elsif ($type eq 'group')
	{
		my $name    = $this->{ed_name}->GetValue();
		my $grp_rec = $db->{groups}{$uuid};
		if ($grp_rec) { $grp_rec->{name} = $name }
		my $n = scalar @{$grp_rec ? ($grp_rec->{wpts} // []) : []};
		$this->{tree}->SetItemText($this->{_edit_item}, "$name ($n wps)") if $this->{_edit_item};
	}
	elsif ($type eq 'route')
	{
		my $name    = $this->{ed_name}->GetValue();
		my $comment = $this->{ed_comment}->GetValue();
		my $color   = $this->{ed_color_choice}->GetSelection();
		my $r_rec   = $db->{routes}{$uuid};
		if ($r_rec)
		{
			$r_rec->{name}    = $name;
			$r_rec->{comment} = $comment;
			$r_rec->{color}   = $color;
		}
		my $n = scalar @{$r_rec ? ($r_rec->{wpts} // []) : []};
		$this->{tree}->SetItemText($this->{_edit_item}, "$name ($n pts)") if $this->{_edit_item};
		if (getFSHVisible($uuid) && $r_rec)
		{
			removeRenderFeatures([$uuid]);
			my $feat = $this->_buildRouteFeature($uuid, $r_rec);
			addRenderFeatures([$feat]) if $feat;
		}
	}
	elsif ($type eq 'track')
	{
		my $name  = $this->{ed_name}->GetValue();
		my $t_rec = $db->{tracks}{$uuid};
		if ($t_rec) { $t_rec->{name} = $name }
		my $pts = $t_rec
			? ($t_rec->{cnt} // (ref $t_rec->{points} eq 'ARRAY' ? scalar @{$t_rec->{points}} : 0))
			: 0;
		$this->{tree}->SetItemText($this->{_edit_item}, "$name ($pts pts)") if $this->{_edit_item};
		if (getFSHVisible($uuid) && $t_rec)
		{
			removeRenderFeatures([$uuid]);
			my $feat = $this->_buildTrackFeature($uuid, $t_rec);
			addRenderFeatures([$feat]) if $feat;
		}
	}
	else
	{
		warning(0, 0, "winFSH save: unknown type($type)");
		return;
	}

	$this->{ed_save}->Enable(0);
	$this->{_editor_dirty} = 0;
}


#---------------------------------
# winTreeBase abstract overrides
#---------------------------------

sub _wpDataSource    { 'fsh' }
sub _groupHasComment { 0 }

sub _wpLatLon
{
	my ($this, $wp) = @_;
	return (($wp->{lat}//0)+0, ($wp->{lon}//0)+0);
}

sub _wpColor { 'FF888888' }

sub _trackColorABGR
{
	my ($this, $track) = @_;
	my $cidx = defined($track->{color}) ? ($track->{color} + 0) : 0;
	return $E80_ROUTE_COLOR_ABGR[$cidx] // 'FF888888';
}

sub _getVisible         { getFSHVisible($_[1]) }
sub _setVisible         { setFSHVisible($_[1], $_[2]) }
sub _clearAllVisible    { clearAllFSHVisible() }
sub _getAllVisibleUUIDs  { getAllFSHVisibleUUIDs() }
sub _batchRemoveVisible { batchRemoveFSHVisible($_[1]) }

sub _routeWpts
{
	my ($this, $r) = @_;
	return map { { lat => ($_->{lat}//0)+0, lon => ($_->{lon}//0)+0, name => $_->{name} // '' } }
	       @{$r->{wpts} // []};
}

sub _groupMemberWpts
{
	my ($this, $data) = @_;
	return map { [$_->{uuid}, $_] }
	       grep { $_->{uuid} } @{$data->{wpts} // []};
}

sub _myWaypoints
{
	my ($this) = @_;
	my $db = $navFSH::fsh_db;
	return $db ? ($db->{waypoints} // {}) : {};
}

sub _allWaypoints
{
	my ($this) = @_;
	my $db = $navFSH::fsh_db;
	return {} if !$db;
	my %all = %{$db->{waypoints} // {}};
	for my $grp (values %{$db->{groups} // {}})
	{
		for my $wp (@{$grp->{wpts} // []})
		{
			$all{$wp->{uuid}} = $wp if $wp->{uuid};
		}
	}
	return \%all;
}

sub _allRoutes
{
	my ($this) = @_;
	my $db = $navFSH::fsh_db;
	return $db ? ($db->{routes} // {}) : {};
}

sub _allTracks
{
	my ($this) = @_;
	my $db = $navFSH::fsh_db;
	return $db ? ($db->{tracks} // {}) : {};
}


sub onLeafletTrackEdit
{
	my ($this, $edit) = @_;
	my $op   = $edit->{op}   // '';
	my $uuid = $edit->{uuid} // '';
	return if !$uuid;
	my $db = $navFSH::fsh_db;
	return if !$db;
	my $tracks = $db->{tracks};
	return if !$tracks;
	display(0,0,"winFSH::onLeafletTrackEdit op=$op uuid=$uuid");

	if ($op eq 'update')
	{
		my $rec = $tracks->{$uuid};
		return if !$rec;
		my $coords = $edit->{coords} // [];
		return if !@$coords;
		my @new_pts = map { shared_clone({ lat => $_->[0]+0, lon => $_->[1]+0 }) } @$coords;
		$rec->{points} = shared_clone(\@new_pts);
		$rec->{cnt}    = scalar @new_pts;
		removeRenderFeatures([$uuid]);
		my $feat = $this->_buildTrackFeature($uuid, $rec);
		addRenderFeatures([$feat]) if $feat;
	}
	elsif ($op eq 'split')
	{
		my $split_idx = $edit->{split_idx} // -1;
		my $new_name  = $edit->{new_name}  // '';
		my $rec = $tracks->{$uuid};
		return if !$rec;
		my @all_pts = @{$rec->{points} // []};
		if ($split_idx <= 0 || $split_idx >= $#all_pts)
		{
			warning(0,0,"winFSH::onLeafletTrackEdit split precondition failed uuid=$uuid idx=$split_idx");
			return;
		}
		my @pts_a = @all_pts[0 .. $split_idx];
		my @pts_b = @all_pts[$split_idx+1 .. $#all_pts];
		$rec->{points} = shared_clone(\@pts_a);
		$rec->{cnt}    = scalar @pts_a;
		my $new_uuid = $uuid . '-' . time();
		$tracks->{$new_uuid} = shared_clone({
			%$rec,
			name   => $new_name,
			points => shared_clone(\@pts_b),
			cnt    => scalar @pts_b,
		});
		removeRenderFeatures([$uuid]);
		my $feat_a = $this->_buildTrackFeature($uuid,     $rec);
		my $feat_b = $this->_buildTrackFeature($new_uuid, $tracks->{$new_uuid});
		addRenderFeatures([$feat_a]) if $feat_a;
		addRenderFeatures([$feat_b]) if $feat_b;
		$this->refresh();
	}
	else
	{
		warning(0,0,"winFSH::onLeafletTrackEdit unknown op '$op' for uuid=$uuid");
	}
}


1;
