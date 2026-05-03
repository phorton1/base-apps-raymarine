#!/usr/bin/perl
#---------------------------------------------
# nmTest.pm
#---------------------------------------------
# HTTP-driven test dispatcher for navMate context menu testing.
# Called from winMain::onIdle when a test command is queued
# via the /api/test HTTP endpoint.
#
# API (all params are query params on GET /api/test):
#   panel=database|e80        which tree window to target
#   select=key1,key2,...      node keys to select (UUIDs or "header:groups" etc.)
#   right_click=key           which node is the right-click target (defaults to first in select)
#   cmd=10010                 numeric CTX_CMD_* constant to fire
#   suppress=0|1              auto-confirm dialogs before firing
#   op=suppress&val=0|1       set suppress_confirm without any tree or fire action
#
# NOTE: NEW_* commands (10510-10550) open name-input dialogs and will block the
# test machinery.  Do not issue them via this endpoint.

package nmTest;
use strict;
use warnings;
use JSON::PP qw(decode_json);
use Pub::Utils qw(display warning);
use nmDialogs qw($suppress_confirm);
use nmClipboard qw(onContextMenuCommand);
use w_resources qw($WIN_DATABASE $WIN_E80);


BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(dispatchTestCommand);
}


my $DUMMY = '__dummy__';


sub dispatchTestCommand
{
	my ($main_win, $cmd_json) = @_;
	my $cmd = eval { decode_json($cmd_json) };
	if ($@) { warning(0,0,"nmTest: bad JSON: $@"); return; }

	# Pure ops — handle before panel resolution
	my $op = $cmd->{op} // '';
	if ($op eq 'suppress')
	{
		$suppress_confirm = ($cmd->{val} // 0) ? 1 : 0;
		display(0,0,"nmTest: suppress_confirm=$suppress_confirm");
		return;
	}
	if ($op eq 'refresh')
	{
		my $pname = $cmd->{panel} // 'database';
		my $pid   = ($pname eq 'e80') ? $WIN_E80 : $WIN_DATABASE;
		my $pane  = $main_win->findPane($pid);
		if (!$pane) { warning(0,0,"nmTest: refresh — panel '$pname' not open"); return; }
		$pane->refresh();
		display(0,0,"nmTest: refresh done panel=$pname");
		return;
	}

	# Apply suppress flag if present on any op
	if (exists $cmd->{suppress})
	{
		$suppress_confirm = $cmd->{suppress} ? 1 : 0;
		display(0,0,"nmTest: suppress_confirm=$suppress_confirm");
	}

	# Resolve panel
	my $panel_name = $cmd->{panel} // 'database';
	my $panel_id   = ($panel_name eq 'e80') ? $WIN_E80 : $WIN_DATABASE;
	my $panel      = $main_win->findPane($panel_id);
	if (!$panel)
	{
		warning(0,0,"nmTest: panel '$panel_name' not open");
		return;
	}

	# auto_expanded: keys of branches collapsed before this command that we expand
	# to reach target nodes.  _doFire collapses them again after the command runs.
	my @auto_expanded;

	# Select nodes if requested
	my $select_str = $cmd->{select} // '';
	if ($select_str)
	{
		my @keys   = split(/,/, $select_str);
		my $rc_key = $cmd->{right_click} // $keys[0];
		_doSelect($panel, \@keys, $rc_key, \@auto_expanded);
	}

	# Fire command if requested
	my $cmd_id = ($cmd->{cmd} // 0) + 0;
	_doFire($panel, $panel_name, $cmd_id, \@auto_expanded) if $cmd_id;
}


#---------------------------------------------
# _getNodeKey — unified key for both tree types
#---------------------------------------------

sub _getNodeKey
{
	my ($node) = @_;
	return undef if ref $node ne 'HASH';
	my $t = $node->{type} // '';
	return "header:$node->{kind}" if $t eq 'header';
	return 'my_waypoints'         if $t eq 'my_waypoints';
	return 'root'                 if $t eq 'root';
	return "rp:$node->{route_uuid}:$node->{uuid}"
		if $t eq 'route_point' && $node->{route_uuid};
	return $node->{uuid} // ($node->{data} // {})->{uuid};
}


#---------------------------------------------
# _walkSelect — traverse tree, select matching nodes
#---------------------------------------------
# Auto-expands collapsed branches (DUMMY placeholder) on the way down.
# Records the key of each branch it expands into $expanded_ref so _doFire
# can collapse them again after the command runs.

sub _walkSelect
{
	my ($tree, $item, $want, $rc_key, $selected, $rc_node_ref, $expanded_ref) = @_;
	return if !($item && $item->IsOk());

	my $d = $tree->GetItemData($item);
	if ($d)
	{
		my $node = $d->GetData();
		if (ref $node eq 'HASH')
		{
			my $key = _getNodeKey($node);
			if (defined $key && $want->{$key})
			{
				$tree->SelectItem($item, 1);
				push @$selected, $node;
				$$rc_node_ref = $node if defined $rc_key && $key eq $rc_key;
			}
		}
	}

	my ($child, $cookie) = $tree->GetFirstChild($item);
	return if !($child && $child->IsOk());

	# Auto-expand collapsed branch, recording its key for later collapse.
	if (($tree->GetItemText($child) // '') eq $DUMMY)
	{
		my $nd = $tree->GetItemData($item);
		if ($nd)
		{
			my $node = $nd->GetData();
			my $key  = _getNodeKey($node) if ref $node eq 'HASH';
			push @$expanded_ref, $key if defined $key;
		}
		$tree->Expand($item);
		($child, $cookie) = $tree->GetFirstChild($item);
	}

	while ($child && $child->IsOk())
	{
		if (($tree->GetItemText($child) // '') ne $DUMMY)
		{
			_walkSelect($tree, $child, $want, $rc_key, $selected, $rc_node_ref, $expanded_ref);
		}
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
}


#---------------------------------------------
# _doSelect — set panel selection state
#---------------------------------------------

sub _doSelect
{
	my ($panel, $keys_ref, $rc_key, $expanded_ref) = @_;
	my %want = map { $_ => 1 } @$keys_ref;
	my $tree = $panel->{tree};

	$tree->UnselectAll();

	my @selected;
	my $rc_node = undef;
	my $root = $tree->GetRootItem();
	_walkSelect($tree, $root, \%want, $rc_key, \@selected, \$rc_node, $expanded_ref);

	$panel->{_context_nodes}    = \@selected;
	$panel->{_right_click_node} = $rc_node // $selected[0];

	my $found = scalar @selected;
	my $rc_t  = $panel->{_right_click_node} ? $panel->{_right_click_node}{type} : 'none';
	display(0,0,"nmTest: selected $found node(s), right_click=$rc_t");
}


#---------------------------------------------
# _walkCollapse — collapse previously auto-expanded branches
#---------------------------------------------

sub _walkCollapse
{
	my ($tree, $item, $to_collapse) = @_;
	return if !($item && $item->IsOk());

	my $d = $tree->GetItemData($item);
	if ($d)
	{
		my $node = $d->GetData();
		if (ref $node eq 'HASH')
		{
			my $key = _getNodeKey($node);
			if (defined $key && $to_collapse->{$key})
			{
				$tree->Collapse($item);
				return;
			}
		}
	}

	my ($child, $cookie) = $tree->GetFirstChild($item);
	while ($child && $child->IsOk())
	{
		if (($tree->GetItemText($child) // '') ne $DUMMY)
		{
			_walkCollapse($tree, $child, $to_collapse);
		}
		($child, $cookie) = $tree->GetNextChild($item, $cookie);
	}
}


#---------------------------------------------
# _doFire — call onContextMenuCommand, then restore expansion state
#---------------------------------------------

sub _doFire
{
	my ($panel, $panel_name, $cmd_id, $expanded_ref) = @_;
	my $rc    = $panel->{_right_click_node};
	my @nodes = @{$panel->{_context_nodes} // []};

	if (!$rc)
	{
		warning(0,0,"nmTest: fire cmd=$cmd_id — no right_click_node set");
		return;
	}

	display(0,0,"nmTest: firing cmd=$cmd_id panel=$panel_name");
	onContextMenuCommand($cmd_id, $panel_name, $rc, $panel->{tree}, @nodes);

	# Collapse branches that were expanded solely to reach the target node.
	if ($expanded_ref && @$expanded_ref)
	{
		my %to_collapse = map { $_ => 1 } @$expanded_ref;
		_walkCollapse($panel->{tree}, $panel->{tree}->GetRootItem(), \%to_collapse);
	}
}


1;
