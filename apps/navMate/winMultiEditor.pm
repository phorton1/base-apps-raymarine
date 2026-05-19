#!/usr/bin/perl
#-------------------------------------------------------------------------
# winMultiEditor.pm
#-------------------------------------------------------------------------
# Modal batch editor for changing shared properties across N>=2 selected
# items (waypoints, routes, tracks) in winDatabase.  See
# apps/navMate/docs/winMultiEditor.md for the design.
#
# Public entry:
#   winMultiEditor::openForSelection($parent_window, \@selected_nodes)
#       -> 1 if changes were committed, 0 if cancelled or nothing
#          eligible was selected.
#
# Eligible items: tree nodes whose type='object' and obj_type is one of
# waypoint, route, track.  All other nodes (collections, route_points,
# headers) are silently filtered.

package winMultiEditor;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_BUTTON
	EVT_CHOICE
	EVT_TEXT);
use Pub::Utils qw(display warning error);
use n_defs;
use n_utils qw(
	@E80_ROUTE_COLOR_NAMES
	@E80_ROUTE_COLOR_ABGR
	abgrToE80Index
	isExactE80Color);
use navDB;
use base 'Wx::Dialog';


my $MULTI_LABEL = '(multi)';


#---------------------------------
# Public entry point
#---------------------------------

sub openForSelection
{
	my ($parent, $nodes) = @_;
	my @items = _extractItems($nodes);
	return 0 if scalar(@items) < 2;
	_fetchCurrent(\@items);
	my $dlg = winMultiEditor->new($parent, \@items);
	my $rc  = $dlg->ShowModal();
	my $touched = $dlg->{_committed_uuids} || [];
	$dlg->Destroy();
	return ($rc == wxID_OK) ? $touched : 0;
}


sub _extractItems
{
	my ($nodes) = @_;
	my @out;
	my %seen;
	for my $n (@$nodes)
	{
		next if ($n->{type} // '') ne 'object';
		my $d = $n->{data} // {};
		my $ot = $d->{obj_type} // '';
		next unless $ot eq 'waypoint' || $ot eq 'route' || $ot eq 'track';
		my $uuid = $d->{uuid};
		next if !$uuid || $seen{$uuid}++;
		push @out, { uuid => $uuid, obj_type => $ot, name => $d->{name} // '' };
	}
	return @out;
}


sub _fetchCurrent
{
	my ($items) = @_;
	my $dbh = connectDB();
	return if !$dbh;
	for my $it (@$items)
	{
		my $ot = $it->{obj_type};
		my $rec;
		if ($ot eq 'waypoint')
		{
			$rec = $dbh->get_record(
				"SELECT color, comment, wp_type FROM waypoints WHERE uuid=?",
				[$it->{uuid}]);
		}
		elsif ($ot eq 'route')
		{
			$rec = $dbh->get_record(
				"SELECT color, comment FROM routes WHERE uuid=?",
				[$it->{uuid}]);
		}
		elsif ($ot eq 'track')
		{
			$rec = $dbh->get_record(
				"SELECT color FROM tracks WHERE uuid=?",
				[$it->{uuid}]);
		}
		$rec //= {};
		$it->{color}   = $rec->{color};
		$it->{comment} = $rec->{comment} if exists $rec->{comment};
		$it->{wp_type} = $rec->{wp_type} if exists $rec->{wp_type};
	}
	disconnectDB($dbh);
}


#---------------------------------
# Helpers
#---------------------------------

sub _sharedValue
{
	my ($vals) = @_;
	return undef if !@$vals;
	my $first = $vals->[0] // '';
	for my $v (@$vals)
	{
		return undef if ($v // '') ne $first;
	}
	return $first;
}


sub _greySwatch
{
	my ($panel) = @_;
	$panel->SetBackgroundColour(Wx::Colour->new(200, 200, 200));
	$panel->Refresh();
}


sub _setSwatch
{
	my ($panel, $abgr) = @_;
	if (defined($abgr) && length($abgr) >= 8)
	{
		my $rr = hex(substr($abgr, 6, 2));
		my $gg = hex(substr($abgr, 4, 2));
		my $bb = hex(substr($abgr, 2, 2));
		$panel->SetBackgroundColour(Wx::Colour->new($rr, $gg, $bb));
	}
	else
	{
		_greySwatch($panel);
	}
	$panel->Refresh();
}


#---------------------------------
# Constructor
#---------------------------------

sub new
{
	my ($class, $parent, $items) = @_;

	my @com_items = grep { $_->{obj_type} ne 'track'    } @$items;
	my @wp_items  = grep { $_->{obj_type} eq 'waypoint' } @$items;
	my $n_total   = scalar @$items;
	my $n_comment = scalar @com_items;
	my $n_wp_type = scalar @wp_items;

	my $color_shared   = _sharedValue([map { lc($_->{color} // '') } @$items]);
	my $comment_shared = @com_items ? _sharedValue([map { $_->{comment} // '' } @com_items]) : undef;
	my $wp_type_shared = @wp_items  ? _sharedValue([map { $_->{wp_type} // ''  } @wp_items])  : undef;

	my $row_h   = 32;
	my $label_x = 14;
	my $label_w = 80;
	my $ctrl_x  = 100;
	my $tag_x   = 410;
	my $tag_w   = 140;

	my $n_rows = 1                        # color
	           + ($n_comment > 0 ? 1 : 0)
	           + ($n_wp_type > 0 ? 1 : 0);

	my $dlg_w = $tag_x + $tag_w + 14;
	my $dlg_h = 50 + ($n_rows * $row_h) + 60;

	my $this = $class->SUPER::new($parent, -1, 'Batch Edit',
		wxDefaultPosition, [$dlg_w, $dlg_h],
		wxDEFAULT_DIALOG_STYLE);

	$this->{items} = $items;
	$this->{_color_dirty}   = 0;
	$this->{_color_value}   = $color_shared;
	$this->{_comment_dirty} = 0;
	$this->{_wp_type_dirty} = 0;
	$this->{_committed_uuids} = [];

	my $y = 14;
	Wx::StaticText->new($this, -1, "Batch edit $n_total items",
		[$label_x, $y], [-1, 20]);
	$y += 26;

	# --- Color row (always present) -------------------------------------
	Wx::StaticText->new($this, -1, 'Color', [$label_x, $y + 4], [$label_w, 20]);
	my @color_entries = (@E80_ROUTE_COLOR_NAMES, 'Custom');
	unshift @color_entries, $MULTI_LABEL if !defined $color_shared;
	$this->{cho_color} = Wx::Choice->new($this, -1,
		[$ctrl_x, $y], [180, 22], \@color_entries);
	$this->{swatch_color} = Wx::Panel->new($this, -1,
		[$ctrl_x + 186, $y + 2], [22, 18], wxSIMPLE_BORDER);
	$this->{btn_color_pick} = Wx::Button->new($this, -1, 'Pick...',
		[$ctrl_x + 214, $y], [-1, 22]);
	my $color_tag = defined($color_shared)
		? "($n_total items)"
		: "(multi $n_total)";
	$this->{tag_color} = Wx::StaticText->new($this, -1, $color_tag,
		[$tag_x, $y + 4], [$tag_w, 20]);
	$this->{_color_multi_offset} = defined($color_shared) ? 0 : 1;

	if (defined $color_shared)
	{
		my $idx = isExactE80Color($color_shared)
			? abgrToE80Index($color_shared)
			: scalar(@E80_ROUTE_COLOR_NAMES);
		$this->{cho_color}->SetSelection($idx);
		_setSwatch($this->{swatch_color}, $color_shared);
	}
	else
	{
		$this->{cho_color}->SetSelection(0);
		_greySwatch($this->{swatch_color});
	}
	$y += $row_h;

	# --- Comment row (if any non-track items) ---------------------------
	if ($n_comment > 0)
	{
		Wx::StaticText->new($this, -1, 'Comment', [$label_x, $y + 4], [$label_w, 20]);
		my $placeholder = defined($comment_shared)
			? $comment_shared
			: "(multi $n_comment)";
		$this->{txt_comment} = Wx::TextCtrl->new($this, -1, $placeholder,
			[$ctrl_x, $y], [290, 22]);
		my $tag = defined($comment_shared)
			? "($n_comment items)"
			: "(multi $n_comment)";
		$this->{tag_comment} = Wx::StaticText->new($this, -1, $tag,
			[$tag_x, $y + 4], [$tag_w, 20]);
		$this->{_comment_orig_text}   = $placeholder;
		$this->{_comment_orig_shared} = $comment_shared;
		EVT_TEXT($this, $this->{txt_comment},
			sub { $_[0]->{_comment_dirty} = 1 });
		$y += $row_h;
	}

	# --- wp_type row (if any waypoints) ---------------------------------
	if ($n_wp_type > 0)
	{
		Wx::StaticText->new($this, -1, 'Type', [$label_x, $y + 4], [$label_w, 20]);
		my @wp_types = ($WP_TYPE_NAV, $WP_TYPE_LABEL, $WP_TYPE_SOUNDING);
		my @entries  = @wp_types;
		unshift @entries, $MULTI_LABEL if !defined $wp_type_shared;
		$this->{cho_wp_type} = Wx::Choice->new($this, -1,
			[$ctrl_x, $y], [180, 22], \@entries);
		my $tag = defined($wp_type_shared)
			? "($n_wp_type items)"
			: "(multi $n_wp_type)";
		$this->{tag_wp_type} = Wx::StaticText->new($this, -1, $tag,
			[$tag_x, $y + 4], [$tag_w, 20]);
		$this->{_wp_type_values}       = \@wp_types;
		$this->{_wp_type_shared}       = $wp_type_shared;
		$this->{_wp_type_multi_offset} = defined($wp_type_shared) ? 0 : 1;
		if (defined $wp_type_shared)
		{
			my $idx = 0;
			for my $i (0 .. $#wp_types)
			{
				$idx = $i if $wp_types[$i] eq $wp_type_shared;
			}
			$this->{cho_wp_type}->SetSelection($idx);
		}
		else
		{
			$this->{cho_wp_type}->SetSelection(0);
		}
		EVT_CHOICE($this, $this->{cho_wp_type}, \&_onWpTypeChoice);
		$y += $row_h;
	}

	# --- OK / Cancel -----------------------------------------------------
	$y += 8;
	my $btn_y = $y;
	$this->{btn_ok} = Wx::Button->new($this, wxID_OK, 'OK',
		[$tag_x, $btn_y], [70, 26]);
	$this->{btn_cancel} = Wx::Button->new($this, wxID_CANCEL, 'Cancel',
		[$tag_x + 76, $btn_y], [70, 26]);

	EVT_CHOICE($this, $this->{cho_color},      \&_onColorChoice);
	EVT_BUTTON($this, $this->{btn_color_pick}, \&_onColorPick);
	EVT_BUTTON($this, $this->{btn_ok},         \&_onOK);
	EVT_BUTTON($this, $this->{btn_cancel},
		sub { $_[0]->EndModal(wxID_CANCEL) });

	return $this;
}


#---------------------------------
# Event handlers
#---------------------------------

sub _onColorChoice
{
	my ($this, $event) = @_;
	my $sel    = $this->{cho_color}->GetSelection();
	my $offset = $this->{_color_multi_offset};
	if ($offset && $sel == 0)
	{
		# user re-selected the (multi) entry -- treat as no change
		$this->{_color_dirty} = 0;
		_greySwatch($this->{swatch_color});
		return;
	}
	my $idx = $sel - $offset;
	if ($idx >= 0 && $idx < scalar(@E80_ROUTE_COLOR_NAMES))
	{
		$this->{_color_value} = $E80_ROUTE_COLOR_ABGR[$idx];
		$this->{_color_dirty} = 1;
		_setSwatch($this->{swatch_color}, $this->{_color_value});
	}
	# 'Custom' entry: do not commit anything until Pick... is used
}


sub _onColorPick
{
	my ($this, $event) = @_;
	my $current = $this->{_color_value} // 'FF0000FF';
	my $aa = substr($current, 0, 2);
	my $rr = hex(substr($current, 6, 2));
	my $gg = hex(substr($current, 4, 2));
	my $bb = hex(substr($current, 2, 2));

	my $cd = Wx::ColourData->new();
	$cd->SetColour(Wx::Colour->new($rr, $gg, $bb));
	$cd->SetChooseFull(1);

	my $dlg = Wx::ColourDialog->new($this, $cd);
	if ($dlg->ShowModal() == wxID_OK)
	{
		my $c = $dlg->GetColourData()->GetColour();
		my $new_abgr = sprintf('%s%02x%02x%02x',
			$aa, $c->Blue(), $c->Green(), $c->Red());
		$this->{_color_value} = $new_abgr;
		$this->{_color_dirty} = 1;
		_setSwatch($this->{swatch_color}, $new_abgr);
		my $custom_idx = $this->{_color_multi_offset} + scalar(@E80_ROUTE_COLOR_NAMES);
		$this->{cho_color}->SetSelection($custom_idx);
	}
	$dlg->Destroy();
}


sub _onWpTypeChoice
{
	my ($this, $event) = @_;
	$this->{_wp_type_dirty} = 1;
}


sub _onOK
{
	my ($this, $event) = @_;

	# Resolve final values
	my $color_new;
	$color_new = $this->{_color_value} if $this->{_color_dirty};

	# Comment: defined($comment_new) means "write it" (empty string is a
	# real value to write); undef means "no change".
	my $comment_new;
	if ($this->{txt_comment} && $this->{_comment_dirty})
	{
		my $txt = $this->{txt_comment}->GetValue();
		if (!defined $this->{_comment_orig_shared})
		{
			# multi case: untouched placeholder == no change
			if ($txt ne $this->{_comment_orig_text})
			{
				$comment_new = $txt;
			}
		}
		else
		{
			$comment_new = $txt;
		}
	}

	my $wp_type_new;
	if ($this->{cho_wp_type} && $this->{_wp_type_dirty})
	{
		my $sel    = $this->{cho_wp_type}->GetSelection();
		my $offset = $this->{_wp_type_multi_offset};
		if (!$offset || $sel > 0)
		{
			my $idx = $sel - $offset;
			$wp_type_new = $this->{_wp_type_values}[$idx];
		}
	}

	if (!defined($color_new) && !defined($comment_new) && !defined($wp_type_new))
	{
		# nothing dirty -- treat as cancel
		$this->EndModal(wxID_CANCEL);
		return;
	}

	my $dbh = connectDB();
	if (!$dbh)
	{
		warning(0, 0, "winMultiEditor: no DB connection");
		$this->EndModal(wxID_CANCEL);
		return;
	}

	my @touched;
	$dbh->do('BEGIN TRANSACTION', []);
	eval
	{
		for my $it (@{$this->{items}})
		{
			my $ot = $it->{obj_type};
			my $table = $ot eq 'waypoint' ? 'waypoints'
			          : $ot eq 'route'    ? 'routes'
			          : $ot eq 'track'    ? 'tracks'
			          : next;
			my %dirty;
			$dirty{color} = $color_new if defined $color_new;
			if (defined($comment_new) && $ot ne 'track')
			{
				$dirty{comment} = $comment_new;
			}
			if (defined($wp_type_new) && $ot eq 'waypoint')
			{
				$dirty{wp_type} = $wp_type_new;
			}
			next if !%dirty;
			$dbh->update_record($table, \%dirty, 'uuid', $it->{uuid}, 1);
			push @touched, $it->{uuid};
		}
	};
	my $err = $@;
	if ($err)
	{
		$dbh->do('ROLLBACK', []);
		warning(0, 0, "winMultiEditor: batch update failed: $err");
		disconnectDB($dbh);
		$this->EndModal(wxID_CANCEL);
		return;
	}
	$dbh->do('COMMIT', []);
	disconnectDB($dbh);

	$this->{_committed_uuids} = \@touched;
	$this->EndModal(wxID_OK);
}


1;
