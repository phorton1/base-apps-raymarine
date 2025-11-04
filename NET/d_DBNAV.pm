#---------------------------------------
# d_DBNAV.pm
#---------------------------------------
# A mcast listener that endeavors to decode mcast DB records.
# These records are transmitted rapidly once the E80 has a fix
# and a heading, with lots of data while moving/autopilot, etc,
# and are setup for broadcast in d_DB.pm

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
	lock($this);
		# return if $this->{in_record};
		# not while we are processing a record

	my $field_values = $this->getFieldValues();
	my $now = time();
	for my $fid (sort {$a <=> $b} keys %$field_values)
	{
		my $field_value = $field_values->{$fid};
		my $time = $field_value->{time};
		my $ttl = $field_value->{ttl};
		if ($now > $time + $ttl)
		{
			my $name = $field_value->{name};
			my $value = $field_value->{value};
			warning($dbg_nav,0,sprintf("Culling fid(%02x) $name = $value",$fid));
			delete $field_values->{$fid};
		}
	}
}



#-------------------------------------------
# static (shark) API
#-------------------------------------------



sub showValues
{
	my ($this) = @_;
	my $field_values = $this->getFieldValues();
	
	my $text = "-------------------------------- DBNAV field_values ------------------------------------\n";

	for my $fid (sort {$a <=> $b} keys %$field_values)
	{
		my $field_value = $field_values->{$fid};

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
			sprintf("fid(%02x) ",$fid).
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
use a_mon;
use a_utils;
use d_DB;
use base qw(a_parser);


my $dbg_dp = 0;

our $ONLY_CHANGED_FIELD_VALUES = 0;



sub newParser
{
	my ($class, $mon_defs) = @_;
	display($dbg_dp,0,"e_DBNAV::newParser($mon_defs->{name})");
	my $this = $class->SUPER::newParser($mon_defs);
	bless $this,$class;
	$this->{field_values}		= shared_clone({});
	return $this;
}





sub parsePacket
	# DBNAV parses the packet first, and then calls the base_clase only
	# if there are some new fields to show, passing the text through
	# a member 'text' field.
{
	my ($this,$packet) = @_;
	my $is_sniffer = $packet->{is_sniffer} || 0;
	my $mon = $packet->{mon};

	my $payload = $packet->{payload};
	my $payload_len = length($payload);
	my ($cmd_word,$sid,$num_fields) = unpack('vvV',substr($payload,0,8));

	display($dbg_dp+2,0,"e_DBNAV::parsePacket is_sniffer($is_sniffer) len($payload_len) num_fields($num_fields) ".
			sprintf("mon(%04x) only_new($ONLY_CHANGED_FIELD_VALUES)",$mon));

	if (0)	# debug only
	{
		my $cmd = $cmd_word & 0xff;
		my $dir = $cmd_word & 0xff00;
		display($dbg_dp+2,1,"e_DBNAV cmd($cmd) dir($dir)");
	}

	$this->{instance_counters} = shared_clone({});

	my $text = '';
	my $offset = 8;
	my $MIN_RECORD_SIZE = 12;		# and that's with a 0 length data field
	for (my $i=0; $i<$num_fields && $offset < $payload_len-$MIN_RECORD_SIZE;  $i++)
	{
		$text .= $this->decode_field($i,$payload,\$offset,$is_sniffer);
	}

	if ($offset != $payload_len)
	{
		error("parsing DBNAV packet cmd($cmd_word) num_fields($num_fields) offset($offset) payload_len($payload_len):\n".
			  parse_dwords('    ',$payload,1));
		
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
	my ($this,$packet,$len,$part) = @_;
	my $mon = $packet->{mon};
	my $color = $packet->{color};
	display($dbg_dp+1,0,sprintf("e_DBNAV::parseMessage($len) mon(%04x)",$mon));
	return undef if !$this->SUPER::parseMessage($packet,$len,$part);

	my $text = $packet->{text};
	if ($text && ($mon & $MON_PARSE))
	{
		printConsole(1,$mon,$color,"DBNAV len($len) num_fields($packet->{num_fields})");
		for my $line (split(/\n/,$text))
		{
			next if !$line;
			printConsole(2,$mon,$color,$line);
		}
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


sub showTime
{
	my ($sec) = @_;
	my $min = int($sec/60);
	my $hour = int($min/60);
	$sec = $sec % 60;
	$min = $min % 60;
	$hour = pad2($hour);
	$min = pad2($min);
	$sec = pad2($sec);
	return "$hour:$min:$sec";
}

sub decodeTime
	# time encoded as 1/10000's of a second
{
	my ($data) = @_;
	my $secs = int(unpack("V",$data) / 10000);
	return showTime($secs);
}

sub decodeSeconds
{
	my ($data) = @_;
	my $secs = unpack("V",$data);
	return showTime($secs);
}


sub decodeDepth
	# depth encoded as centimeters
{
	my ($data) = @_;
	my $depth_int = unpack("V",$data);
	my $depth = sprintf("%0.1f",($depth_int / 100) * $FEET_PER_METER);
	return $depth;
}

sub decodeHeading
{
    my ($data) = @_;
    my $head_int = unpack("v", $data);
    my $deg = sprintf("%0.1f",($head_int / 10000) * (180 / $PI));
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


sub decodeDistanceMeters
	# distance in meters
{
	my ($data) = @_;
	my $meters = unpack('V',$data);
	return sprintf("%0.2f",$meters / $METERS_PER_NM);
}

sub decodeDistanceCentiMeters
	# distance in centimeters
{
	my ($data) = @_;
	my $meters = unpack('V',$data);
	return sprintf("%0.3f",$meters / (100 * $METERS_PER_NM));
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


sub decodeStringNul
	# actuall null terminated string
{
	my ($data) = @_;
	return unpack('Z*',$data);
}


sub decodeWordOver100
	# divide a word by 100 and return it with 2 decimal places
{
	my ($data) = @_;
	return sprintf("%0.2f",unpack('v',$data) / 100);
}

sub decodeIntWordOver4
	# divide a word by 4 and return it as an int
{
	my ($data) = @_;
	return int(unpack('v',$data) / 4);
}

sub decodeWordOver250
	# divide a word by 100 and return it with 2 decimal places
{
	my ($data) = @_;
	return sprintf("%0.2f",unpack('v',$data) / 250);
}


sub decodeMillibarsToPSI
	# convert word millibars to PSI with one decimal place
{
	my ($data) = @_;
	my $mbars = unpack('v',$data);
	return sprintf("%0.1f",$mbars / $PSI_TO_MILLIBARS);
}

sub decodeKelvinOver10
	# convert 1/10s of kelvin to Farenheight with 1 decimal palce
{
	my ($data) = @_;
	my $kelvin = unpack('v',$data) / 10;
	return sprintf("%0.1f",($kelvin - 273.15) * 9/5 + 32);
}
sub decodeKelvinOver100
	# convert 1/100s of kelvin to Farenheight with 1 decimal palce
{
	my ($data) = @_;
	my $kelvin = unpack('v',$data) / 100;
	return sprintf("%0.1f",($kelvin - 273.15) * 9/5 + 32);
}
sub decodeDeciLitresToGallons
{
	my ($data) = @_;
	my $litres = unpack('v',$data) / 10;
	return sprintf("%0.2f",$litres / $GALLONS_TO_LITRES);
}
sub decodeString
{
	my ($data) = @_;
	return unpack('A*',$data);
		# A* trims trailing spaces, a* doesnt
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



our %DECODERS = (
	'date'      			=> \&decodeDate,
	'time'      			=> \&decodeTime,
	'seconds'				=> \&decodeSeconds,
	'depth' 	  			=> \&decodeDepth,
	'heading'    			=> \&decodeHeading,
	'centiMetersPerSec'		=> \&decodeCentiMetersPerSec,
	'deciMetersPerSec'		=> \&decodeDeciMetersPerSec,
	'metersPerSec'    		=> \&decodeMetersPerSec,
	'latLon'    			=> \&decodeLatLon,
	'northEast' 			=> \&decodeNorthEast,
	'stringNul'   			=> \&decodeStringNul,
	'subRecord'   			=> \&decodeSubRecord,
	'distanceMeters'		=> \&decodeDistanceMeters,
	'distanceCentiMeters'	=> \&decodeDistanceCentiMeters,
	'wordOver100'			=> \&decodeWordOver100,
	'intWordOver4'			=> \&decodeIntWordOver4,
	'millibarsToPSI'		=> \&decodeMillibarsToPSI,
	'kelvinOver10'			=> \&decodeKelvinOver10,
	'kelvinOver100'			=> \&decodeKelvinOver100,
	'deciLitresToGallons'   => \&decodeDeciLitresToGallons,
	'wordOver250'			=> \&decodeWordOver250,
	'string'			    => \&decodeString,
);



sub decode_field
{
	my ($this,$field_num,$payload,$poffset,$is_sniffer) = @_;
	my $save_offset = $$poffset;

	# Extract the serial field_value data
	# type, len, subtype, and ttl
	# some packets have some extra bytes, perhaps identifying a record the fields belong to?

	my ($fid,$type,$len) = unpack('Vvv',substr($payload,$$poffset,8));
	$$poffset += 8;
	my $data = substr($payload,$$poffset,$len);
	$$poffset += $len;
	my ($subtype,$ttl,$extra_len) = unpack('CCv',substr($payload,$$poffset,4));
	$$poffset += 4;
	my $extra_hex = $extra_len ? unpack('H*',substr($payload,$$poffset,$extra_len)) : '';
	$$poffset += $extra_len;

	# Update and possibly short return on found values

	my $is_new = 1;
	my $field_values = $this->{field_values};
	my $found = $field_values->{$fid};
	if ($found)
	{
		$is_new = 0;
		$found->{ttl} = $ttl;
		$found->{time} = time();
		my $old_data = $found->{data};
		$found->{data} = $data;

		return '' if $ONLY_CHANGED_FIELD_VALUES &&
			$old_data eq $data;
	}

	# Use the found field_value, or create a new instance

	my $field_def = $DB_FIELDS{$fid};
	my $name = $field_def ? $field_def->{name} : sprintf("UNKNOWN(%02x)",$fid);
	$name = 'SUBRECORD' if $fid == 0x76;

	if (!$found)
	{
		$found = shared_clone({
			fid			=> $fid,
			name		=> $name,
			time		=> time(),
			ttl			=> $ttl,
			type 		=> $type,
			subtype 	=> $subtype,
			extra		=> $extra_hex,
			data 		=> $data, });
		$field_values->{$fid} = $found;

		$self_db->{exists}->{$fid} = 1 if $self_db;
	}


	# DECODE THE RAW STORAGE VALUE

	my $data_hex = unpack('H*',$data);

	my $decoder_type = $field_def ? $field_def->{type} : '';
	my $fxn = $DECODERS{$decoder_type};
	my $value = $fxn ? &{$fxn}($data) : $data_hex;

	# add other information

	if ($fid == $DB_FIELD_WIND_ANGLE_APP ||		# winds are given true bearing relative to the bow
		$fid == $DB_FIELD_WIND_ANGLE_TRUE)
	{
		my $show = $value;		# the entire rebuilt mess
		my $true = '';			# convert to actual absolute true bearing (coming from)
		my $ground = '';		# convert to magnetic bow relaltive true to match E80
		my $head_fid = 0x17;
		my $head_rec = $field_values->{$head_fid};
		if ($head_rec)
		{
			my $head = $head_rec->{value};
			$true = ($value + $head) % 360;
			$true = " ".sprintf("%0.1f",$true)."T";
				# this now corresponds to the Absolute True wind direction, which
				# is not shown anywhere on the E80 except for the arrow.

			my $head_mag_fid = 0x47;
			my $head_mag_rec = $field_values->{$head_mag_fid};
			if ($head_mag_rec)
			{
				my $mag = $head_mag_rec->{value};
				$ground = (360 + $value + $mag - $head) % 360;
				$ground = " ".$ground."G";
					# The E80 shows "Ground Wind" as Magnetic, and still relative
					# to the bow, which I calculate here for a sanity check
			}

		}
		if ($value > 180)
		{
			$show .= " = ".sprintf("%0.1f",360 - $value)."P";
		}
		else
		{
			$show  .= " = ".$value."S";
		}
		$show .= $true.$ground;
		$value = $show;
	}

	$found->{value} = $value;

	#------------------------------------------------
	# $return_it == return $text
	#------------------------------------------------
	# Ones I only want to see once in the console that either change
	# systematically (time), or while the boat is moving (latlon), or
	# not at all because they are just too complicated to deal with
	# at the moment (subrecord)

	my $return_it = 1;
	#	$return_it = 0 if
	#		!$is_new &&
	#		!$is_sniffer && (
	#			$name eq 'TIME' ||
	#			$name =~ 'LATLON' ||
	#			$name eq 'NORTHEAST' );
	#	$return_it = 0 if !$is_sniffer && $name eq 'SUBRECORD';

	# Show the new/changed value in the console
	# by returning text

	if ($return_it)
	{
		return 
			pad($field_num,2).':'.
			pad($save_offset,3).' '.
			sprintf("fid(%02x)",$fid)." ".
			sprintf("type(%04x:%02x) ",$type,$subtype).
			pad("ttl($ttl)",8).
			pad("len($len)",9).
			pad($name,14).
			"= ".
			pad($value,24).
			($fxn ? "'$data_hex'" : '').
			($extra_hex ? "  extra=$extra_hex" : '').
			"\n";
	}

	return '';

}	# decode_field()



1;
