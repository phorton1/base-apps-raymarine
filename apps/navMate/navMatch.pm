#!/usr/bin/perl
#------------------------------------------
# navMatch.pm
#------------------------------------------
# Geographic similarity matching for tracks, routes, and waypoints.
# Pure data primitive -- no Wx, no DB calls; takes points in, returns
# scored relation labels.
#
# Used by:
#   - winFind     -- "Find This..." across all sources
#   - (post-MVP) per-row enrichment actions
#   - (post-MVP) other reconciliation / dedup workflows
#
# Scoring algorithm
# -----------------
# Cascade of two distinct algorithms answering two distinct questions:
#
#   Stage 1 -- EXACT pass: "do these two recordings share source data?"
#   Stage 2 -- DTW fallback: "do these recordings trace the same shape?"
#
# Stage 1 (_exactPass) is hash-based and runs on RAW point arrays.  It
# searches for the longest contiguous run of 1:1 aligned cells under one
# of two specific predicates per cell:
#
#   no-shift  -- subj and cand within EXACT_DEG (byte-identical or
#                precision-rounded)
#   lat-shift -- subj and cand within EXACT_DEG in lon, with dlat
#                matching the known 2011-era LAT_SHIFT_DEG magnitude
#                (within SHIFT_TOLERANCE_DEG)
#
# Both predicates are tested per cell; each maintains its own run set;
# the longest run across both wins.  The two predicate bands are
# disjoint, so a cell matches at most one of them.  No global "offset
# detection" phase -- arbitrary offsets aren't a thing in this domain,
# only the specific lat-shift bug is, and it's handled by the second
# predicate at no extra cost.
#
# Substantial exact runs are statistically infeasible to produce from
# independent recordings -- so when found, it's a confirmation of data
# lineage (one track is a copy, derivative, or trim of the other's
# source recording).  When such a run exists, _classifyExact reports
# an EXACT-tier result and the pipeline is done; no DTW work needed.
#
# Stage 2 (_decimateBobbing + _subsequenceDTW + _classifyDTW) only runs
# when Stage 1 declined to commit.  It decimates anchor-bobbing clusters,
# runs Subsequence DTW under a Sakoe-Chiba band, walks back the best
# alignment path, and classifies the result as MATCH (median per-cell
# cost <= EXACT_DEG) or NEAR (median above).
#
# Output schema (returned by both stages):
#
#   tier    -- 'exact' | 'match' | 'near' | 'none'
#              exact: substantial 1:1 sub-meter run found (data lineage)
#              match: median per-cell cost <= EXACT_DEG (same trip)
#              near:  median above EXACT_DEG (same channel, different recording)
#
#   shape   -- relationship between the leftover portions on each side:
#              full     -- both sides fully inside the matched portion
#              subset   -- subject fully matched, candidate has leftover
#              superset -- candidate fully matched, subject has leftover
#              trimmed  -- small leftovers on both sides (MATCH/NEAR only)
#              partial  -- significant leftovers on both sides (MATCH/NEAR only)
#              anomaly  -- EXACT with non-trivial leftover on both sides
#                          (statistically odd; surfaced for investigation)
#
#   quality -- 0.0..1.0 (MATCH/NEAR only): fraction of cells in the
#              matched range whose per-step cost is sub-meter.  1.0 means
#              every step within the matched portion is at exact-quality;
#              lower numbers reflect chord-corner / sampling residual.
#              Not meaningful for EXACT (always 1.0 by construction).
#
#   subj_coverage -- 0.0..1.0: fraction of subject's path-point count
#              inside the matched window.  Always reported.  The
#              load-bearing number when the user is asking "how much
#              of MY track is contained in this candidate?"
#
#   cand_coverage -- 0.0..1.0: fraction of candidate's path-point count
#              inside the matched window.  Always reported.  Tells the
#              user "how much of this candidate I'm seeing -- is the
#              candidate basically all match, or is it a much bigger
#              track of which I matched a small piece?"
#
#   matched_window -- [subj_start, subj_end, cand_start, cand_end] in
#                     ORIGINAL track-point indices.  For Stage 2, the
#                     index map carried by decimated points lets us
#                     translate the DTW window back to raw indices.
#
#   counts -- { subj_before, subj_in_match, subj_after,
#              cand_before, cand_in_match, cand_after } -- the six
#              point-count regions of the comparison, in original space.
#              Sums: subj_before + subj_in_match + subj_after = N (subject's
#              original point count).  Same for candidate.  Useful for
#              callers that want to display the structural breakdown
#              directly without interpreting tier/shape.
#
#   mode    -- EXACT only: 'noshift' or 'latshift' indicating which predicate
#              the contiguous run matched under.  Diagnostic; not used for
#              enrichment math (scalar fields like depth/temp transfer the
#              same way regardless of the coordinate shift).
#
#   steps   -- DTW (match/near) only: per-cell alignment path in ORIGINAL-
#              index space.  Array of { subj_idx, cand_idx, tb, cost } in
#              path order from start to end.  tb is 0=diagonal (1:1),
#              1=vertical (subject advanced, candidate held), 2=horizontal
#              (candidate advanced, subject held), 3=start.  Used by
#              navEnrich to map cells back to source/destination points
#              when transferring values across a warped alignment.  Absent
#              on EXACT (matched_window + 1:1 invariant is sufficient).
#
# Waypoints: scoreWaypointPair returns tier='exact'/shape='full' when
# the two points are within EXACT_DEG, else 'none'.  No bbox or warping
# concepts apply to a single point.

package navMatch;
use strict;
use warnings;
use Pub::Utils qw(display warning error);
use n_defs;
use navDB;
use navFSH;
use apps::raymarine::NET::c_RAYDP;


BEGIN
{
	use Exporter qw(import);
	our @EXPORT_OK = qw(
		scoreLineStringPair
		scoreWaypointPair
		pointDistanceDeg
		bboxOverlaps
		bboxOfPoints
		enumerateDbCandidates
		enumerateFshCandidates
		enumerateE80Candidates
	);
}


# Thresholds (degrees).
# Crude lat/lon delta thresholds, not true great-circle distances.  At Bocas
# latitude (~9 deg), 1 degree of lat is ~111 km; 1 degree lon at this
# latitude is ~110 km.
#
# EXACT_DEG    sized to coordinate-conversion precision (~0.55 m), not to
#              GPS accuracy.  This is the per-step tolerance for the
#              same-trip tier and the discriminator between `exact` /
#              `match` and `near`.
# BBOX_PAD_DEG used only to pad candidate-enumeration bbox prefilters.
# DTW_PRUNE_DEG is the cheap OUTER prune in _subsequenceDTW: cells
#              whose raw point-to-point distance exceeds this are
#              skipped without computing segment refinement.  Set wide
#              (~2 km) so it only eliminates obviously irrelevant cells,
#              not legitimate sparse-track cells where point-to-point
#              is dominated by sampling-phase offset rather than real
#              divergence (Pythagoras's other leg).
# DTW_SEG_PRUNE_DEG is the FINE prune AFTER segment refinement.  Cells
#              whose perpendicular-to-the-curve distance still exceeds
#              this (~111 m) represent genuine geographic divergence,
#              not sampling-phase noise.  This is the prune that
#              distinguishes "curves diverge here" from "samples are
#              out of phase here."
# STEP_PENALTY tiny additive penalty on vertical/horizontal DP moves.
#              Breaks ties in favor of diagonal (1:1) when segment-
#              refinement makes off-diagonal cells numerically as cheap
#              as diagonal cells in same-rate cases.
use constant {
	EXACT_DEG           => 0.000005,    # ~0.55 m  -- coord-conversion precision
	BBOX_PAD_DEG        => 0.0005,      # ~55 m    -- bbox prefilter padding
	DTW_PRUNE_DEG       => 0.02,        # ~2.2 km  -- DP cheap outer prune (point-to-point)
	DTW_SEG_PRUNE_DEG   => 0.001,       # ~111 m   -- DP fine prune on point-to-segment distance
	STEP_PENALTY        => 0.0000005,   # ~5.5 cm  -- diagonal-bias tiebreaker
	BOBBING_DEG         => 0.000018,    # ~2 m     -- bobbing decimation threshold
	EXACT_MIN_RUN       => 10,          # min consecutive 1:1 cells to call it EXACT
	LAT_SHIFT_DEG       => 0.0000327,   # ~3.6 m  -- known 2011-era systematic lat-only offset
	SHIFT_TOLERANCE_DEG => 0.00001,     # ~1.1 m  -- tolerance around the shift magnitude
};
my $INF = 1e18;

# Upper bound on the DP grid size in cells.  At ~50 bytes per Perl scalar
# this caps DTW memory at roughly 200 MB.  Pairs that exceed it are
# returned as 'none' rather than alignment-attempted; revisit if real
# data hits the cap (the Inline::C escape hatch is the next step there).
use constant DTW_MAX_CELLS => 4_000_000;


#---------------------------------
# helpers
#---------------------------------

sub pointDistanceDeg
{
	# Returns sqrt((dlat)^2 + (dlon)^2) in degrees.  NOT a true earth-surface
	# distance; just a fast comparable scalar.  Adequate for the proximity-
	# threshold tests this module does.
	my ($lat_a, $lon_a, $lat_b, $lon_b) = @_;
	my $dlat = $lat_a - $lat_b;
	my $dlon = $lon_a - $lon_b;
	return sqrt($dlat * $dlat + $dlon * $dlon);
}


sub bboxOfPoints
{
	# Returns { min_lat, max_lat, min_lon, max_lon } or undef for empty.
	my ($points) = @_;
	return undef if !$points || !@$points;
	my ($min_lat, $max_lat, $min_lon, $max_lon);
	for my $pt (@$points)
	{
		my $lat = $pt->{lat} // 0;
		my $lon = $pt->{lon} // 0;
		$min_lat = $lat if !defined($min_lat) || $lat < $min_lat;
		$max_lat = $lat if !defined($max_lat) || $lat > $max_lat;
		$min_lon = $lon if !defined($min_lon) || $lon < $min_lon;
		$max_lon = $lon if !defined($max_lon) || $lon > $max_lon;
	}
	return { min_lat => $min_lat, max_lat => $max_lat,
	         min_lon => $min_lon, max_lon => $max_lon };
}


sub bboxOverlaps
{
	# Inflated by BBOX_PAD_DEG so two tracks that brush each other count as
	# overlapping for prefilter purposes.
	my ($a, $b) = @_;
	return 0 if !$a || !$b;
	my $pad = BBOX_PAD_DEG;
	return 0 if $a->{max_lat} + $pad < $b->{min_lat} - $pad;
	return 0 if $b->{max_lat} + $pad < $a->{min_lat} - $pad;
	return 0 if $a->{max_lon} + $pad < $b->{min_lon} - $pad;
	return 0 if $b->{max_lon} + $pad < $a->{min_lon} - $pad;
	return 1;
}


#---------------------------------
# waypoint pair scoring
#---------------------------------

sub scoreWaypointPair
{
	# Single point vs single point: exact-or-nothing.  Bbox concept does
	# not apply to a point.  Anything further than EXACT_DEG is 'none' --
	# the scorer's job is to confirm same-point; geometric "near" relations
	# on waypoints are a winFind toolbar option, not a default outcome.
	my ($subj_lat, $subj_lon, $cand_lat, $cand_lon) = @_;
	my $d = pointDistanceDeg($subj_lat, $subj_lon, $cand_lat, $cand_lon);
	if ($d <= EXACT_DEG)
	{
		return {
			tier           => 'exact',
			shape          => 'full',
			quality        => undef,
			subj_coverage  => 1.0,
			cand_coverage  => 1.0,
			matched_window => undef,
			counts         => undef,
			distance_deg   => $d,
		};
	}
	return _empty_result();
}


#---------------------------------
# linestring pair scoring (tracks, routes)
#---------------------------------

sub scoreLineStringPair
{
	# Cascade scorer.  Two distinct algorithms answering two distinct
	# questions, in sequence:
	#
	#   1. EXACT pass -- "do these two recordings share source data?"
	#      Hash-based scan for a substantial contiguous run of 1:1
	#      sub-meter aligned points.  Operates on raw points (no
	#      decimation needed -- bobbing in same-source data is exactly
	#      aligned too).  Fast: O(N + M) with a small constant.
	#      If found, classify as EXACT-{full,subset,superset,anomaly}
	#      and we're done.
	#
	#   2. DTW fallback -- "do these two recordings trace the same
	#      shape, allowing for sampling differences?"  Bobbing-decimated
	#      DTW with all the warping machinery.  Only runs when the exact
	#      pass declined to commit.  Returns MATCH (median sub-meter
	#      cost) or NEAR (median above) with the shape pattern.
	#
	# The exact pass is fast precisely because it's looking for something
	# that almost never happens by accident.  Two independent recordings
	# of the same trip on the same device will not produce a substantial
	# run of sub-meter coincident cells -- GPS noise alone defeats that.
	# So when exact fires, it's confirming data lineage, not similarity.

	my ($subj_pts, $cand_pts) = @_;
	return _empty_result() if !$subj_pts || !@$subj_pts;
	return _empty_result() if !$cand_pts || !@$cand_pts;

	my $n = scalar @$subj_pts;
	my $m = scalar @$cand_pts;
	return _empty_result() if $n < 2 || $m < 2;

	# Bbox prefilter (applies to both passes).
	my $sb = bboxOfPoints($subj_pts);
	my $cb = bboxOfPoints($cand_pts);
	return _empty_result() if !bboxOverlaps($sb, $cb);

	# Stage 1: exact pass.  Handles both byte-identical / precision-
	# rounded data (no-shift predicate) and the specific 2011-era
	# Michelle lat-shift case (shift predicate, +- LAT_SHIFT_DEG).
	# No general offset detection -- a global "what's the median
	# offset between these tracks" heuristic was biased by sampling
	# anchor bobbing and produced phantom offsets.
	my $exact = _exactPass($subj_pts, $cand_pts);
	if ($exact)
	{
		return _classifyExact($exact, $n, $m);
	}

	# Stage 2: DTW fallback.  Decimate, run DTW, classify by tier x shape.
	# No constant-offset adjustment at this stage -- DTW just runs on
	# raw decimated coordinates.  Lat-shifted tracks should have been
	# caught upstream by the exact pass's shift predicate; if a track
	# is lat-shifted AND shape-mismatched it will land in 'near' here,
	# which is an honest classification given the structural cost.
	my $subj_dec = _decimateBobbing($subj_pts);
	my $cand_dec = _decimateBobbing($cand_pts);
	my $nd = scalar @$subj_dec;
	my $md = scalar @$cand_dec;
	return _empty_result() if $nd < 2 || $md < 2;
	return _empty_result() if $nd * $md > DTW_MAX_CELLS;

	my $dtw = _subsequenceDTW($subj_dec, $cand_dec, 0, 0);
	return _empty_result() if !$dtw;

	return _classifyDTW($dtw, $nd, $md, $n, $m, $subj_dec, $cand_dec);
}


sub _decimateBobbing
{
	# Collapse consecutive-close-together points (bobbing at anchor) down
	# to a single representative.  Walks the input; keeps a point only
	# when it's at least BOBBING_DEG (~2 m) from the most recently kept
	# point.  First and last points are always preserved.
	#
	# Returns a parallel array of POINT CLONES, each with an added
	# `_orig_idx` field carrying its index in the input array.  The
	# clones (vs storing originals plus a parallel index array) keep the
	# DTW reader code unchanged -- it still reads $pts->[$j]{lat} etc.
	# -- while letting the classifier map matched_window indices back
	# to original-point space.
	#
	# Caveat: this decimation has a known fragility -- the "last kept
	# point" reference can flip a single keep/skip decision when a
	# distance straddles 2 m, and that decision then re-anchors all
	# subsequent comparisons.  Two near-identical tracks can decimate
	# to slightly different counts.  A motion-based replacement
	# (heading-coherence / displacement-over-path-length) would be
	# robust to this and is on the future-work list.

	my ($pts) = @_;
	my $n = scalar @$pts;
	if ($n < 3)
	{
		my @dup;
		for (my $i = 0; $i < $n; $i++)
		{
			push @dup, { %{$pts->[$i]}, _orig_idx => $i };
		}
		return \@dup;
	}

	my @keep;
	push @keep, { %{$pts->[0]}, _orig_idx => 0 };
	my $last_lat = $pts->[0]{lat} // 0;
	my $last_lon = $pts->[0]{lon} // 0;
	my $thresh_sq = BOBBING_DEG * BOBBING_DEG;

	for (my $i = 1; $i < $n - 1; $i++)
	{
		my $dlat = ($pts->[$i]{lat} // 0) - $last_lat;
		my $dlon = ($pts->[$i]{lon} // 0) - $last_lon;
		my $d2 = $dlat * $dlat + $dlon * $dlon;
		if ($d2 >= $thresh_sq)
		{
			push @keep, { %{$pts->[$i]}, _orig_idx => $i };
			$last_lat = $pts->[$i]{lat} // 0;
			$last_lon = $pts->[$i]{lon} // 0;
		}
	}
	push @keep, { %{$pts->[$n - 1]}, _orig_idx => $n - 1 };
	return \@keep;
}


sub _exactPass
{
	# Hash-based search for the longest contiguous run of 1:1 aligned
	# cells between subject and candidate.  Each (subj[i], cand[j]) pair
	# is tested against TWO predicates per cell:
	#
	#   no-shift: sqrt(dlat^2 + dlon^2) <= EXACT_DEG
	#             Byte-identical / precision-rounded data.  Most common.
	#
	#   lat-shift: |dlon| <= EXACT_DEG  AND
	#              abs(|dlat| - LAT_SHIFT_DEG) <= SHIFT_TOLERANCE_DEG
	#             The specific 2011-era Michelle case: a systematic
	#             ~3.6 m lat-only offset that originated in a buggy
	#             north-east-to-lat-lon implementation.  Tolerance
	#             absorbs the small latitude-dependent variation that
	#             bug can produce; the two predicate bands don't overlap
	#             so a cell only matches at most one of them.
	#
	# Each predicate maintains its own run set.  A run extends when the
	# previous (i-1, j-1) cell matched under the SAME predicate; the
	# two predicates do not cross-extend.  At end of walk, the longest
	# run across both predicates wins.
	#
	# Returns hash { i_start, i_end, j_start, j_end, length, mode }
	# (mode = 'noshift' | 'latshift') when a run of >= EXACT_MIN_RUN
	# is found; undef otherwise.
	#
	# Performance: O((N + M) * average_bin_density).  Walks subject
	# once.  No global offset detection -- the two predicates are
	# applied independently per cell, so a track that's the byte-
	# identical case vs one that's the lat-shift case both fall out
	# naturally without a pre-computed "what's the offset" step.

	my ($subj_pts, $cand_pts) = @_;
	my $n = scalar @$subj_pts;
	my $m = scalar @$cand_pts;

	my $bin_size = EXACT_DEG;
	my $exact     = EXACT_DEG;
	my $exact_sq  = $exact * $exact;
	my $shift_mag = LAT_SHIFT_DEG;
	my $shift_tol = SHIFT_TOLERANCE_DEG;

	# Build candidate bin index for the no-shift predicate.
	my %cand_hash;
	my @cand_lat;
	my @cand_lon;
	for (my $j = 0; $j < $m; $j++)
	{
		my $lat = $cand_pts->[$j]{lat} // 0;
		my $lon = $cand_pts->[$j]{lon} // 0;
		$cand_lat[$j] = $lat;
		$cand_lon[$j] = $lon;
		my $key = int($lat / $bin_size) . ':' . int($lon / $bin_size);
		push @{$cand_hash{$key}}, $j;
	}

	# Two independent run sets, one per predicate.
	my %active_no;
	my %active_sh;
	my $best;

	for (my $i = 0; $i < $n; $i++)
	{
		my $slat = $subj_pts->[$i]{lat} // 0;
		my $slon = $subj_pts->[$i]{lon} // 0;
		my $bl   = int($slat / $bin_size);
		my $bn   = int($slon / $bin_size);

		my %new_no;
		my %new_sh;

		# Gather candidate j's in the 3x3 bin neighborhood for the
		# no-shift predicate.  The lat-shift predicate uses the SAME
		# bins because the shift magnitude is ~3.6 m and bin size is
		# 0.55 m -- a lat-shifted match has its candidate point in a
		# bin shifted by ~7 cells from the subject's bin in lat.  We
		# need to look in those shifted bins too.  Cleanest: build the
		# candidate-lookup list once per subject point, then test each
		# candidate against both predicates.
		my @candidates;
		for my $dl (-1, 0, 1)
		{
			for my $dn (-1, 0, 1)
			{
				my $key = ($bl + $dl) . ':' . ($bn + $dn);
				push @candidates, @{$cand_hash{$key}} if $cand_hash{$key};
			}
		}
		# Also gather candidates in the bin neighborhood SHIFTED by the
		# known lat-shift magnitude (both signs), to catch lat-shift
		# matches whose candidate sits in a different lat-bin.
		my $shift_bins = int($shift_mag / $bin_size + 0.5);
		for my $sign (-1, 1)
		{
			my $shifted_bl = $bl + $sign * $shift_bins;
			for my $dl (-1, 0, 1)
			{
				for my $dn (-1, 0, 1)
				{
					my $key = ($shifted_bl + $dl) . ':' . ($bn + $dn);
					push @candidates, @{$cand_hash{$key}} if $cand_hash{$key};
				}
			}
		}

		# Dedup -- a cand index may appear in both neighborhoods if the
		# shift is small.  We don't want to score it twice in run
		# tracking.
		my %seen;
		for my $j (@candidates)
		{
			next if $seen{$j}++;

			my $dlat = $slat - $cand_lat[$j];
			my $dlon = $slon - $cand_lon[$j];

			# No-shift predicate.
			if ($dlat * $dlat + $dlon * $dlon <= $exact_sq)
			{
				my $prev = $active_no{$j - 1};
				my $run;
				if ($prev) { $run = [$prev->[0], $prev->[1], $prev->[2] + 1]; }
				else       { $run = [$i, $j, 1]; }
				my $existing = $new_no{$j};
				if (!$existing || $run->[2] > $existing->[2])
				{
					$new_no{$j} = $run;
				}
				if (!$best || $run->[2] > $best->{length})
				{
					$best = {
						i_start => $run->[0],
						i_end   => $i,
						j_start => $run->[1],
						j_end   => $j,
						length  => $run->[2],
						mode    => 'noshift',
					};
				}
			}
			# Lat-shift predicate.  Disjoint band from no-shift, so a
			# cell can't fire both.
			elsif (abs($dlon) <= $exact
			    && abs(abs($dlat) - $shift_mag) <= $shift_tol)
			{
				my $prev = $active_sh{$j - 1};
				my $run;
				if ($prev) { $run = [$prev->[0], $prev->[1], $prev->[2] + 1]; }
				else       { $run = [$i, $j, 1]; }
				my $existing = $new_sh{$j};
				if (!$existing || $run->[2] > $existing->[2])
				{
					$new_sh{$j} = $run;
				}
				if (!$best || $run->[2] > $best->{length})
				{
					$best = {
						i_start => $run->[0],
						i_end   => $i,
						j_start => $run->[1],
						j_end   => $j,
						length  => $run->[2],
						mode    => 'latshift',
					};
				}
			}
		}

		%active_no = %new_no;
		%active_sh = %new_sh;
	}

	return undef if !$best;
	return undef if $best->{length} < EXACT_MIN_RUN;
	return $best;
}


sub _classifyExact
{
	# Build the result hash for an EXACT-tier match.  The shape derives
	# from which side has leftover points outside the matched run.
	#
	# Per Patrick's framing, EXACT can only legitimately produce three
	# shapes:
	#
	#   full     -- both sides fully contained in the matched run
	#   subset   -- subject fully matched, candidate has leftover (any side)
	#   superset -- candidate fully matched, subject has leftover (any side)
	#   anomaly  -- both have non-trivial leftover.  Statistically very
	#               unlikely from any normal source -- almost certainly
	#               indicates a data anomaly (mid-track edit, double-
	#               compression-and-download, etc.) rather than a real
	#               track relationship.  Surfaced as 'anomaly' so the
	#               user can investigate rather than silently treating
	#               it as a normal subset/superset.

	my ($ex, $n, $m) = @_;

	my $subj_before = $ex->{i_start};
	my $subj_in    = $ex->{i_end} - $ex->{i_start} + 1;
	my $subj_after  = $n - 1 - $ex->{i_end};
	my $cand_before = $ex->{j_start};
	my $cand_in    = $ex->{j_end} - $ex->{j_start} + 1;
	my $cand_after  = $m - 1 - $ex->{j_end};

	my $subj_outside = $subj_before + $subj_after;
	my $cand_outside = $cand_before + $cand_after;

	my $shape;
	if ($subj_outside == 0 && $cand_outside == 0)  { $shape = 'full'     }
	elsif ($subj_outside == 0)                      { $shape = 'subset'   }
	elsif ($cand_outside == 0)                      { $shape = 'superset' }
	else                                            { $shape = 'anomaly'  }

	return {
		tier           => 'exact',
		shape          => $shape,
		quality        => undef,        # not meaningful for exact
		mode           => $ex->{mode},  # 'noshift' | 'latshift'
		subj_coverage  => ($n > 0) ? ($subj_in / $n) : 0,
		cand_coverage  => ($m > 0) ? ($cand_in / $m) : 0,
		matched_window => [$ex->{i_start}, $ex->{i_end},
		                   $ex->{j_start}, $ex->{j_end}],
		counts         => {
			subj_before   => $subj_before,
			subj_in_match => $subj_in,
			subj_after    => $subj_after,
			cand_before   => $cand_before,
			cand_in_match => $cand_in,
			cand_after    => $cand_after,
		},
	};
}


sub _empty_result
{
	return {
		tier           => 'none',
		shape          => undef,
		quality        => undef,
		subj_coverage  => 0,
		cand_coverage  => 0,
		matched_window => undef,
		counts         => undef,
	};
}


#---------------------------------
# DTW machinery (private)
#---------------------------------

sub _pointToSegmentDistance
{
	# Distance from a point P to a line segment A-B in (lat, lon) space.
	# Treats lat/lon as planar -- adequate at the scale where one segment
	# is at most a few meters, the scale at which this scorer cares.
	# Returns the actual distance (not squared) so it composes with
	# EXACT_DEG / DTW_PRUNE_DEG directly.
	my ($plat, $plon, $alat, $alon, $blat, $blon) = @_;
	my $ax = $blat - $alat;
	my $ay = $blon - $alon;
	my $len_sq = $ax * $ax + $ay * $ay;
	if ($len_sq < 1e-20)
	{
		my $dx = $plat - $alat;
		my $dy = $plon - $alon;
		return sqrt($dx * $dx + $dy * $dy);
	}
	my $t = (($plat - $alat) * $ax + ($plon - $alon) * $ay) / $len_sq;
	$t = 0 if $t < 0;
	$t = 1 if $t > 1;
	my $cx = $alat + $t * $ax;
	my $cy = $alon + $t * $ay;
	my $dx = $plat - $cx;
	my $dy = $plon - $cy;
	return sqrt($dx * $dx + $dy * $dy);
}


sub _subsequenceDTW
{
	# Standard DTW DP with three modifications:
	#
	#   - Sakoe-Chiba band of width K around the rescaled diagonal
	#     j ~ i * M / N, so warping stays plausible and cells outside
	#     the band are skipped.  K is fractional (~25% of the larger
	#     dimension) plus a floor; generous enough for sample-rate
	#     mismatches up to ~4x.
	#   - Distance prune: cells whose raw point-to-point distance
	#     exceeds DTW_PRUNE_DEG are set to +inf and skipped.  Loose
	#     enough (~555 m) to let the path propagate past compression-
	#     induced chord-gap regions; tight enough that cells outside
	#     a reasonable corridor are still rejected without DP work.
	#   - Subsequence variant: free start on any cell in row 0 or
	#     column 0 (predecessor = START sentinel), free end picked from
	#     the last row OR last column.  This lets the matched window be
	#     a sub-range of either side.
	#
	# Cell predecessors are:
	#     diagonal  (TB=0): D[i-1][j-1]  -- 1:1 step
	#     vertical  (TB=1): D[i-1][j]    -- many subject -> one candidate
	#     horizontal(TB=2): D[i][j-1]    -- one subject  -> many candidate
	#     START     (TB=3): no predecessor
	#
	# Returns a walkback hash describing the best alignment, or undef when
	# no viable path exists.

	my ($a_pts, $b_pts, $off_lat, $off_lon) = @_;
	my $n = scalar @$a_pts;
	my $m = scalar @$b_pts;
	my $near = DTW_PRUNE_DEG;
	my $near_sq = $near * $near;

	# Precompute flat coordinate arrays with offset baked into B.
	my @a_lat = map { $_->{lat} // 0 } @$a_pts;
	my @a_lon = map { $_->{lon} // 0 } @$a_pts;
	my @b_lat = map { ($_->{lat} // 0) + $off_lat } @$b_pts;
	my @b_lon = map { ($_->{lon} // 0) + $off_lon } @$b_pts;

	my $larger = $n > $m ? $n : $m;
	my $K = int($larger * 0.25);
	$K = 30 if $K < 30;
	my $slope = $m / $n;

	# Flat-indexed cost grid D and traceback grid TB ([i*m + j]).
	my @D;
	my @TB;
	$#D  = $n * $m - 1;
	$#TB = $n * $m - 1;

	for (my $i = 0; $i < $n; $i++)
	{
		my $i_off = $i * $m;
		my $j_center = int($i * $slope);
		my $j_min = $j_center - $K;
		my $j_max = $j_center + $K;
		$j_min = 0     if $j_min < 0;
		$j_max = $m-1  if $j_max > $m - 1;

		my $alat = $a_lat[$i];
		my $alon = $a_lon[$i];

		for (my $j = 0; $j < $m; $j++)
		{
			my $idx = $i_off + $j;
			if ($j < $j_min || $j > $j_max)
			{
				$D[$idx]  = $INF;
				$TB[$idx] = -1;
				next;
			}

			my $dlat = $alat - $b_lat[$j];
			if (abs($dlat) > $near)
			{
				$D[$idx]  = $INF;
				$TB[$idx] = -1;
				next;
			}
			my $dlon = $alon - $b_lon[$j];
			if (abs($dlon) > $near)
			{
				$D[$idx]  = $INF;
				$TB[$idx] = -1;
				next;
			}
			my $d2 = $dlat * $dlat + $dlon * $dlon;
			if ($d2 > $near_sq)
			{
				$D[$idx]  = $INF;
				$TB[$idx] = -1;
				next;
			}
			my $d = sqrt($d2);

			# Refine cell cost with point-to-segment.  This is the load-
			# bearing measurement for two-curve closeness when tracks are
			# sparse samples of a continuous path: point-to-point distance
			# conflates real divergence (deviation perpendicular to the
			# curve) with sampling phase mismatch (along-curve offset
			# between subj's and cand's sampling moments).  Pythagoras:
			# point_to_point^2 = perpendicular^2 + along_curve^2.  Only
			# the perpendicular component is meaningful for "do these
			# trace the same path."
			#
			# Two segment directions:
			#   cand seg (cand[j-1] -> cand[j]): subj[i] to cand's polyline
			#   subj seg (subj[i-1] -> subj[i]): cand[j] to subj's polyline
			# Min of the two (and the raw point-to-point) is the refined
			# cell cost.
			if ($d > EXACT_DEG)
			{
				if ($j > 0)
				{
					my $ds = _pointToSegmentDistance(
						$alat, $alon,
						$b_lat[$j-1], $b_lon[$j-1],
						$b_lat[$j],   $b_lon[$j]);
					$d = $ds if $ds < $d;
				}
				if ($i > 0)
				{
					my $ds = _pointToSegmentDistance(
						$b_lat[$j], $b_lon[$j],
						$a_lat[$i-1], $a_lon[$i-1],
						$a_lat[$i],   $a_lon[$i]);
					$d = $ds if $ds < $d;
				}
			}

			# Inner prune: cells whose REFINED distance is still large
			# represent genuine geographic divergence between the two
			# curves, not sampling-phase artifacts.  This prune at
			# DTW_SEG_PRUNE_DEG (~111 m) is what distinguishes "the
			# curves diverge here" from "the samples are out of phase
			# here."  Without it, all sparse-track cells whose point-
			# to-point distance was within DTW_PRUNE_DEG would enter
			# the DP at high cost, polluting median/avg measurements.
			if ($d > DTW_SEG_PRUNE_DEG)
			{
				$D[$idx]  = $INF;
				$TB[$idx] = -1;
				next;
			}

			my $best_pred = $INF;
			my $best_tb   = -1;

			# Free start on row 0 or column 0.
			if ($i == 0 || $j == 0)
			{
				$best_pred = 0;
				$best_tb   = 3;
			}
			# Diagonal step (no penalty) -- biases the DP toward 1:1
			# alignment when alternatives are equal-cost.
			if ($i > 0 && $j > 0)
			{
				my $v = $D[$idx - $m - 1];
				if ($v < $best_pred) { $best_pred = $v; $best_tb = 0; }
			}
			# Vertical / horizontal steps carry STEP_PENALTY so that
			# segment-refinement (which can make off-diagonal cells
			# numerically as cheap as diagonal cells in same-rate cases)
			# doesn't flip the walkback away from a true 1:1 alignment.
			# Penalty is tiny vs EXACT_DEG so genuine sample-rate-
			# mismatch cases (where the savings dwarf it) are unaffected.
			if ($i > 0)
			{
				my $v = $D[$idx - $m] + STEP_PENALTY;
				if ($v < $best_pred) { $best_pred = $v; $best_tb = 1; }
			}
			if ($j > 0)
			{
				my $v = $D[$idx - 1] + STEP_PENALTY;
				if ($v < $best_pred) { $best_pred = $v; $best_tb = 2; }
			}

			if ($best_pred >= $INF)
			{
				$D[$idx]  = $INF;
				$TB[$idx] = -1;
			}
			else
			{
				$D[$idx]  = $best_pred + $d;
				$TB[$idx] = $best_tb;
			}
		}
	}

	# Pick the best end cell from the last row + last column.  "Best" =
	# the path that covers the most of both sides at the lowest average
	# cost; we use a simple combined rank rather than a true normalized
	# DTW cost because we want long alignments to beat tiny pristine ones.
	my @end_cells;
	for (my $j = 0; $j < $m; $j++)
	{
		my $idx = ($n - 1) * $m + $j;
		push @end_cells, [$n - 1, $j] if $D[$idx] < $INF;
	}
	for (my $i = 0; $i < $n - 1; $i++)
	{
		my $idx = $i * $m + ($m - 1);
		push @end_cells, [$i, $m - 1] if $D[$idx] < $INF;
	}
	return undef if !@end_cells;

	my $best = undef;
	for my $ec (@end_cells)
	{
		my $path = _walkbackDTW(\@D, \@TB, $ec->[0], $ec->[1], $m);
		next if !$path;
		next if scalar(@{$path->{steps}}) < 2;
		my $subj_span = $path->{i_end} - $path->{i_start} + 1;
		my $cand_span = $path->{j_end} - $path->{j_start} + 1;
		my $covered = $subj_span + $cand_span;
		my $L = scalar @{$path->{steps}};
		my $avg = $path->{total_cost} / $L;
		# Higher = better.  Coverage dominates; ties broken by avg cost.
		my $rank = $covered - $avg * 1.0e6;
		if (!$best || $rank > $best->{rank})
		{
			$best = $path;
			$best->{rank} = $rank;
		}
	}

	return $best;
}


sub _walkbackDTW
{
	# Walk back from end cell (i_end, j_end) via TB predecessors until a
	# START sentinel (or an unreachable cell, defensive).  Records:
	#   - per-step incremental cost = D[cur] - D[prev]
	#   - max per-step cost (used to discriminate exact vs near-route)
	#   - step-direction counts (diagonal / vertical / horizontal)
	#   - the (i_start, j_start) that the path entered through

	my ($D, $TB, $i_end, $j_end, $m) = @_;
	my @steps;
	my $max_step_cost = 0;
	my $total_cost    = 0;
	my $n_diag  = 0;
	my $n_vert  = 0;
	my $n_horiz = 0;

	my $i = $i_end;
	my $j = $j_end;
	while ($i >= 0 && $j >= 0)
	{
		my $idx = $i * $m + $j;
		my $tb = $TB->[$idx];
		last if !defined $tb || $tb == -1;

		my $cell_cost;
		if ($tb == 3)
		{
			# START cell: cumulative cost == cell cost.
			$cell_cost = $D->[$idx];
		}
		elsif ($tb == 0)
		{
			$cell_cost = $D->[$idx] - $D->[$idx - $m - 1];
		}
		elsif ($tb == 1)
		{
			$cell_cost = $D->[$idx] - $D->[$idx - $m];
		}
		else
		{
			$cell_cost = $D->[$idx] - $D->[$idx - 1];
		}
		$cell_cost = 0 if $cell_cost < 0;     # defensive against float drift

		$max_step_cost = $cell_cost if $cell_cost > $max_step_cost;
		$total_cost   += $cell_cost;
		push @steps, { i => $i, j => $j, cost => $cell_cost, tb => $tb };

		if ($tb == 3)
		{
			last;
		}
		elsif ($tb == 0)
		{
			$n_diag++;
			$i--;
			$j--;
		}
		elsif ($tb == 1)
		{
			$n_vert++;
			$i--;
		}
		else
		{
			$n_horiz++;
			$j--;
		}
	}

	return undef if !@steps;

	return {
		steps         => \@steps,
		i_start       => $steps[-1]{i},
		j_start       => $steps[-1]{j},
		i_end         => $i_end,
		j_end         => $j_end,
		max_step_cost => $max_step_cost,
		total_cost    => $total_cost,
		n_diag        => $n_diag,
		n_vert        => $n_vert,
		n_horiz       => $n_horiz,
	};
}


sub _classifyDTW
{
	# Classify the DTW alignment into the (match | near) tier with a
	# shape and a quality percentage.
	#
	# tier:
	#   match -- median per-step cost <= EXACT_DEG.  Most cells along
	#            the matched path are sub-meter aligned; chord-corner
	#            outliers from compression are tolerated.
	#   near  -- median above EXACT_DEG.  Curves are geographically
	#            close but not coincident.  Distinguishes "same channel,
	#            different recording" from genuine same-trip matches.
	#
	# Note: 'exact' tier is NOT produced by DTW.  It's produced by the
	# exact-pass cascade upstream of this function.  By the time we
	# reach DTW, the exact pass already declined to commit -- either
	# there's no substantial 1:1 sub-meter run or the warping in the
	# best alignment makes a 1:1 framing wrong.
	#
	# shape (point-count-trim pattern, in ORIGINAL track-point space):
	#   full     -- both ends matched on both sides
	#   trimmed  -- small unmatched portions on both sides
	#   subset   -- subject fully matched, candidate has significant
	#               leftover (subject is a sub-section of candidate)
	#   superset -- candidate fully matched, subject has significant
	#               leftover (candidate is a sub-section of subject)
	#   partial  -- both sides have significant unmatched portions with
	#               a middle match
	#
	# quality: fraction of cells in the matched range whose per-step
	# cost is <= EXACT_DEG.  1.0 = every step sub-meter (effectively
	# exact-quality within the matched portion); lower numbers indicate
	# how much chord/sampling residual the alignment carries.

	my ($dtw, $nd, $md, $n_orig, $m_orig, $subj_dec, $cand_dec) = @_;
	return _empty_result() if !$dtw;

	my $i_start = $dtw->{i_start};
	my $i_end   = $dtw->{i_end};
	my $j_start = $dtw->{j_start};
	my $j_end   = $dtw->{j_end};

	# Median step cost decides tier (match vs near).
	my $L = scalar @{$dtw->{steps}};
	my @step_costs = map { $_->{cost} } @{$dtw->{steps}};
	my @sorted_costs = sort { $a <=> $b } @step_costs;
	my $median_step = ($L > 0) ? $sorted_costs[int(@sorted_costs / 2)] : $INF;
	my $tier = ($median_step <= EXACT_DEG) ? 'match' : 'near';

	# Quality = fraction of cells at sub-meter alignment.
	my $sub_meter = 0;
	for my $c (@step_costs) { $sub_meter++ if $c <= EXACT_DEG; }
	my $quality = ($L > 0) ? ($sub_meter / $L) : 0;

	# Map matched_window from decimated index space back to original
	# track-point indices.  The decimated point hashes carry _orig_idx
	# placed there by _decimateBobbing.  This makes trim counts and
	# shape semantics reflect the actual recorded tracks, not the
	# decimation artifacts.
	my $orig_i_start = $subj_dec->[$i_start]{_orig_idx};
	my $orig_i_end   = $subj_dec->[$i_end]  {_orig_idx};
	my $orig_j_start = $cand_dec->[$j_start]{_orig_idx};
	my $orig_j_end   = $cand_dec->[$j_end]  {_orig_idx};

	my $subj_before = $orig_i_start;
	my $subj_in     = $orig_i_end - $orig_i_start + 1;
	my $subj_after  = $n_orig - 1 - $orig_i_end;
	my $cand_before = $orig_j_start;
	my $cand_in     = $orig_j_end - $orig_j_start + 1;
	my $cand_after  = $m_orig - 1 - $orig_j_end;
	my $subj_outside = $subj_before + $subj_after;
	my $cand_outside = $cand_before + $cand_after;

	# "Small outside" = <= 5 points OR <= 5% of the original side.
	my $small_subj = ($subj_outside <= 5 || $subj_outside <= 0.05 * $n_orig);
	my $small_cand = ($cand_outside <= 5 || $cand_outside <= 0.05 * $m_orig);

	my $shape;
	if ($subj_outside == 0 && $cand_outside == 0)
	{
		$shape = 'full';
	}
	elsif ($small_subj && $small_cand)
	{
		$shape = 'trimmed';
	}
	elsif ($small_subj && !$small_cand)
	{
		$shape = 'subset';
	}
	elsif (!$small_subj && $small_cand)
	{
		$shape = 'superset';
	}
	else
	{
		$shape = 'partial';
	}

	# Translate walkback steps from decimated-index to original-index space
	# using the same _orig_idx map carried on decimated points.  Reverse the
	# array so steps run from start to end of the path (walkback recorded
	# them end-to-start).  Each step preserves tb so navEnrich can interpret
	# diagonal vs vertical vs horizontal alignment cells.
	my @orig_steps;
	for my $st (reverse @{$dtw->{steps}})
	{
		push @orig_steps, {
			subj_idx => $subj_dec->[$st->{i}]{_orig_idx},
			cand_idx => $cand_dec->[$st->{j}]{_orig_idx},
			tb       => $st->{tb},
			cost     => $st->{cost},
		};
	}

	return {
		tier           => $tier,
		shape          => $shape,
		quality        => $quality,
		subj_coverage  => ($n_orig > 0) ? ($subj_in / $n_orig) : 0,
		cand_coverage  => ($m_orig > 0) ? ($cand_in / $m_orig) : 0,
		matched_window => [$orig_i_start, $orig_i_end,
		                   $orig_j_start, $orig_j_end],
		counts         => {
			subj_before   => $subj_before,
			subj_in_match => $subj_in,
			subj_after    => $subj_after,
			cand_before   => $cand_before,
			cand_in_match => $cand_in,
			cand_after    => $cand_after,
		},
		steps          => \@orig_steps,
	};
}


#---------------------------------
# candidate enumeration (per source)
#---------------------------------
# Each enumerator returns an arrayref of candidate hashes for the given
# $obj_type ('waypoint' / 'track' / 'route') whose bounding box overlaps
# $subj_bbox.  Lives here -- not in navDB / navFSH / winE80 -- because
# matching is the load-bearing concern, and we want one place to maintain
# the shape of the returned candidate hashes.  Per-source data access is
# done by calling into navDB / $navFSH::fsh_db / WPMGR+TRACK services
# respectively.
#
# Candidate hash shape (documented once here):
#   source         -- 'db' | 'fsh' | 'e80'
#   uuid           -- the source's UUID
#   obj_type       -- 'waypoint' | 'track' | 'route'
#   name           -- display name
#   hierarchy_path -- "/"-separated container path
#   lat, lon       -- decimal degrees (waypoints only)
#   points         -- arrayref of {lat,lon,...} (tracks/routes only)
#   npts           -- point count
#   bbox           -- { min_lat, max_lat, min_lon, max_lon }
#   color_abgr     -- resolved ABGR string for display (undef when no color)
#   color_value    -- raw stored value: ABGR for DB, palette index for FSH/E80
#   ts_start, ts_end (tracks only)
#   has_ts         -- 1 if any point/record carries a real timestamp
#   has_depth      -- 1 if any point carries non-zero depth_cm
#   has_temp_k     -- 1 if any point carries non-zero temp_k (and not 65535)
#   wp_type        -- integer enum: 0=nav | 3=label | 2=sounding (waypoints only)


sub enumerateDbCandidates
	# Two-step: SQL fetches every track's MIN/MAX-aggregated bbox in one
	# round-trip (no HAVING — that was unreliable), and we filter in Perl
	# using the same bboxOverlaps logic the other enumerators use.  Loads
	# track_points only for tracks that pass the bbox prefilter.
{
	my ($obj_type, $subj_bbox) = @_;
	return [] if !$subj_bbox;
	my $dbh = navDB::connectDB();
	return [] if !$dbh;

	my @out;
	my $pad = BBOX_PAD_DEG;
	my $padded_bbox = {
		min_lat => $subj_bbox->{min_lat} - $pad,
		max_lat => $subj_bbox->{max_lat} + $pad,
		min_lon => $subj_bbox->{min_lon} - $pad,
		max_lon => $subj_bbox->{max_lon} + $pad,
	};
	my $path_cache = {};

	if ($obj_type eq 'waypoint')
	{
		my $rows = $dbh->get_records(
			"SELECT uuid, name, lat, lon, color, collection_uuid, wp_type,
			        depth_cm, temp_k, created_ts, ts_source
			 FROM waypoints
			 WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?",
			[$padded_bbox->{min_lat}, $padded_bbox->{max_lat},
			 $padded_bbox->{min_lon}, $padded_bbox->{max_lon}]);
		for my $r (@{$rows // []})
		{
			push @out, {
				source         => 'db',
				uuid           => $r->{uuid},
				obj_type       => 'waypoint',
				name           => $r->{name} // '',
				hierarchy_path => navDB::getCollectionHierarchyPath($dbh, $r->{collection_uuid}, $path_cache),
				lat            => $r->{lat} + 0,
				lon            => $r->{lon} + 0,
				npts           => 1,
				color_abgr     => $r->{color},
				color_value    => $r->{color},
				bbox           => { min_lat => $r->{lat}+0, max_lat => $r->{lat}+0,
				                    min_lon => $r->{lon}+0, max_lon => $r->{lon}+0 },
				has_ts         => ($r->{created_ts} && (($r->{ts_source} // '') ne 'nav')) ? 1 : 0,
				has_depth      => ($r->{depth_cm} // 0) > 0 ? 1 : 0,
				has_temp_k     => ($r->{temp_k}   // 0) > 0 ? 1 : 0,
				wp_type        => $r->{wp_type} // $WP_TYPE_NAV,
			};
		}
	}
	elsif ($obj_type eq 'track')
	{
		# Pull every track's aggregated bbox.  Plain SELECT with GROUP BY --
		# no HAVING clause.  Filter in Perl.
		my $rows = $dbh->get_records(qq{
			SELECT t.uuid, t.name, t.color, t.collection_uuid,
			       t.ts_start, t.ts_end, t.point_count,
			       MIN(tp.lat) AS min_lat, MAX(tp.lat) AS max_lat,
			       MIN(tp.lon) AS min_lon, MAX(tp.lon) AS max_lon
			FROM tracks t
			JOIN track_points tp ON tp.track_uuid = t.uuid
			GROUP BY t.uuid
		}, []);
		for my $r (@{$rows // []})
		{
			my $cand_bbox = {
				min_lat => $r->{min_lat} + 0, max_lat => $r->{max_lat} + 0,
				min_lon => $r->{min_lon} + 0, max_lon => $r->{max_lon} + 0,
			};
			next if !bboxOverlaps($cand_bbox, $padded_bbox);

			my $pts = navDB::getTrackPoints($dbh, $r->{uuid}) // [];
			my $has_ts    = 0;
			my $has_depth = 0;
			my $has_temp  = 0;
			for my $p (@$pts)
			{
				$has_ts    = 1 if $p->{ts};
				$has_depth = 1 if ($p->{depth_cm} // 0) > 0;
				$has_temp  = 1 if ($p->{temp_k}   // 0) > 0;
				last if $has_ts && $has_depth && $has_temp;
			}
			push @out, {
				source         => 'db',
				uuid           => $r->{uuid},
				obj_type       => 'track',
				name           => $r->{name} // '',
				hierarchy_path => navDB::getCollectionHierarchyPath($dbh, $r->{collection_uuid}, $path_cache),
				points         => $pts,
				npts           => $r->{point_count} // scalar(@$pts),
				color_abgr     => $r->{color},
				color_value    => $r->{color},
				bbox           => $cand_bbox,
				ts_start       => $r->{ts_start},
				ts_end         => $r->{ts_end},
				has_ts         => $has_ts,
				has_depth      => $has_depth,
				has_temp_k     => $has_temp,
			};
		}
	}
	elsif ($obj_type eq 'route')
	{
		my $rows = $dbh->get_records(qq{
			SELECT r.uuid, r.name, r.color, r.collection_uuid,
			       MIN(w.lat) AS min_lat, MAX(w.lat) AS max_lat,
			       MIN(w.lon) AS min_lon, MAX(w.lon) AS max_lon,
			       COUNT(*) AS npts
			FROM routes r
			JOIN route_waypoints rw ON rw.route_uuid = r.uuid
			JOIN waypoints w        ON w.uuid        = rw.wp_uuid
			GROUP BY r.uuid
		}, []);
		for my $r (@{$rows // []})
		{
			my $cand_bbox = {
				min_lat => $r->{min_lat} + 0, max_lat => $r->{max_lat} + 0,
				min_lon => $r->{min_lon} + 0, max_lon => $r->{max_lon} + 0,
			};
			next if !bboxOverlaps($cand_bbox, $padded_bbox);

			my $pts = navDB::getRoutePoints($dbh, $r->{uuid}) // [];
			push @out, {
				source         => 'db',
				uuid           => $r->{uuid},
				obj_type       => 'route',
				name           => $r->{name} // '',
				hierarchy_path => navDB::getCollectionHierarchyPath($dbh, $r->{collection_uuid}, $path_cache),
				points         => $pts,
				npts           => $r->{npts} // scalar(@$pts),
				color_abgr     => $r->{color},
				color_value    => $r->{color},
				bbox           => $cand_bbox,
				has_ts         => 0,
				has_depth      => 0,
				has_temp_k     => 0,
			};
		}
	}

	navDB::disconnectDB($dbh);
	return \@out;
}


sub enumerateFshCandidates
	# Reads $navFSH::fsh_db in-memory.  No DB.
{
	my ($obj_type, $subj_bbox) = @_;
	return [] if !$subj_bbox;
	my $db = $navFSH::fsh_db;
	return [] if !defined $db;

	my @out;
	my $pad = BBOX_PAD_DEG;
	my $padded_bbox = {
		min_lat => $subj_bbox->{min_lat} - $pad,
		max_lat => $subj_bbox->{max_lat} + $pad,
		min_lon => $subj_bbox->{min_lon} - $pad,
		max_lon => $subj_bbox->{max_lon} + $pad,
	};

	if ($obj_type eq 'waypoint')
	{
		# All FSH waypoints (standalone + group members), flattened.
		my %wps = %{$db->{waypoints} // {}};
		for my $grp (values %{$db->{groups} // {}})
		{
			for my $wp (@{$grp->{wpts} // []})
			{
				$wps{$wp->{uuid}} = $wp if $wp->{uuid};
			}
		}
		for my $uuid (keys %wps)
		{
			my $wp  = $wps{$uuid};
			my $lat = ($wp->{lat} // 0) + 0;
			my $lon = ($wp->{lon} // 0) + 0;
			next if $lat < $padded_bbox->{min_lat} || $lat > $padded_bbox->{max_lat};
			next if $lon < $padded_bbox->{min_lon} || $lon > $padded_bbox->{max_lon};
			push @out, {
				source         => 'fsh',
				uuid           => $uuid,
				obj_type       => 'waypoint',
				name           => $wp->{name} // '',
				hierarchy_path => 'FSH/Waypoints',
				lat            => $lat,
				lon            => $lon,
				npts           => 1,
				color_abgr     => undef,
				color_value    => undef,
				bbox           => { min_lat => $lat, max_lat => $lat,
				                    min_lon => $lon, max_lon => $lon },
				has_ts         => ($wp->{date} || $wp->{time}) ? 1 : 0,
				has_depth      => ($wp->{depth} // 0) > 0 ? 1 : 0,
				has_temp_k     => (($wp->{temp_k} // 0) > 0 && $wp->{temp_k} != 65535) ? 1 : 0,
			};
		}
	}
	elsif ($obj_type eq 'track')
	{
		my $tracks = $db->{tracks} // {};
		for my $uuid (keys %$tracks)
		{
			my $t = $tracks->{$uuid};
			my $pts = $t->{points} // [];
			next if !@$pts;
			my $cand_bbox = bboxOfPoints($pts);
			next if !$cand_bbox;
			next if !bboxOverlaps($cand_bbox, $padded_bbox);
			# FSH track points carry `depth` (uint32 cm) and `temp_k` (uint16
			# Kelvin*100) per BLK_TRK decode -- not the navMate-DB column
			# names depth_cm / temp_k.  Match the flag check to the actual
			# field names produced by FSH::fshBlocks::decodeTRK.
			my $has_depth = 0;
			my $has_temp  = 0;
			for my $p (@$pts)
			{
				$has_depth = 1 if ($p->{depth}  // 0) > 0;
				$has_temp  = 1 if (($p->{temp_k} // 0) > 0 && $p->{temp_k} != 65535);
				last if $has_depth && $has_temp;
			}
			push @out, {
				source         => 'fsh',
				uuid           => $uuid,
				obj_type       => 'track',
				name           => $t->{name} // '',
				hierarchy_path => 'FSH/Tracks',
				points         => $pts,
				npts           => $t->{cnt} // scalar(@$pts),
				color_abgr     => undef,
				color_value    => $t->{color},
				bbox           => $cand_bbox,
				has_ts         => 0,
				has_depth      => $has_depth,
				has_temp_k     => $has_temp,
			};
		}
	}
	elsif ($obj_type eq 'route')
	{
		my $routes = $db->{routes} // {};
		for my $uuid (keys %$routes)
		{
			my $r = $routes->{$uuid};
			my $wpts = $r->{wpts} // [];
			next if !@$wpts;
			my @pts = map { { lat => ($_->{lat}//0)+0, lon => ($_->{lon}//0)+0 } } @$wpts;
			my $cand_bbox = bboxOfPoints(\@pts);
			next if !$cand_bbox;
			next if !bboxOverlaps($cand_bbox, $padded_bbox);
			push @out, {
				source         => 'fsh',
				uuid           => $uuid,
				obj_type       => 'route',
				name           => $r->{name} // '',
				hierarchy_path => 'FSH/Routes',
				points         => \@pts,
				npts           => scalar(@pts),
				color_abgr     => undef,
				color_value    => $r->{color},
				bbox           => $cand_bbox,
				has_ts         => 0,
				has_depth      => 0,
				has_temp_k     => 0,
			};
		}
	}

	return \@out;
}


sub enumerateE80Candidates
	# Reads the live E80 device state via $raydp's WPMGR and TRACK services.
	# E80 waypoint lat/lon is stored as integer * 1e7 in WPMGR records;
	# scaled to decimal degrees here.  E80 track points are decimal degrees.
{
	my ($obj_type, $subj_bbox) = @_;
	return [] if !$subj_bbox;
	return [] if !$apps::raymarine::NET::c_RAYDP::raydp;
	my $raydp = $apps::raymarine::NET::c_RAYDP::raydp;

	my $wpmgr     = $raydp->findImplementedService('WPMGR', 1);
	my $track_mgr = $raydp->findImplementedService('TRACK', 1);

	my @out;
	my $pad = BBOX_PAD_DEG;
	my $padded_bbox = {
		min_lat => $subj_bbox->{min_lat} - $pad,
		max_lat => $subj_bbox->{max_lat} + $pad,
		min_lon => $subj_bbox->{min_lon} - $pad,
		max_lon => $subj_bbox->{max_lon} + $pad,
	};

	if ($obj_type eq 'waypoint' && $wpmgr)
	{
		my $wps    = $wpmgr->{waypoints} // {};
		my $groups = $wpmgr->{groups}    // {};
		my %wp_group;
		for my $g_uuid (keys %$groups)
		{
			my $g = $groups->{$g_uuid};
			for my $w_uuid (@{$g->{uuids} // []})
			{
				$wp_group{$w_uuid} = $g->{name} // '';
			}
		}
		for my $uuid (keys %$wps)
		{
			my $wp  = $wps->{$uuid};
			my $lat = (($wp->{lat} // 0) + 0) / 1e7;
			my $lon = (($wp->{lon} // 0) + 0) / 1e7;
			next if $lat < $padded_bbox->{min_lat} || $lat > $padded_bbox->{max_lat};
			next if $lon < $padded_bbox->{min_lon} || $lon > $padded_bbox->{max_lon};
			my $group_name = $wp_group{$uuid};
			push @out, {
				source         => 'e80',
				uuid           => $uuid,
				obj_type       => 'waypoint',
				name           => $wp->{name} // '',
				hierarchy_path => $group_name ? "E80/Groups/$group_name" : 'E80/My Waypoints',
				lat            => $lat,
				lon            => $lon,
				npts           => 1,
				color_abgr     => undef,
				color_value    => undef,
				bbox           => { min_lat => $lat, max_lat => $lat,
				                    min_lon => $lon, max_lon => $lon },
				has_ts         => ($wp->{date} || $wp->{time}) ? 1 : 0,
				has_depth      => ($wp->{depth}  // 0) > 0 ? 1 : 0,
				has_temp_k     => (($wp->{temp_k} // 0) > 0 && $wp->{temp_k} != 65535) ? 1 : 0,
			};
		}
	}
	elsif ($obj_type eq 'route' && $wpmgr)
	{
		my $routes = $wpmgr->{routes}    // {};
		my $wps    = $wpmgr->{waypoints} // {};
		for my $uuid (keys %$routes)
		{
			my $r = $routes->{$uuid};
			my @pts;
			for my $wp_uuid (@{$r->{uuids} // []})
			{
				my $wp = $wps->{$wp_uuid};
				next if !$wp;
				push @pts, {
					lat => (($wp->{lat} // 0) + 0) / 1e7,
					lon => (($wp->{lon} // 0) + 0) / 1e7,
				};
			}
			next if !@pts;
			my $cand_bbox = bboxOfPoints(\@pts);
			next if !$cand_bbox;
			next if !bboxOverlaps($cand_bbox, $padded_bbox);
			push @out, {
				source         => 'e80',
				uuid           => $uuid,
				obj_type       => 'route',
				name           => $r->{name} // '',
				hierarchy_path => 'E80/Routes',
				points         => \@pts,
				npts           => scalar(@pts),
				color_abgr     => undef,
				color_value    => $r->{color},
				bbox           => $cand_bbox,
				has_ts         => 0,
				has_depth      => 0,
				has_temp_k     => 0,
			};
		}
	}
	elsif ($obj_type eq 'track' && $track_mgr)
	{
		my $tracks = $track_mgr->{tracks} // {};
		for my $uuid (keys %$tracks)
		{
			my $t = $tracks->{$uuid};
			my $pts = $t->{points} // [];
			next if !@$pts;
			my $cand_bbox = bboxOfPoints($pts);
			next if !$cand_bbox;
			next if !bboxOverlaps($cand_bbox, $padded_bbox);
			# E80 TRACK points carry `depth` (uint32 cm) and `temp_k`
			# (uint16 Kelvin*100) per b_records.pm point layout -- not
			# the navMate-DB column names depth_cm / temp_k.
			my $has_depth = 0;
			my $has_temp  = 0;
			for my $p (@$pts)
			{
				$has_depth = 1 if ($p->{depth}  // 0) > 0;
				$has_temp  = 1 if (($p->{temp_k} // 0) > 0 && $p->{temp_k} != 65535);
				last if $has_depth && $has_temp;
			}
			push @out, {
				source         => 'e80',
				uuid           => $uuid,
				obj_type       => 'track',
				name           => $t->{name} // '',
				hierarchy_path => 'E80/Tracks',
				points         => $pts,
				npts           => scalar(@$pts),
				color_abgr     => $t->{color},
				color_value    => $t->{color},
				bbox           => $cand_bbox,
				has_ts         => 0,
				has_depth      => $has_depth,
				has_temp_k     => $has_temp,
			};
		}
	}

	return \@out;
}


1;
