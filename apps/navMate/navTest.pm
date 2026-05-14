#!/usr/bin/perl
#---------------------------------------------
# navTest.pm
#---------------------------------------------
# HTTP-driven test dispatcher for navMate context menu testing.
# Called from nmFrame::onIdle when a test command is queued
# via the /api/test HTTP endpoint.
#
# API (all params are query params on GET /api/test):
#   panel=database|e80        which tree window to target
#   select=key1,key2,...      node keys to select (UUIDs or "header:groups" etc.)
#   right_click=key           which node is the right-click target (defaults to first in select)
#   cmd=10200                 numeric CTX_CMD_* constant to fire
#   op=suppress&val=0|1       set suppress_confirm without any tree or fire action
#   op=suppress&val=1&outcome=reject   also set suppress_outcome for two-outcome dialogs
#   op=refresh                reload navMate.db from disk
#   op=clear_e80              delete all E80 routes, groups, waypoints, and tracks
#   op=create_branch&parent_uuid=X&name=Y    create a branch without the name-input dialog
#                              (parent_uuid omitted -> root-level branch).
#                              Use /api/nmdb after to look up the new branch's uuid by name.
#
# NOTE: NEW_* commands (10230-10233) open name-input dialogs and will block the
# test machinery. Do not issue them via this endpoint -- use op=create_branch
# (and equivalent ops as they are added) instead.

package navTest;
use strict;
use warnings;
use JSON::PP qw(decode_json);
use Pub::Utils qw(display warning);
use navOps qw(onContextMenuCommand);
use navDB qw(connectDB disconnectDB insertCollection computePushDownPositions);
use n_defs qw($NODE_TYPE_BRANCH);
use nmDialogs qw($suppress_confirm);
use nmResources qw($WIN_DATABASE $WIN_E80);


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
	if ($@) { warning(0,0,"navTest: bad JSON: $@"); return; }

	# Pure ops - handle before panel resolution
	my $op = $cmd->{op} // '';
	if ($op eq 'suppress')
	{
		$suppress_confirm                 = ($cmd->{val} // 0) ? 1 : 0;
		$nmDialogs::suppress_error_dialog = $suppress_confirm;
		if (exists $cmd->{outcome})
		{
			$nmDialogs::suppress_outcome = $cmd->{outcome} // 'accept';
			display(0,0,"navTest: suppress_confirm=$suppress_confirm suppress_outcome=$nmDialogs::suppress_outcome");
		}
		else
		{
			display(0,0,"navTest: suppress_confirm=$suppress_confirm");
		}
		return;
	}
	if ($op eq 'refresh')
	{
		my $pname = $cmd->{panel} // 'database';
		my $pid   = ($pname eq 'e80') ? $WIN_E80 : $WIN_DATABASE;
		my $pane  = $main_win->findPane($pid);
		if (!$pane) { warning(0,0,"navTest: refresh - panel '$pname' not open"); return; }
		$pane->refresh();
		display(0,0,"navTest: refresh done panel=$pname");
		return;
	}
	if ($op eq 'clear_e80')
	{
		navOps::doClearE80DB($main_win);
		return;
	}
	if ($op eq 'create_branch')
	{
		_doCreateBranch($main_win, $cmd);
		return;
	}

	# Apply suppress flag if present on a fire command
	if (exists $cmd->{suppress})
	{
		$suppress_confirm                 = $cmd->{suppress} ? 1 : 0;
		$nmDialogs::suppress_error_dialog = $suppress_confirm;
		display(0,0,"navTest: suppress_confirm=$suppress_confirm");
	}

	# Resolve panel
	my $panel_name = $cmd->{panel} // 'database';
	my $panel_id   = ($panel_name eq 'e80') ? $WIN_E80 : $WIN_DATABASE;
	my $panel      = $main_win->findPane($panel_id);
	if (!$panel)
	{
		warning(0,0,"navTest: panel '$panel_name' not open");
		return;
	}

	# auto_expanded: keys of branches collapsed before this command that we expand
	# to reach target nodes. _doFire collapses them again after the command runs.
	my @auto_expanded;

	my $select_str = $cmd->{select} // '';
	my $cmd_id     = ($cmd->{cmd} // 0) + 0;

	# Freeze the panel's tree across the entire test-command-side activity:
	# _doSelect (UnselectAll + walk + Expand + SelectItem) -> the command's
	# handler (which calls panel->refresh() internally; that nests harmlessly
	# under this outer Freeze since wx Freeze/Thaw is refcounted) -> _doFire's
	# _walkCollapse to undo the auto-expansions. Without this, the user sees
	# the tree scroll/blank/repaint three times per test command. With it,
	# the entire command produces a single repaint at this Thaw.
	my $tree = $panel->{tree};
	$tree->Freeze();
	eval {
		if ($select_str)
		{
			my @keys   = split(/,/, $select_str);
			my $rc_key = $cmd->{right_click} // $keys[0];
			_doSelect($panel, \@keys, $rc_key, \@auto_expanded);
		}
		_doFire($panel, $panel_name, $cmd_id, \@auto_expanded) if $cmd_id;
	};
	my $err = $@;
	$tree->Thaw();
	warning(0, 0, "navTest: dispatch error: $err") if $err;
}


#---------------------------------------------
# _getNodeKey - unified key for both tree types
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
# _walkSelect - traverse tree, select matching nodes
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
# _doSelect - set panel selection state
#---------------------------------------------

sub _doSelect
{
	my ($panel, $keys_ref, $rc_key, $expanded_ref) = @_;
	my %want = map { $_ => 1 } @$keys_ref;
	my $tree = $panel->{tree};

	$tree->UnselectAll();

	my @selected;
	my $rc_node = undef;
	my $root    = $tree->GetRootItem();
	_walkSelect($tree, $root, \%want, $rc_key, \@selected, \$rc_node, $expanded_ref);

	$panel->{_context_nodes}    = \@selected;
	$panel->{_right_click_node} = $rc_node // $selected[0];

	my $found = scalar @selected;
	my $rc_t  = $panel->{_right_click_node} ? $panel->{_right_click_node}{type} : 'none';
	display(0,0,"navTest: selected $found node(s), right_click=$rc_t");
}


#---------------------------------------------
# _walkCollapse - collapse previously auto-expanded branches
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
# _doCreateBranch - dialog-free NEW_BRANCH for /api/test
#---------------------------------------------
# Creates a new branch collection without opening the wxTextEntryDialog that
# the user-facing NEW_BRANCH path uses. Computes push-down-stack position so
# the new branch lands at the top of its parent (matching the user NEW
# semantic). Refreshes the database panel after insert so the tree reflects
# the new state for subsequent operations in the same test sequence.

sub _doCreateBranch
{
	my ($main_win, $cmd) = @_;
	my $parent_uuid = $cmd->{parent_uuid};
	$parent_uuid    = undef if defined $parent_uuid && $parent_uuid eq '';
	my $name        = $cmd->{name} // '';
	if ($name eq '')
	{
		warning(0,0,"navTest: create_branch - missing name");
		return;
	}
	my $dbh = connectDB();
	if (!$dbh)
	{
		warning(0,0,"navTest: create_branch - db connect failed");
		return;
	}
	my @new_pos = computePushDownPositions($dbh, $parent_uuid, 1);
	my $uuid    = insertCollection($dbh, $name, $parent_uuid, $NODE_TYPE_BRANCH, '', $new_pos[0]);
	disconnectDB($dbh);
	if (!$uuid)
	{
		warning(0,0,"navTest: create_branch - insertCollection returned undef");
		return;
	}
	display(0,0,"navTest: create_branch '$name' uuid=$uuid parent=" . ($parent_uuid // 'ROOT'));

	# Refresh DB panes so the new branch is visible for follow-up ops.
	my $db_pane = $main_win->findPane($WIN_DATABASE);
	$db_pane->refresh() if $db_pane;
}


#---------------------------------------------
# _doFire - call onContextMenuCommand, then restore expansion state
#---------------------------------------------

sub _doFire
{
	my ($panel, $panel_name, $cmd_id, $expanded_ref) = @_;
	my $rc    = $panel->{_right_click_node};
	my @nodes = @{$panel->{_context_nodes} // []};

	if (!$rc)
	{
		warning(0,0,"navTest: fire cmd=$cmd_id - no right_click_node set");
		return;
	}

	display(0,0,"navTest: firing cmd=$cmd_id panel=$panel_name");
	onContextMenuCommand($cmd_id, $panel_name, $rc, $panel->{tree}, @nodes);

	# Collapse branches that were expanded solely to reach the target node.
	if ($expanded_ref && @$expanded_ref)
	{
		my %to_collapse = map { $_ => 1 } @$expanded_ref;
		_walkCollapse($panel->{tree}, $panel->{tree}->GetRootItem(), \%to_collapse);
	}
}


1;
