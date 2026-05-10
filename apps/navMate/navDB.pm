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
		"visible     INTEGER NOT NULL DEFAULT 0",
		"position    REAL    NOT NULL DEFAULT 0",
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
		"created_ts      INTEGER NOT NULL",
		"ts_source       TEXT NOT NULL",
		"source          TEXT",
		"collection_uuid TEXT NOT NULL",
		"visible         INTEGER NOT NULL DEFAULT 0",
		"db_version      INTEGER NOT NULL DEFAULT 1",
		"e80_version     INTEGER",
		"kml_version     INTEGER",
		"position        REAL    NOT NULL DEFAULT 0",
	],

	routes => [
		"uuid            TEXT PRIMARY KEY",
		"name            TEXT NOT NULL",
		"comment         TEXT DEFAULT ''",
		"color           TEXT DEFAULT NULL",
		"collection_uuid TEXT NOT NULL",
		"visible         INTEGER NOT NULL DEFAULT 0",
		"db_version      INTEGER NOT NULL DEFAULT 1",
		"e80_version     INTEGER",
		"kml_version     INTEGER",
		"position        REAL    NOT NULL DEFAULT 0",
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
		"visible         INTEGER NOT NULL DEFAULT 0",
		"db_version      INTEGER NOT NULL DEFAULT 1",
		"e80_version     INTEGER",
		"kml_version     INTEGER",
		"position        REAL    NOT NULL DEFAULT 0",
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

	working_sets => [
		"uuid       TEXT PRIMARY KEY",
		"name       TEXT NOT NULL",
		"comment    TEXT DEFAULT ''",
		"bbox_north REAL",
		"bbox_south REAL",
		"bbox_east  REAL",
		"bbox_west  REAL",
	],

	working_set_members => [
		"ws_uuid     TEXT NOT NULL",
		"object_uuid TEXT NOT NULL",
		"object_type TEXT NOT NULL",
		"PRIMARY KEY (ws_uuid, object_uuid)",
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
		tracks track_points working_sets working_set_members))
	{
		next if $dbh->tableExists($table);
		$dbh->createTable($table)
			or return error("navDB::_createTables failed for $table: $dbh->{errstr}");
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
# insertCollection
#---------------------------------

sub insertCollection
{
	my ($dbh, $name, $parent_uuid, $node_type, $comment) = @_;
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
	my $uuid = newUUID($dbh);
	$dbh->do(
		"INSERT INTO collections (uuid, name, parent_uuid, node_type, comment) VALUES (?,?,?,?,?)",
		[$uuid, $name, $parent_uuid, $node_type // $NODE_TYPE_BRANCH, $comment // '']);
	return $uuid;
}


sub insertCollectionUUID
{
	my ($dbh, $uuid, $name, $parent_uuid, $node_type, $comment) = @_;
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
	$dbh->do(
		"INSERT INTO collections (uuid, name, parent_uuid, node_type, comment) VALUES (?,?,?,?,?)",
		[$uuid, $name, $parent_uuid, $node_type // $NODE_TYPE_BRANCH, $comment // '']);
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
	$dbh->do(qq{
		INSERT INTO waypoints
			(uuid, name, comment, lat, lon, wp_type, color, depth_cm,
			 created_ts, ts_source, source, collection_uuid)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?)},
		[$uuid,
		$a{name},
		$a{comment}         // '',
		$a{lat},
		$a{lon},
		$a{wp_type}         // $WP_TYPE_NAV,
		$a{color},
		$a{depth_cm}        // 0,
		$a{created_ts},
		$a{ts_source},
		$a{source},
		$a{collection_uuid}]);
	return $uuid;
}


sub updateWaypoint
{
	my ($dbh, $uuid, %a) = @_;
	$dbh->do(qq{
		UPDATE waypoints SET
			name=?, comment=?, lat=?, lon=?, wp_type=?, color=?,
			depth_cm=?, created_ts=?, ts_source=?, source=?
		WHERE uuid=?},
		[$a{name},
		$a{comment}  // '',
		$a{lat},
		$a{lon},
		$a{wp_type}  // $WP_TYPE_NAV,
		$a{color},
		$a{depth_cm} // 0,
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
	my ($dbh, $name, $color, $comment, $collection_uuid) = @_;
	my $uuid = newUUID($dbh);
	$dbh->do(
		"INSERT INTO routes (uuid, name, color, comment, collection_uuid) VALUES (?,?,?,?,?)",
		[$uuid, $name, $color // 0, $comment // '', $collection_uuid]);
	return $uuid;
}


sub insertRouteUUID
{
	my ($dbh, $uuid, $name, $color, $comment, $collection_uuid) = @_;
	$dbh->do(
		"INSERT INTO routes (uuid, name, color, comment, collection_uuid) VALUES (?,?,?,?,?)",
		[$uuid, $name, $color // 0, $comment // '', $collection_uuid]);
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
	$dbh->do(qq{
		INSERT INTO tracks
			(uuid, name, color, ts_start, ts_end, ts_source,
			 point_count, collection_uuid)
		VALUES (?,?,?,?,?,?,?,?)},
		[$uuid,
		$a{name},
		$a{color}       // 0,
		$a{ts_start}    // 0,
		$a{ts_end},
		$a{ts_source},
		$a{point_count} // 0,
		$a{collection_uuid}]);
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
		"SELECT uuid, name, 'waypoint' AS obj_type, lat, lon, wp_type, color, visible
		 FROM waypoints WHERE collection_uuid=? ORDER BY position",
		[$coll_uuid]);
	push @objects, @$wps;
	my $routes = $dbh->get_records(
		"SELECT uuid, name, color, 'route' AS obj_type, visible
		 FROM routes WHERE collection_uuid=? ORDER BY position",
		[$coll_uuid]);
	push @objects, @$routes;
	my $tracks = $dbh->get_records(
		"SELECT uuid, name, color, 'track' AS obj_type, ts_start, ts_end, ts_source, point_count, visible
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
		"SELECT uuid, name, parent_uuid, node_type, comment, visible, position FROM collections WHERE uuid=?",
		[$uuid]);
}


#---------------------------------
# getTrack
#---------------------------------

sub getTrack
{
	my ($dbh, $uuid) = @_;
	return $dbh->get_record(
		"SELECT uuid, name, color, ts_start, ts_end, ts_source, point_count, collection_uuid, visible, position FROM tracks WHERE uuid=?",
		[$uuid]);
}


#---------------------------------
# getWaypoint
#---------------------------------

sub getWaypoint
{
	my ($dbh, $uuid) = @_;
	return $dbh->get_record(
		"SELECT uuid, name, comment, lat, lon, wp_type, color, depth_cm, created_ts, ts_source, source, collection_uuid, visible, position FROM waypoints WHERE uuid=?",
		[$uuid]);
}


#---------------------------------
# getRoute
#---------------------------------

sub getRoute
{
	my ($dbh, $uuid) = @_;
	return $dbh->get_record(
		"SELECT uuid, name, comment, color, collection_uuid, visible, position FROM routes WHERE uuid=?",
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
		        created_ts, ts_source, source, collection_uuid, visible
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
	my ($dbh, $uuid, $new_coll_uuid) = @_;
	$dbh->do("UPDATE waypoints SET collection_uuid=? WHERE uuid=?", [$new_coll_uuid, $uuid]);
	return 1;
}


sub moveCollection
{
	my ($dbh, $uuid, $new_parent_uuid) = @_;
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
	$dbh->do("UPDATE collections SET parent_uuid=? WHERE uuid=?", [$new_parent_uuid, $uuid]);
	return 1;
}


sub moveRoute
{
	my ($dbh, $uuid, $new_coll_uuid) = @_;
	$dbh->do("UPDATE routes SET collection_uuid=? WHERE uuid=?", [$new_coll_uuid, $uuid]);
	return 1;
}


sub moveTrack
{
	my ($dbh, $uuid, $new_coll_uuid) = @_;
	$dbh->do("UPDATE tracks SET collection_uuid=? WHERE uuid=?", [$new_coll_uuid, $uuid]);
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
	return 1 unless @$col_rows;
	my @col_uuids = map { $_->{uuid} } @$col_rows;
	my $col_ph    = join(',', map { '?' } @col_uuids);
	my $wp_rows   = $dbh->get_records(
		"SELECT uuid FROM waypoints WHERE collection_uuid IN ($col_ph)",
		\@col_uuids);
	return 1 unless @$wp_rows;
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
		return 0 unless $route_set{$row->{route_uuid}};
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
	return unless @$col_rows;
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


1;

