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

		@E80_SYMS

		$E80_SYM_X
		$E80_SYM_CIRCLE
		$E80_SYM_SQUARE
		$E80_SYM_TRIANGLE
		$E80_SYM_DIAMOND
		$E80_SYM_SHADED_DIAMOND
		$E80_SYM_ANCHOR
		$E80_SYM_SKULL
		$E80_SYM_SQUARE_X
		$E80_SYM_TRIANGLE_I
		$E80_SYM_DOWN_TRI_T
		$E80_SYM_CIRCLE_M
		$E80_SYM_BUOY
		$E80_SYM_SAILBOAT
		$E80_SYM_SHIPWRECK
		$E80_SYM_COCKTAIL
		$E80_SYM_SWIMMER
		$E80_SYM_EXCLAMATION
		$E80_SYM_CLOUD
		$E80_SYM_TREE
		$E80_SYM_REEF
		$E80_SYM_WEEDS
		$E80_SYM_DIVE_FLAG
		$E80_SYM_BLUE_FLAG
		$E80_SYM_BIG_FISH
		$E80_SYM_FISH
		$E80_SYM_FISH_STAR
		$E80_SYM_FISH_TWO_STAR
		$E80_SYM_FISH_THREE_STAR
		$E80_SYM_TWO_FISH
		$E80_SYM_SWORDFISH
		$E80_SYM_DOLPHIN
		$E80_SYM_SHARK
		$E80_SYM_LOBSTER
		$E80_SYM_SPORTFISHEER
		$E80_SYM_TRAWLER

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
# E80 only allows selection of 0..35 but displays 36..39 distinctly.
# RNS allows selection of 0..39 but displays 36..39 same as it does with 3 square.
# RNS displays them differently ; see table comments

our $E80_SYM_X               =  0;
our $E80_SYM_CIRCLE          =  1;  # square in square on RNS
our $E80_SYM_SQUARE          =  2;
our $E80_SYM_TRIANGLE        =  3;  # points up
our $E80_SYM_DIAMOND         =  4;
our $E80_SYM_SHADED_DIAMOND  =  5;  # like a compass rose
our $E80_SYM_ANCHOR          =  6;  # black on RNS
our $E80_SYM_SKULL           =  7;  # skull & crosbones, RNS=black
our $E80_SYM_SQUARE_X        =  8;  # square with X in it
our $E80_SYM_TRIANGLE_I      =  9;  # tri up with i inside
our $E80_SYM_DOWN_TRI_T      = 10;  # tri down with a T inside
our $E80_SYM_CIRCLE_M        = 11;  # RNS MOB small circle
our $E80_SYM_BUOY            = 12;  # looks like a buoy or similar
our $E80_SYM_SAILBOAT        = 13;  # blue on RNS
our $E80_SYM_SHIPWRECK       = 14;
our $E80_SYM_COCKTAIL        = 15;
our $E80_SYM_SWIMMER         = 16;  # barely distinguishable
our $E80_SYM_EXCLAMATION     = 17;  # circle with excl mark; red filled on RNS
our $E80_SYM_CLOUD           = 18;  # cloud with rain falling
our $E80_SYM_TREE            = 19;  # with squiggly line
our $E80_SYM_REEF            = 20;  # fish swimming through weeds
our $E80_SYM_WEEDS           = 21;
our $E80_SYM_DIVE_FLAG       = 22;
our $E80_SYM_BLUE_FLAG       = 23;  # International Dive Flag
our $E80_SYM_BIG_FISH        = 24;  # blue on RNS
our $E80_SYM_FISH            = 25;
our $E80_SYM_FISH_STAR       = 26;
our $E80_SYM_FISH_TWO_STAR   = 27;
our $E80_SYM_FISH_THREE_STAR = 28;
our $E80_SYM_TWO_FISH        = 29;
our $E80_SYM_SWORDFISH       = 30;
our $E80_SYM_DOLPHIN         = 31;
our $E80_SYM_SHARK           = 32;
our $E80_SYM_LOBSTER         = 33;  # black on RNS
our $E80_SYM_SPORTFISHEER    = 34;  # RNS Sportfisher
our $E80_SYM_TRAWLER         = 35;  # RNS Trawler

# following four are kept for posterities sake

our $E80_SYM_MAN_OVERBOARD   = 36;  # person in water waving arms
our $E80_SYM_CIRCLE_S        = 37;
our $E80_SYM_CIRCLE_N        = 38;
our $E80_SYM_BIG_RED_SQUARE  = 39;


our @E80_SYMS = (
    'X',                #  0
    'CIRCLE',           #  1
    'SQUARE',           #  2
    'TRIANGLE',         #  3
    'DIAMOND',          #  4
    'SHADED_DIAMOND',   #  5
    'ANCHOR',           #  6
    'SKULL',            #  7
    'SQUARE_X',         #  8
    'TRIANGLE_I',       #  9
    'DOWN_TRI_T',       # 10
    'CIRCLE_M',         # 11
    'BUOY',             # 12
    'SAILBOAT',         # 13
    'SHIPWRECK',        # 14
    'COCKTAIL',         # 15
    'SWIMMER',          # 16
    'EXCLAMATION',      # 17
    'CLOUD',            # 18
    'TREE',             # 19
    'REEF',             # 20
    'WEEDS',            # 21
    'DIVE_FLAG',        # 22
    'BLUE_FLAG',        # 23
    'BIG_FISH',         # 24
    'FISH',             # 25
    'FISH_STAR',        # 26
    'FISH_TWO_STAR',    # 27
    'FISH_THREE_STAR',  # 28
    'TWO_FISH',         # 29
    'SWORDFISH',        # 30
    'DOLPHIN',          # 31
    'SHARK',            # 32
    'LOBSTER',          # 33
    'SPORTFISHEER',     # 34
    'TRAWLER',          # 35

	# The following four show, but cannot be selected on the E80

	#	'MAN_OVERBOARD',    # 36
    #	'CIRCLE_S',         # 37
    #	'CIRCLE_N',         # 38
    #	'BIG_RED_SQUARE',   # 39
);



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
