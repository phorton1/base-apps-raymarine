#---------------------------------------------
# r_NAVQRY.pm
#---------------------------------------------
# Conflict between a completely self contained
# WGR listener, and a tool to explore and learn
# how to do things (i.e. write waypoints).
#
# I think I will first getting working as a self
# contained WGR listener, but only request waypoints,
# and then add a specific control path to test
# writing waypoints.
#
# Note that I made tried to have commands to start and
# stop this client, but it really didn't make sense.
# If I try to close the socket to a running E80, the
# program hangs until I reboot the E80.
#
# So, instead, there is an optional one time command
# to start it, and thereafter, if it fails to send,
# then and only then it closes the socket, waits 10
# seconds, and retries.


package apps::raymarine::NET::r_NAVQRY;
use strict;
use warnings;
use threads;
use threads::shared;
use POSIX qw(floor pow atan);
use Socket;
use IO::Select;
use IO::Handle;
use IO::Socket::INET;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use apps::raymarine::NET::r_utils;
use apps::raymarine::NET::r_RAYDP;

my $dbg = 0;
my $SHOW = 1;


my $NAVQUERY_PORT 			= 9877;

my $COMMAND_TIMEOUT 		= 3;
my $REFRESH_INTERVAL		= 5;
my $RECONNECT_INTERVAL		= 15;


my $STATE_NONE 				= 0;
my $STATE_GET_WP_DICT 		= 1;
my $STATE_PARSE_WP_DICT 	= 2;
my $STATE_GET_WAYPOINTS		= 3;
my $STATE_GET_ROUTE_DICT	= 4;
my $STATE_PARSE_ROUTE_DICT	= 5;
my $STATE_GET_ROUTES		= 6;
my $STATE_GET_GROUP_DICT	= 7;
my $STATE_PARSE_GROUP_DICT	= 8;
my $STATE_GET_GROUPS		= 9;


my $SUCCESS_SIG = '00000400';
my $DICT_END_RECORD_MARKER	= '10000202';


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(
		navQueryThread
		startNavQuery
		refreshNavQuery
		toggleNavQueryAutoRefresh
    );
}


my $one_time_start:shared = 1;
	# set this to 0 to require startNavQuery() to
	# be called to start the thread.
my $refresh_time:shared = 0;
	# time of the last refresh; 0=immediate-ish
my $auto_refresh:shared = 1;
	# set this to 0 to require refreshNavQuery
	# or toggleNavQueryAutoRefres() to be called.
my $refresh_now:shared = 0;



my $waypoints:shared = shared_clone({});
my $routes:shared = shared_clone({});
my $groups:shared = shared_clone({});
my $state:shared = $STATE_NONE;

sub startNavQuery
{
	display(0,0,"startNavQuery()");
	$one_time_start = 1;
}

sub refreshNavQuery
{
	if ($state || !$one_time_start)
	{
		error("illegal attempt to refreshNavQuery: state($state) started($one_time_start)");
		return;
	}
	display(0,0,"refreshNavQuery()");
	$refresh_now = 1;
	$refresh_time = 0;
}

sub toggleNavQueryAutoRefresh
{
	my $auto = $auto_refresh ? 0 : 1;
	display(0,0,"toggleNavQueryAutoRefresh($auto)");
	$refresh_time = time() if $auto && !$state;
	$auto_refresh = $auto;
}





# constant command atoms

my $context 	= '0800'.'{sig_byte}001'.'0f00'.'{seq_num}';
my $set_context = '1400'.'0002'.'0f00'.'{seq_num}'.	'00000000'.'00000000'.'1a000000';
my $set_buffer 	= '3400'.'0102'.'0f00'.'{seq_num}'.	'28000000'.('00000000'x5).'10270000'.('00000000'x4);
my $dictionary 	= '1000'.'0202'.'0f00'.'{seq_num}'.	'00000000'.'00000000';

my $get_dict 	= $context.$set_context.$set_buffer.$dictionary;
my $get_item	= '1000'.'{sig_byte}301'.'0f00'.'{seq_num}'.'{uuid}';

my $sig_dict	= '{sig_byte}0000f00{seq_num}';
my $sig_item	= '{sig_byte}6000f00{seq_num}';




if (0)
{
	my $waypoint_context = '0800'.'0001'.'0f00'.'{seq_num}';
	my $route_context 	 = '0800'.'4001'.'0f00'.'{seq_num}';
	my $group_context 	 = '0800'.'8001'.'0f00'.'{seq_num}';
		# sets the waypoint, route, or group context
		#	'0800'.'1001'.'0f00'.'{seq_num}',	# 6		stops working
		#	'0800'.'2001'.'0f00'.'{seq_num}',	# 7		stops working
		#	'0800'.'0d01'.'0f00'.'{seq_num}',	# 6		unknown example from RNS
		#	'0800'.'8e01'.'0f00'.'{seq_num}',	# 7		unknown example from RNS
	# my $set_buffer 	= '3400'.'0102'.'0f00'.'{seq_num}'.	'28000000'.('00000000'x5).'10270000'.('00000000'x4);
		# appears to 'commit' whatever context command was sent
		# unsure; this may only be needed once per session
		# maybe sets buffers or enables other comms
		# all of these 3400's are equivilant
		# '3400'.'0102'.'0f00'.'{seq_num}'.	'28000000'.('00000000'x5).'96000000'.('00000000'x4), # 10 a
		# '3400'.'0102'.'0f00'.'{seq_num}'.	'28000000'.('00000000'x5).'64000000'.('00000000'x4), # 11 b
		# '3400'.'0102'.'0f00'.'{seq_num}'.	'28000000'.('00000000'x4).'e8550f16'.'64000000'.('00000000'x4), # 12 c
		# '3400'.'0102'.'0f00'.'{seq_num}'.	'28000000'.('00000000'x4).'e8550f16'.'96000000'.('00000000'x4), # 13 d

		# gets the dictionary (uuid list) for the current context
	my $get_waypoints 	= $waypoint_context.$set_context.$set_buffer.$dictionary;
	my $get_routes 		= $route_context.	$set_context.$set_buffer.$dictionary;
	my $get_groups 		= $group_context.	$set_context.$set_buffer.$dictionary;
	my $get_waypoint	= '1000'.'0301'.'0f00'.'{seq_num}'.'{uuid}';	# get waypoint
	my $get_route		= '1000'.'4301'.'0f00'.'{seq_num}'.'{uuid}',	# get route
	my $get_group 		= '1000'.'8301'.'0f00'.'{seq_num}'.'{uuid}',	# get group
}




my $test_commands = {
	'0'	=>	'0400'.'b101'.'0f00',               # erase context?
	'1'	=>	'0400'.'b201'.'0f00',               # get context report?
		# both return 0800 05000f00 01000000 08004500 0f000100 00000800 85000f00 01000000
	'2' =>	'0800'.'b001'.'0f00'.'{seq_num}',	# get database version
		# returns b0000f00 {seq} {version}
	'f'	=> '1000'.'0301'.'0f00'.'{seq_num}'.'eeeeeeee'.'eeee0110',	# get waypoint
	'g' => '1000'.'4301'.'0f00'.'{seq_num}'.'81b237a6'.'3a00c218',	# get route
	'h' => '1000'.'8301'.'0f00'.'{seq_num}'.'db8299a1'.'f567e68e',	# get group
};


#-------------------------------------------
# implementation
#-------------------------------------------




sub setState
{
	my ($new_state) = @_;
	return if $state == $new_state;
	$state = $new_state;
	my $text =
		$state == $STATE_NONE 				? 'NONE' :
		$state == $STATE_GET_WP_DICT 		? 'GET_WP_DICT' :
		$state == $STATE_PARSE_WP_DICT 		? 'PARSE_WP_DICT' :
		$state == $STATE_GET_WAYPOINTS		? 'GET_WAYPOINTS' :
		$state == $STATE_GET_ROUTE_DICT		? 'GET_ROUTE_DICT' :
		$state == $STATE_PARSE_ROUTE_DICT	? 'PARSE_ROUTE_DICT' :
		$state == $STATE_GET_ROUTES			? 'GET_ROUTES' :
		$state == $STATE_GET_GROUP_DICT		? 'GET_GROUP_DICT' :
		$state == $STATE_PARSE_GROUP_DICT	? 'PARSE_GROUP_DICT' :
		$state == $STATE_GET_GROUPS			? 'GET_GROUPS' :
		'UNKNOWN';
	display($dbg,-1,"setState($state) $text");
}


sub substitute
{
	my ($text,$sig_byte,$seq_num,$uuid,) = @_;
	my $seq_packed = pack('V',$seq_num);
	my $seq_hex = unpack('H*',$seq_packed);
	$text =~ s/{sig_byte}/$sig_byte/g;
	$text =~ s/{seq_num}/$seq_hex/g;
	$text =~ s/{uuid}/$uuid/g;
	return $text;
}

sub sendCommand
{
	my ($sel,$sock,$template,$sig_byte,$seq_num,$uuid) = @_;
	if (!$sel->can_write())
	{
		error("Cannot write to socket");
		return 0;
	}
	my $command = substitute($template,$sig_byte,$seq_num,$uuid);
	my $packed = pack("H*",$command);

	my $offset = 0;
	my $command_len = length($packed);
	while ($offset < $command_len)
	{
		my $hdr = substr($packed,$offset,2);
		my $len = unpack('v',$hdr);
		my $data = substr($packed,$offset+2,$len);

		my $show_hdr = unpack("H*",$hdr);
		my $show_data = unpack("H*",$data);

		print pad("$offset,2",7)."<-- $show_hdr\n" if $SHOW;
		$offset += 2;
		if (!$sock->send($hdr))
		{
			error("Could not send header: $show_hdr\n$!");
			return 0;
		}

		# print pad("$offset,$len",6)."<-- $show_data\n";
		show_dwords(pad("$offset,$len",7)."<-- ",$data,$show_data,0,1) if $SHOW;
		if (!$sock->send($data))
		{
			error("Could not send data: $show_hdr\n$!");
			return 0;
		}
		$offset += $len;
	}
	return 1;
}



sub kind
{
	my ($sig_byte) = @_;
	return
		$sig_byte eq '8' ? 'GROUP' :
		$sig_byte eq '4' ? 'ROUTE' : 'WP';
}


sub navQueryThread
{
    display($dbg,0,"starting navQueryThread");

	# get NAVQRY ip:port

	my $rayport = findRayPortByName('NAVQRY');
	while (!$rayport)
	{
		display($dbg,1,"waiting for rayport(NAVQRY)");
		sleep(1);
		$rayport = findRayPortByName('NAVQRY');
	}
	my $nav_ip = $rayport->{ip};
	my $nav_port = $rayport->{port};
	display($dbg,1,"found rayport(NAVQRY) at $nav_ip:$nav_port");


	my $sel;
	my $sock;
	my $running = 0;
	my $seq_num = 1;
	my $sig_byte = '';
	my $started = 1;

	my $sig = '';
	my $command_time = 0;
	my $reconnect_time = 0;

	while (!$one_time_start)
	{
		display($dbg+1,0,"Waiting for one_time_start");
		sleep(1);
	}
	display($dbg,0,"starting navQuery loop");
	
    while (1)
    {
		#---------------------------------------
		# start/stop = open or close the socket
		#---------------------------------------

		if ($started && !$running)
		{
			display($dbg,0,"opening navQuery socket");
			$sock = IO::Socket::INET->new(
				LocalAddr => $LOCAL_IP,
				LocalPort => $NAVQUERY_PORT,
				PeerAddr  => $nav_ip,
				PeerPort  => $nav_port,
				Proto     => 'tcp',
				Reuse	  => 1,	# allows open even if windows is timing it out
				Timeout	  => 3 );
			if ($sock)
			{
				display($dbg,0,"navQuery socket opened");

				$running = 1;
				$sel = IO::Select->new($sock);
				$waypoints = shared_clone({});
				$routes = shared_clone({});
				$groups = shared_clone({});

				$sig = '';
				$command_time = 0;

				setState($STATE_GET_WP_DICT);
			}
			else
			{
				error("Could not open navQuery socket to $nav_ip:$nav_port\n$!");
				$started = 0;
				$reconnect_time = time();
			}
		}
		elsif ($running && !$started)
		{
			warning(0,0,"closing navQuerySocket");
			$sock->shutdown(2);
			$sock->close();
			$sock = undef;
			$running = 0;
			$sel = undef;

			$sig = '';
			$command_time = 0;
			$refresh_time = 0;
			$reconnect_time = time();
			setState($STATE_NONE);
		}
		if (!$running)
		{
			if ($reconnect_time && time() > $reconnect_time + $RECONNECT_INTERVAL)
			{
				$reconnect_time = 0;
				warning($dbg,0,"AUTO RECONNECTING");
				$started = 1;
			}
			sleep(1);
			next;
		}

		#---------------------------------------
		# read the input buffer
		#---------------------------------------
		
		my $buf;
        if ($sel->can_read(0.1))
        {
            recv($sock, $buf, 4096, 0);
            if ($buf)
            {
                my $hex = unpack("H*",$buf);
				my $len = length($hex);
				show_dwords(pad(length($buf),7)."--> ",$buf,$hex,0,1);
			}
		}

		if ($sig && time() > $command_time + $COMMAND_TIMEOUT)
		{
			error("Command timed out");
			$sig = '';
			$command_time = 0;
			$started = 0;
			$reconnect_time = time();
			setState($STATE_NONE);
			next;
		}

		if ($state == $STATE_NONE)
		{
			if ($refresh_now)
			{
				warning($dbg,0,"REFRESH NOW");
				$refresh_now = 0;
				$refresh_time = 0;
				setState($STATE_GET_WP_DICT);
			}
			elsif ($auto_refresh && $refresh_time && time() > $refresh_time + $REFRESH_INTERVAL)
			{
				warning($dbg,0,"AUTO REFRESHING");
				$refresh_time = 0;
				setState($STATE_GET_WP_DICT);
			}
		}

		#---------------------------------------
		# send dictionary commands
		#---------------------------------------

		if ($state == $STATE_GET_WP_DICT ||
			$state == $STATE_GET_ROUTE_DICT ||
			$state == $STATE_GET_GROUP_DICT )
		{
			my $seq = $seq_num++;
			$sig_byte =
				$state == $STATE_GET_GROUP_DICT ? '8' :
				$state == $STATE_GET_ROUTE_DICT ? '4' : '0';
			display($dbg+1,0,"getting ".kind($sig_byte)." dictionary");
			if (sendCommand($sel,$sock,$get_dict,$sig_byte,$seq))
			{
				$sig = pack('H*',substitute($sig_dict,$sig_byte,$seq));
				$command_time = time();
				setState($state+1);
			}
			else
			{
				$started = 0;
				$reconnect_time = time();
			}
		}

		#-----------------------------------------------
		# handle matching dictionary signatures
		#-----------------------------------------------

		elsif ($buf && substr($buf,0,8) eq $sig)
		{
			display($dbg+2,0,"state($state) ".kind($sig_byte)." sig matched");
			
			$sig = '';
			$command_time = 0;
			if (unpack('H*',substr($buf,8,4)) ne $SUCCESS_SIG)
			{
				error("Unexpected reply. No SUCCESS_SIG($SUCCESS_SIG)");
				setState($STATE_NONE);
				next;
			}
			
			if ($state == $STATE_PARSE_WP_DICT ||
				$state == $STATE_PARSE_ROUTE_DICT ||
				$state == $STATE_PARSE_GROUP_DICT )
			{
				my $hash =
					$state == $STATE_PARSE_GROUP_DICT ? $groups :
					$state == $STATE_PARSE_ROUTE_DICT ? $routes :
					$waypoints;

				# TEMPORARY DICTIONARY FIX - Skip 14 bytes at offset 548

				my $num = 0;
				my $any_new = 0;
				my $offset = 13 * 4;	# the 13th dword starts the first uuid
				my $len = length($buf);
				while ($offset < $len + 8) # 8 bytes for 2 dword uuid
				{
					if ($offset == 548)
					{
						warning($dbg,0,"skipping 14 bytes at offset 548");
						$offset += 14
					}
					my $uuid = unpack('H*',substr($buf,$offset,8));
					last if substr($uuid,0,8) eq $DICT_END_RECORD_MARKER;

					my $found = $hash->{$uuid};
					$any_new = 1 if !$found;
					$hash->{$uuid} = shared_clone({}) if !$found;

					display($dbg+1,1,pad($offset,5).pad(" uuid($num)",10).
						"= $uuid".($found ? '' : ' NEW'));

					$offset += 8;
					$num++;
				}
				display($dbg+2,0,"found($num) uuids in ".kind($sig_byte)." dictionary hash=".scalar(keys %$hash));
				setState($state + 1);
			}

			#-----------------------------------------------
			# handle matching item signatures
			#-----------------------------------------------

			elsif ($state == $STATE_GET_WAYPOINTS ||
				   $state == $STATE_GET_ROUTES ||
				   $state == $STATE_GET_GROUPS )
			{
				my $SELF_ID_OFFSET = 22;
				my $uuid = unpack('H*',substr($buf,$SELF_ID_OFFSET,8));
				my $hash =
					$state == $STATE_GET_GROUPS ? $groups :
					$state == $STATE_GET_ROUTES ? $routes :
					$waypoints;
				my $rec = $hash->{$uuid};
				if ($rec)
				{
					display($dbg+2,0,"parsing ".kind($sig_byte)." item");
				}
				else
				{
					error("Could not find item($uuid)");
					setState($STATE_NONE);
				}
			}
		}	# signature matched

		#----------------------------------------
		# request any pending items
		#----------------------------------------

		if (!$sig && (
			$state == $STATE_GET_WAYPOINTS ||
			$state == $STATE_GET_ROUTES ||
			$state == $STATE_GET_GROUPS ))
		{
			my $hash =
				$state == $STATE_GET_GROUPS ? $groups :
				$state == $STATE_GET_ROUTES ? $routes :
				$waypoints;
			my $sig_byte =
				$state == $STATE_GET_GROUPS ? '8' :
				$state == $STATE_GET_ROUTES ? '4' : '0';

			display($dbg+2,0,"checking ".scalar(keys %$hash)." ".kind($sig_byte)." items");

			my $sent = 0;
			for my $uuid (keys %$hash)
			{
				my $rec = $hash->{$uuid};
				if (!$rec->{requested})
				{
					display($dbg,0,"getting ".kind($sig_byte)." item($uuid)");
					my $seq = $seq_num++;
					if (sendCommand($sel,$sock,$get_item,$sig_byte,$seq,$uuid))
					{
						$sent = 1;
						$rec->{requested} = time();
						$sig = pack('H*',substitute($sig_item,$sig_byte,$seq));
						$command_time = time();
					}
					else
					{
						$started = 0;
						$reconnect_time = time();
					}
					last;
				}
			}

			display($dbg+2,0,kind($sig_byte)." items done sent($sent)");
			setState($state == $STATE_GET_GROUPS ? $STATE_NONE : $state+1) if $started && !$sent;
			if ($state == $STATE_NONE)
			{
				$refresh_time = time();
			}
		}
		
	}	# while 1
}	#	navQueryThread()



#--------------------------------------------------------------
# parseWaypoint
#--------------------------------------------------------------
# Methods ripped off from E80_Nave and/or FSH

my $SCALE_LATLON = 1e-7;


sub decode_coord
{
    my ($raw, $scale) = @_;
    return $raw * $scale;
}

sub deg_to_degmin
{
    my ($decimal_deg) = @_;
    my $degrees = int($decimal_deg);
    my $minutes = abs($decimal_deg - $degrees) * 60;
    return sprintf("%d°%.3f", $degrees, $minutes);

}

sub showLL
{
	my ($what,$data,$offset) = @_;
	my $l_bytes = substr($data,$offset,4);
	my $l_int = unpack('l',$l_bytes);
	my $l_str = unpack("H*",$l_bytes);
	my $l = decode_coord($l_int,$SCALE_LATLON);
	my $s_degmin = deg_to_degmin($l);
		# lat and lon are encoded as fixed point integers
		# with a scaling factor.
	printf("    $what($l_str)=%0.6f==%s\n",$l,$s_degmin);
}



sub showDate
{
	my ($data,$offset) = @_;
	my $date_bytes = substr($data,$offset,2);
	my $date_int = unpack("v",$date_bytes);
	my $date_str = unpack("H*",$date_bytes);
	my $date_seconds = $date_int * 86400;
		# date encoded as days since 1970-01-01 unix epoch
	my ($sec, $min, $hour, $mday, $mon, $year) = gmtime($date_seconds);
	$year += 1900;
	$mon  += 1;
	$mon = pad2($mon);
	$mday = pad2($mday);
	print "    DATE($date_str)-$year-$mon-$mday\n";
}

sub showTime
{
	my ($data,$offset) = @_;
	my $time_bytes = substr($data,$offset,4);
	my $time_int = unpack("V",$time_bytes);
	my $time_str = unpack("H*",$time_bytes);
		# time encoded as 1/10000's of a second

	# THIS IS DIFFERENT THAN E80 NAV THAT GETS THEM AS 1/10000's of a second

	my $sec = $time_int;	# int($time_int/10000);
	my $min = int($sec/60);
	my $hour = int($min/60);
	$sec = $sec % 60;
	$min = $min % 60;
	$hour = pad2($hour);
	$min = pad2($min);
	$sec = pad2($sec);
	print "    TIME($time_str)=$hour:$min:$sec\n";
}


sub northEastToLatLon	# from FSH
    # Convert mercator north,east coords to lat/lon.
    # From blackbox.ai, based on https://wiki.openstreetmap.org/wiki/ARCHIVE.FSH
    # In my first 'fishfarm' test case, I expected 5.263N minutes but got 5.261N
    #   0.001 minutes == approx 1.8553 meters, so this is physically off by about 4 meters.
    #   More testing will be required to see if it's close on other coordinates.
    #   The original fshfunc.c implies an accuracy of 10cm, but that's only for the
    #   the iteration, not the actual value.
{
    my ($north, $east) = @_;

    my $FSH_LAT_SCALE = 107.1709342;
        # Northing in FSH is prescaled by this (empirically determined)
        # Original comment said "probably 107.1710725 is more accurate, not sure"
        # but that makes mine worse, not better.
    # my $FSH_LAT_SCALE = 107.1705000;
        # experimental value gave me 5.263 for fishfarm

    my $LONG_SCALE = 0x7fffffff;  # 2147483647
    my $M_PI = 3.14159265358979323846;
    my $M_PI_2 = $M_PI / 2;

    my $longitude = ($east / $LONG_SCALE) * 180.0;
    my $N = $north / $FSH_LAT_SCALE;

    # WGS84 ellipsoid parameters
    my $a = 6378137;  # semi-major axis
    my $e = 0.08181919;  # eccentricity

    # Iterative calculation for latitude
    my $phi = $M_PI_2;  # Initial guess
    my $phi0;
    my $IT_ACCURACY = 1.5E-8;
    my $MAX_IT = 32;
    my $i = 0;

    do {
        $phi0 = $phi;
        my $esin = $e * sin($phi0);
        $phi = $M_PI_2 - 2.0 * atan(exp(-$N / $a) * pow((1 - $esin) / (1 + $esin), $e / 2));
        $i++;
    } while (abs($phi - $phi0) > $IT_ACCURACY && $i < $MAX_IT);

    # Convert radians to degrees
    my $latitude = $phi * 180 / $M_PI;

	my $lat = sprintf("%.6f",$latitude);
	my $lon = sprintf("%.6f",$longitude);

	#display($dbg,0,"northEastToLatLon($north,$east) ==> $lat,$lon");
	#latLonToNorthEast($lat,$lon);

    return {
        lat => $lat,
        lon => $lon };
}


#------------------------------------
# parse a waypoint
#------------------------------------

my $WP_UUID_MARKER 		= '10000202';



sub printError
{
	my ($msg) = @_;
	setConsoleColor($DISPLAY_COLOR_ERROR);
	print "$msg\n";
	setConsoleColor();
}



sub parseWaypoint
{
	my ($wp_num,$wp_uuid,$buf) = @_;

	display_bytes(0,0,"wp($wp_num)",$buf);

	#   fsh record
	#		these offsets seem to be constant

	#				my $field_specs = [             # typedef struct fsh_wpt_data; total length 40 bytes + name_len + cmt_len
	#		56			north  		=> 'l',         #   0   int32_t north
	#		60			east   		=> 'l',         #   4   int32_t east; 				// prescaled ellipsoid Mercator northing and easting
	#		64			d           => 'A12',       #   8   char d[12];         		// 12x \0
	#		76			sym         => 'C',         #   20  char sym;           		// probably symbol
	#		77			temp        => 'S',         #   21  uint16_t tempr;     		// temperature in Kelvin * 100
	#		79			depth       => 'l',         #   23  int32_t depth;      		// depth in cm
	#												#   ######### fsh_timestamp_t ts; 	// timestamp
	#		83			time        => 'L',         #   27  uint32_t timeofday;  		// time of day in seconds
	#		87			date        => 'S',         #   31  uint16_t date;       		// days since 1.1.1970
	#		89			i           => 'C',         #   33  char i;             		// unknown, always 0
	#		90			name_len    => 'C',         #   34  char name_len;      		// length of name array
	#		91			cmt_len     => 'C',         #   35  char cmt_len;       		// length of comment
	#		92			j     		=> 'L',         #   36  int32_t j;                  // unknown, always 0
	#				];

	#			0        4        8        12       16       20       24       28
	#	0		06000f00 7b000000 00000400 14000002 0f007b00 000081b2 37a63900 e6cc0100   ........................7.9.....
	#	32		00004800 01020f00 7b000000 3c000000 1ee58905 b86009cf 35c39706 fc9c95c5   ..H.........<........`..5.......
	#	64		00000000 00000000 00000000 00ffffff ffffff00 00000000 00000b01 00000000   ................................
	#	96		57617970 6f696e74 62313241 10000202 0f007b00 000081b2 37a63900 e6cc       Waypointb12A......

	my $buf_len = length($buf);
	my $expect_len1 = $buf_len - 54;   #	0x50=80 in rec(134)
	my $expect_len2 = $buf_len - 66;   #	0x44=68 in rec(134)

	my $field_specs = [
		{offset => 0,	name => 'sig1',			pack => 'H8',	len => 4,	expected => "06000f00",		},		#			dword 		06000f00)					06=00001100 reply	 03=00000011 command   00f000=unknown but probably a function
		{offset => 4,	name => 'seq_num',		pack => 'v',	len => 4,	expected => $wp_num+2,		},		#			dword 		currently $wp_num+2
		{offset => 8,	name => 'sig2',			pack => 'H8',	len => 4,	expected => "00000400",		},		#			dword		00000400					probably a max packet length or something
		{offset => 12,	name => 'constant1',	pack => 'H8',	len => 4,	expected => "14000002",		},		#			dword		14000002
		{offset => 16,	name => 'constant2',	pack => 'H4',	len => 2,	expected => "0f00",			},		#			word		0f00
		{offset => 18,	name => 'seq_num2',		pack => 'V',	len => 4,	expected => $wp_num+2,		},		#			dword		repeated
		{offset => 22,	name => 'self_uuid',	pack => 'H16',	len => 8,	expected => $wp_uuid,		},		#			qword		$wp_uuid
		{offset => 30,	name => 'constant3',	pack => 'H8',	len => 4,	expected => "01000000",		},		#			dword		01000000
		{offset => 34,	name => 'length1',		pack => 'v',	len => 2,	expected => $expect_len1,	},		#			word		0x48=72 in rec(126)			some kind of an offset, seems directly related to record size
		{offset => 36,	name => 'constant4',	pack => 'H8',	len => 4,	expected => "01020f00",		},		#			dword		01020f00					looks like a signature
		{offset => 40,	name => 'seq_num3',		pack => 'V',	len => 4,	expected => $wp_num+2,		},		#			dword		repeated again
		{offset => 44,	name => 'length2',		pack => 'V',	len => 4,	expected => $expect_len2,	},		#			dword?		0x3c=60 in rec(126)			some kind of an offset, seems directly related to record size
		{offset => 48,	name => 'lat',			pack => 'l',	len => 4,	expected => undef ,			},		#			dword		latitude integer 1e-7		working with unpack('l')
		{offset => 52,	name => 'lon',			pack => 'l',	len => 4,	expected => undef ,			},		#			dword		longitude integer 1e-1		working with unpack('l')
		# Commmon Waypoint Record - see Common Waypoint in fshBlocks.pm
		{offset => 56,	name => 'north',  		pack => 'l',    len => 4,	expected => undef,			},		#   0 		dword
		{offset => 60,	name => 'east',   		pack => 'l',    len => 4,	expected => undef,			},		# 	4 		dword		prescaled ellipsoid Mercator northing and easting
		{offset => 64,	name => 'constant5',    pack => 'H12',  len => 12,	expected => "000000000000",	},		# 	8 		12 bytes	12x \0
		{offset => 76,	name => 'sym',         	pack => 'C',    len => 1,	expected => undef,			},		# 	20		byte		probably symbol
		{offset => 77,	name => 'temperature',  pack => 'S',    len => 2,	expected => undef,			},		# 	21		word		temperature in Kelvin * 100
		{offset => 79,	name => 'depth',       	pack => 'l',    len => 4,	expected => undef,			},		# 	23		dword		depth in cm
		{offset => 83,	name => 'time',        	pack => 'L',    len => 4,	expected => undef,			},		# 	27		dword		time of day in seconds
		{offset => 87,	name => 'date',        	pack => 'S',    len => 2,	expected => undef,			},		# 	31		word		days since 1.1.1970
		{offset => 89,	name => 'constant6',    pack => 'C',    len => 1,	expected => 0,				},		#  	33		byte		unknown, always 0
		{offset => 90,	name => 'name_len',    	pack => 'C',    len => 1,	expected => undef,			},		# 	34		byte		length of name array
		{offset => 91,	name => 'cmt_len',     	pack => 'C',    len => 1,	expected => undef,			},		# 	35		byte		length of comment
		{offset => 92,	name => 'constant7',    pack => 'l',    len => 4,	expected => undef,			},		# 	36		dword		seen 00000000 and 01000100

	];
	
	my $array = shared_clone([]);
	my $hash  = shared_clone({});
	buildRecord($array,$hash,$buf,$field_specs);


	my $LAT_OFFSET 		= 48;
	my $LON_OFFSET 		= 52;
	my $NORTH_OFFSET 	= 56;
	my $EAST_OFFSET 	= 60;
	my $TIME_OFFSET 	= 83;
	my $DATE_OFFSET 	= 87;
	my $NAME_LEN_OFFSET = 90;
	my $NAME_OFFSET 	= 96;

	my $name_len = unpack('C',substr($buf,$NAME_LEN_OFFSET,1));
		# the name len assumption seems to be holding true.

	my $name = substr($buf,$NAME_OFFSET,$name_len);	# $MAX_NAME);
	# $name =~ s/\x10.*$//;
	print "WP($wp_num) uuid($wp_uuid)            $name\n";
	if ($hash->{cmt_len})
	{
		my $comment = substr($buf,$NAME_OFFSET + $name_len,$hash->{cmt_len});
		print "    Ccomment='$comment'\n";
	}
	showLL('Lat',$buf,$LAT_OFFSET);
	showLL('Lon',$buf,$LON_OFFSET);
	showDate($buf,$DATE_OFFSET);
	showTime($buf,$TIME_OFFSET);

	my $north = unpack('l',substr($buf,$NORTH_OFFSET,4));
	my $east = unpack('l',substr($buf,$EAST_OFFSET,4));
	my $alt_coords = northEastToLatLon($north,$east);
	print "    alt lat($alt_coords->{lat}) lon($alt_coords->{lon})\n";

	#-----------------------------
	# following the name I now think there are a set of guids until one
	# gets to the

	my $rest_hex = unpack('H*',substr($buf,$NAME_OFFSET + $name_len + $hash->{cmt_len}));
	my $hex_len = length($rest_hex);
	my $hex_offset = 0;
	while ($hex_offset < $hex_len-16)
	{
		my $uuid = substr($rest_hex,$hex_offset,16);
		last if index($uuid,$WP_UUID_MARKER) == 0;
		print "    UUID($uuid)\n";
		$hex_offset += 16;
	}

	my $waypoint = shared_clone({});
	$waypoint->{num} = $wp_num;

}	# parseWaypoint


sub buildRecord
{
	my ($array,$hash,$buf,$field_specs) = @_;
	print "RECORD\n";
	for my $spec (@$field_specs)
	{
		my $bytes = substr($buf,$spec->{offset},$spec->{len});
		my $hex = unpack("H*",$bytes);
		my $value = unpack($spec->{pack},$bytes);
		push @$array,$value;
		$hash->{$spec->{name}} = $value;
		print "    ".pad("$spec->{name}($hex)",30)." = '$value'\n";
		if (defined($spec->{expected}) && $value ne $spec->{expected})
		{
			printError("        expected($spec->{expected})  got($value)");
		}
	}
}


1;