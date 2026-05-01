#-----------------------------------------------------
# h_server.pm
#-----------------------------------------------------
# Base HTTP server class for raymarine apps.
# Extends Pub::HTTP::ServerBase; each app subclasses this.
#
# Shared endpoints (available to all apps):
#   /test            - sanity check
#   /raysys.kml      - E80 WGRT state as Google Earth KML
#   /api/db          - WPMGR + TRACK in-memory state as JSON
#   /api/log         - console ring buffer (?tail=N or ?since=seq or ?since=mark)
#   /api/command     - dispatch a NET-layer command (?cmd=...)
#   /api/item        - WPMGR item ops via JSON POST body (op, uuid, name, ...)
#
# Shared command dispatch (handleCommand virtual method):
#   wakeup           - wake up E80
#   db               - showLocalDatabase to ring buffer
#   kml              - dump current KML to ring buffer
#   t <args>         - TRACK trackUICommand
#   q                - WPMGR queryWaypoints
#   new              - WPMGR create waypoint|route|group by name+uuid
#   delete           - WPMGR delete waypoint|route|group by name
#   find             - WPMGR look up UUID by type+name
#   routewp          - WPMGR add/remove waypoint from route by name
#   mon_<wp|route|group|track> [in|out] <hex> - set monitor bits
#   ?|help           - list all commands and parameters
#
# Subclasses override handleCommand to add app-specific commands,
# calling SUPER::handleCommand for anything not handled.

package apps::raymarine::NET::h_server;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time);
use JSON::PP qw(encode_json decode_json);
use Pub::Utils;
use Pub::ServerUtils;
use Pub::HTTP::ServerBase;
use Pub::HTTP::Response qw(http_ok http_error);
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_mon;
use apps::raymarine::NET::a_utils;
use apps::raymarine::NET::b_sock;
use apps::raymarine::NET::c_RAYDP;
use base qw(Pub::HTTP::ServerBase);


my $dbg     = 0;
my $dbg_kml = 1;

my $SERVER_PORT = 9882;
my $NETWORK_LINK = "http://localhost:$SERVER_PORT/raysys.kml";

my $server_version        :shared = -1;
my $server_kml            :shared = '';
my $server_cache_filename          = "$temp_dir/server_cache.kml";
my $mark_seq              :shared = 0;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		kml_RAYSYS
		showLocalDatabase
	);
}


Pub::ServerUtils::initServerUtils(0,'');


#-----------------------------------------
# handle_request
#-----------------------------------------

sub handle_request
{
	my ($this, $client, $request) = @_;
	my $uri = $request->{uri} || '';

	display($dbg,0,"request method=$request->{method} uri=$uri")
		if ($uri ne '/raysys.kml');

	if ($uri eq '/test')
	{
		return http_ok($request,'this is a test');
	}
	elsif ($uri eq '/raysys.kml')
	{
		my $kml = kml_RAYSYS($request->{params});
		if ($kml)
		{
			my $response = http_ok($request,$kml);
			$response->{headers}{'content-type'} = 'application/vnd.google-earth.kml+xml';
			return $response;
		}
		return http_error($request,"No kml was created");
	}
	elsif ($uri eq '/api/db')      { return $this->api_db($request)      }
	elsif ($uri eq '/api/log')     { return $this->api_log($request)     }
	elsif ($uri eq '/api/command') { return $this->api_command($request) }
	elsif ($uri eq '/api/item')    { return $this->api_item($request)    }

	return $this->SUPER::handle_request($client,$request);
}


#==================================================================================
# /api/* shared endpoints
#==================================================================================

sub api_json_response
{
	my ($this, $request, $data) = @_;
	my $json     = encode_json($data);
	my $response = http_ok($request,$json);
	$response->{headers}{'content-type'} = 'application/json';
	return $response;
}


sub api_db
	# GET /api/db — WPMGR + TRACK in-memory state as JSON.
{
	my ($this, $request) = @_;
	my $wp_mgr    = $raydp->findImplementedService('WPMGR',1);
	my $track_mgr = $raydp->findImplementedService('TRACK',1);
	my $data = {
		version   => apps::raymarine::NET::b_sock::getVersion(),
		waypoints => $wp_mgr    ? $wp_mgr->{waypoints}    : {},
		routes    => $wp_mgr    ? $wp_mgr->{routes}       : {},
		groups    => $wp_mgr    ? $wp_mgr->{groups}       : {},
		tracks    => $track_mgr ? $track_mgr->{tracks}    : {},
		logfile   => $logfile || '',
	};
	return $this->api_json_response($request,$data);
}


sub api_log
	# GET /api/log?tail=N    — last N ring-buffer entries (default 200)
	# GET /api/log?since=seq — entries with seq > seq
{
	my ($this, $request) = @_;
	my $params = $request->{params} || {};
	my ($cur_seq, $entries, $overflow);
	if (defined $params->{since})
	{
		my $since = $params->{since} eq 'mark' ? $mark_seq : int($params->{since});
		($cur_seq,$entries,$overflow) = getOutputRingSince($since);
	}
	else
	{
		my $tail = defined($params->{tail}) ? int($params->{tail}) : 2000;
		($cur_seq,$entries,$overflow) = getOutputRingTail($tail);
	}
	return $this->api_json_response($request,{
		seq      => $cur_seq,
		overflow => $overflow,
		lines    => $entries,
	});
}


sub api_command
	# GET /api/command?cmd=<command>
	# Dispatches through handleCommand; poll /api/log for output.
{
	my ($this, $request) = @_;
	my $params = $request->{params} || {};
	my $cmd    = $params->{cmd} || '';
	my $ok     = 0;
	if ($cmd)
	{
		my ($lpart,$rpart) = split(/\s+/,$cmd,2);
		$rpart //= '';
		$this->handleCommand($lpart,$rpart);
		$ok = 1;
	}
	return $this->api_json_response($request,{ok => $ok, cmd => $cmd});
}


sub api_item
	# POST /api/item  Content-Type: application/json
	# Atomic WPMGR item create/delete, bypassing the text command chain.
	# Body fields: op, uuid, name, and op-specific extras:
	#   new_wp    — lat, lon, sym(opt), depth(opt), comment(opt)
	#   new_route — waypoints (arrayref of wp UUIDs), color(opt), comment(opt)
	#   new_group — members (arrayref of wp UUIDs), comment(opt)
	#   del_wp | del_route | del_group — uuid only
{
	my ($this, $request) = @_;
	my $h = $request->getPostJSON();
	return $this->api_json_response($request,{error => 'missing or invalid JSON body'}) if !$h;

	my $op   = $h->{op}   // '';
	my $uuid = $h->{uuid} // '';
	my $name = $h->{name} // '';

	my $wpmgr = $raydp->findImplementedService('WPMGR');
	return $this->api_json_response($request,{error => 'WPMGR not available'}) if !$wpmgr;

	if ($op eq 'new_wp')
	{
		return $this->api_json_response($request,{error => 'new_wp requires uuid, name, lat, lon'})
			if !($uuid && $name && defined($h->{lat}) && defined($h->{lon}));
		$wpmgr->createWaypoint({
			uuid    => $uuid,
			name    => $name,
			lat     => $h->{lat} + 0,
			lon     => $h->{lon} + 0,
			sym     => ($h->{sym}     // 25) + 0,
			depth   => ($h->{depth}   // 0)  + 0,
			comment => $h->{comment}  // '',
		});
	}
	elsif ($op eq 'new_route')
	{
		return $this->api_json_response($request,{error => 'new_route requires uuid and name'})
			if !($uuid && $name);
		$wpmgr->createRoute({
			uuid      => $uuid,
			name      => $name,
			comment   => $h->{comment}   // '',
			color     => ($h->{color}    // 0) + 0,
			waypoints => $h->{waypoints} // shared_clone([]),
		});
	}
	elsif ($op eq 'new_group')
	{
		return $this->api_json_response($request,{error => 'new_group requires uuid and name'})
			if !($uuid && $name);
		$wpmgr->createGroup({
			uuid    => $uuid,
			name    => $name,
			comment => $h->{comment} // '',
			members => $h->{members} // shared_clone([]),
		});
	}
	elsif ($op eq 'del_wp')
	{
		return $this->api_json_response($request,{error => 'del_wp requires uuid'}) if !$uuid;
		my $wp = $wpmgr->{waypoints}{$uuid};
		return $this->api_json_response($request,{error => "del_wp: uuid($uuid) not in memory"}) if !$wp;
		$wpmgr->deleteWaypoint($uuid);
	}
	elsif ($op eq 'del_route')
	{
		return $this->api_json_response($request,{error => 'del_route requires uuid'}) if !$uuid;
		my $rt = $wpmgr->{routes}{$uuid};
		return $this->api_json_response($request,{error => "del_route: uuid($uuid) not in memory"}) if !$rt;
		$wpmgr->deleteRoute($uuid);
	}
	elsif ($op eq 'del_group')
	{
		return $this->api_json_response($request,{error => 'del_group requires uuid'}) if !$uuid;
		my $grp = $wpmgr->{groups}{$uuid};
		return $this->api_json_response($request,{error => "del_group: uuid($uuid) not in memory"}) if !$grp;
		$wpmgr->deleteGroup($uuid);
	}
	else
	{
		return $this->api_json_response($request,{error => "unknown op '$op'"});
	}

	return $this->api_json_response($request,{ok => 1, op => $op, uuid => $uuid});
}


#==================================================================================
# handleCommand — NET-layer command dispatch (virtual; subclasses extend)
#==================================================================================

sub handleCommand
{
	my ($this, $lpart, $rpart) = @_;

	# WAKEUP

	if ($lpart eq 'wakeup')
	{
		apps::raymarine::NET::b_sock::wakeup_e80();
	}

	# E80 in-memory state

	elsif ($lpart eq 'db')
	{
		showLocalDatabase();
	}
	elsif ($lpart eq 'kml')
	{
		my $kml = kml_RAYSYS();
		c_print("\n------------------------------------------------------\n");
		c_print("RAYSYS kml\n");
		c_print("\n------------------------------------------------------\n");
		c_print("$kml\n");
	}

	# TRACK

	elsif ($lpart eq 't')
	{
		my $track = $raydp->findImplementedService('TRACK');
		return if !$track;
		$track->trackUICommand($rpart);
	}
	elsif ($lpart eq 't_uuid')
	{
		my $track = $raydp->findImplementedService('TRACK');
		return if !$track;
		my ($uuid, @rest) = split(/\s+/, $rpart);
		my $op = join(' ', @rest);
		return error("t_uuid: usage: t_uuid <uuid> <erase|mta|rename <new_name>>")
			if !($uuid && $op);
		$track->queueTRACKCommand(
			$apps::raymarine::NET::d_TRACK::API_GENERAL_CMD,
			$uuid, $op);
	}

	# WPMGR

	elsif ($lpart =~ /^(q|new|delete|find|routewp|clear_e80)$/)
	{
		my $wpmgr = $raydp->findImplementedService('WPMGR');
		return if !$wpmgr;

		if ($lpart eq 'q')
		{
			$wpmgr->queryWaypoints();
		}
		elsif ($lpart eq 'new')
		{
			my ($what,$name,$uuid,@rest) = split(/\s+/,$rpart);
			$what = lc($what) if $what;
			if (!$what || !$name || !$uuid)
			{
				error("usage: new <wp|group|route> <name> <uuid> [params]");
			}
			elsif ($what eq 'wp')
			{
				my ($lat,$lon,$sym) = @rest;
				return error("new wp requires lat and lon") if !defined($lat) || !defined($lon);
				my %h = (name => $name, uuid => $uuid, lat => $lat+0, lon => $lon+0);
				$h{sym} = $sym+0 if defined $sym;
				$wpmgr->createWaypoint(\%h);
			}
			elsif ($what eq 'group')
			{
				$wpmgr->createGroup({name => $name, uuid => $uuid});
			}
			elsif ($what eq 'route')
			{
				my ($color) = @rest;
				my %h = (name => $name, uuid => $uuid);
				$h{color} = $color+0 if defined $color;
				$wpmgr->createRoute(\%h);
			}
			else
			{
				error("new: unknown type '$what'");
			}
		}
		elsif ($lpart eq 'delete')
		{
			my ($what,@rest) = split(/\s+/,$rpart);
			my $name = join(' ',@rest);
			$what    = lc($what // '');
			my $full = $what eq 'wp' ? 'waypoint' : $what;
			my $uuid = $wpmgr->findUUIDByName($full,$name);
			return error("delete: $full '$name' not found") if !$uuid;
			$wpmgr->deleteWaypoint($uuid) if $what eq 'wp';
			$wpmgr->deleteRoute($uuid)    if $what eq 'route';
			$wpmgr->deleteGroup($uuid)    if $what eq 'group';
			error("delete: unknown type '$what'") if ($what !~ /^(wp|route|group)$/);
		}
		elsif ($lpart eq 'clear_e80')
		{
			my $nr = scalar keys %{$wpmgr->{routes}    // {}};
			my $ng = scalar keys %{$wpmgr->{groups}    // {}};
			my $nw = scalar keys %{$wpmgr->{waypoints} // {}};
			my $total = $nr + $ng + $nw;
			c_print("clear_e80: submitting $total delete ops\n");
			$wpmgr->deleteRoute($_,    undef)    for keys %{$wpmgr->{routes}    // {}};
			$wpmgr->deleteGroup($_,    undef)    for keys %{$wpmgr->{groups}    // {}};
			$wpmgr->deleteWaypoint($_, undef, 1) for keys %{$wpmgr->{waypoints} // {}};
		}
		elsif ($lpart eq 'find')
		{
			my ($what,@rest) = split(/\s+/,$rpart);
			my $name = join(' ',@rest);
			$what    = lc($what // '');
			my $full = $what eq 'wp' ? 'waypoint' : $what;
			my $uuid = $wpmgr->findUUIDByName($full,$name);
			$uuid
				? c_print("$full '$name' => $uuid\n")
				: c_print("$full '$name' not found\n");
		}
		elsif ($lpart eq 'routewp')
		{
			my ($route_name,$op,$wp_name) = split(/\s+/,$rpart,3);
			$op //= '';
			if (!($route_name && ($op eq '+' || $op eq '-') && $wp_name))
			{
				error("usage: routewp <route> <+|-> <wp>");
				return;
			}
			my $route_uuid = $wpmgr->findUUIDByName('route',$route_name);
			my $wp_uuid    = $wpmgr->findUUIDByName('waypoint',$wp_name);
			return error("routewp: route '$route_name' not found")    if !$route_uuid;
			return error("routewp: waypoint '$wp_name' not found")    if !$wp_uuid;
			$wpmgr->routeWaypoint($route_uuid,$wp_uuid,$op eq '+');
		}
	}	# WPMGR

	# MON bits

	elsif ($lpart =~ /^mon_(wp|route|group|track)$/)
	{
		my $what = $1;

		my ($first, $rest) = split(/\s+/, $rpart, 2);
		my ($dir, $val_str);
		if (($first // '') =~ /^(in|out)$/i)
		{
			$dir     = lc($first);
			$val_str = $rest // '';
		}
		else
		{
			$dir     = 'both';
			$val_str = $first // '';
		}

		$val_str =~ s/^\s+|\s+$//g;
		$val_str =~ s/^0x//i;
		if ($val_str !~ /^[0-9a-fA-F]+$/)
		{
			error(0,0,"mon_$what: invalid value '$val_str'");
			return;
		}
		my $val = hex($val_str) | $MON_SRC_SHARK;

		if ($what eq 'track')
		{
			my $tmd = $SHARK_DEFAULTS{$SPORT_TRACK};
			$tmd->{mon_in}  = $val if $dir eq 'both' || $dir eq 'in';
			$tmd->{mon_out} = $val if $dir eq 'both' || $dir eq 'out';
			my $track = $raydp->findImplementedService('TRACK', 1);
			warning(0,0,"mon_track: TRACK not connected") if !$track;
			c_print("mon_track dir($dir) = 0x".sprintf('%x', $val & ~$MON_SRC_SHARK)."\n");
		}
		else
		{
			my $idx = $what eq 'wp'    ? $MON_WHAT_WAYPOINT :
			          $what eq 'route' ? $MON_WHAT_ROUTE    :
			                             $MON_WHAT_GROUP;
			my $wmd = $SHARK_DEFAULTS{$SPORT_WPMGR};
			$wmd->{mon_ins}[$idx]  = $val if $dir eq 'both' || $dir eq 'in';
			$wmd->{mon_outs}[$idx] = $val if $dir eq 'both' || $dir eq 'out';
			my $wpmgr = $raydp->findImplementedService('WPMGR', 1);
			warning(0,0,"mon_$what: WPMGR not connected") if !$wpmgr;
			c_print("mon_$what dir($dir) = 0x".sprintf('%x', $val & ~$MON_SRC_SHARK)."\n");
		}
	}

	# b_sock command timeout (runtime settable for diagnostics)

	elsif ($lpart eq 'timeout')
	{
		if ($rpart =~ /^\d+$/)
		{
			$apps::raymarine::NET::b_sock::command_timeout = $rpart + 0;
			display(0,0,"b_sock::command_timeout set to $apps::raymarine::NET::b_sock::command_timeout");
		}
		else
		{
			display(0,0,"b_sock::command_timeout = $apps::raymarine::NET::b_sock::command_timeout");
		}
	}

	# Mark — snapshot current ring-buffer seq for ?since=mark queries

	elsif ($lpart eq 'mark')
	{
		display(0,0,"------------------------------ MARK" . ($rpart ? ": $rpart" : '') . " ------------------------------");
		$mark_seq = getOutputRingSeq();
	}

	# Help

	elsif ($lpart eq '?' || $lpart eq 'help')
	{
		my $entries = $this->commandHelp();
		my $max_sig = 0;
		for my $e (@$entries)
		{
			my $len = length($e->[0]);
			$max_sig = $len if $len > $max_sig;
		}
		c_print("Commands:\n");
		for my $e (@$entries)
		{
			c_print(sprintf("  %-*s  %s\n", $max_sig, $e->[0], $e->[1]));
		}
	}

}


#==================================================================================
# commandHelp — [signature, description] pairs for ?/help command
#==================================================================================

sub commandHelp
{
	my ($this) = @_;
	return [
		[ 'wakeup',                                   'wake up E80'                           ],
		[ 'db',                                       'show E80 in-memory database'           ],
		[ 'kml',                                      'dump RAYSYS KML to console'            ],
		[ 't <args>',                                 'TRACK general command by name'         ],
		[ 't_uuid <uuid> <erase|mta|rename <name>>', 'TRACK general command by UUID'          ],
		[ 'q',                                        'WPMGR query waypoints'                 ],
		[ 'new <wp|group|route> <name> <uuid> [...]', 'create object on E80'                  ],
		[ 'delete <wp|route|group> <name>',           'delete object from E80 by name'        ],
		[ 'find <wp|route|group> <name>',             'look up UUID by type+name'             ],
		[ 'routewp <route> <+|-> <wp>',               'add/remove waypoint from route'        ],
		[ 'clear_e80',                                'delete all E80 waypoints/routes/groups'],
		[ 'mon_<wp|route|group|track> [in|out] <hex>', 'set monitor bits'                      ],
		[ 'timeout [N]',                               'get/set b_sock command timeout (seconds)'],
		[ '?|help',                                   'show this help'                        ],
	];
}


#==================================================================================
# showLocalDatabase / showThings
#==================================================================================

sub showThings
{
	my ($service, $what) = @_;
	my $hash  = $service ? $service->{$what} : {};
	my @uuids = sort { cmpByName($hash,$a,$b) } keys %$hash;

	c_print("-------------------------------------------------------------\n");
	c_print(uc($what)."(".scalar(@uuids).")\n");
	c_print("-------------------------------------------------------------\n");
	for my $uuid (@uuids)
	{
		my $thing = $hash->{$uuid};
		if ($what eq 'waypoints')
		{
			my $lat = sprintf('%9.4f', ($thing->{lat} || 0) / $SCALE_LATLON);
			my $lon = sprintf('%10.4f', ($thing->{lon} || 0) / $SCALE_LATLON);
			c_print("    $uuid  $lat  $lon  $thing->{name}\n");
		}
		elsif ($what eq 'routes')
		{
			my $nwps = $thing->{uuids} ? scalar(@{$thing->{uuids}}) : 0;
			c_print("    $uuid  wps($nwps)  $thing->{name}\n");
		}
		elsif ($what eq 'groups')
		{
			my $nwps = $thing->{uuids} ? scalar(@{$thing->{uuids}}) : 0;
			c_print("    $uuid  wps($nwps)  $thing->{name}\n");
		}
		else
		{
			c_print("    $uuid $thing->{name}\n");
			if ($what eq 'tracks')
			{
				my $points  = $thing->{points};
				my $num_pts = $points ? scalar @$points : 0;
				my $cnt     = $thing->{cnt1} || 0;
				c_print("        num_points($num_pts)  expected($cnt)\n");
			}
		}
	}
}


sub showLocalDatabase
{
	my $wp_mgr    = $raydp->findImplementedService('WPMGR',1);
	my $track_mgr = $raydp->findImplementedService('TRACK',1);
	showThings($wp_mgr,'waypoints');
	showThings($wp_mgr,'routes');
	showThings($wp_mgr,'groups');
	showThings($track_mgr,'tracks');
}


#==================================================================================
# KML
#==================================================================================

my $EOL = "\r\n";

my $abgr_color_white      = 'ffffffff';
my $abgr_color_blue       = 'ffff0000';
my $abgr_color_green      = 'ff00ff00';
my $abgr_color_red        = 'ff0000ff';
my $abgr_color_cyan       = 'ffffff00';
my $abgr_color_yellow     = 'ff00ffff';
my $abgr_color_magenta    = 'ffff00ff';
my $abgr_color_dark_green = 'ff008800';

my @line_colors = (
	$abgr_color_red,
	$abgr_color_yellow,
	$abgr_color_green,
	$abgr_color_blue,
	$abgr_color_magenta,
	$abgr_color_white );

my $ROUTE_WIDTH = 4;
my $TRACK_WIDTH = 2;

my $boat_icon        = "http://localhost:$SERVER_PORT/boat_icon.png";
my $circle_icon      = 'http://maps.google.com/mapfiles/kml/shapes/placemark_circle.png';
my $square_icon      = 'http://maps.google.com/mapfiles/kml/shapes/placemark_square.png';
my $circle2_icon     = 'http://maps.google.com/mapfiles/kml/shapes/donut.png';


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
	}
	return $kml;
}


sub kml_footer
{
	my ($update) = @_;
	my $kml = '';
	$kml .= "</Update>$EOL</NetworkLinkControl>$EOL" if $update;
	$kml .= "</Document>$EOL"                        if !$update;
	$kml .= "</kml>$EOL";
	return $kml;
}


sub kml_start_folder
{
	my ($style,$id,$name) = @_;
	display($dbg_kml,0,"kml_start_folder($style,$name)");
	my $kml = "<Folder id=\"$id\">$EOL";
	$kml .= "<name>$name</name>";
	$kml .= "<styleUrl>$style</styleUrl>$EOL";
	$kml .= "<open>1</open>$EOL";
	return $kml;
}


sub kml_end_folder { return "</Folder>$EOL" }


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
	for (my $i = 0; $i < $NUM_ROUTE_COLORS; $i++)
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


sub kml_line_string
{
	my ($what,$color,$name,$points) = @_;
	my $num_points = $points ? scalar @$points : 0;
	display($dbg_kml,0,"kml_line_string($what,$color,$name) num_pts=$num_points");
	my $coord_str = '';
	if ($num_points)
	{
		for my $point (@$points)
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


sub kml_route_string
{
	my ($wp_mgr,$what,$color,$name,$waypoints) = @_;
	my @points;
	for my $uuid (@$waypoints)
	{
		push @points, $wp_mgr->{waypoints}{$uuid};
	}
	return kml_line_string($what,$color,$name,\@points);
}


sub kml_waypoint
{
	my ($style,$id,$wp) = @_;
	display($dbg_kml,0,"kml_waypoint($style,$wp->{name})");
	my $lat = $wp->{lat} / $SCALE_LATLON;
	my $lon = $wp->{lon} / $SCALE_LATLON;
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
	return lc($folders->{$a}{name}) cmp lc($folders->{$b}{name});
}


sub kml_section
{
	my ($wp_mgr,$class) = @_;
	my $hash_name     = $class.'s';
	my $section_name  = CapFirst($hash_name);
	my $folders       = $wp_mgr->{$hash_name};
	my $all_waypoints = $wp_mgr->{waypoints};
	display($dbg_kml,0,"kml_section($class)");

	if ($class eq 'group')
	{
		my %in_group;
		my $fake_uuid = '1234567812345678';
		delete $folders->{$fake_uuid};
		for my $folder_uuid (keys %$folders)
		{
			$in_group{$_} = 1 for @{$folders->{$folder_uuid}{uuids}};
		}
		my @my_wps = grep { !$in_group{$_} }
		             sort { cmpByName($all_waypoints,$a,$b) } keys %$all_waypoints;
		if (@my_wps)
		{
			$folders->{$fake_uuid} = shared_clone({
				name  => '_My Waypoints',
				uuids => shared_clone(\@my_wps),
				color => $ROUTE_COLOR_BLACK });
		}
	}

	return '' if !keys(%$folders);

	my $kml = kml_start_folder('sectionStyle',"section_$section_name",$section_name);
	for my $folder_uuid (sort { cmpByName($folders,$a,$b) } keys %$folders)
	{
		my $folder      = $folders->{$folder_uuid};
		my $folder_name = $folder->{name};
		my $style       = $class eq 'group' ? 'groupStyle' : "routeStyle$folder->{color}";

		$kml .= kml_start_folder($style,$class.'_'.$folder_uuid,$folder_name);
		$kml .= kml_route_string($wp_mgr,'route',$folder->{color},"$folder_name Route",$folder->{uuids})
			if $class eq 'route';

		for my $wp_uuid (sort { cmpByName($all_waypoints,$a,$b) } @{$folder->{uuids}})
		{
			my $id = $class eq 'group'
				? $class.'_'.$wp_uuid
				: $class.'_'.$folder_name.'_'.$wp_uuid;
			$kml .= kml_waypoint($style,$id,$all_waypoints->{$wp_uuid});
		}
		$kml .= kml_end_folder();
	}
	$kml .= kml_end_folder();
	return $kml;
}


sub kml_tracks
{
	my ($track_mgr) = @_;
	my $tracks    = $track_mgr->{tracks};
	my $num_tracks = keys %$tracks;
	display($dbg_kml,0,"kml_tracks() num_tracks=$num_tracks");

	my $kml = kml_start_folder('sectionStyle','section_Tracks','Tracks');
	for my $uuid (sort { cmpByName($tracks,$a,$b) } keys %$tracks)
	{
		my $track = $tracks->{$uuid};
		$kml .= kml_line_string('track',$track->{color},$track->{name},$track->{points});
	}
	$kml .= kml_end_folder();
	return $kml;
}


sub kml_RAYSYS
{
	my ($params) = @_;
	my $param_version = ($params && $params->{version}) ? $params->{version} : 0;

	my $wp_mgr    = $raydp->findImplementedService('WPMGR',1);
	my $track_mgr = $raydp->findImplementedService('TRACK',1);

	my $local_version = apps::raymarine::NET::b_sock::getVersion();
	my $changed = $server_version == $local_version ? 0 : 1;
	my $update  = !$changed && $param_version == $server_version ? 1 : 0;

	display($dbg_kml,1,"kml_RAYSYS($param_version,$server_version,$local_version) changed($changed) update($update)");

	my $kml = kml_header($update,$local_version);

	if ($changed)
	{
		$server_version = $local_version;
		my $inner_kml   = kml_global_styles();
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
		$kml       .= $inner_kml;
	}
	elsif (!$update)
	{
		$kml .= $server_kml;
	}

	$kml .= kml_footer($update);

	printVarToFile(1,$server_cache_filename,$kml,1)
		if $changed && $server_cache_filename;

	return $kml;
}


1;
