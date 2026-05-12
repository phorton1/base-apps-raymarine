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

    # tracks: BLK_MTA records, keyed by mta_uuid.
    # THE MTA_UUID IS THE IDENTITY UUID FOR TRACKS CONSISTENTLY THROUGHOUT THE SYSTEM.
    # Sentinel points (lat =~ /^-0\.00/) stay in the points array;
    # the Leaflet renderer skips them as segment breaks at render time.

    my $tracks = shared_clone({});
    for my $rec (@{$fsh->getTracks()})
    {
        $tracks->{$rec->{mta_uuid}} = shared_clone($rec);
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


sub saveFSH
{
	my ($filename) = @_;
	display($dbg_fsh, 0, "navFSH::saveFSH($filename)");

	if (!$fsh_db)
	{
		error("navFSH::saveFSH: no FSH database loaded");
		return 0;
	}
	if (!$filename)
	{
		error("navFSH::saveFSH: no filename specified");
		return 0;
	}

	my $fsh = apps::raymarine::FSH::fshFile->new();

	for my $uuid (sort keys %{$fsh_db->{waypoints}})
	{
		$fsh->encodeWPT($fsh_db->{waypoints}{$uuid});
	}

	for my $uuid (sort keys %{$fsh_db->{groups}})
	{
		$fsh->encodeGRP($fsh_db->{groups}{$uuid});
	}

	for my $uuid (sort keys %{$fsh_db->{routes}})
	{
		$fsh->encodeRTE($fsh_db->{routes}{$uuid});
	}

	for my $key (sort keys %{$fsh_db->{tracks}})
	{
		my $rec = $fsh_db->{tracks}{$key};
		$fsh->encodeTRK({
			trk_uuid => $rec->{trk_uuid},
			points   => $rec->{points},
		});
		$fsh->encodeMTA({
			mta_uuid => $rec->{mta_uuid},
			trk_uuid => $rec->{trk_uuid},
			name     => $rec->{name},
			color    => $rec->{color} // 0,
			points   => $rec->{points},
		});
	}

	return $fsh->write($filename);
}


1;
