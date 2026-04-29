#---------------------------------------------
# a_parser.pm
#---------------------------------------------
# base class of parse trees, known by b_sock and sniffer
# 	which are it's 'parents'
# Upon each new request/reply, the parser must FIRST call
#	applyMonPrefs() to setup the monitoring for the packet.
#   For the base class that is done simply using the ctor mon_prefs
#   and the $is_reply direction to get the appropriate ones.
#   More complicated classes (i.e. WPMGR) implement their own
#   	applyMonDefs routine
#
# FRAMING
#
# Big issues with 'Framing' TCP stream into logical message groups that
# constitute a 'semantic' unit.  Noticed especially with big Tracks when
# I switched to the Raymarine Router.
#
# (a) we do implicit framing in b_sock and sniffer when we built a packet
#     that is AT LEAST bigger than two bytes (the presumed initial {msg_len}.
# (b) discovered that there can be "dangling" bytes at the end of a packet
#     once it is decomposed into messages.
# (c) implemented "dangling_packet" scheme to return undef until the
#     packet ends exactly on a message boundary.
# (d) had to also change e_Track to append, rather than mergeHash
#     points into the accumulating record after noticing the E80
#     sent multiple trk "info Buffers" in a single message group.
# (e) may have similar issues with big Routes, Groups, or Dictionaries
#     as I have never tested the limits of those parser/services.
#
# I am hoping this weird, implicit, framing is sufficient, as otherwise
# it implies big architectural changes if the derived parsers have to
# "figure out" what consitutes a complete message group (semantic unit).
#
# In self defense, I added a big 'OUT OF BAND' error message in bsock
# if we get a sequenced reply and no-one is waiting for it, or it is
# not the one the parser is waiting for, which would imply a problem
# with the framing or my basic understanding of the protocol vs tcp.





package apps::raymarine::NET::a_parser;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_mon;
use apps::raymarine::NET::a_utils;


my $dbg_parse = 0;
my $dbg_dangling = 1;




sub newParser
	# not called 'new' so that it can be multiple inherited
	# into implemented classes, particularly c_RAYDP
{
	my ($class, $mon_defs) = @_;
	my $name = $mon_defs->{name} ? "e_$mon_defs->{name}" : 'a_parser';
	display($dbg_parse,0,"apps::raymarine::NET::a_parser::newParser($name) sid($mon_defs->{sid})  ".
			"is_shark($mon_defs->{is_shark}) is_sniffer($mon_defs->{is_sniffer})");
	my $this = shared_clone({
		sid => $mon_defs->{sid},
		name => $name,
		mon_defs => $mon_defs });
	bless $this,$class;
	return $this;
}



sub applyMonDefs
	# apply the (default, single, shared) monitoring preferences
	# from the parent device to the packet based soley on $is_reply
{
	my ($this,$packet) = @_;
	my $mon_defs = $this->{mon_defs};
	my $is_reply = $packet->{is_reply};

	if ($mon_defs->{active})
	{
		my $log = $mon_defs->{log};
		$packet->{mon} = $is_reply ? $mon_defs->{mon_in} : $mon_defs->{mon_out};
		$packet->{mon} |= $log;
		# identify self-sniffed packets
		$packet->{mon} |= $MON_SELF_SNIFFED
			if $packet->{is_sniffer} && $packet->{is_shark};
	}
	else
	{
		$packet->{mon} = 0;
	}
	$packet->{color} = $is_reply ? $mon_defs->{in_color} : $mon_defs->{out_color};
	$packet->{name} = "p_$this->{name}";

	display($dbg_parse+1,0,"apps::raymarine::NET::a_parser::applyMonDefs($packet->{name}) ".
		"active($mon_defs->{active}) ".
		"is_sniffer($packet->{is_sniffer}) is_reply($is_reply) ".
		sprintf("mon(%04x) color($packet->{color})",$packet->{mon}));
}



sub doParse
	# doParse() is called by b_sock and sniffer, and
	# does the applyMonDefs() before calling derived
	# classes' parsePacket methods.
{
	my ($this,$packet) = @_;
	if ($this->{dangling_packet})
	{
		warning($dbg_dangling,0,"using dangling packet");
		$this->{dangling_packet}->{payload} .= $packet->{payload};
		$packet = $this->{dangling_packet};
		$this->{dangling_packet} = undef;
	}
	else
	{
		$packet->{mon} = 0;
		$packet->{color} = 0;
		$this->applyMonDefs($packet);
	}
	return $this->parsePacket($packet);
}


sub parsePacket
{
	my ($this,$packet) = @_;
	lock($local_stdout_sem);
		# lock stdout so all of our display and prints occur contiguously
		# within a single color

	my $mon = $packet->{mon};
	my $color = $packet->{color};
	my $payload = $packet->{payload};
	my $packet_len = length($payload);
	
	display($dbg_parse+1,1,sprintf("apps::raymarine::NET::a_parser::parsePacket($this->{name}) is_sniffer($packet->{is_sniffer}) len($packet_len) mon(%04x) color(%d)",$mon,$color));
	display_hash($dbg_parse+3,0,"packet($this->{name})",$packet,'payload');

	if ($packet->{is_sniffer})
	{
		if ($packet->{is_shark} && !($mon & $MON_SNIFF_SELF))
		{
			display($dbg_parse+2,1,"apps::raymarine::NET::a_parser::parsePacket() abandoning sniffer packet to/from self");
			return undef;
		}

		# don't parse sniffer packets if no mon bits are set

		if (!$mon)
		{
			display($dbg_parse+2,1,"apps::raymarine::NET::a_parser::parsePacket() abandoning sniffer packet with no mon bits");
			return undef;
		}
	}


	# Show the packet header if the $MON_HEADER bit is set
	
	if ($mon & $MON_HEADER)
	{
		printConsole(0,$mon,$color,
			$packet->{server_name}.
			($packet->{is_reply} ? ' --> ' : ' <-- ').
			$packet->{client_name}."  ".
			"proto($packet->{proto}) ".
			"len($packet_len)    ".
			"# $packet->{src_ip}:$packet->{src_port} --> $packet->{dst_ip}:$packet->{dst_port}   ".
			"is_sniffer($packet->{is_sniffer})");
		# print parse_dwords(' debug ',$packet->{payload},1);
	}
	
	# Parse the message(s) in the packet

	if ($packet->{proto} eq 'tcp')
	{
		my $offset = 0;
		while ($packet && $packet_len - $offset >= 2)
		{
			my $len_bytes = substr($payload,$offset,2);
			$offset += 2;

			my $len = unpack('v',$len_bytes);
			if ($offset + $len > $packet_len)
			{
				warning($dbg_dangling,0,"insufficent len($len) offset($offset) packet_len($packet_len) dangling: ".unpack('H*',substr($payload,$offset)));
				$packet->{payload} = $len_bytes . substr($payload,$offset);
				$this->{dangling_packet} = shared_clone($packet);
				return undef;
			}

			my $part = substr($payload,$offset,$len);
			$packet = $this->parseMessage($packet,$len,$part);
			$offset += $len;
		}
		if ($offset != $packet_len)
		{
			warning(0,0,"dangling packet bytes offset($offset) packet_len($packet_len)=".unpack('H*',substr($payload,$offset)));
			$packet->{payload} = substr($payload,$offset);
			$this->{dangling_packet} = shared_clone($packet);
			return undef;
		}
	}
	else
	{
		$packet = $this->parseMessage($packet,length($payload),$payload);
	}

	if ($packet)
	{
		my $exclude_re = 'payload';
		$exclude_re .= '|points'	# Track points
			if !($packet->{mon} & $MON_DUMP_DETAILS);
		display_record(0,0,"final packet($packet->{name})",$packet,$exclude_re)
			if $packet->{mon} & $MON_DUMP_RECORD;
	}

	return $packet;
}



sub parseMessage
	# Derived classes call base class first to display the $MON_RAW output
	# and then handle the message as they see fit. This is where a failure
	# to match a service_id *would* be caught. TODO
{
	my ($this,$packet,$len,$part) = @_;
	my $cmd_bytes 	= substr($part,0,2);
	my $sid_bytes 	= substr($part,2,2);
	my $cmd_word 	= unpack('v',$cmd_bytes);
	my $cmd_hex 	= unpack('H*',$cmd_bytes);
	my $sid 		= unpack('v',$sid_bytes);
	my $sid_hex 	= unpack('H*',$sid_bytes);
	my $mon 		= $packet->{mon};
	my $color		= $packet->{color};
	
	display($dbg_parse+2,0,"apps::raymarine::NET::a_parser::parseMessage($this->{name}) ".
			sprintf("len($len) cmd_word($cmd_hex) sid($sid) mon(%04x)",$mon));

	# there cases with sniffer packets being misasligned, where
	# sniffer is started in the middle of a multi-packet tcp buffer,
	# after the length word has been sent, so at this point we might get
	# a packet that has a bogus length (which is actually the command word)
	# and bogus command word (which is actually the sid).

	# We don't really want to drop packets on sniffer as we may not know the actual
	# sid of the packet yet, i.e. $HIDDEN_PORT1.  However, for now we compare the sid.

	if ($sid != $this->{sid})
	{
		my $msg = "apps::raymarine::NET::a_parser::parseMessage($this->{name}) BAD_SID($sid) != expected($this->{sid}) ".
			"is_sniffer($packet->{is_sniffer}) is shark($packet->{is_shark}) len($len) cmd_word($cmd_hex)\n".
			parse_dwords('BAD SID:  ',$packet->{payload},1);
		error($msg);
		printConsole(1,$mon,$UTILS_COLOR_RED,$msg);
		return undef;
	}


	if ($mon & $MON_RAW)
	{
		my $hdr = pad('',4).($packet->{proto} eq 'tcp' ?
			unpack('H*',pack('v',$len)) : pad('',4));
		$hdr .= " $cmd_hex $sid_hex ";
		my $text = parse_dwords($hdr,substr($part,4),$mon & $MON_MULTI);
		$text =~ s/\n$//s;	# get rid of last trailing word from parse_words or change semantic of printConsole
		printConsole(0,$mon,$color,$text);
	}

	return $packet;
}



sub parsePiece
	# Only certain derived classes (WPMGR, TRACK) at this time
	# 	use "pieces" and "rules".
	#
	# The base class parsePiece method knows the
	# simplest most common msg parameter types
	# but not much about inter-message relationships
	#
	# I debate whether or not any 'buffer' parsing should
	# take place in the base class, though there is commonality
	# between d_WPMGR and d_TRACK with regards to is_dict buffers.
	#
	# So this base class uses the 'is_dict' state member, without
	# knowing how it got there.
{
	my ($this,$packet,$piece,$part,$poffset) = @_;
	my $mon = $packet->{mon};
	my $color = $packet->{color};
	
	if ($piece eq 'buffer')
	{
		if ($packet->{is_dict} &&
			$packet->{is_reply})
		{
			$$poffset += 4;	# skip biglen

			$packet->{dict_uuids} ||= shared_clone([]);
			my $dict_uuids = $packet->{dict_uuids};
			my $num;

			if (!defined $packet->{dict_total})
			{
				$num = unpack('V',substr($part,$$poffset,4));
				$$poffset += 4;
				return error("too many dict_uuids!!") if $num>1024;
				$packet->{dict_total} = $num;
				printConsole(2,$mon,$color,"dictionary($num)")
					if $mon & $MON_PIECES;
			}
			else
			{
				$num = $packet->{dict_total};
			}

			my $already = scalar(@$dict_uuids);
			my $remaining = $num - $already;
			my $available = int((length($part) - $$poffset) / 8);
			my $to_read = $remaining < $available ? $remaining : $available;

			for (my $i=0; $i<$to_read; $i++)
			{
				my $idx = $already + $i;
				my $uuid = unpack('H*',substr($part,$$poffset,8));
				$$poffset += 8;
				push @$dict_uuids,$uuid;
				printConsole(3,$mon,$color,"dict_uuid($idx) = $uuid")
					if $mon & $MON_DICT;
			}
		}
	}
	elsif ($piece eq 'seq')
	{
		my $seq_num = unpack('V',substr($part,$$poffset,4));
		$$poffset += 4;
		display($dbg_parse+3,1,"seq_num=$seq_num");
		printConsole(2,$mon,$color,"seq_num = $seq_num")
			if $mon & $MON_PARSE;	# note that is MON_PARSE, not MON_PIECE
		$packet->{seq_num} ||= $seq_num;
	}
	elsif ($piece eq 'uuid')
	{
		my $uuid = unpack('H*',substr($part,$$poffset,8));
		$packet->{uuid} = $uuid;
		$$poffset += 8;
		printConsole(2,$mon,$color,"$piece = $uuid")
			if $mon & $MON_PIECES;
	}
	elsif ($piece eq 'name16')
	{
		my $name = unpack('Z*',substr($part,$$poffset,17));
		$packet->{name} = $name;
		$$poffset += 17;
		printConsole(2,$mon,$color,"name = $name")
			if $mon & $MON_PIECES;
	}
	elsif ($piece eq 'success')
	{
		my $status = unpack('H*',substr($part,$$poffset,4));
		my $ok = $status eq $SUCCESS_SIG ? 1 : 0;
		$packet->{success} = $ok;
		$$poffset += 4;
		printConsole(2,$mon,$color,"$piece = $ok")
			if $mon & $MON_PIECES;
	}

	# implemented in base class with 'some' knowledge
	# of derived classes, but without setting any special state

	elsif ($piece =~ /byte|stopable/)		# one byte (flag on wpmgr events)
	{
		my $byte = unpack('C',substr($part,$$poffset++,1));
		$packet->{$piece} = $byte;
		printConsole(2,$mon,$color,"$piece = $byte")
			if $mon & $MON_PIECES;
	}
	elsif ($piece eq 'bits')				# one word (flag on wpmgr changed events)
	{
		my $word = unpack('v',substr($part,$$poffset,2));
		$packet->{$piece} = $word;
		$$poffset += 2;
		printConsole(2,$mon,$color,"$piece = $word")
			if $mon & $MON_PIECES;
	}
	elsif ($piece =~ /is_dict|is_point/)	# generic boolean value
	{
		# state only to the degree that the $pieces are
		# defined in the rules of derived classes, yet
		# there is no special handling here
		display($dbg_parse + 1,1,"$piece = 1");
		$packet->{$piece} = 1;
		printConsole(2,$mon,$color,"$piece = 1")
			if $mon & $MON_PIECES;
	}

	# DERIVED CLASSES MUST EXPLICITLY HANDLE OTHER PIECES THAT CHANGE STATE
	# This class will parse any remaiing pieces into dwords without
	# changing any state.

	else
	{
		my $str = substr($part,$$poffset,4);
		my $value = unpack('V',$str);
		$packet->{$piece} = $value;
		$$poffset += 4;

		# I prefer to SEE non-counters in hex

		my $show_value = $value;
		$show_value = sprintf("0x%02x",$value)	# ." = (".unpack('H*',$str).")"
			if $piece !~ /db_count|db_version|evt_flag/;

		printConsole(2,$mon,$color,"$piece = $show_value")
			if $mon & $MON_PIECES;
	}

	return 1;
}



1;
