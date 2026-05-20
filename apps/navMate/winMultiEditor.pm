#!/usr/bin/perl
#-------------------------------------------------------------------------
# winMultiEditor.pm
#-------------------------------------------------------------------------
# Modal multi-item editor for changing shared properties across N>=2 selected
# items (waypoints, routes, tracks) in a tree window.  See
# apps/navMate/docs/winMultiEditor.md for the design.
#
# Public entry:
#   winMultiEditor::openForSelection($parent_window, \@selected_nodes, \%descriptor)
#       -> arrayref of touched UUIDs if changes were committed, 0 if
#          cancelled or nothing eligible was selected.
#
# Eligible items: tree nodes whose type=='object' with obj_type one of
# waypoint/route/track (winDatabase shape), OR whose type itself is
# 'waypoint'/'route'/'track' (winFSH shape).  All other nodes are
# silently filtered.
#
# Descriptor (caller-supplied; no defaults):
#   fetch       => coderef ($items) -> fills color/comment/wp_type/sym
#   commit      => coderef ($items, \%changes) -> returns \@touched_uuids
#   color_row   => 'abgr' | 'palette_index'
#   has_wp_type => 0 | 1
#   has_sym     => 0 | 1
#   comment_max => undef | int (hard-reject limit)
#
# The two color editors are intentionally distinct: 'abgr' uses an ABGR
# string end-to-end with a Custom entry + Pick... button; 'palette_index'
# uses an integer index end-to-end with only the named palette and a
# read-only swatch.  No translation between the two modes ever runs.

package winMultiEditor;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_BUTTON
	EVT_CHOICE
	EVT_COMBOBOX
	EVT_TEXT);
use Pub::Utils qw(display warning error);
use n_defs;
use n_utils qw(
	@E80_ROUTE_COLOR_NAMES
	@E80_ROUTE_COLOR_ABGR
	abgrToE80Index
	isExactE80Color);
use apps::raymarine::NET::a_utils;
use nmResources qw(makeSymComboBox);
use base 'Wx::Dialog';


my $MULTI_LABEL = '(multi)';

# Layout constants
my $LBL_X        = 14;
my $LBL_W        = 80;
my $CTRL_X       = 100;
my $COL_GAP      = 6;
my $TAG_PAD      = 30;
my $TAG_W        = 140;
my $ROW_H        = 32;

# Common control widths
my $CHOICE_W     = 180;
my $SWATCH_W     = 22;
my $PICK_W       = 60;
my $COMMENT_W    = 290;
my $SYM_CHOICE_W = 260;


#---------------------------------
# Public entry point
#---------------------------------

sub openForSelection
{
	my ($parent, $nodes, $descriptor) = @_;
	return 0 if !$descriptor || ref($descriptor) ne 'HASH';
	my @items = _extractItems($nodes);
	return 0 if scalar(@items) < 2;
	my $fetch = $descriptor->{fetch};
	if (ref($fetch) eq 'CODE')
	{
		$fetch->(\@items);
	}
	my $dlg = winMultiEditor->new($parent, \@items, $descriptor);
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
		my $node_type = $n->{type} // '';
		my ($ot, $uuid, $name);
		if ($node_type eq 'object')
		{
			# winDatabase shape
			my $d = $n->{data} // {};
			$ot   = $d->{obj_type} // '';
			$uuid = $d->{uuid};
			$name = $d->{name} // '';
		}
		elsif ($node_type eq 'waypoint' || $node_type eq 'route' || $node_type eq 'track')
		{
			# winFSH shape: tree node type IS the obj_type
			$ot   = $node_type;
			$uuid = $n->{uuid};
			$name = ($n->{data} // {})->{name} // '';
		}
		else
		{
			next;
		}
		next if $ot ne 'waypoint' && $ot ne 'route' && $ot ne 'track';
		next if !$uuid || $seen{$uuid}++;
		push @out, { uuid => $uuid, obj_type => $ot, name => $name };
	}
	return @out;
}


#---------------------------------
# Shared helpers
#---------------------------------

sub _sharedValue
{
	my ($vals) = @_;
	return undef if !@$vals;
	my $first = $vals->[0];
	return undef if !defined $first;
	for my $v (@$vals)
	{
		return undef if !defined $v;
		return undef if $v ne $first;
	}
	return $first;
}


sub _greySwatch
{
	my ($panel) = @_;
	$panel->SetBackgroundColour(Wx::Colour->new(200, 200, 200));
	$panel->Refresh();
}


sub _setSwatchAbgr
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


sub _setSwatchIndex
{
	my ($panel, $idx) = @_;
	if (defined($idx) && $idx >= 0 && $idx < scalar(@E80_ROUTE_COLOR_ABGR))
	{
		_setSwatchAbgr($panel, $E80_ROUTE_COLOR_ABGR[$idx]);
	}
	else
	{
		_greySwatch($panel);
	}
}


sub _tagText
{
	my ($shared, $n) = @_;
	return defined($shared) ? "($n items)" : "(multi $n)";
}


#---------------------------------
# Constructor
#---------------------------------

sub new
{
	my ($class, $parent, $items, $descriptor) = @_;

	my @com_items = @$items;
	my @wp_items  = grep { $_->{obj_type} eq 'waypoint' } @$items;

	# ----- Per-type counts for title --------------------------------
	my %type_counts;
	$type_counts{$_->{obj_type}}++ for @$items;
	my @type_parts;
	for my $ot (qw(waypoint route track))
	{
		my $n = $type_counts{$ot} || 0;
		next if !$n;
		my $label = $n == 1 ? $ot : $ot.'s';
		push @type_parts, "$n $label";
	}
	my $n_total = scalar(@$items);
	my $title = "Multi edit $n_total items";
	$title .= ': ' . join(', ', @type_parts) if @type_parts;

	# ----- Which rows apply -----------------------------------------
	my $color_mode  = $descriptor->{color_row} // 'abgr';
	my $has_wp_type = $descriptor->{has_wp_type} ? 1 : 0;
	my $has_sym     = $descriptor->{has_sym}     ? 1 : 0;
	my $comment_max = $descriptor->{comment_max};

	my $show_color   = 1;
	my $show_comment = (scalar @com_items) > 0;
	my $show_wp_type = $has_wp_type && (scalar @wp_items) > 0;
	my $show_sym     = $has_sym     && (scalar @wp_items) > 0;

	# ----- Shared values --------------------------------------------
	my $color_shared;
	if ($color_mode eq 'palette_index')
	{
		$color_shared = _sharedValue([map { defined($_->{color}) ? ($_->{color} + 0) : undef } @$items]);
	}
	else
	{
		$color_shared = _sharedValue([map { defined($_->{color}) ? lc($_->{color}) : undef } @$items]);
	}
	my $comment_shared = $show_comment
		? _sharedValue([map { $_->{comment} // '' } @com_items]) : undef;
	my $wp_type_shared = $show_wp_type
		? _sharedValue([map { $_->{wp_type} // $WP_TYPE_NAV } @wp_items]) : undef;
	my $sym_shared     = $show_sym
		? _sharedValue([map { defined($_->{sym}) ? ($_->{sym} + 0) : undef } @wp_items]) : undef;

	# ----- Dialog dimensions: tag_x driven by widest row's sub-width
	my @widths;
	if ($show_color)
	{
		my $w = $CHOICE_W + $COL_GAP + $SWATCH_W;
		$w += $COL_GAP + $PICK_W if $color_mode eq 'abgr';
		push @widths, $w;
	}
	push @widths, $COMMENT_W     if $show_comment;
	push @widths, $CHOICE_W      if $show_wp_type;
	push @widths, $SYM_CHOICE_W  if $show_sym;

	my $max_sub_w = 0;
	for my $w (@widths) { $max_sub_w = $w if $w > $max_sub_w; }
	my $tag_x = $CTRL_X + $max_sub_w + $TAG_PAD;
	my $dlg_w = $tag_x + $TAG_W + 14;

	my $n_rows = ($show_color ? 1 : 0)
	           + ($show_comment ? 1 : 0)
	           + ($show_wp_type ? 1 : 0)
	           + ($show_sym ? 1 : 0);
	my $dlg_h = 50 + ($n_rows * $ROW_H) + 60;

	my $this = $class->SUPER::new($parent, -1, 'Multi Edit',
		wxDefaultPosition, [$dlg_w, $dlg_h],
		wxDEFAULT_DIALOG_STYLE);

	$this->{items}            = $items;
	$this->{descriptor}       = $descriptor;
	$this->{_color_mode}      = $color_mode;
	$this->{_color_dirty}     = 0;
	$this->{_color_value}     = $color_shared;
	$this->{_comment_dirty}   = 0;
	$this->{_wp_type_dirty}   = 0;
	$this->{_sym_dirty}       = 0;
	$this->{_committed_uuids} = [];

	# ----- Title ----------------------------------------------------
	my $y = 14;
	Wx::StaticText->new($this, -1, $title, [$LBL_X, $y], [-1, 20]);
	$y += 26;

	# ----- Rows (top-down, no gaps) ---------------------------------
	if ($show_color)
	{
		if ($color_mode eq 'palette_index')
		{
			_buildColorRowPalette($this, $y, $n_total, $color_shared, $tag_x);
		}
		else
		{
			_buildColorRowAbgr($this, $y, $n_total, $color_shared, $tag_x);
		}
		$y += $ROW_H;
	}
	if ($show_comment)
	{
		_buildCommentRow($this, $y, scalar(@com_items),
			$comment_shared, $comment_max, $tag_x);
		$y += $ROW_H;
	}
	if ($show_wp_type)
	{
		_buildWpTypeRow($this, $y, scalar(@wp_items), $wp_type_shared, $tag_x);
		$y += $ROW_H;
	}
	if ($show_sym)
	{
		_buildSymRow($this, $y, scalar(@wp_items), $sym_shared, $tag_x);
		$y += $ROW_H;
	}

	# ----- OK / Cancel ----------------------------------------------
	$y += 8;
	$this->{btn_ok} = Wx::Button->new($this, wxID_OK, 'OK',
		[$tag_x, $y], [70, 26]);
	$this->{btn_cancel} = Wx::Button->new($this, wxID_CANCEL, 'Cancel',
		[$tag_x + 76, $y], [70, 26]);
	EVT_BUTTON($this, $this->{btn_ok},     \&_onOK);
	EVT_BUTTON($this, $this->{btn_cancel}, sub { $_[0]->EndModal(wxID_CANCEL) });

	return $this;
}


#---------------------------------
# Row builders
#---------------------------------

sub _buildColorRowAbgr
{
	my ($this, $y, $n_total, $color_shared, $tag_x) = @_;
	Wx::StaticText->new($this, -1, 'Color', [$LBL_X, $y + 4], [$LBL_W, 20]);

	my @entries = (@E80_ROUTE_COLOR_NAMES, 'Custom');
	unshift @entries, $MULTI_LABEL if !defined $color_shared;

	my $x = $CTRL_X;
	$this->{cho_color} = Wx::Choice->new($this, -1,
		[$x, $y], [$CHOICE_W, 22], \@entries);
	$x += $CHOICE_W + $COL_GAP;

	$this->{swatch_color} = Wx::Panel->new($this, -1,
		[$x, $y + 2], [$SWATCH_W, 18], wxSIMPLE_BORDER);
	$x += $SWATCH_W + $COL_GAP;

	$this->{btn_color_pick} = Wx::Button->new($this, -1, 'Pick...',
		[$x, $y], [$PICK_W, 22]);

	$this->{tag_color} = Wx::StaticText->new($this, -1,
		_tagText($color_shared, $n_total), [$tag_x, $y + 4], [$TAG_W, 20]);

	$this->{_color_multi_offset} = defined($color_shared) ? 0 : 1;

	if (defined $color_shared)
	{
		my $idx = isExactE80Color($color_shared)
			? abgrToE80Index($color_shared)
			: scalar(@E80_ROUTE_COLOR_NAMES);
		$this->{cho_color}->SetSelection($idx);
		_setSwatchAbgr($this->{swatch_color}, $color_shared);
	}
	else
	{
		$this->{cho_color}->SetSelection(0);
		_greySwatch($this->{swatch_color});
	}

	EVT_CHOICE($this, $this->{cho_color},      \&_onColorChoiceAbgr);
	EVT_BUTTON($this, $this->{btn_color_pick}, \&_onColorPick);
}


sub _buildColorRowPalette
{
	my ($this, $y, $n_total, $color_shared, $tag_x) = @_;
	Wx::StaticText->new($this, -1, 'Color', [$LBL_X, $y + 4], [$LBL_W, 20]);

	my @entries = (@E80_ROUTE_COLOR_NAMES);
	unshift @entries, $MULTI_LABEL if !defined $color_shared;

	my $x = $CTRL_X;
	$this->{cho_color} = Wx::Choice->new($this, -1,
		[$x, $y], [$CHOICE_W, 22], \@entries);
	$x += $CHOICE_W + $COL_GAP;

	$this->{swatch_color} = Wx::Panel->new($this, -1,
		[$x, $y + 2], [$SWATCH_W, 18], wxSIMPLE_BORDER);
	# No Pick... button in palette mode; ABGR is never exposed.

	$this->{tag_color} = Wx::StaticText->new($this, -1,
		_tagText($color_shared, $n_total), [$tag_x, $y + 4], [$TAG_W, 20]);

	$this->{_color_multi_offset} = defined($color_shared) ? 0 : 1;

	if (defined $color_shared)
	{
		my $idx = $color_shared + 0;
		my $offset = $this->{_color_multi_offset};
		$this->{cho_color}->SetSelection($idx + $offset);
		_setSwatchIndex($this->{swatch_color}, $idx);
	}
	else
	{
		$this->{cho_color}->SetSelection(0);
		_greySwatch($this->{swatch_color});
	}

	EVT_CHOICE($this, $this->{cho_color}, \&_onColorChoicePalette);
}


sub _buildCommentRow
{
	my ($this, $y, $n_comment, $comment_shared, $comment_max, $tag_x) = @_;
	Wx::StaticText->new($this, -1, 'Comment', [$LBL_X, $y + 4], [$LBL_W, 20]);

	my $placeholder = defined($comment_shared)
		? $comment_shared
		: "(multi $n_comment)";
	$this->{txt_comment} = Wx::TextCtrl->new($this, -1, $placeholder,
		[$CTRL_X, $y], [$COMMENT_W, 22]);
	$this->{txt_comment}->SetMaxLength($comment_max) if $comment_max;

	$this->{tag_comment} = Wx::StaticText->new($this, -1,
		_tagText($comment_shared, $n_comment), [$tag_x, $y + 4], [$TAG_W, 20]);

	$this->{_comment_orig_text}   = $placeholder;
	$this->{_comment_orig_shared} = $comment_shared;
	$this->{_comment_max}         = $comment_max;
	EVT_TEXT($this, $this->{txt_comment},
		sub { $_[0]->{_comment_dirty} = 1 });
}


sub _buildWpTypeRow
{
	my ($this, $y, $n_wp, $wp_type_shared, $tag_x) = @_;
	Wx::StaticText->new($this, -1, 'Type', [$LBL_X, $y + 4], [$LBL_W, 20]);

	my @wp_types  = (0 .. $#WP_TYPE_NAMES);
	my @wp_labels = @WP_TYPE_NAMES;
	my @entries   = @wp_labels;
	unshift @entries, $MULTI_LABEL if !defined $wp_type_shared;

	$this->{cho_wp_type} = Wx::Choice->new($this, -1,
		[$CTRL_X, $y], [$CHOICE_W, 22], \@entries);
	$this->{tag_wp_type} = Wx::StaticText->new($this, -1,
		_tagText($wp_type_shared, $n_wp), [$tag_x, $y + 4], [$TAG_W, 20]);

	$this->{_wp_type_values}       = \@wp_types;
	$this->{_wp_type_shared}       = $wp_type_shared;
	$this->{_wp_type_multi_offset} = defined($wp_type_shared) ? 0 : 1;

	if (defined $wp_type_shared)
	{
		my $idx = 0;
		for my $i (0 .. $#wp_types)
		{
			$idx = $i if $wp_types[$i] == $wp_type_shared;
		}
		$this->{cho_wp_type}->SetSelection($idx);
	}
	else
	{
		$this->{cho_wp_type}->SetSelection(0);
	}
	EVT_CHOICE($this, $this->{cho_wp_type},
		sub { $_[0]->{_wp_type_dirty} = 1 });
}


sub _buildSymRow
{
	my ($this, $y, $n_wp, $sym_shared, $tag_x) = @_;
	Wx::StaticText->new($this, -1, 'Sym', [$LBL_X, $y + 4], [$LBL_W, 20]);

	$this->{cho_sym} = makeSymComboBox($this,
		[$CTRL_X, $y], [$SYM_CHOICE_W, 22],
		defined($sym_shared) ? undef : $MULTI_LABEL);
	$this->{tag_sym} = Wx::StaticText->new($this, -1,
		_tagText($sym_shared, $n_wp), [$tag_x, $y + 4], [$TAG_W, 20]);

	$this->{_sym_multi_offset} = defined($sym_shared) ? 0 : 1;

	if (defined $sym_shared)
	{
		my $offset = $this->{_sym_multi_offset};
		$this->{cho_sym}->SetSelection(($sym_shared + 0) + $offset);
	}
	else
	{
		$this->{cho_sym}->SetSelection(0);
	}
	EVT_COMBOBOX($this, $this->{cho_sym},
		sub { $_[0]->{_sym_dirty} = 1 });
}


#---------------------------------
# Color event handlers
#---------------------------------

sub _onColorChoiceAbgr
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
		_setSwatchAbgr($this->{swatch_color}, $this->{_color_value});
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
		_setSwatchAbgr($this->{swatch_color}, $new_abgr);
		my $custom_idx = $this->{_color_multi_offset} + scalar(@E80_ROUTE_COLOR_NAMES);
		$this->{cho_color}->SetSelection($custom_idx);
	}
	$dlg->Destroy();
}


sub _onColorChoicePalette
{
	my ($this, $event) = @_;
	my $sel    = $this->{cho_color}->GetSelection();
	my $offset = $this->{_color_multi_offset};
	if ($offset && $sel == 0)
	{
		$this->{_color_dirty} = 0;
		_greySwatch($this->{swatch_color});
		return;
	}
	my $idx = $sel - $offset;
	if ($idx >= 0 && $idx < scalar(@E80_ROUTE_COLOR_NAMES))
	{
		$this->{_color_value} = $idx;
		$this->{_color_dirty} = 1;
		_setSwatchIndex($this->{swatch_color}, $idx);
	}
}


#---------------------------------
# OK
#---------------------------------

sub _onOK
{
	my ($this, $event) = @_;

	# ----- Comment (validate first so length-reject leaves dialog open)
	my $comment_new;
	my $comment_dirty = 0;
	if ($this->{txt_comment} && $this->{_comment_dirty})
	{
		my $txt = $this->{txt_comment}->GetValue();
		if (!defined $this->{_comment_orig_shared})
		{
			# multi case: untouched placeholder == no change
			if ($txt ne $this->{_comment_orig_text})
			{
				$comment_new = $txt;
				$comment_dirty = 1;
			}
		}
		else
		{
			$comment_new = $txt;
			$comment_dirty = 1;
		}

		if ($comment_dirty
			&& defined $this->{_comment_max}
			&& length($comment_new) > $this->{_comment_max})
		{
			Wx::MessageBox(
				"Comment is " . length($comment_new) . " chars; limit is "
				. $this->{_comment_max} . ".",
				"Comment too long",
				wxOK | wxICON_ERROR, $this);
			return;
		}
	}

	# ----- Color
	my $color_new;
	$color_new = $this->{_color_value} if $this->{_color_dirty};

	# ----- wp_type
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

	# ----- sym
	my $sym_new;
	if ($this->{cho_sym} && $this->{_sym_dirty})
	{
		my $sel    = $this->{cho_sym}->GetSelection();
		my $offset = $this->{_sym_multi_offset};
		if (!$offset || $sel > 0)
		{
			$sym_new = $sel - $offset;
		}
	}

	if (!defined($color_new)
		&& !defined($comment_new)
		&& !defined($wp_type_new)
		&& !defined($sym_new))
	{
		# nothing dirty -- treat as cancel
		$this->EndModal(wxID_CANCEL);
		return;
	}

	my %changes;
	$changes{color}   = $color_new   if defined $color_new;
	$changes{comment} = $comment_new if defined $comment_new;
	$changes{wp_type} = $wp_type_new if defined $wp_type_new;
	$changes{sym}     = $sym_new     if defined $sym_new;

	my $commit = $this->{descriptor}->{commit};
	if (ref($commit) ne 'CODE')
	{
		warning(0, 0, "winMultiEditor: descriptor has no commit callback");
		$this->EndModal(wxID_CANCEL);
		return;
	}

	my $touched = $commit->($this->{items}, \%changes);
	if (!ref($touched) || ref($touched) ne 'ARRAY')
	{
		$this->EndModal(wxID_CANCEL);
		return;
	}

	$this->{_committed_uuids} = $touched;
	$this->EndModal(wxID_OK);
}


1;
