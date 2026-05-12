#--------------------------------------
# fshBlocks.pm
#--------------------------------------
# Based on the C code at https://github.com/rahra/parsefsh
#
# See PRH NEWLY DISCOVERED for fields I've found that parseFSH
# didn't know about.
#
# This code mimics the C data structures from the parsefsh C
# code using perl unpack() calls.
#
# Takes $all_blocks from fshFileToBlocks() and processes
# them into tracks, waypoints, etc, to be iterated through
# by fshToGpx.pm for final output.
#
# In the files produced by my E80, for tracks, there is always
# an BLK_MTA block that follows, and references, each BLK_TRK,
# so we are able to do this as a one time pass through the blocks.
#
# Because of this combination, the MTA becomes the {tracks} record
# and the points from the TRK are merged into it's {points} member.
# The {track} carries both the {mta_uuid} and the {trk_uuid} and
# the MTA_UUID IS USED CONSISTENTLY THROUGHOUT THE SYSTEMS AS
# THE IDENTITY UUID.
#
# A proper implementation would parse all the BLK_TRK blocks first,
# and then allow for the MTAs to reference possible multiple BLK_TRACKS
# by uuid as the data structure implies.

# The E80 uses the archive to keep a full revision history of all
# WGRTs inside the ARCHIVE.FSH file.  Each save appends new blocks
# and marks the previous versions deleted via the active field
# (0x4000 = active, 0x0000 = deleted).  Parsing into a hash by UUID
# keeping only the last ACTIVE block gives the current state.
#
# The active field is how the E80 knows records are deleted.
# There are a number of changes from the 'sole' version that
# exists in memory in shark's WPMGR gotten Route, specifically
#
#	u2_0200 is always '02000000' on the E80 (in shark); it is always '00000000' in the FSH
#	u3 is always the  'b8975601' on the E80,           and is always '00000000' in the FSH
#	u6 is always      'c81c'     on the E80,           and always    '2100'	    in the FSH
#
# but most importantly
#		u4_self and u5_self area ALWAYS THE SELF_UUID on the E80
#		but appear to be SOMETHING ELSE IN THE FSH
#
# Somehow these MUST (?) be marked as free space, because if you delete everything from
# the ARCHIVE.FSH on the E80, the E80 KNOWS, on a fresh boot that it's 'EMPTY'.
# Jeez. 

#--------------------------------------
# WRITING FSH FILES
#--------------------------------------
# fshFile.pm::writeBlock() honors the active flag on every block:
#   $block->{active} ? $FLOB_ACTIVE : 0
# So a client has full control over which blocks are written as
# active and which are written as deleted (revision markers).
#
# Two write modes are available depending on ACTIVE_BLOCKS_ONLY
# in fshFile.pm:
#
# COMPACT REWRITE (ACTIVE_BLOCKS_ONLY = 1, current default):
#   Read only active blocks into $this->{blocks}.
#   Encode new/modified records (createBlock appends them as active).
#   write() produces a clean file with no deleted blocks.
#   This is what kmlToFSH does.
#
# HISTORY-PRESERVING REWRITE (ACTIVE_BLOCKS_ONLY = 0):
#   Read ALL blocks (active and deleted) into $this->{blocks}.
#   To modify a record: find the existing block by UUID+type,
#     set $block->{active} = 0, then encode the replacement
#     (createBlock appends it as active).
#   write() produces a valid FSH with the old block written as
#   deleted and the new block appended after it -- correct
#   Raymarine archive semantics with full history preserved.
#
# Missing helper: a findBlock($uuid_str, $type) sub that searches
# $this->{blocks} for a specific UUID+type and returns it.
# Everything else needed for history-preserving read-modify-write
# is already in place.

package apps::raymarine::FSH::fshFile;		# continued
use strict;
use warnings;
use POSIX qw(floor pow atan);
use Fcntl qw(:seek);
use Time::Local;
use Pub::Utils;
use apps::raymarine::FSH::fshUtils;


my $dbg_block = 0;
my $dbg_trk = 1;
my $dbg_mta = 1;
my $dbg_wpt = 1;
my $dbg_rte = 1;
my $dbg_grp = 1;

my $dbg_wblock = -1;
my $dbg_wtrk = 1;
my $dbg_wmta = 1;
my $dbg_wwpt = 1;
my $dbg_wrte = 1;
my $dbg_wgrp = 1;



my $LL_SCALE_FACTOR = 1e7;
my $PI = 3.14159265358979323846;
our $METERS_PER_NM 	= 1852;

# parsed blocks

#	my $track_points = {};  # BLK_TRK are parsed into arrays of points by uuid
#	my $tracks = [];        # BLK_MTA track meta info records ARE the 'tracks'
#	    # E80 BLK_MTA's always come after their BLK_TRKS, so we can do
#	    # everything in a single loop through all blocks.  For each BLK_MTA
#	    # we find the track_points based on the MTA's 1st (only) sub-uuid,
#	    # and set the {points} member on the "track" record from that.
#	my $waypoints = [];          # BLK_WPT recs from the inner common_waypoint
#	    # with {uuid} and {inner_uuid} members added to by the block
#	my $routes = [];		# BLK_RTE very complicated data structures,
#		# but each record has, at least, a NAME, possible COMMENT, and
#		# an array of {wpts}
#	my $groups = [];
#		# groups have a name element and a {wpts} array
#		# the waypoints have a {int_lat, and int_lon} members
#		# which are the actual values * 1E7, as opposed to the
#		# mercator projectsion lat/lon from northEastToLatLon()


sub getTracks			{ my ($this) = @_; return $this->{tracks}; }
sub getWaypoints()		{ my ($this) = @_; return $this->{waypoints}; }
sub getRoutes()			{ my ($this) = @_; return $this->{routes}; }
sub getGroups()			{ my ($this) = @_; return $this->{groups}; }




sub decodeBlock
    # dispatcher based on block type
{
    my ($this,$block) = @_;
    my $type = $block->{type};

    display($dbg_block+1,0,"decodeBlock[$block->{num}] ".blockTypeToStr($type)."(".uuidToStr($block->{uuid}).")");
    return 0 if $type == $FSH_BLK_TRK && !$this->decodeTRK($block);
    return 0 if $type == $FSH_BLK_MTA && !$this->decodeMTA($block);
    return 0 if $type == $FSH_BLK_WPT && !$this->decodeWPT($block);
    return 0 if $type == $FSH_BLK_RTE && !$this->decodeRTE($block);
    return 0 if $type == $FSH_BLK_GRP && !$this->decodeGRP($block);
    return 1;
}


sub createBlock
{
	my ($this,$uuid_str,$type,$bytes) = @_;
	my $uuid = strToUuid($uuid_str);
	my $show_type = blockTypeToStr($type);
	my $len = length($bytes);
	my $num = @{$this->{blocks}};

	display(0,0,"createBlock($show_type) num($num) uuid($uuid_str) len($len)");
	push @{$this->{blocks}}, {
		num		=> $num,
		active 	=> 1,
		uuid 	=> $uuid,
		type 	=> $type,
		bytes 	=> $bytes, };
}


#---------------------------------------------
# TRK
#---------------------------------------------

my $TRACK_HEADER_SIZE = 8;
my $TRACK_POINT_SIZE = 14;


sub decodeTRK     # parse into array of points in track_points
	# Odd that nothing on a track has a date-time ...
{
    my ($this,$block) = @_;
    my $uuid = $block->{uuid};
    display($dbg_block,0,"decodeTRK[$block->{num}] ".uuidToStr($uuid));

	my $offset = 0;
	my $bytes = $block->{bytes};
	my ($a,$point_count,$b) = unpack('lss',substr($bytes,$offset,$TRACK_HEADER_SIZE));
		# 	int32_t a;        // unknown, always 0
		# 	int16_t cnt;      // number of track points
		# 	int16_t b;        // unknown, always 0
	$offset += $TRACK_HEADER_SIZE;
	display($dbg_trk,1,"point_count($point_count)  ($a,$b)");

    my $points = [];
	for (my $i=0; $i<$point_count; $i++)
	{
		my $point_str = substr($bytes,$offset,$TRACK_POINT_SIZE);
		$offset += $TRACK_POINT_SIZE;
		my ($north,$east,$temp,$depth,$c) = unpack('llSss',$point_str);
			# 	int32_t north, east; // prescaled (FSH_LAT_SCALE) northing and easting (ellipsoid Mercator)
			# 	uint16_t tempr;      // temperature in Kelvin * 100
			# 	int16_t depth;       // depth in cm
			# 	int16_t c;           // unknown, always 0
        my $coords = northEastToLatLon($north,$east);

		if ($dbg_trk < 0)
		{
			my $d_ft = sprintf('%.1fft', $depth / 30.48);
			my $t_f  = sprintf('%.1fF', ($temp / 100 - 273) * 9 / 5 + 32);
			display($dbg_trk+1,2,sprintf("  %2d  %9.6f  %10.6f  %7s  %s",
				$i + 1, $coords->{lat}, $coords->{lon}, $d_ft, $t_f));
		}

		
        my $point = {
            north   => $north,
            east    => $east,
            temp    => $temp,
            depth   => $depth,
            lat     => $coords->{lat},
            lon     => $coords->{lon}, };
        push @$points,$point;
	}

    $this->{track_points}->{$uuid} = $points;
    return 1;

}	# decodeTRK()



sub encodeTRK
{
    my ($this,$rec) = @_;
		# trk_uuid	REQUIRED
		# points	REQUIRED

	my $points = $rec->{points};
	my $num_points = @$points;
	display($dbg_wblock,0,"encodeTRK() trk_uuid=$rec->{trk_uuid} num_points=$num_points");

	my $bytes = pack('lss',0,$num_points,0);
		# 	int32_t a;        // unknown, always 0
		# 	int16_t cnt;      // number of track points
		# 	int16_t b;        // unknown, always 0

	for (my $i=0; $i<$num_points; $i++)
	{
		my $point = $$points[$i];
		my $coords = latLonToNorthEast($point->{lat},$point->{lon});
		$bytes .= pack('llSss',$coords->{north},$coords->{east},0,$point->{depth},0);
			# 	int32_t north, east; // prescaled (FSH_LAT_SCALE) northing and easting (ellipsoid Mercator)
			# 	uint16_t tempr;      // temperature in Kelvin * 100
			# 	int16_t depth;       // depth in cm
			# 	int16_t c;           // unknown, always 0
	}

	$this->createBlock($rec->{trk_uuid},$FSH_BLK_TRK,$bytes);
    return 1;

}	# encodeTRK()





#---------------------------------------------
# MTA
#---------------------------------------------

my $MTA_HEADER_SIZE = 58;
my $MTA_FIELD_SPECS = [             # typedef struct fsh_track_meta     // total length 58 + uuid_cnt * 8 bytes
	k1_1         => 'c',        #   0     char a;                   // always 0x01
	cnt          => 's',        #   1     int16_t cnt;              // number of track points
	_cnt         => 's',        #   3     int16_t _cnt;             // same as cnt
	k2_0         => 's',        #   5     int16_t b;                // unknown, always 0
	length       => 'l',        #   7     int32_t length;           // approx. track length in m
	north_start  => 'l',        #   11    int32_t north_start;      // Northing of first track point
	east_start   => 'l',        #   15    int32_t east_start;       // Easting of first track point
	temp_start   => 'S',        #   19    uint16_t tempr_start;     // temperature of first track point
	depth_start  => 'l',        #   21    int32_t depth_start;      // depth of first track point
	north_end    => 'l',        #   25    int32_t north_end;        // Northing of last track point
	east_end     => 'l',        #   29    int32_t east_end;         // Easting of last track point
	temp_end     => 'S',        #   33    uint16_t tempr_end;       // temperature last track point
	depth_end    => 'l',        #   35    int32_t depth_end;        // depth of last track point
	color        => 'c',        #   39    char col;                 /* track color: 0 - red, 1 - yellow, 2 - green, 3 -#blue, 4 - magenta, 5 - black */
	name         => 'Z16',      #   40    char name[16];            // name of track, string not terminated
	u1           => 'C',        #   56    char j;                   // unknown, never 0 in my files, always 0 according to parsefsh
	uuid_cnt     => 'c',        #   57    uint8_t uuid_cnt;         // nr of uuids following this header (always 1 in my files)
];


sub decodeMTA
	# In my E80 ARCHIVE.FSH's, 'j' is never 0, and it looks the name is
	# actually be 16 bytes, with junk after a null terminator.  All of my MTAs
	# have exactly one uuid which is always the uuid of the previous BLK_TRK.
{
    my ($this,$block) = @_;
    my $uuid = $block->{uuid};
    my $dbg_str = "[$block->{num}]] ".uuidToStr($uuid);
    display($dbg_block,0,"decodeMTA$dbg_str");

	my $bytes = $block->{bytes};
	display_bytes($dbg_mta+1,1,"bytes",$bytes);

	# Note that Z16 removes trailing nulls and garbage from strings
	# And once again, no date-time on a track!!
    # uuid_cnt is always exactly 1 for E80 ARCHIVE.FSH's
    
	my $rec = unpackRecord($dbg_mta+1,$MTA_FIELD_SPECS,$bytes);
    if ($rec->{uuid_cnt} != 1)
    {
        error("MTA$dbg_str has $rec->{uuid_cnt} track uuid's!");
        return 0;
    }

	$rec->{mta_uuid} = uuidToStr($uuid);

	my $offset = $MTA_HEADER_SIZE;
    my $track_uuid = unpack('a8',substr($bytes,$offset,$UUID_SIZE));
    my $track_uuid_str = uuidToStr($track_uuid);

    display($dbg_mta,1,"track name($rec->{name}) uuid = $track_uuid_str");
	$rec->{trk_uuid} =$track_uuid_str;

    my $points = $this->{track_points}->{$track_uuid};
    if (!$points)
    {
        error("Could not find track_points($track_uuid_str) on MTA$dbg_str");
        return 0;
    }

	# decodeMTA actually creates the entire fshFile->{track}

    $rec->{points} = $points;
    $rec->{active} = $block->{active} ? 1 : 0;
    push @{$this->{tracks}},$rec;
    return 1;

}	# decodeMTA()






sub encodeMTA  # create an MTA
{
    my ($this,$rec) = @_;
		# name			REQUIRED
		# mta_uuid		REQUIRED
		# trk_uuid		REQUIRED
		# color			default(0)
		# points		REQUIRED
		# length		default(0) track length in meters
		

		# k1_1         => 'c',        #   0     char a;                   // always 0x01
		# cnt          => 's',        #   1     int16_t cnt;              // number of track points
		# _cnt         => 's',        #   3     int16_t _cnt;             // same as cnt
		# k2_0         => 's',        #   5     int16_t b;                // unknown, always 0
		# length       => 'l',        #   7     int32_t length;           // approx. track length in m
		# north_start  => 'l',        #   11    int32_t north_start;      // Northing of first track point
		# east_start   => 'l',        #   15    int32_t east_start;       // Easting of first track point
		# temp_start   => 'S',        #   19    uint16_t tempr_start;     // temperature of first track point
		# depth_start  => 'l',        #   21    int32_t depth_start;      // depth of first track point
		# north_end    => 'l',        #   25    int32_t north_end;        // Northing of last track point
		# east_end     => 'l',        #   29    int32_t east_end;         // Easting of last track point
		# temp_end     => 'S',        #   33    uint16_t tempr_end;       // temperature last track point
		# depth_end    => 'l',        #   35    int32_t depth_end;        // depth of last track point
		# color        => 'c',        #   39    char col;                 /* track color: 0 - red, 1 - yellow, 2 - green, 3 -#blue, 4 - magenta, 5 - black */
		# name         => 'Z16',      #   40    char name[16];            // name of track, string not terminated
		# u1           => 'C',        #   56    char j;                   // unknown, never 0 in my files, always 0 according to parsefsh
		# uuid_cnt     => 'c',        #   57    uint8_t uuid_cnt;         // nr of uuids following this header (always 1 in my files)

	my $points = $rec->{points};
	my $num_points = @$points;
	display($dbg_wblock,0,"encodeMTA($rec->{name}) mta=$rec->{mta_uuid} trk=$rec->{trk_uuid} num_points=$num_points");

	$rec->{color} ||= 0;
	$rec->{length} ||= 0;

	# zero points = zeros for stuff below
	# one point  = same start and end
	# two+ points = different start and end

	my $north_start = 0;
	my $east_start 	= 0;
	my $depth_start	= 0;
	my $north_end  	= 0;
	my $east_end   	= 0;
	my $depth_end  	= 0;
	if ($num_points)
	{
		my $pt1 = $$points[0];
		my $pt2 = $$points[$num_points-1];
		my $coords = latLonToNorthEast($pt1->{lat},$pt1->{lon});
		$north_start = $coords->{north};
		$east_start = $coords->{east};
		$depth_start = $pt1->{depth};
		$coords = latLonToNorthEast($pt2->{lat},$pt2->{lon});
		$north_end = $coords->{north};
		$east_end = $coords->{east};
		$depth_end = $pt1->{depth};
	}

	my $name = $rec->{name};
	my $name_len = length($name);
	if ($name_len > 16)
	{
		$name = substr($name,0,16);
	}
	elsif ($name_len < 16)
	{
		$name .= ' ' x (16-$name_len);
	}

	my $mta_rec = {
		k1_1         => 0x01,			# => 'c',        #   0     char a;                   // always 0x01
		cnt          => $num_points,	# => 's',        #   1     int16_t cnt;              // number of track points
		_cnt         => $num_points,	# => 's',        #   3     int16_t _cnt;             // same as cnt
		k2_0         => 0,				# => 's',        #   5     int16_t b;                // unknown, always 0
		length       => 10000,	# test value	$rec->{length},	# => 'l',        #   7     int32_t length;           // approx. track length in m
		north_start  => $north_start,	# => 'l',        #   11    int32_t north_start;      // Northing of first track point
		east_start   => $east_start,	# => 'l',        #   15    int32_t east_start;       // Easting of first track point
		temp_start   => 0,				# => 'S',        #   19    uint16_t tempr_start;     // temperature of first track point
		depth_start  => $depth_start,	# => 'l',        #   21    int32_t depth_start;      // depth of first track point
		north_end    => $north_end,		# => 'l',        #   25    int32_t north_end;        // Northing of last track point
		east_end     => $east_end,		# => 'l',        #   29    int32_t east_end;         // Easting of last track point
		temp_end     => 0,				# => 'S',        #   33    uint16_t tempr_end;       // temperature last track point
		depth_end    => $depth_end,		# => 'l',        #   35    int32_t depth_end;        // depth of last track point
		color        => $rec->{color},	# => 'c',        #   39    char col;                 /* track color: 0 - red, 1 - yellow, 2 - green, 3 -#blue, 4 - magenta, 5 - black */
		name         => $name,			# => 'Z16',      #   40    char name[16];            // name of track, string not terminated
		u1           => 204,	# 204 for mtas in my ARCHIVE.FSH			# => 'C',        #   56    char j;                   // unknown, never 0 in my files, always 0 according to parsefsh
		uuid_cnt     => 1,				# => 'c',        #   57    uint8_t uuid_cnt;         // nr of uuids following this header (always 1 in my files)
	};


	my $bytes = packRecord($dbg_wmta+1,$MTA_FIELD_SPECS,$mta_rec);
	$bytes .= strToUuid($rec->{trk_uuid});

	# encodeMTA adds the BLK_MTA to the fshFile but
	# does not add the BLK_TRK which must precede it.

	$this->createBlock($rec->{mta_uuid},$FSH_BLK_MTA,$bytes);
	return 1;

}	# encodMTA()



#--------------------------------------------
# commonWaypoint
#--------------------------------------------

my $WPT_HEADER_SIZE = 48;
my $WPT_FIELD_SPECS = [             # typedef struct fsh_wpt_data; total length 40 bytes + name_len + cmt_len
	lat			=> 'l',			#   0								// 1E7 lat
	lon			=> 'l',			#   4
	north  		=> 'l',         #   8   int32_t north
	east   		=> 'l',         #   12   int32_t east; 				// prescaled ellipsoid Mercator northing and easting
	k1_0x12     => 'A12',       #   16   char d[12];         		// 12x \0
	sym         => 'C',         #   28  char sym;           		// probably symbol
	temp        => 'S',         #   29  uint16_t tempr;     		// temperature in Kelvin * 100
	depth       => 'l',         #   31  int32_t depth;      		// depth in cm
	time        => 'L',         #   35  uint32_t timeofday;  		// time of day in seconds
	date        => 'S',         #   39  uint16_t date;       		// days since 1.1.1970
	k2_0        => 'C',         #   41  char i;             		// unknown, always 0
	name_len    => 'C',         #   42  char name_len;      		// length of name array
	cmt_len     => 'C',         #   43  char cmt_len;       		// length of comment
	k3_0     	=> 'L',         #   44  int32_t j;                  // unknown, always 0
];


sub decodeCommonWaypoint
    # common to BLK_WPT and ....
	# It turns out that the code I borrowed was a bit wrong here.
	# The common waypoint record starts two words earlier, with
	# a more accurate 1e7 lat and lon.  It is better than the
	# northing/easting and mercator projection math.
{
	my ($dbg,$bytes,$offset,$uuid) = @_;
	my $wpt_header = substr($bytes,$offset,$WPT_HEADER_SIZE);
	display_bytes($dbg+3,1,"wpt_header",$wpt_header);

	# offsets shown are from borrowed schema; actual are +8


    # follows are name_len bytes of name string and cmt_len bytes of comment text

	my $rec = unpackRecord($dbg+2,$WPT_FIELD_SPECS,$wpt_header);
	$rec->{lat} /= $LL_SCALE_FACTOR;
	$rec->{lon} /= $LL_SCALE_FACTOR;

	$offset += $WPT_HEADER_SIZE;
	$rec->{uuid} = uuidToStr($uuid);

	my $name = $rec->{name_len} ? substr($bytes,$offset,$rec->{name_len}) : '';
	$offset += $rec->{name_len};
	my $comment = $rec->{cmt_len} ? substr($bytes,$offset,$rec->{cmt_len}) : '';
	$rec->{name} = $name;
	$rec->{comment} = $comment;

	# my $coords = northEastToLatLon($rec->{north},$rec->{east});
	# my $lat = $coords->{lat};
	# my $lon = $coords->{lon};
    # $rec->{lat} = $lat;
    # $rec->{lon} = $lon;

	my $show_lat = degreesWithMinutes('lat',$rec->{lat});
	my $show_lon = degreesWithMinutes('lon',$rec->{lon});
	my $show_time = fshDateTimeToStr($rec->{date},$rec->{time});

	display($dbg,1,"WP(".uuidToStr($uuid).")      ".$show_time."         ".$name);
	display($dbg,2,pad("lat($rec->{lat})=$show_lat",26)." lon($rec->{lon})=$show_lon");
	display($dbg,2,"COMMENT='$comment'") if $comment;

	display_hash($dbg+2,2,"wpt record",$rec);
	return $rec;

}	# decodeCommonWaypoint()



#------------------------------------
# WPT
#------------------------------------

sub decodeWPT
{
    my ($this,$block) = @_;
    my $uuid = $block->{uuid};
    display($dbg_block,0,"decodeWPT[$block->{num}]]");

	my $bytes = $block->{bytes};
	display_bytes($dbg_wpt+2,1,"bytes",$bytes);
	my $wpt = decodeCommonWaypoint($dbg_wpt,$bytes,0,$uuid);
    $wpt->{active} = $block->{active} ? 1 : 0;
    push @{$this->{waypoints}},$wpt;
    return 1;

}	# decodeWPT()



#------------------------------------
# RTE
#------------------------------------
# I don't know why he uses int16_t for enumerations
# I generally use 'C','S', and 'L', prefering unsigned unless
# the number can truly be negative.  This record starts AFTER
# the big_len in NAVQRY ethernet ROUTE BUFFER messages.

my $RTE_HDR1_SIZE = 8;
my $RTE_HDR2_SIZE = 46;
my $RTE_PT_SIZE = 10;
my $RTE_HDR3_SIZE = 4;


my $RTE_HDR1_SPECS = [
	u1_0		=> 'H4',		# 0	 int16_t a;        	// unknown, always 0
	name_len	=> 'C',			# 2	 char name_len;    	// length of name of route
	cmt_len		=> 'C',			# 3	 char cmt_len;     	// length of comment
	uuid_cnt	=> 'v',			# 4	 int16_t uuid_cnt; 	// number of uuids following this header
	bits		=> 'H2',		# 6	 uint8_t b;       	// unknown, 1=temporary; 2=don't transfer to RNS?
	color		=> 'C',			# 7	 uint8_t color;		// NEWLY DISCOVERED: color index (red, yellow, green, blue, purple, black)
];

my $RTE_HDR2_SPECS = [
	lat_start	=> 'l',			# 0   int32_t lat0;
	lon_start	=> 'l',         # 4   int32_t lon0;  		// lat/lon of first waypoint
	lat_end		=> 'l',         # 8   int32_t lat1;
	lon_end		=> 'l',         # 12  int32_t lon1;  		// lat/lon of last waypoint
	distance	=> 'V',         # 16  uint32_t distance;	// PRH NEWLY DISCOVERED: distance of route in meters
	u2_0200	    => 'H8',		# 20  02000000 number?
	u3		    => 'H8',        # 24  b8975601 data? end marker?
	u4_self	    => 'H16',       # 28  self uuid dc82990f f567e68e
	u5_self	    => 'H16',       # 36  self uuid dc82990f f567e68e
	u6		    => 'H4',        # 44  unknown
];

# parseFSH had these points entirely wrong.
# I believe I have discovered their true structure
# This whole structure is PRH NEWLY DISCOVERED

my $RTE_PT_SPECS = [
	bearing		=> 'v',			# 0	 int16_t bearing;			// radians � 10,000 - bearing from previous waypoint; converted to degrees
	legLength	=> 'V',			# 2	 uint32_t leg_length;        // meters - from previous waypoint;
	totLength	=> 'V',			# 4	 uint32_t tot_length;        // meters - cumulative for route;
];


my $RTE_HR3_SPECS = [
	wpt_cnt		=> 'S',			# 0	int16_t wpt_cnt;  	// number of waypoints
	k3_0		=> 'S',			# 2	int16_t a;        	// always 0
];



sub decodeRTE
	# From https://wiki.openstreetmap.org/wiki/ARCHIVE.FSH
	# This complicated block appears to be made up of
	# 	- an fsh_route21_header,
	#   - uuid_cnt uuids
	#   - an fsh_hdr2,
	#   - an array of uuid_cnt 10 byte fsh_pt's
	#   - an fsh_hdr3
	#   - an array of common waypoints, each preceded by TWO uuids
	# This code is a glom and the TWO uuids approach was determined
	# 	semi-empirically and from notes on the above page, where it
	# 	appears that the common waypoints are bracketed by three different
	# 	wrappers depending on what kind of block they are in
	# In detail, it doesn't seem correct that the 1st "point" is all
	#	zeros, and that most of this stuff is 'unknown', and for us,
	#   unused.
	# But to CONSTRUCT one of these we would have to know exactly
	# WTF is going on, including the relationship of all these uuids!
{
    my ($this,$block) = @_;
    my $uuid = $block->{uuid};
    display($dbg_block,0,"decodeRTE[$block->{num}]] ".uuidToStr($uuid));

	my $bytes = $block->{bytes};
	display_bytes($dbg_rte+2,1,"bytes",$bytes);

	# HEADER 1

	my $offset = 0;
	my $hdr1 = unpackRecord($dbg_rte+1,$RTE_HDR1_SPECS,substr($bytes,$offset,$RTE_HDR1_SIZE));
	$offset += $RTE_HDR1_SIZE;
	my $name = $hdr1->{name_len} ? substr($bytes,$offset,$hdr1->{name_len}) : '';
	$offset += $hdr1->{name_len};
	my $comment = $hdr1->{cmt_len} ? substr($bytes,$offset,$hdr1->{cmt_len}) : '';
	$offset += $hdr1->{cmt_len};

	display($dbg_rte,1,"NAME='$name'");
	display($dbg_rte,1,"COMMENT='$comment'") if $comment;

	$hdr1->{name} = $name;
	$hdr1->{comment} = $comment;
	$hdr1->{wpts} = [];
	$hdr1->{pts} = [];

	# we can skip this list of uuids, because they
	# precede each common waypoint ...
	#	for (my $i=0; $i<$hdr1->{uuid_cnt}; $i++)
	#	{
	#		my $uuid = unpack('H*',substr($bytes,$offset,$UUID_SIZE));
	#		warning(0,1,"skipping inner_uuid($uuid)");
	#		$offset += $UUID_SIZE;
	#	}

	$offset += $UUID_SIZE * $hdr1->{uuid_cnt};

	# HEADER2

	display($dbg_rte+1,1,"HEADER2");
	my $hdr2 = unpackRecord($dbg_rte+1,$RTE_HDR2_SPECS,substr($bytes,$offset,$RTE_HDR2_SIZE));
	$hdr2->{lat_start} /= $LL_SCALE_FACTOR;
	$hdr2->{lon_start} /= $LL_SCALE_FACTOR;
	$hdr2->{lat_end}   /= $LL_SCALE_FACTOR;
	$hdr2->{lon_end}   /= $LL_SCALE_FACTOR;
	mergeHash($hdr1,$hdr2);
	$offset += $RTE_HDR2_SIZE;

	# POINTS
	# can probably also be skipped because they contain no information
	# not in the common waypoint record
	
	for (my $i=0; $i<$hdr1->{uuid_cnt}; $i++)
	{
		display($dbg_rte+2,1,"POINT($i)");
		my $pt = unpackRecord($dbg_rte+2,$RTE_PT_SPECS,substr($bytes,$offset,$RTE_PT_SIZE));
		$pt->{bearing} =  roundTwo(($pt->{bearing} / 10000) * (180 / $PI));

		display($dbg_rte,2,sprintf("PT($i) bearing=$pt->{bearing} leg(%d)=%0.3f tot(%d)=%0.3f",
			$pt->{legLength},
			$pt->{legLength} / $METERS_PER_NM,
			$pt->{totLength},
			$pt->{totLength} / $METERS_PER_NM ));

		$offset += $RTE_PT_SIZE;
		push @{$hdr1->{pts}},$pt;
	}

	# HEADER3

	display($dbg_rte+1,1,"HEADER3");
	my $hdr3 = unpackRecord($dbg_rte+1,$RTE_HR3_SPECS,substr($bytes,$offset,$RTE_HDR3_SIZE));
	mergeHash($hdr1,$hdr3);
	$offset += $RTE_HDR3_SIZE;

	# common waypoints
	# each BLK_RTE common waypoint is, itself, preceded by TWO uuids
	
	for (my $i=0; $i<$hdr1->{uuid_cnt}; $i++)
	{
		my $wpt_uuid = substr($bytes,$offset,$UUID_SIZE);
		$offset += $UUID_SIZE;
		my $wpt = decodeCommonWaypoint($dbg_rte,$bytes,$offset,$wpt_uuid);
		$wpt->{active} = $block->{active} ? 1 : 0;
		$offset += $WPT_HEADER_SIZE + $wpt->{name_len} + $wpt->{cmt_len};
		push @{$hdr1->{wpts}},$wpt;
	}

	$hdr1->{uuid} = uuidToStr($uuid);
	$hdr1->{active} = $block->{active} ? 1 : 0;
	push @{$this->{routes}},$hdr1;
	display_hash($dbg_rte,1,"Route Record",$hdr1);

}	# decodeRTE()


#------------------------------------
# GRP
#------------------------------------

my $GRP_HEADER_LEN = 4;

sub decodeGRP
{
    my ($this,$block) = @_;
    my $uuid = $block->{uuid};
    display($dbg_grp,0,"decodeGRP[$block->{num}] ".uuidToStr($uuid));

	my $bytes = $block->{bytes};
	display_bytes($dbg_grp+1,1,"bytes",$bytes);

	# group header is 4 bytes, followed by name_len bytes,
	# followed by uuid_cnt waypoint uuids, followed by "fsh_wpt" which are
	# 2 int32_t's for actual integer lat/lon * 1E7, followed by
	# the common waypoint.  Once again I use S for uint16_t's for
	# the name_len and uuid_cnt.

	my $offset = 0;

	my ($name_len,$uuid_cnt) = unpack('SS',substr($bytes,$offset,$GRP_HEADER_LEN));
		# 	int16_t name_len; // length of name of route
		# 	int16_t uuid_cnt; // number of UUIDs in the list following this header
		# 	char name[];      // unterminated name string of length name_len
	$offset += $GRP_HEADER_LEN;

	my $name = substr($bytes,$offset,$name_len);
	$offset += $name_len;
	display($dbg_grp,1,"GRP_NAME=$name");

	my $grp = {
		uuid => uuidToStr($uuid),
		name => $name,
		wpts => [] };

	my @wp_uuids;
	for (my $i=0; $i<$uuid_cnt; $i++)
	{
		my $uuid = substr($bytes,$offset,$UUID_SIZE);
		$offset += $UUID_SIZE;
		display($dbg_grp+1,2,"uuid[$i]=".uuidToStr($uuid));
		push @wp_uuids,$uuid;
	}

	for (my $i=0; $i<$uuid_cnt; $i++)
	{
		my $wpt = decodeCommonWaypoint($dbg_grp,$bytes,$offset,$wp_uuids[$i]);
		$wpt->{active} = $block->{active} ? 1 : 0;
		$offset += $WPT_HEADER_SIZE + $wpt->{name_len} + $wpt->{cmt_len};
		push @{$grp->{wpts}},$wpt;
	}

	$grp->{active} = $block->{active} ? 1 : 0;
	push @{$this->{groups}},$grp;

}	# decodeGRP()





#--------------------------------------------
# encodeCommonWaypoint (private helper)
#--------------------------------------------

sub _encodeCommonWaypoint
{
	my ($wpt) = @_;
	my $name    = $wpt->{name}    // '';
	my $comment = $wpt->{comment} // '';
	my $rec = {
		lat      => int($wpt->{lat} * $LL_SCALE_FACTOR),
		lon      => int($wpt->{lon} * $LL_SCALE_FACTOR),
		north    => $wpt->{north}  // 0,
		east     => $wpt->{east}   // 0,
		k1_0x12  => chr(0) x 12,
		sym      => $wpt->{sym}    // 0,
		temp     => $wpt->{temp}   // 0,
		depth    => $wpt->{depth}  // 0,
		time     => $wpt->{time}   // 0,
		date     => $wpt->{date}   // 0,
		k2_0     => 0,
		name_len => length($name),
		cmt_len  => length($comment),
		k3_0     => 0,
	};
	return packRecord($dbg_wwpt+1, $WPT_FIELD_SPECS, $rec) . $name . $comment;
}


#--------------------------------------------
# encodeWPT
#--------------------------------------------

sub encodeWPT
{
	my ($this, $wpt) = @_;
	display($dbg_wwpt, 0, "encodeWPT(".($wpt->{uuid}//'?').") name=".($wpt->{name}//''));
	my $bytes = _encodeCommonWaypoint($wpt);
	$this->createBlock($wpt->{uuid}, $FSH_BLK_WPT, $bytes);
	return 1;
}


#--------------------------------------------
# encodeGRP
#--------------------------------------------

sub encodeGRP
{
	my ($this, $grp) = @_;
	my $name     = $grp->{name} // '';
	my $wpts     = $grp->{wpts} // [];
	my $uuid_cnt = scalar @$wpts;
	display($dbg_wgrp, 0, "encodeGRP($name) uuid_cnt=$uuid_cnt");

	my $bytes = pack('SS', length($name), $uuid_cnt) . $name;

	for my $wpt (@$wpts)
	{
		$bytes .= strToUuid($wpt->{uuid});
	}
	for my $wpt (@$wpts)
	{
		$bytes .= _encodeCommonWaypoint($wpt);
	}

	$this->createBlock($grp->{uuid}, $FSH_BLK_GRP, $bytes);
	return 1;
}


#--------------------------------------------
# encodeRTE
#--------------------------------------------

sub encodeRTE
{
	my ($this, $rec) = @_;
	my $name    = $rec->{name}    // '';
	my $comment = $rec->{comment} // '';
	my $wpts    = $rec->{wpts}    // [];
	my $pts     = $rec->{pts}     // [];
	my $uuid_cnt = scalar @$wpts;
	display($dbg_wrte, 0, "encodeRTE($name) uuid_cnt=$uuid_cnt");

	# HDR1
	my $hdr1_rec = {
		u1_0     => $rec->{u1_0}  // '0000',
		name_len => length($name),
		cmt_len  => length($comment),
		uuid_cnt => $uuid_cnt,
		bits     => $rec->{bits}  // '00',
		color    => $rec->{color} // 0,
	};
	my $bytes = packRecord($dbg_wrte+1, $RTE_HDR1_SPECS, $hdr1_rec);
	$bytes .= $name . $comment;

	# uuid list (same uuids as the per-waypoint uuids in section 8)
	for my $wpt (@$wpts)
	{
		$bytes .= strToUuid($wpt->{uuid});
	}

	# HDR2 (lat/lon fields re-scaled to int32)
	my $hdr2_rec = {
		lat_start => int(($rec->{lat_start} // 0) * $LL_SCALE_FACTOR),
		lon_start => int(($rec->{lon_start} // 0) * $LL_SCALE_FACTOR),
		lat_end   => int(($rec->{lat_end}   // 0) * $LL_SCALE_FACTOR),
		lon_end   => int(($rec->{lon_end}   // 0) * $LL_SCALE_FACTOR),
		distance  => $rec->{distance} // 0,
		u2_0200   => $rec->{u2_0200}  // '00000000',
		u3        => $rec->{u3}       // '00000000',
		u4_self   => $rec->{u4_self}  // ('0' x 16),
		u5_self   => $rec->{u5_self}  // ('0' x 16),
		u6        => $rec->{u6}       // '2100',
	};
	$bytes .= packRecord($dbg_wrte+1, $RTE_HDR2_SPECS, $hdr2_rec);

	# RTE_PT records (bearing pre-calculation is lossy; write 0 for bearing,
	# preserve leg and total distances as stored integers)
	for (my $i = 0; $i < $uuid_cnt; $i++)
	{
		my $pt  = $pts->[$i];
		my $leg = $pt ? ($pt->{legLength} // 0) : 0;
		my $tot = $pt ? ($pt->{totLength} // 0) : 0;
		$bytes .= pack('vVV', 0, $leg, $tot);
	}

	# HDR3
	my $hdr3_rec = {
		wpt_cnt => $uuid_cnt,
		k3_0    => 0,
	};
	$bytes .= packRecord($dbg_wrte+1, $RTE_HR3_SPECS, $hdr3_rec);

	# common waypoints, each preceded by its uuid
	for my $wpt (@$wpts)
	{
		$bytes .= strToUuid($wpt->{uuid});
		$bytes .= _encodeCommonWaypoint($wpt);
	}

	$this->createBlock($rec->{uuid}, $FSH_BLK_RTE, $bytes);
	return 1;
}


1;  #end of fshBlocks.pm
