#-----------------------------------------------------
# r_server.pm
#-----------------------------------------------------
# Serves the WAYPOINT database to Google Earth via network links


package r_server;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time);
use Math::Trig qw(deg2rad );
use Pub::Utils;
use Pub::ServerUtils;
use Pub::HTTP::ServerBase;
use Pub::HTTP::Response;
use r_defs;
use tcpBase;
use r_WPMGR;
use r_TRACK;
use wp_parse;
use base qw(Pub::HTTP::ServerBase);

my $dbg = 0;
my $dbg_kml = 1;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(
		startHTTPServer
		kml_RAYSYS
		showLocalDatabase
	);
}


my $EOL = "\r\n";

my $SERVER_PORT = 9882;
my $SRC_DIR = "/base/apps/raymarine/NET";
my $NETWORK_LINK = "http://localhost:9882/raysys.kml";


my $ray_server;
my $server_version:shared = -1;
my $server_kml:shared = kml_header(0,$server_version).kml_footer(0);
my $server_cache_filename = "$temp_dir/server_cache.kml";


#------------------------
# main
#-----------------------

Pub::ServerUtils::initServerUtils(0,'');
	# 0 == DOESNT NEEDS WIFI
	# '' == LINUX PID FILE	


#-----------------------
# startNQServer
#-----------------------

sub startHTTPServer
{
	display($dbg,0,"starting wp_erver");

	$ray_server = r_server->new();
	$ray_server->start();
	display($dbg,0,"finished starting r_server");
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

		HTTP_DEBUG_SERVER => -1,	# POSITIVE NUMBERS MEAN MORE DEBUGGING
			# 0 is nominal debug level showing one line per request and response
		HTTP_DEBUG_REQUEST => 0,
		HTTP_DEBUG_RESPONSE => 0,

		HTTP_DEBUG_QUIET_RE => 'raysys\.kml',
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
		if $request->{uri} ne '/raysys.kml';

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
	elsif ($uri eq '/raysys.kml')
	{
		my $kml = kml_RAYSYS($request->{params});
		if ($kml)
		{
			$response = http_ok($request,$kml);
			$response->{headers}->{'content-type'} = 'application/vnd.google-earth.kml+xml';
		}
		else
		{
			$response = http_error($request,"No kml was created");
		}
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
my $abgr_color_dark_green 	= 'ff008800';

#  0 - red, 1 - yellow, 2 - green, 3 -#blue, 4 - magenta, 5 - black

my @line_colors = (
	$abgr_color_red,
	$abgr_color_yellow,
	$abgr_color_green,
	$abgr_color_blue,
	$abgr_color_magenta,
	$abgr_color_white );


my $ROUTE_WIDTH = 4;
my $TRACK_WIDTH = 2;

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


sub kml_footer
{
	my ($update) = @_;
	my $kml = '';
	$kml .= "</Update>$EOL</NetworkLinkControl>$EOL" if $update;
	$kml .=	"</Document>$EOL" if !$update;
	$kml .= "</kml>$EOL";
	return $kml;
}

sub kml_header
{
	my ($update,$local_version) = @_;
	
	my $kml = '<?xml version="1.0" encoding="UTF-8"?>'.$EOL;
	$kml .= '<kml xmlns="http://www.opengis.net/kml/2.2" ';
	$kml .= 'xmlns:gx="http://www.google.com/kml/ext/2.2" ';
	$kml .= 'xmlns:kml="http://www.opengis.net/kml/2.2" ';
	$kml .= 'xmlns:atom="http://www.w3.org/2005/Atom">'.$EOL;

	$kml .= "<NetworkLinkControl>$EOL";
	# $kml .= "<minRefreshPeriod>0</minRefreshPeriod>$EOL";
	# $kml .= "<maxSessionLength>-1</maxSessionLength>$EOL";
	$kml .= "<cookie>version=$local_version</cookie>$EOL";
	# $kml .= "<message>version($local_version)</message>$EOL";
	$kml .= "<linkName>RAYSYS($local_version)</linkName>$EOL";
	#	doesn't change
	# $kml .= "<linkDescription>...</linkDescription>$EOL";;
	# $kml .= "<linkSnippet maxLines="2">...</linkSnippet>$EOL";
	# $kml .= "<expires>...</expires>$EOL";
	# $kml .= "<Update>...</Update>$EOL";
	# $kml .= "<AbstractView>...</AbstractView>$EOL";

	if ($update)
	{
		$kml .= "<Update>$EOL";
	}
	else
	{
		$kml .= "</NetworkLinkControl>$EOL";
		$kml .= "<Document>$EOL";
		$kml .= "<name>WAYPOINT</name>$EOL";

		if (0)
		{
			$kml .= "<NetworkLink>$EOL";
			# $kml .= "<name>ThirdName</name>$EOL";
			$kml .= "<refreshVisibility>0</refreshVisibility>$EOL";
			$kml .= "<flyToView>1</flyToView>$EOL";
			$kml .= "<Link>$NETWORK_LINK</Link>$EOL";
			$kml .= "</NetworkLink>$EOL";
		}
	}
	return $kml;
}


sub kml_end_folder
{
	return "</Folder>$EOL";
}


sub kml_start_folder
{
	my ($style,$id,$name) = @_;
	display($dbg_kml,0,"kml_folder_string($style,$name)");
	my $kml = "<Folder id=\"$id\">$EOL";
	$kml .= "<name>$name</name>";
	$kml .= "<styleUrl>$style</styleUrl>$EOL";
	# $kml .= "<visibility>1</visibility>$EOL";
	$kml .= "<open>1</open>$EOL";
	return $kml;
}


sub kml_global_styles
	# global style for Groups (waypoints folders including fake _My Waypoints)
{
	my $kml = '';
    $kml .= '<Style id="groupStyle">'.$EOL;
    $kml .= "<IconStyle>$EOL";
	$kml .= "<color>$abgr_color_cyan</color>$EOL";
    $kml .= "<scale>0.6</scale>$EOL";
    # $kml .= "<heading>$heading</heading>$EOL" if $heading;
    $kml .= "<Icon>$EOL";
    $kml .= "<href>$circle2_icon</href>$EOL";
    $kml .= "</Icon>$EOL";
    $kml .= "</IconStyle>$EOL";
	$kml .= "<LabelStyle>$EOL";
    $kml .= "<scale>0.6</scale>$EOL";
	$kml .= "<color>$abgr_color_cyan</color>$EOL";
	$kml .= "</LabelStyle>$EOL";
    $kml .= "</Style>$EOL";

	for (my $i=0; $i<$NUM_ROUTE_COLORS; $i++)
	{
		$kml .= kml_linestyle('route',$i,$square_icon,$abgr_color_red);
		$kml .= kml_linestyle('track',$i,$circle_icon,$abgr_color_dark_green);
	}
	return $kml;
}


sub kml_linestyle
	# style for routes and things in them
{
	my ($what,$color_index,$icon,$icon_label_color) = @_;

	my $width = $what eq 'track' ? $TRACK_WIDTH : $ROUTE_WIDTH;

	my $kml = '';
	$kml .= "<Style id=\"$what"."Style$color_index\">$EOL";
    $kml .= "<IconStyle>$EOL";
    $kml .= "<scale>0.6</scale>$EOL";
	$kml .= "<color>$icon_label_color</color>$EOL";
    $kml .= "<Icon>$EOL";
    $kml .= "<href>$icon</href>$EOL";
	$kml .= "<color>$line_colors[$color_index]</color>$EOL";
    $kml .= "</Icon>$EOL";
    $kml .= "</IconStyle>$EOL";
	$kml .= "<LabelStyle>$EOL";
    $kml .= "<scale>0.6</scale>$EOL";
	$kml .= "<color>$icon_label_color</color>$EOL";
	$kml .= "</LabelStyle>$EOL";
	$kml .= "<LineStyle>$EOL";
	$kml .= "<color>$line_colors[$color_index]</color>$EOL";
	$kml .= "<width>$width</width>$EOL";
	$kml .= "</LineStyle>$EOL";
	$kml .= "</Style>$EOL";
	return $kml;
}



sub kml_route_string
	# builds a placemark with a linestring for a route
{
	my ($what,$color,$name,$waypoints) = @_;
	my @points;
	foreach my $uuid (@$waypoints)
	{
		my $wp = $wp_mgr->{waypoints}->{$uuid};
		push @points,$wp;
	}
	return kml_line_string($what,$color,$name,\@points);
}


sub kml_line_string
	# builds a placemark with a linestring for a route
	# track points are already normal as they're from northEastToLatLon
	# route points are 1E7
{
	my ($what,$color,$name,$points) = @_;
	my $num_points = $points ? @$points : 0;
	# error("No points ref in $what $name!") if !$points;
	# return '' if !$points || !@$points;
	display($dbg_kml,0,"kml_line_string($what,$color,$name) num_pts=$num_points");

	# Build coordinates string

	my $coord_str = '';
	if ($num_points)
	{
		foreach my $point (@$points)
		{
			my $lat = $point->{lat};
			my $lon = $point->{lon};
			$lat /= $SCALE_LATLON if $what eq 'route';
			$lon /= $SCALE_LATLON if $what eq 'route';
			$coord_str .= "$lon,$lat,0 ";
		}
		$coord_str =~ s/\s+$//;  # trim trailing space
	}
	
	# Wrap in Placemark

	my $kml = '';
	$kml .= "<Placemark id=\"$what"."_$name\">$EOL";
	$kml .= "<name>$name</name>$EOL";
	# $kml .= "<visibility>1</visibility>$EOL";
	$kml .= "<styleUrl>$what"."Style$color</styleUrl>$EOL";
	$kml .= "<LineString>$EOL";
	$kml .= "<coordinates>$coord_str</coordinates>$EOL";
	$kml .= "</LineString>$EOL";
	$kml .= "</Placemark>$EOL";
	return $kml;
}




sub kml_waypoint
{
	my ($style, $id, $wp) = @_;
	display($dbg_kml,0,"kml_waypoint($style,$wp->{name})");
	my $lat = $wp->{lat}/$SCALE_LATLON;
	my $lon = $wp->{lon}/$SCALE_LATLON;

	my $kml = '';
	$kml .= "<Placemark id=\"$id\">$EOL";
	$kml .= "<name>$wp->{name}</name>$EOL";
	# $kml .= "<visibility>1</visibility>$EOL";
	# $kml .= "<description>$descrip</description>$EOL" if $descrip;
	# $kml .= "<TimeStamp><when>$timestamp/when></TimeStamp>$EOL" if $timestamp;
	$kml .= "<styleUrl>$style</styleUrl>$EOL";
	$kml .= "<Point>$EOL";
	$kml .= "<coordinates>$lon,$lat,0</coordinates>$EOL";
	$kml .= "</Point>$EOL";
	$kml .= "</Placemark>$EOL";
	return $kml;
}



sub cmpByName
{
	my ($folders,$a,$b) = @_;
	my $wp_a = $folders->{$a};
	my $wp_b = $folders->{$b};
	my $name_a = $wp_a->{name};
	my $name_b = $wp_b->{name};
	return lc($name_a) cmp lc($name_b);
}


sub kml_section
	# builds the two outer section folders Groups and Routes
{
	my ($class) = @_;				# the class is the style used for self and children
	my $hash_name = $class.'s';			# $what is the key into the navqry hashes
	my $section_name = CapFirst($hash_name);		# name of the outer folder
	my $folders = $wp_mgr->{$hash_name};	# items in inner folder (groups or routes with uuids[])
	my $all_waypoints = $wp_mgr->{waypoints};
	display($dbg_kml,0,"kml_section($class)");

	# build fake My Waypoints group

	if ($class eq 'group')
	{
		my %in_group;
		my $fake_uuid = '1234567812345678';
		delete $folders->{$fake_uuid};
		for my $folder_uuid (keys %$folders)
		{
			my $folder = $folders->{$folder_uuid};
			for my $wp_uuid (@{$folder->{uuids}})
			{
				display($dbg_kml+1,1,"found waypoint($wp_uuid) in group($folder->{name}");
				$in_group{$wp_uuid} = 1;
			}
		}

		my @my_waypoints;
		for my $wp_uuid (sort { cmpByName($all_waypoints,$a,$b) } keys %$all_waypoints)
		{
			my $wp = $all_waypoints->{$wp_uuid};
			display($dbg_kml+1,1,"checking waypoint($wp_uuid) $wp->{name}");
			if (!$in_group{$wp_uuid})
			{
				display($dbg_kml,2,"adding waypoint($wp_uuid) $wp->{name} to _My Waypoints");
				push @my_waypoints,$wp_uuid
			}
		}

		if (@my_waypoints)
		{
			my $fake_group = shared_clone({
				name=>'_My Waypoints',
				uuids=> shared_clone(\@my_waypoints),
				color => $ROUTE_COLOR_BLACK });
			$folders->{$fake_uuid} = $fake_group;
		}
	}

	return '' if !keys %$folders;

	# build the kml

	my $kml = kml_start_folder('sectionStyle', "section_$section_name", $section_name);
	for my $folder_uuid (sort { cmpByName($folders,$a,$b) } keys %$folders)
	{
		my $folder = $folders->{$folder_uuid};
		my $folder_name = $folder->{name};
		my $style = $class eq 'group' ?
			'groupStyle' :
			"routeStyle$folder->{color}";

		$kml .= kml_start_folder($style, $class."_".$folder_uuid, $folder_name);

		my $wp_uuids = $folder->{uuids};

		$kml .= kml_route_string('route',$folder->{color},"$folder_name Route",$wp_uuids)
			if $class eq 'route';

		display($dbg_kml,1,"generating ".scalar(@$wp_uuids)." waypoints in $folder_name");
		for my $wp_uuid (sort { cmpByName($all_waypoints,$a,$b) } @$wp_uuids)
		{
			my $wp = $all_waypoints->{$wp_uuid};

			# The id is set uniquely for Route waypoints with $folder-uuid, but
			# to just the waypoint uuid (the same) for waypoints within different Groups.
			# This gives a modicum of control over the visibility
			# of Group waypoints within GE, which remembers visibility
			# by $id, when moving waypoints between Groups.
			
			# my $id = $wp->{name};
			my $id = $class eq 'group' ?
				$class.'_'.$wp_uuid :
				$class.'_'.$folder_name.'_'.$wp_uuid;

			$kml .= kml_waypoint($style,$id, $wp);
		}
		$kml .= kml_end_folder();
	}
	$kml .= kml_end_folder();
	return $kml;

}


sub kml_tracks
{
	my $tracks = $track_mgr->{tracks};
	my $num_tracks = keys %$tracks;
	display($dbg_kml,0,"kml_tracks() num_tracks=$num_tracks");

	my $kml = kml_start_folder('sectionStyle', "section_Tracks", 'Tracks');
	for my $uuid (sort { cmpByName($tracks,$a,$b) } keys %$tracks)
	{
		my $track = $tracks->{$uuid};
		my $name = $track->{name};
		my $color = $track->{color};
		my $points = $track->{points};

		$kml .= kml_line_string('track',$color,$name,$points);
	}
	$kml .= kml_end_folder();
	return $kml;
}


#------------------------------------------------------------------
# buildNavQueryKML
#------------------------------------------------------------------

my $test_version:shared = 100;

sub kml_RAYSYS
{
	my ($params) = @_;
	my $param_version = $params->{version};
	$param_version ||= 0;

	# the global local version is a tcpBase static variable

	my $local_version = tcpBase::getVersion();
	my $changed = $server_version == $local_version ? 0 : 1;
	my $update = !$changed && $param_version == $server_version ? 1 : 0;

	display($dbg_kml,1,"kml_RAYSYS($param_version,$server_version,$local_version) changed($changed) update($update)");

	if (!$wp_mgr && !$track_mgr)
	{
		if (-f $server_cache_filename)
		{
			warning($dbg_kml-1,0,"wpmgr not running; returning $server_cache_filename");
			return getTextFile($server_cache_filename);
		}
		error("No wpmgr or track_mgr objects in kml_RAYSYS");
		return '';
	}


	# Otherwise, create kml from $wp_mgr and $track_mgr hashes
	
	my $kml = kml_header($update,$local_version);

	if ($changed)
	{
		$server_version = $local_version;

		my $inner_kml = kml_global_styles();
		if ($wp_mgr && keys %{$wp_mgr->{waypoints}})
		{
			$inner_kml .= kml_section('group');
			$inner_kml .= kml_section('route');
		}
		if ($track_mgr && keys %{$track_mgr->{tracks}})
		{
			$inner_kml .= kml_tracks();
		}
		
		$server_kml = $inner_kml;
		$kml .= $inner_kml;
	}
	elsif (!$update)
	{
		$kml .= $server_kml;
	}
	
	$kml .= kml_footer($update);
	
	printVarToFile(1,$server_cache_filename,$kml, 1)
		if $changed && $server_cache_filename;

	return $kml;
}


#-------------------------------------
# shark support
#-------------------------------------

sub showThings
{
	my ($is_wpmgr,$what) = @_;
	my $hash = $is_wpmgr ? $wp_mgr->{$what} : $track_mgr->{$what};
	my @uuids = keys %$hash;
	@uuids = sort { cmpByName($hash,$a,$b) } @uuids;

	print "-------------------------------------------------------------\n";
	print uc($what)."(".scalar(@uuids).")\n";
	print "-------------------------------------------------------------\n";
	for my $uuid (@uuids)
	{
		my $thing = $hash->{$uuid};
		print "    $uuid ".$thing->{name}."\n";
	}
}




sub showLocalDatabase
{
	showThings(1,'waypoints');
	showThings(1,'routes');
	showThings(1,'groups');
	showThings(0,'tracks');
}


1;
