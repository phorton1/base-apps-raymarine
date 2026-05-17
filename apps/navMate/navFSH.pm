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
use navDB;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT_OK = qw(
		fshToNavUUID
		navToFSHUUID
	);
}


my $dbg_fsh = 0;

our $fsh_db       = undef;
our $fsh_filename = '';


sub getFSHDb   { return $fsh_db; }
sub getFilename { return $fsh_filename; }


#-----------------------------------------
# UUID format conversion helpers
#-----------------------------------------
# FSH stores UUIDs as 16-char uppercase hex with dashes after bytes
# 1, 3, 5 (e.g. "B2C4-3C00-81B6-XXXX") via fshUtils::uuidToStr.
# navMate (DB and NET layers) uses 16-char lowercase hex no dashes
# (e.g. "b2c43c0081b6XXXX").
#
# All clipboard items in navOps carry navMate-form UUIDs; spoke-format
# conversion happens at the FSH snapshot seam (in `_snapshotFSHNode`
# and the inverse paste paths in `navOpsFSH.pm`).
#
# These helpers are exported for any module that needs to bridge
# the two formats -- primarily `navClipboard::getPushMenuItems` (peer
# presence checks across the seam) and `navOpsFSH.pm` itself.

sub fshToNavUUID
{
	my ($u) = @_;
	return $u if !defined $u || $u eq '';
	# strToUuid: dashed-upper string -> 8 raw bytes
	# unpack H16: 8 bytes -> 16 lower-hex chars no dashes
	return unpack('H16', apps::raymarine::FSH::fshUtils::strToUuid($u));
}


sub navToFSHUUID
{
	my ($u) = @_;
	return $u if !defined $u || $u eq '';
	# pack H16: 16 hex chars (case-insensitive) -> 8 raw bytes
	# uuidToStr: 8 bytes -> dashed-upper string
	return apps::raymarine::FSH::fshUtils::uuidToStr(pack('H16', $u));
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
	my $ok  = 1;

	for my $uuid (sort keys %{$fsh_db->{waypoints}})
	{
		$ok &&= $fsh->encodeWPT($fsh_db->{waypoints}{$uuid});
	}

	for my $uuid (sort keys %{$fsh_db->{groups}})
	{
		$ok &&= $fsh->encodeGRP($fsh_db->{groups}{$uuid});
	}

	for my $uuid (sort keys %{$fsh_db->{routes}})
	{
		$ok &&= $fsh->encodeRTE($fsh_db->{routes}{$uuid});
	}

	for my $key (sort keys %{$fsh_db->{tracks}})
	{
		my $rec = $fsh_db->{tracks}{$key};
		$ok &&= $fsh->encodeTRK({
			trk_uuid => $rec->{trk_uuid},
			points   => $rec->{points},
		});
		$ok &&= $fsh->encodeMTA({
			mta_uuid => $rec->{mta_uuid},
			trk_uuid => $rec->{trk_uuid},
			name     => $rec->{name},
			color    => $rec->{color} // 0,
			points   => $rec->{points},
		});
	}

	if (!$ok)
	{
		error("navFSH::saveFSH: one or more encode errors - file '$filename' NOT written");
		return 0;
	}

	return $fsh->write($filename);
}


#-----------------------------------------
# convertToNavMate
#-----------------------------------------
# One-shot in-memory promotion of an FSH working copy:
#
#   1) Every track name has ALL whitespace stripped (FSH encode space-pads
#      names to 16 chars; Z16 decode leaves the spaces).  "Track 2" -> "Track2".
#   2) Each track whose points contain sentinel breaks (lat =~ /^-0\.00/) is
#      replaced with N new tracks named TRACKNAME-NNN (3-digit zero-padded),
#      each carrying one segment's points and freshly minted navMate-domain
#      UUIDs (mta_uuid and trk_uuid from newUUID).
#
# Single-segment tracks keep their (cleaned) name and stay as one track.
# Waypoints, routes, and groups are untouched.
# Caller must invoke navFSH::saveFSH() afterwards to persist the result.
#
# Returns { tracks_unchanged, tracks_converted, segments_created }.

sub convertToNavMate
{
	my $stats = {
		tracks_unchanged => 0,
		tracks_converted => 0,
		segments_created => 0,
	};

	if (!$fsh_db)
	{
		error("navFSH::convertToNavMate: no FSH database loaded");
		return $stats;
	}

	my $dbh = navDB::connectDB();
	if (!$dbh)
	{
		error("navFSH::convertToNavMate: could not open navMate database for UUID minting");
		return $stats;
	}

	my $tracks = $fsh_db->{tracks};
	my @track_uuids = keys %$tracks;

	for my $uuid (@track_uuids)
	{
		my $track = $tracks->{$uuid};
		my $points = $track->{points} // [];

		# Normalize name: strip all whitespace (FSH encode pads to 16 with
		# spaces, and decoded "Track 2" reads back as "Track 2          ").
		my $orig_name = $track->{name} // 'track';
		$orig_name =~ s/\s+//g;
		$orig_name = 'track' if $orig_name eq '';

		# Split into segments at sentinel points (lat =~ /^-0\.00/).
		# Sentinels are gap markers; they belong to neither neighbor segment.

		my @segments;
		my @current;
		for my $pt (@$points)
		{
			my $lat = $pt->{lat} // 0;
			if ($lat =~ /^-0\.00/)
			{
				if (@current)
				{
					push @segments, [@current];
					@current = ();
				}
			}
			else
			{
				push @current, $pt;
			}
		}
		push @segments, [@current] if @current;

		my $n_seg = scalar @segments;
		if ($n_seg <= 1)
		{
			$track->{name} = $orig_name if ($track->{name} // '') ne $orig_name;
			$stats->{tracks_unchanged}++;
			next;
		}

		my $color = $track->{color} // 0;

		# Replace the original track with N new -NNN tracks.
		# Each gets fresh navMate-domain mta_uuid and trk_uuid.

		delete $tracks->{$uuid};

		for (my $i = 0; $i < $n_seg; $i++)
		{
			my $seg_pts = $segments[$i];
			my $new_mta = navDB::newUUID($dbh);
			my $new_trk = navDB::newUUID($dbh);
			if (!$new_mta || !$new_trk)
			{
				error("navFSH::convertToNavMate: UUID minting failed for $orig_name segment ".($i+1));
				navDB::disconnectDB($dbh);
				return $stats;
			}
			my $new_name = sprintf('%s-%03d', $orig_name, $i + 1);
			$tracks->{$new_mta} = shared_clone({
				mta_uuid => $new_mta,
				trk_uuid => $new_trk,
				name     => $new_name,
				color    => $color,
				points   => [@$seg_pts],
				cnt      => scalar @$seg_pts,
			});
		}

		$stats->{tracks_converted}++;
		$stats->{segments_created} += $n_seg;
	}

	navDB::disconnectDB($dbh);

	display(0, 0, sprintf("navFSH::convertToNavMate: unchanged=%d converted=%d segments=%d",
		$stats->{tracks_unchanged},
		$stats->{tracks_converted},
		$stats->{segments_created}));

	return $stats;
}


1;
