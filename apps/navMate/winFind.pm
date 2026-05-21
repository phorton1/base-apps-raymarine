#!/usr/bin/perl
#------------------------------------------
# winFind.pm
#------------------------------------------
# Modeless "Find similar to this" window.
#
# Triggered by right-click "Find This..." on a waypoint/track/route node
# in winDatabase / winFSH / winE80.  Searches all three sources for items
# whose geographic bounding box overlaps the subject's bbox, scores each
# candidate via navMatch, and presents a sortable list.
#
# Per-row interactions:
#   - Visibility checkbox    -- drives navVisibility for that source:uuid
#                               (and through the observer pattern, updates
#                               the source pane's tree checkbox + the
#                               leaflet feature in one motion)
#   - Click on candidate name -- focusOnObject in the source pane (no
#                                visibility change, no leaflet zoom)
#   - Color swatch click      -- editable per source-asymmetry rules:
#                                  DB: arbitrary AABBGGRR (wxColourDialog)
#                                  FSH track/route: enumerated palette picker
#                                  FSH waypoint: no swatch (no color)
#                                  E80: read-only swatch
#   - Refresh button          -- re-runs the matcher with current settings,
#                                re-reads candidate state from sources.
#                                Use when you suspect color / name has been
#                                edited elsewhere (no mutation observer).
#
# winFind registers a visibility observer to keep its row checkboxes in
# sync with toggles made elsewhere (tree panes, editor checkbox).  It
# does NOT register a mutation observer -- the Refresh button is the
# remedy for color/name drift, by design.
#
# Lifetime: one winFind window at a time per app.  A new "Find This..."
# invocation closes the existing window and opens a fresh one.
#
# Post-MVP growth (see memory winfind_future_items.md):
#   - per-row right-click context menu with enrichment actions
#   - matcher option toolbar (exact only / allow lat_shift / ...)
#   - score-banded row colors

package winFind;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_BUTTON
	EVT_CHECKBOX
	EVT_LEFT_DOWN
	EVT_RIGHT_DOWN
	EVT_MENU
	EVT_CLOSE
	EVT_SIZE
);
use Pub::Utils qw(display warning error);
use n_defs;
use n_utils;
use nmResources;
use navVisibility;
use navMatch;
use navEnrich;
use navServer qw(addRenderFeatures removeRenderFeatures);
use navDB;
use navFSH;
use base 'Wx::Frame';


my $current_window;   # one-at-a-time tracker


#---------------------------------
# entry point
#---------------------------------
# Called from each pane's "Find This..." context menu handler with the
# selected subject's data.  Closes any existing winFind, opens a fresh
# one for the new subject.

sub openForSubject
{
	my (%args) = @_;
	# Required: frame, source, uuid, obj_type, name, bbox
	# For tracks/routes: points
	# For waypoints: lat, lon

	if ($current_window)
	{
		eval { $current_window->Close(1) };
		$current_window = undef;
	}

	my $w = winFind->new(\%args);
	$current_window = $w;
	$w->Show(1);
	return $w;
}


#---------------------------------
# constructor
#---------------------------------

sub new
{
	my ($class, $args) = @_;
	my $frame  = $args->{frame};
	my $title  = sprintf('Find: %s [%s %s]',
		$args->{name} // '(unnamed)',
		uc($args->{source} // ''),
		$args->{obj_type} // '');

	my $this = $class->SUPER::new($frame, -1, $title,
		wxDefaultPosition, [1000, 600],
		wxDEFAULT_FRAME_STYLE | wxFRAME_FLOAT_ON_PARENT);

	$this->{_subject}    = $args;
	$this->{_frame}      = $frame;
	$this->{_row_widgets} = {};   # key "source:uuid" -> { checkbox, swatch_panel, ... }

	# Top-level panel with vertical layout
	my $panel = Wx::Panel->new($this, -1);
	$this->{_panel} = $panel;
	my $vbox = Wx::BoxSizer->new(wxVERTICAL);

	# --- Subject summary line(s) ---
	my $subj_box = Wx::StaticBox->new($panel, -1, 'Subject');
	my $subj_sizer = Wx::StaticBoxSizer->new($subj_box, wxVERTICAL);
	my $subj_text = sprintf("%s  --  %s\nsource: %s  type: %s  npts: %d",
		$args->{name} // '(unnamed)',
		$args->{hierarchy_path} // '',
		uc($args->{source} // ''),
		$args->{obj_type} // '',
		$args->{npts} // ($args->{points} ? scalar @{$args->{points}} : 1));
	$subj_sizer->Add(Wx::StaticText->new($panel, -1, $subj_text), 0, wxALL, 4);
	$vbox->Add($subj_sizer, 0, wxALL | wxEXPAND, 4);

	# --- Toolbar row ---
	my $tb = Wx::BoxSizer->new(wxHORIZONTAL);
	$this->{_refresh_btn} = Wx::Button->new($panel, -1, 'Refresh');
	$this->{_close_btn}   = Wx::Button->new($panel, -1, 'Close');
	$tb->Add($this->{_refresh_btn}, 0, wxALL, 4);
	$tb->Add($this->{_close_btn},   0, wxALL, 4);
	$tb->AddStretchSpacer(1);
	$this->{_status_text} = Wx::StaticText->new($panel, -1, '');
	$tb->Add($this->{_status_text}, 0, wxALIGN_CENTER_VERTICAL | wxRIGHT, 8);
	$vbox->Add($tb, 0, wxEXPAND);

	# --- Column header row (fixed) ---
	my $hdr_panel = Wx::Panel->new($panel, -1);
	$hdr_panel->SetBackgroundColour(Wx::Colour->new(220, 220, 220));
	my $hbox = Wx::BoxSizer->new(wxHORIZONTAL);
	_addHeaderCell($hdr_panel, $hbox, 'Vis',     34);
	_addHeaderCell($hdr_panel, $hbox, 'Color',   34);
	_addHeaderCell($hdr_panel, $hbox, 'Src',     40);
	_addHeaderCell($hdr_panel, $hbox, 'Tier',    40);
	_addHeaderCell($hdr_panel, $hbox, 'Shape',   65);
	_addHeaderCell($hdr_panel, $hbox, 'Subj%',   45);
	_addHeaderCell($hdr_panel, $hbox, 'Cand%',   45);
	_addHeaderCell($hdr_panel, $hbox, 'Qual',    40);
	_addHeaderCell($hdr_panel, $hbox, 'npts',    50);
	_addHeaderCell($hdr_panel, $hbox, 'Path',    300);
	_addHeaderCell($hdr_panel, $hbox, 'Name',    300);
	$hdr_panel->SetSizer($hbox);
	$vbox->Add($hdr_panel, 0, wxEXPAND);

	# --- Scrolled candidate list ---
	$this->{_list_scroll} = Wx::ScrolledWindow->new($panel, -1,
		wxDefaultPosition, wxDefaultSize, wxVSCROLL);
	$this->{_list_scroll}->SetScrollRate(0, 18);
	$this->{_list_sizer} = Wx::BoxSizer->new(wxVERTICAL);
	$this->{_list_scroll}->SetSizer($this->{_list_sizer});
	$vbox->Add($this->{_list_scroll}, 1, wxEXPAND);

	$panel->SetSizer($vbox);

	EVT_BUTTON($this, $this->{_refresh_btn}, sub { $this->_doRefresh() });
	EVT_BUTTON($this, $this->{_close_btn},   sub { $this->Close(1)      });
	EVT_CLOSE ($this, sub { $this->_onClose($_[1]) });

	# Visibility observer.  Keeps row checkboxes in sync with toggles
	# coming from tree panes, editor checkboxes, or other agents.
	$this->{_vis_observer_alive} = 1;
	$this->{_vis_observer} = navVisibility::addVisibilityObserver(sub {
		my ($delta) = @_;
		return if !$this->{_vis_observer_alive};
		$this->_onVisibilityDelta($delta);
	});

	$this->_doRefresh();

	return $this;
}


sub _onClose
{
	my ($this, $event) = @_;
	$this->{_vis_observer_alive} = 0;
	if ($this->{_vis_observer})
	{
		navVisibility::removeVisibilityObserver($this->{_vis_observer});
		$this->{_vis_observer} = undef;
	}
	$current_window = undef if $current_window && $current_window == $this;
	$event->Skip();
}


sub _addHeaderCell
{
	my ($parent, $sizer, $label, $width) = @_;
	my $t = Wx::StaticText->new($parent, -1, $label,
		wxDefaultPosition, [$width, -1]);
	my $f = $t->GetFont();
	$f->SetWeight(wxFONTWEIGHT_BOLD);
	$t->SetFont($f);
	$sizer->Add($t, 0, wxLEFT | wxRIGHT | wxALIGN_CENTER_VERTICAL, 2);
}


#---------------------------------
# refresh: enumerate + score + repopulate
#---------------------------------

sub _doRefresh
{
	my ($this) = @_;
	my $args = $this->{_subject};
	my $obj_type = $args->{obj_type} // '';

	# Reset navMatch's per-Find PP/C divergence-modal counter and the
	# cumulative timing accumulators.  No-op when COMPARE_MODE != 'both'.
	navMatch::resetDivergence();

	# Modeless busy info window auto-destroys when the lexical goes out of
	# scope at end of sub.  Tells the user the matcher is working so the
	# several-second response doesn't feel like a hung app.
	my $busy = Wx::BusyInfo->new('Finding similar items...');

	$this->{_status_text}->SetLabel('Searching...');
	$this->{_panel}->Layout();

	# Subject bbox -- needed for prefilter.  For tracks/routes, compute from
	# points; for waypoints, derive single-point bbox.
	my $subj_bbox = $args->{bbox};
	if (!$subj_bbox)
	{
		if ($obj_type eq 'waypoint')
		{
			my $lat = $args->{lat} + 0;
			my $lon = $args->{lon} + 0;
			$subj_bbox = { min_lat => $lat, max_lat => $lat,
			               min_lon => $lon, max_lon => $lon };
		}
		elsif ($args->{points})
		{
			$subj_bbox = navMatch::bboxOfPoints($args->{points});
		}
	}

	# Populate has_depth/has_temp_k/has_ts on subject so it can be used as a
	# candidate-shaped hash by navEnrich.  Subject is the originating item
	# (passed to openForSubject) -- not enumerated, so these flags aren't
	# otherwise on it.  Source-specific point-field names; matches what the
	# enumerators do.
	_populateSubjectHasFlags($args);

	# Enumerate from all three sources.  Each enumerator handles its own
	# bbox prefilter; we still pass the inflated bbox so the candidate set
	# is reasonable.
	my @all;
	eval {
		push @all, @{navMatch::enumerateDbCandidates($obj_type, $subj_bbox)};
	};
	warning(0,0,"enumerateDbCandidates: $@") if $@;
	eval {
		push @all, @{navMatch::enumerateFshCandidates($obj_type, $subj_bbox)};
	};
	warning(0,0,"enumerateFshCandidates: $@") if $@;
	eval {
		push @all, @{navMatch::enumerateE80Candidates($obj_type, $subj_bbox)};
	};
	warning(0,0,"enumerateE80Candidates: $@") if $@;

	# Score each candidate.  Skip the subject itself.
	my $subj_src  = $args->{source} // '';
	my $subj_uuid = $args->{uuid}   // '';
	my @scored;
	for my $cand (@all)
	{
		next if $cand->{source} eq $subj_src && $cand->{uuid} eq $subj_uuid;
		my $result;
		if ($obj_type eq 'waypoint')
		{
			$result = navMatch::scoreWaypointPair(
				$args->{lat} + 0, $args->{lon} + 0,
				$cand->{lat} + 0, $cand->{lon} + 0);
		}
		else
		{
			$result = navMatch::scoreLineStringPair($args->{points}, $cand->{points});
		}
		next if !$result->{tier} || $result->{tier} eq 'none';
		# Filter near-tier results by COVERAGE, not quality.  Genuine
		# same-trip-different-device matches have low quality (GPS
		# noise > EXACT_DEG everywhere) but high coverage (the whole
		# trip aligned end-to-end on both sides) -- we want to see
		# those.  Geographic-accident matches have low coverage on
		# both sides -- those are noise.  Filter only when BOTH sides
		# show < 10% coverage; if either side has substantial coverage
		# (subset/superset relationship), surface the row.
		if ($result->{tier} eq 'near')
		{
			my $best_cov = ($result->{subj_coverage} // 0);
			$best_cov = $result->{cand_coverage}
				if ($result->{cand_coverage} // 0) > $best_cov;
			next if $best_cov < 0.10;
		}
		$cand->{_match} = $result;
		push @scored, $cand;
	}

	# Cumulative PP-vs-C timing for the whole Find op.  Silent unless
	# COMPARE_MODE = 'both'.  Single log line, not per-pair.
	navMatch::reportCompareTiming();

	# Sort: tier rank descending (exact > match > near), then by quality
	# within match/near, then by coverage extent.  EXACT ties broken by
	# matched-run length (longer = more substantial).
	@scored = sort {
		_sortKey($b->{_match}) <=> _sortKey($a->{_match})
	} @scored;

	$this->_populate(\@scored);
	$this->{_status_text}->SetLabel(scalar(@scored) . ' candidate(s)');
}


sub _populate
{
	my ($this, $candidates) = @_;

	$this->{_list_scroll}->Freeze();
	eval {
		# Tear down existing rows
		$this->{_list_sizer}->Clear(1);   # destroy children
		$this->{_row_widgets} = {};

		for my $cand (@$candidates)
		{
			$this->_addRow($cand);
		}

		$this->{_list_scroll}->FitInside();
		$this->{_list_scroll}->Layout();
	};
	my $err = $@;
	$this->{_list_scroll}->Thaw();
	error("winFind::_populate: $err") if $err;
}


sub _addRow
{
	my ($this, $cand) = @_;
	my $scroll = $this->{_list_scroll};

	my $row = Wx::Panel->new($scroll, -1);
	my $hbox = Wx::BoxSizer->new(wxHORIZONTAL);

	my $source = $cand->{source};
	my $uuid   = $cand->{uuid};
	my $key    = "$source:$uuid";

	# Visibility checkbox
	my $cb = Wx::CheckBox->new($row, -1, '',
		wxDefaultPosition, [28, -1]);
	$cb->SetValue(_isVisible($source, $uuid) ? 1 : 0);
	EVT_CHECKBOX($this, $cb, sub { $this->_onVisToggle($cand, $cb) });
	$hbox->Add($cb, 0, wxLEFT | wxRIGHT | wxALIGN_CENTER_VERTICAL, 4);

	# Color swatch.  Suppressed for FSH/E80 waypoints (no color in those
	# storage models); shown read-only for E80 tracks/routes; editable
	# for DB anything and FSH tracks/routes.
	my $swatch_w = 28;
	if (_sourceHasColorFor($source, $cand->{obj_type}))
	{
		my $swatch = Wx::Panel->new($row, -1,
			wxDefaultPosition, [$swatch_w, 16], wxSIMPLE_BORDER);
		_paintSwatch($swatch, $source, $cand);
		if (_sourceColorEditable($source, $cand->{obj_type}))
		{
			EVT_LEFT_DOWN($swatch, sub { $this->_onColorPick($cand, $swatch); });
		}
		$hbox->Add($swatch, 0, wxLEFT | wxRIGHT | wxALIGN_CENTER_VERTICAL, 2);
		$this->{_row_widgets}{$key}{swatch} = $swatch;
	}
	else
	{
		# placeholder to keep column alignment
		$hbox->Add(Wx::Panel->new($row, -1,
			wxDefaultPosition, [$swatch_w, 16]), 0,
			wxLEFT | wxRIGHT | wxALIGN_CENTER_VERTICAL, 2);
	}

	# Source label
	$hbox->Add(Wx::StaticText->new($row, -1, uc($source),
		wxDefaultPosition, [40, -1]),
		0, wxLEFT | wxRIGHT | wxALIGN_CENTER_VERTICAL, 2);

	# Five fields from the scorer:
	#   Tier   -- exact / match / near
	#   Shape  -- full / subset / superset / trimmed / partial / anomaly
	#             (blank when shape == 'full' so the eye reads bare tier)
	#   Subj % -- fraction of subject's path inside the matched window
	#   Cand % -- fraction of candidate's path inside the matched window
	#   Qual % -- fraction of matched cells aligned at coord precision
	#             (blank for EXACT -- always 100% by construction)
	my $m = $cand->{_match};
	my $tier  = $m->{tier}  // '';
	my $shape = ($m->{shape} && $m->{shape} ne 'full') ? $m->{shape} : '';
	my $subj_pct = sprintf('%.0f%%', ($m->{subj_coverage} // 0) * 100);
	my $cand_pct = sprintf('%.0f%%', ($m->{cand_coverage} // 0) * 100);
	my $qual = ($tier eq 'exact' || !defined $m->{quality})
		? ''
		: sprintf('%.0f%%', $m->{quality} * 100);

	# Enrichable indicator: canEnrich is cheap (flag/tier check only, no
	# point walking).  When it returns at least one possible direction
	# for this row, draw Tier and Shape blue-bold as a hint.  False
	# positives are possible -- the right-click menu is the real decision.
	my $enr = navEnrich::canEnrich($this->{_subject}, $cand, $m);
	my $is_enrichable = ($enr && @$enr) ? 1 : 0;

	my $tier_text  = Wx::StaticText->new($row, -1, $tier,
		wxDefaultPosition, [40, -1]);
	my $shape_text = Wx::StaticText->new($row, -1, $shape,
		wxDefaultPosition, [65, -1]);
	if ($is_enrichable)
	{
		my $blue = Wx::Colour->new(0, 0, 192);
		for my $t ($tier_text, $shape_text)
		{
			$t->SetForegroundColour($blue);
			my $f = $t->GetFont();
			$f->SetWeight(wxFONTWEIGHT_BOLD);
			$t->SetFont($f);
		}
	}
	$hbox->Add($tier_text,
		0, wxLEFT | wxRIGHT | wxALIGN_CENTER_VERTICAL, 2);
	$hbox->Add($shape_text,
		0, wxLEFT | wxRIGHT | wxALIGN_CENTER_VERTICAL, 2);
	$hbox->Add(Wx::StaticText->new($row, -1, $subj_pct,
		wxDefaultPosition, [45, -1]),
		0, wxLEFT | wxRIGHT | wxALIGN_CENTER_VERTICAL, 2);
	$hbox->Add(Wx::StaticText->new($row, -1, $cand_pct,
		wxDefaultPosition, [45, -1]),
		0, wxLEFT | wxRIGHT | wxALIGN_CENTER_VERTICAL, 2);
	$hbox->Add(Wx::StaticText->new($row, -1, $qual,
		wxDefaultPosition, [40, -1]),
		0, wxLEFT | wxRIGHT | wxALIGN_CENTER_VERTICAL, 2);

	# npts
	$hbox->Add(Wx::StaticText->new($row, -1, ($cand->{npts} // 1) . '',
		wxDefaultPosition, [50, -1]),
		0, wxLEFT | wxRIGHT | wxALIGN_CENTER_VERTICAL, 2);

	# Path (truncate if too long)
	my $path = $cand->{hierarchy_path} // '';
	$hbox->Add(Wx::StaticText->new($row, -1, $path,
		wxDefaultPosition, [300, -1]),
		0, wxLEFT | wxRIGHT | wxALIGN_CENTER_VERTICAL, 2);

	# Name (clickable -> navigate)
	my $name_text = Wx::StaticText->new($row, -1, $cand->{name} // '',
		wxDefaultPosition, [300, -1]);
	my $f = $name_text->GetFont();
	$f->SetUnderlined(1);
	$name_text->SetFont($f);
	$name_text->SetForegroundColour(Wx::Colour->new(0, 0, 192));
	$name_text->SetCursor(Wx::Cursor->new(wxCURSOR_HAND));
	EVT_LEFT_DOWN($name_text, sub { $this->_onNameClick($cand); });
	$hbox->Add($name_text, 1, wxLEFT | wxRIGHT | wxALIGN_CENTER_VERTICAL, 2);

	$row->SetSizer($hbox);
	$this->{_list_sizer}->Add($row, 0, wxEXPAND | wxBOTTOM, 1);

	# Right-click anywhere in the row opens the enrichment context menu.
	# EVT_RIGHT_DOWN does not propagate from child widgets to the parent
	# panel in wx, so bind on the row panel AND on every child window
	# (static texts, swatch panel, checkbox, etc.).  Each binding shares
	# the same handler closure.
	my $rclick = sub { $this->_onRowRightDown($cand); };
	EVT_RIGHT_DOWN($row, $rclick);
	for my $child ($row->GetChildren())
	{
		EVT_RIGHT_DOWN($child, $rclick);
	}

	$this->{_row_widgets}{$key}{checkbox} = $cb;
	$this->{_row_widgets}{$key}{cand}     = $cand;
}


#---------------------------------
# helpers: label split, visibility lookup, color asymmetry, swatch paint
#---------------------------------

sub _sortKey
{
	# Compute a single numeric sort key from a match result.  Higher =
	# better.  Encodes:
	#   1. tier rank (exact > match > near) -- primary axis
	#   2. max(subj_coverage, cand_coverage) -- the load-bearing
	#      coverage number, since either side hitting 100% means an
	#      important relationship (full / subset / superset)
	#   3. quality as a tiebreaker for match/near
	#
	# Returns a number in a band per tier so cross-tier ordering is
	# stable regardless of within-tier ties.
	my ($r) = @_;
	return -1 if !$r || !$r->{tier} || $r->{tier} eq 'none';

	my $tier_base = 0;
	if    ($r->{tier} eq 'exact') { $tier_base = 30 }
	elsif ($r->{tier} eq 'match') { $tier_base = 20 }
	else                          { $tier_base = 10 }   # near

	# Higher of the two coverages -- scaled into [0, 0.99) so it can't
	# cross tier boundaries.
	my $best_cov = ($r->{subj_coverage} // 0);
	$best_cov = $r->{cand_coverage}
		if ($r->{cand_coverage} // 0) > $best_cov;
	my $cov_score = $best_cov * 0.99;

	# Quality refinement.  Tiny scale -- only enough to break exact
	# coverage ties within a tier.
	my $qual = (defined $r->{quality}) ? $r->{quality} * 0.001 : 0;

	return $tier_base + $cov_score + $qual;
}


sub _isVisible
{
	my ($source, $uuid) = @_;
	if    ($source eq 'db')  { return navVisibility::getDbVisible($uuid)  }
	elsif ($source eq 'e80') { return navVisibility::getE80Visible($uuid) }
	elsif ($source eq 'fsh') { return navVisibility::getFSHVisible($uuid) }
	return 0;
}


sub _sourceHasColorFor
{
	my ($source, $obj_type) = @_;
	# DB: all three types have color
	# FSH: tracks and routes only (waypoints have no color in FSH)
	# E80: tracks and routes only (waypoints have no color in E80)
	return 1 if $source eq 'db';
	return 0 if $obj_type eq 'waypoint';
	return 1;   # fsh/e80 track or route
}


sub _sourceColorEditable
{
	my ($source, $obj_type) = @_;
	return 1 if $source eq 'db';
	return 1 if $source eq 'fsh';   # any FSH non-waypoint
	return 0;                        # E80 not editable
}


sub _paintSwatch
{
	my ($swatch, $source, $cand) = @_;
	my $abgr = _resolveColorABGR($source, $cand);
	my ($rr, $gg, $bb) = (192, 192, 192);
	if (defined($abgr) && $abgr =~ /^[0-9a-fA-F]{8}$/)
	{
		$rr = hex(substr($abgr, 6, 2));
		$gg = hex(substr($abgr, 4, 2));
		$bb = hex(substr($abgr, 2, 2));
	}
	$swatch->SetBackgroundColour(Wx::Colour->new($rr, $gg, $bb));
	$swatch->Refresh();
}


sub _resolveColorABGR
{
	my ($source, $cand) = @_;
	if ($source eq 'db')
	{
		return $cand->{color_value};   # already AABBGGRR
	}
	# FSH and E80: color_value is an index into E80_ROUTE_COLOR_ABGR
	my $idx = $cand->{color_value};
	return undef if !defined $idx;
	return $E80_ROUTE_COLOR_ABGR[$idx + 0] // 'FF888888';
}


#---------------------------------
# event: visibility toggle
#---------------------------------

sub _onVisToggle
{
	my ($this, $cand, $cb) = @_;
	my $new = $cb->GetValue() ? 1 : 0;
	my $source = $cand->{source};
	my $uuid   = $cand->{uuid};

	# Update visibility store.  The observer notification will fire back
	# into our own _onVisibilityDelta, which idempotently re-sets this
	# checkbox (a no-op since we just set it).  Also updates other panes.
	if    ($source eq 'db')  { navVisibility::setDbVisible($uuid,  $new) }
	elsif ($source eq 'e80') { navVisibility::setE80Visible($uuid, $new) }
	elsif ($source eq 'fsh') { navVisibility::setFSHVisible($uuid, $new) }

	# Drive the leaflet directly -- the visibility observer notifies
	# widgets, but it does not push/pull features.  That's the caller's
	# job and there is no central "push from visibility flag" service
	# (the existing tree-pane code does this in line with its toggle).
	if ($new)
	{
		my $feature = _buildFeatureForLeaflet($source, $cand);
		addRenderFeatures([$feature]) if $feature;
	}
	else
	{
		removeRenderFeatures($source, [$uuid]);
	}
}


sub _buildFeatureForLeaflet
{
	my ($source, $cand) = @_;
	my $obj_type = $cand->{obj_type};
	my $color_abgr = _resolveColorABGR($source, $cand) // 'FF888888';

	if ($obj_type eq 'waypoint')
	{
		return {
			type       => 'Feature',
			properties => {
				uuid        => $cand->{uuid},
				name        => $cand->{name} // '',
				obj_type    => 'waypoint',
				data_source => $source,
				wp_type     => $cand->{wp_type} // $WP_TYPE_NAV,
				color       => $color_abgr,
				lat         => $cand->{lat} + 0,
				lon         => $cand->{lon} + 0,
			},
			geometry => { type => 'Point',
				coordinates => [$cand->{lon} + 0, $cand->{lat} + 0] },
		};
	}
	elsif ($obj_type eq 'track')
	{
		my $pts = $cand->{points} // [];
		return undef if !@$pts;
		return {
			type       => 'Feature',
			properties => {
				uuid        => $cand->{uuid},
				name        => $cand->{name} // '',
				obj_type    => 'track',
				data_source => $source,
				color       => $color_abgr,
				point_count => scalar(@$pts) + 0,
			},
			geometry => { type => 'LineString',
				coordinates => [map { [($_->{lon}//0)+0, ($_->{lat}//0)+0] } @$pts] },
		};
	}
	elsif ($obj_type eq 'route')
	{
		my $pts = $cand->{points} // [];
		return undef if !@$pts;
		return {
			type       => 'Feature',
			properties => {
				uuid        => $cand->{uuid},
				name        => $cand->{name} // '',
				obj_type    => 'route',
				data_source => $source,
				color       => $color_abgr,
				wp_count    => scalar(@$pts) + 0,
			},
			geometry => { type => 'LineString',
				coordinates => [map { [($_->{lon}//0)+0, ($_->{lat}//0)+0] } @$pts] },
		};
	}
	return undef;
}


#---------------------------------
# event: name click -> focus pane
#---------------------------------

sub _onNameClick
{
	my ($this, $cand) = @_;
	my $frame = $this->{_frame};
	return if !$frame;

	my $pane_id = $cand->{source} eq 'db'  ? $WIN_DATABASE
	            : $cand->{source} eq 'e80' ? $WIN_E80
	            : $cand->{source} eq 'fsh' ? $WIN_FSH
	            :                            undef;
	return if !$pane_id;

	my $pane = $frame->findPane($pane_id);
	return if !$pane;
	if ($pane->can('focusOnObject'))
	{
		$pane->focusOnObject($cand->{uuid}, $cand->{obj_type});
	}
}


#---------------------------------
# event: color pick
#---------------------------------

sub _onColorPick
{
	my ($this, $cand, $swatch) = @_;
	my $source = $cand->{source};
	my $obj_type = $cand->{obj_type};
	my $uuid     = $cand->{uuid};

	if ($source eq 'db')
	{
		$this->_pickDbColor($cand, $swatch);
	}
	elsif ($source eq 'fsh')
	{
		$this->_pickFshColor($cand, $swatch);
	}
	# E80: no-op; not editable.
}


sub _pickDbColor
{
	my ($this, $cand, $swatch) = @_;
	my $current = $cand->{color_value} // 'FF0000FF';
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
		$cand->{color_value} = $new_abgr;
		_paintSwatch($swatch, 'db', $cand);

		my $table = $cand->{obj_type} eq 'waypoint' ? 'waypoints'
		          : $cand->{obj_type} eq 'route'    ? 'routes'
		          :                                    'tracks';
		my $dbh = connectDB();
		if ($dbh)
		{
			$dbh->do("UPDATE $table SET color=? WHERE uuid=?",
				[$new_abgr, $cand->{uuid}]);
			disconnectDB($dbh);
		}

		# If visible, refresh on leaflet.
		if (_isVisible('db', $cand->{uuid}))
		{
			removeRenderFeatures('db', [$cand->{uuid}]);
			my $feature = _buildFeatureForLeaflet('db', $cand);
			addRenderFeatures([$feature]) if $feature;
		}
	}
	$dlg->Destroy();
}


sub _pickFshColor
{
	my ($this, $cand, $swatch) = @_;
	my $cur = $cand->{color_value} // 0;
	my @choices = @E80_ROUTE_COLOR_NAMES;

	my $dlg = Wx::SingleChoiceDialog->new($this,
		'Pick color', 'FSH Color', \@choices);
	$dlg->SetSelection($cur);
	if ($dlg->ShowModal() == wxID_OK)
	{
		my $idx = $dlg->GetSelection();
		$cand->{color_value} = $idx;
		_paintSwatch($swatch, 'fsh', $cand);

		# Mutate the in-memory FSH record.
		my $db = $navFSH::fsh_db;
		if ($db)
		{
			my $rec;
			if ($cand->{obj_type} eq 'track')
			{
				$rec = $db->{tracks}{$cand->{uuid}};
			}
			elsif ($cand->{obj_type} eq 'route')
			{
				$rec = $db->{routes}{$cand->{uuid}};
			}
			if ($rec)
			{
				$rec->{color} = $idx;
				navFSH::markDirty();
			}
		}

		# If visible, refresh on leaflet.
		if (_isVisible('fsh', $cand->{uuid}))
		{
			removeRenderFeatures('fsh', [$cand->{uuid}]);
			my $feature = _buildFeatureForLeaflet('fsh', $cand);
			addRenderFeatures([$feature]) if $feature;
		}
	}
	$dlg->Destroy();
}


#---------------------------------
# observer: cross-source visibility changes
#---------------------------------

sub _onVisibilityDelta
{
	my ($this, $delta) = @_;
	for my $source (keys %$delta)
	{
		my $changes = $delta->{$source};
		for my $uuid (keys %$changes)
		{
			my $key = "$source:$uuid";
			my $w = $this->{_row_widgets}{$key};
			next if !$w || !$w->{checkbox};
			$w->{checkbox}->SetValue($changes->{$uuid} ? 1 : 0);
		}
	}
}


#---------------------------------
# subject has_* flag population
#---------------------------------

sub _populateSubjectHasFlags
{
	# Source-specific point field names (mirrors what the enumerators do):
	#   DB    -- depth_cm, temp_k, ts
	#   FSH   -- depth,    temp_k, (no per-point ts)
	#   E80   -- depth,    temp_k, (no per-point ts)
	# Sentinel: temp_k == 65535 is "no reading" for FSH/E80.
	my ($args) = @_;
	my $pts = $args->{points} // [];
	my $src = $args->{source} // '';

	# Single-point objects (waypoints) read scalar fields from $args directly.
	# Track/route iterates points.
	my $depth_key = ($src eq 'db') ? 'depth_cm' : 'depth';
	my $temp_key  = 'temp_k';
	my $ts_key    = 'ts';

	my $has_depth = 0;
	my $has_temp  = 0;
	my $has_ts    = 0;

	if (@$pts)
	{
		for my $p (@$pts)
		{
			$has_depth = 1 if ($p->{$depth_key} // 0) > 0;
			my $tk = $p->{$temp_key} // 0;
			$has_temp  = 1 if ($tk > 0 && $tk != 65535);
			$has_ts    = 1 if $p->{$ts_key};
			last if $has_depth && $has_temp && $has_ts;
		}
	}
	else
	{
		# Waypoint subject: depth/temp on $args directly.
		my $d = $args->{$depth_key} // $args->{depth} // 0;
		my $t = $args->{temp_key}   // 0;
		$has_depth = 1 if $d > 0;
		$has_temp  = 1 if ($t > 0 && $t != 65535);
		$has_ts    = 1 if $args->{created_ts};
	}

	$args->{has_depth}  = $has_depth;
	$args->{has_temp_k} = $has_temp;
	$args->{has_ts}     = $has_ts;
}


#---------------------------------
# right-click row -> enrichment menu
#---------------------------------

sub _onRowRightDown
{
	my ($this, $cand) = @_;

	# Build candidate items from navEnrich (cheap; uses has_* flags only).
	my $subj  = $this->{_subject};
	my $items = navEnrich::canEnrich($subj, $cand, $cand->{_match}) // [];
	return if !@$items;

	# Per-field plan to get counts; skip items with no actionable changes.
	my $menu = Wx::Menu->new();
	my $any  = 0;
	for my $item (@$items)
	{
		my $plan = navEnrich::planEnrichment(
			$subj, $cand, $cand->{_match},
			$item->{field}, $item->{direction});
		next if !$plan;
		my $cnt = $plan->{counts} // {};
		next if ($cnt->{enrich} + $cnt->{update}) == 0;

		my $id    = Wx::NewId();
		my $label = _enrichmentLabel($item, $plan, $cand);
		$menu->Append($id, $label);
		EVT_MENU($this, $id, sub { $this->_doEnrichment($cand, $plan); });
		$any++;
	}

	if (!$any)
	{
		$menu->Destroy();
		return;
	}

	$this->PopupMenu($menu, [-1, -1]);
	$menu->Destroy();
}


sub _enrichmentLabel
{
	my ($item, $plan, $cand) = @_;
	my $cnt = $plan->{counts};
	my $field_name = $item->{field} eq 'depth'  ? 'depth'
	               : $item->{field} eq 'temp_k' ? 'temp'
	               :                              $item->{field};

	# Direction word.  to_subj: this row is the SOURCE -- "from".
	#                  to_other: this row is the DESTINATION -- "to".
	my $dir_word = $item->{direction} eq 'to_subj' ? 'FROM' : 'TO';
	my $other_descr = uc($cand->{source} // '');

	my $verb;
	my $count_str;
	if ($cnt->{update} == 0)
	{
		$verb      = 'Enrich';
		$count_str = sprintf('%d pts', $cnt->{enrich});
	}
	elsif ($cnt->{enrich} == 0)
	{
		$verb      = 'Update';
		$count_str = sprintf('%d differ, %d agree', $cnt->{update}, $cnt->{agree});
	}
	else
	{
		$verb      = 'Enrich + update';
		$count_str = sprintf('%d fill, %d update', $cnt->{enrich}, $cnt->{update});
	}

	return sprintf('%s %s %s %s (%s)',
		$verb, $field_name, $dir_word, $other_descr, $count_str);
}


sub _doEnrichment
{
	my ($this, $cand, $plan) = @_;

	# Confirm dialog for update / hybrid / anomaly cases.  Pure enrich is
	# additive (only fills empty cells) and proceeds silently.
	my $cnt     = $plan->{counts};
	my $needs   = ($cnt->{update} > 0) || (($plan->{shape} // '') eq 'anomaly');
	if ($needs)
	{
		my $msg = _confirmMessage($plan);
		my $dlg = Wx::MessageDialog->new($this, $msg, 'Confirm enrichment',
			wxYES_NO | wxICON_QUESTION);
		my $rc  = $dlg->ShowModal();
		$dlg->Destroy();
		return if $rc != wxID_YES;
	}

	my ($ok, $err) = navEnrich::applyEnrichment($plan);
	if (!$ok)
	{
		error("winFind enrichment failed: " . ($err // 'unknown'));
		my $dlg = Wx::MessageDialog->new($this,
			"Enrichment failed:\n" . ($err // 'unknown'),
			'Enrichment failed', wxOK | wxICON_ERROR);
		$dlg->ShowModal();
		$dlg->Destroy();
		return;
	}

	# Cache coherency: update the in-memory points on whichever side was the
	# destination so subsequent right-clicks see the new state.  The DB has
	# already been authoritatively updated.
	_applyChangesToInMemoryPoints($this, $cand, $plan);

	# Refresh the cand's has_* flags for the destination side; the source
	# side flags are unchanged.  Match score and row layout don't change.
	if ($plan->{direction} eq 'to_subj')
	{
		_populateSubjectHasFlags($this->{_subject});
	}
	else
	{
		_recomputeCandHasFlags($cand);
	}

	# Destination is always the DB.  Tell the winDatabase pane to rebuild
	# so its tree/editor see the new track-point data.  Same pattern as
	# create/delete (navOpsDB::_refreshDatabaseWithDelete).
	my $frame = $this->{_frame};
	if ($frame)
	{
		my $db_pane = $frame->findPane($WIN_DATABASE);
		$db_pane->refresh() if $db_pane;
	}

	$this->{_status_text}->SetLabel(sprintf(
		'%s: %d points written', $plan->{field}, scalar @{$plan->{changes}}));
}


sub _confirmMessage
{
	my ($plan) = @_;
	my $cnt = $plan->{counts};
	my @lines;
	push @lines, sprintf("Enrich field: %s", $plan->{field});
	push @lines, sprintf("Source:       %s", $plan->{src_descr});
	push @lines, sprintf("Destination:  %s", $plan->{dst_descr});
	push @lines, '';
	push @lines, sprintf("Match tier:   %s",  $plan->{tier});
	push @lines, sprintf("Match shape:  %s",  $plan->{shape} // '');
	push @lines, '';
	push @lines, sprintf("Enrich (fill empty): %d", $cnt->{enrich});
	push @lines, sprintf("Update (overwrite):  %d", $cnt->{update});
	push @lines, sprintf("Agree (no change):   %d", $cnt->{agree});
	push @lines, sprintf("Skip  (no source):   %d", $cnt->{skip});

	if (($plan->{shape} // '') eq 'anomaly')
	{
		push @lines, '';
		push @lines, '*** MATCH ANOMALY: both tracks have non-trivial leftover. ***';
		push @lines, '*** Review the pair before applying.                     ***';
	}

	push @lines, '';
	push @lines, 'Proceed?';
	return join("\n", @lines);
}


sub _applyChangesToInMemoryPoints
{
	my ($this, $cand, $plan) = @_;
	# Pick whichever side is the DB destination.  For to_subj direction the
	# subject is destination; for to_other the cand is destination.
	my $dst_pts;
	if ($plan->{direction} eq 'to_subj')
	{
		$dst_pts = $this->{_subject}{points};
	}
	else
	{
		$dst_pts = $cand->{points};
	}
	return if !$dst_pts;

	# Destination is DB; DB column matches logical field via the same map
	# navEnrich uses.  Just resolve once here.
	my $col = $plan->{field} eq 'depth'  ? 'depth_cm'
	        : $plan->{field} eq 'temp_k' ? 'temp_k'
	        :                               $plan->{field};
	for my $c (@{$plan->{changes}})
	{
		my $p = $dst_pts->[$c->{position}];
		$p->{$col} = $c->{new_val} if $p;
	}
}


sub _recomputeCandHasFlags
{
	my ($cand) = @_;
	my $pts = $cand->{points} // [];
	my $depth_key = ($cand->{source} // '') eq 'db' ? 'depth_cm' : 'depth';
	my ($has_depth, $has_temp, $has_ts) = (0, 0, 0);
	for my $p (@$pts)
	{
		$has_depth = 1 if ($p->{$depth_key} // 0) > 0;
		my $tk = $p->{temp_k} // 0;
		$has_temp  = 1 if ($tk > 0 && $tk != 65535);
		$has_ts    = 1 if $p->{ts};
		last if $has_depth && $has_temp && $has_ts;
	}
	$cand->{has_depth}  = $has_depth;
	$cand->{has_temp_k} = $has_temp;
	$cand->{has_ts}     = $has_ts;
}


1;
