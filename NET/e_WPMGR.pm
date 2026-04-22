#---------------------------------------------
# e_WPMGR.pm
#---------------------------------------------
# WPMGR parser overrides parsePacket, parseMessage, and
# parsePiece to implement semantic parsing of WPMGR packets,
# including returning WRG Records in $packet->{item}

package apps::raymarine::NET::e_WPMGR;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_mon;
use apps::raymarine::NET::a_utils;
use apps::raymarine::NET::e_wp_defs;
use apps::raymarine::NET::b_records;
use base qw(apps::raymarine::NET::a_parser);

my $dbg_ewp = 0;


sub newParser
{
	my ($class, $mon_defs) = @_;
	display($dbg_ewp,0,"apps::raymarine::NET::e_WPMGR::newParser($mon_defs->{name}) is_shark($mon_defs->{is_shark}) is_sniffer($mon_defs->{is_sniffer})");
	my $this = $class->SUPER::newParser($mon_defs);
	bless $this,$class;
	return $this;
}


sub applyMonDefs
{
	my ($this,$packet) = @_;
	display($dbg_ewp+1,0,"apps::raymarine::NET::e_WPMGR::applyMonDefs()");

	# skip the 0th message word(length)
	my $cmd_word = unpack('v',substr($packet->{payload},2,2));
	my $W = $cmd_word & 0xf0;

	$packet->{name} = $NAV_WHAT{$W};
	
	my $is_reply = $packet->{is_reply};
	my $mon_defs = $this->{mon_defs};

	my $idx =
		$W == $WHAT_GROUP ? $MON_WHAT_GROUP :
		$W == $WHAT_ROUTE ? $MON_WHAT_ROUTE :
		$MON_WHAT_WAYPOINT;

	if ($mon_defs->{active})
	{
		my $log = $mon_defs->{log};
		$packet->{mon} = $is_reply ?
			$mon_defs->{mon_ins}->[$idx] :
			$mon_defs->{mon_outs}->[$idx];
		$packet->{mon} |= $log;
		# identify self-sniffed packets
		$packet->{mon} |= $MON_SELF_SNIFFED
			if $packet->{is_sniffer} && $packet->{is_shark};
	}
	else
	{
		$packet->{mon} = 0;
	}
	$packet->{color} = $is_reply ?
		$mon_defs->{in_colors}->[$idx] :
		$mon_defs->{out_colors}->[$idx];
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
	display($dbg_ewp+1,0,"apps::raymarine::NET::e_WPMGR::parsePacket()");
	return $this->SUPER::parsePacket($packet);
}



sub parseMessage
	# Calls base_clase BEFORE doing WPMGR specific stuff,
	# which particularly involves maintaing the 'what' context
	# across messages, knowing what messages have sequence numbers,
	# and checking twice for rules,
{
	my ($this,$packet,$len,$part) = @_;
	display($dbg_ewp+2,0,"apps::raymarine::NET::e_WPMGR::parseMessage($len)");
	return undef if !$this->SUPER::parseMessage($packet,$len,$part);

	my $cmd_word = unpack('v',$part);
	my $D = $cmd_word & 0xf00;
	my $W = $cmd_word & 0xf0;
	my $C = $cmd_word & 0xf;

	my $dir_name = $DIRECTION_NAME{$D};
	my $what_name = $NAV_WHAT{$W};
	my $cmd_name = $NAV_COMMAND{$C};

	my $mon = $packet->{mon};
	my $color = $packet->{color};
	printConsole(1,$mon,$color,"$dir_name $cmd_name $what_name")
		if $mon & $MON_PARSE;

	if ($W || !defined($packet->{what}) || $D != $DIRECTION_INFO)
	{
		if (!defined($packet->{what}) || $packet->{what} != $W)
		{
			$packet->{what} = $W;
		}
	}

	# find rule, first by full command word, then by $dir | $cmd

	my $rule = $WPMGR_PARSE_RULES{$cmd_word};
	$rule = $WPMGR_PARSE_RULES{ $D | $C } if !$rule;
	if ($rule)
	{
		my $offset = 4;	# skip cmd_word and sid
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

	return $packet;
}





sub parsePiece
	# Parses pieces that are specific to WPMGR, especially
	# those that change the state of inter-message parsing
	# or rely on previous messages (state).
{
	my ($this,$packet,$piece,$part,$poffset) = @_;
	my $mon = $packet->{mon};
	my $color = $packet->{color};

	if ($piece eq 'buffer' && !$packet->{is_dict})
	{
		# Parse WPMGR specific buffers into records
		my $item;
		my $what = $packet->{what};
		my $buffer = substr($part,$$poffset);

		printConsole(2,$mon,$color,"buffer piece($NAV_WHAT{$what})")
			if $mon & $MON_PIECES;

		$item = parseWaypoint(0,$buffer,$mon,$color) if $what == $WHAT_WAYPOINT;
		$item = parseRoute(0,$buffer,$mon,$color)    if $what == $WHAT_ROUTE;
		$item = parseGroup(0,$buffer,$mon,$color)    if $what == $WHAT_GROUP;

		$packet->{item} = shared_clone($item);
	}
	elsif ($piece eq 'context_bits')
	{
		# context_bits is the only way that WPMGR knows
		# that the buffer contains a dictionary, which
		# buffer will then be parsed by the base class.

		my $str = substr($part,$$poffset,4);
		my $value = unpack('V',$str);
		$$poffset += 4;

		printConsole(2,$mon,$color,sprintf("context_bits = 0x%04x",$value))
			if $mon & $MON_PIECES;

		if ($value & 0x10)
		{
			$packet->{is_dict} = 1;
			$packet->{dict_uuids} = shared_clone([]);
			printConsole(2,$mon,$color,"is_dict = 1")
				if $mon & $MON_PIECES;
		}
	}

	# WPMGR event handling and [mods] are a beast of their own.

	elsif ($piece eq 'evt_flag')
	{
		my $str = substr($part,$$poffset,4);
		my $value = unpack('V',$str);
		$$poffset += 4;

		printConsole(2,$mon,$color,sprintf("evt_flag(%04x) is_event=1",$value))
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

		printConsole(2,$mon,$color,sprintf("mod_bits(%04x)",$value))
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
