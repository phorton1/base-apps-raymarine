#!/usr/bin/perl
#---------------------------------------------
# nmDialogs.pm
#---------------------------------------------
# Multi-field input dialogs for navMate New-object operations.

package nmDialogs;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Pub::Utils qw(warning getAppFrame);
use Pub::WX::Dialogs;


BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(
		$suppress_confirm
		$suppress_outcome
		$suppress_error_dialog
		confirmDialog
		showNewBranch
		showNewGroup
		showNewRoute
		showNewWaypoint
	);
}


our $suppress_confirm      :shared = 0;
our $suppress_outcome      :shared = 'accept';
our $suppress_error_dialog :shared = 0;


sub confirmDialog
{
	my ($win, $msg, $title) = @_;
	if ($suppress_confirm)
	{
		return ($suppress_outcome eq 'reject') ? 0 : 1;
	}
	$win = getAppFrame() if !$win;
	my $dlg = Wx::MessageDialog->new($win, $msg, $title, wxYES | wxNO | wxCENTRE);
	my $rslt = $dlg->ShowModal();
	$dlg->Destroy();
	return ($rslt == wxID_YES) ? 1 : 0;
}


sub showNewBranch
{
	my ($parent) = @_;
	return _showDialog($parent, 'New Branch', [
		{ key => 'name',    label => 'Name:',    required => 1 },
		{ key => 'comment', label => 'Comment:'               },
	]);
}

sub showNewGroup
{
	my ($parent) = @_;
	return _showDialog($parent, 'New Group', [
		{ key => 'name',    label => 'Name:',    required => 1 },
		{ key => 'comment', label => 'Comment:'               },
	]);
}

sub showNewRoute
{
	my ($parent) = @_;
	return _showDialog($parent, 'New Route', [
		{ key => 'name',    label => 'Name:',    required => 1              },
		{ key => 'comment', label => 'Comment:'                             },
		{ key => 'color',   label => 'Color:',   default  => '0xff000000'  },
	]);
}

sub showNewWaypoint
{
	my ($parent) = @_;
	return _showDialog($parent, 'New Waypoint', [
		{ key => 'name',    label => 'Name:',       required => 1 },
		{ key => 'lat',     label => 'Latitude:',   required => 1 },
		{ key => 'lon',     label => 'Longitude:',  required => 1 },
		{ key => 'comment', label => 'Comment:'                    },
	]);
}


#----------------------------------------------------
# _showDialog
#----------------------------------------------------
# fields: arrayref of { key, label, required?, default? }
# Returns hashref of trimmed values, or undef if cancelled or name empty.

sub _showDialog
{
	my ($parent, $title, $fields) = @_;

	my $dlg = Wx::Dialog->new($parent, -1, $title,
		wxDefaultPosition, [-1, -1],
		wxDEFAULT_DIALOG_STYLE);

	my $vsizer = Wx::BoxSizer->new(wxVERTICAL);
	my $gsizer = Wx::FlexGridSizer->new(scalar(@$fields), 2, 6, 8);
	$gsizer->AddGrowableCol(1);

	my @controls;
	for my $f (@$fields)
	{
		$gsizer->Add(
			Wx::StaticText->new($dlg, -1, $f->{label}),
			0, wxALIGN_CENTER_VERTICAL | wxALIGN_RIGHT);
		my $ctrl = Wx::TextCtrl->new($dlg, -1, $f->{default} // '',
			wxDefaultPosition, [280, -1]);
		$gsizer->Add($ctrl, 1, wxEXPAND);
		push @controls, { ctrl => $ctrl, spec => $f };
	}

	$vsizer->Add($gsizer, 0, wxEXPAND | wxALL, 10);
	$vsizer->Add($dlg->CreateButtonSizer(wxOK | wxCANCEL),
		0, wxEXPAND | wxLEFT | wxRIGHT | wxBOTTOM, 8);
	$dlg->SetSizerAndFit($vsizer);
	$dlg->Centre();

	$controls[0]{ctrl}->SetFocus() if @controls;

	my $result = undef;
	if ($dlg->ShowModal() == wxID_OK)
	{
		my %data;
		my $ok = 1;
		for my $c (@controls)
		{
			my $val = $c->{ctrl}->GetValue();
			$val =~ s/^\s+|\s+$//g;
			if ($c->{spec}{required} && $val eq '')
			{
				okDialog($parent, $c->{spec}{label} . " is required.", $title);
				$ok = 0;
				last;
			}
			$data{ $c->{spec}{key} } = $val;
		}
		$result = \%data if $ok;
	}

	$dlg->Destroy();
	return $result;
}


1;
