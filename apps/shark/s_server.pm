#-----------------------------------------------------
# s_server.pm
#-----------------------------------------------------
# Shark-specific HTTP server.
# Serves WPMGR/TRACK state to Google Earth via /raysys.kml
# and exposes /api/* endpoints for collaborative testing.
#
# /api/db        - full WPMGR+TRACK in-memory state as JSON
# /api/command   - execute a shark console command (?cmd=create+wp+3)
# /api/log       - in-memory console ring buffer (?tail=N or ?since=seq)
# /api/colormap  - current per-service color assignments from SHARK_DEFAULTS


package s_server;
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
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_mon;
use apps::raymarine::NET::a_utils;
use apps::raymarine::NET::c_RAYDP;
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
my $SRC_DIR = "/base/apps/raymarine/apps/shark";
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
# startHTTPServer
#-----------------------

sub startHTTPServer
{
	display($dbg,0,"starting s_server");
	$logfile = "$temp_dir/shark_api.log" if !$logfile;
	$ray_server = s_server->new();
	$ray_server->start();
	display($dbg,0,"finished starting s_server");
}


sub new
{
    my ($class) = @_;

	my $no_cache =  shared_clone({
		'cache-control' => 'max-age: 603200',
	});

	my $params = {

		HTTP_DEBUG_SERVER => -1,
		HTTP_DEBUG_REQUEST => 0,
		HTTP_DEBUG_RESPONSE => 0,
		HTTP_DEBUG_QUIET_RE => 'raysys\.kml|/api/',

		HTTP_MAX_THREADS => 5,
		HTTP_KEEP_ALIVE => 0,

		HTTP_PORT => $SERVER_PORT,

		HTTP_DOCUMENT_ROOT => "$SRC_DIR/site",
        HTTP_GET_EXT_RE => 'html|js|css|jpg|png|ico',

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

	my $uri = $request->{uri} || '';
	my $param_text = ($uri =~ s/\?(.*)$//) ? $1 : '';
	my $get_params = $request->{params};

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
	# /api/* endpoints
	#------------------------------------------

	elsif ($uri eq '/api/db')
	{
		$response = $this->api_db($request,$get_params);
	}
	elsif ($uri eq '/api/command')
	{
		$response = $this->api_command($request,$get_params);
	}
	elsif ($uri eq '/api/log')
	{
		$response = $this->api_log($request,$get_params);
	}
	elsif ($uri eq '/api/colormap')
	{
		$response = $this->api_colormap($request,$get_params);
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
# /api/* implementation
#==================================================================================

sub api_json_response
{
	my ($this,$request,$data) = @_;
	my $json = my_encode_json($data);
	my $response = http_ok($request,$json);
	$response->{headers}->{'content-type'} = 'application/json';
	return $response;
}


sub api_db
	# GET /api/db
	# Returns current WPMGR + TRACK in-memory state as JSON.
	# Includes logfile path so caller can tail it directly.
{
	my ($this,$request,$params) = @_;
	my $wp_mgr    = $raydp->findImplementedService('WPMGR',1);
	my $track_mgr = $raydp->findImplementedService('TRACK',1);
	my $data = {
		version   => apps::raymarine::NET::b_sock::getVersion(),
		waypoints => $wp_mgr    ? $wp_mgr->{waypoints} : {},
		routes    => $wp_mgr    ? $wp_mgr->{routes}    : {},
		groups    => $wp_mgr    ? $wp_mgr->{groups}    : {},
		tracks    => $track_mgr ? $track_mgr->{tracks} : {},
		logfile   => $logfile || '',
	};
	return $this->api_json_response($request,$data);
}


sub api_command
	# GET /api/command?cmd=<console_command>
	# Executes a shark console command via the existing handleSerialCommand()
	# dispatch.  Commands are queued to service threads; response is an ack.
	# Poll /api/log after a short delay to see output.
	# Examples: ?cmd=q  ?cmd=create+wp+3  ?cmd=delete+wp+testWaypoint3
{
	my ($this,$request,$params) = @_;
	my $cmd = $params->{cmd} || '';
	my $ok  = 0;
	if ($cmd)
	{
		my ($lpart,$rpart) = split(/\s+/,$cmd,2);
		$rpart ||= '';
		shark::handleSerialCommand($lpart,$rpart);
		$ok = 1;
	}
	return $this->api_json_response($request,{ok => $ok, cmd => $cmd});
}


sub api_log
	# GET /api/log?tail=N    - last N entries from ring buffer (default 200)
	# GET /api/log?since=seq - all entries with seq > seq (for bracketed queries)
	# Response: {seq, overflow, lines:[{seq,color,text},...]}
	# seq is current high-water mark; pass as ?since=seq on next call.
	# overflow is a cumulative count of entries dropped due to buffer full.
{
	my ($this,$request,$params) = @_;
	my ($cur_seq,$entries,$overflow);
	if (defined $params->{since})
	{
		($cur_seq,$entries,$overflow) = getOutputRingSince(int($params->{since}));
	}
	else
	{
		my $tail = defined($params->{tail}) ? int($params->{tail}) : 200;
		($cur_seq,$entries,$overflow) = getOutputRingTail($tail);
	}
	return $this->api_json_response($request,{
		seq      => $cur_seq,
		overflow => $overflow,
		lines    => $entries,
	});
}


sub api_colormap
	# GET /api/colormap
	# Returns current per-service color assignments from SHARK_DEFAULTS.
	# WPMGR has per-type arrays [waypoint, route, group]; others have scalars.
	# Color integers are UTILS_COLOR_* values (0x00-0x0F).
{
	my ($this,$request,$params) = @_;

	my %color_names = (
		0x00 => 'BLACK',        0x01 => 'BLUE',
		0x02 => 'GREEN',        0x03 => 'CYAN',
		0x04 => 'RED',          0x05 => 'MAGENTA',
		0x06 => 'BROWN',        0x07 => 'LIGHT_GRAY',
		0x08 => 'GRAY',         0x09 => 'LIGHT_BLUE',
		0x0A => 'LIGHT_GREEN',  0x0B => 'LIGHT_CYAN',
		0x0C => 'LIGHT_RED',    0x0D => 'LIGHT_MAGENTA',
		0x0E => 'YELLOW',       0x0F => 'WHITE',
	);

	my %map;
	for my $port (sort { $a <=> $b } keys %SHARK_DEFAULTS)
	{
		my $def = $SHARK_DEFAULTS{$port};
		next unless $def->{name};
		my $entry = { name => $def->{name}, port => $port+0 };
		if ($def->{in_colors})
		{
			my @in  = @{$def->{in_colors}};
			my @out = @{$def->{out_colors}};
			$entry->{in_colors}       = \@in;
			$entry->{out_colors}      = \@out;
			$entry->{in_color_names}  = [ map { $color_names{$_} || "color_$_" } @in  ];
			$entry->{out_color_names} = [ map { $color_names{$_} || "color_$_" } @out ];
			$entry->{what_order}      = ['waypoint','route','group'];
		}
		else
		{
			my $ic = ($def->{in_color}  || 0) + 0;
			my $oc = ($def->{out_color} || 0) + 0;
			$entry->{in_color}       = $ic;
			$entry->{out_color}      = $oc;
			$entry->{in_color_name}  = $color_names{$ic} || "color_$ic";
			$entry->{out_color_name} = $color_names{$oc} || "color_$oc";
		}
		$map{$port} = $entry;
	}
	return $this->api_json_response($request,\%map);
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
	$kml .= "<cookie>version=$local_version</cookie>$EOL";
	$kml .= "<linkName>RAYSYS($local_version)</linkName>$EOL";

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
	$kml .= "<open>1</open>$EOL";
	return $kml;
}


sub kml_global_styles
{
	my $kml = '';
    $kml .= '<Style id="groupStyle">'.$EOL;
    $kml .= "<IconStyle>$EOL";
	$kml .= "<color>$abgr_color_cyan</color>$EOL";
    $kml .= "<scale>0.6</scale>$EOL";
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
{
	my ($wp_mgr,$what,$color,$name,$waypoints) = @_;
	my @points;
	foreach my $uuid (@$waypoints)
	{
		my $wp = $wp_mgr->{waypoints}->{$uuid};
		push @points,$wp;
	}
	return kml_line_string($what,$color,$name,\@points);
}


sub kml_line_string
{
	my ($what,$color,$name,$points) = @_;
	my $num_points = $points ? @$points : 0;
	display($dbg_kml,0,"kml_line_string($what,$color,$name) num_pts=$num_points");

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
		$coord_str =~ s/\s+$//;
	}

	my $kml = '';
	$kml .= "<Placemark id=\"$what"."_$name\">$EOL";
	$kml .= "<name>$name</name>$EOL";
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
{
	my ($wp_mgr,$class) = @_;
	my $hash_name = $class.'s';
	my $section_name = CapFirst($hash_name);
	my $folders = $wp_mgr->{$hash_name};
	my $all_waypoints = $wp_mgr->{waypoints};
	display($dbg_kml,0,"kml_section($class)");

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

		$kml .= kml_route_string($wp_mgr,'route',$folder->{color},"$folder_name Route",$wp_uuids)
			if $class eq 'route';

		display($dbg_kml,1,"generating ".scalar(@$wp_uuids)." waypoints in $folder_name");
		for my $wp_uuid (sort { cmpByName($all_waypoints,$a,$b) } @$wp_uuids)
		{
			my $wp = $all_waypoints->{$wp_uuid};

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
	my ($track_mgr) = @_;
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

	my $wp_mgr = $raydp->findImplementedService('WPMGR',1);
	my $track_mgr = $raydp->findImplementedService('TRACK',1);

	my $local_version = apps::raymarine::NET::b_sock::getVersion();
	my $changed = $server_version == $local_version ? 0 : 1;
	my $update = !$changed && $param_version == $server_version ? 1 : 0;

	display($dbg_kml,1,"kml_RAYSYS($param_version,$server_version,$local_version) changed($changed) update($update)");

	my $kml = kml_header($update,$local_version);

	if ($changed)
	{
		$server_version = $local_version;

		my $inner_kml = kml_global_styles();
		if ($wp_mgr && keys %{$wp_mgr->{waypoints}})
		{
			$inner_kml .= kml_section($wp_mgr,'group');
			$inner_kml .= kml_section($wp_mgr,'route');
		}
		if ($track_mgr && keys %{$track_mgr->{tracks}})
		{
			$inner_kml .= kml_tracks($track_mgr);
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
	my ($service,$what) = @_;
	my $hash = $service ? $service->{$what} : {};
	my @uuids = keys %$hash;
	@uuids = sort { cmpByName($hash,$a,$b) } @uuids;

	c_print("-------------------------------------------------------------\n");
	c_print(uc($what)."(".scalar(@uuids).")\n");
	c_print("-------------------------------------------------------------\n");
	for my $uuid (@uuids)
	{
		my $thing = $hash->{$uuid};
		c_print("    $uuid ".$thing->{name}."\n");
		if ($what eq 'tracks')
		{
			my $points = $thing->{points};
			my $num_points = $points ? @$points : 0;
			my $cnt = $thing->{cnt1} || 0;
			c_print("        num_points($num_points)  expected($cnt)\n");
		}
	}
}




sub showLocalDatabase
{
	my $wp_mgr = $raydp->findImplementedService('WPMGR',1);
	my $track_mgr = $raydp->findImplementedService('TRACK',1);
	showThings($wp_mgr,'waypoints');
	showThings($wp_mgr,'routes');
	showThings($wp_mgr,'groups');
	showThings($track_mgr,'tracks');
}


1;
