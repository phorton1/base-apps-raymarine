#!/usr/bin/perl
#---------------------------------------------
# winRename.pm
#---------------------------------------------
# Batch rename dialog for homogeneous selections in winDatabase and winFSH.
#
# The dialog renders a pattern with an embedded {N} token (any number of
# occurrences) into serially-numbered new names for an ordered list of
# items.  Pad-digits and start-index are user-controlled.
#
# Spoke-local: bypasses navOps deliberately (no cross-spoke routing).
# winDatabase applies UPDATEs with auto modified_ts via trigger.  winFSH
# mutates the in-memory FSH-db and marks dirty.  E80 is intentionally
# out of scope.
#
# Preflight (FSH only): per-type name uniqueness across the whole FSH
# plus 15-char ceiling.  DB is deliberately unconstrained -- no preflight.

package winRename;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_TEXT EVT_SPINCTRL EVT_BUTTON);
use Pub::Utils qw(display warning error $UTILS_COLOR_LIGHT_MAGENTA);
use Pub::WX::Dialogs;
use navDB;
use navFSH;
use n_defs;
use apps::raymarine::NET::a_defs qw($E80_MAX_NAME);


BEGIN
{
	use Exporter qw( import );
	our @EXPORT_OK = qw(
		$CTX_CMD_RENAME
		isRenameHomogeneous
		onRenameDB
		onRenameFSH
	);
}


our $CTX_CMD_RENAME = 10572;

my $dbg_rename = 0;


#----------------------------------------------------
# isRenameHomogeneous
#----------------------------------------------------
# Returns the display label (singular/plural) when the selection is a
# homogeneous set of rename-eligible items, undef otherwise.  Eligible:
# waypoint, route, track (DB object types or FSH top-level types), or
# group (DB collection with node_type='group', or FSH top-level group).

sub isRenameHomogeneous
{
	my ($panel, @nodes) = @_;
	return undef if !@nodes;

	my @kinds;
	if ($panel eq 'database')
	{
		for my $n (@nodes)
		{
			my $t = $n->{type} // '';
			my $d = $n->{data} // {};
			if ($t eq 'object')
			{
				my $ot = $d->{obj_type} // '';
				return undef if $ot ne 'waypoint' && $ot ne 'route' && $ot ne 'track';
				push @kinds, $ot;
			}
			elsif ($t eq 'collection' && ($d->{node_type} // '') eq 'group')
			{
				push @kinds, 'group';
			}
			else
			{
				return undef;
			}
		}
	}
	elsif ($panel eq 'fsh')
	{
		for my $n (@nodes)
		{
			my $t = $n->{type} // '';
			return undef if $t ne 'waypoint' && $t ne 'group'
			             && $t ne 'route'    && $t ne 'track';
			push @kinds, $t;
		}
	}
	else
	{
		return undef;
	}

	my $first = $kinds[0];
	return undef if grep { $_ ne $first } @kinds;

	my $plural = @kinds > 1;
	return $first eq 'waypoint' ? ($plural ? 'Waypoints' : 'Waypoint')
	     : $first eq 'route'    ? ($plural ? 'Routes'    : 'Route')
	     : $first eq 'track'    ? ($plural ? 'Tracks'    : 'Track')
	     : $first eq 'group'    ? ($plural ? 'Groups'    : 'Group')
	     : undef;
}


#----------------------------------------------------
# preflightRename
#----------------------------------------------------
# Returns arrayref of { row, id, new, issue } failures (empty = clean).
# $new_pairs:    arrayref of [id, new_name] (the proposed batch)
# $existing_pairs: arrayref of [id, name] for ALL items in the rename scope
#                (full per-type universe of names at the spoke)
# $max_len:      max permitted length; undef = no length check
#
# Items being renamed are excluded from the existing-name collision set
# (you can rename A->B even if A originally held the name "B" -- because
# A is being renamed away from it).

sub preflightRename
{
	my ($new_pairs, $existing_pairs, $max_len) = @_;
	my @failures;

	if ($max_len)
	{
		for my $i (0 .. $#$new_pairs)
		{
			my ($id, $name) = @{$new_pairs->[$i]};
			my $len = length($name);
			push @failures, {
				row => $i, id => $id, new => $name,
				issue => "name exceeds $max_len chars (got $len)"
			} if $len > $max_len;
		}
	}

	my %batch_ids = map { $_->[0] => 1 } @$new_pairs;
	my %retained;
	for my $p (@$existing_pairs)
	{
		my ($id, $name) = @$p;
		next if $batch_ids{$id};
		$retained{$name // ''} = 1;
	}

	my %seen_new;
	for my $i (0 .. $#$new_pairs)
	{
		my ($id, $name) = @{$new_pairs->[$i]};
		if ($retained{$name})
		{
			push @failures, {
				row => $i, id => $id, new => $name,
				issue => "collides with existing name '$name'"
			};
		}
		elsif (defined $seen_new{$name})
		{
			my $prior = $seen_new{$name};
			push @failures, {
				row => $i, id => $id, new => $name,
				issue => "duplicates row " . ($prior + 1) . " in this batch"
			};
		}
		$seen_new{$name} = $i;
	}

	return \@failures;
}


#----------------------------------------------------
# _expandPattern
#----------------------------------------------------

sub _expandPattern
{
	my ($pat, $pad, $start, $i) = @_;
	my $tok = sprintf('%0*d', $pad, $start + $i);
	(my $out = $pat) =~ s/\{N\}/$tok/g;
	return $out;
}


#----------------------------------------------------
# _formatFailures
#----------------------------------------------------

sub _formatFailures
{
	my ($fails) = @_;
	my $n = scalar @$fails;
	my @lines;
	push @lines, ($n == 1 ? "1 issue:" : "$n issues:");
	for my $f (@$fails)
	{
		push @lines, "  '$f->{new}' -- $f->{issue}";
	}
	return join("\n", @lines);
}


#----------------------------------------------------
# showRenameDialog
#----------------------------------------------------
# $parent      -- Wx parent for the modal
# $type_label  -- e.g. 'Waypoints'
# $pairs       -- arrayref of [id, current_name] in target tree-sort order
# $preflight   -- optional sub ref; called as $preflight->($proposed_pairs)
#                 returning arrayref of failures.  When non-empty the
#                 dialog stays open and shows the failure list.
#
# Returns arrayref of [id, new_name] on OK, undef on Cancel.

sub showRenameDialog
{
	my ($parent, $type_label, $pairs, $preflight) = @_;
	my $n = scalar @$pairs;
	return undef if !$n;

	my $title = "Rename $type_label";
	my $dlg = Wx::Dialog->new($parent, -1, $title,
		wxDefaultPosition, [520, 480],
		wxDEFAULT_DIALOG_STYLE | wxRESIZE_BORDER);

	my $vsizer = Wx::BoxSizer->new(wxVERTICAL);

	# Pattern row
	my $row1 = Wx::BoxSizer->new(wxHORIZONTAL);
	$row1->Add(Wx::StaticText->new($dlg, -1, 'Pattern:'),
		0, wxALIGN_CENTER_VERTICAL | wxRIGHT, 6);
	my $pattern_ctrl = Wx::TextCtrl->new($dlg, -1, '');
	$row1->Add($pattern_ctrl, 1, wxEXPAND);
	$vsizer->Add($row1, 0, wxEXPAND | wxALL, 8);

	$vsizer->Add(Wx::StaticText->new($dlg, -1,
		"Use {N} anywhere for the serial number.  Example: Anchor-{N}"),
		0, wxLEFT | wxRIGHT | wxBOTTOM, 8);

	# Pad / Start row
	my $default_pad = length(sprintf('%d', $n));
	$default_pad = 1 if $default_pad < 1;
	my $row2 = Wx::BoxSizer->new(wxHORIZONTAL);
	$row2->Add(Wx::StaticText->new($dlg, -1, 'Pad digits:'),
		0, wxALIGN_CENTER_VERTICAL | wxRIGHT, 6);
	my $pad_ctrl = Wx::SpinCtrl->new($dlg, -1, $default_pad,
		wxDefaultPosition, [70, -1],
		wxSP_ARROW_KEYS, 1, 9, $default_pad);
	$row2->Add($pad_ctrl, 0, wxRIGHT, 24);
	$row2->Add(Wx::StaticText->new($dlg, -1, 'Start at:'),
		0, wxALIGN_CENTER_VERTICAL | wxRIGHT, 6);
	my $start_ctrl = Wx::SpinCtrl->new($dlg, -1, 1,
		wxDefaultPosition, [90, -1],
		wxSP_ARROW_KEYS, 0, 999999, 1);
	$row2->Add($start_ctrl, 0);
	$vsizer->Add($row2, 0, wxLEFT | wxRIGHT | wxBOTTOM, 8);

	# Preview list
	my $list = Wx::ListCtrl->new($dlg, -1,
		wxDefaultPosition, wxDefaultSize,
		wxLC_REPORT | wxLC_SINGLE_SEL);
	$list->InsertColumn(0, 'Current', wxLIST_FORMAT_LEFT, 220);
	$list->InsertColumn(1, 'New',     wxLIST_FORMAT_LEFT, 240);
	for my $i (0 .. $#$pairs)
	{
		$list->InsertStringItem($i, $pairs->[$i][1] // '');
		$list->SetItem($i, 1, '');
	}
	$vsizer->Add($list, 1, wxEXPAND | wxLEFT | wxRIGHT | wxBOTTOM, 8);

	# Buttons (custom so we can validate before EndModal)
	my $ok_btn     = Wx::Button->new($dlg, wxID_OK,     'OK');
	my $cancel_btn = Wx::Button->new($dlg, wxID_CANCEL, 'Cancel');
	my $btn_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$btn_row->AddStretchSpacer(1);
	$btn_row->Add($ok_btn,     0, wxRIGHT, 8);
	$btn_row->Add($cancel_btn, 0);
	$vsizer->Add($btn_row, 0, wxEXPAND | wxALL, 8);

	$dlg->SetSizer($vsizer);

	my $update_preview = sub {
		my $pat = $pattern_ctrl->GetValue();
		my $pad = $pad_ctrl->GetValue();
		my $st  = $start_ctrl->GetValue();
		for my $i (0 .. $#$pairs)
		{
			$list->SetItem($i, 1, _expandPattern($pat, $pad, $st, $i));
		}
	};
	$update_preview->();

	EVT_TEXT($dlg,     $pattern_ctrl, sub { $update_preview->() });
	EVT_SPINCTRL($dlg, $pad_ctrl,     sub { $update_preview->() });
	EVT_SPINCTRL($dlg, $start_ctrl,   sub { $update_preview->() });

	my $result;

	EVT_BUTTON($dlg, wxID_OK, sub {
		my $pat = $pattern_ctrl->GetValue();
		if ($pat eq '')
		{
			my $info = Wx::MessageDialog->new($dlg,
				'Pattern cannot be empty.', 'Rename',
				wxOK | wxICON_INFORMATION | wxCENTRE);
			$info->ShowModal();
			$info->Destroy();
			return;
		}

		my $pad = $pad_ctrl->GetValue();
		my $st  = $start_ctrl->GetValue();
		my @out;
		for my $i (0 .. $#$pairs)
		{
			push @out, [$pairs->[$i][0], _expandPattern($pat, $pad, $st, $i)];
		}

		if ($preflight)
		{
			my $fails = $preflight->(\@out);
			if (@$fails)
			{
				my $err = Wx::MessageDialog->new($dlg,
					_formatFailures($fails), 'Rename failed',
					wxOK | wxICON_WARNING | wxCENTRE);
				$err->ShowModal();
				$err->Destroy();
				return;
			}
		}

		$result = \@out;
		$dlg->EndModal(wxID_OK);
	});

	$pattern_ctrl->SetFocus();
	$dlg->ShowModal();
	$dlg->Destroy();
	return $result;
}


#----------------------------------------------------
# onRenameDB
#----------------------------------------------------
# Called from winDatabase EVT_MENU handler for $CTX_CMD_RENAME.
# Selection nodes carry data->{uuid} and data->{name}.

sub onRenameDB
{
	my ($pane, @nodes) = @_;
	my $label = isRenameHomogeneous('database', @nodes);
	return if !$label;

	display(-1, 0, "===== RENAME (database) STARTED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);

	my $first_type = $nodes[0]->{type} // '';
	my $obj_type;
	if ($first_type eq 'object')
	{
		$obj_type = ($nodes[0]->{data} // {})->{obj_type} // '';
	}
	elsif ($first_type eq 'collection')
	{
		$obj_type = 'group';
	}

	my $table = $obj_type eq 'waypoint' ? 'waypoints'
	          : $obj_type eq 'route'    ? 'routes'
	          : $obj_type eq 'track'    ? 'tracks'
	          : $obj_type eq 'group'    ? 'collections'
	          : undef;
	if (!$table)
	{
		display(-1, 0, "===== RENAME (database) FINISHED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
		return;
	}

	my @pairs;
	for my $n (@nodes)
	{
		my $d = $n->{data} // {};
		next if !$d->{uuid};
		push @pairs, [$d->{uuid}, $d->{name} // ''];
	}
	if (!@pairs)
	{
		display(-1, 0, "===== RENAME (database) FINISHED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
		return;
	}

	my $result = showRenameDialog($pane, $label, \@pairs);
	if (!$result)
	{
		display(-1, 0, "===== RENAME (database) FINISHED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
		return;
	}

	display($dbg_rename, 0, "winRename::onRenameDB applying " . scalar(@$result) . " row(s) to $table");

	my $dbh = connectDB();
	if (!$dbh)
	{
		error("winRename::onRenameDB: connectDB failed");
		display(-1, 0, "===== RENAME (database) FINISHED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
		return;
	}

	my $err;
	eval {
		$dbh->{dbh}->begin_work();
		for my $p (@$result)
		{
			$dbh->do("UPDATE $table SET name=? WHERE uuid=?",
				[$p->[1], $p->[0]]);
		}
		$dbh->commit();
	};
	$err = $@;
	if ($err)
	{
		eval { $dbh->rollback() };
		error("winRename::onRenameDB transaction failed: $err");
	}
	disconnectDB($dbh);

	$pane->refresh();

	display(-1, 0, "===== RENAME (database) FINISHED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
}


#----------------------------------------------------
# onRenameFSH
#----------------------------------------------------
# Called from winFSH EVT_MENU handler for $CTX_CMD_RENAME.
# Selection nodes carry node->{uuid} (FSH-format) and node->{data}{name}.
# Preflight enforces 15-char ceiling and per-type uniqueness.

sub onRenameFSH
{
	my ($pane, @nodes) = @_;
	my $label = isRenameHomogeneous('fsh', @nodes);
	return if !$label;

	display(-1, 0, "===== RENAME (fsh) STARTED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);

	my $db = $navFSH::fsh_db;
	if (!$db)
	{
		error("winRename::onRenameFSH: no FSH db loaded");
		display(-1, 0, "===== RENAME (fsh) FINISHED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
		return;
	}

	my $type = $nodes[0]->{type} // '';

	my @pairs;
	my %node_by_id;
	for my $n (@nodes)
	{
		my $uuid = $n->{uuid};
		next if !$uuid;
		my $d = $n->{data} // {};
		push @pairs, [$uuid, $d->{name} // ''];
		$node_by_id{$uuid} = $n;
	}
	if (!@pairs)
	{
		display(-1, 0, "===== RENAME (fsh) FINISHED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
		return;
	}

	my $existing = _fshExistingPairs($db, $type);

	my $preflight = sub {
		my ($proposed) = @_;
		return preflightRename($proposed, $existing, $E80_MAX_NAME);
	};

	my $result = showRenameDialog($pane, $label, \@pairs, $preflight);
	if (!$result)
	{
		display(-1, 0, "===== RENAME (fsh) FINISHED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
		return;
	}

	display($dbg_rename, 0, "winRename::onRenameFSH applying " . scalar(@$result) . " row(s) to fsh $type");

	for my $p (@$result)
	{
		_applyFSHRename($db, $type, $p->[0], $p->[1], $node_by_id{$p->[0]});
	}

	navFSH::markDirty();
	$pane->refresh();

	display(-1, 0, "===== RENAME (fsh) FINISHED =====", 0, $UTILS_COLOR_LIGHT_MAGENTA);
}


#----------------------------------------------------
# _fshExistingPairs
#----------------------------------------------------
# Build the full universe of [id, name] pairs of a given type in the FSH.
# Waypoints include both standalone (BLK_WPT) and embedded (group->wpts).

sub _fshExistingPairs
{
	my ($db, $type) = @_;
	my @out;
	if ($type eq 'waypoint')
	{
		for my $u (keys %{$db->{waypoints} // {}})
		{
			push @out, [$u, $db->{waypoints}{$u}{name} // ''];
		}
		for my $grp (values %{$db->{groups} // {}})
		{
			for my $wp (@{$grp->{wpts} // []})
			{
				next if !$wp->{uuid};
				push @out, [$wp->{uuid}, $wp->{name} // ''];
			}
		}
	}
	elsif ($type eq 'group')
	{
		for my $u (keys %{$db->{groups} // {}})
		{
			push @out, [$u, $db->{groups}{$u}{name} // ''];
		}
	}
	elsif ($type eq 'route')
	{
		for my $u (keys %{$db->{routes} // {}})
		{
			push @out, [$u, $db->{routes}{$u}{name} // ''];
		}
	}
	elsif ($type eq 'track')
	{
		for my $u (keys %{$db->{tracks} // {}})
		{
			push @out, [$u, $db->{tracks}{$u}{name} // ''];
		}
	}
	return \@out;
}


#----------------------------------------------------
# _applyFSHRename
#----------------------------------------------------

sub _applyFSHRename
{
	my ($db, $type, $uuid, $new_name, $node) = @_;
	if ($type eq 'waypoint')
	{
		if ($db->{waypoints}{$uuid})
		{
			$db->{waypoints}{$uuid}{name} = $new_name;
			return;
		}
		# Embedded WP -- prefer the node's group_uuid hint, fall back to scan.
		my $hint = $node ? $node->{group_uuid} : undef;
		if ($hint && $db->{groups}{$hint})
		{
			for my $wp (@{$db->{groups}{$hint}{wpts} // []})
			{
				if (($wp->{uuid} // '') eq $uuid)
				{
					$wp->{name} = $new_name;
					return;
				}
			}
		}
		for my $grp (values %{$db->{groups} // {}})
		{
			for my $wp (@{$grp->{wpts} // []})
			{
				if (($wp->{uuid} // '') eq $uuid)
				{
					$wp->{name} = $new_name;
					return;
				}
			}
		}
	}
	elsif ($type eq 'group')
	{
		$db->{groups}{$uuid}{name} = $new_name if $db->{groups}{$uuid};
	}
	elsif ($type eq 'route')
	{
		$db->{routes}{$uuid}{name} = $new_name if $db->{routes}{$uuid};
	}
	elsif ($type eq 'track')
	{
		$db->{tracks}{$uuid}{name} = $new_name if $db->{tracks}{$uuid};
	}
}


1;
