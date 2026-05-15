#!/usr/bin/perl
#-----------------------------------------------------
# _recoverTildes.pl
#-----------------------------------------------------
# Additive top-up: recovers the bare-tilde (~) Placemarks
# that navOneTimeImport.pm originally dropped due to its /~$/ filter.
#
# Bare-tilde Placemarks in C:/junk/navMate.kml are the phorton.com
# non-anchorage rendering anchors (regional context labels and dinghy
# tracks). The /~$/ filter only matches names ending in a literal tilde,
# so Foo~N (page-scope anchors) survived; Foo~ (Part-scope labels)
# and tracks like 2008-11-09-DinghyDogIsland~ were dropped.
#
# This tool is:
#   - additive only (never UPDATE, never DELETE, never rename)
#   - idempotent (re-runs skip items already present)
#   - DB-restructure-tolerant (logs and skips if destination
#     folder path can't be resolved by name)
#
# Usage:
#   perl _recoverTildes.pl             # dry-run preview (default)
#   perl _recoverTildes.pl --commit    # actually write to the DB

use strict;
use warnings;
use XML::Simple;
use Time::Local qw(timegm);
use Pub::Utils qw(display warning error);
use n_defs;
use n_utils;
use navDB;

$Pub::Utils::debug_level = -1;

my $NAVMATE_KML = 'C:/junk/navMate.kml';
my $SOURCE_TAG  = 'recoverTildes';
my $COMMIT      = grep { $_ eq '--commit' } @ARGV;

my $xs = XML::Simple->new(
	KeyAttr       => [],
	ForceArray    => ['Folder', 'Document', 'Placemark'],
	SuppressEmpty => '');

my $recovery_ts = time();

my %stats = (
	wp_inserted        => 0,
	wp_skipped_exists  => 0,
	wp_skipped_nocoll  => 0,
	wp_skipped_nocoord => 0,
	tr_inserted        => 0,
	tr_skipped_exists  => 0,
	tr_skipped_nocoll  => 0,
	tr_skipped_nopts   => 0);


sub main
{
	if (!-f $NAVMATE_KML)
	{
		print "FATAL: not found: $NAVMATE_KML\n";
		exit 1;
	}
	print "==== _recoverTildes.pl ", ($COMMIT ? "(COMMIT)" : "(DRY-RUN)"), " ====\n";
	print "Reading $NAVMATE_KML ...\n";
	my $data = $xs->XMLin($NAVMATE_KML);
	my $root = $data->{Document}[0];
	if (!$root)
	{
		print "FATAL: no root Document in $NAVMATE_KML\n";
		exit 1;
	}

	my $ok = openDB();
	if (!$ok || $ok == -1)
	{
		print "FATAL: navDB::openDB failed (returned ", ($ok // 'undef'), ")\n";
		exit 1;
	}
	my $dbh = connectDB();
	if (!$dbh)
	{
		print "FATAL: cannot connect to navMate.db\n";
		exit 1;
	}

	# Strip the outermost <Folder name="navMate"> wrapper, exactly as
	# navOneTimeImport does.
	my $top_folders = $root->{Folder} // [];
	my $container   = (@$top_folders == 1 && ($top_folders->[0]{name}//'') =~ /^navMate/i)
		? $top_folders->[0]
		: $root;

	for my $branch (@{$container->{Folder} // []})
	{
		my $bname = $branch->{name} // '';
		next if !$bname;
		next if $bname =~ /\(no import\)/i;
		_walk($dbh, $branch, [$bname]);
	}

	disconnectDB($dbh);

	print "\n==== SUMMARY ====\n";
	printf "  Waypoints inserted:        %d\n", $stats{wp_inserted};
	printf "  Waypoints already present: %d\n", $stats{wp_skipped_exists};
	printf "  Waypoints no destination:  %d\n", $stats{wp_skipped_nocoll};
	printf "  Waypoints bad coordinates: %d\n", $stats{wp_skipped_nocoord};
	printf "  Tracks    inserted:        %d\n", $stats{tr_inserted};
	printf "  Tracks    already present: %d\n", $stats{tr_skipped_exists};
	printf "  Tracks    no destination:  %d\n", $stats{tr_skipped_nocoll};
	printf "  Tracks    no points:       %d\n", $stats{tr_skipped_nopts};
	print "\n";
	print $COMMIT
		? "Changes committed.\n"
		: "No changes written (dry-run). Re-run with --commit to apply.\n";
}


sub _walk
{
	my ($dbh, $folder, $path) = @_;
	for my $sub (@{$folder->{Folder} // []})
	{
		my $sname = $sub->{name} // '';
		next if !$sname;
		_walk($dbh, $sub, [@$path, $sname]);
	}
	for my $pm (@{$folder->{Placemark} // []})
	{
		my $pname = $pm->{name} // '';
		next if $pname eq '';
		next if $pname !~ /~$/;       # the previously-filtered set only
		if    (exists $pm->{Point})      { _recoverWaypoint($dbh, $pm, $path) }
		elsif (exists $pm->{LineString}) { _recoverTrack($dbh, $pm, $path)    }
	}
}


sub _resolvePathInDB
{
	my ($dbh, $path) = @_;
	my $parent = undef;
	for my $name (@$path)
	{
		my $uuid = findCollection($dbh, $name, $parent);
		return undef if !$uuid;
		$parent = $uuid;
	}
	return $parent;
}


sub _recoverWaypoint
{
	my ($dbh, $pm, $path) = @_;
	my $name      = $pm->{name};
	my $path_str  = join(' / ', @$path);
	my $coll_uuid = _resolvePathInDB($dbh, $path);
	if (!$coll_uuid)
	{
		printf "  SKIP  wp  %-30s  no DB folder for: %s\n", $name, $path_str;
		$stats{wp_skipped_nocoll}++;
		return;
	}

	my $existing = $dbh->get_record(
		"SELECT uuid FROM waypoints WHERE name=? AND collection_uuid=?",
		[$name, $coll_uuid]);
	if ($existing)
	{
		$stats{wp_skipped_exists}++;
		return;
	}

	my $raw = $pm->{Point}{coordinates} // '';
	$raw =~ s/^\s+|\s+$//g;
	my ($lon, $lat) = split /,/, $raw;
	if (!(defined $lat && defined $lon))
	{
		printf "  SKIP  wp  %-30s  bad coords at: %s\n", $name, $path_str;
		$stats{wp_skipped_nocoord}++;
		return;
	}

	printf "  %s  wp  %-30s  -> %s\n",
		($COMMIT ? "INSRT" : "would"), $name, $path_str;

	if ($COMMIT)
	{
		insertWaypoint($dbh,
			name            => $name,
			wp_type         => $WP_TYPE_LABEL,
			lat             => $lat + 0,
			lon             => $lon + 0,
			color           => undef,
			created_ts      => $recovery_ts,
			ts_source       => $TS_SOURCE_IMPORT,
			source          => $SOURCE_TAG,
			collection_uuid => $coll_uuid);
	}
	$stats{wp_inserted}++;
}


sub _recoverTrack
{
	my ($dbh, $pm, $path) = @_;
	my $kml_name = $pm->{name};
	my $db_name  = $kml_name;
	$db_name =~ s/~$//;          # strip trailing tilde for tracks only
	my $path_str  = join(' / ', @$path);
	my $coll_uuid = _resolvePathInDB($dbh, $path);
	if (!$coll_uuid)
	{
		printf "  SKIP  tr  %-50s  no DB folder for: %s\n", $db_name, $path_str;
		$stats{tr_skipped_nocoll}++;
		return;
	}

	my $existing = $dbh->get_record(
		"SELECT uuid FROM tracks WHERE name=? AND collection_uuid=?",
		[$db_name, $coll_uuid]);
	if ($existing)
	{
		$stats{tr_skipped_exists}++;
		return;
	}

	my @pts = _parseCoords($pm->{LineString}{coordinates});
	if (!@pts)
	{
		printf "  SKIP  tr  %-50s  no points at: %s\n", $db_name, $path_str;
		$stats{tr_skipped_nopts}++;
		return;
	}

	my ($ts_start, $ts_end, $ts_source) = (0, undef, $TS_SOURCE_IMPORT);
	if (ref($pm->{LookAt}) eq 'HASH')
	{
		my $span = $pm->{LookAt}{'gx:TimeSpan'};
		if (ref($span) eq 'HASH' && $span->{begin})
		{
			$ts_start  = _parseISO($span->{begin});
			$ts_end    = _parseISO($span->{end}) if $span->{end};
			$ts_source = $TS_SOURCE_KML_TIMESPAN if $ts_start;
		}
	}

	printf "  %s  tr  %-50s  -> %s  (pts=%d, kml=%s)\n",
		($COMMIT ? "INSRT" : "would"), $db_name, $path_str, scalar @pts, $kml_name;

	if ($COMMIT)
	{
		my $track_uuid = insertTrack($dbh,
			name            => $db_name,
			color           => undef,
			ts_start        => $ts_start,
			ts_end          => $ts_end,
			ts_source       => $ts_source,
			collection_uuid => $coll_uuid,
			point_count     => scalar @pts);
		insertTrackPoints($dbh, $track_uuid, \@pts);

		# insertTrack does not currently set 'source'; tag it post-insert
		# so this recovery batch is distinguishable from onetimeImport.
		$dbh->do(
			"UPDATE tracks SET source=? WHERE uuid=?",
			[$SOURCE_TAG, $track_uuid]);
	}
	$stats{tr_inserted}++;
}


sub _parseCoords
{
	my ($raw) = @_;
	return () if !$raw;
	my @pts;
	for my $t (split /\s+/, $raw)
	{
		next if $t !~ /,/;
		my ($lon, $lat) = split /,/, $t;
		push @pts, { lat => $lat + 0, lon => $lon + 0 };
	}
	return @pts;
}


sub _parseISO
{
	my ($s) = @_;
	return 0 if !$s;
	return 0 if $s !~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z?$/;
	return eval { timegm($6, $5, $4, $3, $2-1, $1-1900) } // 0;
}


main();

1;
