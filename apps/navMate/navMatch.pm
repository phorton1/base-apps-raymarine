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
# Tracks/routes are scored with Subsequence Dynamic Time Warping (DTW)
# under a Sakoe-Chiba band.  The label has two orthogonal axes:
#
#   tier    -- MEDIAN per-step cost decides which family:
#              median <= EXACT_DEG, ~no warping -> 'exact' (same trip, 1:1 alignment)
#              median <= EXACT_DEG, warping     -> 'match' (same shape, different sample rate)
#              median >  EXACT_DEG              -> 'near'  (same channel, different recording)
#              Median (not mean) so that a few high-cost chord-corner
#              cells don't pull a same-trip pair into the 'near' tier.
#              "~no warping" tolerates a small absolute count of
#              horizontal/vertical steps (decimation isn't deterministic
#              across nearly-identical tracks; allow a tiny tolerance).
#
#   pattern -- shape of the unmatched portions on each side, by point count:
#              full     -- 0 trim on both sides
#              trimmed  -- small trim on both sides (symmetric agreement
#                          on what to keep)
#              subset   -- small subj trim, large cand trim (subject is a
#                          sub-section of candidate)
#              superset -- large subj trim, small cand trim
#              partial  -- large trim on both sides with a middle match
#
# A 'full' pattern collapses to just the tier name ('exact' / 'match' /
# 'near'); other patterns suffix the tier:  'exact-trimmed',
# 'match-subset', 'near-partial', etc.  15 labels total plus 'none'.
#
# Stage by stage:
#
#   1. Bobbing decimation -- consecutive points within ~2 m (anchor
#      bobbing) collapse to a single representative.  Anchor bobbing
#      can be 88% of a recorded track's points and almost 0% of its
#      path length; carrying it into DTW catastrophically distorts band
#      sizing when the two sides preserve different amounts of bobbing.
#   2. bbox prefilter (cheap eliminator).
#   3. Constant-offset detection -- the lat_shift class seen in 2011-era
#      Michelle data resolves cleanly to an exact match if the median
#      (delta-lat, delta-lon) offset across seed-matches is applied.
#      Detected internally; no separate user-visible label.
#   4. Per-point path-length weights -- each point gets half(prev gap) +
#      half(next gap).  After decimation these are mostly uniform; the
#      weighting still pays off when one side has a denser under-way
#      sampling than the other.
#   5. DP over an N x M grid, banded around the rescaled diagonal
#      (j ~ i * M / N).  Free start on row 0 or col 0, free end on
#      the last row or last col -- the "subsequence" variant that lets
#      the matched window be a sub-range of either side.  Cell cost is
#      point-to-point distance in lat/lon space (with segment refinement
#      for sample-rate mismatches), with raw distance > DTW_PRUNE_DEG pruned to
#      +inf so the path can propagate past compression-induced chord
#      gaps.  Vertical/horizontal moves carry STEP_PENALTY so that
#      segment refinement doesn't flip the walkback away from a true
#      1:1 alignment in same-rate cases.
#   6. Walkback from the best end cell finds [i_start, i_end, j_start,
#      j_end] plus warp pattern statistics.
#   7. _classifyDTW picks the tier (from avg step cost), picks the
#      pattern (from trim sizes), composes the label, and computes a
#      path-length-WEIGHTED coverage score on the decimated points.
#
# Waypoints use a simple exact-only test: distance <= EXACT_DEG is 'exact';
# otherwise 'none'.  There is no per-waypoint bbox concept.
#
# Reverse-direction matching and the gap-pattern 'exact-gapped' label
# are reserved in the label vocabulary but not emitted by this iteration
# (see project memory winfind_future_items.md for the toolbar checkbox
# that re-runs with reverse enabled).
#
# Return shape (stable across iterations, consumed by winFind and future
# enrichment actions):
#
#   {
#     label          => one of the strings above,
#     score          => 0.0 .. 1.0 (path-length-weighted coverage, averaged),
#     fwd_match      => weighted subj-side coverage of matched window,
#     rev_match      => weighted cand-side coverage of matched window,
#     matched_window => [subj_start, subj_end, cand_start, cand_end],
#   }

package navMatch;
use strict;
use warnings;
use Pub::Utils qw(display warning error);
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
# DTW_PRUNE_DEG used only inside _subsequenceDTW to mark a cell as
#              unreachable.  Looser than BBOX_PAD_DEG so the DP can
#              propagate past compression-induced chord gaps where
#              a chord-error briefly exceeds the bbox-padding scale.
# STEP_PENALTY tiny additive penalty on vertical/horizontal DP moves.
#              Breaks ties in favor of diagonal (1:1) when segment-
#              refinement makes off-diagonal cells numerically as cheap
#              as diagonal cells in same-rate cases.
use constant {
	EXACT_DEG     => 0.000005,    # ~0.55 m -- coord-conversion precision
	BBOX_PAD_DEG  => 0.0005,      # ~55 m   -- bbox prefilter padding
	DTW_PRUNE_DEG => 0.005,       # ~555 m  -- DP cell-distance cutoff
	STEP_PENALTY  => 0.0000005,   # ~5.5 cm -- diagonal-bias tiebreaker
	BOBBING_DEG   => 0.000018,    # ~2 m    -- bobbing decimation threshold
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
			label          => 'exact',
			score          => 1.0,
			fwd_match      => 1,
			rev_match      => 1,
			matched_window => undef,
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
	# Subject and candidate are arrays of { lat, lon, ... } point hashes.
	# Subsequence DTW under a Sakoe-Chiba band; see top-of-file comment.

	my ($subj_pts, $cand_pts) = @_;
	return _empty_result() if !$subj_pts || !@$subj_pts;
	return _empty_result() if !$cand_pts || !@$cand_pts;

	# 1.  Bobbing decimation.  Tracks recorded by chartplotters typically
	# include long anchor-bobbing clusters (88% of points in track 1 of
	# our test data were inside ~30 m of anchorage).  Decimating these
	# down to single representative points before DTW does three things
	# at once: drops grid size by 5-10x (perf), fixes Sakoe-Chiba band
	# sizing (slope no longer wildly distorted by asymmetric bobbing
	# between subject and candidate), and removes the source of avg-
	# step-cost inflation that was pushing same-trip pairs into the
	# 'near' tier when one side preserved bobbing and the other didn't.
	$subj_pts = _decimateBobbing($subj_pts);
	$cand_pts = _decimateBobbing($cand_pts);

	my $n = scalar @$subj_pts;
	my $m = scalar @$cand_pts;
	return _empty_result() if $n < 2 || $m < 2;
	return _empty_result() if $n * $m > DTW_MAX_CELLS;

	# 2. Bbox prefilter.
	my $sb = bboxOfPoints($subj_pts);
	my $cb = bboxOfPoints($cand_pts);
	return _empty_result() if !bboxOverlaps($sb, $cb);

	# 3. Constant-offset detection.  Resolves the lat_shift class to an
	# in-tolerance match by subtracting the median (dlat, dlon) when the
	# offset is meaningful.  When the offset is too small to matter the
	# helper returns (0, 0) and we proceed unmodified.
	my ($off_lat, $off_lon) = _detectConstantOffset($subj_pts, $cand_pts);

	# 4.  Per-point path-length weights, on the decimated points.  After
	# decimation these are roughly uniform; weights still flow through
	# because they handle any residual sample-density mismatch the
	# decimation didn't level out (e.g., a candidate that's denser than
	# subject within the under-way region).
	my $subj_weights = _computePointWeights($subj_pts);
	my $cand_weights = _computePointWeights($cand_pts);

	# 5.  Subsequence DTW with band + distance prune, walkback.
	my $dtw = _subsequenceDTW($subj_pts, $cand_pts, $off_lat, $off_lon);
	return _empty_result() if !$dtw;

	# 6.  Classify (tier x pattern) and compute weighted score.  Note:
	# matched_window indices are in DECIMATED-point space, not original
	# track_point positions.  Acceptable for v2; future enrichment work
	# will need a back-mapping (see winfind_future_items.md).
	return _classifyDTW($dtw, $n, $m, $subj_weights, $cand_weights);
}


sub _decimateBobbing
{
	# Collapse consecutive-close-together points (bobbing at anchor) down
	# to a single representative.  Walks the input; keeps a point only
	# when it's at least BOBBING_DEG (~2 m) from the most recently kept
	# point.  First and last points are always preserved.
	#
	# This filter has nothing to do with GPS quality or smoothing -- it
	# only addresses the structural problem that DTW alignment of two
	# tracks differs catastrophically when one preserves anchor bobbing
	# and the other doesn't.  At 0.3 kt and a typical 5-second sample
	# interval, samples are 0.75 m apart -- below threshold.  At drift-
	# sailing speed (~2 kt) samples are ~5 m apart -- well above.

	my ($pts) = @_;
	my $n = scalar @$pts;
	return [@$pts] if $n < 3;

	my @keep;
	push @keep, $pts->[0];
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
			push @keep, $pts->[$i];
			$last_lat = $pts->[$i]{lat} // 0;
			$last_lon = $pts->[$i]{lon} // 0;
		}
	}
	push @keep, $pts->[$n - 1];
	return \@keep;
}


sub _computePointWeights
{
	# Path-length-integral weight for each point: half the distance to its
	# previous neighbor plus half the distance to its next neighbor.  Sum
	# over all points = total recorded path length.  Anchor-bobbing
	# clusters contribute near-zero weight per point; under-way samples
	# contribute their inter-sample distance.  Out-and-back trips are
	# handled correctly (it's a path-length integral, not a displacement).
	#
	# Distances are in degrees -- same scalar units as the DTW costs.
	# Endpoints get just one half-gap (the side they have).

	my ($pts) = @_;
	my $n = scalar @$pts;
	my @w = (0) x $n;
	return \@w if $n < 2;

	# Precompute gap[i] = distance from pts[i] to pts[i+1].
	my @gap;
	$#gap = $n - 2;
	for (my $i = 0; $i < $n - 1; $i++)
	{
		my $dlat = ($pts->[$i+1]{lat} // 0) - ($pts->[$i]{lat} // 0);
		my $dlon = ($pts->[$i+1]{lon} // 0) - ($pts->[$i]{lon} // 0);
		$gap[$i] = sqrt($dlat * $dlat + $dlon * $dlon);
	}

	$w[0]      = $gap[0] / 2;
	$w[$n - 1] = $gap[$n - 2] / 2;
	for (my $i = 1; $i < $n - 1; $i++)
	{
		$w[$i] = ($gap[$i - 1] + $gap[$i]) / 2;
	}
	return \@w;
}


sub _empty_result
{
	return {
		label          => 'none',
		score          => 0,
		fwd_match      => 0,
		rev_match      => 0,
		matched_window => undef,
	};
}


#---------------------------------
# DTW machinery (private)
#---------------------------------

sub _detectConstantOffset
{
	# Sample up to K subject points evenly across the subject.  For each,
	# find the nearest candidate point within BBOX_PAD_DEG and record the
	# (dlat, dlon) pair.  The MEDIAN of those pairs, if it is itself larger
	# than EXACT_DEG/2 in magnitude, is returned as the offset to apply to
	# candidate coordinates during DP.  Median (not mean) so that a few
	# non-matching seeds don't pull the offset off the constant.  Returns
	# (0, 0) when no meaningful offset is detected.
	my ($a_pts, $b_pts) = @_;
	my $n_a = scalar @$a_pts;
	my $n_b = scalar @$b_pts;
	return (0, 0) if $n_a < 2 || $n_b < 2;

	my $K = 20;
	$K = $n_a if $n_a < $K;
	my $denom = $K > 1 ? $K - 1 : 1;
	my $near = BBOX_PAD_DEG;
	my $near_sq = $near * $near;

	my @d_lats;
	my @d_lons;
	for (my $k = 0; $k < $K; $k++)
	{
		my $i = int($k * ($n_a - 1) / $denom);
		my $alat = $a_pts->[$i]{lat} // 0;
		my $alon = $a_pts->[$i]{lon} // 0;
		my $best_d2   = $near_sq + 1;
		my $best_dlat = 0;
		my $best_dlon = 0;
		for my $b (@$b_pts)
		{
			my $dlat = ($b->{lat} // 0) - $alat;
			next if abs($dlat) > $near;
			my $dlon = ($b->{lon} // 0) - $alon;
			next if abs($dlon) > $near;
			my $d2 = $dlat * $dlat + $dlon * $dlon;
			if ($d2 < $best_d2)
			{
				$best_d2   = $d2;
				$best_dlat = $dlat;
				$best_dlon = $dlon;
			}
		}
		if ($best_d2 <= $near_sq)
		{
			push @d_lats, $best_dlat;
			push @d_lons, $best_dlon;
		}
	}

	return (0, 0) if scalar(@d_lats) < 5;

	@d_lats = sort { $a <=> $b } @d_lats;
	@d_lons = sort { $a <=> $b } @d_lons;
	my $med_lat = $d_lats[int(@d_lats / 2)];
	my $med_lon = $d_lons[int(@d_lons / 2)];

	my $half_exact = EXACT_DEG / 2;
	if (abs($med_lat) < $half_exact && abs($med_lon) < $half_exact)
	{
		return (0, 0);
	}
	# We will SUBTRACT the offset from candidate coords during DP, so
	# return the offset to add to candidate to align it with subject:
	# subj ~ cand + offset  =>  offset = subj - cand = -(cand - subj) = -median
	# Median was computed as (cand - subj); flip the sign.
	return (-$med_lat, -$med_lon);
}


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

			# Refine cell cost with point-to-segment when point-to-point
			# is loose -- this is what makes sample-rate-mismatched
			# alignment possible.  We consider the segment ending at
			# cand[j] (handles dense-candidate / sparse-subject) and the
			# segment ending at subj[i] (handles dense-subject / sparse-
			# candidate).  Both directions; the DP picks whichever side
			# warps to fit.
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
	# Compose a label from two orthogonal axes:
	#
	#   tier    = MEDIAN per-step cost <= EXACT_DEG => same-trip family
	#             within same-trip, ~no warping  => 'exact'
	#             within same-trip, has warping  => 'match'
	#             median above EXACT_DEG         => 'near'
	#
	#   pattern = unmatched-trim shape on each side, by POINT count:
	#             full     -- 0 trim on both sides
	#             trimmed  -- small trim on both sides (symmetric)
	#             subset   -- small subj trim, large cand trim (subject is a
	#                         sub-section of candidate)
	#             superset -- large subj trim, small cand trim
	#             partial  -- large trim on both sides with a middle match
	#
	# "Small" trim is <= 5 points OR <= 5% of that side, whichever is larger.
	# 'full' collapses to the bare tier name ('exact' / 'match' / 'near');
	# the other patterns suffix the tier with '-trimmed', '-subset', etc.
	#
	# Score is PATH-LENGTH-WEIGHTED coverage on the decimated points --
	# what fraction of each side's under-way length is inside the matched
	# window.

	my ($dtw, $n, $m, $subj_weights, $cand_weights) = @_;
	return _empty_result() if !$dtw;

	my $i_start = $dtw->{i_start};
	my $i_end   = $dtw->{i_end};
	my $j_start = $dtw->{j_start};
	my $j_end   = $dtw->{j_end};

	# Tier decision: MEDIAN step cost.  Median (not mean) so that a small
	# number of high-cost cells (chord-corner residuals between a
	# compressed track and its raw counterpart) don't pull the
	# discriminator above EXACT_DEG when the majority of cells along the
	# matched path are well-aligned.
	#
	#   median <= EXACT_DEG, ~no warping -> 'exact' (same trip, 1:1)
	#   median <= EXACT_DEG, warping     -> 'match' (same shape, different sample rate)
	#   median >  EXACT_DEG              -> 'near'  (same channel, different recording)
	#
	# "~no warping" tolerates a small number of horizontal/vertical steps:
	# decimation isn't deterministic across nearly-identical tracks (the
	# 2 m threshold can flip individual keep/skip decisions when the
	# precision delta straddles it), so a 354-vs-355 alignment is still
	# semantically 'exact' even though the DP introduced one warp step.

	my $L = scalar @{$dtw->{steps}};
	my @step_costs = map { $_->{cost} } @{$dtw->{steps}};
	my @sorted_costs = sort { $a <=> $b } @step_costs;
	my $median_step = ($L > 0) ? $sorted_costs[int(@sorted_costs / 2)] : $INF;

	my $tier;
	if ($median_step <= EXACT_DEG)
	{
		my $warp_count = $dtw->{n_horiz} + $dtw->{n_vert};
		my $tiny_warp = ($warp_count <= 5 || $warp_count <= 0.05 * $L);
		$tier = $tiny_warp ? 'exact' : 'match';
	}
	else
	{
		$tier = 'near';
	}

	# Pattern decision: point-count trim sizes.
	my $subj_trim = $i_start + ($n - 1 - $i_end);
	my $cand_trim = $j_start + ($m - 1 - $j_end);
	my $small_subj = ($subj_trim <= 5 || $subj_trim <= 0.05 * $n);
	my $small_cand = ($cand_trim <= 5 || $cand_trim <= 0.05 * $m);

	my $pattern;
	if ($small_subj && $small_cand)
	{
		$pattern = ($subj_trim == 0 && $cand_trim == 0) ? 'full' : 'trimmed';
	}
	elsif ($small_subj && !$small_cand)
	{
		$pattern = 'subset';
	}
	elsif (!$small_subj && $small_cand)
	{
		$pattern = 'superset';
	}
	else
	{
		$pattern = 'partial';
	}

	my $label = ($pattern eq 'full') ? $tier : "$tier-$pattern";

	# Weighted score: sum-of-weights inside matched window over total weight.
	# Falls back to point-count coverage when weights are unavailable.
	my ($fwd, $rev);
	if ($subj_weights && $cand_weights)
	{
		my $subj_total = 0; $subj_total += $_ for @$subj_weights;
		my $cand_total = 0; $cand_total += $_ for @$cand_weights;
		my $subj_matched = 0;
		for (my $i = $i_start; $i <= $i_end; $i++)
		{
			$subj_matched += $subj_weights->[$i];
		}
		my $cand_matched = 0;
		for (my $j = $j_start; $j <= $j_end; $j++)
		{
			$cand_matched += $cand_weights->[$j];
		}
		$fwd = ($subj_total > 0) ? ($subj_matched / $subj_total) : 0;
		$rev = ($cand_total > 0) ? ($cand_matched / $cand_total) : 0;
	}
	else
	{
		$fwd = ($i_end - $i_start + 1) / $n;
		$rev = ($j_end - $j_start + 1) / $m;
	}
	my $score = ($fwd + $rev) / 2;

	return {
		label          => $label,
		score          => $score,
		fwd_match      => $fwd,
		rev_match      => $rev,
		matched_window => [$i_start, $i_end, $j_start, $j_end],
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
#   wp_type        -- 'nav' | 'label' | 'sounding' (waypoints only)


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
				wp_type        => $r->{wp_type} // 'nav',
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
			my $has_depth = 0;
			my $has_temp  = 0;
			for my $p (@$pts)
			{
				$has_depth = 1 if ($p->{depth_cm} // 0) > 0;
				$has_temp  = 1 if ($p->{temp_k}   // 0) > 0;
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
			my $has_depth = 0;
			my $has_temp  = 0;
			for my $p (@$pts)
			{
				$has_depth = 1 if ($p->{depth_cm} // 0) > 0;
				$has_temp  = 1 if ($p->{temp_k}   // 0) > 0;
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
