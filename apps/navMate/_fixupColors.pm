#!/usr/bin/perl
#-------------------------------------------------------------------------
# _fixupColors.pm
#-------------------------------------------------------------------------
# One-time backfill of missing waypoint colors in navMate.db.
#
# Audited 2026-05-22 via /api/nmdb: 220 waypoints with empty color
# (color = ''), no NULLs, no '0' values, no malformed:
#
#   wp_type=2 (sounding)  132 records  -> set color = 'FFFFFFFF'
#   wp_type=3 (label)      43 records  -> set color = 'FFFFFFFF'
#   wp_type=1 (route_pt)   45 records  -> inherit color from parent route
#                                         via route_waypoints; fall back
#                                         to 'FFFFFFFF' if no parent route.
#
# 'FFFFFFFF' is the AABBGGRR encoding of E80 palette index 5
# (named BLACK in the protocol, rendered WHITE on the Leaflet map; see
# n_utils.pm:188-198 for the palette table).  Selecting the literal
# palette value (rather than `FF000000`) is what makes the color
# enumerated as "Black (White on Map)" in the editor's color picker
# rather than falling through to "Custom".
#
# Every updated row also gets modified_ts = time().
#
# Run from the repo root in bash; navMate does not hold an exclusive DB
# handle, so the app can stay running.  Output redirected per the
# feedback_perl_output_capture rule:
#
#   /c/Perl/bin/perl.exe -I/base -I/c/base/apps/raymarine/apps/navMate \
#       apps/navMate/_fixupColors.pm > \
#       /c/base_data/temp/raymarine/fixupColors.log 2>&1
#
# Re-verify by re-running the /api/nmdb empty-color audit and confirming
# zero empty-color waypoints across all three wp_type buckets.

use strict;
use warnings;
use navDB;
use n_defs;
use Pub::Utils qw(display);

my $BLACK_WHITE = 'FFFFFFFF';
my $now         = time();

display(0, 0, "_fixupColors.pm starting (modified_ts=$now)");

navDB::openDB();
my $dbh = navDB::connectDB();
if (!$dbh)
{
    print STDERR "connectDB failed\n";
    exit 1;
}

# Pass 1: soundings + labels with empty color -> black-white sentinel.
my $non_route_pt = $dbh->do(
    "UPDATE waypoints
        SET color = ?, modified_ts = ?
      WHERE (color IS NULL OR color = '')
        AND wp_type IN (?, ?)",
    [$BLACK_WHITE, $now, $WP_TYPE_SOUNDING, $WP_TYPE_LABEL]);
$non_route_pt //= 0;
display(0, 0, "pass 1: $non_route_pt sounding+label waypoints -> $BLACK_WHITE");

# Pass 2: route points inherit color from their parent route.
my $rp_rows = $dbh->get_records(
    "SELECT w.uuid AS wp_uuid, r.color AS route_color, r.uuid AS route_uuid
       FROM waypoints w
       LEFT JOIN route_waypoints rw ON rw.wp_uuid = w.uuid
       LEFT JOIN routes          r  ON r.uuid    = rw.route_uuid
      WHERE w.wp_type = ?
        AND (w.color IS NULL OR w.color = '')",
    [$WP_TYPE_ROUTE_PT]);

my %seen;
my $rp_inherited = 0;
my $rp_orphan    = 0;
for my $row (@$rp_rows)
{
    my $wp_uuid = $row->{wp_uuid};
    next if $seen{$wp_uuid}++;   # first route wins if member of multiple
    my $color = $row->{route_color};
    if (!defined $color || $color eq '')
    {
        $color = $BLACK_WHITE;
        $rp_orphan++;
    }
    else
    {
        $rp_inherited++;
    }
    $dbh->do(
        "UPDATE waypoints SET color = ?, modified_ts = ? WHERE uuid = ?",
        [$color, $now, $wp_uuid]);
}
display(0, 0, "pass 2: route_pts -> $rp_inherited inherited from route, "
    . "$rp_orphan orphan fallback to $BLACK_WHITE");

# Post-check: zero empty-color waypoints should remain.
my $remaining = $dbh->get_record(
    "SELECT COUNT(*) AS n FROM waypoints
      WHERE color IS NULL OR color = ''");
my $left = $remaining ? $remaining->{n} : '(query failed)';
display(0, 0, "post-check: $left empty-color waypoints remain");

navDB::disconnectDB($dbh);
display(0, 0, "_fixupColors.pm done");

1;
