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
use n_defs;
use n_utils;
use navPrefs;
use nmResources;
use base qw(Wx::SplitterWindow Pub::WX::Window);

my $dbg_wfsh = 0;

# E80/FSH route+track color index 0-5 to ABGR hex.
# Duplicate of winE80's private copy -- move to shared location when winTreeBase is created.
my @E80_ROUTE_COLOR_ABGR = qw(
	FF0000FF
	FF00FFFF
	FF00FF00
	FFFF0000
	FFFF00FF
	FF000000
);


sub new
{
	my ($class, $frame, $book, $id, $data) = @_;
	my $this = $class->SUPER::new($book, $id);
	$this->MyWindow($frame, $book, $id, 'FSH', $data);

	$this->{tree} = Wx::TreeCtrl->new($this, -1, wxDefaultPosition, wxDefaultSize,
		wxTR_DEFAULT_STYLE | wxTR_HIDE_ROOT | wxTR_MULTIPLE);

	my $state_imgs = Wx::ImageList->new(13, 13);
	$state_imgs->Add(_makeCheckBitmap(0));
	$state_imgs->Add(_makeCheckBitmap(1));
	$state_imgs->Add(_makeCheckBitmap(2));
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
		['Red', 'Yellow', 'Green', 'Blue', 'Purple', 'Black']);

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

	_clearEditor($this);

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
	EVT_LEFT_DOWN($this->{tree}, sub { _onTreeLeftDown($this, @_) });
	EVT_TEXT($this,         $this->{ed_name},         \&_onFieldChanged);
	EVT_TEXT($this,         $this->{ed_comment},       \&_onFieldChanged);
	EVT_TEXT($this,         $this->{ed_lat},           \&_onLatEdit);
	EVT_TEXT($this,         $this->{ed_lon},           \&_onLonEdit);
	EVT_CHOICE($this,       $this->{ed_sym},           \&_onFieldChanged);
	EVT_CHOICE($this,       $this->{ed_color_choice},  \&_onFieldChanged);
	EVT_TEXT($this,         $this->{ed_depth},         \&_onFieldChanged);
	EVT_TEXT($this,         $this->{ed_temp},          \&_onFieldChanged);
	EVT_TEXT($this,         $this->{ed_time},          \&_onFieldChanged);
	EVT_DATE_CHANGED($this, $this->{ed_date},          \&_onFieldChanged);
	EVT_BUTTON($this,       $this->{ed_save},          \&_onSave);
	EVT_CHECKBOX($this,     $this->{ed_visible},       \&_onEdVisibleChanged);

	$this->{_loaded}        = 0;
	$this->{_expanded_keys} = ($data && $data->{expanded})
		? { map { $_ => 1 } split(/,/, $data->{expanded}) }
		: {};
	$this->{_selected_keys} = {};

	if (defined $navFSH::fsh_db)
	{
		_buildAndRestore($this);
	}

	return $this;
}


sub getDataForIniFile
{
	my ($this) = @_;
	_captureExpandedInto($this) if $this->{_loaded} && $this->{tree}->GetCount() > 0;
	return {
		sash       => $this->GetSashPosition(),
		right_sash => $this->{right_split} ? $this->{right_split}->GetSashPosition() : 0,
		expanded   => join(',', sort keys %{$this->{_expanded_keys}}),
	};
}


sub refresh
{
	my ($this) = @_;
	return if !defined $navFSH::fsh_db;
	display($dbg_wfsh,0,"winFSH::refresh");
	if ($this->{tree}->GetCount() > 0)
	{
		_captureExpandedInto($this);
		_captureSelectedInto($this);
	}
	_buildAndRestore($this);
}


sub onClearMap
{
	my ($this) = @_;
	clearAllFSHVisible();
	my $tree = $this->{tree};
	my $root = $tree->GetRootItem();
	_walkSetSubtreeState($tree, $root, 0) if $root && $root->IsOk();
	$this->{ed_visible}->Set3StateValue(wxCHK_UNCHECKED)
		if $this->{ed_visible} && $this->{ed_visible}->IsShown();
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


sub _clearEditor
{
	my ($this) = @_;
	$this->{_edit_uuid}    = undef;
	$this->{_edit_type}    = undef;
	$this->{_edit_item}    = undef;
	$this->{_editor_dirty} = 0;
	$this->{ed_title}->SetLabel('');
	$this->{ed_visible}->Show(0);
	_ed_show_row($this->{ed_lbl_name},    $this->{ed_name},         0);
	_ed_show_row($this->{ed_lbl_lat},     $this->{ed_lat},          0);
	$this->{ed_lat_ddm}->Show(0);
	_ed_show_row($this->{ed_lbl_lon},     $this->{ed_lon},          0);
	$this->{ed_lon_ddm}->Show(0);
	_ed_show_row($this->{ed_lbl_sym},     $this->{ed_sym},          0);
	_ed_show_row($this->{ed_lbl_color},   $this->{ed_color_choice}, 0);
	_ed_show_row($this->{ed_lbl_comment}, $this->{ed_comment},      0);
	_ed_show_row($this->{ed_lbl_depth},   $this->{ed_depth},        0);
	$this->{ed_depth_unit}->Show(0);
	_ed_show_row($this->{ed_lbl_temp},    $this->{ed_temp},         0);
	$this->{ed_temp_unit}->Show(0);
	_ed_show_row($this->{ed_lbl_date},    $this->{ed_date},         0);
	_ed_show_row($this->{ed_lbl_time},    $this->{ed_time},         0);
	$this->{right_split}->SetSashPosition($this->{_ed_sash_other}) if $this->{right_split};
	$this->{ed_save}->Enable(0);
}


sub _loadEditor
{
	my ($this, $node) = @_;
	my $type = $node->{type} // '';
	my $uuid = $node->{uuid};
	my $data = $node->{data} // {};

	my $show_name    = ($type eq 'waypoint' || $type eq 'group'
	                || $type eq 'route'    || $type eq 'track');
	my $show_latlon  = ($type eq 'waypoint');
	my $show_sym     = ($type eq 'waypoint');
	my $show_color   = ($type eq 'route');
	my $show_comment = ($type eq 'waypoint' || $type eq 'route');
	my $show_wp      = ($type eq 'waypoint');

	$this->{_edit_uuid}    = $uuid;
	$this->{_edit_type}    = $type;
	$this->{_editor_dirty} = 0;

	my $title = $type eq 'waypoint' ? 'Waypoint'
	          : $type eq 'group'    ? 'Group'
	          : $type eq 'route'    ? 'Route'
	          : $type eq 'track'    ? 'Track'
	          :                       '';
	$this->{ed_title}->SetLabel($title);

	_ed_show_row($this->{ed_lbl_name},    $this->{ed_name},         $show_name);
	_ed_show_row($this->{ed_lbl_lat},     $this->{ed_lat},          $show_latlon);
	$this->{ed_lat_ddm}->Show($show_latlon ? 1 : 0);
	_ed_show_row($this->{ed_lbl_lon},     $this->{ed_lon},          $show_latlon);
	$this->{ed_lon_ddm}->Show($show_latlon ? 1 : 0);
	_ed_show_row($this->{ed_lbl_sym},     $this->{ed_sym},          $show_sym);
	_ed_show_row($this->{ed_lbl_color},   $this->{ed_color_choice}, $show_color);
	_ed_show_row($this->{ed_lbl_comment}, $this->{ed_comment},      $show_comment);
	_ed_show_row($this->{ed_lbl_depth},   $this->{ed_depth},        $show_wp);
	$this->{ed_depth_unit}->Show($show_wp ? 1 : 0);
	_ed_show_row($this->{ed_lbl_temp},    $this->{ed_temp},         $show_wp);
	$this->{ed_temp_unit}->Show($show_wp ? 1 : 0);
	_ed_show_row($this->{ed_lbl_date},    $this->{ed_date},         $show_wp);
	_ed_show_row($this->{ed_lbl_time},    $this->{ed_time},         $show_wp);

	$this->{_loading_editor} = 1;

	$this->{ed_name}->SetValue($data->{name}       // '') if $show_name;
	$this->{ed_comment}->SetValue($data->{comment} // '') if $show_comment;

	if ($show_latlon)
	{
		my $lat = ($data->{lat} // 0) + 0;
		my $lon = ($data->{lon} // 0) + 0;
		$this->{ed_lat}->SetValue(sprintf('%.6f', $lat));
		$this->{ed_lon}->SetValue(sprintf('%.6f', $lon));
		_updateLatDDM($this);
		_updateLonDDM($this);
	}

	$this->{ed_sym}->SetSelection(($data->{sym}   // 0) + 0) if $show_sym;
	$this->{ed_color_choice}->SetSelection(($data->{color} // 0) + 0) if $show_color;

	if ($show_wp)
	{
		my $use_feet = getPref($PREF_DEPTH_DISPLAY);
		my $use_fahr = getPref($PREF_FAHRENHEIT);

		my $depth_cm   = ($data->{depth} // 0) + 0;
		my $depth_disp = $use_feet ? $depth_cm * 0.0328084 : $depth_cm / 100;
		$this->{ed_depth}->SetValue(sprintf('%.1f', $depth_disp));
		$this->{ed_depth_unit}->SetLabel($use_feet ? 'ft' : 'm');

		my $temp_k100  = ($data->{temp}  // 0) + 0;
		my $temp_c     = $temp_k100 / 100 - 273.15;
		my $temp_disp  = $use_fahr ? $temp_c * 9 / 5 + 32 : $temp_c;
		$this->{ed_temp}->SetValue(sprintf('%.1f', $temp_disp));
		$this->{ed_temp_unit}->SetLabel($use_fahr ? 'F' : 'C');

		my $date_val              = ($data->{date} // 0) + 0;
		my ($d_mday, $d_mon, $d_yr) = (gmtime($date_val * 86400))[3, 4, 5];
		$this->{ed_date}->SetValue(Wx::DateTime->newFromDMY($d_mday, $d_mon, $d_yr + 1900));

		my $time_sec = ($data->{time} // 0) + 0;
		$this->{ed_time}->SetValue(sprintf('%02d:%02d:%02d',
			int($time_sec / 3600),
			int(($time_sec % 3600) / 60),
			$time_sec % 60));
	}

	$this->{ed_visible}->Show(1);
	if ($type eq 'group')
	{
		my @member_uuids = map  { $_->{uuid} }
		                   grep { $_->{uuid} } @{$data->{wpts} // []};
		my $total   = scalar @member_uuids;
		my $visible = scalar grep { getFSHVisible($_) } @member_uuids;
		my $vs = ($total && $visible == $total) ? 1 : ($visible > 0) ? 2 : 0;
		$this->{ed_visible}->Set3StateValue(
			$vs == 1 ? wxCHK_CHECKED :
			$vs == 2 ? wxCHK_UNDETERMINED :
			           wxCHK_UNCHECKED);
	}
	else
	{
		$this->{ed_visible}->Set3StateValue(
			getFSHVisible($uuid // '') ? wxCHK_CHECKED : wxCHK_UNCHECKED);
	}

	$this->{_loading_editor} = 0;
	$this->{right_split}->SetSashPosition(
		$show_wp ? $this->{_ed_sash_wp} : $this->{_ed_sash_other});
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
		if (!defined $lat || !defined $lon)
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
			$wp_rec->{temp}    = $temp_k100;
			$wp_rec->{date}    = $date_val;
			$wp_rec->{time}    = $time_sec;
		}

		$this->{tree}->SetItemText($this->{_edit_item}, $name) if $this->{_edit_item};
		if (getFSHVisible($uuid))
		{
			removeRenderFeatures([$uuid]);
			addRenderFeatures([_buildWpFeature($uuid, $wp_rec)]) if $wp_rec;
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
			my $feat = _buildRouteFeature($uuid, $r_rec);
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
			my $feat = _buildTrackFeature($uuid, $t_rec);
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


sub _onEdVisibleChanged
{
	my ($this, $event) = @_;
	return if $this->{_loading_editor};
	my $uuid = $this->{_edit_uuid};
	return if !$uuid;

	my $cb = $this->{ed_visible}->Get3StateValue();
	return if $cb == wxCHK_UNDETERMINED;
	my $new_visible = ($cb == wxCHK_CHECKED) ? 1 : 0;

	my $item = $this->{_edit_item};
	if ($item && $item->IsOk())
	{
		my $d = $this->{tree}->GetItemData($item);
		if ($d)
		{
			my $node = $d->GetData();
			if (ref $node eq 'HASH')
			{
				_applyNodeVisibility($this, $item, $node, $new_visible);
				_refreshAncestorStates($this, $item);
			}
		}
	}
	openMapBrowser() if $new_visible && !isBrowserConnected();
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
	_walkRestoreStateImages($tree, $root);
	_syncLeafletAfterRebuild();
	$tree->Expand($root);
	_walkRestoreExpanded($tree, $root, $this->{_expanded_keys});
	_walkRestoreSelected($tree, $root, $this->{_selected_keys});
}


sub _name_sort_key
{
	my ($name) = @_;
	my $lc = lc($name // '');
	return $lc =~ /^(.*?)(\d+)$/ ? $1 . sprintf('%020d', $2) : $lc;
}


sub _buildGroups
{
	my ($this, $tree, $root, $db) = @_;
	my $wps    = $db->{waypoints} // {};
	my $groups = $db->{groups}    // {};

	my $hdr = $tree->AppendItem($root, 'Groups', -1, -1,
		Wx::TreeItemData->new({ type => 'header', kind => 'groups' }));

	# BLK_WPT standalone waypoints → My Waypoints
	my @wpt_uuids = sort { _name_sort_key($wps->{$a}{name}) cmp _name_sort_key($wps->{$b}{name}) }
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
	for my $uuid (sort { _name_sort_key($groups->{$a}{name}) cmp _name_sort_key($groups->{$b}{name}) }
	              keys %$groups)
	{
		my $grp  = $groups->{$uuid};
		my $wpts = $grp->{wpts} // [];
		my $n    = scalar @$wpts;
		my $grp_item = $tree->AppendItem($hdr, "$grp->{name} ($n wps)", -1, -1,
			Wx::TreeItemData->new({ type => 'group', uuid => $uuid, data => $grp }));

		my @sorted = sort { _name_sort_key($a->{name}) cmp _name_sort_key($b->{name}) } @$wpts;
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

	for my $uuid (sort { _name_sort_key($routes->{$a}{name}) cmp _name_sort_key($routes->{$b}{name}) }
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

	for my $uuid (sort { _name_sort_key($tracks->{$a}{name}) cmp _name_sort_key($tracks->{$b}{name}) }
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
		_clearEditor($this);
		$text = "FSH file: $navFSH::fsh_filename\n";
	}
	elsif ($type eq 'header')
	{
		_clearEditor($this);
		$text = "($node->{kind})";
	}
	elsif ($type eq 'my_waypoints')
	{
		_clearEditor($this);
		$text = "Standalone waypoints (BLK_WPT) not assigned to any named group.";
	}
	elsif ($type eq 'route_point' && $node->{data})
	{
		_clearEditor($this);
		$text = _fshWaypointText($node);
	}
	elsif ($type eq 'waypoint' && $node->{data})
	{
		$this->{_edit_item} = $item;
		_loadEditor($this, $node);
		$text = _fshWaypointText($node);
	}
	elsif ($type eq 'group' && $node->{data})
	{
		$this->{_edit_item} = $item;
		_loadEditor($this, $node);
		my $grp  = $node->{data};
		my $wpts = $grp->{wpts} // [];
		$text  = "Group: $grp->{name}\n";
		$text .= sprintf("  %-12s = %s\n", 'uuid', $node->{uuid}) if $node->{uuid};
		$text .= sprintf("  %-12s = %d\n", 'waypoints', scalar @$wpts);
	}
	elsif ($type eq 'route' && $node->{data})
	{
		$this->{_edit_item} = $item;
		_loadEditor($this, $node);
		$text = _fshRouteText($node);
	}
	elsif ($type eq 'track' && $node->{data})
	{
		$this->{_edit_item} = $item;
		_loadEditor($this, $node);
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
	if ($wp->{temp})
	{
		my $t_f = sprintf('%.1f F', ($wp->{temp} / 100 - 273) * 9 / 5 + 32);
		$text .= sprintf("  %-12s = %d  (%s)\n", 'temp', $wp->{temp}, $t_f);
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
	$text .= "UUID:   $node->{uuid}\n" if $node->{uuid};
	$text .= "Points: $pts\n";
	$text .= "Color:  $track->{color}\n" if defined $track->{color};
	if (@$points)
	{
		$text .= "\n";
		for my $i (0 .. $#$points)
		{
			my $pt   = $points->[$i];
			my $d_ft = ($pt->{depth} // 0) ? sprintf('%.1fft', $pt->{depth} / 30.48) : '-';
			my $t_f  = ($pt->{temp}  // 0) ? sprintf('%.1fF',  ($pt->{temp}  / 100 - 273) * 9 / 5 + 32) : '-';
			$text .= sprintf("  %2d  %9.6f  %10.6f  %7s  %s\n",
				$i + 1, ($pt->{lat} // 0) + 0, ($pt->{lon} // 0) + 0, $d_ft, $t_f);
		}
	}
	return $text;
}


#---------------------------------
# tree state - expand / select
#---------------------------------

sub _nodeKey
{
	my ($node) = @_;
	return undef if ref $node ne 'HASH';
	my $t = $node->{type} // '';
	return "header:$node->{kind}"                    if $t eq 'header';
	return 'my_waypoints'                            if $t eq 'my_waypoints';
	return "rp:$node->{route_uuid}:$node->{uuid}"   if $t eq 'route_point';
	return $node->{uuid};
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
			_walkExpCapture($tree, $child, \%keys);
			($child, $cookie) = $tree->GetNextChild($root, $cookie);
		}
	}
	$this->{_expanded_keys} = \%keys;
}


sub _walkExpCapture
{
	my ($tree, $item, $result) = @_;
	return if !$item->IsOk();
	if ($tree->IsExpanded($item))
	{
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
	}
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		_walkExpCapture($tree, $child, $result);
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
	$this->{_selected_keys} = \%keys;
}


sub _walkRestoreExpanded
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
			$tree->Expand($item) if $key && $expanded->{$key};
		}
	}
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		_walkRestoreExpanded($tree, $child, $expanded);
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
}


sub _walkRestoreSelected
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
			$tree->SelectItem($item) if $key && $selected->{$key};
		}
	}
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		_walkRestoreSelected($tree, $child, $selected);
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
}


#---------------------------------
# checkbox state bitmaps
#---------------------------------

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
# GeoJSON feature builders
#---------------------------------

sub _buildWpFeature
{
	my ($uuid, $wp) = @_;
	return {
		type       => 'Feature',
		properties => {
			uuid        => $uuid,
			name        => $wp->{name}  // '',
			obj_type    => 'waypoint',
			data_source => 'fsh',
			wp_type     => 'nav',
			color       => 'FF888888',
			lat         => ($wp->{lat}  // 0) + 0,
			lon         => ($wp->{lon}  // 0) + 0,
		},
		geometry   => { type => 'Point',
			coordinates => [($wp->{lon}//0)+0, ($wp->{lat}//0)+0] },
	};
}


sub _buildRouteFeature
{
	my ($uuid, $r) = @_;
	my $wpts = $r->{wpts} // [];
	return undef if !@$wpts;
	my $cidx     = defined($r->{color}) ? ($r->{color} + 0) : 0;
	my $color    = $E80_ROUTE_COLOR_ABGR[$cidx] // 'FF888888';
	my @rp_names = map { $_->{name} // '' } @$wpts;
	return {
		type       => 'Feature',
		properties => {
			uuid        => $uuid,
			name        => $r->{name}  // '',
			obj_type    => 'route',
			data_source => 'fsh',
			color       => $color,
			wp_count    => scalar(@$wpts) + 0,
			rp_names    => \@rp_names,
		},
		geometry   => { type => 'LineString',
			coordinates => [map { [($_->{lon}//0)+0, ($_->{lat}//0)+0] } @$wpts] },
	};
}


sub _buildTrackFeature
{
	my ($uuid, $track) = @_;
	my $pts = ref $track->{points} eq 'ARRAY' ? $track->{points} : [];
	return undef if !@$pts;
	my $cidx  = defined($track->{color}) ? ($track->{color} + 0) : 0;
	my $color = $E80_ROUTE_COLOR_ABGR[$cidx] // 'FF888888';
	return {
		type       => 'Feature',
		properties => {
			uuid        => $uuid,
			name        => $track->{name}  // '',
			obj_type    => 'track',
			data_source => 'fsh',
			color       => $color,
			point_count => scalar(@$pts) + 0,
		},
		geometry   => { type => 'LineString',
			coordinates => [map { [($_->{lon}//0)+0, ($_->{lat}//0)+0] } @$pts] },
	};
}


#---------------------------------
# visibility apply
#---------------------------------

sub _applyWpVisibility
{
	my ($uuid, $wp, $new_visible) = @_;
	return if !$uuid;
	if ($new_visible)
	{
		return if !$wp;
		setFSHVisible($uuid, 1);
		addRenderFeatures([_buildWpFeature($uuid, $wp)]);
	}
	else
	{
		setFSHVisible($uuid, 0);
		removeRenderFeatures([$uuid]);
	}
}


sub _applyRouteVisibility
{
	my ($uuid, $r, $new_visible) = @_;
	return if !$uuid;
	if ($new_visible)
	{
		return if !$r;
		my $feature = _buildRouteFeature($uuid, $r);
		return if !$feature;
		setFSHVisible($uuid, 1);
		addRenderFeatures([$feature]);
	}
	else
	{
		setFSHVisible($uuid, 0);
		removeRenderFeatures([$uuid]);
	}
}


sub _applyTrackVisibility
{
	my ($uuid, $track, $new_visible) = @_;
	return if !$uuid;
	if ($new_visible)
	{
		return if !$track;
		my $feature = _buildTrackFeature($uuid, $track);
		return if !$feature;
		setFSHVisible($uuid, 1);
		addRenderFeatures([$feature]);
	}
	else
	{
		setFSHVisible($uuid, 0);
		removeRenderFeatures([$uuid]);
	}
}


sub _applyNodeVisibility
{
	my ($this, $item, $node, $new_visible) = @_;
	my $type = $node->{type} // '';
	my $tree = $this->{tree};
	my $db   = $navFSH::fsh_db;

	return if $type eq 'root' || $type eq 'route_point';

	if ($type eq 'waypoint')
	{
		_applyWpVisibility($node->{uuid}, $node->{data}, $new_visible);
		$tree->SetItemState($item, $new_visible ? 1 : 0);
	}
	elsif ($type eq 'route')
	{
		_applyRouteVisibility($node->{uuid}, $node->{data}, $new_visible);
		$tree->SetItemState($item, $new_visible ? 1 : 0);
	}
	elsif ($type eq 'track')
	{
		_applyTrackVisibility($node->{uuid}, $node->{data}, $new_visible);
		$tree->SetItemState($item, $new_visible ? 1 : 0);
	}
	elsif ($type eq 'group')
	{
		for my $wp (@{$node->{data}{wpts} // []})
		{
			_applyWpVisibility($wp->{uuid}, $wp, $new_visible) if $wp->{uuid};
		}
		$tree->SetItemState($item, $new_visible ? 1 : 0);
		_walkSetSubtreeState($tree, $item, $new_visible);
	}
	elsif ($type eq 'my_waypoints')
	{
		my $wps = $db ? ($db->{waypoints} // {}) : {};
		for my $uuid (keys %$wps)
		{
			_applyWpVisibility($uuid, $wps->{$uuid}, $new_visible);
		}
		$tree->SetItemState($item, $new_visible ? 1 : 0);
		_walkSetSubtreeState($tree, $item, $new_visible);
	}
	elsif ($type eq 'header')
	{
		my $kind = $node->{kind} // '';
		if ($kind eq 'groups')
		{
			my $wps    = $db ? ($db->{waypoints} // {}) : {};
			my $groups = $db ? ($db->{groups}    // {}) : {};
			for my $uuid (keys %$wps)
			{
				_applyWpVisibility($uuid, $wps->{$uuid}, $new_visible);
			}
			for my $grp (values %$groups)
			{
				for my $wp (@{$grp->{wpts} // []})
				{
					_applyWpVisibility($wp->{uuid}, $wp, $new_visible) if $wp->{uuid};
				}
			}
		}
		elsif ($kind eq 'routes')
		{
			my $routes = $db ? ($db->{routes} // {}) : {};
			for my $uuid (keys %$routes)
			{
				_applyRouteVisibility($uuid, $routes->{$uuid}, $new_visible);
			}
		}
		elsif ($kind eq 'tracks')
		{
			my $tracks = $db ? ($db->{tracks} // {}) : {};
			for my $uuid (keys %$tracks)
			{
				_applyTrackVisibility($uuid, $tracks->{$uuid}, $new_visible);
			}
		}
		$tree->SetItemState($item, $new_visible ? 1 : 0);
		_walkSetSubtreeState($tree, $item, $new_visible);
	}
}


#---------------------------------
# checkbox toggle
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
	my $type = $node->{type} // '';
	return if $type eq 'root' || $type eq 'route_point';

	my $cur_state   = $this->{tree}->GetItemState($item);
	my $new_visible = ($cur_state == 1) ? 0 : 1;

	_applyNodeVisibility($this, $item, $node, $new_visible);
	_refreshAncestorStates($this, $item);
	openMapBrowser() if $new_visible && !isBrowserConnected();
}


#---------------------------------
# tree state - checkbox images
#---------------------------------

sub _walkRestoreStateImages
{
	my ($tree, $item) = @_;
	return if !$item || !$item->IsOk();
	my $d = $tree->GetItemData($item);
	if ($d)
	{
		my $node = $d->GetData();
		if (ref $node eq 'HASH')
		{
			my $type = $node->{type} // '';
			if ($type eq 'waypoint' || $type eq 'route' || $type eq 'track')
			{
				$tree->SetItemState($item, getFSHVisible($node->{uuid} // '') ? 1 : 0);
				if ($type eq 'route')
				{
					my ($child, $cookie) = $tree->GetFirstChild($item);
					while ($child && $child->IsOk())
					{
						$tree->SetItemState($child, 0);
						($child, $cookie) = $tree->GetNextChild($item, $cookie);
					}
				}
				return;
			}
			elsif ($type eq 'route_point')
			{
				$tree->SetItemState($item, 0);
				return;
			}
			elsif ($type eq 'header' || $type eq 'my_waypoints' || $type eq 'group')
			{
				my ($child, $cookie) = $tree->GetFirstChild($item);
				while ($child && $child->IsOk())
				{
					_walkRestoreStateImages($tree, $child);
					($child, $cookie) = $tree->GetNextChild($item, $cookie);
				}
				$tree->SetItemState($item, _computeContainerState($tree, $item));
				return;
			}
		}
	}
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		_walkRestoreStateImages($tree, $child);
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
}


sub _walkSetSubtreeState
{
	my ($tree, $item, $visible) = @_;
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		my $d    = $tree->GetItemData($child);
		my $type = '';
		if ($d) { my $n = $d->GetData(); $type = (ref $n eq 'HASH') ? ($n->{type} // '') : ''; }
		$tree->SetItemState($child, $visible ? 1 : 0) if $type ne 'route_point';
		_walkSetSubtreeState($tree, $child, $visible);
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
}


sub _computeContainerState
{
	my ($tree, $item) = @_;
	my ($total, $visible) = (0, 0);
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		my $d = $tree->GetItemData($child);
		if ($d)
		{
			my $node = $d->GetData();
			if (ref $node eq 'HASH' && ($node->{type} // '') ne 'route_point')
			{
				$total++;
				$visible++ if $tree->GetItemState($child) == 1;
			}
		}
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
	return 0 if !$total;
	return $visible == $total ? 1 : $visible == 0 ? 0 : 2;
}


sub _refreshAncestorStates
{
	my ($this, $item) = @_;
	my $tree   = $this->{tree};
	my $parent = $tree->GetItemParent($item);
	while ($parent && $parent->IsOk())
	{
		my $d = $tree->GetItemData($parent);
		last if !$d;
		my $node = $d->GetData();
		last if ref $node ne 'HASH';
		last if ($node->{type} // '') eq 'root';
		$tree->SetItemState($parent, _computeContainerState($tree, $parent));
		$parent = $tree->GetItemParent($parent);
	}
}


#---------------------------------
# leaflet sync after FSH reload
#---------------------------------

sub _syncLeafletAfterRebuild
{
	my $db = $navFSH::fsh_db;
	return if !$db;
	my @all_visible = getAllFSHVisibleUUIDs();
	return if !@all_visible;

	my %all_wpts;
	for my $uuid (keys %{$db->{waypoints} // {}})
	{
		$all_wpts{$uuid} = $db->{waypoints}{$uuid};
	}
	for my $grp (values %{$db->{groups} // {}})
	{
		for my $wp (@{$grp->{wpts} // []})
		{
			$all_wpts{$wp->{uuid}} = $wp if $wp->{uuid};
		}
	}

	my (@stale, @to_remove, @features);
	for my $uuid (@all_visible)
	{
		if (my $wp = $all_wpts{$uuid})
		{
			push @features, _buildWpFeature($uuid, $wp);
		}
		elsif (my $r = $db->{routes}{$uuid})
		{
			my $f = _buildRouteFeature($uuid, $r);
			push @features, $f if $f;
		}
		elsif (my $t = $db->{tracks}{$uuid})
		{
			my $f = _buildTrackFeature($uuid, $t);
			push @features, $f if $f;
		}
		else
		{
			push @stale,     $uuid;
			push @to_remove, $uuid;
		}
	}
	batchRemoveFSHVisible(\@stale)    if @stale;
	removeRenderFeatures(\@to_remove) if @to_remove;
	addRenderFeatures(\@features)     if @features;
}


1;
