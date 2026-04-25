#---------------------------------------------
# c_db.pm
#---------------------------------------------

package c_db;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::Database;
use a_defs;
use a_utils;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		openDB
		closeDB
		resetDB
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
		getTrackPoints
		getRoutePoints
		getRouteWaypoints
		rawQuery
		classifyOrphanWaypoints
	);
}


my $db;
my $db_path = "$data_dir/navMate.db";

my $db_def = {

	key_values => [
		"key    TEXT PRIMARY KEY",
		"value  TEXT",
	],

	collections => [
		"uuid        TEXT PRIMARY KEY",
		"name        TEXT NOT NULL",
		"parent_uuid TEXT",
		"comment     TEXT DEFAULT ''",
	],

	waypoints => [
		"uuid            TEXT PRIMARY KEY",
		"name            TEXT NOT NULL",
		"comment         TEXT DEFAULT ''",
		"lat             REAL NOT NULL",
		"lon             REAL NOT NULL",
		"sym             INTEGER DEFAULT 0",
		"wp_type         TEXT NOT NULL DEFAULT 'nav'",
		"color           TEXT",
		"depth_cm        INTEGER DEFAULT 0",
		"created_ts      INTEGER NOT NULL",
		"ts_source       TEXT NOT NULL",
		"source_file     TEXT",
		"source          TEXT",
		"collection_uuid TEXT NOT NULL",
	],

	routes => [
		"uuid            TEXT PRIMARY KEY",
		"name            TEXT NOT NULL",
		"comment         TEXT DEFAULT ''",
		"color           INTEGER DEFAULT 0",
		"collection_uuid TEXT NOT NULL",
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
		"color           INTEGER DEFAULT 0",
		"ts_start        INTEGER NOT NULL",
		"ts_end          INTEGER",
		"ts_source       TEXT NOT NULL",
		"point_count     INTEGER",
		"source_file     TEXT",
		"collection_uuid TEXT NOT NULL",
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

sub openDB
{
	display(0,0,"c_db::openDB($db_path)");

	$db = Pub::Database->connect(_db_params());
	if (!$db)
	{
		error("c_db::openDB connect failed");
		return 0;
	}

	_createTables() or return 0;
	_initKeyValues();

	my $rec = $db->get_record("SELECT value FROM key_values WHERE key='schema_version'");
	my $stored = $rec ? $rec->{value} : '0.0';

	my ($stored_major)   = split(/\./, $stored);
	my ($expected_major) = split(/\./, $SCHEMA_VERSION);

	if ($stored_major != $expected_major)
	{
		warning(0,0,"schema_version mismatch: DB has $stored, code expects $SCHEMA_VERSION — reimport required");
		$db->disconnect();
		$db = undef;
		return -1;
	}

	if ($stored ne $SCHEMA_VERSION)
	{
		warning(0,0,"schema_version advisory: DB has $stored, code expects $SCHEMA_VERSION");
	}

	display(0,0,"c_db::openDB ok (schema $stored)");
	return 1;
}


#---------------------------------
# closeDB
#---------------------------------

sub closeDB
{
	return unless $db;
	$db->disconnect();
	$db = undef;
	display(0,0,"c_db::closeDB ok");
}


#---------------------------------
# resetDB
#---------------------------------
# Close DB, delete the file, and reopen (fresh schema + reimport).
# Returns same values as openDB: 1=ok, 0=connect failed, -1=schema mismatch.

sub resetDB
{
	closeDB();
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
	for my $table (qw(
		key_values collections waypoints routes route_waypoints
		tracks track_points working_sets working_set_members))
	{
		next if $db->tableExists($table);
		$db->createTable($table)
			or return error("c_db::_createTables failed for $table: $db->{errstr}");
	}
	return 1;
}


#---------------------------------
# _initKeyValues
#---------------------------------

sub _initKeyValues
{
	$db->do("INSERT OR IGNORE INTO key_values (key, value) VALUES ('schema_version', ?)",
		[$SCHEMA_VERSION]);
	$db->do("INSERT OR IGNORE INTO key_values (key, value) VALUES ('uuid_counter', '0')");
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
		$db->{dbh}->begin_work();
		my $rec = $db->get_record("SELECT value FROM key_values WHERE key='uuid_counter'");
		$counter = ($rec ? $rec->{value} : 0) + 1;
		$db->do("UPDATE key_values SET value=? WHERE key='uuid_counter'", [$counter]);
		$db->commit();
	};
	if ($@)
	{
		eval { $db->rollback() };
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
	my ($name, $parent_uuid, $comment) = @_;
	my $uuid = newUUID();
	$db->do(
		"INSERT INTO collections (uuid, name, parent_uuid, comment) VALUES (?,?,?,?)",
		[$uuid, $name, $parent_uuid, $comment // '']);
	return $uuid;
}


#---------------------------------
# findCollection
#---------------------------------

sub findCollection
{
	my ($name, $parent_uuid) = @_;
	my $rec;
	if (defined $parent_uuid)
	{
		$rec = $db->get_record(
			"SELECT uuid FROM collections WHERE name=? AND parent_uuid=?",
			[$name, $parent_uuid]);
	}
	else
	{
		$rec = $db->get_record(
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
	my (%a) = @_;
	my $uuid = newUUID();
	$db->do(qq{
		INSERT INTO waypoints
			(uuid, name, comment, lat, lon, sym, wp_type, color, depth_cm,
			 created_ts, ts_source, source_file, source, collection_uuid)
		VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)},
		[$uuid,
		$a{name},
		$a{comment}         // '',
		$a{lat},
		$a{lon},
		$a{sym}             // 0,
		$a{wp_type}         // $WP_TYPE_NAV,
		$a{color},
		$a{depth_cm}        // 0,
		$a{created_ts},
		$a{ts_source},
		$a{source_file},
		$a{source},
		$a{collection_uuid}]);
	return $uuid;
}


#---------------------------------
# insertRoute
#---------------------------------

sub insertRoute
{
	my ($name, $color, $comment, $collection_uuid) = @_;
	my $uuid = newUUID();
	$db->do(
		"INSERT INTO routes (uuid, name, color, comment, collection_uuid) VALUES (?,?,?,?,?)",
		[$uuid, $name, $color // 0, $comment // '', $collection_uuid]);
	return $uuid;
}


#---------------------------------
# appendRouteWaypoint
#---------------------------------

sub appendRouteWaypoint
{
	my ($route_uuid, $wp_uuid, $position) = @_;
	$db->do(
		"INSERT INTO route_waypoints (route_uuid, wp_uuid, position) VALUES (?,?,?)",
		[$route_uuid, $wp_uuid, $position]);
	return 1;
}


#---------------------------------
# insertTrack
#---------------------------------

sub insertTrack
{
	my (%a) = @_;
	my $uuid = newUUID();
	$db->do(qq{
		INSERT INTO tracks
			(uuid, name, color, ts_start, ts_end, ts_source,
			 point_count, source_file, collection_uuid)
		VALUES (?,?,?,?,?,?,?,?,?)},
		[$uuid,
		$a{name},
		$a{color}       // 0,
		$a{ts_start}    // 0,
		$a{ts_end},
		$a{ts_source},
		$a{point_count} // 0,
		$a{source_file},
		$a{collection_uuid}]);
	return $uuid;
}


#---------------------------------
# insertTrackPoints
#---------------------------------

sub insertTrackPoints
{
	my ($track_uuid, $points) = @_;
	return 0 unless @$points;
	my $sth = $db->{dbh}->prepare(qq{
		INSERT INTO track_points
			(track_uuid, position, lat, lon, depth_cm, temp_k, ts)
		VALUES (?,?,?,?,?,?,?)});
	eval
	{
		$db->{dbh}->begin_work();
		for my $i (0 .. $#$points)
		{
			my $p = $points->[$i];
			$sth->execute(
				$track_uuid, $i,
				$p->{lat}, $p->{lon},
				$p->{depth_cm}, $p->{temp_k}, $p->{ts});
		}
		$db->commit();
	};
	if ($@)
	{
		eval { $db->rollback() };
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
	my $rec;
	if (defined $ts_source)
	{
		$rec = $db->get_record(
			"SELECT uuid FROM tracks WHERE name=? AND source_file=? AND ts_source=?",
			[$name, $source_file, $ts_source]);
	}
	else
	{
		$rec = $db->get_record(
			"SELECT uuid FROM tracks WHERE name=? AND source_file=?",
			[$name, $source_file]);
	}
	return $rec ? $rec->{uuid} : undef;
}


#---------------------------------
# getTrackTsSource
#---------------------------------

sub getTrackTsSource
{
	my ($uuid) = @_;
	my $rec = $db->get_record(
		"SELECT ts_source FROM tracks WHERE uuid=?", [$uuid]);
	return $rec ? $rec->{ts_source} : undef;
}


#---------------------------------
# updateTrackTimestamps
#---------------------------------

sub updateTrackTimestamps
{
	my ($uuid, $ts_start, $ts_end, $ts_source) = @_;
	$db->do(
		"UPDATE tracks SET ts_start=?, ts_end=?, ts_source=? WHERE uuid=?",
		[$ts_start, $ts_end, $ts_source, $uuid]);
	return 1;
}


#---------------------------------
# getCollectionChildren
#---------------------------------

sub getCollectionChildren
{
	my ($parent_uuid) = @_;
	if (defined $parent_uuid)
	{
		return $db->get_records(
			"SELECT uuid, name, comment FROM collections WHERE parent_uuid=? ORDER BY rowid",
			[$parent_uuid]);
	}
	return $db->get_records(
		"SELECT uuid, name, comment FROM collections WHERE parent_uuid IS NULL ORDER BY rowid");
}


#---------------------------------
# getCollectionCounts
#---------------------------------

sub getCollectionCounts
{
	my ($coll_uuid) = @_;
	my $r_c = $db->get_record("SELECT COUNT(*) AS n FROM collections WHERE parent_uuid=?",  [$coll_uuid]);
	my $r_w = $db->get_record("SELECT COUNT(*) AS n FROM waypoints   WHERE collection_uuid=?", [$coll_uuid]);
	my $r_r = $db->get_record("SELECT COUNT(*) AS n FROM routes      WHERE collection_uuid=?", [$coll_uuid]);
	my $r_t = $db->get_record("SELECT COUNT(*) AS n FROM tracks      WHERE collection_uuid=?", [$coll_uuid]);
	return {
		collections => ($r_c ? $r_c->{n} : 0) + 0,
		waypoints   => ($r_w ? $r_w->{n} : 0) + 0,
		routes      => ($r_r ? $r_r->{n} : 0) + 0,
		tracks      => ($r_t ? $r_t->{n} : 0) + 0,
	};
}


#---------------------------------
# getCollectionObjects
#---------------------------------
# Returns leaf objects in a collection ordered by type then rowid.
# Each record has: uuid, name, obj_type, plus type-specific fields.

sub getCollectionObjects
{
	my ($coll_uuid) = @_;
	my @objects;
	my $wps = $db->get_records(
		"SELECT uuid, name, 'waypoint' AS obj_type, lat, lon, sym, wp_type, color
		 FROM waypoints WHERE collection_uuid=? ORDER BY rowid",
		[$coll_uuid]);
	push @objects, @$wps;
	my $routes = $db->get_records(
		"SELECT uuid, name, color, 'route' AS obj_type
		 FROM routes WHERE collection_uuid=? ORDER BY rowid",
		[$coll_uuid]);
	push @objects, @$routes;
	my $tracks = $db->get_records(
		"SELECT uuid, name, color, 'track' AS obj_type, ts_start, ts_end, ts_source, point_count
		 FROM tracks WHERE collection_uuid=? ORDER BY rowid",
		[$coll_uuid]);
	push @objects, @$tracks;
	return \@objects;
}


#---------------------------------
# findWaypointByLatLon
#---------------------------------

sub findWaypointByLatLon
{
	my ($lat, $lon, $source_file) = @_;
	my $rec = $db->get_record(
		"SELECT uuid FROM waypoints WHERE ABS(lat-?) < 0.000001 AND ABS(lon-?) < 0.000001 AND source_file=? LIMIT 1",
		[$lat, $lon, $source_file]);
	return $rec ? $rec->{uuid} : undef;
}


#---------------------------------
# getCollection
#---------------------------------

sub getCollection
{
	my ($uuid) = @_;
	return $db->get_record(
		"SELECT uuid, name, parent_uuid, comment FROM collections WHERE uuid=?",
		[$uuid]);
}


#---------------------------------
# getTrack
#---------------------------------

sub getTrack
{
	my ($uuid) = @_;
	return $db->get_record(
		"SELECT uuid, name, color, ts_start, ts_end, ts_source, point_count, source_file, collection_uuid FROM tracks WHERE uuid=?",
		[$uuid]);
}


#---------------------------------
# getWaypoint
#---------------------------------

sub getWaypoint
{
	my ($uuid) = @_;
	return $db->get_record(
		"SELECT uuid, name, comment, lat, lon, sym, wp_type, color, depth_cm, created_ts, ts_source, source_file, source, collection_uuid FROM waypoints WHERE uuid=?",
		[$uuid]);
}


#---------------------------------
# getRoute
#---------------------------------

sub getRoute
{
	my ($uuid) = @_;
	return $db->get_record(
		"SELECT uuid, name, comment, color, collection_uuid FROM routes WHERE uuid=?",
		[$uuid]);
}


#---------------------------------
# getRouteWaypointCount
#---------------------------------

sub getRouteWaypointCount
{
	my ($uuid) = @_;
	my $rec = $db->get_record(
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
	my ($uuid) = @_;
	my $cte = qq{
		WITH RECURSIVE tree(uuid) AS (
			SELECT uuid FROM collections WHERE uuid=?
			UNION ALL
			SELECT c.uuid FROM collections c JOIN tree ON c.parent_uuid=tree.uuid
		)
	};
	my $wps = $db->get_records(
		$cte . "SELECT uuid, name, lat, lon, sym, wp_type, color, depth_cm FROM waypoints WHERE collection_uuid IN (SELECT uuid FROM tree)",
		[$uuid]);
	my $routes = $db->get_records(
		$cte . "SELECT uuid, name, color FROM routes WHERE collection_uuid IN (SELECT uuid FROM tree)",
		[$uuid]);
	my $tracks = $db->get_records(
		$cte . "SELECT uuid, name, color, point_count FROM tracks WHERE collection_uuid IN (SELECT uuid FROM tree)",
		[$uuid]);
	return {
		waypoints => $wps    // [],
		routes    => $routes // [],
		tracks    => $tracks // [],
	};
}


#---------------------------------
# getTrackPoints
#---------------------------------

sub getTrackPoints
{
	my ($uuid) = @_;
	return $db->get_records(
		"SELECT lat, lon FROM track_points WHERE track_uuid=? ORDER BY position",
		[$uuid]);
}


#---------------------------------
# getRoutePoints
#---------------------------------
# Returns ordered lat/lon via route_waypoints JOIN waypoints.

sub getRoutePoints
{
	my ($uuid) = @_;
	return $db->get_records(
		"SELECT w.lat, w.lon FROM route_waypoints rw JOIN waypoints w ON rw.wp_uuid=w.uuid WHERE rw.route_uuid=? ORDER BY rw.position",
		[$uuid]);
}


#---------------------------------
# getRouteWaypoints
#---------------------------------
# Returns ordered waypoint records (uuid, name, lat, lon) for a route.

sub getRouteWaypoints
{
	my ($uuid) = @_;
	return $db->get_records(
		"SELECT w.uuid, w.name, w.lat, w.lon
		 FROM route_waypoints rw JOIN waypoints w ON rw.wp_uuid=w.uuid
		 WHERE rw.route_uuid=? ORDER BY rw.position",
		[$uuid]);
}


#---------------------------------
# classifyOrphanWaypoints
#---------------------------------
# Post-import pass: any 'nav' waypoint in the tree under $top_uuid that is not
# within $tol degrees of a track start or end point is reclassified as 'label'.
# Skipped (returns 0) when the tree has no tracks.

sub classifyOrphanWaypoints
{
	my ($top_uuid, $tol) = @_;
	$tol //= 0.001;

	my $cte = "WITH RECURSIVE tree(uuid) AS (
		SELECT uuid FROM collections WHERE uuid=?
		UNION ALL
		SELECT c.uuid FROM collections c JOIN tree ON c.parent_uuid=tree.uuid
	) ";

	my $tc = $db->get_record(
		$cte . "SELECT COUNT(*) AS n FROM tracks WHERE collection_uuid IN (SELECT uuid FROM tree)",
		[$top_uuid]);
	return 0 unless $tc && $tc->{n} > 0;

	my $eps = $db->get_records(
		$cte . "SELECT tp.lat, tp.lon
		        FROM track_points tp
		        JOIN tracks t ON tp.track_uuid = t.uuid
		        WHERE t.collection_uuid IN (SELECT uuid FROM tree)
		        AND (tp.position = 0
		             OR (t.point_count > 0 AND tp.position = t.point_count - 1))",
		[$top_uuid]);
	return 0 unless @$eps;

	my $wps = $db->get_records(
		$cte . "SELECT uuid, lat, lon FROM waypoints
		        WHERE collection_uuid IN (SELECT uuid FROM tree)
		        AND wp_type = 'nav'",
		[$top_uuid]);
	return 0 unless @$wps;

	my $relabeled = 0;
	for my $wp (@$wps)
	{
		my $matched = 0;
		for my $ep (@$eps)
		{
			if (abs($wp->{lat} - $ep->{lat}) <= $tol
			 && abs($wp->{lon} - $ep->{lon}) <= $tol)
			{
				$matched = 1;
				last;
			}
		}
		unless ($matched)
		{
			$db->do("UPDATE waypoints SET wp_type='label' WHERE uuid=?", [$wp->{uuid}]);
			$relabeled++;
		}
	}
	return $relabeled;
}


#---------------------------------
# rawQuery
#---------------------------------
# Debug endpoint — SELECT only.

sub rawQuery
{
	my ($sql) = @_;
	my $rows = eval { $db->get_records($sql) };
	return (undef, $@) if $@;
	return ($rows // []);
}


1;
