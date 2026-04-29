#---------------------------------------------
# a_utils.pm
#---------------------------------------------

package apps::raymarine::NET::a_utils;
use strict;
use warnings;
use threads;
use threads::shared;
use POSIX qw(floor pow atan tan);
use Time::HiRes qw(sleep);
use Wx qw(:everything);
use Pub::Utils;
use Pub::WX::AppConfig;
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_mon;



BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(

		setConsoleColor
		printConsole
		c_print

		enableOutputRing
		clearOutputRing
		pushOutputRing
		getOutputRingSeq
		getOutputRingSince
		getOutputRingTail

		clearLog
		writeLog

		name16_hex
		packRecord
		unpackRecord
		
		degreeMinutes
		northEastToLatLon
		latLonToNorthEast

		parse_dwords

		@console_color_names
		$console_color_values

		$wx_color_red
		$wx_color_green
		$wx_color_blue
		$wx_color_cyan
		$wx_color_magenta
		$wx_color_yellow
		$wx_color_dark_yellow
		$wx_color_grey
		$wx_color_purple
		$wx_color_orange
		$wx_color_white
		$wx_color_medium_cyan
		$wx_color_dark_cyan
		$wx_color_lime
		$wx_color_light_grey
		$wx_color_medium_grey

		@WPICON_TABLE
		%WPICON_BY_NAME

		$appClientName

    );
}






#--------------------------------
# main
#--------------------------------

our $appClientName = 'app';
our $appGroup = 'raymarine';
	# same data and temp directories for
	# shark and raynet (to become 'raynet')

# createSTDOUTSemaphore("sem$appGroup");
$USE_SHARED_LOCK_SEM = 1;

Pub::Utils::initUtils();

setStandardTempDir($appGroup);
setStandardDataDir($appGroup);





#---------------------------------------
# console colors
#---------------------------------------
# Map to $UTIL_COLORS of the same names

our @console_color_names = (
    'Default',
    'Blue',
    'Green',
    'Cyan',
    'Red',
    'Magenta',
    'Brown',
    'Light Gray',
    'Gray',
    'Light Blue',
    'Light Green',
    'Light Cyan',
    'Light Red',
    'Light Magenta',
    'Yellow',
    'White', );
our $console_color_values = { map { $console_color_names[$_] => $_ } 0..$#console_color_names };
	# $#array gives the last index of the array as opposed to @array which is the length in a scalar context
	# map takes a list and applies a block of code to each element, returning a new list.
	# The block of code is within the {} and $_ is each element of the elist is presented to the right
	# map {block} list

enableOutputRing(2000);



#-------------------------------------------
# WX colors
#-------------------------------------------

our $wx_color_red     	    = Wx::Colour->new(0xE0, 0x00, 0x00);
our $wx_color_green   	    = Wx::Colour->new(0x00, 0x60, 0x00);
our $wx_color_blue    	    = Wx::Colour->new(0x00, 0x00, 0xC0);
our $wx_color_cyan          = Wx::Colour->new(0x00, 0xE0, 0xE0);
our $wx_color_magenta       = Wx::Colour->new(0xC0, 0x00, 0xC0);
our $wx_color_yellow        = Wx::Colour->new(0xFF, 0xD7, 0x00);
our $wx_color_dark_yellow   = Wx::Colour->new(0xA0, 0xA0, 0x00);
our $wx_color_grey          = Wx::Colour->new(0x99, 0x99, 0x99);
our $wx_color_purple        = Wx::Colour->new(0x60, 0x00, 0xC0);
our $wx_color_orange        = Wx::Colour->new(0xC0, 0x60, 0x00);
our $wx_color_white         = Wx::Colour->new(0xFF, 0xFF, 0xFF);
our $wx_color_medium_cyan   = Wx::Colour->new(0x00, 0x60, 0xC0);
our $wx_color_dark_cyan     = Wx::Colour->new(0x00, 0x60, 0x60);
our $wx_color_lime  	    = Wx::Colour->new(0x50, 0xA0, 0x00);
our $wx_color_light_grey    = Wx::Colour->new(0xF0, 0xF0, 0xF0);
our $wx_color_medium_grey   = Wx::Colour->new(0xC0, 0xC0, 0xC0);



#------------------------------------------
# Waypoint Icons
#------------------------------------------
# E80 waypoint symbol (the 'sym' wire field).
# Empirically confirmed 2026-04-23 via direct WPMGR protocol writes to E80-4.
# ALL symbols are RED descriptions (from E80) unless the name says otherwise.
# sym >= 40 crashes E80 firmware (confirmed -- do not use).
# E80 only allows selection of 0..35 but disiplays 36..39 distinctly.
# RNS allows selection of 0..39 but displays 36..39 same as it does with 3 square.
# RNS displays them differently ; see table comments
#
# Structure: [ NAME, USEFUL, DESCRIPTION ]
#   NAME:    uppercase display label
#   USEFUL:  1 = distinct and meaningful for navMate UI
#            0 = indistinct or not meaningful
#   DESC:    additional detail for UI display ('' if none)

our @WPICON_TABLE = (
	# [ name,                          useful, description                ]  # sym
	[ 'X',                              1, ''                             ],  #  0
	[ 'CIRCLE',                         1, 'square in square on RNS'      ],  #  1
	[ 'SQUARE',                         1, ''                             ],  #  2
	[ 'UP TRIANGLE',                    1, ''                             ],  #  3
	[ 'DIAMOND',                        1, ''                             ],  #  4
	[ 'SHADED DIAMOND',                 1, 'like a compass rose'          ],  #  5
	[ 'ANCHOR',                         1, 'black on RNS'                 ],  #  6
	[ 'SKULL AND CROSSBONES',           1, 'black on RNS'                 ],  #  7
	[ 'SQUARE WITH X',                  1, ''                             ],  #  8
	[ 'UP TRIANGLE THING',              1, 'something inside'             ],  #  9
	[ 'DOWN TRIANGLE WITH T',           1, ''                             ],  # 10
	[ 'CIRCLE WITH M',                  1, 'RNS MOB small circle'         ],  # 11
	[ 'ROUNDED FILLED UP TRIANGLE',     1, ''                             ],  # 12
	[ 'SAILBOAT',                       1, 'blue on RNS'                  ],  # 13
	[ 'SHIPWRECK',                      1, ''                             ],  # 14
	[ 'COCKTAIL',                       1, ''                             ],  # 15
	[ 'SWIMMER',                        0, 'barely distinguishable'       ],  # 16
	[ 'CIRCLE WITH EXCLAMATION MARK',   1, 'red filled ATTENTION on RNS'  ],  # 17
	[ 'CLOUD WITH RAIN',                0, ''                             ],  # 18
	[ 'TREE WITH SQUIGGLY LINE',        0, ''                             ],  # 19
	[ 'FISH SWIMMING THROUGH WEEDS',    0, ''                             ],  # 20
	[ 'WEEDS',                          0, ''                             ],  # 21
	[ 'DIVE FLAG',                      1, ''                             ],  # 22
	[ 'WHITE AND BLUE FLAG',            1, 'International Dive Flag'      ],  # 23
	[ 'BIG FISH',                       1, 'blue on RNS'                  ],  # 24
	[ 'FISH',                           1, ''                             ],  # 25
	[ 'FISH WITH ONE STAR',             1, ''                             ],  # 26
	[ 'FISH WITH TWO STARS',            1, ''                             ],  # 27
	[ 'FISH WITH THREE STARS',          1, ''                             ],  # 28
	[ 'TWO FISH',                       1, ''                             ],  # 29
	[ 'SWORDFISH',                      1, ''                             ],  # 30
	[ 'DOLPHIN',                        1, ''                             ],  # 31
	[ 'SHARK',                          1, ''                             ],  # 32
	[ 'LOBSTER',                        0, 'black on RNS'                 ],  # 33
	[ 'SHIP TYPE 1',                    0, 'RNS Sportfisher'              ],  # 34
	[ 'SHIP TYPE 2',                    0, 'RNS Trawler'                  ],  # 35
	[ 'MAN OVERBOARD',                  1, 'person in water waving arms'  ],  # 36
	[ 'CIRCLE WITH S',                  1, ''                             ],  # 37
	[ 'CIRCLE WITH N',                  1, ''                             ],  # 38
	[ 'WHITE FILLED RED SQUARE',        1, ''                             ],  # 39
);

our %WPICON_BY_NAME = map { $WPICON_TABLE[$_][0] => $_ } 0..$#WPICON_TABLE;



#---------------------------------
# methods
#---------------------------------

sub name16_hex
	# return hex representation of max16 name + null
{
	my ($name,$no_delim) = @_;
	while (length($name) < 16) { $name .= "\x00" }
	$name .= "\x00" if !$no_delim;
	return unpack('H*',$name);
}


sub setConsoleColor
	# running in context of Pub::Utils; does not use ansi colors above
	# just sets the console to the given Pub::Utils::$DISPLAY_COLOR_XXX or $UTILS_COLOR_YYY
	# wheree XXX is NONE, LOG, ERROR, or WARNING and YYY are color names
	# if $utils_color not provide, uses $DISPLAY_COLOR_NONE to return to standard light grey
{
	my ($utils_color) = @_;
	$utils_color = $DISPLAY_COLOR_NONE if !defined($utils_color);
	Pub::Utils::_setColor($utils_color);
}


sub printConsole
	# print to the console and/or to the logfile
	# DONT write self-mons to the sniffer logfile
{
	my ($level,$mon,$color,$text) = @_;
	$mon ||= 0;

	if ($level)
	{
		my $hdr = pad('',9).'# '.pad('',($level-1)*4);
		$text = $hdr.$text;
	}
	
	if (!($mon & $MON_LOG_ONLY))
	{
		lock($local_stdout_sem);
		setConsoleColor($color) if $color;
		print $text."\n";
		setConsoleColor() if $color;
	}
	if ($mon & $MON_WRITE_LOG)
	{
		my $mon_src_sniffer = $mon & $MON_SRC_SHARK ? 0 : 1;
		my $mon_self_sniffed = $mon & $MON_SELF_SNIFFED ? 1 : 0;
		if (!$mon_src_sniffer || !$mon_self_sniffed)
		{
			my $output_file = $mon_src_sniffer ?
				"rns.log" : "shark.log";
			writeLog($text."\n",$output_file);
		}
	}
	pushOutputRing($text,$color);
}


sub c_print
	# Like print, but also pushes to the ring buffer so /api/log captures it.
	# Use this instead of bare print() anywhere in shark/NET so that application-level
	# output (show commands, query results, debug banners) is visible to HTTP clients
	# without needing to freeze/scroll the console window.
{
	my ($text) = @_;
	{
		lock($local_stdout_sem);
		print $text;
	}
	pushOutputRing($text,0);
}


sub clearLog
{
	my ($filename) = @_;
	my $path = "$temp_dir/log/$filename";
	if (open(AFILE,">$path"))
	{
		close AFILE;
	}
}

sub writeLog
{
	my ($text,$filename) = @_;
	my $path = "$temp_dir/log/$filename";
	if (open(AFILE,">>$path"))
	{
		print AFILE $text;
		close AFILE;
	}
}



sub degreeMinutes
{
	my $DEG_CHAR = chr(0xB0);
	my ($ll) = @_;
	my $deg = int($ll);
	my $min = round(abs($ll - $deg) * 60,3);
	return "$deg$DEG_CHAR$min";
}



#---------------------------------------------------
# northEast stuff
#---------------------------------------------------

my $FSH_LON_SCALE = 0x7fffffff;  # 2147483647
my $FSH_LAT_SCALE = 107.1709342;
	# Northing in FSH is prescaled by this (empirically determined)
	# Original comment said "probably 107.1710725 is more accurate, not sure"
	# but that makes mine worse, not better.


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
    my $longitude = ($east / $FSH_LON_SCALE) * 180.0;
    my $N = $north / $FSH_LAT_SCALE;

    # WGS84 ellipsoid parameters
    my $a = 6378137;  # semi-major axis
    my $e = 0.08181919;  # eccentricity

    # Iterative calculation for latitude
    my $phi = $PI_OVER_2;  # Initial guess
    my $phi0;
    my $IT_ACCURACY = 1.5E-8;
    my $MAX_IT = 32;
    my $i = 0;

    do {
        $phi0 = $phi;
        my $esin = $e * sin($phi0);
        $phi = $PI_OVER_2 - 2.0 * atan(exp(-$N / $a) * pow((1 - $esin) / (1 + $esin), $e / 2));
        $i++;
    } while (abs($phi - $phi0) > $IT_ACCURACY && $i < $MAX_IT);

    # Convert radians to degrees
    my $latitude = $phi * 180 / $PI;

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
    my $lat_rad = $lat_deg * $PI / 180.0;

    # Mercator projection formula for northing
    my $esin = $e * sin($lat_rad);
    my $N = $a * log(tan($PI / 4 + $lat_rad / 2) * ((1 - $esin) / (1 + $esin)) ** ($e / 2));

    # Apply FSH scaling
    my $north = int($N * $FSH_LAT_SCALE + 0.5);

    # Easting is linear
    my $east = int(($lon_deg / 180.0) * $FSH_LON_SCALE + 0.5);

    return {
        north => $north,
        east  => $east
    };
}


#----------------------------------------------------
# parse_dwords
#----------------------------------------------------


my $BYTES_PER_GROUP = 4;
my $GROUPS_PER_LINE = 8;
my $BYTES_PER_LINE	= $GROUPS_PER_LINE * $BYTES_PER_GROUP;
my $LEFT_SIZE = $GROUPS_PER_LINE * $BYTES_PER_GROUP * 2 + $GROUPS_PER_LINE;

sub parse_dwords
{
	my ($header,$raw_data,$multi) = @_;
	my $offset = 0;
	my $byte_num = 0;
	my $group_byte = 0;
	my $left_side = '';
	my $right_side = '';
	my $full_packet = $header;
	my $header_len = length($header);
	my $packet_len = length($raw_data);
	# $full_packet .= "\nONE($hex_data)\n" if $packet_len == 1;
	while ($offset < $packet_len)
	{
		$byte_num = $offset % $BYTES_PER_LINE;
		if ($offset && !$byte_num)
		{
			$full_packet .= $left_side.' # '.$right_side;
			$full_packet .= ' >>>' if !$multi;
			$full_packet .= "\n";
			$left_side = '';
			$right_side = '';
			$group_byte = 0;
			last if !$multi;
			$full_packet .= pad('',$header_len);
		}

		my $byte = substr($raw_data,$offset++,1);
		$left_side .= unpack('H2',$byte);
		$group_byte++;
		if ($group_byte == $BYTES_PER_GROUP)
		{
			$left_side .= ' ';
			$group_byte = 0;
		}
		$right_side .= ($byte ge ' ' && $byte le 'z') ? $byte : '.';
	}
	if ($left_side)
	{
		$full_packet .= pad($left_side,$LEFT_SIZE).' # '.$right_side."\n";
	}
	return $full_packet;
}





#-------------------------------------
# pack and unpack native records
#-------------------------------------
# fields within a field spec record; known by convention in field specs

my $PACK_DETAIL = 0;	# 0=actual data; 1=control stuff (name_len, etc); 2=unknown
my $PACK_SIZE	= 1;	# the size (for moving to the next piece of buffer
my $PACK_TYPE	= 2;	# the perl pack/unpack type


sub unpackRecord
	# All fields are packed/unpacked into the reccord so that
	# 	the operations are symetrical and no information is lost
	# $level is merely used to adjust what things show in debugging
{
	my ($mon,				# monitoring bits  passed in by client
		$color,				# color passed in by client
		$name,				# a name given to the record
		$field_specs,		# REQUIRED the field specs that define the record
		$buffer,			# REQUIRED raw data being unpacked
		$rec_offset,		# REQUIRED offset into the buffer to parse at
		$rec_size) = @_;	# the record size, if defined, will show the raw data bytes at $dbg+1
	

	printConsole(3,$mon,$color,"unpackRecord($name) offset($rec_offset) rec_size("._def($rec_size).")")
		if $mon & $MON_PACK;

	my $data = substr($buffer,$rec_offset,$rec_size) if defined($rec_size);
	printConsole(4,$mon,$color,"data=".unpack('H*',$data))
		if $mon & $MON_PACK_UNKNOWN;

	my $offset = 0;
	my $rec = shared_clone({});
	my $num_specs = scalar(@$field_specs) / 2;
	for (my $i=0; $i<$num_specs; $i++)
	{
		my $field = $field_specs->[$i * 2];
		my $spec = $field_specs->[$i * 2 + 1];
		my ($detail,$size,$type) = @$spec;

		my $raw  = substr($data,$offset,$size);
		my $hex  = unpack('H*',$raw);
		my $val  = unpack($type,$raw);

		my $showit =
			$detail == 2 ? $mon & $MON_PACK_UNKNOWN :
			$detail == 1 ? $mon & $MON_PACK_CONTROL :
			$mon & $MON_PACK;

		$rec->{$field} = defined($val) ? $val : 0;
		printConsole(4,$mon,$color,pad("offset($offset)",11).' '.pad($field,12).' '.pad("($hex)",12)." = '$rec->{$field}'")
			if $showit;
		$offset += $size;
	}
	return $rec;
}


sub packRecord
	# builds the record WITHOUT the big_len field
{
	my ($mon,$color,$name,$rec,$field_specs) = @_;
	$rec ||= {};

	printConsole(3,$mon,$color,"packRecord($name)")
		if $mon & $MON_PACK;

	my $data = '';
	my $offset = 0;
	my $num_specs = scalar(@$field_specs) / 2;
	for (my $i=0; $i<$num_specs; $i++)
	{
		my $field = $field_specs->[$i * 2];
		next if $field eq 'big_len';
		my $spec = $field_specs->[$i * 2 + 1];
		my ($detail,$size,$type) = @$spec;

		my $val  = $rec->{$field};
		$val = 0 if !defined($val);
		my $packed .= pack($type,$val);
		$data .= $packed;

		my $showit =
			$detail == 2 ? $mon & $MON_PACK_UNKNOWN :
			$detail == 1 ? $mon & $MON_PACK_CONTROL :
			$mon & $MON_PACK;

		$rec->{$field} = defined($val) ? $val : 0;
		printConsole(4,$mon,$color,pad("offset($offset)",11).' '.pad($field,12).' '.pad("(".unpack('H*',$packed).")",12)." = '$val'")
			if $showit;

		$offset += $size;
	}

	if ($mon & $MON_PACK_UNKNOWN)
	{
		printConsole(4,$mon,$color,"data=".unpack('H*',$data));
	}

	return $data;
}



1;
