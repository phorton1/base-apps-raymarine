#---------------------------------------
# d_DBNAV.pm
#---------------------------------------
# A mcast listener that endeavors to decode Database records.
# These records are transmitted rapidly once the E80 has a fix
# and a heading, with lots of data while moving/autopilot, etc

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


#-----------------------------------
# winDBNAV API
#-----------------------------------

sub getFieldValues
{
	my ($this) = @_;
	return $this->{parser} ? $this->{parser}->{field_values} : {};
}


#---------------------------------------------------------
# instantiation
#---------------------------------------------------------
# 'become' and 'unbecome' a 'real' service with a socket

sub init
{
	my ($this) = @_;
	display($dbg_nav,0,"d_DBNAV init($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto}");
	$this->SUPER::init();
	$this->{local_ip} = $LOCAL_IP;
	return $this;
}



sub destroy
{
	my ($this) = @_;
	display($dbg_nav,0,"d_DBNAV destroy($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto}");
	$this->SUPER::destroy();
    #	delete @$this{qw(
	#		field_values
	#		instance_counters
	#		seen_records
	#		record_type
	#	)};
	return $this;
}


#--------------------------------------------
# b_sock override onIdle
#--------------------------------------------

sub onIdle
	# culls any variables who have outlived their TTL
{
	my ($this) = @_;
	return;
	lock($this);
		# return if $this->{in_record};
		# not while we are processing a record

	my $field_values = $this->getFieldValues();
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



#-------------------------------------------
# static (shark) API
#-------------------------------------------


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
	my $field_values = $this->getFieldValues();
	
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



#========================================================
#========================================================
# e_DBNAV parser
#========================================================
#========================================================

package e_DBNAV;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use a_defs;
use a_utils;
use base qw(a_parser);


my $dbg_dp = 0;

our $ONLY_CHANGED_FIELD_VALUES = 1;



sub newParser
{
	my ($class, $parent) = @_;
	display($dbg_dp,0,"e_DBNAV::newParser($parent->{name})");
	my $this = $class->SUPER::newParser($parent);
	bless $this,$class;

	$this->{field_values}		= shared_clone({});
	$this->{instance_counters} 	= shared_clone({});
		# a count, by the 'record' a field is found in,
		# of the number of instances of this field 'type',
		# to allow for semantically distinguishing multiple
		# fields of the same 'type' and 'subtype'
		# It is cleared at the top of each packet, and built as-you-go
	$this->{seen_records}		= shared_clone({});
	$this->{record_type} 		= 0;

	return $this;
}





sub parsePacket
	# DBNAV parses the packet first, and then calls the base_clase only
	# if there are some new fields to show, passing the text through
	# a member 'text' field.
{
	my ($this,$packet) = @_;
	my $is_sniffer = $this->{parent}->{is_sniffer} || 0;

	my $payload = $packet->{payload};
	my $payload_len = length($payload);
	my ($cmd_word,$sid,$num_fields) = unpack('vvV',substr($payload,0,8));

	display($dbg_dp+2,0,"e_DBNAV::parsePacket is_sniffer($is_sniffer) len($payload_len) num_fields($num_fields) only_new($ONLY_CHANGED_FIELD_VALUES)");

	if (0)	# debug only
	{
		my $cmd = $cmd_word & 0xff;
		my $dir = $cmd_word & 0xff00;
		display($dbg_dp+2,1,"e_DBNAV cmd($cmd) dir($dir)");
	}

	$this->{instance_counters} = shared_clone({});

	my $text = '';
	my $offset = 8;
	for (my $i=0; $i<$num_fields; $i++)
	{
		$text .= $this->decode_field($i,$payload,\$offset,$is_sniffer);
	}

	if ($text || $is_sniffer || !$ONLY_CHANGED_FIELD_VALUES)
	{
		$packet->{text} = $text;
		$packet->{num_fields} = $num_fields;
		$this->SUPER::parsePacket($packet);
	}

	return undef;
}




sub parseMessage
	# Displays the previously parsed text if there is any
{
	my ($this,$packet,$len,$part,$hdr) = @_;
	my $mon = $packet->{mon};
	display($dbg_dp+1,0,sprintf("e_DBNAV::parseMessage($len) mon(%04x)",$mon));
	return undef if !$this->SUPER::parseMessage($packet,$len,$part,$hdr);

	my $text = $packet->{text};
	if ($text && ($mon & $MON_PARSE))
	{
		$text = "    # DBNAV len($len) num_fields($packet->{num_fields})\n".$text;
		printConsole($packet->{color},$text,$mon);
	}

	return $packet;

}



#----------------------------------------
# decode_field primitives
#----------------------------------------

sub decodeDate
	# date encoded as days since 1970-01-01 unix epoch
{
	my ($data) = @_;
	my $date_int = unpack("v",$data);
	my $date_seconds = $date_int * $SECS_PER_DAY;
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
	my ($this,$field_num,$payload,$poffset,$is_sniffer) = @_;
	my $save_offset = $$poffset;

	# Extract the serial field_value data
	# type, len, subtype, and ttl

	my ($some_offset,$type,$len) = unpack('Vvv',substr($payload,$$poffset,8));
	$$poffset += 8;

	my $data = substr($payload,$$poffset,$len);
	$$poffset += $len;

	my ($subtype,$ttl,$zero) = unpack('CCv',substr($payload,$$poffset,4));
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
		return '' if
			$found->{data} eq $data &&
			$ONLY_CHANGED_FIELD_VALUES;
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
	$field_values->{$key} = $field_value;


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
	

	#------------------------------------------------
	# $return_it == return $text
	#------------------------------------------------
	# Ones I only want to see once in the console that either change
	# systematically (time), or while the boat is moving (latlon), or
	# not at all because they are just too complicated to deal with
	# at the moment (subrecord)

	my $return_it = 1;
	$return_it = 0 if
		$found &&
		!$this->{parent}->{is_sniffer} && (
			$decoder_name eq 'TIME' ||
			$decoder_name eq 'LATLON' ||
			$decoder_name eq 'NORTHEAST' );
	# $return_it = 0 if $decoder_name eq 'SUBRECORD';

	# Show the new/changed value in the console
	# by returning text

	if ($return_it)
	{
		my $subtype_hex= sprintf("%02x",$subtype);
		my $record_type_hex = sprintf("%02x",$record_type);

		return "        # ".
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

	return '';

}	# decode_field()



1;
