#---------------------------------------------
# c_db.pm
#---------------------------------------------

package c_db;
use strict;
use warnings;
use threads;
use threads::shared;
use DBI;
use Pub::Utils;
use a_defs;
use a_utils;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		openDB
		newUUID
		insertCollection
		findCollection
		insertWaypoint
		insertRoute
		appendRouteWaypoint
		insertTrack
		insertTrackPoints
		findTrackByNameAndSource
		getTrackTsSource
		updateTrackTimestamps
	);
}


my $dbh;


#---------------------------------
# openDB
#---------------------------------

sub openDB
{
	my $path = "$data_dir/navMate.db";
	display(0,0,"c_db::openDB($path)");

	$dbh = DBI->connect(
		"dbi:SQLite:dbname=$path",
		'', '',
		{ RaiseError => 1, AutoCommit => 1 });

	if (!$dbh)
	{
		error("c_db::openDB failed: $DBI::errstr");
		return 0;
	}

	_createSchema();
	_initKeyValues();
	display(0,0,"c_db::openDB ok");
	return 1;
}


#---------------------------------
# _createSchema
#---------------------------------

sub _createSchema
{
	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS key_values (
			key    TEXT PRIMARY KEY,
			value  TEXT
		)
	});

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS collections (
			uuid        TEXT PRIMARY KEY,
			name        TEXT NOT NULL,
			parent_uuid TEXT REFERENCES collections(uuid),
			node_type   TEXT NOT NULL,
			comment     TEXT DEFAULT ''
		)
	});

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS waypoints (
			uuid            TEXT PRIMARY KEY,
			name            TEXT NOT NULL,
			comment         TEXT DEFAULT '',
			lat             REAL NOT NULL,
			lon             REAL NOT NULL,
			sym             INTEGER DEFAULT 0,
			depth_cm        INTEGER DEFAULT 0,
			created_ts      INTEGER NOT NULL,
			ts_source       TEXT NOT NULL,
			source_file     TEXT,
			source          TEXT,
			collection_uuid TEXT NOT NULL REFERENCES collections(uuid)
		)
	});

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS routes (
			uuid            TEXT PRIMARY KEY,
			name            TEXT NOT NULL,
			comment         TEXT DEFAULT '',
			color           INTEGER DEFAULT 0,
			collection_uuid TEXT NOT NULL REFERENCES collections(uuid)
		)
	});

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS route_waypoints (
			route_uuid TEXT    NOT NULL REFERENCES routes(uuid),
			wp_uuid    TEXT    NOT NULL REFERENCES waypoints(uuid),
			position   INTEGER NOT NULL,
			PRIMARY KEY (route_uuid, position)
		)
	});

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS tracks (
			uuid            TEXT PRIMARY KEY,
			name            TEXT NOT NULL,
			color           INTEGER DEFAULT 0,
			ts_start        INTEGER NOT NULL,
			ts_end          INTEGER,
			ts_source       TEXT NOT NULL,
			point_count     INTEGER,
			source_file     TEXT,
			collection_uuid TEXT NOT NULL REFERENCES collections(uuid)
		)
	});

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS track_points (
			track_uuid TEXT    NOT NULL REFERENCES tracks(uuid),
			position   INTEGER NOT NULL,
			lat        REAL    NOT NULL,
			lon        REAL    NOT NULL,
			depth_cm   INTEGER,
			temp_k     INTEGER,
			ts         INTEGER,
			PRIMARY KEY (track_uuid, position)
		)
	});

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS working_sets (
			uuid       TEXT PRIMARY KEY,
			name       TEXT NOT NULL,
			comment    TEXT DEFAULT '',
			bbox_north REAL,
			bbox_south REAL,
			bbox_east  REAL,
			bbox_west  REAL
		)
	});

	$dbh->do(qq{
		CREATE TABLE IF NOT EXISTS working_set_members (
			ws_uuid     TEXT NOT NULL REFERENCES working_sets(uuid),
			object_uuid TEXT NOT NULL,
			object_type TEXT NOT NULL,
			PRIMARY KEY (ws_uuid, object_uuid)
		)
	});
}


#---------------------------------
# _initKeyValues
#---------------------------------

sub _initKeyValues
{
	$dbh->do("INSERT OR IGNORE INTO key_values (key, value) VALUES ('schema_version', '1')");
	$dbh->do("INSERT OR IGNORE INTO key_values (key, value) VALUES ('uuid_counter', '0')");
}


#---------------------------------
# newUUID
#---------------------------------

sub newUUID
	# Atomically increment uuid_counter and return a new navMate UUID.
{
	my $counter;
	eval
	{
		$dbh->begin_work();
		($counter) = $dbh->selectrow_array(
			"SELECT value FROM key_values WHERE key = 'uuid_counter'");
		$counter++;
		$dbh->do("UPDATE key_values SET value = ? WHERE key = 'uuid_counter'",
			undef, $counter);
		$dbh->commit();
	};
	if ($@)
	{
		eval { $dbh->rollback() };
		error("c_db::newUUID failed: $@");
		return undef;
	}
	return makeUUID($counter);
}


#---------------------------------
# insertCollection
#---------------------------------

sub insertCollection
{
	my ($name, $parent_uuid, $node_type, $comment) = @_;
	my $uuid = newUUID();
	$dbh->do(
		"INSERT INTO collections (uuid, name, parent_uuid, node_type, comment) VALUES (?,?,?,?,?)",
		undef, $uuid, $name, $parent_uuid, $node_type, $comment // '');
	return $uuid;
}


#---------------------------------
# findCollection
#---------------------------------

sub findCollection
{
	my ($name, $parent_uuid) = @_;
	my ($uuid);
	if (defined $parent_uuid)
	{
		($uuid) = $dbh->selectrow_array(
			"SELECT uuid FROM collections WHERE name=? AND parent_uuid=?",
			undef, $name, $parent_uuid);
	}
	else
	{
		($uuid) = $dbh->selectrow_array(
			"SELECT uuid FROM collections WHERE name=? AND parent_uuid IS NULL",
			undef, $name);
	}
	return $uuid;
}


#---------------------------------
# insertWaypoint
#---------------------------------

sub insertWaypoint
{
	my (%a) = @_;
	my $uuid = newUUID();
	$dbh->do(qq{
		INSERT INTO waypoints
			(uuid, name, comment, lat, lon, sym, depth_cm,
			 created_ts, ts_source, source_file, source, collection_uuid)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?)},
		undef,
		$uuid,
		$a{name},
		$a{comment}         // '',
		$a{lat},
		$a{lon},
		$a{sym}             // 0,
		$a{depth_cm}        // 0,
		$a{created_ts},
		$a{ts_source},
		$a{source_file},
		$a{source},
		$a{collection_uuid});
	return $uuid;
}


#---------------------------------
# insertRoute
#---------------------------------

sub insertRoute
{
	my ($name, $color, $comment, $collection_uuid) = @_;
	my $uuid = newUUID();
	$dbh->do(
		"INSERT INTO routes (uuid, name, color, comment, collection_uuid) VALUES (?,?,?,?,?)",
		undef, $uuid, $name, $color // 0, $comment // '', $collection_uuid);
	return $uuid;
}


#---------------------------------
# appendRouteWaypoint
#---------------------------------

sub appendRouteWaypoint
{
	my ($route_uuid, $wp_uuid, $position) = @_;
	$dbh->do(
		"INSERT INTO route_waypoints (route_uuid, wp_uuid, position) VALUES (?,?,?)",
		undef, $route_uuid, $wp_uuid, $position);
	return 1;
}


#---------------------------------
# insertTrack
#---------------------------------

sub insertTrack
{
	my (%a) = @_;
	my $uuid = newUUID();
	$dbh->do(qq{
		INSERT INTO tracks
			(uuid, name, color, ts_start, ts_end, ts_source,
			 point_count, source_file, collection_uuid)
		VALUES (?,?,?,?,?,?,?,?,?)},
		undef,
		$uuid,
		$a{name},
		$a{color}       // 0,
		$a{ts_start}    // 0,
		$a{ts_end},
		$a{ts_source},
		$a{point_count} // 0,
		$a{source_file},
		$a{collection_uuid});
	return $uuid;
}


#---------------------------------
# insertTrackPoints
#---------------------------------

sub insertTrackPoints
{
	my ($track_uuid, $points) = @_;
	return 0 unless @$points;
	my $sth = $dbh->prepare(qq{
		INSERT INTO track_points
			(track_uuid, position, lat, lon, depth_cm, temp_k, ts)
		VALUES (?,?,?,?,?,?,?)});
	eval
	{
		$dbh->begin_work();
		for my $i (0 .. $#$points)
		{
			my $p = $points->[$i];
			$sth->execute(
				$track_uuid, $i,
				$p->{lat}, $p->{lon},
				$p->{depth_cm}, $p->{temp_k}, $p->{ts});
		}
		$dbh->commit();
	};
	if ($@)
	{
		eval { $dbh->rollback() };
		error("c_db::insertTrackPoints failed: $@");
		return 0;
	}
	return scalar @$points;
}


#---------------------------------
# findTrackByNameAndSource
#---------------------------------

sub findTrackByNameAndSource
	# ts_source is optional; omit to match any ts_source.
{
	my ($name, $source_file, $ts_source) = @_;
	if (defined $ts_source)
	{
		my ($uuid) = $dbh->selectrow_array(
			"SELECT uuid FROM tracks WHERE name=? AND source_file=? AND ts_source=?",
			undef, $name, $source_file, $ts_source);
		return $uuid;
	}
	my ($uuid) = $dbh->selectrow_array(
		"SELECT uuid FROM tracks WHERE name=? AND source_file=?",
		undef, $name, $source_file);
	return $uuid;
}


#---------------------------------
# getTrackTsSource
#---------------------------------

sub getTrackTsSource
{
	my ($uuid) = @_;
	my ($ts_source) = $dbh->selectrow_array(
		"SELECT ts_source FROM tracks WHERE uuid=?",
		undef, $uuid);
	return $ts_source;
}


#---------------------------------
# updateTrackTimestamps
#---------------------------------

sub updateTrackTimestamps
{
	my ($uuid, $ts_start, $ts_end, $ts_source) = @_;
	$dbh->do(
		"UPDATE tracks SET ts_start=?, ts_end=?, ts_source=? WHERE uuid=?",
		undef, $ts_start, $ts_end, $ts_source, $uuid);
	return 1;
}


1;
