#!/usr/bin/perl
#-------------------------------------------------------------------------
# winTreeBase.pm
#-------------------------------------------------------------------------
# Base class for winDatabase, winE80, and winFSH.  Provides the tree/editor/
# visibility/Leaflet infrastructure common to the three windows.
# Subclasses supply 16 abstract methods for the per-source differences.
# winE80 and winFSH override all 16; winDatabase currently overrides only
# _wpDataSource and reaches into shared helpers directly (refactor pending).

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
use navVisibility;
use base qw(Wx::SplitterWindow Pub::WX::Window);
use winTreeColors;


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
    return "trackgrp:$node->{prefix}"              if $t eq 'track_group';
    # Pane header rows (Database / E80 / FSH banner at the top of each
    # tree) use type='root' with data.uuid=undef.  Give them a stable
    # key so _captureFirstVisibleInto can record them when they're the
    # topmost visible item -- otherwise the undef key bails out of
    # _walkRestoreFirstVisible and the viewport drifts.
    my $banner_name = ($node->{data} // {})->{name};
    return 'root:' . ($banner_name // 'header')   if $t eq 'root';
    # winDatabase nodes carry their uuid inside data; E80/FSH carry it
    # at top level.  The fallback handles both.
    return $node->{uuid} // ($node->{data} // {})->{uuid};
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
# tree state - scroll viewport (first visible item)
#---------------------------------
# refresh() does a full DeleteAllItems+rebuild, resetting scroll to 0.
# _walkRestoreExpanded's Expand() calls and _walkRestoreSelected's
# SelectItem() calls each scroll the viewport to wherever the last-touched
# item lands, which is rarely where the user was looking. To hold the
# viewport steady we capture the node key of the topmost visible item
# before the rebuild and EnsureVisible() it afterward.

sub _captureFirstVisibleInto
{
    # Walk down from the topmost visible item until we find one with a
    # non-undef _nodeKey.  The 'root' banner type is now keyed (above),
    # but the defensive walk also guards against any future node type
    # that lacks a key handler -- without it, an undef key on the
    # topmost visible item silently disables scroll restoration.
    my ($this) = @_;
    my $tree = $this->{tree};
    $this->{_first_visible_key} = undef;

    my $item = $tree->GetFirstVisibleItem();
    while ($item && $item->IsOk())
    {
        my $d = $tree->GetItemData($item);
        if ($d)
        {
            my $node = $d->GetData();
            if (ref $node eq 'HASH')
            {
                my $k = _nodeKey($node);
                if (defined $k)
                {
                    $this->{_first_visible_key} = $k;
                    return;
                }
            }
        }
        $item = $tree->GetNextVisible($item);
    }
}


sub _walkRestoreFirstVisible
{
    my ($tree, $item, $key) = @_;
    return 0 if !defined $key;
    return 0 if !($item && $item->IsOk());
    my $d = $tree->GetItemData($item);
    if ($d)
    {
        my $node = $d->GetData();
        if (ref $node eq 'HASH')
        {
            my $k = _nodeKey($node);
            if ($k && $k eq $key)
            {
                $tree->EnsureVisible($item);
                return 1;
            }
        }
    }
    my ($child, $cookie) = $tree->GetFirstChild($item);
    while ($child && $child->IsOk())
    {
        return 1 if _walkRestoreFirstVisible($tree, $child, $key);
        ($child, $cookie) = $tree->GetNextChild($item, $cookie);
    }
    return 0;
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
            elsif ($type eq 'header' || $type eq 'my_waypoints' || $type eq 'group' || $type eq 'track_group')
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
# visibility observer (cross-pane sync)
#---------------------------------
# Tree panes register an observer with navVisibility at construction time.
# When ANY caller mutates visibility (this pane, another pane, winFind,
# bulk operations), every observer receives a delta hash of the form
# { source => { uuid => new_value, ... }, ... } and updates its widgets to
# match.  This is what keeps multi-instance winDatabase in sync, what lets
# the editor "Visible" checkbox track tree clicks, and what lets winFind
# drive visibility from outside the source pane.
#
# Default observer body (this file) handles E80/FSH-style trees where node
# uuids live at $node->{uuid} and container state is computed by walking the
# loaded tree.  winDatabase overrides the per-node uuid extraction and the
# container-state computation (collections may be lazy-loaded; it consults
# the DB instead).

sub installVisibilityObserver
{
	# Called from each pane's new() after the tree exists and abstract
	# methods are usable.
	my ($this) = @_;
	$this->{_vis_observer_alive} = 1;
	$this->{_vis_observer} = navVisibility::addVisibilityObserver(sub {
		my ($delta) = @_;
		return if !$this->{_vis_observer_alive};
		$this->_onVisibilityDelta($delta);
	});
}


sub uninstallVisibilityObserver
{
	# Mark the closure inert.  Safe to call multiple times.
	my ($this) = @_;
	$this->{_vis_observer_alive} = 0;
	if ($this->{_vis_observer})
	{
		navVisibility::removeVisibilityObserver($this->{_vis_observer});
		$this->{_vis_observer} = undef;
	}
}


#---------------------------------
# focusOnObject  (winFind callback)
#---------------------------------
# Selects the tree item whose node carries the given uuid and brings the
# pane to the front of the notebook.  Default walks the currently-loaded
# tree only; lazy-loaded subtrees that haven't been expanded yet will not
# be found (post-MVP could expand-on-the-way).  Returns 1 if found, 0 if
# not.  Subclasses MAY override to add expand-on-the-way behavior.

sub focusOnObject
{
	my ($this, $uuid, $obj_type) = @_;
	return 0 if !$uuid;
	my $tree = $this->{tree};
	return 0 if !$tree;

	my $found = _findItemByUuid($tree, $tree->GetRootItem(), $uuid);
	return 0 if !$found || !$found->IsOk();

	$tree->UnselectAll();
	$tree->SelectItem($found, 1);
	$tree->EnsureVisible($found);

	# Bring this pane to the front of its notebook.
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


sub _findItemByUuid
{
	my ($tree, $item, $uuid) = @_;
	return undef if !$item || !$item->IsOk();
	my $d = $tree->GetItemData($item);
	if ($d)
	{
		my $node = $d->GetData();
		if (ref $node eq 'HASH')
		{
			# Try top-level uuid (E80/FSH style) then data->uuid (DB style).
			my $cand = $node->{uuid} // (($node->{data} // {})->{uuid});
			return $item if $cand && $cand eq $uuid;
		}
	}
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		my $r = _findItemByUuid($tree, $child, $uuid);
		return $r if $r && $r->IsOk();
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
	return undef;
}


sub _visObserverNodeUuid
{
	# Default: E80/FSH-style node carries uuid at top level.
	my ($this, $node) = @_;
	return $node->{uuid};
}


sub _visObserverIsContainer
{
	# Default: container-style node types whose state is computed from
	# descendants.  winDatabase overrides because its container is
	# 'collection' and its computation is DB-backed.
	my ($this, $node) = @_;
	my $type = $node->{type} // '';
	return ($type eq 'header'
		|| $type eq 'group'
		|| $type eq 'my_waypoints'
		|| $type eq 'track_group');
}


sub _visObserverComputeContainerState
{
	# Default: walk currently-loaded children and band them.
	my ($this, $item, $node) = @_;
	return _computeContainerState($this->{tree}, $item);
}


sub _onVisibilityDelta
{
	my ($this, $delta) = @_;
	my $source = $this->_wpDataSource();
	my $changes = $delta->{$source};
	return if !$changes;
	my $tree = $this->{tree};
	return if !$tree || $tree->GetCount() <= 0;

	$tree->Freeze();
	eval {
		_walkApplyVisDelta($this, $tree, $tree->GetRootItem(), $changes);

		# Editor checkbox sync.  Use _loading_editor guard to suppress
		# the EVT_CHECKBOX from firing _onEdVisibleChanged.
		my $edit_uuid = $this->{_edit_uuid} // '';
		if ($edit_uuid && exists $changes->{$edit_uuid} && $this->{ed_visible})
		{
			$this->{_loading_editor} = 1;
			$this->{ed_visible}->Set3StateValue(
				$changes->{$edit_uuid} ? wxCHK_CHECKED : wxCHK_UNCHECKED);
			$this->{_loading_editor} = 0;
		}
	};
	my $err = $@;
	$tree->Thaw();
	error("_onVisibilityDelta: $err") if $err;
}


sub _walkApplyVisDelta
{
	# Recursive walker: for each item, if its uuid is in the delta set the
	# leaf state; if any descendant changed, recompute container state on
	# the way back up.  Returns 1 if anything in this subtree changed.
	my ($this, $tree, $item, $changes) = @_;
	return 0 if !$item || !$item->IsOk();

	my $d = $tree->GetItemData($item);
	my $is_leaf_change = 0;
	my $node;

	if ($d)
	{
		$node = $d->GetData();
		if (ref $node eq 'HASH')
		{
			my $uuid = $this->_visObserverNodeUuid($node);
			if ($uuid && exists $changes->{$uuid})
			{
				$tree->SetItemState($item, $changes->{$uuid} ? 1 : 0);
				$is_leaf_change = 1;
			}
		}
	}

	my $descendant_change = 0;
	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		my $r = _walkApplyVisDelta($this, $tree, $child, $changes);
		$descendant_change = 1 if $r;
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}

	if ($descendant_change && $node && ref $node eq 'HASH'
		&& $this->_visObserverIsContainer($node))
	{
		$tree->SetItemState($item,
			$this->_visObserverComputeContainerState($item, $node));
	}

	return ($is_leaf_change || $descendant_change) ? 1 : 0;
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
        $this->_onCheckboxClick($item);
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
    # Click cycle on a tristate container: none -> all -> none -> all,
    # mixed -> none -> all.  Going to "none" first from a mixed state
    # preserves whatever the user was visually focused on -- otherwise an
    # implicit "all" toggle re-renders unrelated items and re-autozooms
    # the leaflet outwards, losing the user's context.
    my $new_visible = ($cur_state == 0) ? 1 : 0;

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
# layout walker (per-item-type packed layout)
#---------------------------------
# Class-agnostic on purpose: takes $this as a hashref-of-widgets, not as
# self.  Called as a package function (winTreeBase::_layoutEditor(...))
# rather than a method so the same code serves callers that don't use the
# standard winTreeBase widget setup.
#
# Reads from $this:
#   {_ed_field_widgets}  - { field => [label_key, control_key, [companion_keys]] }
#   {_ed_header_size}, {_ed_row_h}, {_ed_margin}, {_ed_ctrl_x}, {_ed_bottom_pad}
#   {right_panel}, {detail}
#
# Writes:
#   {_editor_height}     - pixel height of the editor strip (header + visible
#                           rows + one row of grey at bottom)
#
# Called with $fields = []  -> editor strip collapses to header + bottom pad,
# every editor widget hidden.  Called with $fields = [...]  -> listed fields
# are positioned top-down with a running y-counter, all other fields hidden.

sub _layoutEditor
{
    my ($this, $fields) = @_;
    $fields ||= [];
    my $widgets = $this->{_ed_field_widgets} || {};
    my %in_show = map { $_ => 1 } @$fields;

    # hide everything not in show list
    for my $field (keys %$widgets)
    {
        next if $in_show{$field};
        my ($lkey, $ckey, $comps) = @{$widgets->{$field}};
        my $lbl  = $lkey ? $this->{$lkey} : undef;
        my $ctrl = $ckey ? $this->{$ckey} : undef;
        $lbl->Show(0)  if $lbl;
        $ctrl->Show(0) if $ctrl;
        for my $ck (@{$comps || []})
        {
            my $w = $this->{$ck};
            $w->Show(0) if $w;
        }
    }

    # position + show fields in registry order
    my $y     = $this->{_ed_header_size};
    my $row_h = $this->{_ed_row_h};
    my $mx    = $this->{_ed_margin};
    my $cx    = $this->{_ed_ctrl_x};

    for my $field (@$fields)
    {
        my $w = $widgets->{$field};
        next if !$w;
        my ($lkey, $ckey, $comps) = @$w;
        my $lbl  = $lkey ? $this->{$lkey} : undef;
        my $ctrl = $ckey ? $this->{$ckey} : undef;
        if ($lbl)  { $lbl->Move([$mx, $y]); $lbl->Show(1); }
        if ($ctrl) { $ctrl->Move([$cx, $y]); $ctrl->Show(1); }
        for my $ck (@{$comps || []})
        {
            my $comp = $this->{$ck};
            next if !$comp;
            my $pos = $comp->GetPosition();
            $comp->Move([$pos->x, $y]);
            $comp->Show(1);
        }
        $y += $row_h;
    }

    my $bottom_pad = $this->{_ed_bottom_pad} // $row_h;
    $this->{_editor_height} = $y + $bottom_pad;
    _resizeRightPanel($this);
    return $this->{_editor_height};
}


sub _resizeRightPanel
{
    my ($this) = @_;
    my $rp = $this->{right_panel};
    return if !$rp;
    my $sz = $rp->GetSize();
    my $w  = $sz->GetWidth();
    my $h  = $sz->GetHeight();
    my $eh = $this->{_editor_height}
          // ($this->{_ed_header_size} + ($this->{_ed_bottom_pad} // $this->{_ed_row_h}));
    my $detail = $this->{detail};
    return if !$detail;
    my $dh = $h - $eh;
    $dh = 0 if $dh < 0;
    $detail->Move([0, $eh]);
    $detail->SetSize($w, $dh);
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
    _layoutEditor($this, []);
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
    my $show_color   = ($type eq 'route')
                    || ($type eq 'track' && $this->_wpDataSource() eq 'fsh');
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

    my @fields;
    push @fields, 'name'    if $show_name;
    push @fields, 'comment' if $show_comment;
    push @fields, 'lat'     if $show_latlon;
    push @fields, 'lon'     if $show_latlon;
    push @fields, 'sym'     if $show_sym;
    push @fields, 'color'   if $show_color;
    push @fields, 'depth'   if $show_wp;
    push @fields, 'temp'    if $show_wp;
    push @fields, 'date'    if $show_wp;
    push @fields, 'time'    if $show_wp;
    _layoutEditor($this, \@fields);

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

        my $temp_k100  = ($data->{temp_k}  // 0) + 0;
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
    # E80/FSH waypoints don't carry a wp_type field on the wire; they
    # render as NAV teardrops in leaflet today.  Leaflet will switch to
    # rendering by sym directly once production-quality sym icons land;
    # at that point wp_type becomes immaterial here.  Sending sym on
    # the wire now is the prep for that switch.
    return {
        type       => 'Feature',
        properties => {
            uuid        => $uuid,
            name        => $wp->{name}    // '',
            obj_type    => 'waypoint',
            data_source => $this->_wpDataSource(),
            wp_type     => $wp->{wp_type} // $WP_TYPE_NAV,
            sym         => $wp->{sym}     // 0,
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


sub _trackPointDepthCm
    # Returns the per-point depth in cm for JSON emission, normalizing
    # absent / sentinel values to undef (JSON null).  Accepts points from
    # either the FSH/E80 path ({depth}) or the DB path ({depth_cm}).
{
    my ($pt) = @_;
    my $d = exists $pt->{depth_cm} ? $pt->{depth_cm} : $pt->{depth};
    return undef if !defined $d;
    return undef if $d == 0xFFFFFFFF;   # uint32 sentinel
    return undef if $d == -1;           # legacy DB rows from pre-uint32-fix era
    return $d + 0;
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
            depth_cm    => [ map { _trackPointDepthCm($_) } @$pts ],
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
        removeRenderFeatures($this->_wpDataSource(), [$uuid]);
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
        removeRenderFeatures($this->_wpDataSource(), [$uuid]);
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
        removeRenderFeatures($this->_wpDataSource(), [$uuid]);
    }
}


sub _applyNodeVisibility
    # Wrapped with navVisibility::begin/endVisibilityBatch so that container-
    # type toggles (group / my_waypoints / track_group / header) produce one
    # observer notification with a complete delta, not one per child UUID.
    # Single-item types (waypoint / route / track) get one set call inside the
    # batch, which still resolves to one notification at endBatch.  No flicker
    # in this pane, no notification storm to other panes.
{
    my ($this, $item, $node, $new_visible) = @_;
    my $type = $node->{type} // '';
    my $tree = $this->{tree};

    return if $type eq 'root' || $type eq 'route_point';

    navVisibility::beginVisibilityBatch();
    eval {

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
    elsif ($type eq 'track_group')
    {
        my $tracks = $this->_allTracks();
        for my $uuid (@{$node->{uuids} // []})
        {
            _applyTrackVisibility($this, $uuid, $tracks->{$uuid}, $new_visible);
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

    };
    my $err = $@;
    navVisibility::endVisibilityBatch();
    error("_applyNodeVisibility: $err") if $err;
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
    $this->_batchRemoveVisible(\@stale)               if @stale;
    removeRenderFeatures($this->_wpDataSource(), \@to_remove) if @to_remove;
    addRenderFeatures(\@features)                     if @features;
}


1;
