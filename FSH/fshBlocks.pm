#--------------------------------------
# fshBlocks.pm
#--------------------------------------
# Based on the C code at https://github.com/rahra/parsefsh
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
# A proper implementation would parse all the BLK_TRK blocks first,
# and then allow for the MTAs to reference possible multiple BLK_TRACKS
# by guid as the data structure implies.


package apps::raymarine::FSH::fshBlocks;
use strict;
use warnings;
use POSIX qw(floor pow atan);
use Fcntl qw(:seek);
use Time::Local;
use Pub::Utils;
use apps::raymarine::FSH::fshUtils;


my $dbg_trk = 0;
my $dbg_mta = 0;
my $dbg_wpt = 0;
my $dbg_rte = 0;
my $dbg_grp = 0;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (

        processBlocks
        getTracks
        getWaypoints
		getRoutes
		getGroups

    );
}

my $WPT_HEADER_LEN = 40;

# parsed blocks

my $track_points = {};  # BLK_TRK are parsed into arrays of points by guid
my $tracks = [];        # BLK_MTA track meta info records ARE the 'tracks'
    # E80 BLK_MTA's always come after their BLK_TRKS, so we can do
    # everything in a single loop through all blocks.  For each BLK_MTA
    # we find the track_points based on the MTA's 1st (only) sub-guid,
    # and set the {points} member on the "track" record from that.
my $waypoints = [];          # BLK_WPT recs from the inner common_waypoint
    # with {guid} and {inner_guid} members added to by the block
my $routes = [];		# BLK_RTE very complicated data structures,
	# but each record has, at least, a NAME, possible COMMENT, and
	# an array of {wpts}
my $groups = [];
	# groups have a name element and a {wpts} array
	# the waypoints have a {int_lat, and int_lon} members
	# which are the actual values * 1E7, as opposed to the
	# mercator projectsion lat/lon from northEastToLatLon()


sub getTracks			{ return $tracks; }
sub getWaypoints()		{ return $waypoints; }
sub getRoutes()			{ return $routes; }
sub getGroups()			{ return $groups; }



sub processBlocks
{
    my ($all_blocks) = @_;
    display(0,0,"processing blocks ...");

    my $blk_num = 0;
    for my $block (@$all_blocks)
    {
        return if !decodeBlock($blk_num,$block);
    }

    return 1;
}



sub decodeBlock
    # dispatcher based on block type
{
    my ($blk_num,$block) = @_;
    my $type = $block->{type};
    # display(0,0,"decodeBlock($blk_num] ".blockTypeToStr($type)."(".guidToStr($block->{guid}).")");
    return 0 if $type == $FSH_BLK_TRK && !decodeTRK($blk_num,$block);
    return 0 if $type == $FSH_BLK_MTA && !decodeMTA($blk_num,$block);
    return 0 if $type == $FSH_BLK_WPT && !decodeWPT($blk_num,$block);
    return 0 if $type == $FSH_BLK_RTE && !decodeRTE($blk_num,$block);
    return 0 if $type == $FSH_BLK_GRP && !decodeGRP($blk_num,$block);
    return 1;
}



sub decodeTRK     # parse a BLK_TRK into array of points in track_points
	# Odd that nothing on a track has a date-time ...
{
    my ($blk_num,$block) = @_;
    my $guid = $block->{guid};
    display($dbg_trk,0,"decodeTRK[$blk_num] ".guidToStr($guid));

	my $TRACK_HEADER_SIZE = 8;
	my $TRACK_POINT_SIZE = 14;

	my $offset = 0;
	my $bytes = $block->{bytes};
	my ($a,$point_count,$b) = unpack('lss',substr($bytes,$offset,$TRACK_HEADER_SIZE));
		# typedef struct fsh_track_header
		# {
		# 	int32_t a;        // unknown, always 0
		# 	int16_t cnt;      // number of track points
		# 	int16_t b;        // unknown, always 0
		# }
	$offset += $TRACK_HEADER_SIZE;
	display($dbg_trk,1,"point_count($point_count)  ($a,$b)");

    my $points = [];
	for (my $i=0; $i<$point_count; $i++)
	{
		my $point_str = substr($bytes,$offset,$TRACK_POINT_SIZE);
		$offset += $TRACK_POINT_SIZE;
		my ($north,$east,$temp,$depth,$c) = unpack('llSss',$point_str);
			# typedef struct fsh_track_point
			# {
			# 	int32_t north, east; // prescaled (FSH_LAT_SCALE) northing and easting (ellipsoid Mercator)
			# 	uint16_t tempr;      // temperature in Kelvin * 100
			# 	int16_t depth;       // depth in cm
			# 	int16_t c;           // unknown, always 0
			# }
        my $coords = northEastToLatLon($north,$east);

        my $point = {
            north   => $north,
            east    => $east,
            temp    => $temp,
            depth   => $depth,
            lat     => $coords->{lat},
            lon     => $coords->{lon}, };
        push @$points,$point;
	}

    $track_points->{$guid} = $points;
    return 1;

}	# decodeTRK()



sub decodeMTA  # parse a BLK_MTA
	# In my E80 ARCHIVE.FSH's, 'j' is never 0, and it looks the name is
	# actually be 16 bytes, with junk after a null terminator.  All of my MTAs
	# have exactly one guid which is always the guid of the previous BLK_TRK.
{
    my ($blk_num,$block) = @_;
    my $guid = $block->{guid};
    my $dbg_str = "[$blk_num] ".guidToStr($guid);
    display($dbg_mta,0,"decodeMTA$dbg_str");

	my $bytes = $block->{bytes};
	display_bytes($dbg_mta+1,1,"bytes",$bytes);

	# Note that Z16 removes trailing nulls and garbage from strings
	# And once again, no date-time on a track!!

	my $MTA_HEADER_SIZE = 58;
    my $field_specs = [             # typedef struct fsh_track_meta     // total length 58 + guid_cnt * 8 bytes
        a            => 'c',        #   0     char a;                   // always 0x01
        cnt          => 's',        #   1     int16_t cnt;              // number of track points
        _cnt         => 's',        #   3     int16_t _cnt;             // same as cnt
        b            => 's',        #   5     int16_t b;                // unknown, always 0
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
        j            => 'C',        #   56    char j;                   // unknown, never 0 in my files, always 0 according to parsefsh
		guid_cnt     => 'c',        #   57    uint8_t guid_cnt;         // nr of guids following this header (always 1 in my files)
	];

    # guid_cnt is always exactly 1 for E80 ARCHIVE.FSH's
    
	my $rec = unpackRecord($dbg_mta+1,$field_specs,$bytes);
    return error("MTA$dbg_str has $rec->{guid_cnt} track guid's!")
        if $rec->{guid_cnt} != 1;


	my $offset = $MTA_HEADER_SIZE;
    my $track_guid = unpack('A8',substr($bytes,$offset,$GUID_SIZE));
    my $track_guid_str = guidToStr($track_guid);

    display($dbg_mta,1,"track name($rec->{name}) guid = $track_guid_str");

    my $points = $track_points->{$track_guid};
    return error("Could not find track_points($track_guid_str) on MTA$dbg_str")
        if !$points;

    $rec->{points} = $points;
    push @$tracks,$rec;
    return 1;

}	# decodeMTA()



sub decodeCommonWaypoint
    # common to BLK_WPT and ....
{
	my ($dbg,$bytes,$offset) = @_;
	my $wpt_header = substr($bytes,$offset,$WPT_HEADER_LEN);
	display_bytes($dbg+1,1,"wpt_header",$wpt_header);

    my $field_specs = [             # typedef struct fsh_wpt_data; total length 40 bytes + name_len + cmt_len
        north  		=> 'l',         #   0   int32_t north
        east   		=> 'l',         #   4   int32_t east; 				// prescaled ellipsoid Mercator northing and easting
        d           => 'A12',       #   8   char d[12];         		// 12x \0
        sym         => 'C',         #   20  char sym;           		// probably symbol
        temp        => 'S',         #   21  uint16_t tempr;     		// temperature in Kelvin * 100
        depth       => 'l',         #   23  int32_t depth;      		// depth in cm
                                    #   ######### fsh_timestamp_t ts; 	// timestamp
        time        => 'L',         #   27  uint32_t timeofday;  		// time of day in seconds
        date        => 'S',         #   31  uint16_t date;       		// days since 1.1.1970
        i           => 'C',         #   33  char i;             		// unknown, always 0
		name_len    => 'C',         #   34  char name_len;      		// length of name array
        cmt_len     => 'C',         #   35  char cmt_len;       		// length of comment
        j     		=> 'L',         #   36  int32_t j;                  // unknown, always 0
	];

    # follows are name_len bytes of name string and cmt_len bytes of comment text

	my $rec = unpackRecord($dbg+1,$field_specs,$wpt_header);
	$offset += $WPT_HEADER_LEN;

	my $name = $rec->{name_len} ? substr($bytes,$offset,$rec->{name_len}) : '';
	$offset += $rec->{name_len};
	my $comment = $rec->{cmt_len} ? substr($bytes,$offset,$rec->{cmt_len}) : '';

	my $show_time = fshDateTimeToStr($rec->{date},$rec->{time});

	display($dbg,1,"NAME=".pad($name,25)." $show_time");
	display($dbg,2,"COMMENT='$comment'") if $comment;

	$rec->{name} = $name;
	$rec->{comment} = $comment;

	my $coords = northEastToLatLon($rec->{north},$rec->{east});
	my $lat = $coords->{lat};
	my $lon = $coords->{lon};
    $rec->{lat} = $lat;
    $rec->{lon} = $lon;

	my $show_lat = degreesWithMinutes('lat',$lat);
	my $show_lon = degreesWithMinutes('lon',$lon);
	display($dbg,2,"lat($lat)=$show_lat lon($lon)=$show_lon");

	return $rec;

}	# decodeCommonWaypoint()



sub decodeWPT   # BLK_WPT
	# // length 8 bytes  + sizeof common wpt_data_t
	# typedef struct fsh_wpt01
	# {
	#    int64_t guid;
	#    fsh_wpt_data_t wpd;
	# }
{
    my ($blk_num,$block) = @_;
    my $guid = $block->{guid};
    display($dbg_wpt,0,"decodeWPT[$blk_num] ".guidToStr($guid));

	my $bytes = $block->{bytes};
	display_bytes($dbg_wpt+1,1,"bytes",$bytes);

	my $inner_guid = unpack('A8',$bytes);
	display($dbg_wpt+1,1,"inner guid=".guidToStr($inner_guid));

	my $offset = $GUID_SIZE;     # move past the guid
	my $rec = decodeCommonWaypoint($dbg_wpt,$bytes,$offset);
    $rec->{guid} = $guid;
    $rec->{inner_guid} = $inner_guid;
    push @$waypoints,$rec;
    return 1;

}	# decodeWPT()



sub decodeRTE   # BLK_RTE
	# From https://wiki.openstreetmap.org/wiki/ARCHIVE.FSH
	# This complicated block appears to be made up of
	# 	- an fsh_route21_header,
	#   - guid_cnt guids
	#   - an fsh_hdr2,
	#   - an array of guid_cnt 10 byte fsh_pt's
	#   - an fsh_hdr3
	#   - an array of common waypoints, each preceded by TWO guids
	# This code is a glom and the TWO guids approach was determined
	# 	semi-empirically and from notes on the above page, where it
	# 	appears that the common waypoints are bracketed by three different
	# 	wrappers depending on what kind of block they are in
	# In detail, it doesn't seem correct that the 1st "point" is all
	#	zeros, and that most of this stuff is 'unknown', and for us,
	#   unused.
	# But to CONSTRUCT one of these we would have to know exactly
	# WTF is going on, including the relationship of all these guids!
{
    my ($blk_num,$block) = @_;
    my $guid = $block->{guid};
    display($dbg_rte,0,"decodeRTE[$blk_num] ".guidToStr($guid));

	my $bytes = $block->{bytes};
	display_bytes($dbg_rte+1,1,"bytes",$bytes);

	my $HEADER1_SIZE = 8;
	my $HEADER2_SIZE = 46;
	my $FSH_PT_SIZE = 10;
	my $HEADER3_SIZE = 4;

	# I don't know why he uses int16_t for enumerations
	# I generally use 'C','S', and 'L', prefering unsigned unless
	# the number can truly be negative.

    my $hdr1_specs = [				# struct fsh_route21_header;  8 bytes
        a			=> 'S',			#   int16_t a;        	// unknown, always 0
		name_len	=> 'C',			#   char name_len;    	// length of name of route
		cmt_len		=> 'C',			#   char cmt_len;     	// length of comment
		guid_cnt	=> 's',			#   int16_t guid_cnt; 	// number of guids following this header
		b			=> 'S',			#   uint16_t b;       	// unknown
	];								# }

    my $hdr2_specs = [				# struct fsh_hdr2;   46 bytes
        lat0		=> 'l',			#	int32_t lat0;
		lon0		=> 'l',         #	int32_t lon0;  		// lat/lon of first waypoint
		lat1		=> 'l',         #	int32_t lat1;
		lon1		=> 'l',         #	int32_t lon1;  		// lat/lon of last waypoint
		a			=> 'L',         #	int32_t a;
		                            #	//int16_t b;        // comment only; not a real field: 0 or 1
		c			=> 'S',         #	int16_t c;
		d			=> 'A24',       #	char d[24];
	];								# }

	my $fsh_pt_specs = [			# struct fsh_pt; 10 bytes
		a			=> 'S',			#	int16_t a;
		b			=> 'S',			#	int16_t b;        	// depth?
		c			=> 'S',			#	int16_t c;        	// always 0
		d			=> 'S',			# 	int16_t d;        	// in the first element same value like b
		sym			=> 'S',			#	int16_t sym;      	// seems to be the symbol
	];								# }

	my $hdr3_specs = [				# struct fsh_hdr3; 4 bytes
		wpt_cnt		=> 'S',			# 	int16_t wpt_cnt;  	// number of waypoints
		a			=> 'S',			#	int16_t a;        	// always 0
	];								# }


	# HEADER 1

	my $offset = 0;
	my $hdr1 = unpackRecord($dbg_rte+1,$hdr1_specs,substr($bytes,$offset,$HEADER1_SIZE));
	$offset += $HEADER1_SIZE;
	my $name = $hdr1->{name_len} ? substr($bytes,$offset,$hdr1->{name_len}) : '';
	$offset += $hdr1->{name_len};
	my $comment = $hdr1->{cmt_len} ? substr($bytes,$offset,$hdr1->{cmt_len}) : '';
	$offset += $hdr1->{cmt_len};

	display($dbg_rte,1,"NAME='$name'");
	display($dbg_rte,1,"COMMENT='$comment'") if $comment;

	$hdr1->{name} = $name;
	$hdr1->{comment} = $comment;
	$hdr1->{guids} = [];
	$hdr1->{wpts} = [];
	$hdr1->{pts} = [];

	# INNER GUIDS

	for (my $i=0; $i<$hdr1->{guid_cnt}; $i++)
	{
		my $inner_guid = substr($bytes,$offset,$GUID_SIZE);
		$offset += $GUID_SIZE;
		display($dbg_rte+1,2,"inner_guid($i)=".guidToStr($inner_guid));
		push @{$hdr1->{guids}},$inner_guid;
	}

	# HEADER2

	display($dbg_rte+1,1,"HEADER2");
	$hdr1->{hdr2} = unpackRecord($dbg_rte+1,$hdr2_specs,substr($bytes,$offset,$HEADER2_SIZE));
	$offset += $HEADER2_SIZE;

	# POINTS

	for (my $i=0; $i<$hdr1->{guid_cnt}; $i++)
	{
		display($dbg_rte+1,1,"POINT($i)");
		my $pt = unpackRecord($dbg_rte+1,$fsh_pt_specs,substr($bytes,$offset,$FSH_PT_SIZE));
		$offset += $FSH_PT_SIZE;
		push @{$hdr1->{pts}},$pt;
	}

	# HEADER3

	display($dbg_rte+1,1,"HEADER3");
	$hdr1->{hdr3} = unpackRecord($dbg_rte+1,$hdr3_specs,substr($bytes,$offset,$HEADER3_SIZE));
	$offset += $HEADER3_SIZE;


	# common waypoints
	# each BLK_RTE common waypoint is, itself, preceded by TWO guids
	
	for (my $i=0; $i<$hdr1->{guid_cnt}; $i++)
	{
		my $wpt_guid1 = substr($bytes,$offset,$GUID_SIZE);
		$offset += $GUID_SIZE;
		my $wpt_guid2 = substr($bytes,$offset,$GUID_SIZE);
		$offset += $GUID_SIZE;

		display($dbg_rte+1,1,"TWO GUID AND COMMON WAYPOINT($i)");
		display($dbg_rte+1,2,"wpt_guid($i)=".guidToStr($wpt_guid1));
		display($dbg_rte+1,2,"wpt_guid($i)=".guidToStr($wpt_guid2));
		
		my $wpt = decodeCommonWaypoint($dbg_rte,$bytes,$offset);
		$offset += $WPT_HEADER_LEN + $wpt->{name_len} + $wpt->{cmt_len};
		push @{$hdr1->{wpts}},$wpt;
	}

	push @$routes,$hdr1;
	
}	# decodeRTE()



sub decodeGRP   # BLK_GRP
{
    my ($blk_num,$block) = @_;
    my $guid = $block->{guid};
    display($dbg_grp,0,"decodeGRP[$blk_num] ".guidToStr($guid));

	my $bytes = $block->{bytes};
	display_bytes($dbg_grp+1,1,"bytes",$bytes);

	# group header is 4 bytes, followed by name_len bytes,
	# followed by guid_cnt guids, followed by "fsh_wpt" which are
	# 2 int32_t's for actual integer lat/lon * 1E7, followed by
	# the common waypoint.  Once again I use S for uint16_t's for
	# the name_len and guid_cnt.

	my $offset = 0;
	my $GRP_HEADER_LEN = 4;
	my ($name_len,$guid_cnt) = unpack('SS',substr($bytes,$offset,$GRP_HEADER_LEN));
		# typedef struct fsh_group22_header
		# {
		# 	int16_t name_len; // length of name of route
		# 	int16_t guid_cnt; // number of GUIDs in the list following this header
		# 	char name[];      // unterminated name string of length name_len
		# }
	$offset += $GRP_HEADER_LEN;

	my $name = substr($bytes,$offset,$name_len);
	$offset += $name_len;
	display($dbg_grp,1,"GRP_NAME=$name");

	my $grp = {
		name => $name,
		guids => [],
		wpts => [] };

	for (my $i=0; $i<$guid_cnt; $i++)
	{
		my $guid = substr($bytes,$offset,$GUID_SIZE);
		$offset += $GUID_SIZE;
		display($dbg_grp+1,2,"guid[$i]=".guidToStr($guid));
		push @{$grp->{guids}},$guid;
	}

	# typedef struct fsh_wpt
	# {
	# 	int32_t lat, lon;   //!< latitude/longitude * 1E7
	# 	fsh_wpt_data_t wpd;
	# }

	for (my $i=0; $i<$guid_cnt; $i++)
	{
		my ($int_lat,$int_lon) = unpack('ll',substr($bytes,$offset,8));
		$offset += 8;
		my $wpt = decodeCommonWaypoint($dbg_grp,$bytes,$offset);

		my $show_lat = $int_lat / 10000000;
		my $show_lon = $int_lon / 10000000;

		display($dbg_grp,3,"int_lat=".sprintf("%.6f",$show_lat)."  int_lon=".sprintf("%.6f",$show_lon));

		$offset += $WPT_HEADER_LEN + $wpt->{name_len} + $wpt->{cmt_len};
		$wpt->{int_lat} = $int_lat;
		$wpt->{int_lon} = $int_lon;
		push @{$grp->{wpts}},$wpt;
	}

	push @$groups,$grp;

}	# decodeGRP()




1;  #end of fshBlocks.pm
