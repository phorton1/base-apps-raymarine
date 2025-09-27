#---------------------------------------
# r_NAVSTAT.pm
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

package r_NAVSTAT;
use strict;
use warnings;
use r_utils;
use Pub::Utils;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (
		decodeNAVSTAT
	);
}


my $SCALE_LATLON = 1e-7;
my $PI = 3.1415926535;
my $METERS_TO_FEET = 3.28084;
my $KNOTS_TO_METERS_PER_SEC = 0.5144;


# scheme cannot encode offset(0)
# some records might have duplicates that could be encoded as separate fields

my $FTYPE_DATE      = 0;
my $FTYPE_TIME      = 1;
my $FTYPE_DEPTH     = 2;
my $FTYPE_HEAD_DEV	= 3;
my $FTYPE_HEAD_ABS  = 4;
my $FTYPE_SOG       = 5;
my $FTYPE_LAT       = 6;
my $FTYPE_LON       = 7;
my $FTYPE_SOG2      = 8;
my $NUM_FTYPES      = 9;


sub getFields
	# returns undef for uknown type, or
	# returns an array, sorted by offset
	# of [offset, field_type, field_len];
{
	my ($type, $version) = @_;

	my $fields = {};
	if ($type == 0x03)	# General Nav - no motor?
	{
		# 0x04 len 60
		# 0x05 len 74
		# 0x06 len 94
		# 0x07 len 106
		$fields->{$FTYPE_SOG} = 6;
		$fields->{$FTYPE_SOG2} = 20;
		$fields->{$FTYPE_HEAD_DEV} = 34;
		$fields->{$FTYPE_LAT} = 48;
		$fields->{$FTYPE_LON} = 52;
		if ($version >= 0x07)
		{
			if ($version >= 0x0a)
			{
				# 0x0a len 151
				# 0x0d len 190
				$fields->{$FTYPE_DEPTH} = 34;
				$fields->{$FTYPE_HEAD_DEV} = 50;
				$fields->{$FTYPE_LAT} = 78;
				$fields->{$FTYPE_LON} = 82;
				$fields->{$FTYPE_HEAD_ABS} = 96;
				if ($version >= 0x0d)
				{
					# 0x0d len 190
					$fields->{$FTYPE_SOG2} = 0;
					$fields->{$FTYPE_LAT} = 72;
					$fields->{$FTYPE_LON} = 86;

					if ($version >= 0x10)
					{
						$fields->{$FTYPE_DEPTH} = 0;
						$fields->{$FTYPE_HEAD_DEV} = 0;
						$fields->{$FTYPE_LAT} = 100;
						$fields->{$FTYPE_LON} = 104;
						$fields->{$FTYPE_HEAD_ABS} = 120;

						if ($version >= 0x11)
						{
							# 0x11 len 248
							$fields->{$FTYPE_DATE} = 50;
							$fields->{$FTYPE_HEAD_DEV} = 92;
							$fields->{$FTYPE_LAT} = 96;
							$fields->{$FTYPE_LON} = 100;
							$fields->{$FTYPE_HEAD_ABS} = 140;

							if ($version >= 0x13)
							{
								# 0x13 len 276
								# 0x14 len 290
								# 0x15 len 292
								$fields->{$FTYPE_DEPTH} = 34;
								$fields->{$FTYPE_LAT} = 120;
								$fields->{$FTYPE_LON} = 124;

								if ($version >= 0x17)
								{
									# 0x17 len 332
									$fields->{$FTYPE_HEAD_DEV} = 92;
									$fields->{$FTYPE_LAT} = 120;
									$fields->{$FTYPE_LON} = 124;
									$fields->{$FTYPE_HEAD_ABS} = 140;
								}
							}
						}
					}
				}
			}
		}
	}
	elsif ($type == 0x04)	# General Nav - with motor?
	{
		# 0x09 len 124
		# 0x0a len 148	138?

		$fields->{$FTYPE_SOG} = 6;
		$fields->{$FTYPE_DEPTH} = 20;
		$fields->{$FTYPE_DATE} = 36;
		$fields->{$FTYPE_HEAD_DEV} = 50;
		$fields->{$FTYPE_HEAD_ABS} = 78;
		if ($version >= 0x0b)
		{
			# 0x0b len 164
			# 0x0c len 178
			# 0x0d len 192
			$fields->{$FTYPE_LAT} = 78;
			$fields->{$FTYPE_LON} = 82;
			$fields->{$FTYPE_HEAD_ABS} = 98;
		}
	}
	elsif ($type == 0x09)
	{
		# 0x06 len 82
		$fields->{$FTYPE_DEPTH} = 6;
		if ($version >= 0x08)
		{
			# 0x08 len 122 110?   <---
			# 0x0a len 150 158?
			$fields->{$FTYPE_HEAD_DEV} = 36;
			$fields->{$FTYPE_HEAD_ABS} = 64;
		}
	}
	elsif ($type == 0x12)
	{
		# 0x02 len 28
		# 0x03 len 48
		$fields->{$FTYPE_TIME} = 6;
		$fields->{$FTYPE_DATE} = 22;
		if ($version >= 0x3)
		{
			$fields->{$FTYPE_LAT} = 36;
			$fields->{$FTYPE_LON} = 40;
		}

	}
	elsif ($type == 0x13)	# General Info
	{
		# 0x05 len 66
		$fields->{$FTYPE_DATE} = 6;
		if ($version >= 0x07)
		{
			# 0x07 len 106
			$fields->{$FTYPE_LAT} = 34;
			$fields->{$FTYPE_LON} = 38;
			if ($version >= 0x08)
			{
				# 0x08 len 120
				$fields->{$FTYPE_LAT} = 48;
				$fields->{$FTYPE_LON} = 52;
			}
		}
	}
	elsif ($type == 0x17)	# Rapid position (once 'heading' established)
	{
		# 0x01 len 12

		$fields->{$FTYPE_HEAD_DEV} = 6;
		if ($version >= 0x02)
		{
			# 0x02 len 26

			$fields->{$FTYPE_HEAD_ABS} = 20;
		}
	}
	elsif ($type == 0x1c)	# rarely seen
	{
	}
	else
	{
		return undef;
	}

	my @values;
	for (my $i=0; $i<$NUM_FTYPES; $i++)
	{
		my $offset = $fields->{$i};
		if ($offset)
		{
			my $len =
				$i == $FTYPE_DATE      ? 2 :
				$i == $FTYPE_TIME      ? 4 :
				$i == $FTYPE_DEPTH     ? 4 :
				$i == $FTYPE_HEAD_DEV  ? 2 :
				$i == $FTYPE_HEAD_ABS  ? 2 :
				$i == $FTYPE_SOG       ? 2 :
				$i == $FTYPE_LAT       ? 4 :
				$i == $FTYPE_LON       ? 4 :
				$i == $FTYPE_SOG2      ? 2 : 0;
			push @values,[$offset, $i, $len];
		}
	}

	my $rslt = [ sort { $a->[0] <=> $b->[0] } @values ];
	return $rslt;
}





sub showValue
{
	my ($offset,$left,$right) = @_;
	return "        ".pad($offset,6).pad($left,30).$right."\r\n";
}

sub showDate
{
	my ($data,$offset) = @_;
	my $date_bytes = substr($data,$offset,2);
	my $date_int = unpack("v",$date_bytes);
	my $date_str = unpack("H*",$date_bytes);
	my $date_seconds = $date_int * 86400;
		# date encoded as days since 1970-01-01 unix epoch
	my ($sec, $min, $hour, $mday, $mon, $year) = gmtime($date_seconds);
	$year += 1900;
	$mon  += 1;
	$mon = pad2($mon);
	$mday = pad2($mday);
	return showValue($offset,"DATE($date_str)","$year-$mon-$mday");
}

sub showTime
{
	my ($data,$offset) = @_;
	my $time_bytes = substr($data,$offset,4);
	my $time_int = unpack("V",$time_bytes);
	my $time_str = unpack("H*",$time_bytes);
		# time encoded as 1/10000's of a second
	my $sec = int($time_int/10000);
	my $min = int($sec/60);
	my $hour = int($min/60);
	$sec = $sec % 60;
	$min = $min % 60;
	$hour = pad2($hour);
	$min = pad2($min);
	$sec = pad2($sec);
	return showValue($offset,"TIME($time_str)","$hour:$min:$sec");
}

sub showDepth
{
	my ($data,$offset) = @_;
	my $depth_bytes = substr($data,$offset,4);
	my $depth_int = unpack("V",$depth_bytes);
	my $depth_str = unpack("H*",$depth_bytes);
	my $depth = roundTwo(($depth_int / 100) * $METERS_TO_FEET);
		# depth encoded as centimeters
	return showValue($offset,"DEPTH($depth_str)", $depth);
}

sub showHeading
{
	my ($data,$offset,$what) = @_;
	my $head_bytes = substr($data,$offset,2);
	my $head_int = unpack("v",$head_bytes);
	my $head_str = unpack("H*",$head_bytes);
	my $deg = roundTwo(($head_int / 10000) * (180 / $PI));
		# bearing encoded as radians/10000
	return showValue($offset,"HEAD($what,$head_str)",$deg);
}

sub showSOG
{
	my ($data,$offset) = @_;
	my $sog_bytes = substr($data,$offset,2);
	my $sog_int = unpack("v",$sog_bytes);
	my $sog_str = unpack("H*",$sog_bytes);
	my $sog = sprintf("%0.1f",$sog_int / (100 * $KNOTS_TO_METERS_PER_SEC));
		# sog encoded as centimeters per second
	return showValue($offset,"SOG($sog_str)","$sog knots");
}




sub decode_coord
{
    my ($raw, $scale) = @_;
    return $raw * $scale;
}

sub deg_to_degmin
{
    my ($decimal_deg) = @_;
    my $degrees = int($decimal_deg);
    my $minutes = abs($decimal_deg - $degrees) * 60;
    return sprintf("%d°%.3f", $degrees, $minutes);

}

sub showLL
{
	my ($data,$offset,$what) = @_;
	my $l_bytes = substr($data,$offset,4);
	my $l_int = unpack('l',$l_bytes);
	my $l_str = unpack("H*",$l_bytes);
	my $l = decode_coord($l_int,$SCALE_LATLON);
	my $l_min = deg_to_degmin($l);
		# lat and lon are encoded as fixed point integers
		# with a scaling factor.
	return showValue($offset,"$what($l_str)",pad(sprintf("%0.6f",$l),12).$l_min);
}



sub decodeNAVSTAT
{
	my ($packet) = @_;
	my $raw = $packet->{raw_data};

	# my $fields = $template->{fields} || [];

	my $type = unpack('v',substr($raw,8,2));
	my $version = unpack('v',substr($raw,4,2));
	my $data = substr($raw,10);
	my $len = length($data);

	my $text = sprintf("    NAVSTAT len($len) type(0x%02x) version(0x%02x)\r\n",$type,$version);

	my $field_num = 0;
	my $fields = getFields($type,$version);
	for my $field_def (@$fields)
	{
		my ($offset, $ftype, $flen) = @$field_def;

		$text .= showDate	($data,$offset) 		if $ftype == $FTYPE_DATE;
		$text .= showTime	($data,$offset) 		if $ftype == $FTYPE_TIME;
		$text .= showDepth	($data,$offset) 		if $ftype == $FTYPE_DEPTH;
		$text .= showHeading($data,$offset,'DEV') 	if $ftype == $FTYPE_HEAD_DEV;
		$text .= showHeading($data,$offset,'ABS')	if $ftype == $FTYPE_HEAD_ABS;
		$text .= showSOG	($data,$offset)			if $ftype == $FTYPE_SOG;
		$text .= showLL		($data,$offset,'LAT')	if $ftype == $FTYPE_LAT;
		$text .= showLL		($data,$offset,'LON')	if $ftype == $FTYPE_LON;
		$text .= showSOG	($data,$offset) 		if $ftype == $FTYPE_SOG2;
	}

	setConsoleColor($UTILS_COLOR_GREEN);
	print $text;
	setConsoleColor();

}	# decodeNAVSTAT()



1;
