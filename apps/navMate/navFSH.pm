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
use navDB qw(connectDB disconnectDB newFSHUUID);

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


sub _isFSHMapped
{
    my ($fsh_db) = @_;
    for my $coll (qw(waypoints groups routes tracks))
    {
        for my $uuid (keys %{$fsh_db->{$coll}})
        {
            return 0 if length($uuid) != 16;
            return substr($uuid, 2, 2) eq '46' ? 1 : 0;
        }
    }
    return 1;
}


sub _remapUUIDs
{
    my ($old_db) = @_;

    my $dbh = connectDB();
    if (!$dbh)
    {
        error("navFSH::_remapUUIDs: cannot connect to DB");
        return undef;
    }

    my %uuid_map;
    my $ok = 1;

    my $reg = sub
    {
        my ($old) = @_;
        return 1 if !$old || exists $uuid_map{$old};
        my $new = newFSHUUID($dbh);
        if (!$new) { $ok = 0; return 0; }
        $uuid_map{$old} = $new;
        return 1;
    };

    for my $uuid (keys %{$old_db->{waypoints}})
    {
        $reg->($uuid) or last;
    }

    if ($ok)
    {
        GRPLOOP: for my $uuid (keys %{$old_db->{groups}})
        {
            $reg->($uuid) or last GRPLOOP;
            for my $wpt (@{$old_db->{groups}{$uuid}{wpts} // []})
            {
                $reg->($wpt->{uuid}) or last GRPLOOP;
            }
        }
    }

    if ($ok)
    {
        RTELOOP: for my $uuid (keys %{$old_db->{routes}})
        {
            $reg->($uuid) or last RTELOOP;
            for my $wpt (@{$old_db->{routes}{$uuid}{wpts} // []})
            {
                $reg->($wpt->{uuid}) or last RTELOOP;
            }
        }
    }

    if ($ok)
    {
        for my $key (keys %{$old_db->{tracks}})
        {
            my $rec = $old_db->{tracks}{$key};
            $reg->($key)             or last;
            $reg->($rec->{mta_uuid}) or last;
            $reg->($rec->{trk_uuid}) or last;
        }
    }

    if (!$ok)
    {
        error("navFSH::_remapUUIDs: newFSHUUID failed - keeping raw E80 UUIDs");
        disconnectDB($dbh);
        return undef;
    }

    disconnectDB($dbh);

    my %new_wpts;
    for my $old (keys %{$old_db->{waypoints}})
    {
        my $rec = {%{$old_db->{waypoints}{$old}}};
        my $new = $uuid_map{$old};
        $rec->{origin_uuid} = $old;
        $rec->{uuid}        = $new;
        $new_wpts{$new}     = $rec;
    }

    my %new_grps;
    for my $old (keys %{$old_db->{groups}})
    {
        my $rec = {%{$old_db->{groups}{$old}}};
        my $new = $uuid_map{$old};
        $rec->{origin_uuid} = $old;
        $rec->{uuid}        = $new;
        my @rwpts;
        for my $wpt (@{$rec->{wpts} // []})
        {
            push @rwpts, {%$wpt, uuid => $uuid_map{$wpt->{uuid}} // $wpt->{uuid}};
        }
        $rec->{wpts}    = \@rwpts;
        $new_grps{$new} = $rec;
    }

    my %new_rtes;
    for my $old (keys %{$old_db->{routes}})
    {
        my $rec = {%{$old_db->{routes}{$old}}};
        my $new = $uuid_map{$old};
        $rec->{origin_uuid} = $old;
        $rec->{uuid}        = $new;
        my @rwpts;
        for my $wpt (@{$rec->{wpts} // []})
        {
            push @rwpts, {%$wpt, uuid => $uuid_map{$wpt->{uuid}} // $wpt->{uuid}};
        }
        $rec->{wpts}    = \@rwpts;
        $new_rtes{$new} = $rec;
    }

    my %new_trks;
    for my $old_key (keys %{$old_db->{tracks}})
    {
        my $rec     = {%{$old_db->{tracks}{$old_key}}};
        my $new_key = $uuid_map{$old_key};
        $rec->{origin_uuid} = $old_key;
        $rec->{mta_uuid}    = $uuid_map{$rec->{mta_uuid}} // $new_key;
        $rec->{trk_uuid}    = $uuid_map{$rec->{trk_uuid}} // $new_key;
        $new_trks{$new_key} = $rec;
    }

    return shared_clone({
        waypoints => \%new_wpts,
        groups    => \%new_grps,
        routes    => \%new_rtes,
        tracks    => \%new_trks,
    });
}


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

    if (!_isFSHMapped($fsh_db))
    {
        my $remapped = _remapUUIDs($fsh_db);
        $fsh_db = $remapped if $remapped;
    }

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

	# Each fsh_db track entry is written as its own TRK+MTA pair.
	# Segmented tracks (key != mta_uuid) share mta_uuid/trk_uuid with their
	# siblings, so writing them separately requires fresh unique block UUIDs.
	# Deriving from base-UUID bytes fails because two track groups can share
	# the same leading bytes and produce collisions.  Instead, use a counter
	# with synthetic prefixes (0xFFFFFF01/02) that can never match real E80 UUIDs.

	my $seg_n = 0;
	for my $key (sort keys %{$fsh_db->{tracks}})
	{
		my $rec      = $fsh_db->{tracks}{$key};
		my $base_mta = $rec->{mta_uuid};

		my ($mta_uuid_str, $trk_uuid_str);
		if ($key eq $base_mta)
		{
			$mta_uuid_str = $base_mta;
			$trk_uuid_str = $rec->{trk_uuid};
		}
		else
		{
			$seg_n++;
			$mta_uuid_str = uuidToStr(pack('NN', 0xFFFFFF01, $seg_n));
			$trk_uuid_str = uuidToStr(pack('NN', 0xFFFFFF02, $seg_n));
		}

		$fsh->encodeTRK({
			trk_uuid => $trk_uuid_str,
			points   => $rec->{points},
		});
		$fsh->encodeMTA({
			mta_uuid => $mta_uuid_str,
			trk_uuid => $trk_uuid_str,
			name     => $rec->{name},
			color    => $rec->{color} // 0,
			points   => $rec->{points},
		});
	}

	return $fsh->write($filename);
}


1;
