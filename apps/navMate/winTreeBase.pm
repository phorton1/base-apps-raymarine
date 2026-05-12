#!/usr/bin/perl
#-------------------------------------------------------------------------
# winTreeBase.pm
#-------------------------------------------------------------------------
# Base class shared by winE80 and winFSH.  Provides the tree/editor/
# visibility/Leaflet infrastructure common to both windows.
# Subclasses supply 16 abstract methods for the per-source differences.

package winTreeBase;
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
use n_defs;
use n_utils;
use navPrefs;
use navServer qw(addRenderFeatures removeRenderFeatures openMapBrowser isBrowserConnected);
use base qw(Wx::SplitterWindow Pub::WX::Window);


#---------------------------------
# Abstract method stubs
#---------------------------------
# Visibility store:
#   _getVisible($uuid)             read one flag
#   _setVisible($uuid, $val)       write one flag
#   _clearAllVisible()             clear all flags
#   _getAllVisibleUUIDs()           list of currently visible UUIDs
#   _batchRemoveVisible(\@stale)   remove a set of flags
#
# Feature building:
#   _wpDataSource()                'e80' or 'fsh'
#   _wpLatLon($wp)                 ($lat, $lon) decimal degrees
#   _wpColor($wp)                  ABGR hex string
#   _routeWpts($r)                 list of {lat,lon,name} already scaled
#   _trackColorABGR($track)        ABGR hex string
#
# Data access:
#   _myWaypoints()                 {uuid=>wp} for My Waypoints subtree
#   _allWaypoints()                {uuid=>wp} all waypoints flat
#   _allRoutes()                   {uuid=>r}
#   _allTracks()                   {uuid=>t}
#   _groupMemberWpts($data)        list of [$uuid,$wp] for a group record
#
# Editor:
#   _groupHasComment()             1 if groups have a comment field, else 0

sub _getVisible         { error("winTreeBase: _getVisible is abstract");         return }
sub _setVisible         { error("winTreeBase: _setVisible is abstract");         return }
sub _clearAllVisible    { error("winTreeBase: _clearAllVisible is abstract");    return }
sub _getAllVisibleUUIDs { error("winTreeBase: _getAllVisibleUUIDs is abstract");  return }
sub _batchRemoveVisible { error("winTreeBase: _batchRemoveVisible is abstract"); return }
sub _wpDataSource       { error("winTreeBase: _wpDataSource is abstract");       return }
sub _wpLatLon           { error("winTreeBase: _wpLatLon is abstract");           return }
sub _wpColor            { error("winTreeBase: _wpColor is abstract");            return }
sub _routeWpts          { error("winTreeBase: _routeWpts is abstract");          return }
sub _trackColorABGR     { error("winTreeBase: _trackColorABGR is abstract");    return }
sub _myWaypoints        { error("winTreeBase: _myWaypoints is abstract");        return }
sub _allWaypoints       { error("winTreeBase: _allWaypoints is abstract");       return }
sub _allRoutes          { error("winTreeBase: _allRoutes is abstract");          return }
sub _allTracks          { error("winTreeBase: _allTracks is abstract");          return }
sub _groupMemberWpts    { error("winTreeBase: _groupMemberWpts is abstract");    return }
sub _groupHasComment    { error("winTreeBase: _groupHasComment is abstract");    return }


sub _groupMemberUUIDs
{
    my ($this, $data) = @_;
    return map { $_->[0] } $this->_groupMemberWpts($data);
}


#---------------------------------
# tree state - sort key
#---------------------------------

sub _name_sort_key
{
    my ($name) = @_;
    my $lc = lc($name // '');
    return $lc =~ /^(.*?)(\d+)$/ ? $1 . sprintf('%020d', $2) : $lc;
}


#---------------------------------
# tree state - node key
#---------------------------------

sub _nodeKey
{
    my ($node) = @_;
    return undef if ref $node ne 'HASH';
    my $t = $node->{type} // '';
    return "header:$node->{kind}"                  if $t eq 'header';
    return 'my_waypoints'                          if $t eq 'my_waypoints';
    return "rp:$node->{route_uuid}:$node->{uuid}" if $t eq 'route_point';
    return $node->{uuid};
}


#---------------------------------
# tree state - expand / select capture
#---------------------------------

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


#---------------------------------
# tree state - expand / select restore
#---------------------------------

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
            $tree->SelectItem($item, 1) if $key && $selected->{$key};
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
# tree state - checkbox images
#---------------------------------

sub _walkRestoreStateImages
{
    my ($this, $tree, $item) = @_;
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
                $tree->SetItemState($item, $this->_getVisible($node->{uuid} // '') ? 1 : 0);
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
                    _walkRestoreStateImages($this, $tree, $child);
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
        _walkRestoreStateImages($this, $tree, $child);
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
# checkbox click / clear map
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


sub onClearMap
{
    my ($this) = @_;
    $this->_clearAllVisible();
    my $tree = $this->{tree};
    my $root = $tree->GetRootItem();
    _walkSetSubtreeState($tree, $root, 0) if $root && $root->IsOk();
    $this->{ed_visible}->Set3StateValue(wxCHK_UNCHECKED)
        if $this->{ed_visible} && $this->{ed_visible}->IsShown();
}


#---------------------------------
# editor panel helpers
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
    my $show_comment = ($type eq 'waypoint'
                    || ($type eq 'group' && $this->_groupHasComment())
                    || $type eq 'route');
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
        my ($lat, $lon) = $this->_wpLatLon($data);
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
        my @member_uuids = $this->_groupMemberUUIDs($data);
        my $total   = scalar @member_uuids;
        my $visible = scalar grep { $this->_getVisible($_) } @member_uuids;
        my $vs = ($total && $visible == $total) ? 1 : ($visible > 0) ? 2 : 0;
        $this->{ed_visible}->Set3StateValue(
            $vs == 1 ? wxCHK_CHECKED :
            $vs == 2 ? wxCHK_UNDETERMINED :
                       wxCHK_UNCHECKED);
    }
    else
    {
        $this->{ed_visible}->Set3StateValue(
            $this->_getVisible($uuid // '') ? wxCHK_CHECKED : wxCHK_UNCHECKED);
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
    $this->{ed_lat_ddm}->SetLabel(defined($dd) ? _ddm_label($dd, 1) : '');
}


sub _updateLonDDM
{
    my ($this) = @_;
    my $dd = parseLatLon($this->{ed_lon}->GetValue());
    $this->{ed_lon_ddm}->SetLabel(defined($dd) ? _ddm_label($dd, 0) : '');
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


#---------------------------------
# editor visibility checkbox
#---------------------------------

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
# GeoJSON feature builders
#---------------------------------

sub _buildWpFeature
{
    my ($this, $uuid, $wp) = @_;
    my ($lat, $lon) = $this->_wpLatLon($wp);
    return {
        type       => 'Feature',
        properties => {
            uuid        => $uuid,
            name        => $wp->{name}    // '',
            obj_type    => 'waypoint',
            data_source => $this->_wpDataSource(),
            wp_type     => $wp->{wp_type} // 'nav',
            color       => $this->_wpColor($wp),
            lat         => $lat,
            lon         => $lon,
        },
        geometry   => { type => 'Point', coordinates => [$lon, $lat] },
    };
}


sub _buildRouteFeature
{
    my ($this, $uuid, $r) = @_;
    my @wpts = $this->_routeWpts($r);
    return undef if !@wpts;
    my $cidx  = defined($r->{color}) ? ($r->{color} + 0) : 0;
    my $color = $E80_ROUTE_COLOR_ABGR[$cidx] // 'FF888888';
    return {
        type       => 'Feature',
        properties => {
            uuid        => $uuid,
            name        => $r->{name}  // '',
            obj_type    => 'route',
            data_source => $this->_wpDataSource(),
            color       => $color,
            wp_count    => scalar(@wpts) + 0,
            rp_names    => [map { $_->{name} } @wpts],
        },
        geometry   => { type => 'LineString',
            coordinates => [map { [$_->{lon}, $_->{lat}] } @wpts] },
    };
}


sub _buildTrackFeature
{
    my ($this, $uuid, $track) = @_;
    my $pts = ref $track->{points} eq 'ARRAY' ? $track->{points} : [];
    return undef if !@$pts;
    my $comp = $track->{companion_uuid} // $track->{trk_uuid};
    return {
        type       => 'Feature',
        properties => {
            uuid        => $uuid,
            name        => $track->{name}  // '',
            obj_type    => 'track',
            data_source => $this->_wpDataSource(),
            color       => $this->_trackColorABGR($track),
            point_count => scalar(@$pts) + 0,
            ($comp ? (companion_uuid => $comp) : ()),
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
    my ($this, $uuid, $wp, $new_visible) = @_;
    return if !$uuid;
    if ($new_visible)
    {
        return if !$wp;
        $this->_setVisible($uuid, 1);
        addRenderFeatures([_buildWpFeature($this, $uuid, $wp)]);
    }
    else
    {
        $this->_setVisible($uuid, 0);
        removeRenderFeatures([$uuid]);
    }
}


sub _applyRouteVisibility
{
    my ($this, $uuid, $r, $new_visible) = @_;
    return if !$uuid;
    if ($new_visible)
    {
        return if !$r;
        my $feature = _buildRouteFeature($this, $uuid, $r);
        return if !$feature;
        $this->_setVisible($uuid, 1);
        addRenderFeatures([$feature]);
    }
    else
    {
        $this->_setVisible($uuid, 0);
        removeRenderFeatures([$uuid]);
    }
}


sub _applyTrackVisibility
{
    my ($this, $uuid, $track, $new_visible) = @_;
    return if !$uuid;
    if ($new_visible)
    {
        return if !$track;
        my $feature = _buildTrackFeature($this, $uuid, $track);
        return if !$feature;
        $this->_setVisible($uuid, 1);
        addRenderFeatures([$feature]);
    }
    else
    {
        $this->_setVisible($uuid, 0);
        removeRenderFeatures([$uuid]);
    }
}


sub _applyNodeVisibility
{
    my ($this, $item, $node, $new_visible) = @_;
    my $type = $node->{type} // '';
    my $tree = $this->{tree};

    return if $type eq 'root' || $type eq 'route_point';

    if ($type eq 'waypoint')
    {
        _applyWpVisibility($this, $node->{uuid}, $node->{data}, $new_visible);
        $tree->SetItemState($item, $new_visible ? 1 : 0);
    }
    elsif ($type eq 'route')
    {
        _applyRouteVisibility($this, $node->{uuid}, $node->{data}, $new_visible);
        $tree->SetItemState($item, $new_visible ? 1 : 0);
    }
    elsif ($type eq 'track')
    {
        _applyTrackVisibility($this, $node->{uuid}, $node->{data}, $new_visible);
        $tree->SetItemState($item, $new_visible ? 1 : 0);
    }
    elsif ($type eq 'group')
    {
        for my $pair ($this->_groupMemberWpts($node->{data}))
        {
            _applyWpVisibility($this, $pair->[0], $pair->[1], $new_visible);
        }
        $tree->SetItemState($item, $new_visible ? 1 : 0);
        _walkSetSubtreeState($tree, $item, $new_visible);
    }
    elsif ($type eq 'my_waypoints')
    {
        my $wps = $this->_myWaypoints();
        for my $uuid (keys %$wps)
        {
            _applyWpVisibility($this, $uuid, $wps->{$uuid}, $new_visible);
        }
        $tree->SetItemState($item, $new_visible ? 1 : 0);
        _walkSetSubtreeState($tree, $item, $new_visible);
    }
    elsif ($type eq 'header')
    {
        my $kind = $node->{kind} // '';
        if ($kind eq 'groups')
        {
            my $wps = $this->_allWaypoints();
            for my $uuid (keys %$wps)
            {
                _applyWpVisibility($this, $uuid, $wps->{$uuid}, $new_visible);
            }
        }
        elsif ($kind eq 'routes')
        {
            my $routes = $this->_allRoutes();
            for my $uuid (keys %$routes)
            {
                _applyRouteVisibility($this, $uuid, $routes->{$uuid}, $new_visible);
            }
        }
        elsif ($kind eq 'tracks')
        {
            my $tracks = $this->_allTracks();
            for my $uuid (keys %$tracks)
            {
                _applyTrackVisibility($this, $uuid, $tracks->{$uuid}, $new_visible);
            }
        }
        $tree->SetItemState($item, $new_visible ? 1 : 0);
        _walkSetSubtreeState($tree, $item, $new_visible);
    }
}


#---------------------------------
# leaflet sync after rebuild
#---------------------------------

sub _syncLeafletAfterRebuild
{
    my ($this) = @_;
    my @all_visible = $this->_getAllVisibleUUIDs();
    return if !@all_visible;

    my $all_wpts   = $this->_allWaypoints();
    my $all_routes = $this->_allRoutes();
    my $all_tracks = $this->_allTracks();

    my (@stale, @to_remove, @features);
    for my $uuid (@all_visible)
    {
        if (my $wp = $all_wpts->{$uuid})
        {
            push @features, _buildWpFeature($this, $uuid, $wp);
        }
        elsif (my $r = $all_routes->{$uuid})
        {
            my $f = _buildRouteFeature($this, $uuid, $r);
            push @features, $f if $f;
        }
        elsif (my $t = $all_tracks->{$uuid})
        {
            my $f = _buildTrackFeature($this, $uuid, $t);
            push @features, $f if $f;
        }
        else
        {
            push @stale,     $uuid;
            push @to_remove, $uuid;
        }
    }
    $this->_batchRemoveVisible(\@stale)   if @stale;
    removeRenderFeatures(\@to_remove)     if @to_remove;
    addRenderFeatures(\@features)         if @features;
}


1;
