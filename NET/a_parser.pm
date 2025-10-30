#---------------------------------------------
# a_parser.pm
#---------------------------------------------
# base class of parse trees, known by b_sock and sniffer
# 	which are it's 'parents'
# Upon each packet, the parser must FIRST get the monitoring
# 	preferences from the parent via a call to setMonDefs.
# $def_port is no longer used ?!?


package a_parser;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use a_defs;
use a_mon;
use a_utils;


my $dbg_parse = 0;



sub newParser
	# not called 'new' so that it can be multiple inherited
	# into implemented classes, particularly c_RAYSYS
{
	my ($class, $mon_defs) = @_;
	my $name = $mon_defs->{name} ? "e_$mon_defs->{name}" : 'a_parser';
	display($dbg_parse,0,"a_parser::newParser($name) sid($mon_defs->{sid})  ".
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

	display($dbg_parse+1,0,"a_parser::applyMonDefs($packet->{name}) ".
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
	$packet->{mon} = 0;
	$packet->{color} = 0;
	$this->applyMonDefs($packet);
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
	display($dbg_parse+1,1,sprintf("a_parser::parsePacket($this->{name}) is_sniffer($packet->{is_sniffer}) len($packet_len) mon(%04x) color(%d)",$mon,$color));
	display_hash($dbg_parse+3,0,"packet($this->{name})",$packet,'payload');

	if ($packet->{is_sniffer})
	{
		if ($packet->{is_shark} && !($mon & $MON_SNIFF_SELF))
		{
			display($dbg_parse+2,1,"a_parser::parsePacket() abandoning sniffer packet to/from self");
			return;
		}

		# don't parse sniffer packets if no mon bits are set

		if (!$mon)
		{
			display($dbg_parse+2,1,"a_parser::parsePacket() abandoning sniffer packet with no mon bits");
			return;
		}
	}


	# Show the packet header if the $MON_HEADER bit is set
	
	if ($mon & $MON_HEADER)
	{
		printConsole($packet->{color},
			$packet->{server_name}.
			($packet->{is_reply} ? ' --> ' : ' <-- ').
			$packet->{client_name}."  ".
			"proto($packet->{proto}) ".
			"len($packet_len)    ".
			"# $packet->{src_ip}:$packet->{src_port} --> $packet->{dst_ip}:$packet->{dst_port}   ".
			"is_sniffer($packet->{is_sniffer})",
			$mon);
		# print parse_dwords(' debug ',$packet->{payload},1);
	}
	
	# Parse the message(s) in the packet

	if ($packet->{proto} eq 'tcp')
	{
		my $offset = 0;
		while ($packet && $packet_len - $offset >= 4)
		{
			my $len_bytes = substr($payload,$offset,2);
			my $len = unpack('v',$len_bytes);
			my $part = substr($payload,$offset+2,$len);
			my $hdr = pad('',4).unpack('H*',$len_bytes).' ';
			$packet = $this->parseMessage($packet,$len,$part,$hdr);
			$offset += $len + 2;
		}
	}
	else
	{
		my $hdr = pad('',8);
		$packet = $this->parseMessage($packet,length($payload),$payload,$hdr);
	}

	# Return the completely constructed packet.
	# This will be weirdly diffrent in FILESYS

	return $packet;
}



sub parseMessage
	# Derived classes call base class first to display the $MON_RAW output
	# and then handle the message as they see fit. This is where a failure
	# to match a service_id *would* be caught. TODO
{
	my ($this,$packet,$len,$part,$hdr) = @_;
	my $cmd_bytes 	= substr($part,0,2);
	my $sid_bytes 	= substr($part,2,2);
	my $cmd_word 	= unpack('v',$cmd_bytes);
	my $cmd_hex 	= unpack('H*',$cmd_bytes);
	my $sid 		= unpack('v',$sid_bytes);
	my $sid_hex 	= unpack('H*',$sid_bytes);
	my $mon 		= $packet->{mon} || 0;
	
	display($dbg_parse+2,0,"a_parser::parseMessage($this->{name}) ".
			sprintf("len($len) hdr($hdr) cmd_word($cmd_hex) sid($sid) mon(%04x)",$mon));

	# there cases with sniffer packets being misasligned, where
	# sniffer is started in the middle of a multi-packet tcp buffer,
	# after the length word has been sent, so at this point we might get
	# a packet that has a bogus length (which is actually the command word)
	# and bogus command word (which is actually the sid).

	# We don't really want to drop packets on sniffer as we may not know the actual
	# sid of the packet yet, i.e. $HIDDEN_PORT1.  However, for now we compare the sid.

	if ($sid != $this->{sid})
	{
		my $msg = "a_parser::parseMessage($this->{name}) BAD_SID($sid) != expected($this->{sid}) ".
			"is_sniffer($packet->{is_sniffer}) is shark($packet->{is_shark}) len($len) cmd_word($cmd_hex) hdr($hdr)\n".
			parse_dwords('BAD SID:  ',$packet->{payload},1);
		error($msg);
		printConsole($UTILS_COLOR_RED,$msg,$mon);
		return undef;
	}


	if ($mon & $MON_RAW)
	{
		$hdr .= "$cmd_hex $sid_hex ";
		my $text = parse_dwords($hdr,substr($part,4),$mon & $MON_MULTI);
		$text =~ s/\n$//s;	# get rid of last trailing word from parse_words or change semantic of printConsole
		printConsole($packet->{color},$text,$mon);
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
	my ($this,$packet,$piece,$data,$pdata) = @_;

	my $pad = pad('',9);
	my $mon = $packet->{mon} || 0;
	if ($piece eq 'buffer')
	{
		if ($packet->{is_dict} &&
			$packet->{is_reply})
		{
			$$pdata += 4;	# skip biglen
			my $num = unpack('V',substr($data,$$pdata,4));
			$$pdata += 4;
			return error("too many dict_uuids!!") if $num>1024;
				# prevent runaway implementation bug endless loops

			printConsole($packet->{color},$pad."#     dictionary($num)",$mon)
				if $mon & $MON_PIECES;
			$packet->{dict_uuids} ||= shared_clone([]);
			my $dict_uuids = $packet->{dict_uuids};
			for (my $i=0; $i<$num; $i++)
			{
				my $uuid = unpack('H*',substr($data,$$pdata,8));
				$$pdata += 8;
				push @$dict_uuids,$uuid;
				printConsole($packet->{color},$pad."#         dict_uuid($i) = $uuid",$mon)
					if $mon & $MON_DICT;
			}
		}
	}
	elsif ($piece eq 'uuid')
	{
		my $uuid = unpack('H*',substr($data,$$pdata,8));
		$packet->{uuid} = $uuid;
		$$pdata += 8;
		printConsole($packet->{color},$pad."#     $piece = $uuid",$mon)
			if $mon & $MON_PIECES;
	}
	elsif ($piece eq 'name16')
	{
		my $name = unpack('Z*',substr($data,$$pdata,17));
		$packet->{name} = $name;
		$$pdata += 17;
		printConsole($packet->{color},$pad."#     name = $name",$mon)
			if $mon & $MON_PIECES;
	}
	elsif ($piece eq 'success')
	{
		my $status = unpack('H*',substr($data,$$pdata,4));
		my $ok = $status eq $SUCCESS_SIG ? 1 : 0;
		$packet->{success} = $ok;
		$$pdata += 4;
		printConsole($packet->{color},$pad."#     $piece = $ok",$mon)
			if $mon & $MON_PIECES;
	}

	# implemented in base class with 'some' knowledge
	# of derived classes, but without setting any special state

	elsif ($piece =~ /byte|stopable/)		# one byte (flag on wpmgr events)
	{
		my $byte = unpack('C',substr($data,$$pdata++,1));
		$packet->{$piece} = $byte;
		printConsole($packet->{color},$pad."#     $piece = $byte",$mon)
			if $mon & $MON_PIECES;
	}
	elsif ($piece eq 'bits')				# one word (flag on wpmgr changed events)
	{
		my $word = unpack('v',substr($data,$$pdata,2));
		$packet->{$piece} = $word;
		$$pdata += 2;
		printConsole($packet->{color},$pad."#     $piece = $word",$mon)
			if $mon & $MON_PIECES;
	}
	elsif ($piece =~ /is_dict|is_point/)	# generic boolean value
	{
		# state only to the degree that the $pieces are
		# defined in the rules of derived classes, yet
		# there is no special handling here
		display($dbg_parse + 1,1,"$piece = 1");
		$packet->{$piece} = 1;
		printConsole($packet->{color},$pad."#     $piece = 1",$mon)
			if $mon & $MON_PIECES;
	}

	# DERIVED CLASSES MUST EXPLICITLY HANDLE OTHER PIECES THAT CHANGE STATE
	# This class will parse any remaiing pieces into dwords without
	# changing any state.

	else
	{
		my $str = substr($data,$$pdata,4);
		my $value = unpack('V',$str);
		$packet->{$piece} = $value;
		$$pdata += 4;

		# I prefer to SEE non-counters in hex

		my $show_value = $value;
		$show_value = sprintf("0x%02x",$value)
			if $piece !~ /db_count|db_version|evt_flag/;

		printConsole($packet->{color},$pad."#     $piece = $show_value",$mon)
			if $mon & $MON_PIECES;
	}

	return 1;
}



1;
