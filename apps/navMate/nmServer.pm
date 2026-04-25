#---------------------------------------------
# nmServer.pm
#---------------------------------------------
# HTTP server for navMate. Port 9883.
# Static files from _site/. API: /poll /geojson /clear.
#
# Shared state is written by the wx thread (addRenderFeatures, clearRenderMap)
# and read by the server threads (/geojson, /poll). All updates lock $map_version.

package nmServer;
use strict;
use warnings;
use threads;
use threads::shared;
use File::Basename qw(dirname);
use Cwd qw(abs_path);
use Pub::Utils qw(display warning error);
use Pub::HTTP::ServerBase;
use Pub::HTTP::Response qw(json_response);
use JSON::PP qw(encode_json decode_json);
use c_db;
use base qw(Pub::HTTP::ServerBase);

my $SERVER_PORT = 9883;
my $SITE_DIR    = dirname(abs_path(__FILE__)) . '/_site';

my $nm_server;

my $map_version    :shared = 0;
my $last_poll_time :shared = 0;
my $features_json  :shared = '[]';
my $clear_version  :shared = 0;


BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(
		startNavMateServer
		addRenderFeatures
		clearRenderMap
		isBrowserConnected
		openMapBrowser
		getClearVersion
	);
}


#---------------------------------
# public API (called from wx thread)
#---------------------------------

sub startNavMateServer
{
	display(0, 0, "starting nmServer on port $SERVER_PORT");
	$nm_server = nmServer->new();
	$nm_server->start();
	display(0, 0, "nmServer started");
}


sub addRenderFeatures
{
	my ($features_ref) = @_;
	return unless @$features_ref;
	lock($map_version);
	my $existing = decode_json($features_json);
	push @$existing, @$features_ref;
	$features_json = encode_json($existing);
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
	system(1, 'cmd /c start firefox --new-window http://localhost:9883/map.html');
}


sub getClearVersion
{
	return $clear_version + 0;
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
		my $params = $request->{params} || {};
		my $cv;
		{ lock($map_version); $cv = $map_version + 0; }
		$last_poll_time = time();
		return json_response($request, { version => $cv });
	}
	elsif ($uri eq '/geojson')
	{
		my $json;
		{ lock($map_version); $json = $features_json; }
		my $features = decode_json($json);
		return json_response($request, {
			type     => 'FeatureCollection',
			features => $features,
		});
	}
	elsif ($uri eq '/clear')
	{
		clearRenderMap();
		return json_response($request, { ok => 1 });
	}
	elsif ($uri eq '/api/query')
	{
		my $sql = ($request->{params} || {})->{sql} // '';
		return json_response($request, { error => 'no sql' }) unless $sql;
		return json_response($request, { error => 'only SELECT allowed' })
			unless $sql =~ /^\s*SELECT\s/i;
		my ($rows, $err) = c_db::rawQuery($sql);
		return $err
			? json_response($request, { error => $err })
			: json_response($request, { rows => $rows });
	}

	return $this->SUPER::handle_request($client, $request);
}


1;
