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
	my ($class, $mon_def, $mctrl_device) = @_;
	display($dbg_ewp,0,"e_WPMGR::new()");
	my $this = $class->SUPER::new($mon_def,$mctrl_device);
	bless $this,$class;
	return $this;
}



sub setContext
	# WPMGR packets must maintain the $what context
	# 	appropriately between messages.
	# This method sets {what} if it is non-zero within
	#	the command word, or on SEND/RECIVE (!INFO) direction
	#	nibble within the command word.
{
	my ($this,$packet,$cmd_bytes) = @_;
	my $cmd_word = unpack('v',$cmd_bytes);
	my $D = $cmd_word & 0xf00;
	my $W = $cmd_word & 0xf0;
	$packet->{cmd_word} = $cmd_word;
	$packet->{what} = $W if $W || $D != $DIR_INFO;
}





sub parsePacket
	# Calls base clase AFTER figuring out what mon_spec to use.
	# We know that WBPMGR is tcp and know to skip the message length word
	# 	to look ahead to 0th message to get the cmd_word which is
	# 	needed to get the mon_spec for the packet, so we, and the
	# 	base class know whether or not to display/parse the packet.
	# We pass the {mon_spec} member back to the base class
{
	my ($this,$packet) = @_;
	my $payload = $packet->{payload};

	# the packet namespace is crowded and it is crucial
	# that no base class names are overwritten by derived classes

	mergeHash($packet,{
		what 		=> 0,	# sigh
		is_dict 	=> 0,
		seq_num 	=> 0,
		is_event 	=> 0,
		uuid		=> '' });

	my $cmd_bytes = substr($payload,2,2);
	$this->setContext($packet,$cmd_bytes);
		# very specific to WPMGR is the fact that there are three
		# three subtypes within it, and we need to figure that out here.

	my $what = $packet->{what};
	my $cmd_word = $packet->{cmd_word};
	display($dbg_ewp+1,0,sprintf("e_WPMGR::parsePacket() cmd_word(%04x) what($what)=".$NAV_WHAT{$what},$cmd_word));

	# The idea of $MCTRL_WHAT_DICT is questionable.
	# It has always bothered me that what=0 is only an implied WP.
	# We wont know if its a dictionary until much later, and I am
	# trying hard to implement real-time monitoring while parsing
	# without building a whole text structure first, so I will just
	# proceed here and debug it later.

	my $mon_key =
		$what == $WHAT_ROUTE ? $MCTRL_WHAT_ROUTE :
		$what == $WHAT_GROUP ? $MCTRL_WHAT_GROUP :
		$MCTRL_WHAT_WP;
	my $mon_dir = $packet->{is_reply} ? $RX : $TX;

	my $dir_def = $this->{$mon_dir};
	$packet->{mon_spec} = $dir_def->{$mon_key};

	my $rslt = $this->SUPER::parsePacket($packet);

	# temp debugging
	my $mon = $packet->{mon} || 0;
	display_record(0,0,"packet",$packet,'payload') if $mon & $MON_PIECE;

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

	my $cmd_bytes = substr($part,0,2);
	$this->setContext($packet,$cmd_bytes);

	my $what = $packet->{what};
	my $cmd_word = $packet->{cmd_word};
	display($dbg_ewp+2,1,sprintf("e_WPMGR::parseMessage() cmd_word(%04x) context what($what)=".$NAV_WHAT{$what},$cmd_word));

	my $D = $cmd_word & 0xf00;
	my $W = $cmd_word & 0xf0;
	my $C = $cmd_word & 0xf;
	my $dir_name = $NAV_DIRECTION{$D};
	my $what_name = $NAV_WHAT{$W};
	my $cmd_name = $NAV_COMMAND{$C};

	my $pad = pad('',9);
	my $mon = $packet->{mon};
	printConsole($packet->{color},$pad."# $dir_name $cmd_name $what_name")
		if $mon & ($MON_PARSE | $MON_PIECE);

	my $data_offset = 4;
	if (!$packet->{is_reply} || (
		$C != $CMD_MODIFY &&
		$C != $CMD_EVENT ))
	{
		my $seq_num = unpack('V',substr($part,$data_offset,4));
		display($dbg_ewp+2,1,"seq_num=$seq_num");
		printConsole($packet->{color},$pad."#     seq_num = $seq_num")
			if $mon & ($MON_PARSE | $MON_PIECE);

		$packet->{seq_num} ||= $seq_num;
		$data_offset += 4;
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
				\$data_offset);	# indent buffer records a bit
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
	my ($this,$packet,$piece,$data,$pdata) = @_;

	my $pad = pad('',9);
	my $mon = $packet->{mon};

	if ($piece eq 'buffer' && !$packet->{is_dict})
	{
		# Parse WPMGR specific buffers into records
		my $what_name = $NAV_WHAT{$packet->{what}};

		printConsole($packet->{color},$pad."#     buffer piece($what_name)")
			if $mon & $MON_PIECE;

		my $detail_level = 0;
		my $item = parseWPMGRRecord($what_name,substr($data,$$pdata));
		# $text = WPRecordToText($item,$show_what,$indent,$detail_level)
		# 	if $with_text;
		$packet->{item} = $item;
	}
	elsif ($piece eq 'context_bits')
	{
		# context_bits is the only way that WPMGR knows
		# that the buffer contains a dictionary, which
		# buffer will then be parsed by the base class.

		my $str = substr($data,$$pdata,4);
		my $value = unpack('V',$str);
		$$pdata += 4;

		printConsole($packet->{color},$pad.sprintf("#     context_bits = 0x%04x",$value))
			if $mon & $MON_PIECE;

		if ($value & 0x10)
		{
			$packet->{is_dict} = 1;
			$packet->{dict_uuids} = shared_clone([]);
			printConsole($packet->{color},$pad."#         is_dict = 1")
				if $mon & $MON_PIECE;
		}
	}

	# WPMGR event handling and [mods] are a beast of their own.

	elsif ($piece eq 'evt_flag')
	{
		my $str = substr($data,$$pdata,4);
		my $value = unpack('V',$str);
		$$pdata += 4;

		printConsole($packet->{color},$pad.sprintf("#     evt_flag(%04x) is_event=1",$value))
			if $mon & $MON_PIECE;

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

		my $str = substr($data,$$pdata,4);
		my $value = unpack('V',$str);
		$$pdata += 4;

		printConsole($packet->{color},$pad.sprintf("#     mod_bits(%04x)",$value))
			if $mon & $MON_PIECE;

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
		return $this->SUPER::parsePiece($packet,$piece,$data,$pdata)
	}

	# return 1 to indicate no errors

	return 1;
}


1;
