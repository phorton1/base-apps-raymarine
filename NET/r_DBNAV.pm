#---------------------------------------
# r_DBNAV.pm
#---------------------------------------
# This package endeavors to decode NAVSTAT udp multicast packet.
#
# These packets are sent out fairly rapidly once the MFD has a
# GPS fix and/or is "underway".
#
# The record structure is exceedingly complex, pointing to
# years of evolution in development, with many different
# types, and versions, of records.
#
# The code herein is currently working poorly after a rapid
# port, without much debugging, from raynet_old.pm

package r_DBNAV;
use strict;
use warnings;

use Pub::Utils;
use r_units;
use r_utils;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
		decodeDBNAV
	);
}



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
    my ($data, $subtype) = @_;
    my $head_int = unpack("v", $data);
    my $deg = roundTwo(($head_int / 10000) * (180 / $PI));

    # my %subtype_map = (
    #     '05060000' => 'COG',         # Course Over Ground
    #     '0a050000' => 'TrueWind',    # True Wind Direction
    #     '0e060000' => 'AppWind',     # Apparent Wind Direction
    #     # Add more as you empirically confirm them
    # );
    #
    # my $label = $subtype_map{$subtype} || 'HEAD';

    return $deg;
}


sub decodeSOG
	# sog encoded as centimeters per second
{
	my ($data) = @_;
	my $sog_int = unpack("v",$data);
	my $sog = sprintf("%0.1f",$sog_int / (100 * $KNOTS_TO_METERS_PER_SEC));
	return $sog;
}


sub decodeCoord
{
	my ($what,$data) = @_;
	my $l = unpack('l',$data) / $SCALE_LATLON;
	my $l_min = degreeMinutes($l);
	return sprintf("$what %0.6f	$l_min",$l);
}

sub decodeLatLon
{
	my ($data,$subtype,$field_header_len) = @_;
	my $text =
		decodeCoord("LAT",substr($data,0,4))."\n".
		pad('',$field_header_len).
		decodeCoord("LON",substr($data,4,4));
	return $text;
}

sub decodeName16
{
	my ($data) = @_;
	return unpack('Z*',$data);
}


#	type	len			field			preceded by
#	2a00	0200		HEAD(DEV)		4700 0000
#	2a00	0200		HEAD(ABS)		1a00 0000												undifferentated
#	0100	0200		SOG				0400 0000
#	0400	0400		TIME			1200 0000
#	0300	0200		DATE			1300 0000
#	3c00	0800		LATLON			4400 0000
#	0e00	0400		DEPTH			0900 0000

my %decoders = (
	0x01 => { name => 'SOG',		fxn => \&decodeSOG,       },
	0x04 => { name => 'TIME',		fxn => \&decodeTime,      },
	0x03 => { name => 'DATE',		fxn => \&decodeDate,      },
	0x0e => { name => 'DEPTH',		fxn => \&decodeDepth,     },
	0x2a => { name => 'HEAD',		fxn => \&decodeHeading,   },
	0x3c => { name => 'LATLON',		fxn => \&decodeLatLon,    },
	0xaf => { name => 'STRING',		fxn => \&decodeName16	  }
);



sub decode_field
{
	my ($raw,$poffset) = @_;
	my $save_offset = $$poffset;

	my $some_offset = unpack('V',substr($raw,$$poffset,4));
	$$poffset += 4;

	my $type_bytes = substr($raw,$$poffset,2);
	my $type_hex = unpack('H*',$type_bytes);
	my $type = unpack('v',$type_bytes);
	$$poffset += 2;
	my $len = unpack('v',substr($raw,$$poffset,2));
	$$poffset += 2;

	my $data = substr($raw,$$poffset,$len);
	$$poffset += $len;

	my $subtype = unpack('H*',substr($raw,$$poffset,4));
	# there's a dword I don't understand
	$$poffset += 4;

	my $SHOW_ALL = 1;

	my $decoder = $decoders{$type};
	return '' if !$SHOW_ALL && !$decoder;

	my $name = $decoder ? $decoder->{name} : 'UNKNOWN';
	$name = "--------------" if $type & 0x8000;
	my $fxn = $decoder ? $decoder->{fxn} : 0;

	my $hex = unpack('H*',$data);
	my $text = "        offset($save_offset)=$some_offset type($type_hex) len($len) subtype($subtype) $name";
	if ($fxn)
	{
		$text .= "($hex) = ";
		$text .= &{$fxn}($data,$subtype,length($text));
	}
	else
	{
		$text .= " = ".$hex;
	}
	
	$text .= "\n";
	return $text;
}


sub decodeDBNAV
{
	my ($packet) = @_;
	my $raw = $packet->{raw_data};

	my $command = unpack('v',substr($raw,0,2));
	my $func = unpack('v',substr($raw,2,2));
	my $num_fields = unpack('V',substr($raw,4,4));
	my $offset = 8;

	my $text = sprintf("    DATABASE command(%04x) func(%d) num_fields($num_fields)\n",$command,$func);

	my $packet_len = length($raw);
	while ($offset < $packet_len)
	{
		$text .= decode_field($raw,\$offset);
	}

	setConsoleColor($UTILS_COLOR_GREEN);
	print $text;
	setConsoleColor();

}	# decodeDBNAV()



1;
