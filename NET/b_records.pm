#---------------------------------------------
# b_records.pm
#---------------------------------------------
# Routines to parse and build well known records:
#
#	Waypoint
#	Route
#	Group
#
# Parse only:
#
#	MTA
#	Track
#	Point

package apps::raymarine::NET::b_records;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_mon;
use apps::raymarine::NET::a_utils;


my $BUILD_CHECK_GROUP = 1;
my $BUILD_CHECK_ROUTE = 1;
my $BUILD_CHECK_WP 	  = 1;
my $BUILD_CHECK_MTA   = 1;
my $BUILD_CHECK_TRACK = 1;
my $BUILD_CHECK_POINT = 1;


my $dbg_wp		= 1;
my $dbg_route	= 1;
# my $dbg_mta		= 1;
# my $dbg_track	= 1;
# my $dbg_point	= 1;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		wpmgrRecordToText

		parseWaypoint
		parseRoute
		parseGroup
		
		buildWaypoint
		buildRoute
		buildGroup

		parseTRK
		parseMTA
		parsePoint

    );
}




my $WP_REC_SIZE = 48;
my $WP_REC_SPECS = [
	#              	detail	size	unpack
	lat			=> [ 0,		4,		'l',	],	   #  0   int32_t lat;				// 1E7 lat
	lon			=> [ 0,		4,		'l',	],	   #  4   int32_t lon;				// 1E7 lon
	north  		=> [ 0,		4,		'l',    ],     #  8   int32_t north				// prescaled ellipsoid Mercator northing and easting
	east   		=> [ 0,		4,		'l',    ],     #  12  int32_t east;
	k1_0x12     => [ 2,		12,		'H24',  ],     #  16  char d[12];         		// 12x \0
	sym         => [ 0,		1,		'C',    ],     #  28  char sym;           		// probably symbol
	temp        => [ 0,		2,		'S',    ],     #  29  uint16_t tempr;     		// temperature in Kelvin * 100
	depth       => [ 0,		4,		'l',    ],     #  31  int32_t depth;      		// depth in cm
	time        => [ 0,		4,		'L',    ],     #  35  uint32_t timeofday;  		// time of day in seconds
	date        => [ 0,		2,		'S',    ],     #  39  uint16_t date;       		// days since 1.1.1970
	k2_0        => [ 2,		1,		'C',    ],     #  41  char i;             		// unknown, always 0
	name_len    => [ 1,		1,		'C',    ],     #  42  char name_len;      		// length of name array
	cmt_len     => [ 1,		1,		'C',    ],     #  43  char cmt_len;       		// length of comment
	k3_0     	=> [ 2,		4,		'L',    ],     #  44  int32_t j;                // unknown, always 0
];


my $GROUP_REC_SIZE = 4;
my $GROUP_REC_SPECS = [
	name_len	=> [ 1,	1,	'C',	],		# 0		uint8_t;
	cmt_len 	=> [ 1,	1,	'C',	],		# 1		uint8_t;
	num_uuids   => [ 0,	2,	'v',	],		# 2		uint16_t;
];



my $ROUTE_HDR1_SIZE = 8;
my $ROUTE_HDR1_SPECS = [
	u1_0		=> [ 2,	2,	'H4',	],		# 0		uint16_t;
	name_len	=> [ 1,	1,	'C',	],		# 2		uint8_t;
	cmt_len 	=> [ 1,	1,	'C',	],		# 3		uint8_t;
	num_wpts    => [ 0,	2,	'v',	],		# 4		uint16_t;
	bits		=> [ 2,	1,	'H2',   ],		# 6		uint8_t;   1=temporary; 2=don't transfer to RNS
	color		=> [ 0, 1,	'C',	],		# 7		uint8_t color index
];

my $ROUTE_HDR2_SIZE = 46;
my $ROUTE_HDR2_SPECS = [
	lat_start	=> [ 0,	4,	'l',	],		# 0		int32_t lat0;
	lon_start	=> [ 0,	4,	'l',	],		# 4     int32_t lon0;
	lat_end		=> [ 0,	4,	'l',	],		# 8     int32_t lat1;
	lon_end 	=> [ 0,	4,	'l',	],		# 12    int32_t lon1;
	distance	=> [ 2,	4,	'V', 	],		# 16	uint32_t distance in meters
	u2_0200		=> [ 2,	4,	'H8',	],		# 20	02000000 number?
	u3			=> [ 2,	4,	'H8',	],		# 24	b8975601 data? end marker?
	u4_self		=> [ 1,	8,	'H16',	],		# 28	self uuid dc82990f f567e68e
	u5_self		=> [ 1,	8,	'H16',	],		# 36	self uuid dc82990f f567e68e
	u6		    => [ 2,	2,	'H4',   ],		# 44	unknown
];		# 34 = e039 - 0x39e = 926



# Route Points
# I have conclusivly determined that the E80 SETS these on any
# routes and that these are the correct fields (more corrections
# to parseFSH)

my $ROUTE_PT_SIZE = 10;
my $ROUTE_PT_SPECS = [
	bearing		=> [ 0,	2,	'v',   ],		# 0		uint16_t;
	legLength	=> [ 1,	4,	'V',   ],		# 2		uint32_t;
	totLength 	=> [ 0, 4,	'V'	   ],		# 4		uint32_t;
];




#--------------------------------------------------------------
# wpmgrRecordToText
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


sub outputBearing
{
    my ($value) = @_;
    my $degrees = roundTwo(($value / 10000) * (180 / $PI));
	my $hex = unpack('H*',pack('v',$value));
	return "($hex) $degrees";
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
	my $seconds = $date_int * $SECS_PER_DAY;
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


sub wpmgrRecordToText
{
	my ($rec,$kind,$indent,$detail_level,$index,$wpmgr) = @_;
	my $pad = pad('',$indent);

	my $text = '';
	if (defined($index))
	{
		$text = pad('',$indent-1)."$kind($index)\n";
	}
	else
	{
		$text = "\n".$pad."$kind Record\n";
	}
	
	my $offset = 0;

	$text .= addOutput($pad,'name',$rec->{name}) if $rec->{name};
	$text .= addOutput($pad,'comment',$rec->{comment}) if $rec->{comment};
	my $alt_coords;
	$alt_coords = northEastToLatLon($rec->{north},$rec->{east})
		if defined($rec->{north}) && defined($rec->{east});

	my $all_specs =
		$kind eq 'GROUP' ? [ $GROUP_REC_SPECS ] :
		$kind eq 'ROUTE' ? [ $ROUTE_HDR1_SPECS, $ROUTE_HDR2_SPECS ] :
		$kind eq 'POINT' ? [ $ROUTE_PT_SPECS ] :
		[ $WP_REC_SPECS ];

	my $num = 1;
	for my $specs (@$all_specs)
	{
		$text .= $pad."HDR$num\n" if @$all_specs > 1;
		for (my $i = 0; $i < @$specs; $i += 2)
		{
			my ($key, $spec) = @$specs[$i, $i+1];
			my ($detail, $size, $type) = @$spec;
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
				$extra = outputDistance($val) if $key eq 'distance' || $key =~ /length/i;
				$extra = outputDepth($val) if $key eq 'depth';
				$extra = outputBearing($val) if $key eq 'bearing';

				$text .= addOutput($pad,$key,$val,$extra);
			}
		}
		$num++;
	}

	my $uuids = $rec->{uuids} || [];
	for (my $i=0; $i<@$uuids; $i++)
	{
		my $uuid = $$uuids[$i];
		if ($wpmgr && ($kind eq 'GROUP' || $kind eq 'ROUTE'))
		{
			my $wp = $wpmgr->{waypoints}->{$uuid};
			my $name = $wp ? $wp->{name} : 'unknown';
			$text .= addOutput($pad,"WP($i)","$uuid = $name");
		}
		else
		{
			$text .= addOutput($pad,"UUID($i)",$uuid);
		}
	}

	if ($kind eq 'ROUTE')
	{
		my $points = $rec->{points};
		my $num = 0;
		for my $point (@$points)
		{
			$text .= wpmgrRecordToText($point,'POINT',$indent+1,$detail_level,$num);
			$num++;
		}
	}

	return $text;
}




#------------------------------------
# Groups
#------------------------------------

sub parseGroup
	# The message itself starts with
	#		len	 command  seqnum
    #       5e00 01020f00 0f000000
	# after which the buffer starts with a dword(big_len) for the number
	# 	of bytes which follow the dword(len), which will always be
	# 	length($buffer)-4, and which is not returned by parsing
	#
	#       big_len  data
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
	# The data itself (starting at 0b0000000) is
	#	byte(name_len)
	#	byte(cmt_len)
	#	word(num_uuids)
	#   name
	#	comment if any
	#   [uuids]
{
	my ($fsh,$buffer,$mon,$color) = @_;
	my $buf_len = length($buffer);

	printConsole(2,$mon,$color,"parseGroup($fsh) len($buf_len)")
		if $mon & $MON_REC;

	my $offset = 0;
	my $big_len = 0;
	if (!$fsh)
	{
		$big_len = unpack('V',$buffer);
		$offset += 4;
		printConsole(3,$mon,$color,"big_len = $big_len")
			if $mon & $MON_REC;
	}

	my $rec = unpackRecord(
		$mon,
		$color,
		'group_hdr',
		$GROUP_REC_SPECS,
		$buffer,
		$offset,
		$GROUP_REC_SIZE);
	$offset += $GROUP_REC_SIZE;
	
	my $name = substr($buffer,$offset,$rec->{name_len});
	$offset += $rec->{name_len};
	my $comment = $rec->{cmt_len} ? substr($buffer,$offset,$rec->{cmt_len}) : '';
	$offset += $rec->{cmt_len};

	if ($mon & $MON_REC)
	{
		printConsole(3,$mon,$color,"name    = $name");
		printConsole(3,$mon,$color,"comment = $comment") if $comment;
	}

	$rec->{name} = $name;
	$rec->{comment} = $comment;
	my $uuids = $rec->{uuids} = shared_clone([]);

	for (my $i=0; $i<$rec->{num_uuids}; $i++)
	{
		my $uuid = unpack('H*',substr($buffer,$offset,8));
		printConsole(3,$mon,$color,"uuid($i) = $uuid")
			if $mon & $MON_REC;
		push @$uuids,$uuid;
		$offset += 8;
	}

	# display_hash($dbg_group+1,1,"group($name)",$rec);
	return $rec;
}


sub buildGroup
{
	my ($fsh,$rec,$mon,$color) = @_;
	my $name = $rec->{name} || '';
	my $comment = $rec->{comment} || '';
	my $uuids = $rec->{uuids} || shared_clone([]);

	$rec->{name_len} = length($name);
	$rec->{cmt_len} = length($comment);
	$rec->{uuids} = $uuids;
	$rec->{num_uuids} = @$uuids;

	printConsole(2,$mon,$color,"buildGroup($fsh) $name commant($comment) num_uuids($rec->{num_uuids})")
		if $mon & $MON_REC;

	my $buffer = packRecord(
		$mon,
		$color,
		'group',
		$rec,
		$GROUP_REC_SPECS);
	$buffer .= $name;
	$buffer .= $comment;

	my $num = 0;
	for my $uuid (@$uuids)
	{
		$buffer .= pack('H*',$uuid);
		printConsole(3,$mon,$color,"uuid($num) = $uuid")
			if $mon & $MON_REC;
		$num++;
	}

	# add big_len if !$fsh

	if (!$fsh)
	{
		my $big_len = length($buffer);
		$buffer = pack('V',$big_len).$buffer;
		printConsole(3,$mon,$color,"big_len = $big_len")
			if $mon & $MON_REC;
	}
	
	# parse check

	parseGroup($fsh,$buffer,$mon,$color) if $BUILD_CHECK_GROUP;
	return $buffer;
}



#------------------------------------
# Routes
#------------------------------------

sub parseRoute
	# The message itself starts with
	#		len	 command  seqnum
    #       5e00 01020f00 0f000000
	# after which the buffer starts with a dword(big_len) for the number
	# of bytes which follow the dword(len), which will always be
	# length($buffer)-4, and not returned by parsing
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
	my ($fsh,$buffer,$mon,$color) = @_;
	my $buf_len = length($buffer);

	printConsole(2,$mon,$color,"parseRoute($fsh) len($buf_len)")
		if $mon & $MON_REC;

	my $offset = 0;
	my $big_len = 0;
	if (!$fsh)
	{
		$big_len = unpack('V',$buffer);
		$offset += 4;
		printConsole(3,$mon,$color,"big_len = $big_len")
			if $mon & $MON_REC;
	}

	my $rec = unpackRecord(
		$mon,
		$color,
		'route_hdr1',
		$ROUTE_HDR1_SPECS,
		$buffer,
		$offset,
		$ROUTE_HDR1_SIZE);
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

	if ($mon & $MON_REC)
	{
		printConsole(3,$mon,$color,"name    = $name");
		printConsole(3,$mon,$color,"comment = $comment") if $comment;
	}

	$rec->{name} = $name;
	$rec->{comment} = $comment;
	my $uuids = $rec->{uuids} = shared_clone([]);
	my $points = $rec->{points} = shared_clone([]);

	for (my $i=0; $i<$rec->{num_wpts}; $i++)
	{
		my $uuid = unpack('H*',substr($buffer,$offset,8));
		printConsole(3,$mon,$color,"uuid($i) = $uuid")
			if $mon & $MON_REC;
		push @$uuids,$uuid;
		$offset += 8;
	}

	my $hdr2 = unpackRecord(
		$mon,
		$color,
		'hdr2',
		$ROUTE_HDR2_SPECS,
		$buffer,
		$offset,
		$ROUTE_HDR2_SIZE);
	$offset += $ROUTE_HDR2_SIZE;
	mergeHash($rec,$hdr2);
	
	for (my $i=0; $i<$rec->{num_wpts}; $i++)
	{
		my $pt = unpackRecord(
			$mon,
			$color,
			'point',
			$ROUTE_PT_SPECS,
			$buffer,
			$offset,
			$ROUTE_PT_SIZE);

		printConsole(3,$mon,$color,sprintf("point($i) = heading(%0.1f) leg(%0.1f) total(%0.1f)",
			$pt->{bearing},
			$pt->{legLength},
			$pt->{totLength}) )
			if $mon & $MON_REC_DETAILS;

		push @$points,$pt;
		$offset += $ROUTE_PT_SIZE;
	}

	# display_hash($dbg_route,1,"route($name)",$rec);
	return $rec;
}


sub buildRoute
{
	my ($fsh,$rec,$mon,$color) = @_;
	my $name = $rec->{name} || '';
	my $comment = $rec->{comment} || '';
	my $uuids = $rec->{uuids} || shared_clone([]);
	my $points = $rec->{points} || shared_clone([]);

	printConsole(2,$mon,$color,"buildRoute($name,$comment) num_uuids(".scalar(@$uuids).") num_points(".scalar(@$points).")")
		if $mon & $MON_REC;

	$rec->{name_len} = length($name);
	$rec->{cmt_len} = length($comment);
	$rec->{uuids} = $uuids;
	$rec->{points} = $points;
	my $num_wpts = $rec->{num_wpts} = @$uuids;

	my $buffer = packRecord(
		$mon,
		$color,
		'route_hdr1',
		$rec,
		$ROUTE_HDR1_SPECS);
	$buffer .= $name;
	$buffer .= $comment;

	for (my $i=0; $i<$num_wpts; $i++)
	{
		my $uuid = $$uuids[$i] || '0000000000000000';
		printConsole(3,$mon,$color,"uuid($i) = $uuid")
			if $mon & $MON_REC;
		$buffer .= pack('H*',$uuid);
	}

	$buffer .= packRecord(
		$mon,
		$color,
		'route_hdr2',
		$rec,
		$ROUTE_HDR2_SPECS);

	for (my $i=0; $i<$num_wpts; $i++)
	{
		my $pt = $$points[$i];

		printConsole(3,$mon,$color,sprintf("point($i) = heading(%0.1f) leg(%0.1f) total(%0.1f)",
			$pt->{bearing},
			$pt->{legLength},
			$pt->{totalLength}) )
			if $mon & $MON_REC_DETAILS;

		$buffer .= packRecord(
			$mon,
			$color,
			"route_pt($i)",
			$pt,
			$ROUTE_PT_SPECS);
	}

	# add big_len if !$fsh

	if (!$fsh)
	{
		my $big_len = length($buffer);
		$buffer = pack('V',$big_len).$buffer;
		printConsole(3,$mon,$color,"big_len = $big_len")
			if $mon & $MON_REC;
	}

	# parse check

	parseRoute($fsh,$buffer,$mon,$color) if $BUILD_CHECK_ROUTE;
	return $buffer;
}



#------------------------------------
# Waypoints
#------------------------------------

sub parseWaypoint
	# The WAYPOINT message itself starts with
	#       len  command  seqnum
	# 		5b00 01020f00 43000000
	# after which the buffer starts with a dword(big_len) for the number
	# 	of bytes which follow the dword(len), which will always be
	# 	length($buffer)-4, and which is generally not returned by parsing
	# followed by the length(48) waypoint data record,
	# followed by zero or more uuids.
	#		4f000000 9e449005 ecdbface c16a9f06 ad4a84c5 00000000   				  ...D.......j...J......
	#      	00000000 00000000 02010030 010000ef dc000088 4f000d0a 01000000 74657374   ...........0........O.......test
	#      	57617970 6f696e74 31777043 6f6d6d65 6e7431dc 82990ff5 67e68e              Waypoint1wpComment1.....g..
	# The general idea appears to be that the waypoint will keep
	# 	the uuid of the parent Group if it is in a Group, and/or a
	# 	list of the uuids of the Routes it is in, if it is in Routes.
{
	my ($fsh,$buffer,$mon,$color) = @_;
	my $buf_len = length($buffer);
	display($dbg_wp,0,"parseWaypoint($fsh) len($buf_len)");
	if ($buf_len < $WP_REC_SIZE)
	{
		warning($dbg_wp,1,"buffer($buf_len) is less than WP_REC_SIZE($WP_REC_SIZE) in length");
		return undef;
	}
	printConsole(2,$mon,$color,"parseWaypoint len($buf_len)")
		if $mon & $MON_REC;

	my $offset = 0;
	my $big_len = 0;
	if (!$fsh)
	{
		$big_len = unpack('V',$buffer);
		$offset += 4;
		printConsole(3,$mon,$color,"big_len = $big_len")
			if $mon & $MON_REC;
	}

	my $rec = unpackRecord(
		$mon,
		$color,
		'waypoint',
		$WP_REC_SPECS,
		$buffer,
		$offset,
		$WP_REC_SIZE);

	$offset += $WP_REC_SIZE;
	my $name = substr($buffer,$offset,$rec->{name_len});
	$offset += $rec->{name_len};
	my $comment = $rec->{cmt_len} ? substr($buffer,$offset,$rec->{cmt_len}) : '';
	$offset += $rec->{cmt_len};

	if ($mon & $MON_REC)
	{
		printConsole(3,$mon,$color,"name    = $name");
		printConsole(3,$mon,$color,"comment = $comment") if $comment;
	}

	$rec->{name} = $name;
	$rec->{comment} = $comment;
	my $uuids = $rec->{uuids} = shared_clone([]);

	my $num = 0;
	while ($offset <= $buf_len-8)
	{
		my $uuid = unpack('H*',substr($buffer,$offset,8));
		printConsole(3,$mon,$color,"uuid($num) = $uuid")
			if $mon & $MON_REC;
		push @$uuids,$uuid;
		$offset += 8;
		$num++;
	}

	display_hash($dbg_wp+1,1,"wp($name)",$rec);
	return $rec;
}



sub buildWaypoint
{
	my ($fsh,$rec,$mon,$color) = @_;
	my $name = $rec->{name} || '';
	my $comment = $rec->{comment} || '';
	$rec->{name_len} = length($name);
	$rec->{cmt_len} = length($comment);
	
	printConsole(2,$mon,$color,"buildWaypoint($name,$comment)")
		if $mon & $MON_REC;

	my $buffer = packRecord(
		$mon,
		$color,
		'waypoint',
		$rec,
		$WP_REC_SPECS);
	$buffer .= $name;
	$buffer .= $comment;
	
	my $num = 0;
	my $uuids = $rec->{uuids};
	for my $uuid (@$uuids)
	{
		printConsole(3,$mon,$color,"uuid($num) = $uuid")
			if $mon & $MON_REC;
		$buffer .= pack('H*',$uuid);
		$num++;
	}

	# add big_len if !$fsh

	if (!$fsh)
	{
		my $big_len = length($buffer);
		$buffer = pack('V',$big_len).$buffer;
		printConsole(3,$mon,$color,"big_len = $big_len")
			if $mon & $MON_REC;
	}

	# readback check

	parseWaypoint($fsh,$buffer,$mon,$color) if $BUILD_CHECK_WP;
	return $buffer;
}



#-------------------------------------------------
# Track parsing
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
	my ($buffer,$mon,$color) = @_;
	my $buf_len = length($buffer);

	printConsole(2,$mon,$color,"parseMTA len($buf_len)")
		if $mon & $MON_REC;

	my $offset = 0;
	my $rec = unpackRecord(
		$mon,
		$color,
		'mta',
		$MTA_REC_SPECS,
		$buffer,
		$offset,
		$MTA_REC_SIZE);

	my $coords = northEastToLatLon($rec->{north_start},$rec->{east_start});
	$rec->{lat_start} = $coords->{lat};
	$rec->{lon_start} = $coords->{lon};
	$coords = northEastToLatLon($rec->{north_end},$rec->{east_end});
	$rec->{lat_end} = $coords->{lat};
	$rec->{lon_end} = $coords->{lon};

	if ($mon & $MON_REC)
	{
		my $deg_lat_start = degreeMinutes($rec->{lat_start});
		my $deg_lon_start = degreeMinutes($rec->{lon_start});
		my $deg_lat_end = degreeMinutes($rec->{lat_end});
		my $deg_lon_end = degreeMinutes($rec->{lon_end});

		printConsole(3,$mon,$color,"start($deg_lat_start,$deg_lon_start)");
		printConsole(3,$mon,$color,"end  ($deg_lat_end,$deg_lon_end)");
	}

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

	# display($dbg_mta,1,"found MTA($rec->{name}) with $rec->{cnt1} points");
	# display_hash($dbg_mta,1,"parsetMTA($rec->{name}) returning",$rec);
	return $rec;
}


sub parseTRK
{
	my ($buffer,$mon,$color) = @_;
	my $buf_len = length($buffer);

	printConsole(2,$mon,$color,"parseTRK len($buf_len)")
		if $mon & $MON_REC;

	my $offset = 0;
	my $rec = unpackRecord(
		$mon,
		$color,
		'track_hdr',
		$TRACK_HEADER_SPECS,
		$buffer,
		$offset,
		$TRACK_HDR_SIZE);
	$offset += $TRACK_HDR_SIZE;

	$mon = 0 if !($mon & $MON_PACK_SUBRECORDS);
		# dont show track points unpacked (there can be 1000's of them)

	# to identify weird record from GET_TRACK of Current Track's uuid
	# if (0 && $old_rec->{k1_1} == 0)

	my $points = $rec->{points} = shared_clone([]);
	for (my $i=0; $i<$rec->{cnt}; $i++)
	{
		my $pt = unpackRecord(
			$mon,
			$color,
			'track_point',
			$TRACK_PT_SPECS,
			$buffer,
			$offset,
			$TRACK_PT_SIZE);

		my $coords = northEastToLatLon($pt->{north},$pt->{east});
		$pt->{lat} = $coords->{lat};
		$pt->{lon} = $coords->{lon};

		printConsole(3,$mon,$color,sprintf("point($i) lat(%s) lon(%s)",
			degreeMinutes($pt->{lat}),
			degreeMinutes($pt->{lon}) ))
			if $mon & $MON_REC_DETAILS;

		push @$points,$pt;
		$offset += $TRACK_PT_SIZE;
	}

	return $rec;
}



sub parsePoint
{
	my ($buffer,$mon,$color) = @_;
	my $buf_len = length($buffer);

	printConsole(2,$mon,$color,"parsePoint len($buf_len)")
		if $mon & $MON_REC;

	my $offset = 2;
		# skip garbage word efef
	my $pt = unpackRecord(
		$mon,
		$color,
		'track_point',
		$TRACK_PT_SPECS,
		$buffer,
		$offset,
		$TRACK_PT_SIZE);
	my $coords = northEastToLatLon($pt->{north},$pt->{east});
	$pt->{lat} = $coords->{lat};
	$pt->{lon} = $coords->{lon};

	printConsole(3,$mon,$color,sprintf("lat(%s) lon(%s)",
		degreeMinutes($pt->{lat}),
		degreeMinutes($pt->{lon}) ))
		if $mon & $MON_REC;

	return $pt;
}





1;