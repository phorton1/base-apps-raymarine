#--------------------------------------------
# ray_E80NAV.pm
#--------------------------------------------

package bat::raymarineE80::parse_E80_NAV;



sub handlePacketUI
{
	my ($name,$raw) = @_;

	my $key = substr($raw,0,10);
	my $data = substr($raw,10);
	my $len = length($data);
	my $show_key = unpack("H*", $key);
	my $found = $patterns->{$key};
	my $rec = $found ? $found : { num=>0, count=>0, data=>$data, changes=>{} };
	$rec->{count}++ if $found;

	my $template = $templates->{$show_key} || {};
	my $fields = $template->{fields} || [];
	my $ignores = $template->{ignore} || [];

	# determine number lines the record will take, which is
	# the maximum of the number of lines or number of fields.
	# put it on the current line, add it to $patterns, and
	# bump $line_num for the next one

	my $lines = int(($len + $BYTES_PER_LINE-1) / $BYTES_PER_LINE);
	if (!$found)
	{
		my $known = @$fields;
		$lines = $known if $known > $lines;

		$rec->{line_num} = $line_num;
		$line_num += $lines + 1;
		$patterns->{$key} = $rec;
	}

	#-------------------------------------
	# Analyze for changes.
	#-------------------------------------
	# If an ignored byte changes we redraw them all.
	# Otherwise, any new changes are given a timestamp, and
	# if there are any, the record is considered to be "diff"

	my $diff = 0;
	my $ignore_changed = 0;
	my $now = time();

	# build a hash of the ignored bytes => 1 for the loop

	my $ignore_bytes = {};
	for my $ignore (@$ignores)
	{
		$ignore_bytes->{$ignore} = 1;
	}

	if ($found)
	{
		for (my $i=0; $i<$len; $i++)
		{
			if (substr($data,$i,1) ne substr($found->{data},$i,1))
			{
				if ($ignore_bytes->{$i})
				{
					$ignore_changed = 1;
				}
				else
				{
					$rec->{changes}->{$i} = $now;
					$diff = 1;
				}
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

	# for the initial rec we show the key and len
	# highlighting unknown keys in cyan

	if (!$found)
	{
		my $color = $templates->{$show_key} ? 0 : $fg_cyan;
		cursor($line,11);
		print color_str($color) if $color;
		print "$show_key len($len)\n";
		print color_str($fg_light_gray) if $color;
	}

	# create lookup of known bytes in fields
	# to give them a specific bg_color

	my $in_field = {};
	for my $field_template (@$fields)
	{
		$field_template =~ /^(.+)\((.*)\)$/;
		my ($func,$param_str) = ($1,$2);
		my ($offset) = split(/,/,$param_str);
		my $byte_len =
			$func eq 'DATE' ? 	2 :
			$func eq 'TIME' ? 	4 :
			$func eq 'DEPTH' ? 	4 :
			$func eq 'HEAD' ? 	2 :
			$func eq 'SOG' ? 	2 :
			$func eq 'LAT' ? 	4 :
			$func eq 'LON' ? 	4 :
			0;
		for (my $i=$offset; $i<$offset+$byte_len; $i++)
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

		if (!$found || $rec->{changes}->{$i} || (
			$ignore_changed && $ignore_bytes->{$i}))
		{
			my $chg = $rec->{changes}->{$i} || 0;
			my $elapsed = $now - $chg;

			my $bg_color = $in_field->{$i} ?
				$bg_light_gray : 0;

			my $color = $bg_color ?
				$ignore_bytes->{$i} ? $fg_green :
				$elapsed <= 3 ? $fg_red :
				$elapsed <= 6 ? $fg_blue : $fg_black
				:
				$ignore_bytes->{$i} ? $fg_green :
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
	# OLD show known parsed fields
	#-----------------------------

	if (1 && !$found || $diff)
	{
		my $field_num = 0;
		for my $field_template (@$fields)
		{
			$field_template =~ /^(.+)\((.*)\)$/;
			my ($func,$param_str) = ($1,$2);
			my @params = split(/,/,$param_str);
			$func eq 'DATE' ? 	showDate	($rec->{line_num} + $field_num, $data, $params[0]) :
			$func eq 'TIME' ? 	showTime	($rec->{line_num} + $field_num, $data, $params[0]) :
			$func eq 'DEPTH' ? 	showDepth	($rec->{line_num} + $field_num, $data, $params[0]) :
			$func eq 'HEAD' ? 	showHeading	($rec->{line_num} + $field_num, $data, $params[0], $params[1]) :
			$func eq 'SOG' ? 	showSOG		($rec->{line_num} + $field_num, $data, $params[0]) :
			$func eq 'LAT' ? 	showLL		($rec->{line_num} + $field_num, $data, $params[0], 'LAT') :
			$func eq 'LON' ? 	showLL		($rec->{line_num} + $field_num, $data, $params[0], 'LON') :
				0;
			$field_num++;
		}
	}

	# Switching to decimal (displayed in hex)

	my $offset = 0;
	my $type = unpack("v",substr($raw,8,2));
	my $version = unpack("v",substr($raw,5,2));

	if ($type == 3)
	{
		$offset = skip($offset,6);
		$offset = showSOG($offset,$in_field);
		$offset = skip($offset,1);
		$offset = ignore($offset,$ignore_bytes);

		$offset +=




	'00031000040000000300' => { len=> 60,	fields=>['SOG(6)', 'HEAD(34,DEV)'],
		ignore=>[9, 23, 37] },
	'00031000050000000300' => { len=> 74,	fields=>['SOG(6)', 'HEAD(34,DEV)'],
		ignore=>[9, 23, 37] },
	'00031000060000000300' => { len=> 94,	fields=>['SOG(6)', 'HEAD(34,DEV)'],
		ignore=>[9, 23, 37] },
	'000310000a0000000300' => { len=> 151,	fields=>['SOG(6)', 'HEAD(34,DEV)'],
		ignore=>[9, 23, 39, 95, 119] },
	'00031000110000000300' => { len=> 248,	fields=>['SOG(6)', 'HEAD(64,DEV)', 'HEAD(112,ABS)'],
		ignore=>[9, 23, 53, 95, 143, 185, 199] },
	'00031000140000000300' => { len=> 290,	fields=>['SOG(6)', 'HEAD(34,DEV)'],
		ignore=>[9, 23, 53, 95, 143, 185, 199] },
	'00031000150000000300' => { len=> 292,	fields=>['SOG(6)', 'HEAD(34,DEV)'],
		ignore=>[9, 23, 53, 95, 143, 185, 199] },
	'00031000170000000300' => { len=> 332,	fields=>['SOG(6)', 'SOG(20)', 'DEPTH(34)', 'HEAD(92,DEV)', 'LAT(120)', 'LON(124)', 'HEAD(140,ABS)'],
		ignore=>[9, 23, 39, 53, 95, 143, 185, 199] },
	}
	elsif ($type eq '0400')
	{
	}
	elsif ($type eq '0900')
	{
	}
	elsif ($type eq '1200')
	{
	}
	elsif ($type eq '1300')
	{
	}
	elsif ($type eq '1700')
	{
	}


}	# handlePacketUI()