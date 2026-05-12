#!/usr/bin/perl
use strict;
use warnings;
use DBI;
use POSIX qw(mktime);
use XML::Simple qw(:strict);

my $GPX_FILE = 'C:/base_data/temp/raymarine/_cat32.gpx';
my $DB_PATH  = 'C:/dat/Rhapsody/navMate.db';

sub new_uuid {
    return sprintf('%04x%04x%04x%04x',
        int(rand(0xFFFF)), int(rand(0xFFFF)),
        int(rand(0xFFFF)), int(rand(0xFFFF)));
}

sub parse_iso8601 {
    my ($s) = @_;
    return undef unless defined $s;
    return undef unless $s =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/;
    return mktime($6, $5, $4, $3, $2-1, $1-1900);
}

my $MATCH_THRESHOLD = 0.0005;  # ~55m; reject donor points farther than this

sub nearest_ts {
    my ($lat, $lon, $donor) = @_;
    my $best_ts   = undef;
    my $best_dist = $MATCH_THRESHOLD * $MATCH_THRESHOLD;
    for my $d (@$donor) {
        my $dlat = $lat - $d->[0];
        my $dlon = $lon - $d->[1];
        my $dist = $dlat*$dlat + $dlon*$dlon;
        if ($dist < $best_dist) {
            $best_dist = $dist;
            $best_ts   = $d->[2];
        }
    }
    return $best_ts;
}

my $xml = XML::Simple->new(ForceArray => ['trk','trkseg','trkpt'], KeyAttr => []);
my $gpx = $xml->XMLin($GPX_FILE);

# Pass 1: load all tracks from GPX, separating donor (ACTIVE LOG) from keepers
my %tracks;
for my $trk (@{$gpx->{trk}}) {
    my $name = $trk->{name} // 'unnamed';
    my @pts;
    for my $seg (@{$trk->{trkseg}}) {
        push @pts, @{$seg->{trkpt}};
    }
    $tracks{$name} = \@pts;
}

# Build timestamp donor list from ACTIVE LOG (lat, lon, ts triples)
my @donor;
for my $pt (@{$tracks{'ACTIVE LOG'} // []}) {
    my $ts = parse_iso8601($pt->{time});
    push @donor, [$pt->{lat}+0, $pt->{lon}+0, $ts] if defined $ts;
}
printf "Donor: ACTIVE LOG -- %d timestamped points\n", scalar @donor;

my $dbh = DBI->connect("dbi:SQLite:dbname=$DB_PATH", '', '',
    { RaiseError => 1, AutoCommit => 0 });

# Create Before_Mandala collection at position 9.0 (after MandalaLogs)
my $coll_uuid = new_uuid();
$dbh->do(
    "INSERT INTO collections (uuid, name, parent_uuid, node_type, comment, position)
     VALUES (?, 'Before Mandala', NULL, 'branch', '', 9.0)",
    undef, $coll_uuid);
print "Created collection: Before Mandala  $coll_uuid\n";

my $sth = $dbh->prepare(
    "INSERT INTO track_points (track_uuid, position, lat, lon, depth_cm, temp_k, ts)
     VALUES (?, ?, ?, ?, NULL, NULL, ?)");

# Pass 2: import only the two named tracks; skip ACTIVE LOG and ACTIVE LOG 001
my $track_pos = 1.0;
for my $name ('08-OCT-05', '09-OCT-05') {
    my $pts = $tracks{$name} or do { print "  WARNING: $name not found in GPX\n"; next };

    my @rows;
    for my $pt (@$pts) {
        my $lat = $pt->{lat} + 0;
        my $lon = $pt->{lon} + 0;
        my $ts  = parse_iso8601($pt->{time});
        # 09-OCT-05 has no per-point ts -- enrich from ACTIVE LOG donor (same trip)
        $ts //= nearest_ts($lat, $lon, \@donor) if @donor && $name eq '09-OCT-05';
        push @rows, [$lat, $lon, $ts];
    }

    my $ts_start   = (sort { $a <=> $b } grep { defined $_ } map { $_->[2] } @rows)[0];
    my $ts_end     = (sort { $b <=> $a } grep { defined $_ } map { $_->[2] } @rows)[0];
    my $ts_count   = scalar grep { defined $_->[2] } @rows;
    my $would_match = ($name eq '08-OCT-05' && @donor)
        ? scalar grep { defined nearest_ts($_->[0], $_->[1], \@donor) } @rows
        : 0;

    my $trk_uuid = new_uuid();
    $dbh->do(
        "INSERT INTO tracks (uuid, name, color, ts_start, ts_end, ts_source, point_count,
                             collection_uuid, db_version, e80_version, kml_version, position, companion_uuid)
         VALUES (?, ?, NULL, ?, ?, 'gdb', ?, ?, 1, NULL, NULL, ?, NULL)",
        undef, $trk_uuid, $name, $ts_start//0, $ts_end//0,
        scalar(@rows), $coll_uuid, $track_pos);

    my $i = 0;
    for my $r (@rows) {
        $sth->execute($trk_uuid, $i++, $r->[0], $r->[1], $r->[2]);
    }

    my $diag = $would_match ? "  (would-match from Oct9 donor: $would_match)" : '';
    printf "  Track: %-14s  %s  pts=%d  ts_matched=%d  ts_start=%s  ts_end=%s%s\n",
        $name, $trk_uuid, scalar(@rows), $ts_count,
        $ts_start // '-', $ts_end // '-', $diag;

    $track_pos += 1.0;
}

$dbh->commit();
$dbh->disconnect();
print "Done.\n";
