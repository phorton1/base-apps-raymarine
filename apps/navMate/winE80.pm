#!/usr/bin/perl
#-------------------------------------------------------------------------
# winE80.pm
#-------------------------------------------------------------------------
# Read-only live view of the E80's WPMGR contents (waypoints, routes, groups).
#
# Tree structure mirrors the E80's own organization:
#   Groups
#     My Waypoints  (synthesized: waypoints not in any named group)
#       waypoint ...
#     named group ...
#       waypoint ...
#   Routes
#     route ...
#   Tracks  (stub -- WPMGR does not query tracks)
#
# Refresh is triggered by winMain::onIdle whenever the global NET version
# increments (i.e. any WPMGR item changes).

package winE80;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(EVT_TREE_SEL_CHANGED);
use Pub::Utils qw(display warning error);
use Pub::WX::Window;
use apps::raymarine::NET::b_records qw(wpmgrRecordToText);
use apps::raymarine::NET::c_RAYDP;
use w_resources;
use base qw(Wx::SplitterWindow Pub::WX::Window);


sub new
{
	my ($class, $frame, $book, $id, $data) = @_;
	my $this = $class->SUPER::new($book, $id);
	$this->MyWindow($frame, $book, $id, 'E80 Browser', $data);

	$this->{tree} = Wx::TreeCtrl->new($this, -1, wxDefaultPosition, wxDefaultSize,
		wxTR_DEFAULT_STYLE | wxTR_HIDE_ROOT);

	$this->{detail} = Wx::TextCtrl->new($this, -1, '', wxDefaultPosition, wxDefaultSize,
		wxTE_MULTILINE | wxTE_READONLY);

	my $font = Wx::Font->new(9, wxFONTFAMILY_MODERN, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_NORMAL);
	$this->{detail}->SetFont($font);

	my $sash = ($data && ref($data) eq 'HASH' && $data->{sash}) ? $data->{sash} : 250;
	$this->SplitVertically($this->{tree}, $this->{detail}, $sash);
	$this->SetSashGravity(0.5);

	EVT_TREE_SEL_CHANGED($this, $this->{tree}, \&onTreeSelect);

	$this->refresh();

	return $this;
}


#---------------------------------
# build / refresh tree
#---------------------------------

sub refresh
{
	my ($this) = @_;
	my $tree = $this->{tree};
	$tree->DeleteAllItems();
	$this->{detail}->SetValue('');

	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR') : undef;
	unless ($wpmgr)
	{
		my $root = $tree->AddRoot('E80');
		$tree->AppendItem($root, '(WPMGR not connected)');
		return;
	}

	my $root = $tree->AddRoot('E80');
	my @headers;

	push @headers, _buildGroups($this, $tree, $root, $wpmgr);
	push @headers, _buildRoutes($this, $tree, $root, $wpmgr);
	push @headers, _buildTracks($this, $tree, $root);

	$tree->Expand($_) for @headers;
}


sub _buildGroups
{
	my ($this, $tree, $root, $wpmgr) = @_;
	my $wps    = $wpmgr->{waypoints} // {};
	my $groups = $wpmgr->{groups}    // {};
	return () unless %$wps || %$groups;

	# find which waypoint UUIDs are claimed by a named group
	my %grouped;
	for my $uuid (keys %$groups)
	{
		$grouped{$_} = 1 for @{$groups->{$uuid}{uuids} // []};
	}

	my @ungrouped = sort { ($wps->{$a}{name} // '') cmp ($wps->{$b}{name} // '') }
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
	for my $uuid (sort { ($groups->{$a}{name} // '') cmp ($groups->{$b}{name} // '') }
	              keys %$groups)
	{
		my $grp = $groups->{$uuid};
		my @member_uuids = @{$grp->{uuids} // []};
		my $n = scalar @member_uuids;
		my $grp_item = $tree->AppendItem($hdr, "$grp->{name} ($n wps)", -1, -1,
			Wx::TreeItemData->new({ type => 'group', uuid => $uuid, data => $grp }));

		for my $wp_uuid (@member_uuids)
		{
			my $wp = $wps->{$wp_uuid};
			my $label = $wp ? ($wp->{name} // $wp_uuid) : "($wp_uuid)";
			$tree->AppendItem($grp_item, $label, -1, -1,
				Wx::TreeItemData->new({ type => 'waypoint', uuid => $wp_uuid, data => $wp }));
		}
	}

	return $hdr;
}


sub _buildRoutes
{
	my ($this, $tree, $root, $wpmgr) = @_;
	my $routes = $wpmgr->{routes} // {};
	return () unless %$routes;

	my $hdr = $tree->AppendItem($root, 'Routes', -1, -1,
		Wx::TreeItemData->new({ type => 'header', kind => 'routes' }));

	for my $uuid (sort { ($routes->{$a}{name} // '') cmp ($routes->{$b}{name} // '') }
	              keys %$routes)
	{
		my $r = $routes->{$uuid};
		my $n = $r->{num_wpts} // scalar(@{$r->{uuids} // []});
		$tree->AppendItem($hdr, "$r->{name} ($n pts)", -1, -1,
			Wx::TreeItemData->new({ type => 'route', uuid => $uuid, data => $r }));
	}

	return $hdr;
}


sub _buildTracks
{
	my ($this, $tree, $root) = @_;
	my $hdr = $tree->AppendItem($root, 'Tracks (not queried)', -1, -1,
		Wx::TreeItemData->new({ type => 'header', kind => 'tracks' }));
	return $hdr;
}


#---------------------------------
# selection -> detail
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
	elsif ($type eq 'waypoint' && $node->{data})
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
