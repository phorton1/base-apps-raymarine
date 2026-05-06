#---------------------------------------------
# nmOldE80.pm
#---------------------------------------------
# Analyzes oldE80 tracks against the rest of navMate,
# finds novel segments, and inserts them as a new
# 'E80 Residue' top-level branch in the DB.
#
# APPROACH: per-segment strand matching.
# Each oldE80 -NNN segment is tested against every non-oldE80 reference
# track.  Coverage = fraction of segment points found in order in the
# reference track (greedy forward scan, bounding-box pre-filter).
# A segment is NOVEL if no reference track covers >= $MATCH_THR of it.
# Novel segments are inserted as-is (using the original segment name).

package nmOldE80;
use strict;
use warnings;
use threads;
use threads::shared;
use POSIX qw(floor);
use Pub::Utils qw(display warning error);
use c_db;
use a_defs;

BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		doImportOldE80Residue
	);
}

my $OLDE80_UUID  = 'c54e66ec4f006122';
my $RESIDUE_NAME = 'E80 Residue';
my %SKIP_STRAND  = map { $_ => 1 } ('PERLAS', 'PERLAS2', 'SAN BLAS 1');
my %SKIP_WP      = map { $_ => 1 } ('t01', 't02', 't03', 't04', 't05', 't06');
my $WP_TOL       = 0.00005; # ~5m   waypoint identity match
my $PT_TOL       = 0.001;   # ~100m per-point coordinate match tolerance
my $MATCH_THR    = 0.80;    # segment covered if one ref track matches >= 80%


sub _haversine_nm
{
	my ($lat1, $lon1, $lat2, $lon2) = @_;
	my $PI   = 3.14159265358979;
	my $R    = 3440.065;
	my $dlat = ($lat2 - $lat1) * $PI / 180;
	my $dlon = ($lon2 - $lon1) * $PI / 180;
	my $rl1  = $lat1 * $PI / 180;
	my $rl2  = $lat2 * $PI / 180;
	my $a    = sin($dlat/2)**2 + cos($rl1) * cos($rl2) * sin($dlon/2)**2;
	my $c    = 2 * atan2(sqrt($a), sqrt(1 - $a));
	return $R * $c;
}


sub _run_distance_nm
{
	my ($pts) = @_;
	my $d = 0;
	for my $i (1 .. $#$pts)
	{
		$d += _haversine_nm(
			$pts->[$i-1]{lat}, $pts->[$i-1]{lon},
			$pts->[$i  ]{lat}, $pts->[$i  ]{lon});
	}
	return $d;
}


# Greedy forward scan: fraction of seg_pts found in order in ref_pts.
# If a segment point has no match from the current scan position,
# rpos is NOT advanced -- subsequent points can still match from there.
sub _seq_coverage
{
	my ($seg_pts, $ref_pts) = @_;
	my $rpos    = 0;
	my $matched = 0;
	for my $sp (@$seg_pts)
	{
		for my $j ($rpos .. $#$ref_pts)
		{
			if (abs($sp->{lat} - $ref_pts->[$j]{lat}) < $PT_TOL &&
			    abs($sp->{lon} - $ref_pts->[$j]{lon}) < $PT_TOL)
			{
				$matched++;
				$rpos = $j + 1;
				last;
			}
		}
	}
	return @$seg_pts ? $matched / scalar(@$seg_pts) : 0;
}


sub doImportOldE80Residue
{
	display(0,0,"nmOldE80::doImportOldE80Residue starting");

	my $dbh = connectDB();
	return error("nmOldE80: cannot connect to DB") if !$dbh;

	my $existing = findCollection($dbh, $RESIDUE_NAME, undef);
	if ($existing)
	{
		display(0,1,"removing existing '$RESIDUE_NAME' branch ...");
		deleteBranch($dbh, $existing);
	}

	# Load all non-oldE80 reference tracks with points and bounding box
	display(0,1,"loading reference tracks ...");
	my ($ref_rows) = rawQuery($dbh, qq{
		WITH RECURSIVE tree(uuid) AS (
			SELECT uuid FROM collections
			WHERE uuid='$OLDE80_UUID'
			   OR (name='$RESIDUE_NAME' AND parent_uuid IS NULL)
			UNION ALL
			SELECT c.uuid FROM collections c JOIN tree ON c.parent_uuid=tree.uuid
		)
		SELECT uuid, name FROM tracks
		WHERE collection_uuid NOT IN (SELECT uuid FROM tree)
	});

	my @ref_tracks;
	for my $t (@{$ref_rows // []})
	{
		my $pts = getTrackPoints($dbh, $t->{uuid});
		next if @$pts < 2;
		my ($min_lat, $max_lat, $min_lon, $max_lon);
		for my $p (@$pts)
		{
			$min_lat = $p->{lat} if !defined $min_lat || $p->{lat} < $min_lat;
			$max_lat = $p->{lat} if !defined $max_lat || $p->{lat} > $max_lat;
			$min_lon = $p->{lon} if !defined $min_lon || $p->{lon} < $min_lon;
			$max_lon = $p->{lon} if !defined $max_lon || $p->{lon} > $max_lon;
		}
		push @ref_tracks, {
			name    => $t->{name},
			pts     => $pts,
			min_lat => $min_lat, max_lat => $max_lat,
			min_lon => $min_lon, max_lon => $max_lon,
		};
	}
	display(0,1,scalar(@ref_tracks)." reference tracks loaded");

	# Get all oldE80 tracks, group into strands by stripping -NNN suffix
	my $olde80      = getCollectionWRGTs($dbh, $OLDE80_UUID);
	my $olde80_trks = $olde80->{tracks};

	my %strands;
	for my $t (@$olde80_trks)
	{
		(my $strand = $t->{name}) =~ s/-\d{3}$//;
		push @{$strands{$strand}}, $t;
	}
	display(0,1,scalar(@$olde80_trks)." oldE80 tracks in ".scalar(keys %strands)." strands");

	# Create the residue branch
	my $res_uuid = insertCollection($dbh, $RESIDUE_NAME, undef, $NODE_TYPE_BRANCH);

	# WAYPOINTS — novel WPs from oldE80 "Waypoints" sub-folder (inserted first = top of tree)
	my ($wp_coll_rows) = rawQuery($dbh,
		"SELECT uuid FROM collections WHERE name='Waypoints' AND parent_uuid='$OLDE80_UUID'");
	my $wp_coll_uuid = @{$wp_coll_rows // []} ? $wp_coll_rows->[0]{uuid} : undef;

	if ($wp_coll_uuid)
	{
		display(0,1,"processing oldE80 Waypoints folder ...");
		my ($old_wps) = rawQuery($dbh,
			"SELECT uuid, name, lat, lon FROM waypoints WHERE collection_uuid='$wp_coll_uuid'");

		my @sorted_wps = sort {
			my ($na) = ($a->{name} =~ /(\d+)$/);
			my ($nb) = ($b->{name} =~ /(\d+)$/);
			($na // 0) <=> ($nb // 0)
		} @{$old_wps // []};

		my ($wp_branch_uuid, $wp_inserted) = (undef, 0);
		my @wp_results;

		for my $wp (@sorted_wps)
		{
			next if $SKIP_WP{$wp->{name}};

			my $hit = $dbh->get_record(qq{
				WITH RECURSIVE tree(uuid) AS (
					SELECT uuid FROM collections
					WHERE uuid='$OLDE80_UUID'
					   OR (name='$RESIDUE_NAME' AND parent_uuid IS NULL)
					UNION ALL
					SELECT c.uuid FROM collections c JOIN tree ON c.parent_uuid=tree.uuid
				)
				SELECT uuid, name FROM waypoints
				WHERE ABS(lat-?) < $WP_TOL
				  AND ABS(lon-?) < $WP_TOL
				  AND collection_uuid NOT IN (SELECT uuid FROM tree)
				LIMIT 1
			}, [$wp->{lat}, $wp->{lon}]);

			if ($hit)
			{
				push @wp_results, { %$wp, status => 'MATCHED', match_name => $hit->{name} };
				next;
			}

			push @wp_results, { %$wp, status => '', match_name => '' };

			$wp_branch_uuid //= insertCollection($dbh, 'Waypoints', $res_uuid, $NODE_TYPE_BRANCH);
			insertWaypoint($dbh,
				name            => $wp->{name},
				lat             => $wp->{lat},
				lon             => $wp->{lon},
				wp_type         => $WP_TYPE_NAV,
				color           => undef,
				depth_cm        => 0,
				created_ts      => 0,
				ts_source       => $TS_SOURCE_IMPORT,
				source          => 'oldE80',
				collection_uuid => $wp_branch_uuid);

			$wp_inserted++;
		}

		for my $r (@wp_results)
		{
			display(0,2, sprintf("%-20s  %-7s  lat=%.6f  lon=%.6f  %s",
				$r->{name}, $r->{status}, $r->{lat}, $r->{lon}, $r->{match_name}));
		}
		display(0,1,"Waypoints: $wp_inserted novel inserted");
	}

	my $total_inserted = 0;

	for my $sname (sort keys %strands)
	{
		if ($SKIP_STRAND{$sname})
		{
			display(0,1,"$sname: skipped (known duplicate)");
			next;
		}

		my @segs = sort { $a->{name} cmp $b->{name} } @{$strands{$sname}};
		my $strand_inserted = 0;
		my $sub_uuid;

		for my $seg (@segs)
		{
			my $pts = getTrackPoints($dbh, $seg->{uuid});
			next if @$pts < 2;

			# Bounding box of this segment
			my ($smin_lat, $smax_lat, $smin_lon, $smax_lon);
			for my $p (@$pts)
			{
				$smin_lat = $p->{lat} if !defined $smin_lat || $p->{lat} < $smin_lat;
				$smax_lat = $p->{lat} if !defined $smax_lat || $p->{lat} > $smax_lat;
				$smin_lon = $p->{lon} if !defined $smin_lon || $p->{lon} < $smin_lon;
				$smax_lon = $p->{lon} if !defined $smax_lon || $p->{lon} > $smax_lon;
			}

			# Find best coverage across all reference tracks
			my $best_pct  = 0;
			my $best_name = '(none)';
			for my $ref (@ref_tracks)
			{
				next if $ref->{max_lat} < $smin_lat - $PT_TOL;
				next if $ref->{min_lat} > $smax_lat + $PT_TOL;
				next if $ref->{max_lon} < $smin_lon - $PT_TOL;
				next if $ref->{min_lon} > $smax_lon + $PT_TOL;

				my $pct = _seq_coverage($pts, $ref->{pts});
				if ($pct > $best_pct)
				{
					$best_pct  = $pct;
					$best_name = $ref->{name};
				}
				last if $best_pct >= $MATCH_THR;
			}

			my $nm      = _run_distance_nm($pts);
			my $pct_str = int($best_pct * 100 + 0.5) . '%';

			if ($best_pct >= $MATCH_THR)
			{
				display(0,2,"$seg->{name}: ".scalar(@$pts)." pts  ".sprintf("%.1f",$nm)." nm  COVERED $pct_str  by $best_name");
				next;
			}

			# Novel segment -- insert
			$sub_uuid //= insertCollection($dbh, $sname, $res_uuid, $NODE_TYPE_BRANCH);

			my $pt_recs = [ map { {
				lat      => $_->{lat},
				lon      => $_->{lon},
				depth_cm => undef,
				temp_k   => undef,
				ts       => undef } } @$pts ];

			my $track_uuid = insertTrack($dbh,
				name            => $seg->{name},
				color           => 1,
				ts_start        => 0,
				ts_end          => undef,
				ts_source       => $TS_SOURCE_IMPORT,
				point_count     => scalar @$pts,
				collection_uuid => $sub_uuid);
			insertTrackPoints($dbh, $track_uuid, $pt_recs);

			display(0,2,"$seg->{name}: ".scalar(@$pts)." pts  ".sprintf("%.1f",$nm)." nm  NOVEL  (best $pct_str by $best_name)");
			$strand_inserted++;
			$total_inserted++;
		}
		display(0,1,"$sname: $strand_inserted segments inserted");
	}

	disconnectDB($dbh);
	display(0,0,"nmOldE80: done — $total_inserted segments inserted into '$RESIDUE_NAME'");
	return 1;
}


# OLD BUCKET APPROACH (preserved for reference)
#
# Built one global spatial bucket index (~100m cells) from ALL non-oldE80
# track points, then concatenated each strand's -NNN segments into one
# sequence and found contiguous novel RUNS within it.
# Problem: a point is covered if ANY track passed within 100m, regardless
# of which track or sequence order.  Dense anchorages (Isla Veraguas etc.)
# suppress connective points, fragmenting continuous journeys into many
# small runs.  SAN BLAS 3 produced 66 fragments; strand approach produces
# 6 segments including two >50nm runs that were invisible before.
#
# my $TK_TOL = 0.001;
# my %bucket;
# for my $t (@{$ref_rows // []}) {
#     my $pts = getTrackPoints($dbh, $t->{uuid});
#     for my $p (@$pts) {
#         my $bk = floor($p->{lat}/$TK_TOL).','floor($p->{lon}/$TK_TOL);
#         $bucket{$bk} = 1;
#     }
# }
# ... then concatenate strand segments and find contiguous novel runs ...


1;
