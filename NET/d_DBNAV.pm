#---------------------------------------
# d_DBNAV.pm
#---------------------------------------
# A mcast listener that endeavors to decode Database records.
# These records are only transmitted once the E80 has a fix,
# and rapidly once it has a heading.

package d_DBNAV;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time sleep);
use Pub::Utils;
use a_defs;
use a_utils;
use base qw(b_sock);

my $dbg_nav = 0;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(

		$RECORD_DEFAULT
		$RECORD_SHIP
		$RECORD_WIND
		$RECORD_WATER
		%RECORD_TYPE_NAME

		%DECODERS
	);
}


#---------------------------------------------------------
# instantiation
#---------------------------------------------------------
# 'become' and 'unbecome' a 'real' service with a socket

our $SHOW_DBNAV_RAW_INPUT 		= 0;
our $SHOW_DBNAV_RAW_OUTPUT		= 1;
our $SHOW_DBNAV_PARSED_INPUT  	= 0;
our $SHOW_DBNAV_PARSED_OUTPUT	= 0;

my $IN_COLOR = $UTILS_COLOR_LIGHT_GREEN;
my $OUT_COLOR = $UTILS_COLOR_YELLOW;


sub init
{
	my ($this) = @_;
	display($dbg_nav,0,"d_DBNAV init($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto}");

	$this->SUPER::init();

	$this->{show_raw_input} 	= $SHOW_DBNAV_RAW_INPUT;
	$this->{show_raw_output} 	= $SHOW_DBNAV_RAW_OUTPUT;
	$this->{show_parsed_input}  = $SHOW_DBNAV_PARSED_INPUT;
	$this->{show_parsed_output} = $SHOW_DBNAV_PARSED_OUTPUT;
	$this->{in_color} 			= $IN_COLOR;
	$this->{out_color} 			= $OUT_COLOR;

	$this->{field_values}		= shared_clone({});
	$this->{instance_counters} 	= shared_clone({});
	$this->{seen_records}		= shared_clone({});
	$this->{record_type} 		= 0;
	
		# a count, by the 'record' a field is found in
		# of the number of instances of this field 'type',
		# to allow for semantically distinguishing multiple
		# fields of the same 'type' and 'subtype'
		# It is cleared at the top of each packet, and built as-you-go
		
	return $this;
}



sub destroy
{
	my ($this) = @_;
	display($dbg_nav,0,"d_DBNAV destroy($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto}");

	$this->SUPER::destroy();

    delete @$this{qw(
		field_values
		instance_counters
		seen_records
		record_type
	)};
	return $this;
}



#----------------------------------------
# handlePacket primitives
#----------------------------------------

sub decodeDate
	# date encoded as days since 1970-01-01 unix epoch
{
	my ($data) = @_;
	my $date_int = unpack("v",$data);
	my $date_seconds = $date_int * 86400;
	my ($sec, $min, $hour, $mday, $mon, $year) = gmtime($date_seconds);
	$year += 1900;
	$mon  += 1;
	$mon = pad2($mon);
	$mday = pad2($mday);
	return "$year-$mon-$mday";
}

sub decodeTime
	# time encoded as 1/10000's of a second
{
	my ($data) = @_;
	my $time_int = unpack("V",$data);
	my $sec = int($time_int/10000);
	my $min = int($sec/60);
	my $hour = int($min/60);
	$sec = $sec % 60;
	$min = $min % 60;
	$hour = pad2($hour);
	$min = pad2($min);
	$sec = pad2($sec);
	return "$hour:$min:$sec";
}

sub decodeDepth
	# depth encoded as centimeters
{
	my ($data) = @_;
	my $depth_int = unpack("V",$data);
	my $depth = roundTwo(($depth_int / 100) * $FEET_PER_METER);
	return $depth;
}

sub decodeHeading
{
    my ($data) = @_;
    my $head_int = unpack("v", $data);
    my $deg = roundTwo(($head_int / 10000) * (180 / $PI));
    return $deg;
}


sub decodeCentiMetersPerSec
	# speed encoded as centimeters per second
{
	my ($data) = @_;
	my $int = unpack("v",$data);
	my $speed = sprintf("%0.1f",$int / (100 * $KNOTS_TO_METERS_PER_SEC));
	return $speed;
}


sub decodeDeciMetersPerSec
	# speed encoded as meters per second
{
	my ($data) = @_;
	my $int = unpack("v",$data);
	my $speed = sprintf("%0.1f",$int / (10 * $KNOTS_TO_METERS_PER_SEC));
	return $speed;
}


sub decodeMetersPerSec
	# speed encoded as meters per second
{
	my ($data) = @_;
	my $int = unpack("v",$data);
	my $speed = sprintf("%0.1f",$int / $KNOTS_TO_METERS_PER_SEC);
	return $speed;
}




sub decodeCoord
{
	my ($data) = @_;
	my $l = unpack('l',$data) / $SCALE_LATLON;
	return $l;
}

sub decodeLatLon
{
	my ($data) = @_;
	my $text =
		decodeCoord(substr($data,0,4)).",".
		decodeCoord(substr($data,4,4));
	return $text;
}


sub decodeNorthEast
{
	my ($data) = @_;
	my ($north,$east) = unpack('ll',$data);
	return "$north,$east";
}


sub decodeName16
{
	my ($data) = @_;
	return unpack('Z*',$data);
}


sub decodeSubRecord
{
	my ($data,$subtype,$header_len) = @_;
	my $text = "";
	my $num = 0;
	my $offset = 0;
	my $len = 1;
	while ($len && $offset < length($data))
	{
		$len = unpack('C',substr($data,$offset,1));
		$offset += 1;
		my $subdata = unpack('H*',substr($data,$offset,$len));
		$text .= "\n";
		$text .= pad('',16)."sub($num) len($len) = $subdata";
		$offset += $len;
		$num++;
	}
	return $text;
}


#------------------------------------------
# decode_field
#------------------------------------------
#	type	len			field			preceded by
#	2a00	0200		HEAD(DEV)		4700 0000
#	2a00	0200		HEAD(ABS)		1a00 0000												undifferentated
#	0100	0200		SOG				0400 0000
#	0400	0400		TIME			1200 0000
#	0300	0200		DATE			1300 0000
#	3c00	0800		LATLON			4400 0000
#	0e00	0400		DEPTH			0900 0000
#
# The 0th speed given appears to be SOG (no record prefix)
#
# The WINDSPEEDS given appear to be TRUE then RELATIVE
# 	within 'record type' 80a8, which has a value of '3c00';
#
# type(0x51) is a big record, of 256, with a ttl of 31


# this hash gives presumed names to the 'record types' within a packet,
# which are identified with 0x8000 in the type word.  They demarcate
# the packet into different semantic sections.

our $RECORD_DEFAULT = 0xff;
our $RECORD_SHIP 	= 0x07;
our $RECORD_WIND 	= 0x0a;
our $RECORD_WATER 	= 0x05;

our %RECORD_TYPE_NAME = (
	$RECORD_DEFAULT => 'default',
	$RECORD_SHIP	=> 'ship',
	$RECORD_WIND	=> 'wind',
	$RECORD_WATER	=> 'water',
);


# This hash defines the storage type of field_values in the packet.
# A number of the field's semantics must be determined by looking at
# the subtype, record_type, and/or instance within the 'record'

our %DECODERS = (
	0x00 => { name => 'WINDSPEED',	fxn => \&decodeDeciMetersPerSec,  },
	0x01 => { name => 'SPEED',		fxn => \&decodeCentiMetersPerSec,  },
	0x04 => { name => 'TIME',		fxn => \&decodeTime,      },
	0x03 => { name => 'DATE',		fxn => \&decodeDate,      },
	0x0e => { name => 'DEPTH',		fxn => \&decodeDepth,     },
	0x2a => { name => 'HEAD',		fxn => \&decodeHeading,   },
	0x3c => { name => 'LATLON',		fxn => \&decodeLatLon,    },
	0x5a => { name => 'SUBRECORD',	fxn => \&decodeSubRecord, },
	0x73 => { name => 'NORTHEAST',	fxn => \&decodeNorthEast, },
	0xaf => { name => 'STRING',		fxn => \&decodeName16	  }
);




sub decode_field
{
	my ($this,$field_num,$raw,$poffset) = @_;
	my $save_offset = $$poffset;

	# Extract the serial field_value data
	# type, len, subtype, and ttl

	my ($some_offset,$type,$len) = unpack('Vvv',substr($raw,$$poffset,8));
	$$poffset += 8;

	my $data = substr($raw,$$poffset,$len);
	$$poffset += $len;

	my ($subtype,$ttl,$zero) = unpack('CCv',substr($raw,$$poffset,4));
	$$poffset += 4;

	error("unexpected value for zero($zero)") if $zero != 0;

	
	# Get the storage type decoder and
	# Set the running record type

	my $decoder = $DECODERS{$type};
	my $decoder_name = $decoder ? $decoder->{name} : 'UNKNOWN';

	my $is_record = 0;
	if ($type & 0x8000)
	{
		$is_record = 1;
		$type &= ~0x8000;
		my $record_type = $subtype; #.$data_hex;
		$this->{record_type} = $record_type;
	}
	$this->{record_type} ||= $RECORD_SHIP;
		# empirically derived default record type = ship's info


	# Group field_values I consider to only take on one value, regardless
	# of subtype or record_type, under record_type(ff) and subtype(ff)

	my $record_type = $this->{record_type};
	if ($decoder_name =~ /^(DATE|TIME|DEPTH|LATLON|NORTHEAST|SUBRECORD)$/)
	{
		$record_type = $RECORD_DEFAULT;
		$subtype = 0xff;
	}


	# Get the instance of this field_value storage type
	# within the given record_type; the position is used
	# to decipher fields_values (i.e. HEAD) that appear more
	# than once in a 'record'

	my $instance_counters = $this->{instance_counters};
	$instance_counters->{$record_type} ||= shared_clone({});
	my $instances = $instance_counters->{$record_type};

	my $instance_key = "$type";	#.$subtype";
	$instances->{$instance_key} = defined($instances->{$instance_key}) ? ++$instances->{$instance_key} :  0;
	my $instance = $instances->{$instance_key};


	# See if the stored field_value (data) has changed.
	# if not, assign the possibly changed ttl and return.

	my $field_values = $is_record ? $this->{seen_records} : $this->{field_values};
	my $key = "$type.$subtype.$record_type.$instance";
	my $found = $field_values->{$key};

	if ($found)
	{
		$found->{ttl} = $ttl;
		$found->{time} = time();
		return '' if $found->{data} eq $data;
		$found->{data} = $data;
	}


	# Use the found field_value, or create a new instance

	my $field_value = $found || shared_clone({
		time		=> time(),
		ttl			=> $ttl,
		type 		=> $type,
		subtype 	=> $subtype,
		is_record	=> $is_record,
		record_type => $record_type,
		instance 	=> $instance,
		data 		=> $data, });
	$field_values->{$key} = $field_value if !$found;


	# DECODE THE STORAGE VALUE

	my $data_hex = unpack('H*',$data);
	my $fxn = $decoder ? $decoder->{fxn} : 0;
	my $value = $fxn ? &{$fxn}($data) : $data_hex;
	$field_value->{value} = $value;
	

	# CHARACTERIZE KNOWN VALUES INTO field names
	# very messed up and complicated heuristic

	my $type_hex = sprintf("%02x",$type);
	my $name = "unknown_$type_hex";

	my $record_type_name = $RECORD_TYPE_NAME{$record_type} || "unknown($record_type)";
	$name = " ------$record_type_name---------"
		if $is_record;

	$name = lc($decoder_name)
		if $decoder_name =~ /^(TIME|DATE|DEPTH|LATLON|NORTHEAST|SUBRECORD)$/;

	if ($record_type == $RECORD_SHIP)
	{
		# seatalk, subtype(09), rec 07, inst(0) by itself is 'heading'
		
		$name = 'sog'
			if $decoder_name eq 'SPEED';

		my $postfix =
			$subtype == 0x0e ? 'Mag' :		# proper NMEA0183 mag (instance 0)
			$subtype == 0x05 ? 'True' :		# proper NMEA0183 true (instance 1)
			$subtype == 0x0f ? 'True' :		# proper Seatlk true (instance 0)
			'Mag';							# subtype(0x09) = proper Seatalk mag (instance 1)
		$name = "cog$postfix" if $decoder_name eq 'HEAD';
	}
	elsif ($record_type == $RECORD_WIND)
	{
		my $prefix =
			$subtype == 0x09 ? 'app' :		# proper NMEA0183 apparent
			$subtype == 0x0a ? 'true' :		# proper NMEA0183 true,
			$instance == 1   ? 'true' :		# subtype(05) discernable by instance only
			'app';
		$name = $prefix."WindSpeed" if $decoder_name eq 'WINDSPEED';
		$name = $prefix."WindAngle" if $decoder_name eq 'HEAD';
	}
	elsif ($record_type == $RECORD_WATER)
	{
		$name = ($instance == 1 ? 'waterSpeedAbs' : 'waterSpeedRel')
			if $decoder_name eq 'SPEED';
		$name = ($subtype == 0x0e ? 'waterAngleMag' : 'waterAngleTrue')
			if $decoder_name eq 'HEAD';
	}

	$field_value->{name} = $name;
	

	# Ones I only want to see once in the console that either change
	# systematically (time), or while the boat is moving (latlon), or
	# not at all because they are just too complicated to deal with
	# at the moment (subrecord)

	my $showit = 1;
	$showit = 0 if $found && (
			$decoder_name eq 'TIME' ||
			$decoder_name eq 'LATLON' ||
			$decoder_name eq 'NORTHEAST' );
	# $showit = 0 if $decoder_name eq 'SUBRECORD';


	# Show the new/changed value in the console
	# by returning text

	if ($showit)
	{
		my $subtype_hex= sprintf("%02x",$subtype);
		my $record_type_hex = sprintf("%02x",$record_type);

		return "        ".
			pad("field($field_num)",10).
			pad("offset($save_offset)=$some_offset",16).
			pad("type($type_hex)",9).
			pad("len($len)",9).
			pad("subtype($subtype_hex)",12).
			pad("ttl($ttl)",8).
			pad("rec($record_type_hex)",10).
			pad("inst($instance)",8).
			pad($name,14).
			"= ".
			$value.
			"\n";
	}
	
	# or don't show it by returninng ''

	return '';

}	# decode_field()



#--------------------------------------------------------------
# handlePacket, cull, and show the values
#--------------------------------------------------------------


sub handlePacket
	# 00 03 1000 01000000
	# ... 17000000 2a000200 89780e01 0000
{
	my ($this,$packet) = @_;
	my ($cmd,$dir,$sid,$num_fields) = unpack('CCvV',$packet);
	my $packet_len = length($packet);
	my $offset = 8;

	$this->{instance_counters} = shared_clone({});

	$this->{in_record} = 1;
		# entrancy protection for winDBNAV

	my $text = '';
	for (my $i=0; $i<$num_fields; $i++)
	{
		$text .= $this->decode_field($i,$packet,\$offset);
	}


	if ($text)
	{
		$text = "    DATABASE len($packet_len) cmd($cmd) dir($dir) sid($sid) num_fields($num_fields)\n".$text;
		setConsoleColor($this->{in_color}) if $this->{in_color};
		print $text;
		setConsoleColor() if $this->{in_color};
	}

	$this->cullTTL();
	$this->{in_record} = 0;
		# entrancy protection for winDBNAV

}	# decodeDBNAV()



sub cullTTL
{
	my ($this) = @_;
	my $field_values = $this->{field_values};
	my $now = time();
	for my $key (keys %$field_values)
	{
		my $field_value = $field_values->{$key};
		my $time = $field_value->{time};
		my $ttl = $field_value->{ttl};
		if ($now > $time + $ttl)
		{
			my $type_hex = sprintf("%02x",$field_value->{type});
			my $subtype_hex = sprintf("%02x",$field_value->{subtype});
			my $rectype_hex = sprintf("%02x",$field_value->{record_type});
			my $instance = $field_value->{instance};
			my $name = $field_value->{name};
			my $value = $field_value->{value};
			warning($dbg_nav,0,"Culling type($type_hex) subtype($subtype_hex) rec($rectype_hex) inst($instance) $name = $value");

			delete $field_values->{$key};
		}
	}
}



sub cmpValues
{
	my ($field_values,$key_a,$key_b) = @_;
	my $field_a = $field_values->{$key_a};
	my $field_b = $field_values->{$key_b};
	my $cmp = $field_a->{record_type} <=> $field_b->{record_type};
	return $cmp if $cmp;
	return $field_a->{name} cmp $field_b->{name};
}

sub showValues
{
	my ($this) = @_;
	my $field_values = $this->{field_values};
	my $text = "-------------------------------- DBNAV field_values ------------------------------------\n";
	
	for my $key (sort {cmpValues($field_values,$a,$b)} keys %$field_values)
	{
		my $field_value = $field_values->{$key};

		my $ttl = $field_value->{ttl};
		my $type_hex = sprintf("%02x",$field_value->{type});
		my $subtype_hex = sprintf("%02x",$field_value->{subtype});
		my $rectype_hex = sprintf("%02x",$field_value->{record_type});
		my $instance = $field_value->{instance};
		my $name = $field_value->{name};
		my $value = $field_value->{value};

		next if $name eq 'subrecord';
			# not ready to deal with this

		$text .=
			pad("ttl($ttl)",8).
			pad("type($type_hex)",9).
			pad("subtype($subtype_hex)",12).
			pad("rec($rectype_hex)",10).
			pad("inst($instance)",8).
			pad($name,14).
			"= ".
			$value.
			"\n";
	}

	print $text;
}


1;
