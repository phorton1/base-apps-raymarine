#---------------------------------------------
# nq_parse.pm
#---------------------------------------------
# Routines to parse NAVQRY messages, and the
# BUFFERS within them into Waypoints, Routes, and Groups.


package nq_parse;
use strict;
use warnings;
use threads;
use threads::shared;
use POSIX qw(floor pow atan tan);
use Pub::Utils;


my $dbg_wp = 0;
my $dbg_route = -2;
my $dbg_group = 0;
my $dbg_unpack = -1;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		parseNQRecord
		displayNQRecord

		parseNQWaypoint
		parseNQRoute
		parseNQGroup
		
		buildNQWaypoint
		buildNQRoute
		buildNQGroup

		unpackRecord
		packRecord

		latLonToNorthEast
		northEastToLatLon

		$SCALE_LATLON
		$METERS_PER_NM
		$FEET_PER_METER
		$SECS_PER_DAY

    );
}

our $SCALE_LATLON 	= 1e7;
our $METERS_PER_NM 	= 1852;
our $FEET_PER_METER  = 3.28084;
our $SECS_PER_DAY 	= 86400;


my $SPEC_DETAIL = 0;
my $SPEC_SIZE	= 1;
my $SPEC_UNPACK	= 2;
	# fields within a field spec record


my $WP_REC_SIZE = 52;
my $WP_REC_SPECS = [
	#              	detail	size	unpack
	big_len	    => [ 1,		4,		'V',	],	   #  0   uint32_t len				// length of data buffer
	lat			=> [ 0,		4,		'l',	],	   #  4	  int32_t lat;				// 1E7 lat
	lon			=> [ 0,		4,		'l',	],	   #  8   int32_t lon;				// 1E7 lon
	north  		=> [ 0,		4,		'l',    ],     #  12  int32_t north				// prescaled ellipsoid Mercator northing and easting
	east   		=> [ 0,		4,		'l',    ],     #  16  int32_t east;
	k1_0x12     => [ 2,		12,		'H24',  ],     #  20  char d[12];         		// 12x \0
	sym         => [ 0,		1,		'C',    ],     #  32  char sym;           		// probably symbol
	temp        => [ 0,		2,		'S',    ],     #  33  uint16_t tempr;     		// temperature in Kelvin * 100
	depth       => [ 0,		4,		'l',    ],     #  35  int32_t depth;      		// depth in cm
	time        => [ 0,		4,		'L',    ],     #  39  uint32_t timeofday;  		// time of day in seconds
	date        => [ 0,		2,		'S',    ],     #  43  uint16_t date;       		// days since 1.1.1970
	k2_0        => [ 2,		1,		'C',    ],     #  45  char i;             		// unknown, always 0
	name_len    => [ 1,		1,		'C',    ],     #  46  char name_len;      		// length of name array
	cmt_len     => [ 1,		1,		'C',    ],     #  47  char cmt_len;       		// length of comment
	k3_0     	=> [ 2,		4,		'L',    ],     #  48  int32_t j;                  // unknown, always 0
];


my $GROUP_REC_SIZE = 8;
my $GROUP_REC_SPECS = [
	big_len	    => [ 1,	4,	'V',	],		# 0		uint32_t;
	name_len	=> [ 1,	1,	'C',	],		# 6		uint8_t;
	cmt_len 	=> [ 1,	1,	'C',	],		# 7		uint8_t;
	num_uuids   => [ 0,	2,	'v',	],		# 8		uint16_t;
];



my $ROUTE_HDR1_SIZE = 12;
my $ROUTE_HDR1_SPECS = [
	big_len	    => [ 1,	4,	'V',	],		# 0		uint32_t;
	u1_0		=> [ 2,	2,	'H4',	],		# 4		uint16_t;
	name_len	=> [ 1,	1,	'C',	],		# 6		uint8_t;
	cmt_len 	=> [ 1,	1,	'C',	],		# 7		uint8_t;
	num_wpts    => [ 0,	2,	'v',	],		# 8		uint16_t;
	bits		=> [ 2,	1,	'H2',   ],		# 10	uint8_t;   1=temporary; 2=don't transfer to RNS
	color		=> [ 0, 1,	'C',	],		# 11	uint8_t color index
];

my $ROUTE_HDR2_SIZE = 46;
my $ROUTE_HDR2_SPECS = [
	lat_start	=> [ 0,	4,	'l',	],		# 0
	lon_start	=> [ 0,	4,	'l',	],		# 4
	lat_end		=> [ 0,	4,	'l',	],		# 8
	lon_end 	=> [ 0,	4,	'l',	],		# 12
	distance	=> [ 2,	4,	'V', 	],		# 16 = uint32_t distance in meters
	u4_0200		=> [ 2,	4,	'H8',	],		# 20 = 02000000 number?
	u5			=> [ 2,	4,	'H8',	],		# 24 = b8975601 data? end marker?
	u6_self		=> [ 1,	8,	'H16',	],		# 28 = self uuid dc82990f f567e68e
	u7_self		=> [ 1,	8,	'H16',	],		# 36 = self uuid dc82990f f567e68e
	u8		    => [ 2,	2,	'H4',   ],		# unknown
];		# 34 = e039 - 0x39e = 926

# Points, which never seems to be populated by E80 or RNS
# are only shown at $NAVQRY_ROUTE_DETAIL >= 2

my $ROUTE_PT_SIZE = 10;
my $ROUTE_PT_SPECS = [
	p_u0_0		=> [ 1,	2,	'H4',   ],		# 0		uint16_t;
	p_depth		=> [ 1,	2,	'H4',   ],		# 2		uint16_t;
	p_u1_0		=> [ 1,	4,	'H8',   ],		# 4		uint32_t;
	p_sym		=> [ 1,	2,	'H4',   ],		# 8		uint16_t;
];


sub parseNQRecord
{
	my ($kind,$buffer) = @_;
	return parseNQWaypoint($buffer) if $kind eq 'WAYPOINT';
	return parseNQRoute($buffer) if $kind eq 'ROUTE';
	return parseNQGroup($buffer) if $kind eq 'GROUP';
}



#--------------------------------------------------------------
# parseWaypointBuffer
#--------------------------------------------------------------
# Methods ripped off from E80_Nave and/or FSH
# Not yet re-applied after reworking whole NAVQRY
# as well as a bunch of FSH stuff

sub padRight
{
	my ($s,$size) = @_;
	my $len = length($s);
	my $pad = $len < $size ? pad('',$size-$len) : '';
	return $pad.$s;
}

sub addOutput
{
	my ($pad,$key,$value,$extra,$condition) = @_;
	return '' if defined($condition) && !$condition;
	my $text = $pad.pad($key,10)." = ".pad($value,20);
	$text .= "= $extra" if $extra;
	return $text."\n";
}

sub deg_to_degmin
{
    my ($decimal_deg) = @_;
    my $degrees = int($decimal_deg);
    my $minutes = abs($decimal_deg - $degrees) * 60;
    return sprintf("%d°%.3f", $degrees, $minutes);
}

sub outputLL
{
	my ($raw,$value,$scale) = @_;
	$value /= $SCALE_LATLON if $scale;
	my $hex = unpack('H*',pack('V',$raw));
	my $degmin = deg_to_degmin($value);
	my $degrees = padRight(sprintf("%0.3f",$value),8);
	return "($hex) $degrees = ".padRight($degmin,12);
}

sub outputDistance
	# distance in meters
{
	my ($value) = @_;
	my $hex = unpack('H*',pack('V',$value));
	return sprintf "($hex) NM = %0.2f",$value/$METERS_PER_NM;
}

sub outputDepth
	# signed? depth in centimeters
{
	my ($value) = @_;
	my $hex = unpack('H*',pack('l',$value));
	return sprintf "($hex) FEET = %0.2f",($value/100)*$FEET_PER_METER;
}

sub unpackDate
{
	my ($date_int) = @_;
	my $hex = unpack("H*",pack('v',$date_int));
	my $seconds = $date_int * 86400;
		# date encoded as days since 1970-01-01 unix epoch
	my ($sec, $min, $hour, $mday, $mon, $year) = gmtime($seconds);
	$year += 1900;
	$mon  += 1;
	$mon = pad2($mon);
	$mday = pad2($mday);
	return "($hex)     $year-$mon-$mday";
}

sub unpackTime
	# time encoded directly as seconds
	# THIS IS DIFFERENT THAN E80 NAV THAT GETS THEM AS 1/10000's of a second
{
	my ($time_long) = @_;
	my $hex = unpack("H*",pack('V',$time_long));
	my $sec = $time_long;	# int($time_int/10000);
	my $min = int($sec/60);
	my $hour = int($min/60);
	$sec = $sec % 60;
	$min = $min % 60;
	$hour = pad2($hour);
	$min = pad2($min);
	$sec = pad2($sec);
	return "($hex) $hour:$min:$sec";
}



my $FSH_LAT_SCALE = 107.1709342;  # same scale used in forward transform
my $LONG_SCALE = 0x7fffffff;  # 2147483647
my $M_PI = 3.14159265358979323846;
my $M_PI_2 = $M_PI / 2;


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


sub latLonToNorthEast
	# from copilot
{
    my ($lat_deg, $lon_deg) = @_;

    # WGS84 ellipsoid parameters
    my $a = 6378137;       # semi-major axis
    my $e = 0.08181919;    # eccentricity

    # Convert degrees to radians
    my $lat_rad = $lat_deg * $M_PI / 180.0;

    # Mercator projection formula for northing
    my $esin = $e * sin($lat_rad);
    my $N = $a * log(tan($M_PI / 4 + $lat_rad / 2) * ((1 - $esin) / (1 + $esin)) ** ($e / 2));

    # Apply FSH scaling
    my $north = int($N * $FSH_LAT_SCALE + 0.5);

    # Easting is linear
    my $east = int(($lon_deg / 180.0) * $LONG_SCALE + 0.5);

    return {
        north => $north,
        east  => $east
    };
}



sub displayNQRecord
{
	my ($rec,$kind,$indent,$detail_level) = @_;
	my $pad = pad('',$indent);
	my $text = "\n".$pad."$kind Record\n";
	my $offset = 0;

	$text .= addOutput($pad,'name',$rec->{name}) if $rec->{name};
	$text .= addOutput($pad,'comment',$rec->{comment}) if $rec->{comment};
	my $alt_coords;
	$alt_coords = northEastToLatLon($rec->{north},$rec->{east})
		if defined($rec->{north}) && defined($rec->{east});

	my $all_specs =
		$kind eq 'GROUP' ? [ $GROUP_REC_SPECS ] :
		$kind eq 'ROUTE' ? [ $ROUTE_HDR1_SPECS, $ROUTE_HDR2_SPECS ] :
		[ $WP_REC_SPECS ];

	my $num = 1;
	for my $specs (@$all_specs)
	{
		$text .= $pad."HDR$num\n" if @$all_specs > 1;
		for (my $i = 0; $i < @$specs; $i += 2)
		{
			my ($key, $spec) = @$specs[$i, $i+1];
			my $detail = $$spec[$SPEC_DETAIL];
			if ($detail_level >= $detail)
			{
				my $val = $rec->{$key};
				$val = 0 if !defined($val);
				my $extra = '';
				$extra = outputLL($val,$val,1) if $key =~ /^(lat|lon)/;
				$extra = outputLL($val,$alt_coords->{lat}) if $key eq 'north';
				$extra = outputLL($val,$alt_coords->{lon}) if $key eq 'east';
				$extra = unpackDate($val) if $key eq 'date';
				$extra = unpackTime($val) if $key eq 'time';
				$extra = outputDistance($val) if $key eq 'distance';
				$extra = outputDepth($val) if $key eq 'depth';
				$text .= addOutput($pad,$key,$val,$extra);
			}
		}
	}

	my $uuids = $rec->{uuids} || [];
	my $raw_points = $rec->{raw_points} || [];
	for (my $i=0; $i<@$uuids; $i++)
	{
		$text .= addOutput($pad,"UUID($i)",$$uuids[$i]);
	}
	for (my $i=0; $i<@$raw_points; $i++)
	{
		$text .= addOutput($pad,"PT($i)",$$raw_points[$i]);
	}
	
	return $text;
}




sub unpackRecord
{
	my ($rec_name,$field_specs,$buffer,$rec_offset,$rec_size) = @_;
	display($dbg_unpack,0,"unpackRecord($rec_name) offset($rec_offset) rec_size($rec_size)");

	my $data = substr($buffer,$rec_offset,$rec_size);
	display($dbg_unpack+1,1,"data=".unpack('H*',$data));

	my $offset = 0;
	my $rec = shared_clone({});
	my $num_specs = scalar(@$field_specs) / 2;
	for (my $i=0; $i<$num_specs; $i++)
	{
		my $field = $field_specs->[$i * 2];
		my $spec = $field_specs->[$i * 2 + 1];
		my $size = $$spec[$SPEC_SIZE];
		my $up   = $$spec[$SPEC_UNPACK];

		my $raw  = substr($data,$offset,$size);
		my $hex  = unpack('H*',$raw);
		my $val  = unpack($up,$raw);

		$rec->{$field} = defined($val) ? $val : 0;
		display($dbg_unpack,1,"offset($offset) ".pad($field,20)."($hex)= '$rec->{$field}'");
		$offset += $size;
	}
	return $rec;
}


sub packRecord
	# builds the record WITHOUT the big_len field
{
	my ($name,$rec,$field_specs) = @_;
	$rec ||= {};
	display_hash($dbg_unpack,0,"packRecord($name)",$rec);

	my $data = '';
	my $num_specs = scalar(@$field_specs) / 2;
	for (my $i=0; $i<$num_specs; $i++)
	{
		my $field = $field_specs->[$i * 2];
		next if $field eq 'big_len';
		my $spec = $field_specs->[$i * 2 + 1];
		my $up   = $$spec[$SPEC_UNPACK];
		my $val  = $rec->{$field};
		$val = 0 if !defined($val);
		$data .= pack($up,$val);
	}

	display($dbg_unpack,1,"data=".unpack('H*',$data));
	return $data;
}



#------------------------------------
# parse a group
#------------------------------------

sub parseNQGroup
	# The message itself starts with
	#		len	 command  seqnum
    #       5e00 01020f00 0f000000
	# after which the buffer starts with a dword(big_len) for the number
	# of bytes which follow the dword(len), which will always be
	# length($buffer)-4
    #       17000000 0b000100 74657374 466f6c64 657239				................testFolder9
	#				 dc829918 f567e68e
	#		1f000000 0b000200 74657374 466f6c64 657239				................testFolder9
	#				 dc829918 f567e68e
	#                aaaaaaaa aaaaaaaa
	#		27000000 0b000300 74657374 466f6c64 6572				................testFolder9
	#				 dc829918 f567e68e
	#                aaaaaaaa aaaaaaaa
	#				 bbbbbbbb bbbbbbbb
	#
	# The data itself (starting at 0b0000000)
	#	word? name length, name_len
	#   I'm gonna go with byte(name_len) and byte(cmt_len)
	#   word number of uuids
	#   followed by the name
	#   followed by a list of uuids
	# Where the first uuid is the self_uuid of the folder
	# and the subsequent ones are the waypoints.
{
	my ($buffer) = @_;
	my $buf_len = length($buffer);
	display($dbg_group,0,"parseNQGroup len($buf_len)");

	my $offset = 0;
	my $rec = unpackRecord('group_hdr',$GROUP_REC_SPECS, $buffer, $offset, $GROUP_REC_SIZE);
	$offset += $GROUP_REC_SIZE;
	
	my $name = substr($buffer,$offset,$rec->{name_len});
	$offset += $rec->{name_len};
	my $comment = $rec->{cmt_len} ? substr($buffer,$offset,$rec->{cmt_len}) : '';
	$offset += $rec->{cmt_len};

	$rec->{name} = $name;
	$rec->{comment} = $comment;
	my $uuids = $rec->{uuids} = shared_clone([]);

	for (my $i=0; $i<$rec->{num_uuids}; $i++)
	{
		my $uuid = unpack('H*',substr($buffer,$offset,8));
		push @$uuids,$uuid;
		$offset += 8;
	}

	$rec->{text_uuids} = join(" ",@$uuids);
	display_hash($dbg_group+1,1,"group($name)",$rec);
	return $rec;
}


sub buildNQGroup
{
	my ($rec) = @_;
	my $name = $rec->{name} || '';
	my $comment = $rec->{comment} || '';
	my $uuids = $rec->{uuids} || shared_clone([]);

	$rec->{name_len} = length($name);
	$rec->{cmt_len} = length($comment);
	$rec->{uuids} = $uuids;
	$rec->{num_uuids} = @$uuids;

	display($dbg_wp,0,"buildNQGroup($rec->{name}");
	my $buffer = packRecord('GROUP',$rec,$GROUP_REC_SPECS);
	$buffer .= $name;
	$buffer .= $comment;

	for my $uuid (@$uuids)
	{
		$buffer .= pack('H*',$uuid);
	}

	$buffer = pack('V',length($buffer)).$buffer;
	parseNQGroup($buffer);	# debug check
	return $buffer;
}



#------------------------------------
# parse a route
#------------------------------------

sub parseNQRoute
	# The message itself starts with
	#		len	 command  seqnum
    #       5e00 01020f00 0f000000
	# after which the buffer starts with a dword(big_len) for the number
	# of bytes which follow the dword(len), which will always be
	# length($buffer)-4
	#		52000000 00000a00 01000005 74657374 526f7574 6531aaaa   				  .........testRoute1..
    #       aaaaaaaa aaaa9e44 9005ecdb face9e44 9005ecdb face0000 00000200 0000b897   .......D.......D................
    #       5601dc82 990ff567 e68edc82 990ff567 e68ee039 00000000 00000000 0000       V......g.......g...9..........
	# The data itself consists of
	#	- a HDR1 record
	#	- num_wpts Waypoint uuids
	#	- a HDR2 record
	#	- num_wpts POINT records
	# Some of the fields are tentatively named,
	# 	like 'self_uuid' but are not consistently
	# 	created by RNS or E80 as I would expect.
{
	my ($buffer) = @_;
	my $buf_len = length($buffer);
	display($dbg_route,0,"parseNQRoute len($buf_len)");

	my $offset = 0;
	my $rec = unpackRecord('hdr1',$ROUTE_HDR1_SPECS, $buffer, $offset, $ROUTE_HDR1_SIZE);
	$offset += $ROUTE_HDR1_SIZE;

	if ($rec->{num_wpts} == 0 && $rec->{name_len} == 0)
 	{
		warning($dbg_route,1,"NO NAME OR WAYPOINTS IN ROUTE");
		return undef;
	}

	my $name = substr($buffer,$offset,$rec->{name_len});
	$offset += $rec->{name_len};
	my $comment = $rec->{cmt_len} ? substr($buffer,$offset,$rec->{cmt_len}) : '';
	$offset += $rec->{cmt_len};

	$rec->{name} = $name;
	$rec->{comment} = $comment;
	my $uuids = $rec->{uuids} = shared_clone([]);
	my $points = $rec->{points} = shared_clone([]);
	my $raw_points = $rec->{raw_points} = shared_clone([]);

	for (my $i=0; $i<$rec->{num_wpts}; $i++)
	{
		my $uuid = unpack('H*',substr($buffer,$offset,8));
		push @$uuids,$uuid;
		$offset += 8;
	}

	my $hdr2 = unpackRecord('hdr2',$ROUTE_HDR2_SPECS, $buffer, $offset, $ROUTE_HDR2_SIZE);
	$offset += $ROUTE_HDR2_SIZE;
	
	for (my $i=0; $i<$rec->{num_wpts}; $i++)
	{
		my $raw_point = unpack('H*',substr($buffer,$offset,$ROUTE_PT_SIZE));
		push @$raw_points,$raw_point;
		my $pt = unpackRecord('point',$ROUTE_PT_SPECS, $buffer, $offset, $ROUTE_PT_SIZE);
		push @$points,$pt;
		$offset += $ROUTE_PT_SIZE;
	}


	$rec->{text_uuids} = join(" ",@$uuids);
	display_hash($dbg_route+1,1,"route($name)",$rec);
	return $rec;
}


sub buildNQRoute
{
	my ($rec) = @_;
	my $name = $rec->{name} || '';
	my $comment = $rec->{comment} || '';
	my $uuids = $rec->{uuids} || shared_clone([]);
	my $points = $rec->{uuids} || shared_clone([]);

	$rec->{name_len} = length($name);
	$rec->{cmt_len} = length($comment);
	$rec->{uuids} = $uuids;
	$rec->{points} = $uuids;
	my $num_wpts = $rec->{num_wpts} = @$uuids;

	display($dbg_wp,0,"buildNQRoute($rec->{name}");
	my $buffer = packRecord('ROUTE_HDR1',$rec,$ROUTE_HDR1_SPECS);
	$buffer .= $name;
	$buffer .= $comment;

	for (my $i=0; $i<$num_wpts; $i++)
	{
		my $uuid = $$uuids[$i] || '0000000000000000';
		$buffer .= pack('H*',$uuid);
	}

	$buffer .= packRecord('ROUTE_HDR2',$rec,$ROUTE_HDR2_SPECS);

	for (my $i=0; $i<$num_wpts; $i++)
	{
		my $point = $$points[$i];
		$buffer .= packRecord("ROUTE_PT($i)",$point,$ROUTE_PT_SPECS);
	}

	$buffer = pack('V',length($buffer)).$buffer;
	parseNQRoute($buffer);	# debug check
	return $buffer;
}



#------------------------------------
# parse a waypoint
#------------------------------------

sub parseNQWaypoint
	# The NAVQRY message itself starts with
	#       len  command  seqnum
	# 		5b00 01020f00 43000000
	# after which the buffer starts with a dword(big_len) for the number
	# of bytes which follow the dword(len), which will always be
	# length($buffer)-4, followed by the length(52) waypoint data record,
	# followed by zero or more uuids.
	#		4f000000 9e449005 ecdbface c16a9f06 ad4a84c5 00000000   				  ...D.......j...J......
	#      	00000000 00000000 02010030 010000ef dc000088 4f000d0a 01000000 74657374   ...........0........O.......test
	#      	57617970 6f696e74 31777043 6f6d6d65 6e7431dc 82990ff5 67e68e              Waypoint1wpComment1.....g..
	# The general idea appears to be that the waypoint will keep
	# the uuid of the parent Group if it is in a Group, and/or a
	# list of the uuids of the Routes it is in, if it is in Routes.
	# In practice I don't believe these uuids are used for anything,
	# and they, at least the ones for Routes, are not rigourously
	# maintained by the E80 or RNS.
{
	my ($buffer) = @_;
	my $buf_len = length($buffer);
	display($dbg_wp,0,"parseNQWaypoint len($buf_len)");
	if ($buf_len < $WP_REC_SIZE)
	{
		warning($dbg_wp,1,"buffer($buf_len) is less than WP_REC_SIZE($WP_REC_SIZE) in length");
		return undef;
	}

	my $offset = 0;
	my $rec = unpackRecord('waypoint',$WP_REC_SPECS, $buffer, $offset, $WP_REC_SIZE);

	$offset += $WP_REC_SIZE;
	my $name = substr($buffer,$offset,$rec->{name_len});
	$offset += $rec->{name_len};
	my $comment = $rec->{cmt_len} ? substr($buffer,$offset,$rec->{cmt_len}) : '';
	$offset += $rec->{cmt_len};

	$rec->{name} = $name;
	$rec->{comment} = $comment;
	my $uuids = $rec->{uuids} = shared_clone([]);

	while ($offset <= $buf_len-8)
	{
		my $uuid = unpack('H*',substr($buffer,$offset,8));
		push @$uuids,$uuid;
		$offset += 8;
	}

	$rec->{text_uuids} = join(" ",@$uuids);
	display_hash($dbg_wp+1,1,"wp($name)",$rec);
	return $rec;
}


sub buildNQWaypoint
{
	my ($rec) = @_;
	my $name = $rec->{name} || '';
	my $comment = $rec->{comment} || '';
	$rec->{name_len} = length($name);
	$rec->{cmt_len} = length($comment);
	
	display($dbg_wp,0,"buildNQWaypoint($rec->{name}");
	my $buffer = packRecord('WAYPOINT',$rec,$WP_REC_SPECS);
	$buffer .= $name;
	$buffer .= $comment;
	
	my $uuids = $rec->{uuids};
	for my $uuid (@$uuids)
	{
		$buffer .= pack('H*',$uuid);
	}

	$buffer = pack('V',length($buffer)).$buffer;
	parseNQWaypoint($buffer);	# debug check
	return $buffer;
}


1;