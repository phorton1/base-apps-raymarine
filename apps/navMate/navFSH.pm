#-----------------------------------------
# navFSH.pm
#-----------------------------------------
# Loads an FSH file into a shared in-memory FSH-db structured like the E80-db
# (UUID-keyed hashes for waypoints, groups, routes, tracks).
#
# The fshFile object is discarded after conversion to free raw block bytes.
# The FSH-db is held in $fsh_db (shared, threads::shared) for future
# compatibility with the PASTE_NEW path.

package navFSH;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils qw(display warning error);
use apps::raymarine::FSH::fshUtils;
use apps::raymarine::FSH::fshBlocks;
use apps::raymarine::FSH::fshFile;

my $dbg_fsh = 0;

our $fsh_db       = undef;
our $fsh_filename = '';


sub getFSHDb   { return $fsh_db; }
sub getFilename { return $fsh_filename; }


sub _splitSegments
    # Split a track record on north=0,east=0 sentinel points.
    # Returns arrayref of [$key, $seg_rec] pairs.
    # Unsegmented tracks return a single pair with the original mta_uuid key.
    # Segments are named TRACKNAME-NNN (001-based) and keyed mta_uuid-NNN,
    # matching the genKML.pm convention used in docs/private/Data_Fixup.md.
{
    my ($rec) = @_;
    my $points    = $rec->{points} // [];
    my $base_name = $rec->{name}   // '';
    my $base_uuid = $rec->{mta_uuid};

    my $found = 0;
    for my $pt (@$points)
    {
        if (($pt->{lat} // '') =~ /^-0\.00/)
        {
            $found = 1;
            last;
        }
    }
    return [[$base_uuid, $rec]] if !$found;

    my @result;
    my $num     = '000';
    my $seg_pts = [];

    for my $pt (@$points)
    {
        if (($pt->{lat} // '') =~ /^-0\.00/)
        {
            if (@$seg_pts)
            {
                $num++;
                my $seg = { %$rec,
                    name   => "$base_name-$num",
                    points => $seg_pts,
                    cnt    => scalar @$seg_pts };
                push @result, ["$base_uuid-$num", $seg];
                $seg_pts = [];
            }
        }
        else
        {
            push @$seg_pts, $pt;
        }
    }
    if (@$seg_pts)
    {
        $num++;
        my $seg = { %$rec,
            name   => "$base_name-$num",
            points => $seg_pts,
            cnt    => scalar @$seg_pts };
        push @result, ["$base_uuid-$num", $seg];
    }

    return \@result;

}   # _splitSegments()


sub loadFSH
{
    my ($filename) = @_;
    display($dbg_fsh,0,"navFSH::loadFSH($filename)");

    my $fsh = apps::raymarine::FSH::fshFile->new($filename);
    if (!$fsh)
    {
        error("navFSH::loadFSH could not parse $filename");
        return 0;
    }

    # waypoints: BLK_WPT records, keyed by uuid
    # decodeCommonWaypoint already sets $rec->{uuid} = uuidToStr(...)

    my $waypoints = shared_clone({});
    for my $rec (@{$fsh->getWaypoints()})
    {
        $waypoints->{$rec->{uuid}} = shared_clone($rec);
    }

    # groups: BLK_GRP records (now have {uuid} after fshBlocks fix), keyed by uuid
    # each group has {name}, {uuid}, {wpts} array of embedded waypoint records

    my $groups = shared_clone({});
    for my $rec (@{$fsh->getGroups()})
    {
        $groups->{$rec->{uuid}} = shared_clone($rec);
    }

    # routes: BLK_RTE records (now have {uuid} after fshBlocks fix), keyed by uuid

    my $routes = shared_clone({});
    for my $rec (@{$fsh->getRoutes()})
    {
        $routes->{$rec->{uuid}} = shared_clone($rec);
    }

    # tracks: BLK_MTA records, split on north=0,east=0 sentinels.
    # Unsegmented tracks are keyed by mta_uuid; segments by mta_uuid-NNN.
    # Segment names are TRACKNAME-NNN, matching the genKML.pm convention.

    my $tracks = shared_clone({});
    for my $rec (@{$fsh->getTracks()})
    {
        for my $entry (@{_splitSegments($rec)})
        {
            my ($key, $seg) = @$entry;
            $tracks->{$key} = shared_clone($seg);
        }
    }

    $fsh_db = shared_clone({
        waypoints => $waypoints,
        groups    => $groups,
        routes    => $routes,
        tracks    => $tracks,
    });

    $fsh_filename = $filename;

    my $nw = scalar keys %$waypoints;
    my $ng = scalar keys %$groups;
    my $nr = scalar keys %$routes;
    my $nt = scalar keys %$tracks;
    display(0,0,"navFSH loaded: $nw waypoints, $ng groups, $nr routes, $nt tracks from $filename");

    return 1;

}   # loadFSH()


1;
