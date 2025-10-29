#---------------------------------------------
# e_WPMGR.pm
#---------------------------------------------
# WPMGR parser overrides parsePacket, parseMessage, and
# parsePiece to implement semantic parsing of WPMGR packets,
# including returning WRG Records in $packet->{item}

package e_WPMGR;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use a_defs;
use a_utils;
use e_wp_defs;		# temp architecture
use b_records;
use base qw(a_parser);

my $dbg_ewp = 0;


sub new
{
	my ($class, $parent, $def_port) = @_;
	display($dbg_ewp,0,"e_WPMGR::new($parent->{name}) def_port($def_port)");
	my $this = $class->SUPER::new($parent,$def_port);
	bless $this,$class;
	$this->{name} = 'e_WPMGR';
	return $this;
}


sub applyMonDefs
{
	my ($this,$packet) = @_;
	display($dbg_ewp+1,0,"e_WPMGR::applyMonDefs()");

	$this->setContext($packet,substr($packet->{payload},2,2));
		# the entire payload includes the leading length word
	my $what = $packet->{what};
	$packet->{name} = $NAV_WHAT{$what};
	
	my $is_reply = $packet->{is_reply};
	my $defs = $packet->{is_sniffer} ?
		\%SNIFFER_DEFAULTS :
		\%RAYSYS_DEFAULTS;
	my $def = $defs->{$this->{def_port}};

	my $idx =
		$what == $WHAT_GROUP ? $MON_WHAT_GROUP :
		$what == $WHAT_ROUTE ? $MON_WHAT_ROUTE :
		$MON_WHAT_WAYPOINT;

	$packet->{mon} = $is_reply ?
		$def->{mon_ins}->[$idx] :
		$def->{mon_outs}->[$idx];
	$packet->{color} = $is_reply ?
		$def->{in_colors}->[$idx] :
		$def->{out_colors}->[$idx];
}



sub setContext
	# WPMGR packets must maintain the $what context
	# 	appropriately between messages.
	# This method sets {what} if it is non-zero within
	#	the command word, or on SEND/RECIVE (!INFO) direction
	#	nibble within the command word.
{
	my ($this,$packet,$part) = @_;
	my $cmd_word = unpack('v',$part);
	my $D = $cmd_word & 0xf00;
	my $W = $cmd_word & 0xf0;
	$packet->{cmd_word} = $cmd_word;
	$packet->{what} = $W if $W || $D != $DIRECTION_INFO;
	$packet->{what} ||= 0;
	my $what = $packet->{what};
	display($dbg_ewp+1,0,sprintf("e_WPMGR::setContext() cmd_word(%04x) what($what}=$NAV_WHAT{$what}",$cmd_word));
}





sub parsePacket
	# Calls base clase AFTER figuring out what mon_ins/outs,
	# colors to use, and applying them to the packet
{
	my ($this,$packet) = @_;

	# the packet namespace is crowded and it is crucial
	# that no base class names are overwritten by derived classes

	mergeHash($packet,{
		is_dict 	=> 0,
		seq_num 	=> 0,
		is_event 	=> 0,
		uuid		=> '' });

	display($dbg_ewp+1,0,"e_WPMGR::parsePacket()");

	my $rslt = $this->SUPER::parsePacket($packet);

	display_record(0,0,"final packet($packet->{name})",$packet,'payload') if
		$packet->{mon} & $MON_DUMP_RECORD;

	return $rslt;
}



sub parseMessage
	# Calls base_clase BEFORE doing WPMGR specific stuff,
	# which particularly involves maintaing the 'what' context
	# across messages, knowing what messages have sequence numbers,
	# and checking twice for rules,
{
	my ($this,$packet,$len,$part,$hdr) = @_;
	display($dbg_ewp+2,0,"e_WPMGR::parseMessage($len) hdr($hdr)");
	return 0 if !$this->SUPER::parseMessage($packet,$len,$part,$hdr);

	$this->setContext($packet,$part);
		# parts do not include the leading length word

	my $what = $packet->{what};
	my $cmd_word = $packet->{cmd_word};
	display($dbg_ewp+2,1,sprintf("e_WPMGR::parseMessage() cmd_word(%04x) context what($what)=".$NAV_WHAT{$what},$cmd_word));

	my $D = $cmd_word & 0xf00;
	my $W = $cmd_word & 0xf0;
	my $C = $cmd_word & 0xf;
	my $dir_name = $DIRECTION_NAME{$D};
	my $what_name = $NAV_WHAT{$W};
	my $cmd_name = $NAV_COMMAND{$C};

	my $pad = pad('',9);
	my $mon = $packet->{mon};
	printConsole($packet->{color},$pad."# $dir_name $cmd_name $what_name",$mon)
		if $mon & $MON_PARSE;

	my $offset = 4;	# skip cmd_word and sid
	if (!$packet->{is_reply} || (
		$C != $CMD_MODIFY &&
		$C != $CMD_EVENT ))
	{
		my $seq_num = unpack('V',substr($part,$offset,4));
		display($dbg_ewp+3,1,"seq_num=$seq_num");
		printConsole($packet->{color},$pad."#     seq_num = $seq_num",$mon)
			if $mon & $MON_PARSE;

		$packet->{seq_num} ||= $seq_num;
		$offset += 4;
	}

	# find rule, first by full command word, then by $dir | $cmd

	my $rule = $WPMGR_PARSE_RULES{$cmd_word};
	$rule = $WPMGR_PARSE_RULES{ $D | $C } if !$rule;
	if ($rule)
	{
		for my $piece (@$rule)
		{
			$this->parsePiece(
				$packet,
				$piece,
				$part,
				\$offset);
		}
	}
	else # NO RULE!
	{
		error("NO RULE FOR $dir_name | $cmd_name | $what_name");
	}

	return 1;
}





sub parsePiece
	# Parses pieces that are specific to WPMGR, especially
	# those that change the state of inter-message parsing
	# or rely on previous messages (state).
{
	my ($this,$packet,$piece,$part,$poffset) = @_;

	my $pad = pad('',9);
	my $mon = $packet->{mon};

	if ($piece eq 'buffer' && !$packet->{is_dict})
	{
		# Parse WPMGR specific buffers into records
		my $what_name = $NAV_WHAT{$packet->{what}};

		printConsole($packet->{color},$pad."#     buffer piece($what_name)",$mon)
			if $mon & $MON_PIECES;

		my $detail_level = 0;
		my $item = parseWPMGRRecord($what_name,substr($part,$$poffset));
		# $text = WPRecordToText($item,$show_what,$indent,$detail_level)
		# 	if $with_text;
		$packet->{item} = $item;
	}
	elsif ($piece eq 'context_bits')
	{
		# context_bits is the only way that WPMGR knows
		# that the buffer contains a dictionary, which
		# buffer will then be parsed by the base class.

		my $str = substr($part,$$poffset,4);
		my $value = unpack('V',$str);
		$$poffset += 4;

		printConsole($packet->{color},$pad.sprintf("#     context_bits = 0x%04x",$value),$mon)
			if $mon & $MON_PIECES;

		if ($value & 0x10)
		{
			$packet->{is_dict} = 1;
			$packet->{dict_uuids} = shared_clone([]);
			printConsole($packet->{color},$pad."#         is_dict = 1",$mon)
				if $mon & $MON_PIECES;
		}
	}

	# WPMGR event handling and [mods] are a beast of their own.

	elsif ($piece eq 'evt_flag')
	{
		my $str = substr($part,$$poffset,4);
		my $value = unpack('V',$str);
		$$poffset += 4;

		printConsole($packet->{color},$pad.sprintf("#     evt_flag(%04x) is_event=1",$value),$mon)
			if $mon & $MON_PIECES;

		$packet->{is_event} = 1;
		$packet->{evt_mask} ||= 0;
			# Since all replies are atomic, the is_event from init_context()
			# is only used to set the initial record to zero. is_event is
			# never normalized back into the context.

		my $mask = $packet->{what};
		$mask |= 1;					# add in specific 1=waypoints
		$mask <<= $value * 4;		# shift closing flags to high nibble
		$packet->{evt_mask} |= $mask;
	}
	elsif ($piece eq 'mod_bits')
	{
		# Developes a list of 'mods' about records the E80 has
		# told us we need to delete, or get as a result of our request.

		my $str = substr($part,$$poffset,4);
		my $value = unpack('V',$str);
		$$poffset += 4;

		printConsole($packet->{color},$pad.sprintf("#     mod_bits(%04x)",$value),$mon)
			if $mon & $MON_PIECES;

		my $what = $packet->{what};
		my $uuid = $packet->{uuid};
		my $mods = $packet->{mods} = shared_clone([]) if !exists($packet->{mods});
		my $mod = shared_clone({
			what => $what,
			uuid => $uuid,
			bits => $value });
		push @$mods,$mod;
	}

	# Call the base class to handle many common piece types

	else
	{
		return $this->SUPER::parsePiece($packet,$piece,$part,$poffset)
	}

	# return 1 to indicate no errors

	return 1;
}


1;
