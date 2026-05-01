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
# Refresh is triggered by winMain::onIdle whenever the global NET version
# increments (i.e. any WPMGR or TRACK item changes).

package winE80;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_TREE_SEL_CHANGED
	EVT_TREE_ITEM_RIGHT_CLICK
	EVT_MENU);
use Pub::Utils qw(display warning error);
use Pub::WX::Window;
use apps::raymarine::NET::b_records qw(wpmgrRecordToText);
use apps::raymarine::NET::c_RAYDP;
use nmClipboard;
use nmOps;
use w_resources;
use base qw(Wx::SplitterWindow Pub::WX::Window);

our $dbg_wine80 = 0;


sub new
{
	my ($class, $frame, $book, $id, $data) = @_;
	my $this = $class->SUPER::new($book, $id);
	$this->MyWindow($frame, $book, $id, 'E80', $data);

	$this->{tree} = Wx::TreeCtrl->new($this, -1, wxDefaultPosition, wxDefaultSize,
		wxTR_DEFAULT_STYLE | wxTR_HIDE_ROOT | wxTR_MULTIPLE);

	$this->{detail} = Wx::TextCtrl->new($this, -1, '', wxDefaultPosition, wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY | wxTE_DONTWRAP);

	my $font = Wx::Font->new(9, wxFONTFAMILY_MODERN, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL);
	$this->{detail}->SetFont($font);

	my $sash = ($data && ref($data) eq 'HASH' && $data->{sash}) ? $data->{sash} : 250;
	$this->SplitVertically($this->{tree}, $this->{detail}, $sash);
	$this->SetSashGravity(0);

	EVT_TREE_SEL_CHANGED($this,      $this->{tree}, \&onTreeSelect);
	EVT_TREE_ITEM_RIGHT_CLICK($this, $this->{tree}, \&onTreeRightClick);
	EVT_MENU($this, $_, \&_onContextMenuCommand)
		for (allCopyCmds(), allCutCmds(), $CMD_PASTE, allDeleteCmds(), allNewCmds());
	EVT_MENU($this, $CMD_REFRESH_E80, sub { doRefresh($_[0]) });

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

sub onSessionStart
{
	my ($this) = @_;
	# Use ini-loaded _expanded_keys as-is.  Capture only if there is already
	# a live tree (shouldn't normally happen on first start).
	if ($this->{_e80_loaded} && $this->{tree}->GetCount() > 0)
	{
		_captureExpandedInto($this);
		_captureSelectedInto($this);
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
		_captureExpandedInto($this);
		_captureSelectedInto($this);
	}
	_buildAndRestore($this);
}


sub _buildAndRestore
{
	my ($this) = @_;
	my $tree      = $this->{tree};
	my $wpmgr     = $raydp ? $raydp->findImplementedService('WPMGR', 1) : undef;
	my $track_mgr = $raydp ? $raydp->findImplementedService('TRACK', 1) : undef;

	$tree->DeleteAllItems();
	$this->{detail}->SetValue('');

	if (!$wpmgr)
	{
		my $root = $tree->AddRoot('E80');
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
	_buildGroups($this, $tree, $root, $wpmgr);
	_buildRoutes($this, $tree, $root, $wpmgr);
	_buildTracks($this, $tree, $root, $track_mgr);

	$this->{_e80_loaded} = 1;
	$tree->Expand($root);
	_walkRestoreExpanded($tree, $root, $this->{_expanded_keys});
	_walkRestoreSelected($tree, $root, $this->{_selected_keys});
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

	my @ungrouped = sort { lc($wps->{$a}{name} // '') cmp lc($wps->{$b}{name} // '') }
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

	# named groups, sorted by name case-insensitively
	for my $uuid (sort { lc($groups->{$a}{name} // '') cmp lc($groups->{$b}{name} // '') }
	              keys %$groups)
	{
		my $grp = $groups->{$uuid};
		my @member_uuids = sort {
			my $wa = $wps->{$a}; my $wb = $wps->{$b};
			lc($wa ? ($wa->{name} // '') : '') cmp lc($wb ? ($wb->{name} // '') : '')
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

	for my $uuid (sort { lc($routes->{$a}{name} // '') cmp lc($routes->{$b}{name} // '') }
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

	for my $uuid (sort { lc($tracks->{$a}{name} // '') cmp lc($tracks->{$b}{name} // '') }
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

	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR') : undef;

	my $type = $node->{type};
	my $text = '';

	if ($type eq 'header')
	{
		$text = "($node->{kind})";
	}
	elsif ($type eq 'my_waypoints')
	{
		$text = "Synthesized node: waypoints not assigned to any named group.";
	}
	elsif (($type eq 'waypoint' || $type eq 'route_point') && $node->{data})
	{
		$text = wpmgrRecordToText($node->{data}, 'WAYPOINT', 2, 0, undef, $wpmgr);
	}
	elsif ($type eq 'group' && $node->{data})
	{
		$text = wpmgrRecordToText($node->{data}, 'GROUP', 2, 0, undef, $wpmgr);
	}
	elsif ($type eq 'route' && $node->{data})
	{
		$text = wpmgrRecordToText($node->{data}, 'ROUTE', 2, 0, undef, $wpmgr);
	}
	elsif ($type eq 'track' && $node->{data})
	{
		my $track = $node->{data};
		my $pts   = $track->{cnt1} // (ref $track->{points} ? scalar @{$track->{points}} : 0);
		$text  = "Track:  $track->{name}\n";
		$text .= "UUID:   $node->{uuid}\n";
		$text .= "Points: $pts\n";
		$text .= "Color:  $track->{color}\n" if defined $track->{color};
	}

	$this->{detail}->SetValue($text);
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

	my $menu = Wx::Menu->new();

	my @copy_items = getCopyMenuItems('e80', @nodes);
	$menu->Append($_->{id}, $_->{label}) for @copy_items;
	$menu->AppendSeparator()             if @copy_items;

	$menu->Append($CMD_PASTE, 'Paste');
	$menu->Enable($CMD_PASTE, canPaste($right_click_node, 'e80') ? 1 : 0);

	my @delete_items = getDeleteMenuItems('e80', $right_click_node);
	if (@delete_items)
	{
		$menu->AppendSeparator();
		$menu->Append($_->{id}, $_->{label}) for @delete_items;
	}

	my @new_items = getNewMenuItems('e80', $right_click_node);
	if (@new_items)
	{
		$menu->AppendSeparator();
		$menu->Append($_->{id}, $_->{label}) for @new_items;
	}

	$menu->AppendSeparator();
	$menu->Append($CMD_REFRESH_E80, 'Refresh E80');

	return $menu;
}


sub _onContextMenuCommand
{
	my ($this, $event) = @_;
	onContextMenuCommand(
		$event->GetId(), 'e80', $this->{_right_click_node}, $this->{tree});
}


#---------------------------------
# ini persistence
#---------------------------------

sub getDataForIniFile
{
	my ($this) = @_;
	_captureExpandedInto($this) if $this->{_e80_loaded} && $this->{tree}->GetCount() > 0;
	return {
		sash     => $this->GetSashPosition(),
		expanded => join(',', sort keys %{$this->{_expanded_keys}}),
	};
}


#---------------------------------
# tree state — expand / select
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


1;
