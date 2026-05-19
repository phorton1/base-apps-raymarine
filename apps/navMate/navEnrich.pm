#!/usr/bin/perl
#------------------------------------------
# navEnrich.pm
#------------------------------------------
# Per-pair, per-field enrichment of navMate DB tracks from FSH or E80 source
# data (and optionally from other DB tracks).  Used by winFind's per-row
# context menu.
#
# Architecture: the navMate database is ALWAYS the enrichment destination.
# FSH and E80 are lossy transports (per navops hub-and-spoke); they can act
# as a source of depth/temp data the DB is missing, but they are never
# enriched themselves.  DB->DB enrichment is allowed when one DB track has
# depth/temp the other lacks (both source and destination are the same
# storage, so direction is the only thing that matters).
#
# Three public entry points:
#
#   canEnrich($subj_cand, $other_cand, $match)
#     Cheap.  Returns an arrayref of { field, direction } items that COULD
#     be offered for this pair, based purely on:
#       - match tier (none/near excluded)
#       - object types (track only in v1)
#       - DB-as-destination rule (at least one side must be 'db')
#       - has_X flag on the source side
#     Does no per-point walking.  Callers run planEnrichment() to get the
#     counts that decide whether the menu item should actually appear.
#
#   planEnrichment($subj_cand, $other_cand, $match, $field, $direction)
#     Medium cost: one walk over the alignment cells.  Returns a $plan
#     hash with per-point change list and { enrich, update, agree, skip }
#     counts.  The change list is the input to applyEnrichment.  No
#     mutation here.
#
#   applyEnrichment($plan)
#     Performs the writeback.  Dispatches to navDB::updateTrackPointFields
#     and bumps tracks.modified_ts via that function's own internal txn.
#     Returns (1, undef) on success or (0, $err_string).
#
# Field handling
# --------------
# Logical field names are 'depth' and 'temp_k' (and later 'ts', deferred).
# Source-side point field names differ by transport:
#
#   logical  | DB column / point key | FSH point key | E80 point key
#   ---------+-----------------------+---------------+---------------
#   depth    | depth_cm              | depth         | depth
#   temp_k   | temp_k                | temp_k        | temp_k
#   ts       | ts                    | (n/a)         | (n/a)
#
# Destination is always DB, so writes always use the DB column name; the
# source side is resolved via _readField($source, $point, $logical_field).
#
# Alignment
# ---------
# Exact tier: match->matched_window is contiguous and 1:1.  Walk it.
# Match tier (DTW): match->steps carries per-cell { subj_idx, cand_idx, tb }
# in original-index space.  For each destination index that appears on the
# path, pick the diagonal cell if present (tb==0), otherwise the lowest-cost
# cell; that gives one source value per destination point regardless of
# warping shape.
# Near tier is excluded -- geographic looseness makes confident per-point
# transfer untrustworthy.
#
# Anomaly shape is permitted on EXACT (the matched window is still 1:1);
# winFind surfaces it in the confirm dialog so the user reviews before
# committing.

package navEnrich;
use strict;
use warnings;
use Pub::Utils qw(display warning error);
use navDB;


BEGIN
{
	use Exporter qw(import);
	our @EXPORT_OK = qw(
		canEnrich
		planEnrichment
		applyEnrichment
	);
}


# Field-name resolution for reading from each source's in-memory point hash.
# Destination is always DB so write column names are the DB column directly
# (see _dbColumn).
my %SOURCE_FIELD = (
	db  => { depth => 'depth_cm', temp_k => 'temp_k', ts => 'ts' },
	fsh => { depth => 'depth',    temp_k => 'temp_k' },
	e80 => { depth => 'depth',    temp_k => 'temp_k' },
);

# Logical field -> DB column name for writes.
my %DB_COLUMN = (
	depth  => 'depth_cm',
	temp_k => 'temp_k',
	ts     => 'ts',
);

# Logical field -> has_X flag name on the candidate hash (set by
# enumerateDbCandidates / enumerateFshCandidates / enumerateE80Candidates).
my %HAS_FLAG = (
	depth  => 'has_depth',
	temp_k => 'has_temp_k',
	ts     => 'has_ts',
);

# v1 logical fields offered for track enrichment.  'ts' is deferred --
# its "different" rule needs more work (hand-derived 00:00:00 placeholders
# vs device-recorded second-precision values are not a plain equality test).
my @V1_FIELDS = qw(depth temp_k);


#---------------------------------
# canEnrich
#---------------------------------

sub canEnrich
{
	my ($subj_cand, $other_cand, $match) = @_;
	return [] if !$subj_cand || !$other_cand || !$match;

	my $tier = $match->{tier} // 'none';
	return [] if $tier eq 'none';
	# 'near' is allowed: it's the classifier for "same trip, different
	# recording" -- coordinates aren't within EXACT_DEG of each other
	# (often a KML round-trip rounded them past the 0.55m threshold) but
	# the curves trace the same path with high coverage.  DTW alignment
	# via match->{steps} handles per-point transfer correctly for these.
	# winFind itself filters near-tier rows by coverage before showing
	# them, so anything reaching here is already coverage-qualified.

	# Per-point enrichment is tracks-only in v1.
	return [] if ($subj_cand->{obj_type}  // '') ne 'track';
	return [] if ($other_cand->{obj_type} // '') ne 'track';

	my $subj_src  = $subj_cand->{source}  // '';
	my $other_src = $other_cand->{source} // '';

	# DB-as-destination rule: at least one side must be DB.  No FSH<->E80,
	# no FSH<->FSH, no E80<->E80 enrichment.
	return [] if $subj_src ne 'db' && $other_src ne 'db';

	my @items;
	for my $field (@V1_FIELDS)
	{
		my $flag = $HAS_FLAG{$field};

		# direction='to_subj': source flows from other into subject.
		# Destination is subject; subject must be DB.  Source must have
		# the field populated somewhere.
		if ($subj_src eq 'db' && $other_cand->{$flag})
		{
			push @items, { field => $field, direction => 'to_subj' };
		}

		# direction='to_other': source flows from subject into other.
		# Destination is other; other must be DB.
		if ($other_src eq 'db' && $subj_cand->{$flag})
		{
			push @items, { field => $field, direction => 'to_other' };
		}
	}

	return \@items;
}


#---------------------------------
# planEnrichment
#---------------------------------

sub planEnrichment
{
	my ($subj_cand, $other_cand, $match, $field, $direction) = @_;
	return undef if !$subj_cand || !$other_cand || !$match || !$field || !$direction;

	my ($src_cand, $dst_cand);
	if ($direction eq 'to_subj')
	{
		$src_cand = $other_cand;
		$dst_cand = $subj_cand;
	}
	elsif ($direction eq 'to_other')
	{
		$src_cand = $subj_cand;
		$dst_cand = $other_cand;
	}
	else
	{
		error("navEnrich::planEnrichment unknown direction '$direction'");
		return undef;
	}

	if (($dst_cand->{source} // '') ne 'db')
	{
		error("navEnrich::planEnrichment destination must be db (got '$dst_cand->{source}')");
		return undef;
	}

	my $src_pts = $src_cand->{points} // [];
	my $dst_pts = $dst_cand->{points} // [];
	return undef if !@$src_pts || !@$dst_pts;

	# Build dst_idx -> src_idx pair list from the alignment.
	my @pairs = _alignmentPairs($match, $direction);
	return undef if !@pairs;

	my $src_source = $src_cand->{source} // '';

	my @changes;
	my %counts = (enrich => 0, update => 0, agree => 0, skip => 0);

	for my $pair (@pairs)
	{
		my $src_p = $src_pts->[$pair->{src_idx}];
		my $dst_p = $dst_pts->[$pair->{dst_idx}];
		next if !$src_p || !$dst_p;

		my $src_val = _readField($src_source, $src_p, $field);
		my $dst_val = _readField('db',        $dst_p, $field);

		if (!_isPresent($src_val, $field))
		{
			$counts{skip}++;
			next;
		}
		if (!_isPresent($dst_val, $field))
		{
			$counts{enrich}++;
			push @changes, {
				position => $pair->{dst_idx},
				new_val  => $src_val,
				old_val  => undef,
			};
		}
		elsif ($src_val == $dst_val)
		{
			$counts{agree}++;
		}
		else
		{
			$counts{update}++;
			push @changes, {
				position => $pair->{dst_idx},
				new_val  => $src_val,
				old_val  => $dst_val,
			};
		}
	}

	return {
		field      => $field,
		direction  => $direction,
		tier       => $match->{tier},
		shape      => $match->{shape},
		src_descr  => _describe($src_cand),
		dst_descr  => _describe($dst_cand),
		dst_source => $dst_cand->{source},
		dst_uuid   => $dst_cand->{uuid},
		dst_name   => $dst_cand->{name},
		changes    => \@changes,
		counts     => \%counts,
	};
}


#---------------------------------
# applyEnrichment
#---------------------------------

sub applyEnrichment
{
	my ($plan) = @_;
	return (0, "no plan")          if !$plan;
	return (1, undef)              if !@{$plan->{changes} // []};

	if (($plan->{dst_source} // '') ne 'db')
	{
		return (0, "destination must be db (got '" . ($plan->{dst_source} // '') . "')");
	}

	my $field  = $plan->{field};
	my $column = $DB_COLUMN{$field};
	if (!$column)
	{
		return (0, "unknown logical field '$field'");
	}

	my $dbh = navDB::connectDB();
	return (0, "could not connect to navMate DB") if !$dbh;

	my $count = navDB::updateTrackPointFields(
		$dbh, $plan->{dst_uuid}, $column, $plan->{changes});

	navDB::disconnectDB($dbh);

	if (!$count)
	{
		return (0, "updateTrackPointFields wrote 0 rows");
	}

	display(0, 0, sprintf(
		"navEnrich applied: %s %s -> %s (%d points)",
		$field, $plan->{src_descr}, $plan->{dst_descr}, $count));

	return (1, undef);
}


#---------------------------------
# alignment
#---------------------------------

sub _alignmentPairs
{
	# Returns list of { src_idx, dst_idx } in destination-index order.
	# direction tells us which side of the matched_window / steps array
	# is source vs destination:
	#   to_subj  -- src = candidate (cand_idx / j), dst = subject (subj_idx / i)
	#   to_other -- src = subject  (subj_idx / i), dst = candidate (cand_idx / j)
	my ($match, $direction) = @_;
	my $tier = $match->{tier} // '';

	if ($tier eq 'exact')
	{
		my $mw = $match->{matched_window};
		return () if !$mw;
		my ($i_start, $i_end, $j_start, $j_end) = @$mw;
		my $len = $i_end - $i_start + 1;
		return () if $len < 1;

		my @pairs;
		for my $k (0 .. $len - 1)
		{
			if ($direction eq 'to_subj')
			{
				# src is cand (j), dst is subj (i)
				push @pairs, {
					src_idx => $j_start + $k,
					dst_idx => $i_start + $k,
				};
			}
			else
			{
				push @pairs, {
					src_idx => $i_start + $k,
					dst_idx => $j_start + $k,
				};
			}
		}
		return @pairs;
	}

	if ($tier eq 'match' || $tier eq 'near')
	{
		# DTW: walk steps; for each destination index, keep the best cell.
		# Both 'match' and 'near' tiers produce steps; the tier name is
		# only the median-cost classifier, not a structural difference in
		# the alignment data.
		# Diagonal cells (tb==0) beat off-diagonal regardless of cost; among
		# off-diagonal cells, lower cost wins.  This gives every dst point
		# in the matched window exactly one source value, and replicates a
		# single src value across multiple dst points when the path went
		# horizontal (one source, many destinations).
		my $steps = $match->{steps} // [];
		return () if !@$steps;

		my %best;  # dst_idx -> { src_idx, score }
		for my $st (@$steps)
		{
			my $tb = $st->{tb} // -1;
			next if $tb == 3 || $tb < 0;     # START sentinel / invalid

			my ($src_idx, $dst_idx);
			if ($direction eq 'to_subj')
			{
				$src_idx = $st->{cand_idx};
				$dst_idx = $st->{subj_idx};
			}
			else
			{
				$src_idx = $st->{subj_idx};
				$dst_idx = $st->{cand_idx};
			}
			next if !defined($src_idx) || !defined($dst_idx);

			# Lower score wins.  Diagonal cells get -1 to always beat any
			# non-negative off-diagonal cost.
			my $score = ($tb == 0) ? -1 : ($st->{cost} // 0);
			my $prev  = $best{$dst_idx};
			if (!$prev || $score < $prev->{score})
			{
				$best{$dst_idx} = { src_idx => $src_idx, score => $score };
			}
		}

		my @pairs;
		for my $dst_idx (sort { $a <=> $b } keys %best)
		{
			push @pairs, {
				src_idx => $best{$dst_idx}{src_idx},
				dst_idx => $dst_idx,
			};
		}
		return @pairs;
	}

	return ();
}


#---------------------------------
# field access / presence
#---------------------------------

sub _readField
{
	# Returns the raw stored value or undef.  Caller decides presence
	# semantics via _isPresent (depth/temp use >0; ts uses defined).
	my ($source, $point, $logical_field) = @_;
	return undef if !$point;
	my $map = $SOURCE_FIELD{$source};
	return undef if !$map;
	my $key = $map->{$logical_field};
	return undef if !$key;
	return $point->{$key};
}


sub _isPresent
{
	# Per-field sentinel rules:
	#   depth  -- the int16 sentinel is exactly -1 ("no reading").  Any
	#             other value (including 0 and other negatives) is treated
	#             as a real reading; this matches Patrick's data
	#             ("depth === -1 is the sentinel value, not depth < 0").
	#   temp_k -- uint16 sentinel is 0xFFFF (65535); 0 is also not a
	#             physical Kelvin*100 reading so treat as absent.
	#   ts     -- defined and truthy (epoch second).
	my ($val, $field) = @_;
	return 0 if !defined $val;

	if ($field eq 'depth')
	{
		my $n = $val + 0;
		return ($n == -1) ? 0 : 1;
	}
	if ($field eq 'temp_k')
	{
		my $n = $val + 0;
		return ($n > 0 && $n != 65535) ? 1 : 0;
	}
	if ($field eq 'ts')
	{
		return $val ? 1 : 0;
	}
	return 0;
}


sub _describe
{
	my ($cand) = @_;
	my $src = uc($cand->{source} // '');
	my $nm  = $cand->{name} // '(unnamed)';
	return "$src:$nm";
}


1;
