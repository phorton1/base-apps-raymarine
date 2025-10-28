#---------------------------------------------
# a_parser.pm
#---------------------------------------------
# base class of parse trees
# known by b_sock and sniffer

package a_parser;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use a_defs;
use a_utils;


my $dbg_parse = 0;



sub new
	# Takes a full port RAYSYS_DEFAULT/SNIFFER_DEFAULT in $mon_def and
	# $mctrl_device as the identified 'client' devices, RNS or SHARK.
	# Applies the mctrl_device to all mon_specs within {$RX} and {$TX}
{
	my ($class, $mon_def, $mctrl_device) = @_;
	$mctrl_device ||= 0;
	display($dbg_parse,0,sprintf("a_parser::new($mon_def->{name},$mon_def->{sid},$mon_def->{proto}) mctrl_device(%04x)",$mctrl_device));
	my $this = shared_clone($mon_def);
	for my $dir ($RX,$TX)
	{
		my $dir_def = $mon_def->{$dir};
		for my $what (keys %$dir_def)
		{
			my $mon_spec = $dir_def->{$what};
			$mon_spec->{ctrl} |= $mctrl_device;
			display($dbg_parse+1,1,sprintf("a_parser::new() mon_spec($dir,$what) color(%d) mctrl(%04x) mon(%08x)",
				$mon_spec->{color} || 0,
				$mon_spec->{ctrl} || 0,
				$mon_spec->{mon} || 0));
		}
	}
	bless $this,$class;
	return $this;
}




sub parsePacket
	# Derived classes figure out {mon_spec} first, then call base class
	# before any monitoring output has taken place.
{
	my ($this,$packet) = @_;
	lock($local_stdout_sem);
		# lock stdout so all of our display and prints occur contiguously
		# within a single color
		
	my $payload = $packet->{payload};
	my $packet_len = length($payload);
	display_hash($dbg_parse+3,0,"a_parser::parsePacket($packet_len)",$packet,'payload');
	
	# derived classes may have set a service specific $mon_spec
	# otherwise, we get the $MCTRL_WHAT_DEFAULT spec from this
	# base class a_parser

	my $mon_spec = $packet->{mon_spec};
	if (!$mon_spec)
	{
		my $dir = $packet->{is_reply} ? $RX : $TX;
		my $dir_defs = $this->{$dir};
		$mon_spec = $dir_defs->{$MCTRL_WHAT_DEFAULT};
		return error("Could not find mon_spec(MCTRL_WHAT_NONE) for dir($dir) in b_parser")
			if !$mon_spec;
		$packet->{mon_spec} = $mon_spec;
	}

	# don't parse SNIFFER PACKETS from ourself, unless
	# $MCTRL_SNIFF_SELF is also specified.

	display($dbg_parse+1,1,sprintf("a_parser::parsePacket mon_spec color(%d) ctrl(%04x) mon(%08x)",
		$mon_spec->{color} || 0,
		$mon_spec->{ctrl} || 0,
		$mon_spec->{mon} || 0));

	my $ctrl = $mon_spec->{ctrl};
	my $mon = $mon_spec->{mon} || 0;
	if ($ctrl & $MCTRL_SOURCE_SNIFFER)
	{
		if ($packet->{is_shark} && !($ctrl & $MCTRL_SNIFF_SELF))
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

	mergeHash($packet,$mon_spec);
		# the packet directly takes on {color} {ctrl} and {mon}

	# Show the raw packet header if the $MON_RAW bit is set
	
	if ($mon & $MON_RAW)
	{
		printConsole($packet->{color},
			pad($packet->{server_name},20).
			($packet->{is_reply} ? '--> ' : '<-- ').
			pad($packet->{client_name},20).
			" $packet->{proto} ".
			pad("len($packet_len)",41).
			"# $packet->{src_ip}:$packet->{src_port} --> $packet->{dst_ip}:$packet->{dst_port}");
	}
	
	# Parse the message(s) in the packet

	if ($this->{proto} eq 'tcp')
	{
		my $offset = 0;
		while ($packet_len - $offset >= 4)
		{
			my $len_bytes = substr($payload,$offset,2);
			my $len = unpack('v',$len_bytes);
			my $part = substr($payload,$offset+2,$len);
			my $hdr = pad('',4).unpack('H*',$len_bytes).' ';
			$this->parseMessage($packet,$len,$part,$hdr);
			$offset += $len + 2;
		}
	}
	else
	{
		my $hdr = pad('',8);
		$this->parseMessage($packet,length($payload),$payload,$hdr);
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
	
	display($dbg_parse+2,0,"a_parser::parseMessage($len) hdr($hdr) cmd_word($cmd_hex) sid($sid)");

	my $mon = $packet->{mon} || 0;
	if ($mon & $MON_RAW)
	{
		$hdr .= "$cmd_hex $sid_hex ";
		my $text = parse_dwords($hdr,substr($part,4),$mon & $MON_MULTI);
		$text =~ s/\n$//s;	# get rid of last trailing word from parse_words or change semantic of printConsole
		printConsole($packet->{color},$text);
	}

	return 1;
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

			printConsole($packet->{color},$pad."#     dictionary($num)")
				if $mon & $MON_PIECE;
			my $dict_uuids = $packet->{dict_uuids};
			for (my $i=0; $i<$num; $i++)
			{
				my $uuid = unpack('H*',substr($data,$$pdata,8));
				$$pdata += 8;
				push @$dict_uuids,$uuid;
				printConsole($packet->{color},$pad."#         dict_uuid($i) = $uuid")
					if $mon & $MON_PIECE;
			}
		}
	}
	elsif ($piece eq 'uuid')
	{
		my $uuid = unpack('H*',substr($data,$$pdata,8));
		$packet->{uuid} = $uuid;
		$$pdata += 8;
		printConsole($packet->{color},$pad."#     $piece = $uuid")
			if $mon & $MON_PIECE;
	}
	elsif ($piece eq 'name16')
	{
		my $name = unpack('Z*',substr($data,$$pdata,17));
		$packet->{name} = $name;
		$$pdata += 17;
		printConsole($packet->{color},$pad."#     name = $name")
			if $mon & $MON_PIECE;
	}
	elsif ($piece eq 'success')
	{
		my $status = unpack('H*',substr($data,$$pdata,4));
		my $ok = $status eq $SUCCESS_SIG ? 1 : 0;
		$packet->{success} = $ok;
		$$pdata += 4;
		printConsole($packet->{color},$pad."#     $piece = $ok")
			if $mon & $MON_PIECE;
	}

	# implemented in base class with 'some' knowledge
	# of derived classes, but without setting any special state

	elsif ($piece =~ /byte|stopable/)		# one byte (flag on wpmgr events)
	{
		my $byte = unpack('C',substr($data,$$pdata++,1));
		$packet->{$piece} = $byte;
		printConsole($packet->{color},$pad."#     $piece = $byte")
			if $mon & $MON_PIECE;
	}
	elsif ($piece eq 'bits')				# one word (flag on wpmgr changed events)
	{
		my $word = unpack('v',substr($data,$$pdata,2));
		$packet->{$piece} = $word;
		$$pdata += 2;
		printConsole($packet->{color},$pad."#     $piece = $word")
			if $mon & $MON_PIECE;
	}
	elsif ($piece =~ /is_dict|is_point/)	# generic boolean value
	{
		# state only to the degree that the $pieces are
		# defined in the rules of derived classes, yet
		# there is no special handling here
		display($dbg_parse,1,"$piece = 1");
		$packet->{$piece} = 1;
		printConsole($packet->{color},$pad."#     $piece = 1")
			if $mon & $MON_PIECE;
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

		printConsole($packet->{color},$pad."#     $piece = $show_value")
			if $mon & $MON_PIECE;
	}

	return 1;
}





#---------------------------------------
# temporary derived classes
#---------------------------------------

package e_DBNAV;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use a_defs;
use a_utils;
use base qw(a_parser);


1;
