#!/usr/bin/perl
use strict;
use warnings;
use lib '/base';
use POSIX qw(floor);
use Pub::Utils;
use apps::raymarine::FSH::fshFile;
use apps::raymarine::FSH::fshBlocks;

$Pub::Utils::debug_level = -1;

my $FSH_FILE = 'C:/base/apps/raymarine/FSH/test/working_oldE80.fsh';

my $fsh = apps::raymarine::FSH::fshFile->new($FSH_FILE);
die "Could not parse FSH file" unless $fsh;

# Unix timestamp from FSH date (days since 1970-01-01) + time (seconds since midnight)
sub fsh_ts {
    my ($date_days, $time_secs) = @_;
    return undef unless $date_days;
    return $date_days * 86400 + ($time_secs // 0);
}

sub ts_to_str {
    my ($ts) = @_;
    return '-' unless defined $ts && $ts > 0;
    my @t = gmtime($ts);
    return sprintf('%04d-%02d-%02d %02d:%02d:%02d UTC',
        $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0]);
}

print "\n" . "=" x 100 . "\n";
print "FSH TRACK INVENTORY -- FSH/test/working_oldE80.fsh\n";
print "=" x 100 . "\n";
printf "  %-14s  %-19s  %-19s  %5s  %5s  %5s  %9s  %9s  %9s  %9s\n",
    "Name", "mta_uuid", "trk_uuid", "pts", "dep%", "tmp%", "lat_min", "lat_max", "lon_min", "lon_max";
print "-" x 110 . "\n";

my $tracks = $fsh->getTracks();
for my $t (@$tracks) {
    next unless $t->{active};
    my $pts      = $t->{points};
    my $n        = scalar @$pts;
    my $dep_ct   = grep { defined $_->{depth} && $_->{depth} != 0 } @$pts;
    my $tmp_ct   = grep { defined $_->{temp_k} && $_->{temp_k} != 0 } @$pts;
    my $dep_pct  = $n ? sprintf('%.0f%%', 100 * $dep_ct / $n) : '-';
    my $tmp_pct  = $n ? sprintf('%.0f%%', 100 * $tmp_ct / $n) : '-';
    my $lat_min  = $n ? sprintf('%.5f', (sort { $a <=> $b } map { $_->{lat} } @$pts)[0])    : '-';
    my $lat_max  = $n ? sprintf('%.5f', (sort { $b <=> $a } map { $_->{lat} } @$pts)[0])    : '-';
    my $lon_min  = $n ? sprintf('%.5f', (sort { $a <=> $b } map { $_->{lon} } @$pts)[0])    : '-';
    my $lon_max  = $n ? sprintf('%.5f', (sort { $b <=> $a } map { $_->{lon} } @$pts)[0])    : '-';

    printf "  %-14s  %-19s  %-19s  %5d  %5s  %5s  %9s  %9s  %9s  %9s\n",
        $t->{name}, $t->{mta_uuid}//'', $t->{trk_uuid}//'', $n, $dep_pct, $tmp_pct,
        $lat_min, $lat_max, $lon_min, $lon_max;
}

print "\n" . "=" x 100 . "\n";
print "FSH WAYPOINT INVENTORY\n";
print "=" x 100 . "\n";
printf "  %-20s  %-28s  %8s  %8s  %5s  %8s  %8s\n",
    "Name", "datetime (UTC)", "depth_cm", "temp_k", "sym", "lat", "lon";
print "-" x 100 . "\n";

my $waypoints = $fsh->getWaypoints();
my ($wpt_total, $wpt_with_dt, $wpt_with_dep, $wpt_with_tmp) = (0,0,0,0);

for my $w (@$waypoints) {
    next unless $w->{active};
    $wpt_total++;
    my $ts       = fsh_ts($w->{date}, $w->{time});
    my $dt_str   = ts_to_str($ts);
    my $has_dt   = (defined $ts && $ts > 0) ? 1 : 0;
    my $has_dep  = (defined $w->{depth}  && $w->{depth}  > 0) ? 1 : 0;   # -1 = no reading sentinel
    my $has_tmp  = (defined $w->{temp_k} && $w->{temp_k} != 0 && $w->{temp_k} != 65535) ? 1 : 0;  # 65535 = no reading sentinel
    $wpt_with_dt  += $has_dt;
    $wpt_with_dep += $has_dep;
    $wpt_with_tmp += $has_tmp;

    printf "  %-20s  %-28s  %8s  %8s  %5s  %8.5f  %8.5f\n",
        substr($w->{name}//'-', 0, 20),
        $dt_str,
        ($has_dep ? $w->{depth}  : '-'),
        ($has_tmp ? $w->{temp_k} : '-'),
        $w->{sym} // '-',
        $w->{lat}, $w->{lon};
}

print "-" x 100 . "\n";
printf "  Totals: %d waypoints, %d with datetime, %d with depth, %d with temp_k\n",
    $wpt_total, $wpt_with_dt, $wpt_with_dep, $wpt_with_tmp;
