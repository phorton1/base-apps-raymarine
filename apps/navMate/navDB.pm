#---------------------------------------------
# navDB.pm
#---------------------------------------------

package navDB;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Database;
use n_defs;
use n_utils;
use navVisibility qw(pruneDbVisible getDbVisible setDbVisible batchSetDbVisible clearAllDbVisible);


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		openDB
		resetDB
		connectDB
		disconnectDB
		newUUID
		newFSHUUID
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
		getCollectionChildren
		getCollectionCounts
		getCollectionObjects
		findWaypointByLatLon
		getCollection
		getTrack
		getWaypoint
		getRoute
		getRouteWaypointCount
		getCollectionWRGTs
		getCollectionGroups
		getTrackPoints
		getRoutePoints
		getRouteWaypoints
		rawQuery
		deleteCollection
		deleteBranch
		deleteRoute
		deleteWaypoint
		deleteTrack
		isBranchDeleteSafe
		getWaypointRouteRefCount
		getWaypointRoutes
		getGroupWaypoints
		removeRoutePoint
		promoteNavWaypoints
		promoteWaypointOnlyBranches
		updateWaypoint
		insertCollectionUUID
		insertRouteUUID
		updateRoute
		clearRouteWaypoints
		moveWaypoint
		moveCollection
		moveRoute
		moveTrack
		isDBReady
		getCollectionTerminalUUIDs
		getCollectionVisibleState
		setTerminalVisible
		setCollectionVisibleRecursive
		clearAllVisible
		getAllVisibleFeatures
		pruneDbVisibility
		getMinChildPosition
		getMaxChildPosition
		computePushDownPositions
		computeFractionalBetween
		getContainerChildren
		getPositionByAnchor
		compactContainer
		compactAllContainers
	);
}


my $db_path = $NAVMATE_DATABASE;

our $db_ready :shared = 0;

my $db_def = {

	key_values => [
		"key    TEXT PRIMARY KEY",
		"value  TEXT",
	],

	collections => [
		"uuid        TEXT PRIMARY KEY",
		"name        TEXT NOT NULL",
		"parent_uuid TEXT",
		"node_type   TEXT NOT NULL DEFAULT 'branch'",
		"comment     TEXT DEFAULT ''",
		"position    REAL    NOT NULL DEFAULT 0",
		"source      TEXT",
		"created_ts  INTEGER NOT NULL",
		"modified_ts INTEGER",
	],

	waypoints => [
		"uuid            TEXT PRIMARY KEY",
		"name            TEXT NOT NULL",
		"comment         TEXT DEFAULT ''",
		"lat             REAL NOT NULL",
		"lon             REAL NOT NULL",
		"wp_type         TEXT NOT NULL DEFAULT 'nav'",
		"color           TEXT",
		"depth_cm        INTEGER DEFAULT 0",
		"temp_k          INTEGER DEFAULT NULL",
		"created_ts      INTEGER NOT NULL",
		"ts_source       TEXT NOT NULL",
		"source          TEXT",
		"collection_uuid TEXT NOT NULL",
		"db_version      INTEGER NOT NULL DEFAULT 1",
		"e80_version     INTEGER",
		"kml_version     INTEGER",
		"position        REAL    NOT NULL DEFAULT 0",
		"modified_ts     INTEGER",
	],

	routes => [
		"uuid            TEXT PRIMARY KEY",
		"name            TEXT NOT NULL",
		"comment         TEXT DEFAULT ''",
		"color           TEXT DEFAULT NULL",
		"collection_uuid TEXT NOT NULL",
		"db_version      INTEGER NOT NULL DEFAULT 1",
		"e80_version     INTEGER",
		"kml_version     INTEGER",
		"position        REAL    NOT NULL DEFAULT 0",
		"source          TEXT",
		"created_ts      INTEGER NOT NULL",
		"modified_ts     INTEGER",
	],

	route_waypoints => [
		"route_uuid TEXT NOT NULL",
		"wp_uuid    TEXT NOT NULL",
		"position   INTEGER NOT NULL",
		"PRIMARY KEY (route_uuid, position)",
	],

	tracks => [
		"uuid            TEXT PRIMARY KEY",
		"name            TEXT NOT NULL",
		"color           TEXT DEFAULT NULL",
		"ts_start        INTEGER NOT NULL",
		"ts_end          INTEGER",
		"ts_source       TEXT NOT NULL",
		"point_count     INTEGER",
		"collection_uuid TEXT NOT NULL",
		"db_version      INTEGER NOT NULL DEFAULT 1",
		"e80_version     INTEGER",
		"kml_version     INTEGER",
		"position        REAL    NOT NULL DEFAULT 0",
		"companion_uuid  TEXT",
		"source          TEXT",
		"created_ts      INTEGER NOT NULL",
		"modified_ts     INTEGER",
	],

	track_points => [
		"track_uuid TEXT NOT NULL",
		"position   INTEGER NOT NULL",
		"lat        REAL NOT NULL",
		"lon        REAL NOT NULL",
		"depth_cm   INTEGER",
		"temp_k     INTEGER",
		"ts         INTEGER",
		"PRIMARY KEY (track_uuid, position)",
	],

};


#---------------------------------
# openDB
#---------------------------------
# Connect, create/verify schema, disconnect.  Returns 1=ok, 0=error, -1=mismatch.

sub openDB
{
	display(0,0,"navDB::openDB($db_path)");
	$db_ready = 0;

	my $dbh = Pub::Database->connect(_db_params());
	if (!$dbh)
	{
		error("navDB::openDB connect failed");
		return 0;
	}

	if (!_createTables($dbh))
	{
		$dbh->disconnect();
		return 0;
	}
	_initKeyValues($dbh);

	my $rec    = $dbh->get_record("SELECT value FROM key_values WHERE key='schema_version'");
	my $stored = $rec ? $rec->{value} : '0.0';

	if ($stored eq '7.0' || $stored eq '8.0')
	{
		display(0,0,"navDB::openDB migrating schema $stored -> 9.0");
		if ($stored eq '7.0')
		{
			for my $table (qw(collections waypoints routes tracks))
			{
				$dbh->do("ALTER TABLE $table ADD COLUMN visible INTEGER NOT NULL DEFAULT 0", []);
			}
		}
		for my $table (qw(waypoints routes tracks))
		{
			$dbh->do("ALTER TABLE $table ADD COLUMN db_version  INTEGER NOT NULL DEFAULT 1", []);
			$dbh->do("ALTER TABLE $table ADD COLUMN e80_version INTEGER", []);
			$dbh->do("ALTER TABLE $table ADD COLUMN kml_version INTEGER", []);
		}
		$dbh->do("UPDATE key_values SET value='9.0' WHERE key='schema_version'", []);
		$stored = '9.0';
		display(0,0,"navDB::openDB migration to 9.0 complete");
	}

	if ($stored eq '9.0')
	{
		display(0,0,"navDB::openDB migrating schema 9.0 -> 10.0");
		for my $table (qw(collections waypoints routes tracks))
		{
			$dbh->do("ALTER TABLE $table ADD COLUMN position REAL NOT NULL DEFAULT 0", []);
		}
		$dbh->do("UPDATE collections SET position = (
			SELECT COUNT(*) FROM collections c2
			WHERE (c2.parent_uuid = collections.parent_uuid
				OR (c2.parent_uuid IS NULL AND collections.parent_uuid IS NULL))
			AND c2.rowid <= collections.rowid
		)", []);
		$dbh->do("UPDATE waypoints SET position = (
			SELECT COUNT(*) FROM waypoints w2
			WHERE w2.collection_uuid = waypoints.collection_uuid
			AND w2.rowid <= waypoints.rowid
		)", []);
		$dbh->do("UPDATE routes SET position = (
			SELECT COUNT(*) FROM routes r2
			WHERE r2.collection_uuid = routes.collection_uuid
			AND r2.rowid <= routes.rowid
		)", []);
		$dbh->do("UPDATE tracks SET position = (
			SELECT COUNT(*) FROM tracks t2
			WHERE t2.collection_uuid = tracks.collection_uuid
			AND t2.rowid <= tracks.rowid
		)", []);
		$dbh->do("UPDATE key_values SET value='10.0' WHERE key='schema_version'", []);
		$stored = '10.0';
		display(0,0,"navDB::openDB migration to 10.0 complete");
	}

	if ($stored eq '10.0')
	{
		display(0,0,"navDB::openDB migrating schema 10.0 -> 11.0");
		$dbh->do("DROP TABLE IF EXISTS working_set_members", []);
		$dbh->do("DROP TABLE IF EXISTS working_sets", []);
		# drops 'visible' column from all four WRT tables
		for my $table (qw(collections waypoints routes tracks))
		{
			if (!$dbh->dropUnusedTableColumns($table))
			{
				$dbh->disconnect();
				return 0;
			}
		}
		$dbh->do("UPDATE key_values SET value='11.0' WHERE key='schema_version'", []);
		$stored = '11.0';
		display(0,0,"navDB::openDB migration to 11.0 complete");
	}

	if ($stored eq '11.0')
	{
		display(0,0,"navDB::openDB migrating schema 11.0 -> 11.1");
		$dbh->do("ALTER TABLE tracks ADD COLUMN companion_uuid TEXT", []);
		$dbh->do("UPDATE key_values SET value='11.1' WHERE key='schema_version'", []);
		$stored = '11.1';
		display(0,0,"navDB::openDB migration to 11.1 complete");
	}

	if ($stored eq '11.1')
	{
		warning(0,0,"navDB::openDB migrating schema 11.1 -> 11.2");
		$dbh->do("ALTER TABLE waypoints ADD COLUMN temp_k INTEGER DEFAULT NULL", []);
		$dbh->do("UPDATE key_values SET value='11.2' WHERE key='schema_version'", []);
		$stored = '11.2';
		warning(0,0,"navDB::openDB migration to 11.2 complete");
	}

	if ($stored eq '11.2')
	{
		warning(0,0,"navDB::openDB migrating schema 11.2 -> 11.3");

		# Canonical onetimeImport timestamp, derived 2026-05-14 from the
		# live DB: every one of 686 waypoints carries this exact value
		# in created_ts (distinct_ts = 1, ts_source = 'import').
		# Decodes to 2026-05-04 21:39:44 UTC.
		my $ONETIME_IMPORT_TS = 1777930784;

		# waypoints already has source/created_ts; add modified_ts only
		$dbh->do("ALTER TABLE waypoints ADD COLUMN modified_ts INTEGER", []);
		$dbh->do("UPDATE waypoints SET modified_ts = created_ts WHERE modified_ts IS NULL", []);
		# normalize legacy source='' to 'onetimeImport'
		$dbh->do("UPDATE waypoints SET source='onetimeImport' WHERE source IS NULL OR source=''", []);

		# routes, tracks, collections: add all three provenance columns
		for my $table (qw(routes tracks collections))
		{
			$dbh->do("ALTER TABLE $table ADD COLUMN source      TEXT", []);
			$dbh->do("ALTER TABLE $table ADD COLUMN created_ts  INTEGER", []);
			$dbh->do("ALTER TABLE $table ADD COLUMN modified_ts INTEGER", []);
			$dbh->do("UPDATE $table SET source='onetimeImport' WHERE source IS NULL OR source=''", []);
			$dbh->do("UPDATE $table SET created_ts=?, modified_ts=? WHERE created_ts IS NULL",
				[$ONETIME_IMPORT_TS, $ONETIME_IMPORT_TS]);
		}

		$dbh->do("UPDATE key_values SET value='11.3' WHERE key='schema_version'", []);
		$stored = '11.3';
		warning(0,0,"navDB::openDB migration to 11.3 complete");
	}

	# Provenance triggers: auto-populate created_ts and modified_ts.
	# Idempotent (CREATE TRIGGER IF NOT EXISTS); runs every openDB so
	# fresh DBs and migrated DBs both end up with the triggers active.
	# Relies on SQLite's default PRAGMA recursive_triggers = OFF so the
	# triggers' own UPDATEs do not re-fire triggers.
	_createTriggers($dbh);

	my ($stored_major)   = split(/\./, $stored);
	my ($expected_major) = split(/\./, $SCHEMA_VERSION);

	if ($stored_major != $expected_major)
	{
		warning(0,0,"schema_version mismatch: DB has $stored, code expects $SCHEMA_VERSION - reimport required");
		$dbh->disconnect();
		return -1;
	}

	if ($stored ne $SCHEMA_VERSION)
	{
		warning(0,0,"schema_version advisory: DB has $stored, code expects $SCHEMA_VERSION");
	}

	display(0,0,"navDB::openDB ok (schema $stored)");
	$db_ready = 1;
	$dbh->disconnect();
	return 1;
}


#---------------------------------
# connectDB / disconnectDB
#---------------------------------

sub connectDB
{
	return undef if !$db_ready;
	my $dbh = Pub::Database->connect(_db_params());
	error("navDB::connectDB failed") if !$dbh;
	return $dbh;
}


sub disconnectDB
{
	my ($dbh) = @_;
	$dbh->disconnect() if $dbh;
}


#---------------------------------
# resetDB
#---------------------------------
# Delete the database file and re-run openDB (fresh schema).

sub resetDB
{
	Pub::Database::deleteDatabase(_db_params());
	return openDB();
}


#---------------------------------
# _db_params
#---------------------------------

sub _db_params
{
	return {
		engine       => $engine_sqlite,
		database     => $db_path,
		database_def => $db_def,
	};
}


#---------------------------------
# _createTables
#---------------------------------

sub _createTables
{
	my ($dbh) = @_;
	for my $table (qw(
		key_values collections waypoints routes route_waypoints
		tracks track_points))
	{
		next if $dbh->tableExists($table);
		$dbh->createTable($table)
			or return error("navDB::_createTables failed for $table: $dbh->{errstr}");
	}
	return 1;
}


#---------------------------------
# _createTriggers
#---------------------------------
# Provenance triggers on the four WGRT tables.  Each table gets:
#   <table>_insert_ts  - AFTER INSERT, sets created_ts (if not provided)
#                        and modified_ts (= created_ts) using NEW.* and
#                        COALESCE so explicit values win.
#   <table>_update_ts  - AFTER UPDATE, touches modified_ts to current
#                        time UNLESS the UPDATE itself already changed
#                        modified_ts (WHEN OLD.modified_ts IS NEW.modified_ts
#                        guards against trigger overriding an explicit set).
#
# Idempotent via CREATE TRIGGER IF NOT EXISTS.  Recursion safety relies
# on SQLite's default PRAGMA recursive_triggers = OFF.

sub _createTriggers
{
	my ($dbh) = @_;

	for my $table (qw(waypoints routes tracks collections))
	{
		$dbh->do(<<SQL, []);
CREATE TRIGGER IF NOT EXISTS ${table}_insert_ts AFTER INSERT ON $table
FOR EACH ROW
BEGIN
    UPDATE $table
       SET created_ts  = COALESCE(NEW.created_ts, strftime('%s','now')),
           modified_ts = COALESCE(NEW.modified_ts, NEW.created_ts, strftime('%s','now'))
     WHERE uuid = NEW.uuid;
END
SQL

		$dbh->do(<<SQL, []);
CREATE TRIGGER IF NOT EXISTS ${table}_update_ts AFTER UPDATE ON $table
FOR EACH ROW
WHEN OLD.modified_ts IS NEW.modified_ts
BEGIN
    UPDATE $table
       SET modified_ts = strftime('%s','now')
     WHERE uuid = NEW.uuid;
END
SQL
	}

	return 1;
}


#---------------------------------
# _initKeyValues
#---------------------------------

sub _initKeyValues
{
	my ($dbh) = @_;
	$dbh->do("INSERT OR IGNORE INTO key_values (key, value) VALUES ('schema_version', ?)",
		[$SCHEMA_VERSION]);
	$dbh->do("INSERT OR IGNORE INTO key_values (key, value) VALUES ('uuid_counter', '0')");
	$dbh->do("INSERT OR IGNORE INTO key_values (key, value) VALUES ('fsh_uuid_counter', '0')");
}


#---------------------------------
# newUUID
#---------------------------------
# Atomically increment uuid_counter and return a new navMate UUID.

sub newUUID
{
	my ($dbh) = @_;
	my $counter;
	eval
	{
		$dbh->{dbh}->begin_work();
		my $rec = $dbh->get_record("SELECT value FROM key_values WHERE key='uuid_counter'");
		$counter = ($rec ? $rec->{value} : 0) + 1;
		$dbh->do("UPDATE key_values SET value=? WHERE key='uuid_counter'", [$counter]);
		$dbh->commit();
	};
	if ($@)
	{
		eval { $dbh->rollback() };
		error("navDB::newUUID failed: $@");
		return undef;
	}
	return makeUUID($counter);
}


#---------------------------------
# newFSHUUID
#---------------------------------

sub newFSHUUID
{
	my ($dbh) = @_;
	my $counter;
	eval
	{
		$dbh->{dbh}->begin_work();
		my $rec = $dbh->get_record("SELECT value FROM key_values WHERE key='fsh_uuid_counter'");
		$counter = ($rec ? $rec->{value} : 0) + 1;
		$dbh->do("UPDATE key_values SET value=? WHERE key='fsh_uuid_counter'", [$counter]);
		$dbh->commit();
	};
	if ($@)
	{
		eval { $dbh->rollback() };
		error("navDB::newFSHUUID failed: $@");
		return undef;
	}
	return makeFSHUUID($counter);
}


#---------------------------------
# insertCollection
#---------------------------------

sub insertCollection
{
	my ($dbh, $name, $parent_uuid, $node_type, $comment, $position) = @_;
	if (defined $parent_uuid)
	{
		my $pr = $dbh->get_record(
			"SELECT node_type FROM collections WHERE uuid=?", [$parent_uuid]);
		if ($pr && $pr->{node_type} eq $NODE_TYPE_GROUP)
		{
			error("insertCollection: cannot add sub-collection under group '$name'");
			return undef;
		}
	}
	$position = _appendPositionFallback($dbh, $parent_uuid, 'insertCollection', $name)
		if !defined $position;
	my $uuid = newUUID($dbh);
	$dbh->do(
		"INSERT INTO collections (uuid, name, parent_uuid, node_type, comment, position) VALUES (?,?,?,?,?,?)",
		[$uuid, $name, $parent_uuid, $node_type // $NODE_TYPE_BRANCH, $comment // '', $position]);
	return $uuid;
}


sub insertCollectionUUID
{
	my ($dbh, $uuid, $name, $parent_uuid, $node_type, $comment, $position) = @_;
	if (defined $parent_uuid)
	{
		my $pr = $dbh->get_record(
			"SELECT node_type FROM collections WHERE uuid=?", [$parent_uuid]);
		if ($pr && $pr->{node_type} eq $NODE_TYPE_GROUP)
		{
			error("insertCollectionUUID: cannot add sub-collection under group '$name'");
			return undef;
		}
	}
	$position = _appendPositionFallback($dbh, $parent_uuid, 'insertCollectionUUID', $name)
		if !defined $position;
	$dbh->do(
		"INSERT INTO collections (uuid, name, parent_uuid, node_type, comment, position) VALUES (?,?,?,?,?,?)",
		[$uuid, $name, $parent_uuid, $node_type // $NODE_TYPE_BRANCH, $comment // '', $position]);
	return $uuid;
}


#---------------------------------
# findCollection
#---------------------------------

sub findCollection
{
	my ($dbh, $name, $parent_uuid) = @_;
	my $rec;
	if (defined $parent_uuid)
	{
		$rec = $dbh->get_record(
			"SELECT uuid FROM collections WHERE name=? AND parent_uuid=?",
			[$name, $parent_uuid]);
	}
	else
	{
		$rec = $dbh->get_record(
			"SELECT uuid FROM collections WHERE name=? AND parent_uuid IS NULL",
			[$name]);
	}
	return $rec ? $rec->{uuid} : undef;
}


#---------------------------------
# insertWaypoint
#---------------------------------

sub insertWaypoint
{
	my ($dbh, %a) = @_;
	my $uuid = $a{uuid} // newUUID($dbh);
	my $position = $a{position};
	$position = _appendPositionFallback($dbh, $a{collection_uuid}, 'insertWaypoint', $a{name})
		if !defined $position;
	$dbh->do(qq{
		INSERT INTO waypoints
			(uuid, name, comment, lat, lon, wp_type, color, depth_cm, temp_k,
			 created_ts, ts_source, source, collection_uuid, position)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)},
		[$uuid,
		$a{name},
		$a{comment}         // '',
		$a{lat},
		$a{lon},
		$a{wp_type}         // $WP_TYPE_NAV,
		$a{color},
		$a{depth_cm}        // 0,
		$a{temp_k}          || undef,
		$a{created_ts},
		$a{ts_source},
		$a{source},
		$a{collection_uuid},
		$position]);
	return $uuid;
}


sub updateWaypoint
{
	my ($dbh, $uuid, %a) = @_;
	$dbh->do(qq{
		UPDATE waypoints SET
			name=?, comment=?, lat=?, lon=?, wp_type=?, color=?,
			depth_cm=?, temp_k=?, created_ts=?, ts_source=?, source=?
		WHERE uuid=?},
		[$a{name},
		$a{comment}  // '',
		$a{lat},
		$a{lon},
		$a{wp_type}  // $WP_TYPE_NAV,
		$a{color},
		$a{depth_cm} // 0,
		$a{temp_k}   || undef,
		$a{created_ts},
		$a{ts_source},
		$a{source},
		$uuid]);
	return 1;
}


#---------------------------------
# insertRoute
#---------------------------------

sub insertRoute
{
	my ($dbh, $name, $color, $comment, $collection_uuid, $position) = @_;
	$position = _appendPositionFallback($dbh, $collection_uuid, 'insertRoute', $name)
		if !defined $position;
	my $uuid = newUUID($dbh);
	$dbh->do(
		"INSERT INTO routes (uuid, name, color, comment, collection_uuid, position) VALUES (?,?,?,?,?,?)",
		[$uuid, $name, $color // 0, $comment // '', $collection_uuid, $position]);
	return $uuid;
}


sub insertRouteUUID
{
	my ($dbh, $uuid, $name, $color, $comment, $collection_uuid, $position) = @_;
	$position = _appendPositionFallback($dbh, $collection_uuid, 'insertRouteUUID', $name)
		if !defined $position;
	$dbh->do(
		"INSERT INTO routes (uuid, name, color, comment, collection_uuid, position) VALUES (?,?,?,?,?,?)",
		[$uuid, $name, $color // 0, $comment // '', $collection_uuid, $position]);
	return $uuid;
}


sub updateRoute
{
	my ($dbh, $uuid, $name, $color, $comment) = @_;
	$dbh->do(
		"UPDATE routes SET name=?, color=?, comment=? WHERE uuid=?",
		[$name, $color // 0, $comment // '', $uuid]);
	return 1;
}


#---------------------------------
# appendRouteWaypoint
#---------------------------------

sub appendRouteWaypoint
{
	my ($dbh, $route_uuid, $wp_uuid, $position) = @_;
	$dbh->do(
		"INSERT INTO route_waypoints (route_uuid, wp_uuid, position) VALUES (?,?,?)",
		[$route_uuid, $wp_uuid, $position]);
	return 1;
}


#---------------------------------
# insertTrack
#---------------------------------

sub insertTrack
{
	my ($dbh, %a) = @_;
	my $uuid = $a{uuid} // newUUID($dbh);
	my $position = $a{position};
	$position = _appendPositionFallback($dbh, $a{collection_uuid}, 'insertTrack', $a{name})
		if !defined $position;
	$dbh->do(qq{
		INSERT INTO tracks
			(uuid, name, color, ts_start, ts_end, ts_source,
			 point_count, collection_uuid, companion_uuid, position)
		VALUES (?,?,?,?,?,?,?,?,?,?)},
		[$uuid,
		$a{name},
		$a{color}          // 0,
		$a{ts_start}       // 0,
		$a{ts_end},
		$a{ts_source},
		$a{point_count}    // 0,
		$a{collection_uuid},
		$a{companion_uuid},
		$position]);
	return $uuid;
}


#---------------------------------
# insertTrackPoints
#---------------------------------

sub insertTrackPoints
{
	my ($dbh, $track_uuid, $points) = @_;
	return 0 if !@$points;
	my $sth = $dbh->{dbh}->prepare(qq{
		INSERT INTO track_points
			(track_uuid, position, lat, lon, depth_cm, temp_k, ts)
		VALUES (?,?,?,?,?,?,?)});
	eval
	{
		$dbh->{dbh}->begin_work();
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
		error("navDB::insertTrackPoints failed: $@");
		return 0;
	}
	return scalar @$points;
}


#---------------------------------
# findTrackByNameAndSource
#---------------------------------
# ts_source is optional; omit to match any ts_source.

sub findTrackByNameAndSource
{
	my ($dbh, $name, $ts_source) = @_;
	my $rec;
	if (defined $ts_source)
	{
		$rec = $dbh->get_record(
			"SELECT uuid FROM tracks WHERE name=? AND ts_source=?",
			[$name, $ts_source]);
	}
	else
	{
		$rec = $dbh->get_record(
			"SELECT uuid FROM tracks WHERE name=?",
			[$name]);
	}
	return $rec ? $rec->{uuid} : undef;
}


#---------------------------------
# getTrackTsSource
#---------------------------------

sub getTrackTsSource
{
	my ($dbh, $uuid) = @_;
	my $rec = $dbh->get_record(
		"SELECT ts_source FROM tracks WHERE uuid=?", [$uuid]);
	return $rec ? $rec->{ts_source} : undef;
}


#---------------------------------
# updateTrackTimestamps
#---------------------------------

sub updateTrackTimestamps
{
	my ($dbh, $uuid, $ts_start, $ts_end, $ts_source) = @_;
	$dbh->do(
		"UPDATE tracks SET ts_start=?, ts_end=?, ts_source=? WHERE uuid=?",
		[$ts_start, $ts_end, $ts_source, $uuid]);
	return 1;
}


#---------------------------------
# getCollectionChildren
#---------------------------------

sub getCollectionChildren
{
	my ($dbh, $parent_uuid) = @_;
	if (defined $parent_uuid)
	{
		return $dbh->get_records(
			"SELECT uuid, name, node_type, comment FROM collections WHERE parent_uuid=? ORDER BY position",
			[$parent_uuid]);
	}
	return $dbh->get_records(
		"SELECT uuid, name, node_type, comment FROM collections WHERE parent_uuid IS NULL ORDER BY position");
}


#---------------------------------
# getCollectionCounts
#---------------------------------

sub getCollectionCounts
{
	my ($dbh, $coll_uuid) = @_;
	my $r_g = $dbh->get_record("SELECT COUNT(*) AS n FROM collections WHERE parent_uuid=? AND node_type='group'",  [$coll_uuid]);
	my $r_b = $dbh->get_record("SELECT COUNT(*) AS n FROM collections WHERE parent_uuid=? AND node_type='branch'", [$coll_uuid]);
	my $r_w = $dbh->get_record("SELECT COUNT(*) AS n FROM waypoints   WHERE collection_uuid=?", [$coll_uuid]);
	my $r_r = $dbh->get_record("SELECT COUNT(*) AS n FROM routes      WHERE collection_uuid=?", [$coll_uuid]);
	my $r_t = $dbh->get_record("SELECT COUNT(*) AS n FROM tracks      WHERE collection_uuid=?", [$coll_uuid]);
	my $ng = ($r_g ? $r_g->{n} : 0) + 0;
	my $nb = ($r_b ? $r_b->{n} : 0) + 0;
	return {
		collections => $ng + $nb,
		groups      => $ng,
		branches    => $nb,
		waypoints   => ($r_w ? $r_w->{n} : 0) + 0,
		routes      => ($r_r ? $r_r->{n} : 0) + 0,
		tracks      => ($r_t ? $r_t->{n} : 0) + 0,
	};
}


#---------------------------------
# getCollectionObjects
#---------------------------------
# Returns leaf objects in a collection ordered by type then rowid.

sub getCollectionObjects
{
	my ($dbh, $coll_uuid) = @_;
	my @objects;
	my $wps = $dbh->get_records(
		"SELECT uuid, name, 'waypoint' AS obj_type, lat, lon, wp_type, color
		 FROM waypoints WHERE collection_uuid=? ORDER BY position",
		[$coll_uuid]);
	push @objects, @$wps;
	my $routes = $dbh->get_records(
		"SELECT uuid, name, color, 'route' AS obj_type
		 FROM routes WHERE collection_uuid=? ORDER BY position",
		[$coll_uuid]);
	push @objects, @$routes;
	my $tracks = $dbh->get_records(
		"SELECT uuid, name, color, 'track' AS obj_type, ts_start, ts_end, ts_source, point_count
		 FROM tracks WHERE collection_uuid=? ORDER BY position",
		[$coll_uuid]);
	push @objects, @$tracks;
	return \@objects;
}


#---------------------------------
# findWaypointByLatLon
#---------------------------------

sub findWaypointByLatLon
{
	my ($dbh, $lat, $lon) = @_;
	my $rec = $dbh->get_record(
		"SELECT uuid FROM waypoints WHERE ABS(lat-?) < 0.000001 AND ABS(lon-?) < 0.000001 LIMIT 1",
		[$lat, $lon]);
	return $rec ? $rec->{uuid} : undef;
}


#---------------------------------
# getCollection
#---------------------------------

sub getCollection
{
	my ($dbh, $uuid) = @_;
	return $dbh->get_record(
		"SELECT uuid, name, parent_uuid, node_type, comment, position, source, created_ts, modified_ts FROM collections WHERE uuid=?",
		[$uuid]);
}


#---------------------------------
# getTrack
#---------------------------------

sub getTrack
{
	my ($dbh, $uuid) = @_;
	return $dbh->get_record(
		"SELECT uuid, name, color, ts_start, ts_end, ts_source, point_count, collection_uuid, position, companion_uuid, source, created_ts, modified_ts FROM tracks WHERE uuid=?",
		[$uuid]);
}


#---------------------------------
# getWaypoint
#---------------------------------

sub getWaypoint
{
	my ($dbh, $uuid) = @_;
	return $dbh->get_record(
		"SELECT uuid, name, comment, lat, lon, wp_type, color, depth_cm, temp_k, created_ts, ts_source, source, collection_uuid, position, modified_ts FROM waypoints WHERE uuid=?",
		[$uuid]);
}


#---------------------------------
# getRoute
#---------------------------------

sub getRoute
{
	my ($dbh, $uuid) = @_;
	return $dbh->get_record(
		"SELECT uuid, name, comment, color, collection_uuid, position, source, created_ts, modified_ts FROM routes WHERE uuid=?",
		[$uuid]);
}


#---------------------------------
# getRouteWaypointCount
#---------------------------------

sub getRouteWaypointCount
{
	my ($dbh, $uuid) = @_;
	my $rec = $dbh->get_record(
		"SELECT COUNT(*) AS n FROM route_waypoints WHERE route_uuid=?",
		[$uuid]);
	return $rec ? $rec->{n} + 0 : 0;
}


#---------------------------------
# getCollectionWRGTs
#---------------------------------
# Returns all waypoints, routes, and tracks under $uuid and all
# descendant collections (recursive).  Uses WITH RECURSIVE CTE.

sub getCollectionWRGTs
{
	my ($dbh, $uuid) = @_;
	my $cte = qq{
		WITH RECURSIVE tree(uuid) AS (
			SELECT uuid FROM collections WHERE uuid=?
			UNION ALL
			SELECT c.uuid FROM collections c JOIN tree ON c.parent_uuid=tree.uuid
		)
	};
	my $wps = $dbh->get_records(
		$cte . "SELECT uuid, name, comment, lat, lon, wp_type, color, depth_cm,
		        created_ts, ts_source, source, collection_uuid
		        FROM waypoints WHERE collection_uuid IN (SELECT uuid FROM tree)",
		[$uuid]);
	my $routes = $dbh->get_records(
		$cte . "SELECT uuid, name, comment, color, collection_uuid
		        FROM routes WHERE collection_uuid IN (SELECT uuid FROM tree)",
		[$uuid]);
	my $tracks = $dbh->get_records(
		$cte . "SELECT uuid, name, color, ts_start, ts_end, ts_source,
		        point_count, collection_uuid
		        FROM tracks WHERE collection_uuid IN (SELECT uuid FROM tree)",
		[$uuid]);
	return {
		waypoints => $wps    // [],
		routes    => $routes // [],
		tracks    => $tracks // [],
	};
}


#---------------------------------
# getCollectionVisibleState
#---------------------------------
# Returns 0 (none visible), 1 (all visible), or 2 (some visible) for the
# terminal objects (waypoints, routes, tracks) under $uuid and all
# descendant collections.  Empty collections return 0.

sub getCollectionVisibleState
{
	my ($dbh, $uuid) = @_;
	my $uuids = getCollectionTerminalUUIDs($dbh, $uuid);
	return 0 if !@$uuids;
	my $vis = grep { getDbVisible($_) } @$uuids;
	return 0 if $vis == 0;
	return 1 if $vis == scalar @$uuids;
	return 2;
}


#---------------------------------
# getCollectionTerminalUUIDs
#---------------------------------
# Returns arrayref of all waypoint/route/track UUIDs under $uuid (recursive).

sub getCollectionTerminalUUIDs
{
	my ($dbh, $uuid) = @_;
	my $cte = qq{
		WITH RECURSIVE tree(uuid) AS (
			SELECT uuid FROM collections WHERE uuid=?
			UNION ALL
			SELECT c.uuid FROM collections c JOIN tree ON c.parent_uuid=tree.uuid
		)
	};
	my $wps    = $dbh->get_records($cte . "SELECT uuid FROM waypoints WHERE collection_uuid IN (SELECT uuid FROM tree)", [$uuid]);
	my $routes = $dbh->get_records($cte . "SELECT uuid FROM routes    WHERE collection_uuid IN (SELECT uuid FROM tree)", [$uuid]);
	my $tracks = $dbh->get_records($cte . "SELECT uuid FROM tracks    WHERE collection_uuid IN (SELECT uuid FROM tree)", [$uuid]);
	return [
		(map { $_->{uuid} } @{$wps    // []}),
		(map { $_->{uuid} } @{$routes // []}),
		(map { $_->{uuid} } @{$tracks // []}),
	];
}


#---------------------------------
# setTerminalVisible
#---------------------------------

sub setTerminalVisible
{
	my ($dbh, $uuid, $obj_type, $visible) = @_;
	setDbVisible($uuid, $visible);
	return 1;
}


#---------------------------------
# setCollectionVisibleRecursive
#---------------------------------

sub setCollectionVisibleRecursive
{
	my ($dbh, $uuid, $visible) = @_;
	my $uuids = getCollectionTerminalUUIDs($dbh, $uuid);
	batchSetDbVisible($visible, $uuids);
	return 1;
}


#---------------------------------
# clearAllVisible
#---------------------------------

sub clearAllVisible
{
	my ($dbh) = @_;
	clearAllDbVisible();
	return 1;
}


#---------------------------------
# pruneDbVisibility
#---------------------------------

sub pruneDbVisibility
{
	my $dbh = connectDB();
	return if !$dbh;
	my %live;
	for my $table (qw(waypoints routes tracks))
	{
		my $rows = $dbh->get_records("SELECT uuid FROM $table", []);
		$live{$_->{uuid}} = 1 for @{$rows // []};
	}
	disconnectDB($dbh);
	pruneDbVisible(\%live);
}


#---------------------------------
# getAllVisibleFeatures
#---------------------------------
# Returns all visible terminal objects with enough data for Leaflet rendering.
# Routes include their ordered waypoints; tracks include their points.

sub getAllVisibleFeatures
{
	my ($dbh) = @_;
	my $all_wps = $dbh->get_records(
		"SELECT uuid, name, comment, lat, lon, wp_type, color, depth_cm,
		 created_ts, ts_source, source, collection_uuid
		 FROM waypoints", []);
	my $wps = [grep { getDbVisible($_->{uuid}) } @{$all_wps // []}];

	my $all_routes = $dbh->get_records(
		"SELECT uuid, name, comment, color, collection_uuid FROM routes", []);
	my $routes = [grep { getDbVisible($_->{uuid}) } @{$all_routes // []}];

	my $all_tracks = $dbh->get_records(
		"SELECT uuid, name, color, ts_start, ts_end, ts_source, point_count, collection_uuid
		 FROM tracks", []);
	my $tracks = [grep { getDbVisible($_->{uuid}) } @{$all_tracks // []}];

	for my $r (@$routes) { $r->{waypoints} = getRouteWaypoints($dbh, $r->{uuid}) }
	for my $t (@$tracks) { $t->{points}    = getTrackPoints($dbh,    $t->{uuid}) }
	return {
		waypoints => $wps,
		routes    => $routes,
		tracks    => $tracks,
	};
}


#---------------------------------
# getCollectionGroups
#---------------------------------
# Returns all node_type='group' collections in the sub-tree rooted at
# $coll_uuid, with their member waypoints.
# Returns arrayref of { uuid, name, waypoints => [{uuid,name,lat,lon}] }.

sub getCollectionGroups
{
	my ($dbh, $coll_uuid) = @_;
	my $rows = $dbh->get_records(qq{
		WITH RECURSIVE tree(uuid) AS (
			SELECT uuid FROM collections WHERE parent_uuid=?
			UNION ALL
			SELECT c.uuid FROM collections c JOIN tree ON c.parent_uuid=tree.uuid
		)
		SELECT col.uuid AS coll_uuid, col.name AS coll_name,
		       w.uuid   AS wp_uuid,   w.name   AS wp_name,
		       w.lat, w.lon
		FROM tree t
		JOIN collections col ON col.uuid=t.uuid AND col.node_type='group'
		JOIN waypoints w ON w.collection_uuid=col.uuid
		ORDER BY col.name, w.position
	}, [$coll_uuid]);

	my @groups;
	my %idx;
	for my $row (@{$rows // []})
	{
		my $cu = $row->{coll_uuid};
		if (!exists $idx{$cu})
		{
			$idx{$cu} = scalar @groups;
			push @groups, { uuid => $cu, name => $row->{coll_name}, waypoints => [] };
		}
		push @{$groups[$idx{$cu}]->{waypoints}}, {
			uuid => $row->{wp_uuid},
			name => $row->{wp_name},
			lat  => $row->{lat},
			lon  => $row->{lon},
		};
	}
	return \@groups;
}


#---------------------------------
# getTrackPoints
#---------------------------------

sub getTrackPoints
{
	my ($dbh, $uuid) = @_;
	return $dbh->get_records(
		"SELECT lat, lon, depth_cm, temp_k, ts FROM track_points WHERE track_uuid=? ORDER BY position",
		[$uuid]);
}


#---------------------------------
# getRoutePoints
#---------------------------------
# Returns ordered lat/lon via route_waypoints JOIN waypoints.

sub getRoutePoints
{
	my ($dbh, $uuid) = @_;
	return $dbh->get_records(
		"SELECT w.lat, w.lon FROM route_waypoints rw JOIN waypoints w ON rw.wp_uuid=w.uuid WHERE rw.route_uuid=? ORDER BY rw.position",
		[$uuid]);
}


#---------------------------------
# getRouteWaypoints
#---------------------------------
# Returns ordered waypoint records (uuid, name, lat, lon) for a route.

sub getRouteWaypoints
{
	my ($dbh, $uuid) = @_;
	return $dbh->get_records(
		"SELECT w.uuid, w.name, w.lat, w.lon, rw.position
		 FROM route_waypoints rw JOIN waypoints w ON rw.wp_uuid=w.uuid
		 WHERE rw.route_uuid=? ORDER BY rw.position",
		[$uuid]);
}


#---------------------------------
# removeRoutePoint
#---------------------------------
# Removes one waypoint occurrence from a route by DB position value,
# then decrements all higher positions to keep the sequence contiguous.

sub removeRoutePoint
{
	my ($dbh, $route_uuid, $position) = @_;
	$dbh->do(
		"DELETE FROM route_waypoints WHERE route_uuid=? AND position=?",
		[$route_uuid, $position]);
	$dbh->do(
		"UPDATE route_waypoints SET position=position-1 WHERE route_uuid=? AND position>?",
		[$route_uuid, $position]);
}


sub clearRouteWaypoints
{
	my ($dbh, $route_uuid) = @_;
	$dbh->do("DELETE FROM route_waypoints WHERE route_uuid=?", [$route_uuid]);
}


#---------------------------------
# move* - re-home an object to a different collection/parent
#---------------------------------

sub moveWaypoint
{
	my ($dbh, $uuid, $new_coll_uuid, $position) = @_;
	$position = _appendPositionFallback($dbh, $new_coll_uuid, 'moveWaypoint', $uuid)
		if !defined $position;
	$dbh->do("UPDATE waypoints SET collection_uuid=?, position=? WHERE uuid=?",
		[$new_coll_uuid, $position, $uuid]);
	return 1;
}


sub moveCollection
{
	my ($dbh, $uuid, $new_parent_uuid, $position) = @_;
	if (defined $new_parent_uuid)
	{
		my $pr = $dbh->get_record(
			"SELECT node_type FROM collections WHERE uuid=?", [$new_parent_uuid]);
		if ($pr && $pr->{node_type} eq $NODE_TYPE_GROUP)
		{
			error("moveCollection: cannot move collection under group");
			return undef;
		}
	}
	$position = _appendPositionFallback($dbh, $new_parent_uuid, 'moveCollection', $uuid)
		if !defined $position;
	$dbh->do("UPDATE collections SET parent_uuid=?, position=? WHERE uuid=?",
		[$new_parent_uuid, $position, $uuid]);
	return 1;
}


sub moveRoute
{
	my ($dbh, $uuid, $new_coll_uuid, $position) = @_;
	$position = _appendPositionFallback($dbh, $new_coll_uuid, 'moveRoute', $uuid)
		if !defined $position;
	$dbh->do("UPDATE routes SET collection_uuid=?, position=? WHERE uuid=?",
		[$new_coll_uuid, $position, $uuid]);
	return 1;
}


sub moveTrack
{
	my ($dbh, $uuid, $new_coll_uuid, $position) = @_;
	$position = _appendPositionFallback($dbh, $new_coll_uuid, 'moveTrack', $uuid)
		if !defined $position;
	$dbh->do("UPDATE tracks SET collection_uuid=?, position=? WHERE uuid=?",
		[$new_coll_uuid, $position, $uuid]);
	return 1;
}


#---------------------------------
# deleteCollection
#---------------------------------

sub deleteCollection
{
	my ($dbh, $uuid) = @_;
	$dbh->do("DELETE FROM collections WHERE uuid=?", [$uuid]);
}


#---------------------------------
# isBranchDeleteSafe
#---------------------------------
# Returns 1 if deleting the branch at $uuid (recursively) would not orphan
# any route_waypoints rows - i.e. every route that references a WP in the
# subtree is itself inside the same subtree. Returns 0 if any WP is referenced
# by a route that lives outside the branch.

sub isBranchDeleteSafe
{
	my ($dbh, $uuid) = @_;
	my $col_rows = $dbh->get_records(
		"WITH RECURSIVE subtree(uuid) AS (
			SELECT uuid FROM collections WHERE uuid = ?
			UNION ALL
			SELECT c.uuid FROM collections c JOIN subtree s ON c.parent_uuid = s.uuid
		) SELECT uuid FROM subtree",
		[$uuid]);
	return 1 if !@$col_rows;
	my @col_uuids = map { $_->{uuid} } @$col_rows;
	my $col_ph    = join(',', map { '?' } @col_uuids);
	my $wp_rows   = $dbh->get_records(
		"SELECT uuid FROM waypoints WHERE collection_uuid IN ($col_ph)",
		\@col_uuids);
	return 1 if !@$wp_rows;
	my $rt_rows = $dbh->get_records(
		"SELECT uuid FROM routes WHERE collection_uuid IN ($col_ph)",
		\@col_uuids);
	my %route_set = map { $_->{uuid} => 1 } @$rt_rows;
	my @wp_uuids  = map { $_->{uuid} } @$wp_rows;
	my $wp_ph     = join(',', map { '?' } @wp_uuids);
	my $ref_rows  = $dbh->get_records(
		"SELECT DISTINCT route_uuid FROM route_waypoints WHERE wp_uuid IN ($wp_ph)",
		\@wp_uuids);
	for my $row (@$ref_rows)
	{
		return 0 if !$route_set{$row->{route_uuid}};
	}
	return 1;
}


#---------------------------------
# deleteBranch
#---------------------------------
# Recursively deletes a branch and all its descendants. Caller must verify
# safety with isBranchDeleteSafe before calling.

sub deleteBranch
{
	my ($dbh, $uuid) = @_;
	my $col_rows = $dbh->get_records(
		"WITH RECURSIVE subtree(uuid) AS (
			SELECT uuid FROM collections WHERE uuid = ?
			UNION ALL
			SELECT c.uuid FROM collections c JOIN subtree s ON c.parent_uuid = s.uuid
		) SELECT uuid FROM subtree",
		[$uuid]);
	return if !@$col_rows;
	my @col_uuids = map { $_->{uuid} } @$col_rows;
	my $col_ph    = join(',', map { '?' } @col_uuids);
	my $rt_rows = $dbh->get_records(
		"SELECT uuid FROM routes WHERE collection_uuid IN ($col_ph)",
		\@col_uuids);
	if (@$rt_rows)
	{
		my @rt_uuids = map { $_->{uuid} } @$rt_rows;
		my $rt_ph = join(',', map { '?' } @rt_uuids);
		$dbh->do("DELETE FROM route_waypoints WHERE route_uuid IN ($rt_ph)", \@rt_uuids);
	}
	my $tk_rows = $dbh->get_records(
		"SELECT uuid FROM tracks WHERE collection_uuid IN ($col_ph)",
		\@col_uuids);
	if (@$tk_rows)
	{
		my @tk_uuids = map { $_->{uuid} } @$tk_rows;
		my $tk_ph = join(',', map { '?' } @tk_uuids);
		$dbh->do("DELETE FROM track_points WHERE track_uuid IN ($tk_ph)", \@tk_uuids);
	}
	$dbh->do("DELETE FROM waypoints   WHERE collection_uuid IN ($col_ph)", \@col_uuids);
	$dbh->do("DELETE FROM routes      WHERE collection_uuid IN ($col_ph)", \@col_uuids);
	$dbh->do("DELETE FROM tracks      WHERE collection_uuid IN ($col_ph)", \@col_uuids);
	$dbh->do("DELETE FROM collections WHERE uuid IN ($col_ph)",            \@col_uuids);
}


#---------------------------------
# deleteRoute
#---------------------------------

sub deleteRoute
{
	my ($dbh, $uuid) = @_;
	$dbh->do("DELETE FROM route_waypoints WHERE route_uuid=?", [$uuid]);
	$dbh->do("DELETE FROM routes WHERE uuid=?", [$uuid]);
}


#---------------------------------
# deleteWaypoint
#---------------------------------

sub deleteWaypoint
{
	my ($dbh, $uuid) = @_;
	$dbh->do("DELETE FROM waypoints WHERE uuid=?", [$uuid]);
}


#---------------------------------
# deleteTrack
#---------------------------------

sub deleteTrack
{
	my ($dbh, $uuid) = @_;
	$dbh->do("DELETE FROM track_points WHERE track_uuid=?", [$uuid]);
	$dbh->do("DELETE FROM tracks WHERE uuid=?", [$uuid]);
}


#---------------------------------
# getWaypointRouteRefCount
#---------------------------------

sub getWaypointRouteRefCount
{
	my ($dbh, $uuid) = @_;
	my $rec = $dbh->get_record(
		"SELECT COUNT(*) AS n FROM route_waypoints WHERE wp_uuid=?",
		[$uuid]);
	return $rec ? $rec->{n} + 0 : 0;
}


#---------------------------------
# getWaypointRoutes
#---------------------------------
# Returns [{route_uuid, route_name, position}] for every route containing $wp_uuid.

sub getWaypointRoutes
{
	my ($dbh, $wp_uuid) = @_;
	return $dbh->get_records(
		"SELECT rw.route_uuid, r.name AS route_name, rw.position
		 FROM route_waypoints rw JOIN routes r ON rw.route_uuid=r.uuid
		 WHERE rw.wp_uuid=? ORDER BY r.name",
		[$wp_uuid]);
}


#---------------------------------
# getGroupWaypoints
#---------------------------------
# Returns [{uuid, name}] for all waypoints directly in a group collection.

sub getGroupWaypoints
{
	my ($dbh, $collection_uuid) = @_;
	return $dbh->get_records(
		"SELECT uuid, name FROM waypoints WHERE collection_uuid=? ORDER BY position",
		[$collection_uuid]);
}


#---------------------------------
# promoteNavWaypoints
#---------------------------------
# Post-import pass: any 'label' waypoint in the tree under $top_uuid that is
# referenced in route_waypoints, or is within $tol degrees of a track start or
# end point, is promoted to 'nav'.  Everything else stays 'label'.

sub promoteNavWaypoints
{
	my ($dbh, $top_uuid, $tol) = @_;
	$tol //= 0.001;

	my $cte = "WITH RECURSIVE tree(uuid) AS (
		SELECT uuid FROM collections WHERE uuid=?
		UNION ALL
		SELECT c.uuid FROM collections c JOIN tree ON c.parent_uuid=tree.uuid
	) ";

	my $wps = $dbh->get_records(
		$cte . "SELECT uuid, lat, lon FROM waypoints
		        WHERE collection_uuid IN (SELECT uuid FROM tree)
		        AND wp_type = 'label'",
		[$top_uuid]);
	return 0 if !@$wps;

	my $route_rows = $dbh->get_records(
		$cte . "SELECT DISTINCT rw.wp_uuid
		        FROM route_waypoints rw
		        JOIN routes r ON rw.route_uuid = r.uuid
		        WHERE r.collection_uuid IN (SELECT uuid FROM tree)",
		[$top_uuid]);
	my %in_route = map { $_->{wp_uuid} => 1 } @{$route_rows // []};

	my $eps = $dbh->get_records(
		$cte . "SELECT tp.lat, tp.lon
		        FROM track_points tp
		        JOIN tracks t ON tp.track_uuid = t.uuid
		        WHERE t.collection_uuid IN (SELECT uuid FROM tree)
		        AND (tp.position = 0
		             OR (t.point_count > 0 AND tp.position = t.point_count - 1))",
		[$top_uuid]);

	my $promoted = 0;
	for my $wp (@$wps)
	{
		my $is_nav = $in_route{$wp->{uuid}};
		if (!$is_nav)
		{
			for my $ep (@{$eps // []})
			{
				if (abs($wp->{lat} - $ep->{lat}) <= $tol
				 && abs($wp->{lon} - $ep->{lon}) <= $tol)
				{
					$is_nav = 1;
					last;
				}
			}
		}
		if ($is_nav)
		{
			$dbh->do("UPDATE waypoints SET wp_type='nav' WHERE uuid=?", [$wp->{uuid}]);
			$promoted++;
		}
	}
	return $promoted;
}


#---------------------------------
# promoteWaypointOnlyBranches
#---------------------------------
# Post-import pass: any branch collection that has at least one direct waypoint
# and no sub-collections, routes, or tracks is promoted to node_type='group'.

sub promoteWaypointOnlyBranches
{
	my ($dbh) = @_;
	my $rows = $dbh->get_records(
		"SELECT uuid FROM collections
		 WHERE node_type = 'branch'
		   AND EXISTS     (SELECT 1 FROM waypoints    w  WHERE w.collection_uuid  = collections.uuid)
		   AND NOT EXISTS (SELECT 1 FROM collections  cc WHERE cc.parent_uuid     = collections.uuid)
		   AND NOT EXISTS (SELECT 1 FROM routes       r  WHERE r.collection_uuid  = collections.uuid)
		   AND NOT EXISTS (SELECT 1 FROM tracks       t  WHERE t.collection_uuid  = collections.uuid)",
		[]);
	my $n = 0;
	for my $row (@$rows)
	{
		$dbh->do("UPDATE collections SET node_type='group' WHERE uuid=?", [$row->{uuid}]);
		$n++;
	}
	display(0,1,"  promoted $n branch(es) to group") if $n;
	return $n;
}


sub isDBReady { return $db_ready }


#---------------------------------
# rawQuery
#---------------------------------
# Debug endpoint - SELECT only.

sub rawQuery
{
	my ($dbh, $sql) = @_;
	my $rows = eval { $dbh->get_records($sql) };
	return (undef, $@) if $@;
	return ($rows // []);
}


#---------------------------------------------
# _appendPositionFallback
#---------------------------------------------
# Internal: callers SHOULD pass an explicit position to every insert/move
# primitive. If they do not, fall back to "append at end" (MAX(position)+1
# of the destination container) and log a warning so the forgotten caller
# is visible. End-state: no warnings logged.

sub _appendPositionFallback
{
	my ($dbh, $container_uuid, $fn, $what) = @_;
	my $max = getMaxChildPosition($dbh, $container_uuid);
	my $pos = defined($max) ? ($max + 1) : 1.0;
	warning(0, 0, "navDB::$fn: position not specified for '" . ($what // '') .
		"' -- appending at $pos (caller should pass position explicitly)");
	return $pos;
}


#---------------------------------------------
# Position-computing helpers
#---------------------------------------------
# Siblings within a container span four tables (sub-collections by
# parent_uuid; waypoints, routes, tracks by collection_uuid). These
# helpers walk all four as a unified position space.
# Root container (container_uuid = undef) holds only sub-collections.

# Precision threshold for the auto-renumber trigger. If a per-slot gap
# falls below this, the helper calls compactContainer() on the destination
# before placing items. 1e-9 allows ~30 hot-spot bisections from an
# integer-gap starting point; well clear of 2^-52 (~2.2e-16) underflow.
my $POSITION_EPS = 1e-9;


# Internal: build a UNION ALL sub-query over the four sibling tables
# for $container_uuid, optionally with "AND position $cmp ?" filter.
# Returns ($sql_fragment, \@bind_params). The fragment is parenthesized
# and ready for "SELECT MIN/MAX(p) FROM <fragment>" wrapping.

sub _siblingPositionsSql
{
	my ($container_uuid, $cmp, $val) = @_;
	my $extra = defined($cmp) ? " AND position $cmp ?" : "";
	my @parts;
	my @params;
	if (defined $container_uuid)
	{
		for my $info (
			['waypoints',   'collection_uuid'],
			['routes',      'collection_uuid'],
			['tracks',      'collection_uuid'],
			['collections', 'parent_uuid'])
		{
			my ($tbl, $col) = @$info;
			push @parts, "SELECT position AS p FROM $tbl WHERE $col=?$extra";
			push @params, $container_uuid;
			push @params, $val if defined $cmp;
		}
	}
	else
	{
		push @parts, "SELECT position AS p FROM collections WHERE parent_uuid IS NULL$extra";
		push @params, $val if defined $cmp;
	}
	return ("(" . join(" UNION ALL ", @parts) . ")", \@params);
}


# Internal: if the per-slot gap is below eps, renumber the container and
# return 1; else return 0. Renumber is the existing compactContainer; it
# preserves order and does not bump db_version.

sub _precisionRenumberIfNeeded
{
	my ($dbh, $container_uuid, $gap_per_slot) = @_;
	return 0 if !defined $gap_per_slot;
	return 0 if $gap_per_slot >= $POSITION_EPS;
	warning(0, 0, "AutoCompact FLOAT positions for container " . ($container_uuid // 'ROOT'));
	compactContainer($dbh, $container_uuid);
	return 1;
}


sub getMinChildPosition
{
	my ($dbh, $container_uuid) = @_;
	my ($sub, $params) = _siblingPositionsSql($container_uuid);
	my $rec = $dbh->get_record("SELECT MIN(p) AS position FROM $sub", $params);
	return (defined $rec && defined $rec->{position}) ? $rec->{position} : undef;
}


sub getMaxChildPosition
{
	my ($dbh, $container_uuid) = @_;
	my ($sub, $params) = _siblingPositionsSql($container_uuid);
	my $rec = $dbh->get_record("SELECT MAX(p) AS position FROM $sub", $params);
	return (defined $rec && defined $rec->{position}) ? $rec->{position} : undef;
}


# Look up a node's position by uuid + table. Used by computeFractionalBetween
# to refetch an anchor's position after a precision-triggered renumber.
# $anchor_table is one of 'waypoints', 'routes', 'tracks', 'collections'.

sub getPositionByAnchor
{
	my ($dbh, $anchor_uuid, $anchor_table) = @_;
	return undef if !$anchor_uuid || !$anchor_table;
	my $rec = $dbh->get_record(
		"SELECT position FROM $anchor_table WHERE uuid=?",
		[$anchor_uuid]);
	return (defined $rec && defined $rec->{position}) ? $rec->{position} : undef;
}


# Push-down-stack positions for N new items at the top of the container.
# pos_i = upper * (i+1) / (N+1)  where upper = MIN(positions) or N+1 if empty.
# devolves to 1..N for empty containers.
#
# Precision-aware: if the per-slot gap upper/(N+1) falls below POSITION_EPS,
# triggers compactContainer on the destination first, then recomputes upper.

sub computePushDownPositions
{
	my ($dbh, $container_uuid, $n) = @_;
	return () if $n < 1;
	my $min       = getMinChildPosition($dbh, $container_uuid);
	my $upper     = defined($min) ? $min : ($n + 1);
	my $gap_slot  = $upper / ($n + 1);
	if (_precisionRenumberIfNeeded($dbh, $container_uuid, $gap_slot))
	{
		$min   = getMinChildPosition($dbh, $container_uuid);
		$upper = defined($min) ? $min : ($n + 1);
	}
	my @positions;
	for my $i (0 .. $n - 1)
	{
		push @positions, $upper * ($i + 1) / ($n + 1);
	}
	return @positions;
}


# Unified fractional allocator. Returns N positions placed strictly between
# the anchor and its nearest neighbor in the chosen direction. Replaces the
# old computeFractionalBefore / computeFractionalAfter helpers AND the
# inline cross-table neighbor query + N-item bisection that previously lived
# in navOpsDB.pm's PASTE_BEFORE/AFTER block.
#
#   $anchor_uuid, $anchor_table identify the right-clicked node so its
#     position can be refetched if a precision renumber fires.
#   $is_before = 1 -> place items below the anchor (smaller positions);
#                0 -> place items above the anchor (larger positions).
#   $n         -> count of items to place.
#
# Returns an empty list on lookup failure.

sub computeFractionalBetween
{
	my ($dbh, $container_uuid, $anchor_uuid, $anchor_table, $is_before, $n) = @_;
	return () if $n < 1;

	# Two-pass: if a renumber fires inside _precisionRenumberIfNeeded the
	# anchor's position is now stale; reload neighbors and recompute once.
	for my $pass (1, 2)
	{
		my $anchor_pos = getPositionByAnchor($dbh, $anchor_uuid, $anchor_table);
		return () if !defined $anchor_pos;

		my $cmp     = $is_before ? '<' : '>';
		my $agg     = $is_before ? 'MAX' : 'MIN';
		my ($sub, $params) = _siblingPositionsSql($container_uuid, $cmp, $anchor_pos);
		my $rec     = $dbh->get_record("SELECT $agg(p) AS position FROM $sub", $params);
		my $nbr     = (defined $rec && defined $rec->{position})
			? $rec->{position}
			: ($is_before ? 0 : $anchor_pos + 1);

		my ($low, $high) = $is_before ? ($nbr, $anchor_pos) : ($anchor_pos, $nbr);
		my $gap_slot     = ($high - $low) / ($n + 1);

		if ($pass == 1 && _precisionRenumberIfNeeded($dbh, $container_uuid, $gap_slot))
		{
			next;  # retry once with refreshed anchor + neighbors
		}

		my @positions;
		for my $i (0 .. $n - 1)
		{
			push @positions, $low + ($high - $low) * ($i + 1) / ($n + 1);
		}
		return @positions;
	}
	return ();
}


# Merged sorted list of all immediate children of $container_uuid.
# Returns arrayref; each row carries kind=>'collection' or kind=>'object',
# the row's own position, and the fields the renderer needs to construct
# tree items. Replacement for separate getCollectionChildren +
# getCollectionObjects calls in the renderer.

sub getContainerChildren
{
	my ($dbh, $container_uuid) = @_;
	my @rows;

	my $colls;
	if (defined $container_uuid)
	{
		$colls = $dbh->get_records(
			"SELECT uuid, name, node_type, comment, position
			 FROM collections WHERE parent_uuid=?",
			[$container_uuid]);
	}
	else
	{
		$colls = $dbh->get_records(
			"SELECT uuid, name, node_type, comment, position
			 FROM collections WHERE parent_uuid IS NULL");
	}
	for my $row (@$colls)
	{
		$row->{kind} = 'collection';
		push @rows, $row;
	}

	if (defined $container_uuid)
	{
		my $wps = $dbh->get_records(
			"SELECT uuid, name, 'waypoint' AS obj_type, lat, lon, wp_type, color, position
			 FROM waypoints WHERE collection_uuid=?",
			[$container_uuid]);
		for my $row (@$wps)
		{
			$row->{kind} = 'object';
			push @rows, $row;
		}

		my $routes = $dbh->get_records(
			"SELECT uuid, name, color, 'route' AS obj_type, position
			 FROM routes WHERE collection_uuid=?",
			[$container_uuid]);
		for my $row (@$routes)
		{
			$row->{kind} = 'object';
			push @rows, $row;
		}

		my $tracks = $dbh->get_records(
			"SELECT uuid, name, color, 'track' AS obj_type, ts_start, ts_end, ts_source, point_count, position
			 FROM tracks WHERE collection_uuid=?",
			[$container_uuid]);
		for my $row (@$tracks)
		{
			$row->{kind} = 'object';
			push @rows, $row;
		}
	}

	@rows = sort { $a->{position} <=> $b->{position} } @rows;
	return \@rows;
}


#---------------------------------------------
# Compact -- renumber sibling positions
#---------------------------------------------
# compactContainer assigns 1.0, 2.0, 3.0, ... to every direct child of
# $container_uuid in current sorted order, breaking duplicate-position
# ties by rowid. compactAllContainers iterates every collection plus
# the root (NULL parent).
#
# Compact is the canonical normalization for legacy zero-positions and
# the precision-wall reclamation tool. It is idempotent on an already-
# compacted container.
#
# compactContainer returns the count of rows whose position was actually
# CHANGED (rows already at the correct integer position are skipped). A
# return of 0 means the container was already compact.


sub compactContainer
{
	my ($dbh, $container_uuid) = @_;
	my @rows;

	# Each row: ($table, $uuid, $position, $rowid)
	my $colls_sql;
	my $colls_params;
	if (defined $container_uuid)
	{
		$colls_sql = "SELECT uuid, position, rowid FROM collections WHERE parent_uuid=?";
		$colls_params = [$container_uuid];
	}
	else
	{
		$colls_sql = "SELECT uuid, position, rowid FROM collections WHERE parent_uuid IS NULL";
		$colls_params = [];
	}
	my $colls = $dbh->get_records($colls_sql, $colls_params);
	for my $r (@$colls)
	{
		push @rows, ['collections', $r->{uuid}, $r->{position} // 0, $r->{rowid} // 0];
	}

	if (defined $container_uuid)
	{
		for my $tbl ('waypoints', 'routes', 'tracks')
		{
			my $rs = $dbh->get_records(
				"SELECT uuid, position, rowid FROM $tbl WHERE collection_uuid=?",
				[$container_uuid]);
			for my $r (@$rs)
			{
				push @rows, [$tbl, $r->{uuid}, $r->{position} // 0, $r->{rowid} // 0];
			}
		}
	}

	# Sort by (position, rowid) -- preserves any existing meaningful
	# ordering and breaks duplicate-zero ties by insertion order.
	@rows = sort {
		$a->[2] <=> $b->[2]
			|| $a->[3] <=> $b->[3]
	} @rows;

	my $i        = 0;
	my $n_changed = 0;
	for my $row (@rows)
	{
		$i++;
		my ($tbl, $uuid, $cur_pos, undef) = @$row;
		my $new_pos = $i + 0.0;
		next if defined($cur_pos) && $cur_pos == $new_pos;
		$dbh->do("UPDATE $tbl SET position=? WHERE uuid=?", [$new_pos, $uuid]);
		$n_changed++;
	}
	return $n_changed;
}


sub compactAllContainers
{
	my ($dbh) = @_;
	my $total_rows  = 0;
	my $total_conts = 0;

	# Root first
	my $n = compactContainer($dbh, undef);
	if ($n > 0)
	{
		$total_rows  += $n;
		$total_conts++;
	}

	# Then every collection in the DB
	my $all = $dbh->get_records("SELECT uuid FROM collections");
	for my $row (@$all)
	{
		my $m = compactContainer($dbh, $row->{uuid});
		if ($m > 0)
		{
			$total_rows  += $m;
			$total_conts++;
		}
	}

	display(0,0,"compactAllContainers: renumbered $total_rows row(s) across $total_conts container(s)");
	return ($total_conts, $total_rows);
}


1;

