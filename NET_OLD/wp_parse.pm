#---------------------------------------------
# wp_parse.pm
#---------------------------------------------
# Routines to parse WPMGR messages, and the
# BUFFERS within them into Waypoints, Routes, and Groups.


package wp_parse;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use r_defs;


my $dbg_wp = 1;
my $dbg_route = 1;
my $dbg_group = 1;
my $dbg_track = 1;
my $dbg_unpack = 1;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		parseWPMGRRecord
		WPRecordToText

		parseWPWaypoint
		parseWPRoute
		parseWPGroup
		
		buildWPWaypoint
		buildWPRoute
		buildWPGroup

		unpackRecord
		packRecord

		latLonToNorthEast
		northEastToLatLon

		parseTrack
		parseMTA
		parsePoint

    );
}


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
# are only shown at $detail >= 2

my $ROUTE_PT_SIZE = 10;
my $ROUTE_PT_SPECS = [
	p_u0_0		=> [ 1,	2,	'H4',   ],		# 0		uint16_t;
	p_depth		=> [ 1,	2,	'H4',   ],		# 2		uint16_t;
	p_u1_0		=> [ 1,	4,	'H8',   ],		# 4		uint32_t;
	p_sym		=> [ 1,	2,	'H4',   ],		# 8		uint16_t;
];


sub parseWPMGRRecord
{
	my ($kind,$buffer) = @_;
	return parseWPWaypoint($buffer) if $kind eq 'WAYPOINT';
	return parseWPRoute($buffer) if $kind eq 'ROUTE';
	return parseWPGroup($buffer) if $kind eq 'GROUP';
}



#--------------------------------------------------------------
# WPRecordToText
#--------------------------------------------------------------
# The outputXXX() methods are denormalized from decodeXXX() methods because
# we are using the record  containing properly unpacked (native) values, and,
# in order to show the hex, and properly align them for output,
# each method is the only one to know how to repack into a hex format
# and do the alignment padding.

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


sub outputLL
{
	my ($raw,$value,$scale) = @_;
	$value /= $SCALE_LATLON if $scale;
	my $hex = unpack('H*',pack('V',$raw));
	my $degmin = degreeMinutes($value);
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

sub outputDate
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

sub outputTime
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


sub WPRecordToText
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
				$extra = outputDate($val) if $key eq 'date';
				$extra = outputTime($val) if $key eq 'time';
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


#-------------------------------------
# pack and unpack native records
#-------------------------------------

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
# WPGroups
#------------------------------------

sub parseWPGroup
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
	display($dbg_group,0,"parseWPGroup len($buf_len)");

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


sub buildWPGroup
{
	my ($rec) = @_;
	my $name = $rec->{name} || '';
	my $comment = $rec->{comment} || '';
	my $uuids = $rec->{uuids} || shared_clone([]);

	$rec->{name_len} = length($name);
	$rec->{cmt_len} = length($comment);
	$rec->{uuids} = $uuids;
	$rec->{num_uuids} = @$uuids;

	display($dbg_wp,0,"buildWPGroup($rec->{name}");
	my $buffer = packRecord('GROUP',$rec,$GROUP_REC_SPECS);
	$buffer .= $name;
	$buffer .= $comment;

	for my $uuid (@$uuids)
	{
		$buffer .= pack('H*',$uuid);
	}

	$buffer = pack('V',length($buffer)).$buffer;
	parseWPGroup($buffer);	# debug check
	return $buffer;
}



#------------------------------------
# WPRoutes
#------------------------------------

sub parseWPRoute
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
	display($dbg_route,0,"parseWPRoute len($buf_len)");

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


sub buildWPRoute
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

	display($dbg_wp,0,"buildWPRoute($rec->{name}");
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
	parseWPRoute($buffer);	# debug check
	return $buffer;
}



#------------------------------------
# WPWaypoints
#------------------------------------

sub parseWPWaypoint
	# The WAYPOINT message itself starts with
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
	display($dbg_wp,0,"parseWPWaypoint len($buf_len)");
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


sub buildWPWaypoint
{
	my ($rec) = @_;
	my $name = $rec->{name} || '';
	my $comment = $rec->{comment} || '';
	$rec->{name_len} = length($name);
	$rec->{cmt_len} = length($comment);
	
	display($dbg_wp,0,"buildWPWaypoint($rec->{name}");
	my $buffer = packRecord('WAYPOINT',$rec,$WP_REC_SPECS);
	$buffer .= $name;
	$buffer .= $comment;
	
	my $uuids = $rec->{uuids};
	for my $uuid (@$uuids)
	{
		$buffer .= pack('H*',$uuid);
	}

	$buffer = pack('V',length($buffer)).$buffer;
	parseWPWaypoint($buffer);	# debug check
	return $buffer;
}


#-------------------------------------------------
# trackMTA
#-------------------------------------------------


my $MTA_REC_SIZE = 57;
my $MTA_REC_SPECS = [
	k1_1         => [ 1,	1,		'c',     ],   #   0     char a;                   // always 0x01
	cnt1         => [ 0,	2,		's',     ],   #   1     int16_t cnt;              // number of track points
	cnt2         => [ 0,	2,		's',     ],   #   3     int16_t _cnt;             // same as cnt
	k2_0         => [ 1,	2,		's',     ],   #   5     int16_t b;                // unknown, always 0
	length       => [ 0,	4,		'l',     ],   #   7     int32_t length;           // approx. track length in m
	north_start  => [ 0,	4,		'l',     ],   #   11    int32_t north_start;      // Northing of first track point
	east_start   => [ 0,	4,		'l',     ],   #   15    int32_t east_start;       // Easting of first track point
	temp_start   => [ 0,	2,		'S',     ],   #   19    uint16_t tempr_start;     // temperature of first track point
	depth_start  => [ 0,	4,		'l',     ],   #   21    int32_t depth_start;      // depth of first track point
	north_end    => [ 0,	4,		'l',     ],   #   25    int32_t north_end;        // Northing of last track point
	east_end     => [ 0,	4,		'l',     ],   #   29    int32_t east_end;         // Easting of last track point
	temp_end     => [ 0,	2,		'S',     ],   #   33    uint16_t tempr_end;       // temperature last track point
	depth_end    => [ 0,	4,		'l',     ],   #   35    int32_t depth_end;        // depth of last track point
	color        => [ 0,	1,		'c',     ],   #   39    char col;                 /* track color: 0 - red, 1 - yellow, 2 - green, 3 -#blue, 4 - magenta, 5 - black */
	name         => [ 0,	16,		'Z16',   ],   #   40    char name[16];            // name of track, string not terminated
	u1           => [ 1,	1,		'C',     ],   #   56    char j;                   // unknown, never 0 in my files, always 0 according to parsefsh
];


my $TRACK_HDR_SIZE = 8;
my $TRACK_HEADER_SPECS = [
	a 			=> [ 0,		4,		'V',	 ],	 # 0 	int32_t a;        // unknown, always 0
	cnt			=> [ 0,		2,		'v',	 ],	 # 4	int16_t cnt;
	b			=> [ 0,		2,		'v',	 ],	 # 6	int16_t cnt;
];



# Current track with one point doesn't line up these
# 0102130011000000160000000000000001000000 060000eae5f805eaf2f805ea01f9
#
#	0102 1300 11000000 16000000 	cmd, func, seq, big_len
#	00000000 0100 0000				a, cnt, b
#
#	060000ea						not a good north (-369098746 = -29.701 south)
#	e5f805ea						not a good east  (-368707355 = -30.904693 west)
#	f2f8							not a good tempr
#	05ea							not a good depth
#	01f9							not even a good unknown 'c'

# 060000eae5f805eaf2f805ea01f9
#
# It looks to me, and particularly in larger unsaved tracks, that this
# is broken up differently
#
#	0600 00eae5f8 05eaf2f8 05ea01f9

# a bigger example

# 0102 1300 14000000 32000000 00000000 03000000
# 0600 00eae5f8 05eaf2f8 05ea01f9 05ea9fff 05ea1bf9 05ea3ff9 05eaded8 05ea0000 a0e3150f 07ee0d10
#
#	I wonder if they could be two uin16 deltas







my $TRACK_PT_SIZE = 14;
my $TRACK_PT_SPECS = [
	north		=> [ 0,		4,		'l',	],	#  0	int32_t north 		// prescaled (FSH_LAT_SCALE) northing and easting (ellipsoid Mercator)
	east		=> [ 0,		4,		'l',	],	#  4 	int33_t east
	tempr		=> [ 0,		2,		'v',	],	#  8	uint16_t tempr;      // temperature in Kelvin * 100
	depth		=> [ 0,		2,		'v',	],	# 10	int16_t depth;       // depth in cm
	c			=> [ 0,		2,		'v',	],	# 12	int16_t c;           // unknown, always 0
];



sub parseMTA
{
	my ($buffer) = @_;
	my $buf_len = length($buffer);
	display($dbg_track,0,"parseMTA len($buf_len)");
	my $offset = 0;
	my $rec = unpackRecord('mta',$MTA_REC_SPECS, $buffer, $offset, $MTA_REC_SIZE);

	my $coords = northEastToLatLon($rec->{north_start},$rec->{east_start});
	$rec->{lat_start} = $coords->{lat};
	$rec->{lon_start} = $coords->{lon};
	$coords = northEastToLatLon($rec->{north_end},$rec->{east_end});
	$rec->{lat_end} = $coords->{lat};
	$rec->{lon_end} = $coords->{lon};

	my $deg_lat_start = degreeMinutes($rec->{lat_start});
	my $deg_lon_start = degreeMinutes($rec->{lon_start});

	my $deg_lat_end = degreeMinutes($rec->{lat_end});
	my $deg_lon_end = degreeMinutes($rec->{lon_end});

	display(0,-1,"start($deg_lat_start,$deg_lon_start)",0,$UTILS_COLOR_WHITE);
	display(0,-1,"  end($deg_lat_end,$deg_lon_end)",0,$UTILS_COLOR_WHITE);


	# I think the unknown k1_1 variable may be one for a saved, regular track
	# and 0 for an unsaved, in-process track, and that their point layouts are
	# different.  I note that it is possible to get the "current track" from the
	# E80, and then not be able to get it by uuid (fails), so there is also the
	# idea that the current track may not have even started recording yet, but
	# i don't see anyting obvious in the MTA that indicates this, except for
	# perhaps cnt1=cnt2==0.
	#
	# u1 is also a bit suspicious,
	#	239 = not recording yet

	display($dbg_track,1,"found MTA($rec->{name}) with $rec->{cnt1} points");
	display_hash(0,1,"parsetMTA($rec->{name}) returning",$rec);
	return $rec;
}


sub parseTrack
{
	my ($buffer) = @_;
	my $buf_len = length($buffer);
	display($dbg_track,0,"parseTrack len($buf_len)");

	# there's some garbage in the front

	my $offset = 0;
	my $rec = unpackRecord('track_hdr',$TRACK_HEADER_SPECS, $buffer, $offset, $TRACK_HDR_SIZE);
	$offset += $TRACK_HDR_SIZE;

	display($dbg_track,1,"found $rec->{cnt} track points");

	# to identify weird record from GET_TRACK of Current Track's uuid
	# if (0 && $old_rec->{k1_1} == 0)

	my $points = $rec->{points} = shared_clone([]);
	for (my $i=0; $i<$rec->{cnt}; $i++)
	{
		my $pt = unpackRecord('track_point',$TRACK_PT_SPECS, $buffer, $offset, $TRACK_PT_SIZE);
		my $coords = northEastToLatLon($pt->{north},$pt->{east});
		$pt->{lat} = $coords->{lat};
		$pt->{lon} = $coords->{lon};

		display(0,-1,sprintf("point($i) lat(%s) lon(%s)",
			degreeMinutes($pt->{lat}),
			degreeMinutes($pt->{lon}) ),0,$UTILS_COLOR_WHITE);

		push @$points,$pt;
		$offset += $TRACK_PT_SIZE;
	}


	return $rec;
}



sub parsePoint
{
	my ($buffer) = @_;
	my $buf_len = length($buffer);
	display($dbg_track-1,0,"parsePoint len($buf_len)=".unpack('H*',$buffer));

	my $offset = 2;
		# skip garbage word efef

	my $pt = unpackRecord('track_point',$TRACK_PT_SPECS, $buffer, $offset, $TRACK_PT_SIZE);
	my $coords = northEastToLatLon($pt->{north},$pt->{east});
	$pt->{lat} = $coords->{lat};
	$pt->{lon} = $coords->{lon};

	display(0,-1,sprintf("lat(%s) lon(%s)",
		degreeMinutes($pt->{lat}),
		degreeMinutes($pt->{lon}) ),0,$UTILS_COLOR_WHITE);

	return $pt;
}





1;