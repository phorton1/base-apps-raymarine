#---------------------------------------------
# navServer.pm
#---------------------------------------------
# navMate HTTP server.  Extends h_server.pm.
# HTTP port from the HTTP_PORT pref (dev 9883 / packaged 9873).  Static files from _res/site/.
#
# Inherits from h_server:
#   /api/db      - E80 WGRT in-memory state as JSON
#   /api/log     - console ring buffer
#   /api/command - NET-layer command dispatch
#   /raysys.kml  - E80 state as Google Earth KML
#
# navMate-specific endpoints:
#   /poll        - Leaflet map version check
#   /geojson     - current render feature set
#   /clear       - clear render map
#   /api/query   - SELECT against navMate SQLite DB
#   /api/nmdb    - structured snapshot: collections, waypoints, routes, route_waypoints, tracks
#   /api/fsh     - navFSH in-memory state as JSON (waypoints, groups, routes, tracks)
#   /api/e80config - headless E80 config save/restore/clear:
#                  ?op=save|restore|clear&ip=<addr>&folder=<path>  (folder omitted for clear)
#                  -> { ok:1, message:... } | { error:... }   (blocking; no dialogs)
#   /api/e80grab - headless E80 screen capture:
#                  ?ip=<addr>[&path=<png-path>]
#                  -> image/png bytes (no path) | { ok:1, message:..., path:... } (path) | { error:... }

package navServer;
use strict;
use warnings;
use threads;
use threads::shared;
use JSON::PP qw(encode_json decode_json);
use Pub::Utils qw(display warning error $resource_dir);
use Pub::HTTP::Response qw(json_response);
use apps::raymarine::NET::h_server;
use navPrefs qw(getPref setPref $PREF_HTTP_PORT $PREF_MAP_BROWSER);
use nmResources qw(ensureLeafletNative ensureLeafletMask leafletNativePath leafletMaskPath);
use nmDialogs qw($suppress_confirm $suppress_outcome $suppress_error_dialog);
use navDB;
use navFSH;
use nmE80DirectOps;
use base qw(apps::raymarine::NET::h_server);


my $nm_server;

my $map_version           :shared = 0;
my $last_poll_time        :shared = 0;
my %features_by_key       :shared;   # keyed "$source:$uuid" -- see addRenderFeatures
my $clear_version         :shared = 0;
my $test_pending          :shared = '';
my $clear_map_pending     :shared = 0;
my $track_edit_pending    :shared = '';
my $route_edit_pending    :shared = '';


BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(
		startNavMateServer
		dispatchNavMateCommand
		addRenderFeatures
		removeRenderFeatures
		clearRenderMap
		isBrowserConnected
		openMapBrowser
		getClearVersion
		pollTestCommand
		pollClearMapPending
		pollTrackEditPending
		pollRouteEditPending
	);
}


#---------------------------------
# public API (called from wx thread)
#---------------------------------

sub startNavMateServer
{
	$nm_server = navServer->new();
	display(0,0,"starting navServer on port ".getPref($PREF_HTTP_PORT));
	$nm_server->start();
	display(0,0,"navServer started");
}


sub dispatchNavMateCommand
{
	my ($lpart, $rpart) = @_;
	$nm_server->handleCommand($lpart, $rpart) if $nm_server;
}


sub addRenderFeatures
	# Render-identity is the pair (data_source, uuid), not bare uuid:  a single
	# UUID may exist as denormalized renderable items in two or three panes
	# (DB / E80 / FSH) with different colors, point lists, etc.  Each feature
	# already carries its `data_source` in properties; we form the composite
	# storage key "$source:$uuid" from that, so add() callers do not need an
	# explicit source argument.
{
	my ($features_ref) = @_;
	return if !@$features_ref;
	my %encoded;
	for my $f (@$features_ref)
	{
		my $source = $f->{properties}{data_source} // '';
		my $uuid   = $f->{properties}{uuid}        // '';
		next if $source eq '' || $uuid eq '';
		$encoded{"$source:$uuid"} = encode_json($f);
	}
	return if !%encoded;
	lock($map_version);
	$features_by_key{$_} = $encoded{$_} for keys %encoded;
	$map_version++;
}


sub removeRenderFeatures
	# Remove takes an explicit ($source, $uuids_ref) because the caller does
	# not have the feature objects -- only UUIDs -- so we cannot derive the
	# source the way addRenderFeatures does.  Asymmetric on purpose.
{
	my ($source, $uuids_ref) = @_;
	return if !$source || !@$uuids_ref;
	lock($map_version);
	delete $features_by_key{"$source:$_"} for @$uuids_ref;
	$map_version++;
}


sub clearRenderMap
	# Whole-map wipe.  User-driven coarse clear -- invoked from the Leaflet
	# "Clear" button (/clear endpoint) and from each pane's onClearMap.  NOT a
	# synchronization primitive; do not call from reconnect / refresh paths.
{
	lock($map_version);
	%features_by_key = ();
	$clear_version++;
	$map_version++;
}


sub isBrowserConnected
{
	return (time() - $last_poll_time) < 3;
}


sub openMapBrowser
	# MAP_BROWSER pref (if set) precedes the URL -- e.g. 'firefox --new-window'
	# to force a separate window; empty -> the system default browser.
{
	my $browser = getPref($PREF_MAP_BROWSER) // '';
	my $url     = 'http://localhost:'.getPref($PREF_HTTP_PORT).'/map.html';
	my $cmd     = $browser ? "start $browser $url" : "start \"\" $url";
	system(1, "cmd /c $cmd");
}


sub getClearVersion
{
	return $clear_version + 0;
}


sub pollTestCommand
{
	lock($test_pending);
	return '' if !$test_pending;
	my $cmd = $test_pending;
	$test_pending = '';
	return $cmd;
}


sub pollClearMapPending
{
	lock($clear_map_pending);
	return 0 if !$clear_map_pending;
	$clear_map_pending = 0;
	return 1;
}


sub pollTrackEditPending
{
	lock($track_edit_pending);
	return '' if !$track_edit_pending;
	my $edit = $track_edit_pending;
	$track_edit_pending = '';
	return $edit;
}


sub pollRouteEditPending
{
	lock($route_edit_pending);
	return '' if !$route_edit_pending;
	my $edit = $route_edit_pending;
	$route_edit_pending = '';
	return $edit;
}


#---------------------------------
# HTTP server
#---------------------------------

sub new
{
	my ($class) = @_;

	# navServer's HTTP config.  HTTP_PORT's default lives here and is published
	# to the prefs hash so getPref($PREF_HTTP_PORT) is its canonical read; a
	# prefs-file HTTP_PORT wins (set-if-absent skips it).  Packaged builds use a
	# different port so they coexist with development.
	setPref($PREF_HTTP_PORT, $Cava::Packager::PACKAGED ? 9873 : 9883)
		if !defined getPref($PREF_HTTP_PORT);

	my $params = {
		HTTP_DOCUMENT_ROOT    => "$resource_dir/site",
		HTTP_GET_EXT_RE       => 'html|js|css|png',
		HTTP_DEFAULT_LOCATION => '/map.html',
		HTTP_MAX_THREADS      => 4,
		HTTP_KEEP_ALIVE       => 0,
		HTTP_DEBUG_QUIET_RE   => '\/poll',
	};
	return $class->SUPER::new($params);
}


sub handle_request
{
	my ($this, $client, $request) = @_;
	my $uri = $request->{uri};

	if ($uri eq '/poll')
	{
		# Pure version query.  Server no longer detects reconnects via poll
		# gaps; that proved unreliable when the JS thread blocked on heavy
		# renders.  The client owns its own reconnect handling (see map.js
		# state machine + fetch timeouts).  $last_poll_time is still updated
		# so isBrowserConnected() can answer "have I been polled recently?"
		# for openMapBrowser() decisions.
		my $cv;
		{ lock($map_version); $cv = $map_version + 0; }
		$last_poll_time = time();
		return json_response($request,{ version => $cv });
	}
	elsif ($uri eq '/geojson')
	{
		my @feature_jsons;
		{ lock($map_version); @feature_jsons = values %features_by_key; }
		my @features = map { decode_json($_) } @feature_jsons;
		return json_response($request,{
			type     => 'FeatureCollection',
			features => \@features,
		});
	}
	elsif ($uri eq '/clear')
	{
		clearRenderMap();
		{ lock($clear_map_pending); $clear_map_pending = 1; }
		return json_response($request,{ ok => 1 });
	}
	elsif ($uri eq '/api/query')
	{
		my $sql = ($request->{params} || {})->{sql} // '';
		return json_response($request,{ error => 'no sql' }) if !$sql;
		return json_response($request,{ error => 'only SELECT allowed' })
			if ($sql !~ /^\s*SELECT\s/i);
		my $dbh = navDB::connectDB();
		my ($rows,$err) = navDB::rawQuery($dbh,$sql);
		navDB::disconnectDB($dbh);
		return $err
			? json_response($request,{ error => $err })
			: json_response($request,{ rows  => $rows });
	}
	elsif ($uri eq '/api/nmdb')
	{
		my $dbh = navDB::connectDB();
		return json_response($request,{ error => 'db connect failed' }) if !$dbh;
		my ($colls,  $e1) = navDB::rawQuery($dbh,
			"SELECT uuid, name, parent_uuid, node_type, position, source, created_ts, modified_ts FROM collections ORDER BY name");
		my ($wps,    $e2) = navDB::rawQuery($dbh,
			"SELECT uuid, name, collection_uuid, wp_type, sym, color, db_version, e80_version, kml_version, position, source, created_ts, modified_ts FROM waypoints ORDER BY name");
		my ($routes, $e3) = navDB::rawQuery($dbh,
			"SELECT uuid, name, collection_uuid, color, db_version, e80_version, kml_version, position, source, created_ts, modified_ts FROM routes ORDER BY name");
		my ($rtwps,  $e4) = navDB::rawQuery($dbh,
			"SELECT route_uuid, wp_uuid, position FROM route_waypoints ORDER BY route_uuid, position");
		my ($tracks, $e5) = navDB::rawQuery($dbh,
			"SELECT uuid, name, collection_uuid, ts_start, color, db_version, e80_version, kml_version, position, source, created_ts, modified_ts, point_count FROM tracks ORDER BY name");
		navDB::disconnectDB($dbh);
		my $err = $e1 || $e2 || $e3 || $e4 || $e5;
		return json_response($request,{ error => $err }) if $err;
		return json_response($request,{
			collections      => $colls,
			waypoints        => $wps,
			routes           => $routes,
			route_waypoints  => $rtwps,
			tracks           => $tracks,
		});
	}
	elsif ($uri eq '/api/fsh')
	{
		my $fsh_db = navFSH::getFSHDb();
		return json_response($request,{ error => 'no FSH database loaded' })
			if !$fsh_db;
		return json_response($request,{
			filename  => navFSH::getFilename(),
			waypoints => $fsh_db->{waypoints} // {},
			groups    => $fsh_db->{groups}    // {},
			routes    => $fsh_db->{routes}    // {},
			tracks    => $fsh_db->{tracks}    // {},
		});
	}
	elsif ($uri eq '/api/e80config')
	{
		# headless save/restore/clear: ip + folder are supplied directly (no pickers),
		# the library call runs to completion on this HTTP thread, no dialogs.  See
		# nmE80DirectOps::apiOp and docs/e80_config.md.
		my $params = $request->{params} // {};
		my $result = nmE80DirectOps::apiOp($params->{op}, $params->{ip}, $params->{folder});
		return json_response($request, $result);
	}
	elsif ($uri eq '/api/e80grab')
	{
		# headless screen capture: ip supplied directly.  With path=, write the PNG there and return
		# JSON; without path=, return the PNG bytes inline as image/png.  See nmE80DirectOps::apiGrab
		# and e80ScreenGrab_API.md.
		my $params = $request->{params} // {};
		my $result = nmE80DirectOps::apiGrab($params->{ip}, $params->{path});
		return Pub::HTTP::Response->new($request, $result->{png}, 200, 'image/png') if defined($result->{png});
		return json_response($request, $result);
	}

	elsif ($uri eq '/api/test')
	{
		my $params = $request->{params} // {};
		# op=suppress runs synchronously on the HTTP server thread so that
		# a subsequent /api/test op (e.g. clear_e80) cannot overwrite the
		# pending-test single slot and race past the suppression flag.
		# The flags are shared :shared scalars so cross-thread writes are
		# visible to the wx main thread immediately.
		if (($params->{op} // '') eq 'suppress')
		{
			$suppress_confirm      = ($params->{val} // 0) ? 1 : 0;
			$suppress_error_dialog = $suppress_confirm;
			if (exists $params->{outcome})
			{
				$suppress_outcome = $params->{outcome} // 'accept';
			}
			return json_response($request, { ok => 1, suppress_confirm => $suppress_confirm });
		}
		{ lock($test_pending); $test_pending = encode_json($params); }
		return json_response($request, { ok => 1, queued => 1 });
	}
	elsif ($uri eq '/track/edit')
	{
		my $h = $request->getPostJSON();
		return json_response($request,{ error => 'missing or invalid JSON body' }) if !$h;
		{ lock($track_edit_pending); $track_edit_pending = encode_json($h); }
		return json_response($request, { ok => 1, queued => 1 });
	}
	elsif ($uri eq '/route/edit')
	{
		my $h = $request->getPostJSON();
		return json_response($request, { error => 'missing or invalid JSON body' }) if !$h;
		{ lock($route_edit_pending); $route_edit_pending = encode_json($h); }
		return json_response($request, { ok => 1, queued => 1 });
	}

	if ($uri =~ m{^/sym/(native|mask)/(\d{2})\.png$})
	{
		# Leaflet sym icons.  /sym/native/NN.png returns the 16x16 RGBA
		# source with green-sentinel pixels keyed to alpha=0 (used as-is
		# by E80 and FSH waypoints).  /sym/mask/NN.png returns the same
		# geometry collapsed to luminance for client-side canvas tinting
		# of database waypoints.  Cache files live under
		# sym_catalog/cache/ and are built lazily on first request.
		my $kind = $1;
		my $i    = $2 + 0;
		my $cache_path = $kind eq 'native'
			? ensureLeafletNative($i)
			: ensureLeafletMask($i);
		if (!$cache_path)
		{
			return Pub::HTTP::Response->new($request, 'sym not found', 404, 'text/plain');
		}
		my $bytes = '';
		if (open(my $fh, '<:raw', $cache_path))
		{
			local $/;
			$bytes = <$fh>;
			close $fh;
		}
		return Pub::HTTP::Response->new($request, $bytes, 200, 'image/png');
	}

	$request->{uri} = '/anchor.png' if $uri eq '/favicon.ico';
	return $this->SUPER::handle_request($client,$request);
}


1;
