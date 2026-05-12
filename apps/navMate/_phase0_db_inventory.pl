#!/usr/bin/perl
use strict;
use warnings;
use DBI;

my $db_path = 'C:/dat/Rhapsody/navMate.db';
my $dbh = DBI->connect("dbi:SQLite:dbname=$db_path", '', '',
    { RaiseError => 1, AutoCommit => 1 });

# Build collection path lookup
my %coll;
my $sth = $dbh->prepare("SELECT uuid, name, parent_uuid FROM collections");
$sth->execute();
while (my $row = $sth->fetchrow_hashref()) {
    $coll{$row->{uuid}} = $row;
}

sub coll_path {
    my ($uuid) = @_;
    return '' unless $uuid && $coll{$uuid};
    my @parts;
    my $cur = $uuid;
    while ($cur && $coll{$cur}) {
        unshift @parts, $coll{$cur}{name};
        $cur = $coll{$cur}{parent_uuid};
    }
    return join(' / ', @parts);
}

# ts is "date-only" if it is a multiple of 86400 (midnight UTC) -- proxy for
# KML-imported tracks where only a date, not a time, was recorded
sub is_date_only {
    my ($ts) = @_;
    return 0 unless defined $ts && $ts > 0;
    return ($ts % 86400 == 0) ? 1 : 0;
}

print "=" x 100 . "\n";
print "TRACK INVENTORY\n";
print "=" x 100 . "\n";
printf "%-50s  %6s  %6s  %6s  %6s  %6s  %6s\n",
    "Collection / Track", "pts", "ts=NULL", "date_only", "no_dep", "no_tmp", "enrich?";
print "-" x 100 . "\n";

my $tracks = $dbh->selectall_arrayref(
    "SELECT uuid, name, collection_uuid, point_count FROM tracks ORDER BY collection_uuid, position",
    { Slice => {} });

my ($total_pts, $total_null_ts, $total_dateonly, $total_no_dep, $total_no_tmp) = (0,0,0,0,0);

for my $t (@$tracks) {
    my $pts = $dbh->selectall_arrayref(
        "SELECT ts, depth_cm, temp_k FROM track_points WHERE track_uuid=?",
        { Slice => {} }, $t->{uuid});

    my ($null_ts, $dateonly, $no_dep, $no_tmp) = (0,0,0,0);
    for my $p (@$pts) {
        $null_ts++  unless defined $p->{ts};
        $dateonly++ if is_date_only($p->{ts});
        $no_dep++   unless defined $p->{depth_cm} && $p->{depth_cm} != 0;
        $no_tmp++   unless defined $p->{temp_k}   && $p->{temp_k}   != 0;
    }
    my $n   = scalar @$pts;
    my $enrich = ($null_ts || $dateonly || $no_dep || $no_tmp) ? 'YES' : '-';

    my $label = coll_path($t->{collection_uuid}) . ' / ' . $t->{name};
    $label = substr($label, 0, 50) if length($label) > 50;

    printf "%-50s  %6d  %6d  %6d  %6d  %6d  %6s\n",
        $label, $n, $null_ts, $dateonly, $no_dep, $no_tmp, $enrich;

    $total_pts      += $n;
    $total_null_ts  += $null_ts;
    $total_dateonly += $dateonly;
    $total_no_dep   += $no_dep;
    $total_no_tmp   += $no_tmp;
}

print "-" x 100 . "\n";
printf "%-50s  %6d  %6d  %6d  %6d  %6d\n",
    "TOTALS", $total_pts, $total_null_ts, $total_dateonly, $total_no_dep, $total_no_tmp;


print "\n" . "=" x 100 . "\n";
print "WAYPOINT INVENTORY\n";
print "=" x 100 . "\n";
printf "%-50s  %6s  %6s  %6s  %6s  %6s\n",
    "Collection / Name", "ts_ok", "dt_only", "no_dep", "no_tmp", "enrich?";
print "-" x 100 . "\n";

my $wps = $dbh->selectall_arrayref(
    "SELECT uuid, name, collection_uuid, created_ts, depth_cm, temp_k FROM waypoints ORDER BY collection_uuid, position",
    { Slice => {} });

my ($wp_ts_ok, $wp_dateonly, $wp_no_dep, $wp_no_tmp) = (0,0,0,0);

for my $w (@$wps) {
    my $ts_ok   = (defined $w->{created_ts} && $w->{created_ts} > 0 && !is_date_only($w->{created_ts})) ? 1 : 0;
    my $dateonly= is_date_only($w->{created_ts});
    my $no_dep  = (!defined $w->{depth_cm} || $w->{depth_cm} == 0) ? 1 : 0;
    my $no_tmp  = (!defined $w->{temp_k}   || $w->{temp_k}   == 0) ? 1 : 0;
    my $enrich  = (!$ts_ok || $no_dep || $no_tmp) ? 'YES' : '-';

    my $label = coll_path($w->{collection_uuid}) . ' / ' . $w->{name};
    $label = substr($label, 0, 50) if length($label) > 50;

    printf "%-50s  %6s  %6s  %6s  %6s  %6s\n",
        $label,
        ($ts_ok ? 'yes' : '-'),
        ($dateonly ? 'yes' : '-'),
        ($no_dep ? 'yes' : '-'),
        ($no_tmp ? 'yes' : '-'),
        $enrich;

    $wp_ts_ok   += $ts_ok;
    $wp_dateonly+= $dateonly;
    $wp_no_dep  += $no_dep;
    $wp_no_tmp  += $no_tmp;
}

print "-" x 100 . "\n";
printf "%-50s  %6d  %6d  %6d  %6d\n",
    "TOTALS", $wp_ts_ok, $wp_dateonly, $wp_no_dep, $wp_no_tmp;

$dbh->disconnect();
