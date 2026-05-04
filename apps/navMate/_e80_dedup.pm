#----------------------------------------------
# _e80_dedup.pm
#----------------------------------------------
# oldE80 archaeology: waypoint dedup + track strand matching
# Run from: C:\base\apps\raymarine
# Usage:    /c/Perl/bin/perl.exe -I/base apps/navMate/_e80_dedup.pm
#
# APPROACH: per-segment matching against individual reference tracks.
# Each oldE80 -NNN segment is tested against every non-oldE80 track.
# Coverage = fraction of segment points found in order in the ref track
# (greedy forward scan with coordinate tolerance PT_TOL).
# A segment is COVERED if one ref track covers >= MATCH_THR of its points.
# Bounding-box pre-filter keeps runtime tractable.

package main;
use strict;
use warnings;
use DBI;
use POSIX qw(floor);

my $DB     = 'C:/dat/Rhapsody/navMate.db';
my $OLDE80 = 'c54e66ec4f006122';

my %SKIP_STRAND = map { $_ => 1 } ('SAN BLAS 1');

my $WP_TOL    = 0.00005;   # ~5m     waypoint identity match
my $PT_TOL    = 0.0001;    # ~10m    per-point coordinate match tolerance
my $MATCH_THR = 0.80;      # segment is COVERED if best ref track >= 80%

#----------------------------------------------
# connect
#----------------------------------------------

my $dbh = DBI->connect(
    "dbi:SQLite:dbname=$DB", '', '',
    { RaiseError => 1, AutoCommit => 1 })
    or die "Cannot connect to $DB\n";

#----------------------------------------------
# enumerate oldE80 collection UUIDs (recursive)
#----------------------------------------------

my $olde80_uuids = $dbh->selectcol_arrayref(qq{
    WITH RECURSIVE tree(uuid) AS (
        SELECT uuid FROM collections WHERE uuid='$OLDE80'
        UNION ALL
        SELECT c.uuid FROM collections c JOIN tree ON c.parent_uuid=tree.uuid
    )
    SELECT uuid FROM tree
});

# Also exclude E80 Residue branch (created by nmOldE80 runs) from reference tracks
my $residue_uuids = $dbh->selectcol_arrayref(qq{
    WITH RECURSIVE tree(uuid) AS (
        SELECT uuid FROM collections WHERE name='E80 Residue' AND parent_uuid IS NULL
        UNION ALL
        SELECT c.uuid FROM collections c JOIN tree ON c.parent_uuid=tree.uuid
    )
    SELECT uuid FROM tree
});

my $in_old      = join(',', map { "'$_'" } @$olde80_uuids);
my $in_excluded = join(',', map { "'$_'" } (@$olde80_uuids, @$residue_uuids));
my $not_old     = "collection_uuid NOT IN ($in_excluded)";
my $is_old      = "collection_uuid IN ($in_old)";

printf "oldE80 subtree: %d collections  E80 Residue: %d collections excluded\n",
    scalar @$olde80_uuids, scalar @$residue_uuids;

#----------------------------------------------
# WAYPOINT DEDUP
#----------------------------------------------

print "\n=== WAYPOINT DEDUP (tolerance ${WP_TOL} deg ~5m, Waypoints folder only) ===\n\n";

# Only the "Waypoints" sub-folder -- Tracks folder WPs are genKML track-start artifacts
my ($wp_coll_uuid) = $dbh->selectrow_array(
    "SELECT uuid FROM collections WHERE name='Waypoints' AND parent_uuid='$OLDE80'");

if (!$wp_coll_uuid)
{
    print "  No 'Waypoints' sub-collection found under oldE80 -- skipping WP dedup\n";
}
else
{
    my $old_wps = $dbh->selectall_arrayref(
        "SELECT uuid, name, lat, lon FROM waypoints WHERE collection_uuid='$wp_coll_uuid' ORDER BY rowid",
        { Slice => {} });

    my (@matched, @unmatched);

    for my $wp (@$old_wps)
    {
        my ($hit) = $dbh->selectrow_array(
            "SELECT uuid FROM waypoints
             WHERE ABS(lat-?) < $WP_TOL AND ABS(lon-?) < $WP_TOL
             AND $not_old LIMIT 1",
            {}, $wp->{lat}, $wp->{lon});
        if ($hit) { push @matched,   $wp; }
        else       { push @unmatched, $wp; }
    }

    printf "  Total Waypoints-folder WPs:  %3d\n", scalar @$old_wps;
    printf "  Matched elsewhere:           %3d\n", scalar @matched;
    printf "  RESIDUE (unmatched):         %3d\n", scalar @unmatched;

    if (@unmatched)
    {
        print "\n  Unmatched waypoints:\n";
        for my $wp (sort {
            my ($na) = ($a->{name} =~ /(\d+)$/);
            my ($nb) = ($b->{name} =~ /(\d+)$/);
            ($na // 0) <=> ($nb // 0)
        } @unmatched)
        {
            printf "    %-32s  lat=%.6f  lon=%.6f\n",
                $wp->{name}, $wp->{lat}, $wp->{lon};
        }
    }
}

#----------------------------------------------
# helpers
#----------------------------------------------

sub haversine_nm
{
    my ($lat1, $lon1, $lat2, $lon2) = @_;
    my $PI  = 3.14159265358979;
    my $R   = 3440.065;
    my $dlat = ($lat2 - $lat1) * $PI / 180;
    my $dlon = ($lon2 - $lon1) * $PI / 180;
    my $rl1  = $lat1 * $PI / 180;
    my $rl2  = $lat2 * $PI / 180;
    my $a    = sin($dlat/2)**2 + cos($rl1) * cos($rl2) * sin($dlon/2)**2;
    my $c    = 2 * atan2(sqrt($a), sqrt(1 - $a));
    return $R * $c;
}

sub run_distance_nm
{
    my ($pts) = @_;
    my $d = 0;
    for my $i (1 .. $#$pts)
    {
        $d += haversine_nm(
            $pts->[$i-1]{lat}, $pts->[$i-1]{lon},
            $pts->[$i  ]{lat}, $pts->[$i  ]{lon});
    }
    return $d;
}

# Greedy forward scan: fraction of seg_pts found in order in ref_pts.
# If a segment point has no match from the current scan position,
# rpos is NOT advanced -- subsequent segment points can still match.
sub seq_coverage
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
        # no match found: rpos unchanged, next segment point tries from same position
    }
    return @$seg_pts ? $matched / scalar(@$seg_pts) : 0;
}

#----------------------------------------------
# TRACK STRAND MATCHING
#----------------------------------------------

print "\n=== TRACK STRAND MATCHING (pt_tol=${PT_TOL} deg, threshold=${MATCH_THR}) ===\n\n";

# Load all reference tracks with points + bounding box
print "  Loading reference tracks...\n";
my $ref_track_rows = $dbh->selectall_arrayref(
    "SELECT uuid, name FROM tracks WHERE $not_old ORDER BY name",
    { Slice => {} });

my @ref_tracks;
for my $t (@$ref_track_rows)
{
    my $pts = $dbh->selectall_arrayref(
        "SELECT lat, lon FROM track_points WHERE track_uuid=? ORDER BY position",
        { Slice => {} }, $t->{uuid});
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
        uuid    => $t->{uuid},
        pts     => $pts,
        min_lat => $min_lat, max_lat => $max_lat,
        min_lon => $min_lon, max_lon => $max_lon,
    };
}
printf "  Loaded %d reference tracks\n\n", scalar @ref_tracks;

# Load oldE80 tracks grouped by strand
my $old_tracks = $dbh->selectall_arrayref(
    "SELECT uuid, name, point_count FROM tracks WHERE $is_old ORDER BY name",
    { Slice => {} });

my %strands;
for my $t (@$old_tracks)
{
    (my $strand = $t->{name}) =~ s/-\d{3}$//;
    push @{$strands{$strand}}, $t;
}

printf "  oldE80: %d tracks in %d strands\n\n", scalar @$old_tracks, scalar keys %strands;

my ($total_novel, $total_covered, $total_skip) = (0, 0, 0);

for my $sname (sort keys %strands)
{
    if ($SKIP_STRAND{$sname})
    {
        printf "  %-20s  -- SKIPPED\n\n", $sname;
        next;
    }

    my @segs = sort { $a->{name} cmp $b->{name} } @{$strands{$sname}};
    my ($strand_novel, $strand_covered) = (0, 0);

    printf "  %s  (%d segments)\n", $sname, scalar @segs;

    for my $seg (@segs)
    {
        my $pts = $dbh->selectall_arrayref(
            "SELECT lat, lon FROM track_points WHERE track_uuid=? ORDER BY position",
            { Slice => {} }, $seg->{uuid});

        if (@$pts < 2)
        {
            printf "    %-20s  %4d pts  -- too short\n", $seg->{name}, scalar @$pts;
            $total_skip++;
            next;
        }

        # Bounding box of this segment
        my ($smin_lat, $smax_lat, $smin_lon, $smax_lon);
        for my $p (@$pts)
        {
            $smin_lat = $p->{lat} if !defined $smin_lat || $p->{lat} < $smin_lat;
            $smax_lat = $p->{lat} if !defined $smax_lat || $p->{lat} > $smax_lat;
            $smin_lon = $p->{lon} if !defined $smin_lon || $p->{lon} < $smin_lon;
            $smax_lon = $p->{lon} if !defined $smax_lon || $p->{lon} > $smax_lon;
        }

        my $nm        = run_distance_nm($pts);
        my $best_pct  = 0;
        my $best_name = '(none)';

        for my $ref (@ref_tracks)
        {
            # Bounding-box pre-filter (with PT_TOL margin)
            next if $ref->{max_lat} < $smin_lat - $PT_TOL;
            next if $ref->{min_lat} > $smax_lat + $PT_TOL;
            next if $ref->{max_lon} < $smin_lon - $PT_TOL;
            next if $ref->{min_lon} > $smax_lon + $PT_TOL;

            my $pct = seq_coverage($pts, $ref->{pts});
            if ($pct > $best_pct)
            {
                $best_pct  = $pct;
                $best_name = $ref->{name};
            }
        }

        my $pct_str = sprintf "%3d%%", int($best_pct * 100 + 0.5);

        if ($best_pct >= $MATCH_THR)
        {
            printf "    %-20s  %4d pts  %6.1f nm  COVERED %s  by %s\n",
                $seg->{name}, scalar @$pts, $nm, $pct_str, $best_name;
            $strand_covered++;
            $total_covered++;
        }
        else
        {
            printf "    %-20s  %4d pts  %6.1f nm  NOVEL   (best %s by %s)\n",
                $seg->{name}, scalar @$pts, $nm, $pct_str, $best_name;
            $strand_novel++;
            $total_novel++;
        }
    }

    printf "    => novel: %d  covered: %d\n\n", $strand_novel, $strand_covered;
}

printf "  TOTAL: %d novel  %d covered  %d skipped\n\n",
    $total_novel, $total_covered, $total_skip;

$dbh->disconnect();


#----------------------------------------------
# OLD BUCKET APPROACH (preserved for reference)
#----------------------------------------------
# The original approach built one global spatial bucket index from ALL
# non-oldE80 track points, then classified each oldE80 point as novel
# or covered based on whether its 100m bucket was occupied by anything.
# Advantage: fast.  Problem: a point is "covered" if ANY track passed
# nearby, regardless of which track or whether the sequence is preserved.
# Dense anchorages (e.g. Isla Veraguas) suppress points from tracks that
# happen to pass through them, fragmenting what should be continuous runs.
#
# To restore: uncomment, set $TK_TOL, and re-add the bucket-build loop.

# my $TK_TOL = 0.001;
# my %bucket;
# for my $t (@$ref_tracks) {
#     for my $p (@{$t->{pts}}) {
#         my $bk = floor($p->{lat}/$TK_TOL).','floor($p->{lon}/$TK_TOL);
#         $bucket{$bk} = 1;
#     }
# }

1;
