#-----------------------------------------------------
# wp_server.pm
#-----------------------------------------------------
# Serves the WAYPOINT database to Google Earth via network links
#
# To implement a true Google Earty KML 'Update', we have to
# denormalize our own local database (hashes), and keep
# track of what has changed for the client vis-a-vis the
# version number we sent them and they returned.
#
# We will start bu keeping the version number of every updated
# record in the WPMGR hashes, as well as implementing a compare
# to only update them if they have really changed.
#
# Although we could simply then compare the version of each local
# record versus the version of the GE request for existing changed
# records, this will not tell us which ones are new, nor which ones
# have been deleted.  Therefore, upon each GE request, we will create
# list of all the uuids in the WRG hashes with their version numbers.
#
# Each client will need to have a session ID by which the whole tree
# is kept for each client.



package wp_server;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time);
use Math::Trig qw(deg2rad );
use Pub::Utils;
use Pub::HTTP::ServerBase;
use Pub::HTTP::Response;
use r_WPMGR;
use wp_parse;
use base qw(Pub::HTTP::ServerBase);

my $dbg = 0;
my $dbg_kml = 1;
my $dbg_session = 1;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(
		startNQServer
		buildNavQueryKML
	);
}


my $EOL = "\r\n";

my $SERVER_PORT = 9882;
my $SRC_DIR = "/base/apps/raymarine/NET";
my $NETWORK_LINK = "http://localhost:9882/navqry.kml";

my $server_version:shared = -1;
my $navqry_kml:shared = kml_header(0,$server_version).kml_footer(0);

my $next_session_id:shared = 1000;
my $sessions = shared_clone({});

my $wp_server;
	





#-----------------------
# startNQServer
#-----------------------



sub startNQServer
{
	display($dbg,0,"starting wp_erver");
	$wp_server = wp_server->new();
	$wp_server->start();
	display($dbg,0,"finished starting wp_server");
}

sub new
{
    my ($class) = @_;

	# since we do not use a prefs file, we must
	# pass in all the HTTP::ServerBase parameters

	my $no_cache =  shared_clone({
		'cache-control' => 'max-age: 603200',
	});

	my $params = {

		HTTP_DEBUG_SERVER => -1,
			# 0 is nominal debug level showing one line per request and response
		HTTP_DEBUG_REQUEST => 0,
		HTTP_DEBUG_RESPONSE => 0,

		HTTP_DEBUG_QUIET_RE => 'navqry\.kml',
			# if the request matches this RE, the request
			# and response debug levels will be bumped by 2
			# so that under normal circumstances, no messages
			# will show for these.
		# HTTP_DEBUG_LOUD_RE => '^.*\.(?!jpg$|png$)[^.]+$',
			# An example that shows urls that DO NOT match .jpt and .png,
			# which shows JS, HTML, etc. And by setting DEBUG_REQUEST and
			# DEBUG_RESPONSE to -1, you only see headers for the debugging
			# at level 1.

		HTTP_MAX_THREADS => 5,
		HTTP_KEEP_ALIVE => 0,
			# In the ebay application, KEEP_ALIVE makes all the difference
			# in the world, not spawning a new thread for all 1000 images.

		HTTP_PORT => $SERVER_PORT,

		# Firefox image caching between invocations only works with HTTPS
		# HTTPS seems to work ok, but I get a number of untraceable
		# red "SSL attempt" failures. Even with normal HTTP, I get a number
		# of untraceable "Message(3397)::read_headers() TIMEOUT(2)"
		# red failures.

		# HTTP_SSL => 1,
		# HTTP_SSL_CERT_FILE => "/dat/Private/ssl/esp32/myIOT.crt",
		# HTTP_SSL_KEY_FILE  => "/dat/Private/ssl/esp32/myIOT.key",
		# HTTP_AUTH_ENCRYPTED => 1,
		# HTTP_AUTH_FILE      => "$base_data_dir/users/local_users.txt",
		# HTTP_AUTH_REALM     => "$owner_name Customs Manager Service",
		# HTTP_USE_GZIP_RESPONSES => 1,
		# HTTP_DEFAULT_HEADERS => {},
        # HTTP_ALLOW_SCRIPT_EXTENSIONS_RE => '',

		HTTP_DOCUMENT_ROOT => "$SRC_DIR/site",
        HTTP_GET_EXT_RE => 'html|js|css|jpg|png|ico',

		# example of setting default headers for GET_EXT_RE extensions

		HTTP_DEFAULT_HEADERS_JPG => $no_cache,
		HTTP_DEFAULT_HEADERS_PNG => $no_cache,
	};

    my $this = $class->SUPER::new($params);
	$this->{stop_service} = 0;
	return $this;

}


#-----------------------------------------
# handle_request
#-----------------------------------------

sub handle_request
{
    my ($this,$client,$request) = @_;
	my $response;

	display($dbg,0,"request method=$request->{method} uri=$request->{uri}")
		if $request->{uri} ne '/navqry.kml';

	# $request->{uri} = "/order_tracking.html" if $request->{uri} eq "index.html";
	# $request->{uri} = "/favicon.png" if $request->{uri} eq "/favicon.ico";

	my $uri = $request->{uri} || '';
	my $param_text = ($uri =~ s/\?(.*)$//) ? $1 : '';
	my $get_params = $request->{params};


	#-----------------------------------------------------------
	# main code
	#-----------------------------------------------------------

	if ($uri eq '/test')
	{
		my $text = 'this is a test';
		$response = http_ok($request,$text);
	}
	elsif ($uri eq '/navqry.kml')
	{
		# display_hash(0,0,"params",$request->{params});
		my $kml = buildNavQueryKML($request->{params});
		$response = http_ok($request,$kml);
		$response->{headers}->{'content-type'} = 'application/vnd.google-earth.kml+xml';
	}

	#------------------------------------------
	# Let the base class handle it
	#------------------------------------------

	else
	{
		$response = $this->SUPER::handle_request($client,$request);
	}
	return $response;

}	# handle_request()



#--------------------------------------------------------------------------------
# session management
#--------------------------------------------------------------------------------

sub update_session
{
	my ($sid,$client_version) = @_;
	display($dbg_session,0,"update_session($sid) client_version=$client_version wpmgr_version=".$wpmgr->getVersion());
	my $session = $sessions->{$sid};

	if (!$session)
	{
		$sid = $next_session_id++;
		display($dbg_session,1,"createing session($sid)");
		$session = $sessions->{$sid} = shared_clone({});
		$session->{sid} = $sid;
	}

	$session->{new} = 0;
	$session->{changed} = 0;
	$session->{deleted} = 0;

	addSessionHash($client_version,$session,'waypoints');
	addSessionHash($client_version,$session,'routes');
	addSessionHash($client_version,$session,'groups');

	display($dbg_session,0,"update_session() returning sid($sid)");
	return $sid;
}


sub addSessionHash
{
	my ($client_version,$session,$what_name) = @_;
	display($dbg_session,0,"addSessionHash($what_name) client_version=$client_version");

	my $new = 0;
	my $changed = 0;
	my $deleted = 0;

	my $new_items 		= $session->{"new_$what_name"} 		= shared_clone({});
	my $changed_items 	= $session->{"changed_$what_name"} 	= shared_clone({});
	my $deleted_items 	= $session->{"deleted_$what_name"} 	= shared_clone({});

	my $client_versions = $session->{$what_name} || {};
	my $local_items = $wpmgr->{$what_name};

	# deletions

	for my $uuid (keys %$client_versions)
	{
		my $client_version = $client_versions->{$uuid};
		my $local_item = $local_items->{$uuid};
		if (!$local_item)
		{
			$deleted_items->{$uuid} = $client_version;
			$deleted++;
		}
	}

	# additions and changes

	for my $uuid (keys %$local_items)
	{
		my $local_item = $local_items->{$uuid};
		my $local_version = $local_item->{version};
		my $client_version = $client_versions->{$uuid};
		if (!$client_version)	# version numbers must start at 1
		{
			$new_items->{$uuid} = $local_version;
			$new++;
		}
		elsif ($local_version != $client_version)
		{
			$changed_items->{$uuid} = $local_version;
			$changed++;
		}
	}

	# add all existing records to the client's records

	$client_versions = $session->{$what_name} = shared_clone({});
	for my $uuid (keys %$new_items)
	{
		$client_versions->{$uuid} = $new_items->{$uuid};
	}
	for my $uuid (keys %$changed_items)
	{
		$client_versions->{$uuid} = $changed_items->{$uuid};
	}

	# done

	$session->{new} += $new;
	$session->{changed} += $changed;
	$session->{deleted} += $deleted;

	display($dbg_session,0,"addSessionHash($what_name) returning new($new) changed($changed) deleted($deleted)");

}


#==================================================================================
# KML
#==================================================================================
# constants

my $abgr_color_white	= 'ffffffff';
my $abgr_color_blue 	= 'ffff0000';
my $abgr_color_green 	= 'ff00ff00';
my $abgr_color_red 		= 'ff0000ff';
my $abgr_color_cyan 	= 'ffffff00';
my $abgr_color_yellow 	= 'ff00ffff';
my $abgr_color_magenta 	= 'ffff00ff';

#  0 - red, 1 - yellow, 2 - green, 3 -#blue, 4 - magenta, 5 - black

my @route_colors = (
	$abgr_color_red,
	$abgr_color_yellow,
	$abgr_color_green,
	$abgr_color_blue,
	$abgr_color_magenta,
	$abgr_color_white );


my $route_width = 4;

# icons

my $boat_icon = "http://localhost:$SERVER_PORT/boat_icon.png";
my $circle_icon = 'http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png';
my $square_icon = 'http://maps.google.com/mapfiles/kml/shapes/placemark_square.png';
my $cross_hairs_icon = 'http://maps.google.com/mapfiles/kml/shapes/cross-hairs.png';

my $circle3_icon = 'http://maps.google.com/mapfiles/kml/shapes/target.png';
my $circle2_icon = 'http://maps.google.com/mapfiles/kml/shapes/donut.png';
my $square2_icon = 'http://maps.google.com/mapfiles/kml/shapes/square.png';
my $diamond2_icon = 'http://maps.google.com/mapfiles/kml/shapes/open-diamond.png';
my $triangle2_icon = 'http://maps.google.com/mapfiles/kml/shapes/triangle.png';
my $star_icon = 'http://maps.google.com/mapfiles/kml/shapes/star.png';


#----------------------------------
# methods
#----------------------------------

my $indent_level = 0;



sub indent
{
	my ($level,$s) = @_;
	$indent_level += $level if $level < 0;
	my $kml = pad('',$indent_level*4).$s.$EOL;
	$indent_level += $level if $level > 0;
	$indent_level = 0 if $indent_level < 0;
	return $kml;
}



sub kml_footer
{
	my ($update) = @_;
	my $kml = '';
	if ($update)
	{
		$kml .= indent(-1,"</Update>");
		$kml .= indent(-1,"</NetworkLinkControl>");
	}
	else
	{
		$kml .= indent(-1,"</Document>");
		$kml .= indent(0,"<Name>Test</Name>");
	}
	$kml .= indent(0,"</kml>");
	return $kml;
}

sub kml_header
{
	my ($sid,$version,$update) = @_;
	my $kml = '<?xml version="1.0" encoding="UTF-8"?>'.$EOL;
	$kml .= '<kml xmlns="http://www.opengis.net/kml/2.2" ';
	$kml .= 'xmlns:gx="http://www.google.com/kml/ext/2.2" ';
	$kml .= 'xmlns:kml="http://www.opengis.net/kml/2.2" ';
	$kml .= 'xmlns:atom="http://www.w3.org/2005/Atom">'.$EOL;
	$kml .= indent( 1,"<NetworkLinkControl>");
	$kml .= indent( 0,"<cookie>sid=$sid&amp;version=$version</cookie>");
	$kml .= indent( 0,"<linkName>Waypoint Manager</linkName>");
	$kml .= indent( 0,"<targetHref>$NETWORK_LINK</targetHref>");
	if ($update)
	{
		$kml .= indent( 1,"<Update>");
	}
	else
	{
		$kml .= indent(-1,"</NetworkLinkControl>");
		$kml .= indent( 1,"<Document>");
	}

	return $kml;
}


sub kml_end_folder
{
	return indent(-1,"</Folder>");
}


sub kml_start_folder
{
	my ($style,$id,$name) = @_;
	display($dbg_kml,0,"kml_start_folder($style,$name)");

	my $kml = '';
	$kml .= indent( 1,"<Folder id=\"$id\">");
	$kml .= indent( 0,"<name>$name</name>");
	$kml .= indent( 0,"<styleUrl>$style</styleUrl>");
	# $kml .= indent( 0,"<visibility>1</visibility>");
	$kml .= indent( 0,"<open>1</open>");
	return $kml;
}





sub kml_global_styles
	# global style for Groups (waypoints folders including fake _My Waypoints)
{
	my $kml = '';
    $kml .= indent( 1,"<Style id=\"groupStyle\">",-1);
    $kml .= indent( 1,"<IconStyle>");
	$kml .= indent( 0,"<color>$abgr_color_cyan</color>");
    $kml .= indent( 0,"<scale>0.6</scale>");
    # $kml .= indent( 0,"<heading>$heading</heading>") if $heading;
    $kml .= indent( 1,"<Icon>");
    $kml .= indent( 0,"<href>$circle2_icon</href>");
    $kml .= indent(-1,"</Icon>");
    $kml .= indent(-1,"</IconStyle>");
	$kml .= indent( 1,"<LabelStyle>");
    $kml .= indent( 0,"<scale>0.6</scale>");
	$kml .= indent( 0,"<color>$abgr_color_cyan</color>");
	$kml .= indent(-1,"</LabelStyle>");
    $kml .= indent(-1,"</Style>");

	for (my $i=0; $i<$NUM_ROUTE_COLORS; $i++)
	{
		$kml .= kml_route_style($i);
	}
	return $kml;
}


sub kml_route_style
	# style for routes and things in them
{
	my ($color_index) = @_;
	my $kml = '';

	$kml .= indent( 1,"<Style id=\"routeStyle$color_index\">");
    $kml .= indent( 1,"<IconStyle>");
    $kml .= indent( 0,"<scale>0.6</scale>");
	$kml .= indent( 0,"<color>$abgr_color_red</color>");
    $kml .= indent( 1,"<Icon>");
    $kml .= indent( 0,"<href>$square_icon</href>");
	$kml .= indent( 0,"<color>$route_colors[$color_index]</color>");
    $kml .= indent(-1,"</Icon>");
    $kml .= indent(-1,"</IconStyle>");
	$kml .= indent( 1,"<LabelStyle>");
    $kml .= indent( 0,"<scale>0.6</scale>");
	$kml .= indent( 0,"<color>$abgr_color_red</color>");
	$kml .= indent(-1,"</LabelStyle>");
	$kml .= indent( 1,"<LineStyle>");
	$kml .= indent( 0,"<color>$route_colors[$color_index]</color>");
	$kml .= indent( 0,"<width>$route_width</width>");
	$kml .= indent(-1, "</LineStyle>");
	$kml .= indent(-1, "</Style>");
	return $kml;
}


sub kml_waypoint
{
	my ($style, $id, $wp) = @_;
	display($dbg_kml,0,"kml_waypoint($style,$id) $wp->{name}");
	my $lat = $wp->{lat}/$SCALE_LATLON;
	my $lon = $wp->{lon}/$SCALE_LATLON;

	my $kml = '';
	$kml .= indent( 1,"<Placemark id=\"$id\">");
	$kml .= indent( 0,"<name>$wp->{name}</name>");
	$kml .= indent( 0,"<visibility>1</visibility>");
	# $kml .= indent( 0,"<description>$descrip</description>") if $descrip;
	# $kml .= indent( 0,"<TimeStamp><when>$timestamp/when></TimeStamp>") if $timestamp;
	$kml .= indent( 0,"<styleUrl>$style</styleUrl>");
	$kml .= indent( 1,"<Point>", 1);
	$kml .= indent( 0,"<coordinates>$lon,$lat,0</coordinates>");
	$kml .= indent(-1,"</Point>");
	$kml .= indent(-1,"</Placemark>");
	return $kml;
}



sub kml_route_string
	# builds a placemark with a linestring for a route
{
	my ($style,$route_name,$waypoints) = @_;
	return '' if !@$waypoints;
	display($dbg_kml,0,"kml_route_string($style,$route_name)");

	# Build coordinates string

	my $coord_str = '';
	foreach my $uuid (@$waypoints)
	{
		my $wp = $wpmgr->{waypoints}->{$uuid};
		my $lat = $wp->{lat}/$SCALE_LATLON;
		my $lon = $wp->{lon}/$SCALE_LATLON;

		$wp ?
			($coord_str .= "$lon,$lat,0 ") :
			 error("Could not find wp($uuid)");
	}
	$coord_str =~ s/\s+$//;  # trim trailing space

	# Wrap in Placemark

	my $kml = '';
	$kml .= indent( 1,"<Placemark id=\"$route_name\">");
	$kml .= indent( 0,"<name>$route_name Track</name>");
	$kml .= indent( 0,"<visibility>1</visibility>");
	$kml .= indent( 0,"<styleUrl>$style</styleUrl>");
	$kml .= indent( 1,"<LineString>");
	$kml .= indent( 0,"<coordinates>$coord_str</coordinates>");
	$kml .= indent(-1,"</LineString>");
	$kml .= indent(-1,"</Placemark>");
	return $kml;
}



sub cmpByName
{
	my ($hash,$a,$b) = @_;
	my $wp_a = $hash->{$a};
	my $wp_b = $hash->{$b};
	my $name_a = $wp_a->{name};
	my $name_b = $wp_b->{name};
	return lc($name_a) cmp lc($name_b);
}

sub sortedKeys
{
	my ($session,$key_field) = @_;
	my $hash_name = $key_field;
	$hash_name =~ s/(new_|changed_|deleted_)//;
	my $hash = $wpmgr->{$hash_name};

	my @keys = sort {cmpByName($hash,$a,$b)} keys %{$session->{$key_field}};
	return @keys;
}
	



sub kml_delete_items
{
	my ($session) = @_;
	display($dbg_kml,0,"kml_delete_items() sid=$session->{sid}");

	my $kml = '';
	for my $uuid (sortedKeys($session,'deleted_waypoints'))
	{
		display($dbg_kml,0,"kml_delete_items() waypoint uuid=$uuid");
		$kml .= indent( 0,"<Placemark targetId=\"$uuid\"/>");
	}
	for my $uuid (sortedKeys($session,'deleted_groups'))
	{
		display($dbg_kml,0,"kml_delete_items() group uuid=$uuid");
		$kml .= indent( 0,"<Folder targetId=\"$uuid\"/>");
	}
	for my $uuid (sortedKeys($session,'deleted_routes'))
	{
		display($dbg_kml,0,"kml_delete_items() route uuid=$uuid");
		$kml .= indent( 0,"<Folder targetId=\"$uuid\"/>");
	}

	display($dbg_kml,0,"kml_delete_items() complete sid=$session->{sid}");
	return $kml;
}



sub kml_change_items
{
	my ($session, $wpmgr) = @_;
	display($dbg_kml,0,"kml_change_items() sid=$session->{sid}");

	my $kml = '';

	for my $uuid (sortedKeys($session,'changed_waypoints'))
	{
		my $wp = $wpmgr->{waypoints}{$uuid} or next;
		display($dbg_kml,0,"kml_change_items() waypoint uuid=$uuid");

		my $lat = $wp->{lat}/$SCALE_LATLON;
		my $lon = $wp->{lon}/$SCALE_LATLON;

		$kml .= indent( 1,"<Placemark targetId=\"$uuid\">");
		$kml .= indent( 0,"<name>$wp->{name}</name>");
		$kml .= indent( 0,"<styleUrl>#groupStyle</styleUrl>");
		$kml .= indent( 0,"<Point><coordinates>$lon,$lat,0</coordinates></Point>");
		$kml .= indent(-1,"</Placemark>");
	}

	for my $uuid (sortedKeys($session,'changed_groups'))
	{
		my $group = $wpmgr->{groups}{$uuid} or next;
		display($dbg_kml,0,"kml_change_items() group uuid=$uuid");

		$kml .= indent( 1,"<Folder targetId=\"$uuid\">");
		$kml .= indent( 0,"<name>$group->{name}</name>");
		$kml .= indent( 0,"<styleUrl>#groupStyle</styleUrl>");
		$kml .= indent(-1,"</Folder>");
	}

	for my $uuid (sortedKeys($session,'changed_routes'))
	{
		my $route = $wpmgr->{routes}{$uuid} or next;
		display($dbg_kml,0,"kml_change_items() route uuid=$uuid");

		$kml .= indent( 1,"<Folder targetId=\"$uuid\">");
		$kml .= indent( 0,"<name>$route->{name}</name>");
		$kml .= indent( 0,"<styleUrl>#routeStyle</styleUrl>");
		$kml .= indent(-1,"</Folder>");
	}

	display($dbg_kml,0,"kml_change_items() complete sid=$session->{sid}");
	return $kml;
}


sub kml_create_groups
{
	my ($session, $wpmgr) = @_;
	display($dbg_kml,0,"kml_create_groups() sid=$session->{sid}");

	my $kml = '';
	for my $uuid (sortedKeys($session,'new_groups'))
	{
		my $group = $wpmgr->{groups}{$uuid} or next;
		display($dbg_kml,0,"kml_create_groups() uuid=$uuid");

		$kml .= kml_start_folder("#groupStyle", $uuid, $group->{name});
		for my $wp_uuid (@{ $group->{uuids} })
		{
			my $wp = $wpmgr->{waypoints}->{$wp_uuid} or next;
			$kml .= kml_waypoint("#groupStyle", $wp_uuid, $wp);
		}
		$kml .= kml_end_folder();
	}

	display($dbg_kml,0,"kml_create_groups() complete sid=$session->{sid}");
	return $kml;
}


sub kml_create_routes
{
	my ($session, $wpmgr) = @_;
	display($dbg_kml,0,"kml_create_routes() sid=$session->{sid}");

	my $kml = '';
	for my $uuid (sortedKeys($session,'new_routes'))
	{
		my $route = $wpmgr->{routes}{$uuid} or next;
		display($dbg_kml,0,"kml_create_routes() uuid=$uuid");

		my $routeStyle = "#routeStyle$route->{color}";
		
		$kml .= kml_start_folder($routeStyle, $uuid, $route->{name});
		for my $wp_uuid (@{ $route->{uuids} })
		{
			my $wp = $wpmgr->{waypoints}{$wp_uuid} or next;
			$kml .= kml_waypoint($routeStyle, $wp_uuid, $wp);
		}
		$kml .= kml_end_folder();
	}

	display($dbg_kml,0,"kml_create_routes() complete sid=$session->{sid}");
	return $kml;
}


sub kml_create_orphan_waypoints
{
	my ($session, $wpmgr) = @_;
	display($dbg_kml,0,"kml_create_orphan_waypoints() sid=$session->{sid}");

	my $kml = '';
	$kml .= kml_start_folder("#groupStyle","my_waypoints","My Waypoints");
	for my $uuid (sortedKeys($session,'new_waypoints'))
	{
		my $wp = $wpmgr->{waypoints}{$uuid} or next;

		my $in_group = grep { $uuid ~~ $_->{uuids} } values %{ $wpmgr->{groups} };
		my $in_route = grep { $uuid ~~ $_->{uuids} } values %{ $wpmgr->{routes} };
		next if $in_group || $in_route;

		display($dbg_kml,0,"kml_create_orphan_waypoints() uuid=$uuid");
		$kml .= kml_waypoint("#groupStyle", $uuid, $wp);
	}
	$kml.= kml_end_folder();
	display($dbg_kml,0,"kml_create_orphan_waypoints() complete sid=$session->{sid}");
	return $kml;
}



#------------------------------------------------------------------
# buildNavQueryKML
#------------------------------------------------------------------


sub kml_update_block
{
	my ($session, $update) = @_;
	display($dbg_kml,0,"kml_update_block($update) sid=$session->{sid}");

	my $kml = '';

	if ($update)
	{
		$kml .= indent( 1,"<Delete>");
		$kml .= kml_delete_items($session);
		$kml .= indent(-1,"</Delete>");

		$kml .= indent( 1,"<Change>");
		$kml .= kml_change_items($session, $wpmgr);
		$kml .= indent(-1,"</Change>");

		$kml .= indent( 1,"<Create>");
	}
	else
	{
		$kml .= kml_global_styles();
	}

	$kml .= kml_start_folder('#groupStyle',"groups_id","Groups");
	$kml .= kml_create_orphan_waypoints($session, $wpmgr);
	$kml .= kml_create_groups($session, $wpmgr);
	$kml .= kml_end_folder();

	$kml .= kml_start_folder('#routeStyle',"routes_id","Routes");
	$kml .= kml_create_routes($session, $wpmgr);
	$kml .= kml_end_folder();

	$kml .= indent(-1,"</Create>")
		if $update;

	display($dbg_kml,0,"kml_update_block() complete sid=$session->{sid}");
	return $kml;
}



sub buildNavQueryKML
{
	my ($params) = @_;
	my $old_sid = $params->{sid} || 0;
	my $old_version = $params->{version} || 0;
	my $new_version = $wpmgr->getVersion();
	display($dbg_kml-1,0,"buildNavQueryKML($old_sid,$old_version)");
	
	my $update = $old_sid ? 1 : 0;
	
	my $sid = update_session($old_sid,$old_version);
	my $session = $sessions->{$sid};
	display_hash($dbg_kml,1,"session($sid)",$session);

	my $kml = kml_header($sid,$new_version,$update);
	$kml .= kml_update_block($session,$update);
	$kml .= kml_footer($update);

	if (1 || $dbg_kml < -1)
	{
		if (0 && $dbg_kml < -1)
		{
			print "---------------------------------------\n";
			print $kml;
			print "---------------------------------------\n";
		}
		printVarToFile(1,"test.kml",$kml, 1);
	}


	return $kml;
}




1;
