#---------------------------------------------
# r_ParseMessages.pm
#---------------------------------------------
# Methods to parse and characterize parse NAVQRY requests and replies,
# noting that requests and replies can and usually do consist of
# more than one message.

package r_characterize;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use r_utils;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		characterize
		showCharacterizedCommands
		clearCharacterizedCommands

	);
}


# Adding a Waypoint to the E80
#
# Appears to be a conversation where first the new uuid is
# checked, then the waypoint name is checked, then if all is
# ok, the uuid is created on the e80, then name is created
# then the content of the item is created, then a readback
# is performed.
#
# It is very verbose, and I have also seen that eventing is
# happens when running both my (now active) NAVQRY tcp port
# and RNS.
#
# I believe that the E80 is the actual 'master', but that since
# RNS also caches/keeps its own WRG's, that much synchronization
# needs to be done and that RNS is a bit paranoid about that.

#	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52530    0400
#	tcp(4)    10.0.241.54:2052     <-- 10.0.241.200:52530    b1010f00
#
#	The first reply is seen often.  Perhaps 08004500-0f00000 and 08008500-0f00000 are significant
#	05000f00 *might* be an event prefix
#
#	tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52530    0800
#	tcp(28)   10.0.241.54:2052     --> 10.0.241.200:52530    05000f00 00000000 08004500 0f000000 00000800 85000f00 00000000
#
#	The b1010f00 command is sent again, but this time no reply happens.
#
#	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52530    0400
#	tcp(4)    10.0.241.54:2052     <-- 10.0.241.200:52530    b1010f00
#
#	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52530    0800
#	tcp(8)    10.0.241.54:2052     <-- 10.0.241.200:52530    0d010f00 16000000
#	tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52530    0c00
#	tcp(12)   10.0.241.54:2052     --> 10.0.241.200:52530    09000f00 16000000 00000000                                                ............
#
#	# RNS tries to get the new uuid from the E80.
#	# 03010f00 is the 'get waypoint' command, but presumably this is an overall uniqness test
#	# I have sent this command many times with incorrect uuids, and I have no indication that
#	# this is a command to CREATE a new uuid
#
#	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52530    1000                                                                      ..
#	tcp(16)   10.0.241.54:2052     <-- 10.0.241.200:52530    03010f00 17000000 eeeeeeee eeee0110                                       ................
#
#	# The essential answer is "no the given UUID does not exist"
#	# The following failure reply 030b0480 may contain bit(s) that indicate
#	# that not only does the WP with that UUID not exist, but no other
#	# items with that UUID exist.  Or perhaps UUID namespace overlap
#	# is allowed between WPs, ROUTES, and GROUPS
#
#	tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52530    0c00                                                                      ..
#	tcp(12)   10.0.241.54:2052     --> 10.0.241.200:52530    06000f00 17000000 030b0480                                                ............
#
#	# name exists?
#
#	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52530    1900                                                                      ..
#	tcp(25)   10.0.241.54:2052     <-- 10.0.241.200:52530    0c010f00 18000000 506f7061 30000000 90c71900 834e2a65 00                  ........Popa0........N*e.
#
#	# exist query failure
#
#	tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52530    1400                                                                      ..
#	tcp(20)   10.0.241.54:2052     --> 10.0.241.200:52530    08000f00 18000000 030b0480 00000000 00000000                              ....................
#
#	# create(1/4) send the uuid; perhaps the leading nibble(0) indicates waypoint
#
#	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52530    1000                                                                      ..
#	tcp(16)   10.0.241.54:2052     <-- 10.0.241.200:52530    07010f00 19000000 eeeeeeee eeee0110                                       ................
#
#	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52530    1400                                                                      ..
#	tcp(20)   10.0.241.54:2052     <-- 10.0.241.200:52530    00020f00 19000000 eeeeeeee eeee0110 01000000                              ....................
#	         # I'm telling you context?
#
#	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52530    4100                                                                      A.
#	tcp(65)   10.0.241.54:2052     <-- 10.0.241.200:52530    01020f00 19000000 35000000 9e449005 ecdbface c16a9f06 ad4a84c5 00000000   ........5....D.......j...J......
#	                                                         00000000 00000000 02010000 000000f2 3c010081 4f000500 00000000 506f7061   ................<...O.......Popa
#	                                                         30                                                                        0
#	         # and here's the data.
#	         # This looks like a navquery waypoint that starts at length2(35000000)=53, offset 44
#	         # it definitely has lat(9e449005) and lon(ecdbface), and right after that the
#	         # The common waypoint starts with north(c16a9f06) and continues with east(ad4a84c5)
#	         # constant5(000000000000000000000000) sym(02) temperature(0100) depth(000000000) time(f2ec0100) date(814f)
#	         # constant6(00) name_len(05) comment_len(0) and constant7(00000000) before the name, all of which line up.
#	         # There is nothing after the name.
#	         #
#	         # When I request this back, I get a length(127) record with length2(3d000000)=61 length1(4900)=73
#
#
#	tcp(2)    10.0.241.54:2052     <-- 10.0.241.200:52530    1000                                                                      ..
#	tcp(16)   10.0.241.54:2052     <-- 10.0.241.200:52530    02020f00 19000000 eeeeeeee eeee0110                                       ................
#	         # commit?
#	tcp(2)    10.0.241.54:2052     --> 10.0.241.200:52530    0c00                                                                      ..
#	tcp(18)   10.0.241.54:2052     --> 10.0.241.200:9877     10000700 0f00eeee eeeeeeee 01100000 0000                                  ..................
#	         # notify shark.pm (in middle of "ok" to RNS)
#	tcp(30)   10.0.241.54:2052     --> 10.0.241.200:52530    03000f00 19000000 00000400 10000700 0f00eeee eeeeeeee 01100000 0000       ..............................
#	         # ok
#



my %messages:shared;
	# a hash of all messages in any requests or replies
	# by command word
my $rns_started:shared = 0;
	# I use this, and a particular order of operations when running shark.pm
	# and RNS, to note when I get the first messages from RNS, so that henceforth
	# I can characterize any messages to shark as "events".


sub clearCharacterizedCommands
{
	display(0,0,"COMMANDS CLEARED");
	%messages = ();
}



sub characterize
	# This method parses what I used to think of as a monolithic
	# request or reply into separate parts (messages) based on the lengths
	#
	# For simple input navquery of stable e80, there are no events
	# that might come in the stream, so we (need to) assume the declared
	# length of any packet is the length that cam in the packet
	# before the given packet.
	#
	# NOTE THAT the packet passed in is AFTER the declared_len bytes
{
	my ($src_port, $dest_port, $declared_len, $packet) = @_;

	my $arrow = $src_port == 2052 ? "--> " : "<-- ";

	my $color =
		$src_port == $NAVQUERY_PORT ? $UTILS_COLOR_BROWN :			# from me to E80
		$dest_port == $NAVQUERY_PORT ? $UTILS_COLOR_LIGHT_BLUE :	# from E80 to me
		$dest_port == 2052 ?	$UTILS_COLOR_LIGHT_MAGENTA :		# from RNS to E80
		$UTILS_COLOR_LIGHT_CYAN;									# from E80 to RNS

	my $is_event = 0;
	$rns_started=1 if $color == $UTILS_COLOR_LIGHT_MAGENTA;

	if ($rns_started && $dest_port == $NAVQUERY_PORT)
	{
		# highligh events to me in white
		$is_event = 1;
		$color = $UTILS_COLOR_WHITE;
	}

	setConsoleColor($color);

	# As we parse the messages (command words) we keep
	# track of how many we have seen, the minimum and maximum
	# length of the message, whether it has been seen as
	#
	#	cmd = the first message in in a request packet
	#   rep = the first message in a reply packet
	#   evt = the first message in an event packet
	#
	#   inc = seen in a request packet
	#   inr = seen in a reply packet
	#   ine = seen in an event packet
	#
	#   outer = seen as the first message in a request, reply, or event
	#   inner = seen anywhere inside a request, reply, or event
	#   ndata = the number of unique data chunks we have seen for it
	#   data  = a hash of {data=>1) for any unique data chunks

	my $packet_len = length($packet);
	print "src($src_port) dest($dest_port) declared_len($declared_len\) packet_len($packet_len)\n";

	my $offset = 0;
	my $partnum = 0;
	my $len = $declared_len;
	while ($len)
	{
		my $hex_len = unpack('H*',pack('v',$len));
		my $raw = substr($packet,$offset,$len);
		my $hex = unpack('H*',$raw);
		my $command = substr($hex,0,4);
		my $func = substr($hex,4,4);
		my $seq_num = $len > 4 ? substr($hex,8,8) : '';
		my $data = $len > 8 ? substr($hex,16) : '';
		my $data_len = length($data);
		my $show_data = $data;

		if ($func ne '0f00')
		{
			error("offset($offset) func($func) is not 0f00");
			last;
		}
		$show_data = substr($show_data,0,40)."..." if $data_len > 40;
		print "    part($partnum) command($command) ".
			pad("data_len($hex_len=$data_len)",20).
			"$show_data\n";

		#-----------------------------------
		# characterize message

		my $found = $messages{$command};
		if (!$found)
		{
			$found = shared_clone({
				command => $command,
				count => 0,
				min => 99999,
				max => 0,
				cmd => 0,
				rep => 0,
				evt => 0,
				inc => 0,
				inr => 0,
				ine => 0,
				data => shared_clone({}),
				outer => 0,
				inner => 0, });
			$messages{$command} = $found;
		}

		$found->{count}++;
		$found->{max} = $len if $len > $found->{max};
		$found->{min} = $len if $len < $found->{min};
		if ($offset == 0)
		{
			$found->{outer} = 1;
			if ($is_event)
			{
				$found->{evt} = 1;
			}
			else
			{
				$found->{cmd} = 1 if $dest_port==2052;
				$found->{rep} = 1 if $src_port==2052;
			}
		}
		else
		{
			$found->{inner} = 1;
			if ($is_event)
			{
				$found->{ine} = 1;
			}
			else
			{
				$found->{inc} = 1 if $dest_port==2052;
				$found->{inr} = 1 if $src_port==2052;
			}
		}
		$found->{data}->{$arrow.$data} = 1 if $data_len;


		#-----------------------------------

		$offset += $len;
		$len = 0;
		if ($offset < $packet_len - 2)
		{
			$len = unpack('v',substr($packet,$offset,2));
			$offset += 2;
		}
		$partnum++;
	}

	setConsoleColor();
}


sub cmpCommands
{
	my ($aa,$bb) = @_;
	my $msg_a = $messages{$aa};
	my $msg_b = $messages{$bb};
	my $cmp;

	# outer messages at top

	$cmp = $msg_b->{outer} <=> $msg_a->{outer};
	return $cmp if $cmp;

	# commands before replies

	$cmp = $msg_b->{cmd} <=> $msg_a->{cmd};
	return $cmp if $cmp;

	# replies before events

	$cmp = $msg_b->{rep} <=> $msg_a->{rep};
	return $cmp if $cmp;

	# events befre anything remaining

	$cmp = $msg_b->{evt} <=> $msg_a->{evt};
	return $cmp if $cmp;


	# by Z (in wxyz)

	$cmp = substr($aa,3,1) cmp substr($bb,3,1);
	return $cmp if $cmp;

	# by X (in wxyz)

	$cmp = substr($aa,1,1) cmp substr($bb,1,1);
	return $cmp if $cmp;

	# by W (in wxyz)

	return $aa cmp $bb;
}


sub showCharacterizedCommands
{
	my ($with_data) = @_;

	print "\r\n";
	print "Characterized Commands\n";

	print
		pad("command",8).				# 0
		pad("count",6).                 # 8
		pad("min",5).                   # 14
		pad("max",5).                   # 19
		pad("cmd",4).                   # 24
		pad("rep",4).                   # 28
		pad("evt",4).                   # 32
		pad("inc",4).                   # 36
		pad("inr",4).                   # 40
		pad("ine",4).                   # 44
		pad("outer",6).                 # 48
		pad("inner",6).                 # 54
		pad("new",4).					# 60
		pad("ndata",6).					# 64
		"data\n";						# 70
	print "----------------------------------------------------------------------------------------------------------------\n";

	my $MAX_SHOW = 80;
	for my $command (sort {cmpCommands($a,$b)} keys %messages)
	{
		my $rec = $messages{$command};
		my @data = sort keys %{$rec->{data}};
		my $num_data = @data;
		my $first_data = @data ? shift @data : '';
		my $data_len = length($first_data);
		$first_data = substr($first_data,0,$MAX_SHOW)."..." if $data_len > $MAX_SHOW;

		my $new = $rec->{seen} ? '' : 'new';

		print
			pad($rec->{command},	8).
			pad($rec->{count},		6).
			pad($rec->{min},		5).
			pad($rec->{max},		5).
			pad($rec->{cmd},		4).
			pad($rec->{rep},		4).
			pad($rec->{evt},		4).
			pad($rec->{inc},		4).
			pad($rec->{inr},		4).
			pad($rec->{ine},		4).
			pad($rec->{outer},		6).
			pad($rec->{inner},		6).
			pad($new,				4).
			pad($num_data,			6).
			"$first_data\n";

		$rec->{seen} = 1;

		if ($with_data)
		{
			for my $data (@data)
			{
				my $len = length($data);
				$data = substr($data,0,$MAX_SHOW)."..." if $len > $MAX_SHOW;
				print pad("",70);
				print "$data\n";
			}
		}
	}
	print "\n\n";

}






1;