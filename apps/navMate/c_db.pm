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


1;
