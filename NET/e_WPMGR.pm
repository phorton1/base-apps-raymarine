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
	$this->{last_dir_was_reply} = 1;
	$this->resetTransaction();
	return $this;
}


sub resetTransaction
{
	my ($this) = @_;
	$this->{tx} = shared_clone({
		seq_num    => 0,
		what       => 0,
		is_dict    => 0,
		is_event   => 0,
		evt_mask   => 0,
		evt_close  => 0,
		uuid       => '',
		success    => 0,
		item       => undef,
		item_buf   => '',
		item_total => undef,
		dict_uuids => undef,
		dict_total => undef,
		mods       => undef,
		name       => '',
	});
}


sub applyMonDefs
{
	my ($this,$packet) = @_;
	display($dbg_ewp+1,0,"apps::raymarine::NET::e_WPMGR::applyMonDefs()");

	# payload is now the msg body (no length prefix); cmd_word is at offset 0
	my $cmd_word = unpack('v',substr($packet->{payload},0,2));
	my $D = $cmd_word & 0xf00;
	my $W = $cmd_word & 0xf0;
	# for INFO messages where W==0, use established tx context
	if (!$W && $D == $DIRECTION_INFO)
	{
		$W = $this->{tx}{what} // 0;
	}

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







sub parseMessage
	# Per-message dispatch for TCP stream model.
	# Returns undef for intermediate messages, shared reply hash for terminal.
{
	my ($this,$packet,$len,$part) = @_;
	display($dbg_ewp+2,0,"apps::raymarine::NET::e_WPMGR::parseMessage($len)");
	return undef if !$this->SUPER::parseMessage($packet,$len,$part);

	my $cmd_word = unpack('v',$part);
	my $D = $cmd_word & 0xf00;
	my $W = $cmd_word & 0xf0;
	my $C = $cmd_word & 0xf;

	my $dir_name  = $DIRECTION_NAME{$D};
	my $what_name = $NAV_WHAT{$W};
	my $cmd_name  = $NAV_COMMAND{$C};

	my $mon   = $packet->{mon};
	my $color = $packet->{color};
	printConsole(0,$mon,$color,"$dir_name $cmd_name $what_name")
		if $mon & $MON_PARSE;

	# update 'what' context; W==0 on INFO means keep current context
	if ($W || !defined($this->{tx}{what}) || $D != $DIRECTION_INFO)
	{
		$this->{tx}{what} = $W;
	}

	my $rule = $WPMGR_PARSE_RULES{$cmd_word};
	$rule = $WPMGR_PARSE_RULES{$D | $C} if !$rule;
	if ($rule)
	{
		my $offset = 4;
		for my $piece (@{$rule->{pieces}})
		{
			$this->parsePiece($packet,$piece,$part,\$offset);
		}

		# RECV_DATA: terminal only when success==0 (item not found)
		if ($D == $DIRECTION_RECV && $C == $CMD_DATA && !$this->{tx}{success})
		{
			return shared_clone({%{$this->{tx}}});
		}

		if ($rule->{terminal})
		{
			my $reply = shared_clone({%{$this->{tx}}});
			$reply->{seq_num} = 0 if $rule->{is_event};
			return $reply;
		}
	}
	else
	{
		error("NO RULE FOR $dir_name | $cmd_name | $what_name");
	}

	return undef;
}





sub parsePiece
	# State fields use $this->{tx}; $packet carries only display info (mon, color).
{
	my ($this,$packet,$piece,$part,$poffset) = @_;
	my $mon   = $packet->{mon};
	my $color = $packet->{color};

	if ($piece eq 'buffer' && !$this->{tx}{is_dict})
	{
		my $what   = $this->{tx}{what};
		my $buffer = substr($part,$$poffset);

		printConsole(2,$mon,$color,"buffer piece($NAV_WHAT{$what})")
			if $mon & $MON_PIECES;

		if ($what == $WHAT_ROUTE)
		{
			my $big_len = unpack('V', substr($buffer, 0, 4));

			if (!defined $this->{tx}{item_total})
			{
				$this->{tx}{item_buf} = substr($buffer, 4, $big_len);
				my $name_len = unpack('C', substr($this->{tx}{item_buf}, 2, 1));
				my $cmt_len  = unpack('C', substr($this->{tx}{item_buf}, 3, 1));
				my $num_wpts = unpack('v', substr($this->{tx}{item_buf}, 4, 2));
				$this->{tx}{item_total} = 8 + $name_len + $cmt_len + $num_wpts * 18 + 46;
			}
			else
			{
				$this->{tx}{item_buf} .= substr($buffer, 4, $big_len);
			}

			if (length($this->{tx}{item_buf}) >= $this->{tx}{item_total})
			{
				my $total = length($this->{tx}{item_buf});
				my $item = parseRoute(0, pack('V',$total) . $this->{tx}{item_buf}, $mon, $color);
				$this->{tx}{item} = shared_clone($item) if $item;
				delete $this->{tx}{item_buf};
				delete $this->{tx}{item_total};
			}
		}
		else
		{
			my $item;
			$item = parseWaypoint(0,$buffer,$mon,$color) if $what == $WHAT_WAYPOINT;
			$item = parseGroup(0,$buffer,$mon,$color)    if $what == $WHAT_GROUP;
			$this->{tx}{item} = shared_clone($item);
		}
	}
	elsif ($piece eq 'context_bits')
	{
		my $str = substr($part,$$poffset,4);
		my $value = unpack('V',$str);
		$$poffset += 4;

		printConsole(2,$mon,$color,sprintf("context_bits = 0x%04x",$value))
			if $mon & $MON_PIECES;

		if ($value & 0x10)
		{
			$this->{tx}{is_dict}    = 1;
			$this->{tx}{dict_uuids} = shared_clone([]);
			printConsole(2,$mon,$color,"is_dict = 1")
				if $mon & $MON_PIECES;
		}
	}
	elsif ($piece eq 'evt_flag')
	{
		my $str = substr($part,$$poffset,4);
		my $value = unpack('V',$str);
		$$poffset += 4;

		printConsole(2,$mon,$color,sprintf("evt_flag(%04x) is_event=1",$value))
			if $mon & $MON_PIECES;

		$this->{tx}{is_event} = 1;
		$this->{tx}{evt_mask} ||= 0;

		my $mask = $this->{tx}{what};
		$mask |= 1;
		$mask <<= $value * 4;
		$this->{tx}{evt_mask} |= $mask;
		$this->{tx}{evt_close} = 1 if $value == 1;
	}
	elsif ($piece eq 'mod_bits')
	{
		my $str = substr($part,$$poffset,4);
		my $value = unpack('V',$str);
		$$poffset += 4;

		printConsole(2,$mon,$color,sprintf("mod_bits(%04x)",$value))
			if $mon & $MON_PIECES;

		my $what = $this->{tx}{what};
		my $uuid = $this->{tx}{uuid};
		$this->{tx}{mods} ||= shared_clone([]);
		my $mod = shared_clone({
			what => $what,
			uuid => $uuid,
			bits => $value });
		push @{$this->{tx}{mods}},$mod;
	}
	else
	{
		return $this->SUPER::parsePiece($packet,$piece,$part,$poffset)
	}

	return 1;
}


1;
