#!/usr/bin/perl
#---------------------------------------------
# winSymMapping.pm
#---------------------------------------------
# Two modal dialogs that surface the wp_type -> sym mapping kept in
# key_values.wp_mapped_syms:
#
#   showSymMappingDialog($parent)
#       The Conservative editor.  Lists all 9 wp_types and their current
#       mapped syms; user may edit, then Save applies a conservative
#       UPDATE pass that only touches waypoints whose pre-edit pair was
#       in sync with the mapping.  Off-map (hand-set) syms are preserved.
#       Also the primary "see what the current mappings are" surface.
#
#   showForceSymResetDialog($parent)
#       The Force command.  Picks one wp_type and resets EVERY waypoint
#       of that type to the mapped sym -- including hand-set ones.
#       Destructive; confirmed before running.
#
# Both refresh the navDB sym-map cache on apply and return 1 if changes
# were committed (so callers can refresh the database panes).

package winSymMapping;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(EVT_CHOICE EVT_BUTTON);
use Pub::Utils qw(display warning error my_encode_json);
use Pub::WX::Dialogs;
use navDB;
use n_defs;
use n_utils;
use nmDialogs qw(confirmDialog);
use nmResources qw(symBitmap makeSymComboBox);
use apps::raymarine::NET::a_utils;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		showSymMappingDialog
		showForceSymResetDialog
	);
}


my $dbg_sym_map = 0;


#----------------------------------------------------
# helpers
#----------------------------------------------------

sub _snapshotMapping
{
	# Read the current %_mapped_syms cache by walking the wp_type enum.
	# (loadSymMap was called at openDB; the cache reflects the row.)
	my %snap;
	for my $wt (0 .. $#WP_TYPE_NAMES)
	{
		my $sym = symForWpType($wt);
		$snap{$wt} = defined $sym ? $sym : ($WP_DEFAULT_SYMS{$wt} // 0);
	}
	return \%snap;
}


#----------------------------------------------------
# showSymMappingDialog -- Conservative editor
#----------------------------------------------------

sub showSymMappingDialog
{
	my ($parent) = @_;

	my $snap = _snapshotMapping();

	my $dlg = Wx::Dialog->new($parent, -1, 'Waypoint Sym Mapping',
		wxDefaultPosition, [460, 440],
		wxDEFAULT_DIALOG_STYLE);

	my $vsizer = Wx::BoxSizer->new(wxVERTICAL);

	$vsizer->Add(Wx::StaticText->new($dlg, -1,
		"Each wp_type has a mapped sym.  Editing a row + Save runs a\n" .
		"conservative pass: waypoints currently in sync with the\n" .
		"mapping follow to the new sym; off-map (hand-set) syms are\n" .
		"preserved.  Force Reset is available from the Utils menu."),
		0, wxALL, 10);

	my $grid = Wx::FlexGridSizer->new(scalar(@WP_TYPE_NAMES), 2, 4, 12);
	my @sym_choices;
	for my $wt (0 .. $#WP_TYPE_NAMES)
	{
		my $label = sprintf('%d - %s', $wt, $WP_TYPE_NAMES[$wt]);
		$grid->Add(Wx::StaticText->new($dlg, -1, $label),
			0, wxALIGN_CENTER_VERTICAL | wxLEFT, 10);
		my $choice = makeSymComboBox($dlg, wxDefaultPosition, [240, -1]);
		$choice->SetSelection($snap->{$wt} // 0);
		$grid->Add($choice, 0, wxRIGHT, 10);
		$sym_choices[$wt] = $choice;
	}
	$vsizer->Add($grid, 0, wxALIGN_CENTER_HORIZONTAL);

	# Buttons row
	my $reset_btn  = Wx::Button->new($dlg, -1,         'Reset to Defaults');
	my $cancel_btn = Wx::Button->new($dlg, wxID_CANCEL, 'Cancel');
	my $save_btn   = Wx::Button->new($dlg, wxID_OK,     'Save');
	my $btn_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$btn_row->Add($reset_btn,  0);
	$btn_row->AddStretchSpacer(1);
	$btn_row->Add($cancel_btn, 0, wxRIGHT, 8);
	$btn_row->Add($save_btn,   0);
	$vsizer->Add($btn_row, 0, wxEXPAND | wxALL, 10);

	$dlg->SetSizer($vsizer);

	my $applied = 0;

	EVT_BUTTON($dlg, $reset_btn, sub {
		return if !confirmDialog($dlg,
			"Reset all 9 sym mappings to their seed defaults?\n\n" .
			"This only refills the dialog -- you still need to click Save\n" .
			"to apply the changes.",
			'Reset to Defaults');
		for my $wt (0 .. $#WP_TYPE_NAMES)
		{
			my $def = $WP_DEFAULT_SYMS{$wt} // 0;
			$sym_choices[$wt]->SetSelection($def);
		}
	});

	EVT_BUTTON($dlg, wxID_OK, sub {
		# Read new mapping from Choices
		my %new_map;
		for my $wt (0 .. $#WP_TYPE_NAMES)
		{
			$new_map{$wt} = $sym_choices[$wt]->GetSelection();
		}

		# Uniqueness validation
		my %seen;
		my @dups;
		for my $wt (sort { $a <=> $b } keys %new_map)
		{
			my $s = $new_map{$wt};
			if ($seen{$s})
			{
				push @dups, sprintf("sym %d - %s is assigned to both '%s' and '%s'",
					$s, $E80_SYMS[$s], $WP_TYPE_NAMES[$seen{$s} - 1], $WP_TYPE_NAMES[$wt]);
			}
			else
			{
				$seen{$s} = $wt + 1;  # +1 because 0 is a valid wp_type
			}
		}
		if (@dups)
		{
			my $msg = "Each sym can map to at most one wp_type.\n\n" . join("\n", @dups);
			my $err = Wx::MessageDialog->new($dlg, $msg, 'Mapping conflict',
				wxOK | wxICON_WARNING | wxCENTRE);
			$err->ShowModal();
			$err->Destroy();
			return;
		}

		# Diff vs snapshot
		my @changed;
		for my $wt (0 .. $#WP_TYPE_NAMES)
		{
			push @changed, $wt if $new_map{$wt} != $snap->{$wt};
		}

		if (!@changed)
		{
			$dlg->EndModal(wxID_CANCEL);
			return;
		}

		# Preflight: count mapped vs off-map waypoints per changed wp_type
		my $dbh = connectDB();
		if (!$dbh)
		{
			error("winSymMapping: connectDB failed");
			return;
		}
		my $total_mapped   = 0;
		my $total_off_map  = 0;
		my @lines;
		for my $wt (@changed)
		{
			my $old = $snap->{$wt};
			my $new = $new_map{$wt};
			my $mapped_rec = $dbh->get_record(
				"SELECT COUNT(*) AS n FROM waypoints WHERE wp_type=? AND sym=?",
				[$wt, $old]);
			my $any_rec = $dbh->get_record(
				"SELECT COUNT(*) AS n FROM waypoints WHERE wp_type=?",
				[$wt]);
			my $mapped = $mapped_rec ? $mapped_rec->{n} : 0;
			my $any    = $any_rec    ? $any_rec->{n}    : 0;
			my $off    = $any - $mapped;
			$total_mapped  += $mapped;
			$total_off_map += $off;
			push @lines, sprintf(
				"  %-9s: sym %d -> sym %d, %d will follow, %d preserved (off-map)",
				$WP_TYPE_NAMES[$wt], $old, $new, $mapped, $off);
		}

		my $confirm_msg =
			"Apply the following sym mapping changes?\n\n" .
			join("\n", @lines) .
			"\n\nTotal: $total_mapped waypoint(s) will be updated, " .
			"$total_off_map preserved.";

		if (!confirmDialog($dlg, $confirm_msg, 'Apply sym mapping'))
		{
			disconnectDB($dbh);
			return;
		}

		# Commit transaction
		my $err;
		eval {
			$dbh->{dbh}->begin_work();
			for my $wt (@changed)
			{
				my $old = $snap->{$wt};
				my $new = $new_map{$wt};
				$dbh->do(
					"UPDATE waypoints SET sym=? WHERE wp_type=? AND sym=?",
					[$new, $wt, $old]);
			}
			$dbh->do(
				"UPDATE key_values SET value=? WHERE key='wp_mapped_syms'",
				[my_encode_json(\%new_map)]);
			$dbh->commit();
		};
		$err = $@;
		if ($err)
		{
			eval { $dbh->rollback() };
			error("winSymMapping: transaction failed: $err");
			disconnectDB($dbh);
			my $msg = Wx::MessageDialog->new($dlg,
				"Mapping update failed: $err", 'Error',
				wxOK | wxICON_ERROR | wxCENTRE);
			$msg->ShowModal();
			$msg->Destroy();
			return;
		}

		# Refresh in-memory cache from the freshly-written row
		loadSymMap($dbh);
		disconnectDB($dbh);

		display(0, 0, "winSymMapping: applied " . scalar(@changed) . " mapping change(s); " .
			"$total_mapped waypoint(s) updated, $total_off_map preserved");
		$applied = 1;
		$dlg->EndModal(wxID_OK);
	});

	$dlg->ShowModal();
	$dlg->Destroy();
	return $applied;
}


#----------------------------------------------------
# showForceSymResetDialog -- Force command (per-row)
#----------------------------------------------------
# Read-only view of the wp_type -> sym mapping with a live "Hand-set"
# count per row (waypoints of that wp_type whose sym differs from the
# mapping).  Each row carries its own [Force] button which is disabled
# when the hand-set count is 0.  Clicking a row's [Force] confirms,
# runs a single UPDATE for that wp_type, refreshes the row's count,
# and re-disables the button.  Dialog stays open so the user can step
# through multiple rows.  Close dismisses.
#
# Returns 1 if any row got force-reset (so the caller can refresh
# database panes); 0 if nothing was applied.

sub _handsetCount
{
	my ($dbh, $wt, $def) = @_;
	my $r = $dbh->get_record(
		"SELECT COUNT(*) AS n FROM waypoints WHERE wp_type=? AND sym<>?",
		[$wt, $def]);
	return $r ? $r->{n} : 0;
}


sub showForceSymResetDialog
{
	my ($parent) = @_;

	my $dlg = Wx::Dialog->new($parent, -1, 'Force Reset Syms by Waypoint Type',
		wxDefaultPosition, [520, 480],
		wxDEFAULT_DIALOG_STYLE);

	my $vsizer = Wx::BoxSizer->new(wxVERTICAL);

	$vsizer->Add(Wx::StaticText->new($dlg, -1,
		"For each wp_type, [Force] sets every waypoint of that type to\n" .
		"the mapped sym -- including hand-set syms.  Destructive; hand-\n" .
		"set syms cannot be recovered.  Button disables when there's\n" .
		"nothing diverging to overwrite.\n\n" .
		"Edit the mapping itself via Utils > Waypoint Sym Mapping..."),
		0, wxALL, 10);

	# Header row (5 columns: Type, Icon, Sym, Hand-set, Action)
	my $grid = Wx::FlexGridSizer->new(scalar(@WP_TYPE_NAMES) + 1, 5, 6, 10);
	$grid->Add(Wx::StaticText->new($dlg, -1, 'Type'),     0, wxLEFT,  10);
	$grid->Add(Wx::StaticText->new($dlg, -1, ''),         0);
	$grid->Add(Wx::StaticText->new($dlg, -1, 'Sym'),      0);
	$grid->Add(Wx::StaticText->new($dlg, -1, 'Hand-set'), 0);
	$grid->Add(Wx::StaticText->new($dlg, -1, ''),         0, wxRIGHT, 10);

	my @count_lbls;
	my @force_btns;
	for my $wt (0 .. $#WP_TYPE_NAMES)
	{
		my $def_sym = symForWpType($wt) // 0;
		$grid->Add(Wx::StaticText->new($dlg, -1,
			sprintf('%d - %s', $wt, $WP_TYPE_NAMES[$wt])),
			0, wxALIGN_CENTER_VERTICAL | wxLEFT, 10);
		my $bm = symBitmap($def_sym);
		$grid->Add(Wx::StaticBitmap->new($dlg, -1, $bm),
			0, wxALIGN_CENTER_VERTICAL);
		$grid->Add(Wx::StaticText->new($dlg, -1,
			sprintf('%d - %s', $def_sym, $E80_SYMS[$def_sym])),
			0, wxALIGN_CENTER_VERTICAL);
		my $count_lbl = Wx::StaticText->new($dlg, -1, '0',
			wxDefaultPosition, [50, -1]);
		$count_lbls[$wt] = $count_lbl;
		$grid->Add($count_lbl, 0, wxALIGN_CENTER_VERTICAL);
		my $btn = Wx::Button->new($dlg, -1, 'Force');
		$force_btns[$wt] = $btn;
		$grid->Add($btn, 0, wxRIGHT, 10);
	}
	$vsizer->Add($grid, 0, wxALIGN_CENTER_HORIZONTAL);

	# Close button
	my $close_btn = Wx::Button->new($dlg, wxID_CANCEL, 'Close');
	my $btn_row = Wx::BoxSizer->new(wxHORIZONTAL);
	$btn_row->AddStretchSpacer(1);
	$btn_row->Add($close_btn, 0);
	$vsizer->Add($btn_row, 0, wxEXPAND | wxALL, 10);

	$dlg->SetSizer($vsizer);

	# Initial count refresh
	my $refresh_row = sub {
		my ($wt) = @_;
		my $dbh = connectDB();
		return if !$dbh;
		my $def = symForWpType($wt) // 0;
		my $n = _handsetCount($dbh, $wt, $def);
		disconnectDB($dbh);
		$count_lbls[$wt]->SetLabel($n);
		$force_btns[$wt]->Enable($n > 0 ? 1 : 0);
	};
	$refresh_row->($_) for 0 .. $#WP_TYPE_NAMES;

	my $applied = 0;

	# Per-row Force button wiring
	for my $wt (0 .. $#WP_TYPE_NAMES)
	{
		my $btn = $force_btns[$wt];
		EVT_BUTTON($dlg, $btn, sub {
			my $def = symForWpType($wt);
			if (!defined $def)
			{
				error("winSymMapping: no mapped sym for wp_type $wt");
				return;
			}
			my $dbh = connectDB();
			if (!$dbh)
			{
				error("winSymMapping: connectDB failed");
				return;
			}
			my $n = _handsetCount($dbh, $wt, $def);
			if ($n == 0)
			{
				disconnectDB($dbh);
				return;
			}
			my $msg = sprintf(
				"Force sym=%d (%s) on every waypoint with wp_type='%s'.\n\n" .
				"%d hand-set sym(s) will be overwritten and cannot be recovered.\n\n" .
				"Continue?",
				$def, $E80_SYMS[$def], $WP_TYPE_NAMES[$wt], $n);
			if (!confirmDialog($dlg, $msg, 'Force Reset Syms'))
			{
				disconnectDB($dbh);
				return;
			}

			my $err;
			eval {
				$dbh->{dbh}->begin_work();
				$dbh->do(
					"UPDATE waypoints SET sym=? WHERE wp_type=?",
					[$def, $wt]);
				$dbh->commit();
			};
			$err = $@;
			if ($err)
			{
				eval { $dbh->rollback() };
				error("winSymMapping: force-reset transaction failed: $err");
				disconnectDB($dbh);
				my $errdlg = Wx::MessageDialog->new($dlg,
					"Force Reset failed: $err", 'Error',
					wxOK | wxICON_ERROR | wxCENTRE);
				$errdlg->ShowModal();
				$errdlg->Destroy();
				return;
			}
			disconnectDB($dbh);

			display(0, 0, sprintf(
				"winSymMapping: force-reset %s to sym %d (%s); %d hand-set syms overwritten",
				$WP_TYPE_NAMES[$wt], $def, $E80_SYMS[$def], $n));
			$applied = 1;
			$refresh_row->($wt);
		});
	}

	$dlg->ShowModal();
	$dlg->Destroy();
	return $applied;
}


1;
