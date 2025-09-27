#---------------------------------------------
# r_parseWP.pm
#---------------------------------------------

package r_ParseWP;
use strict;
use warnings;
use threads;
use threads::shared;
use POSIX qw(floor pow atan);
use Pub::Utils;
use r_utils;

BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(
		parseWaypoint
    );
}



#--------------------------------------------------------------
# parseWaypoint
#--------------------------------------------------------------
# Methods ripped off from E80_Nave and/or FSH
# Not yet re-applied after reworking whole NAVQRY
# as well as a bunch of FSH stuff

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

	#   fsh old common waypoint record
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
	#
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
		# parses buf into array and hash using field specs


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
	# parses buf into array and hash using field specs
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