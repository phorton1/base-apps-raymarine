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
		classifyOrphanWaypoints
		promoteWaypointOnlyBranches
	);
}


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
		"node_type   TEXT NOT NULL DEFAULT 'branch'",
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
# Connect, create/verify schema, disconnect.  Returns 1=ok, 0=error, -1=mismatch.

sub openDB
{
	display(0,0,"c_db::openDB($db_path)");

	my $dbh = Pub::Database->connect(_db_params());
	if (!$dbh)
	{
		error("c_db::openDB connect failed");
		return 0;
	}

	unless (_createTables($dbh))
	{
		$dbh->disconnect();
		return 0;
	}
	_initKeyValues($dbh);

	my $rec    = $dbh->get_record("SELECT value FROM key_values WHERE key='schema_version'");
	my $stored = $rec ? $rec->{value} : '0.0';

	my ($stored_major)   = split(/\./, $stored);
	my ($expected_major) = split(/\./, $SCHEMA_VERSION);

	if ($stored_major != $expected_major)
	{
		warning(0,0,"schema_version mismatch: DB has $stored, code expects $SCHEMA_VERSION — reimport required");
		$dbh->disconnect();
		return -1;
	}

	if ($stored ne $SCHEMA_VERSION)
	{
		warning(0,0,"schema_version advisory: DB has $stored, code expects $SCHEMA_VERSION");
	}

	display(0,0,"c_db::openDB ok (schema $stored)");
	$dbh->disconnect();
	return 1;
}


#---------------------------------
# connectDB / disconnectDB
#---------------------------------

sub connectDB
{
	my $dbh = Pub::Database->connect(_db_params());
	error("c_db::connectDB failed") unless $dbh;
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
			or return error("c_db::_createTables failed for $table: $dbh->{errstr}");
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
	my ($dbh, $name, $parent_uuid, $node_type, $comment) = @_;
	if (defined $parent_uuid)
	{
		my $pr = $dbh->get_record(
			"SELECT node_type FROM collections WHERE uuid=?", [$parent_uuid]);
		if ($pr && $pr->{node_type} eq $NODE_TYPE_GROUP)
		{
			error(0,0,"insertCollection: cannot add sub-collection under group '$name'");
			return undef;
		}
	}
	my $uuid = newUUID($dbh);
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
	my $uuid = newUUID($dbh);
	$dbh->do(qq{
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
	my ($dbh, $name, $color, $comment, $collection_uuid) = @_;
	my $uuid = newUUID($dbh);
	$dbh->do(
		"INSERT INTO routes (uuid, name, color, comment, collection_uuid) VALUES (?,?,?,?,?)",
		[$uuid, $name, $color // 0, $comment // '', $collection_uuid]);
	return $uuid;
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
	my $uuid = newUUID($dbh);
	$dbh->do(qq{
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
	my ($dbh, $track_uuid, $points) = @_;
	return 0 unless @$points;
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
		error("c_db::insertTrackPoints failed: $@");
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
	my ($dbh, $name, $source_file, $ts_source) = @_;
	my $rec;
	if (defined $ts_source)
	{
		$rec = $dbh->get_record(
			"SELECT uuid FROM tracks WHERE name=? AND source_file=? AND ts_source=?",
			[$name, $source_file, $ts_source]);
	}
	else
	{
		$rec = $dbh->get_record(
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
			"SELECT uuid, name, node_type, comment FROM collections WHERE parent_uuid=? ORDER BY rowid",
			[$parent_uuid]);
	}
	return $dbh->get_records(
		"SELECT uuid, name, node_type, comment FROM collections WHERE parent_uuid IS NULL ORDER BY rowid");
}


#---------------------------------
# getCollectionCounts
#---------------------------------

sub getCollectionCounts
{
	my ($dbh, $coll_uuid) = @_;
	my $r_c = $dbh->get_record("SELECT COUNT(*) AS n FROM collections WHERE parent_uuid=?",    [$coll_uuid]);
	my $r_w = $dbh->get_record("SELECT COUNT(*) AS n FROM waypoints   WHERE collection_uuid=?", [$coll_uuid]);
	my $r_r = $dbh->get_record("SELECT COUNT(*) AS n FROM routes      WHERE collection_uuid=?", [$coll_uuid]);
	my $r_t = $dbh->get_record("SELECT COUNT(*) AS n FROM tracks      WHERE collection_uuid=?", [$coll_uuid]);
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

sub getCollectionObjects
{
	my ($dbh, $coll_uuid) = @_;
	my @objects;
	my $wps = $dbh->get_records(
		"SELECT uuid, name, 'waypoint' AS obj_type, lat, lon, sym, wp_type, color
		 FROM waypoints WHERE collection_uuid=? ORDER BY rowid",
		[$coll_uuid]);
	push @objects, @$wps;
	my $routes = $dbh->get_records(
		"SELECT uuid, name, color, 'route' AS obj_type
		 FROM routes WHERE collection_uuid=? ORDER BY rowid",
		[$coll_uuid]);
	push @objects, @$routes;
	my $tracks = $dbh->get_records(
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
	my ($dbh, $lat, $lon, $source_file) = @_;
	my $rec = $dbh->get_record(
		"SELECT uuid FROM waypoints WHERE ABS(lat-?) < 0.000001 AND ABS(lon-?) < 0.000001 AND source_file=? LIMIT 1",
		[$lat, $lon, $source_file]);
	return $rec ? $rec->{uuid} : undef;
}


#---------------------------------
# getCollection
#---------------------------------

sub getCollection
{
	my ($dbh, $uuid) = @_;
	return $dbh->get_record(
		"SELECT uuid, name, parent_uuid, node_type, comment FROM collections WHERE uuid=?",
		[$uuid]);
}


#---------------------------------
# getTrack
#---------------------------------

sub getTrack
{
	my ($dbh, $uuid) = @_;
	return $dbh->get_record(
		"SELECT uuid, name, color, ts_start, ts_end, ts_source, point_count, source_file, collection_uuid FROM tracks WHERE uuid=?",
		[$uuid]);
}


#---------------------------------
# getWaypoint
#---------------------------------

sub getWaypoint
{
	my ($dbh, $uuid) = @_;
	return $dbh->get_record(
		"SELECT uuid, name, comment, lat, lon, sym, wp_type, color, depth_cm, created_ts, ts_source, source_file, source, collection_uuid FROM waypoints WHERE uuid=?",
		[$uuid]);
}


#---------------------------------
# getRoute
#---------------------------------

sub getRoute
{
	my ($dbh, $uuid) = @_;
	return $dbh->get_record(
		"SELECT uuid, name, comment, color, collection_uuid FROM routes WHERE uuid=?",
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
		$cte . "SELECT uuid, name, lat, lon, sym, wp_type, color, depth_cm FROM waypoints WHERE collection_uuid IN (SELECT uuid FROM tree)",
		[$uuid]);
	my $routes = $dbh->get_records(
		$cte . "SELECT uuid, name, color FROM routes WHERE collection_uuid IN (SELECT uuid FROM tree)",
		[$uuid]);
	my $tracks = $dbh->get_records(
		$cte . "SELECT uuid, name, color, point_count FROM tracks WHERE collection_uuid IN (SELECT uuid FROM tree)",
		[$uuid]);
	return {
		waypoints => $wps    // [],
		routes    => $routes // [],
		tracks    => $tracks // [],
	};
}


#---------------------------------
# getCollectionGroups
#---------------------------------
# Returns all node_type='group' collections in the sub-tree rooted at
# $coll_uuid, with their member waypoints.
# Returns arrayref of { uuid, name, waypoints => [{uuid,name,lat,lon,sym}] }.

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
		       w.lat, w.lon, w.sym
		FROM tree t
		JOIN collections col ON col.uuid=t.uuid AND col.node_type='group'
		JOIN waypoints w ON w.collection_uuid=col.uuid
		ORDER BY col.name, w.rowid
	}, [$coll_uuid]);

	my @groups;
	my %idx;
	for my $row (@{$rows // []})
	{
		my $cu = $row->{coll_uuid};
		unless (exists $idx{$cu})
		{
			$idx{$cu} = scalar @groups;
			push @groups, { uuid => $cu, name => $row->{coll_name}, waypoints => [] };
		}
		push @{$groups[$idx{$cu}]->{waypoints}}, {
			uuid => $row->{wp_uuid},
			name => $row->{wp_name},
			lat  => $row->{lat},
			lon  => $row->{lon},
			sym  => $row->{sym},
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
		"SELECT lat, lon FROM track_points WHERE track_uuid=? ORDER BY position",
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
	my ($dbh, $top_uuid, $tol) = @_;
	$tol //= 0.001;

	my $cte = "WITH RECURSIVE tree(uuid) AS (
		SELECT uuid FROM collections WHERE uuid=?
		UNION ALL
		SELECT c.uuid FROM collections c JOIN tree ON c.parent_uuid=tree.uuid
	) ";

	my $tc = $dbh->get_record(
		$cte . "SELECT COUNT(*) AS n FROM tracks WHERE collection_uuid IN (SELECT uuid FROM tree)",
		[$top_uuid]);
	return 0 unless $tc && $tc->{n} > 0;

	my $eps = $dbh->get_records(
		$cte . "SELECT tp.lat, tp.lon
		        FROM track_points tp
		        JOIN tracks t ON tp.track_uuid = t.uuid
		        WHERE t.collection_uuid IN (SELECT uuid FROM tree)
		        AND (tp.position = 0
		             OR (t.point_count > 0 AND tp.position = t.point_count - 1))",
		[$top_uuid]);
	return 0 unless @$eps;

	my $wps = $dbh->get_records(
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
			$dbh->do("UPDATE waypoints SET wp_type='label' WHERE uuid=?", [$wp->{uuid}]);
			$relabeled++;
		}
	}
	return $relabeled;
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


#---------------------------------
# rawQuery
#---------------------------------
# Debug endpoint — SELECT only.

sub rawQuery
{
	my ($dbh, $sql) = @_;
	my $rows = eval { $dbh->get_records($sql) };
	return (undef, $@) if $@;
	return ($rows // []);
}


1;
