#---------------------------------------------
# nmServer.pm
#---------------------------------------------
# navMate HTTP server.  Extends h_server.pm.
# Port 9883.  Static files from _site/.
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

package nmServer;
use strict;
use warnings;
use threads;
use threads::shared;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use JSON::PP qw(encode_json decode_json);
use Pub::Utils qw(display warning error);
use Pub::HTTP::Response qw(json_response);
use apps::raymarine::NET::h_server;
use c_db;
use base qw(apps::raymarine::NET::h_server);


my $SERVER_PORT = 9883;
my $SITE_DIR    = dirname(abs_path(__FILE__)) . '/_site';

my $nm_server;

my $map_version    :shared = 0;
my $last_poll_time :shared = 0;
my $features_json  :shared = '[]';
my $clear_version  :shared = 0;
my $test_pending   :shared = '';


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
	);
}


#---------------------------------
# public API (called from wx thread)
#---------------------------------

sub startNavMateServer
{
	display(0,0,"starting nmServer on port $SERVER_PORT");
	$nm_server = nmServer->new();
	$nm_server->start();
	display(0,0,"nmServer started");
}


sub dispatchNavMateCommand
{
	my ($lpart, $rpart) = @_;
	$nm_server->handleCommand($lpart, $rpart) if $nm_server;
}


sub addRenderFeatures
{
	my ($features_ref) = @_;
	return if !@$features_ref;
	lock($map_version);
	my $existing = decode_json($features_json);
	push @$existing, @$features_ref;
	$features_json = encode_json($existing);
	$map_version++;
}


sub removeRenderFeatures
{
	my ($uuids_ref) = @_;
	return if !@$uuids_ref;
	my %remove = map { $_ => 1 } @$uuids_ref;
	lock($map_version);
	my $existing = decode_json($features_json);
	my @kept = grep { !$remove{$_->{properties}{uuid} // ''} } @$existing;
	$features_json = encode_json(\@kept);
	$map_version++;
}


sub clearRenderMap
{
	lock($map_version);
	$features_json = '[]';
	$clear_version++;
	$map_version++;
}


sub isBrowserConnected
{
	return (time() - $last_poll_time) < 3;
}


sub openMapBrowser
{
	system(1,'cmd /c start firefox --new-window http://localhost:9883/map.html');
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


#---------------------------------
# HTTP server
#---------------------------------

sub new
{
	my ($class) = @_;
	my $params = {
		HTTP_PORT             => $SERVER_PORT,
		HTTP_DOCUMENT_ROOT    => $SITE_DIR,
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
		my $cv;
		{ lock($map_version); $cv = $map_version + 0; }
		$last_poll_time = time();
		return json_response($request,{ version => $cv });
	}
	elsif ($uri eq '/geojson')
	{
		my $json;
		{ lock($map_version); $json = $features_json; }
		my $features = decode_json($json);
		return json_response($request,{
			type     => 'FeatureCollection',
			features => $features,
		});
	}
	elsif ($uri eq '/clear')
	{
		clearRenderMap();
		return json_response($request,{ ok => 1 });
	}
	elsif ($uri eq '/api/query')
	{
		my $sql = ($request->{params} || {})->{sql} // '';
		return json_response($request,{ error => 'no sql' }) if !$sql;
		return json_response($request,{ error => 'only SELECT allowed' })
			if ($sql !~ /^\s*SELECT\s/i);
		my $dbh = c_db::connectDB();
		my ($rows,$err) = c_db::rawQuery($dbh,$sql);
		c_db::disconnectDB($dbh);
		return $err
			? json_response($request,{ error => $err })
			: json_response($request,{ rows  => $rows });
	}
	elsif ($uri eq '/api/nmdb')
	{
		my $dbh = c_db::connectDB();
		return json_response($request,{ error => 'db connect failed' }) if !$dbh;
		my ($colls,  $e1) = c_db::rawQuery($dbh,
			"SELECT uuid, name, parent_uuid, node_type FROM collections ORDER BY name");
		my ($wps,    $e2) = c_db::rawQuery($dbh,
			"SELECT uuid, name, collection_uuid, wp_type FROM waypoints ORDER BY name");
		my ($routes, $e3) = c_db::rawQuery($dbh,
			"SELECT uuid, name, collection_uuid FROM routes ORDER BY name");
		my ($rtwps,  $e4) = c_db::rawQuery($dbh,
			"SELECT route_uuid, wp_uuid, position FROM route_waypoints ORDER BY route_uuid, position");
		my ($tracks, $e5) = c_db::rawQuery($dbh,
			"SELECT uuid, name, collection_uuid, ts_start FROM tracks ORDER BY name");
		c_db::disconnectDB($dbh);
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

	elsif ($uri eq '/api/test')
	{
		my $params = $request->{params} // {};
		{ lock($test_pending); $test_pending = encode_json($params); }
		return json_response($request, { ok => 1, queued => 1 });
	}

	return $this->SUPER::handle_request($client,$request);
}


1;
