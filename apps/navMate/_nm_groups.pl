#!/usr/bin/perl
use strict;
use warnings;
use JSON;

my $raw = do { local $/; <STDIN> };
my $d   = decode_json($raw);

# Build route-membership lookup
my %in_route;
for my $rw (@{$d->{route_waypoints}}) {
    $in_route{$rw->{waypoint_uuid}} = 1;
}

# Build collection map
my %coll;
for my $c (@{$d->{collections}}) {
    $coll{$c->{uuid}} = $c;
}

# Group WPs by collection_uuid
my %group_wps;
for my $wp (@{$d->{waypoints}}) {
    my $cid = $wp->{collection_uuid} // next;
    $group_wps{$cid} //= [];
    push @{$group_wps{$cid}}, $wp;
}

# Navigation/Routes UUID  -  exclude groups under this branch
my $nav_routes = 'ac4e2c500600b9aa';

sub under_nav {
    my ($uuid) = @_;
    my $cur = $uuid;
    for (1..15) {
        return 1 if ($cur // '') eq $nav_routes;
        my $c = $coll{$cur // ''} or return 0;
        $cur = $c->{parent_uuid};
    }
    return 0;
}

# Collect grandparent name for context
sub ancestor_path {
    my ($uuid) = @_;
    my @parts;
    my $cur = $uuid;
    for (1..6) {
        my $c = $coll{$cur // ''} or last;
        unshift @parts, $c->{name};
        $cur = $c->{parent_uuid};
        last if !defined $cur;
    }
    return join(' / ', @parts);
}

printf("%-34s  %-22s  %4s  %5s  %s\n", 'UUID', 'Name', 'Mbrs', 'InRte', 'Path');
print '-' x 100 . "\n";

for my $c (sort { $a->{name} cmp $b->{name} } @{$d->{collections}}) {
    next if ($c->{node_type} // '') ne 'group';
    my $uuid = $c->{uuid};
    my $wps  = $group_wps{$uuid} // [];
    next if !@$wps;                # skip empty groups
    next if under_nav($uuid);         # skip Navigation/Routes subtree

    my $in_rt   = scalar grep { $in_route{$_->{uuid}} } @$wps;
    my $path    = ancestor_path($c->{parent_uuid} // '');

    printf("%-34s  %-22s  %4d  %5d  %s\n",
        $uuid, substr($c->{name}, 0, 22), scalar @$wps, $in_rt, $path);
}
