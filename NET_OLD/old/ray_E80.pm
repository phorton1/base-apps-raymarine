#---------------------------------------
# raynet.pm
#---------------------------------------
# see docs/raynet.md

package old::ray_E80;
use strict;
use warnings;
use Pub::Utils;
use old::ray_UI;

BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (

		handleE80NAV
	);
}


my $PI = 3.1415926535;
my $METERS_TO_FEET = 3.28084;
my $KNOTS_TO_METERS_PER_SEC = 0.5144;
my $SCALE_LATLON = 1e-7;

my $WORD_SPACE = 5;
my $BYTES_PER_LINE = 20;
my $WORDS_PER_LINE = 10;
my $DATA_COL = 41;
my $STR_COL  = $DATA_COL + $WORDS_PER_LINE*$WORD_SPACE + 2;
my $SENSOR_COL = $STR_COL + $BYTES_PER_LINE + 2;

my $patterns = {};
my $line_num = 2;

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
my $FTYPE_UINT32    = 9;
my $NUM_FTYPES      = 10;


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

									if ($version > 0x17)
									{
										# 0x1d len 420

										# poking around thought this might be
										# distance to waypoint or something.
										# it seems to decrement in proportion to speed
										$fields->{$FTYPE_UINT32} = 336;
									}
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
				$i == $FTYPE_SOG2      ? 2 :
				$i == $FTYPE_UINT32    ? 4 : 0;
			push @values,[$offset, $i, $len];
		}
	}

	my $rslt = [ sort { $a->[0] <=> $b->[0] } @values ];
	return $rslt;
}





sub showValue
{
	my ($out_line, $left,$right) = @_;
	cursor($out_line,$SENSOR_COL);
	clear_eol();
	print pad($left,30).$right."\n";
}

sub showDate
{
	my ($out_line,$data,$offset) = @_;
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
	showValue($out_line,"DATE($date_str)","$year-$mon-$mday");
}

sub showTime
{
	my ($out_line,$data,$offset) = @_;
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
	showValue($out_line,"TIME($time_str)","$hour:$min:$sec");
}

sub showDepth
{
	my ($out_line,$data,$offset) = @_;
	my $depth_bytes = substr($data,$offset,4);
	my $depth_int = unpack("V",$depth_bytes);
	my $depth_str = unpack("H*",$depth_bytes);
	my $depth = roundTwo(($depth_int / 100) * $METERS_TO_FEET);
		# depth encoded as centimeters
	showValue($out_line,"DEPTH($depth_str)", $depth);
}

sub showHeading
{
	my ($out_line,$data,$offset,$what) = @_;
	my $head_bytes = substr($data,$offset,2);
	my $head_int = unpack("v",$head_bytes);
	my $head_str = unpack("H*",$head_bytes);
	my $deg = roundTwo(($head_int / 10000) * (180 / $PI));
		# bearing encoded as radians/10000
	showValue($out_line,"HEAD($what,$head_str)",$deg);
}

sub showSOG
{
	my ($out_line,$data,$offset) = @_;
	my $sog_bytes = substr($data,$offset,2);
	my $sog_int = unpack("v",$sog_bytes);
	my $sog_str = unpack("H*",$sog_bytes);
	my $sog = sprintf("%0.1f",$sog_int / (100 * $KNOTS_TO_METERS_PER_SEC));
		# sog encoded as centimeters per second
	showValue($out_line,"SOG($sog_str)","$sog knots");
}

sub showUINT32
{
	my ($out_line,$data,$offset) = @_;
	my $uint32_bytes = substr($data,$offset,4);
	my $uint32_int = unpack("V",$uint32_bytes);
	my $uint32_str = unpack("H*",$uint32_bytes);
	showValue($out_line,"UINT32($uint32_str)",$uint32_int);
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
	my ($out_line,$data,$offset,$what) = @_;
	my $l_bytes = substr($data,$offset,4);
	my $l_int = unpack('l',$l_bytes);
	my $l_str = unpack("H*",$l_bytes);
	my $l = decode_coord($l_int,$SCALE_LATLON);
	my $l_min = deg_to_degmin($l);
		# lat and lon are encoded as fixed point integers
		# with a scaling factor.
	showValue($out_line,"$what($l_str)",pad(sprintf("%0.6f",$l),12).$l_min);
}



sub handleE80NAV
{
	my ($raw) = @_;

	my $key = substr($raw,0,10);
	my $data = substr($raw,10);
	my $len = length($data);
	my $show_key = unpack("H*", $key);
	my $found = $patterns->{$key};
	my $rec = $found ? $found : { num=>0, count=>0, data=>$data, changes=>{} };
	$rec->{count}++ if $found;

	# my $fields = $template->{fields} || [];

	my $type = unpack('v',substr($raw,8,2));
	my $version = unpack('v',substr($raw,4,2));
	my $fields = getFields($type,$version);
	my $unknown_type = $fields ? 0 : 1;
	$fields ||= [];

	# determine number lines the record will take, which is
	# the maximum of the number of lines or number of fields.
	# put it on the current line, add it to $patterns, and
	# bump $line_num for the next one

	my $lines = int(($len + $BYTES_PER_LINE-1) / $BYTES_PER_LINE);
	if (!$found)
	{
		my $num_fields = @$fields;
		$lines =  $num_fields if $num_fields > $lines;
		$rec->{line_num} = $line_num;
		$line_num += $lines + 1;
		$patterns->{$key} = $rec;
	}

	#-------------------------------------
	# Analyze for changes.
	#-------------------------------------
	# Any new changes are given a timestamp, and
	# if there are any, the record is considered to be "diff"

	my $diff = 0;
	my $len_changed = 0;
	my $now = time();

	if ($found)
	{
		my $fdata = $found->{data};
		my $flen = length($fdata);
		$len_changed = 1 if $len != $flen;
		my $use_len = $len <= $flen ? $len : $flen;
		for (my $i=0; $i<$use_len; $i++)
		{
			if (substr($data,$i,1) ne substr($found->{data},$i,1))
			{
				$rec->{changes}->{$i} = $now;
				$diff = 1;
			}
		}
		$found->{data} = $data;
	}

	#----------------------------------------
	# draw
	#----------------------------------------
	# we always show the line header

	my $action =
		$diff ? "chg" :
		$found ? "rpt" : "new";

	my $line = $rec->{line_num};
	cursor($line,0);
	print "$action($rec->{count})\n";

	if ($len_changed)
	{
		cursor($line+1,0);
		print color_str($fg_magenta);
		print "len($len) old(".length($found->{data}).")";
		print color_str($fg_light_gray)."\n";
	}

	# for the initial rec we show the key and len
	# highlighting unknown types in cyan

	if (!$found || $len_changed)
	{
		my $color = $unknown_type ? $fg_cyan : 0;
		cursor($line,11);
		print color_str($color) if $color;
		print "$show_key len($len)\n";
		print color_str($fg_light_gray) if $color;
	}

	# create lookup of known bytes in fields
	# to give them a specific bg_color

	my $in_field = {};
	for my $field_def (@$fields)
	{
		my ($offset, $ftype, $flen) = @$field_def;
		for (my $i=$offset; $i<$offset+$flen; $i++)
		{
			$in_field->{$i} = 1;
		}
	}

	# draw the record

	my $char_str = '';
	my $byte_num = 0;
	for (my $i=0; $i<$len; $i++)
	{
		$byte_num = $i % $BYTES_PER_LINE;

		if ($i && $byte_num==0)
		{
			cursor($line, $STR_COL);
			print"$char_str\n";
			$line++;
			$char_str = '';
		}

		my $byte = substr($data,$i,1);
		my $str = unpack("H*",$byte);

		$char_str .= $byte ge ' ' ? $byte : '.';

		if (!$found || $rec->{changes}->{$i})
		{
			my $chg = $rec->{changes}->{$i} || 0;
			my $elapsed = $now - $chg;

			my $bg_color = $in_field->{$i} ?
				$bg_light_gray : 0;

			my $color = $bg_color ?
				$elapsed <= 3 ? $fg_red :
				$elapsed <= 6 ? $fg_blue : $fg_black
				:
				$elapsed <= 3 ? $fg_red :
				$elapsed <= 6 ? $fg_blue : 0;

			my $word_num = int($byte_num / 2);
			my $word_byte = $byte_num % 2;
			cursor($line, $DATA_COL + $word_num + $byte_num*2);	# $word_num * $WORD_SPACE + $word_byte * 2);
			print color_str($bg_color) if $bg_color;
			print color_str($color) if $color;
			print $str;
			print color_str($fg_light_gray) if $color;
			print color_str($bg_black) if $bg_color;
			print "\n";
		}
	}

	if ($byte_num)
	{
		cursor($line, $STR_COL);
		print "$char_str\n";
	}

	#-----------------------------
	# show known parsed fields
	#-----------------------------

	if (!$found || $diff)
	{
		my $field_num = 0;
		for my $field_def (@$fields)
		{
			my ($offset, $ftype, $flen) = @$field_def;
			my $at_line = $rec->{line_num} + $field_num++;

			showDate	($at_line,$data,$offset) 		if $ftype == $FTYPE_DATE;
			showTime	($at_line,$data,$offset) 		if $ftype == $FTYPE_TIME;
			showDepth	($at_line,$data,$offset) 		if $ftype == $FTYPE_DEPTH;
			showHeading ($at_line,$data,$offset,'DEV') 	if $ftype == $FTYPE_HEAD_DEV;
			showHeading ($at_line,$data,$offset,'ABS')	if $ftype == $FTYPE_HEAD_ABS;
			showSOG		($at_line,$data,$offset)		if $ftype == $FTYPE_SOG;
			showLL		($at_line,$data,$offset,'LAT')	if $ftype == $FTYPE_LAT;
			showLL		($at_line,$data,$offset,'LON')	if $ftype == $FTYPE_LON;
			showSOG		($at_line,$data,$offset) 		if $ftype == $FTYPE_SOG2;
			showUINT32  ($at_line,$data,$offset) 		if $ftype == $FTYPE_UINT32;
		}
	}

}	# handleE80NAV()



1;
