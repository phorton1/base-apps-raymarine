#---------------------------------------------
# e_TRACK.pm
#---------------------------------------------
# TRACK specific packet parser.
# Overrides parsePacket, parseMessage, and parsePiece to
# implement semantic parsing of service specific packets,
# including returning Track Records in $packet->{item}

package apps::raymarine::NET::e_TRACK;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_mon;
use apps::raymarine::NET::a_utils;
use apps::raymarine::NET::b_records;
use apps::raymarine::NET::d_TRACK;
use base qw(apps::raymarine::NET::a_parser);

my $dbg_tp = 0;
my $dbg_evt = 0;


sub newParser
{
	my ($class, $mon_defs) = @_;
	display($dbg_tp,0,"apps::raymarine::NET::e_TRACK::new($mon_defs->{name})");
	my $this = $class->SUPER::newParser($mon_defs);
	bless $this,$class;
	$this->resetTransaction();
	return $this;
}


sub resetTransaction
{
	my ($this) = @_;
	$this->{tx} = shared_clone({
		seq_num    => 0,
		is_dict    => 0,
		is_track   => 0,
		is_point   => 0,
		is_event   => 0,
		expect_trk => 0,
		evt_mask   => 0,
		uuid       => '',
		success    => 0,
		item       => undef,
		dict_uuids => undef,
		dict_total => undef,
		mods       => undef,
		byte       => 0,
		mta_uuid   => '',
		trk_uuid   => '',
		point_uuid => '',
	});
	delete $this->{buffer_complete};
}



sub parseMessage
	# Per-message dispatch for TCP stream model.
	# Returns undef for intermediate messages, shared reply hash for terminal.
{
	my ($this,$packet,$len,$part) = @_;
	display($dbg_tp+2,0,"apps::raymarine::NET::e_TRACK::parseMessage($len)");
	return undef if !$this->SUPER::parseMessage($packet,$len,$part);

	my $cmd_word = unpack('v',substr($part,0,2));
	my $cmd = $cmd_word & 0xff;
	my $dir = $cmd_word & 0xff00;

	return undef if $cmd_word == 0xFFFF;		# E80 close-marker sent before FIN

	my $cmd_name = $packet->{is_reply} ? $TRACK_REPLY_NAME{$cmd} : $TRACK_REQUEST_NAME{$cmd};
	$cmd_name ||= 'WHO CARES?';
	my $dir_name = $DIRECTION_NAME{$dir} // sprintf('0x%04X',$dir);
	display($dbg_tp+2,1,"apps::raymarine::NET::e_TRACK::parseMessage() dir($dir)=$dir_name cmd($cmd)=$cmd_name");

	my $mon = $packet->{mon};
	printConsole(1,$mon,$packet->{color},"$dir_name $cmd_name")
		if $mon & $MON_PARSE;

	my $rule = $TRACK_PARSE_RULES{$cmd_word};
	return error("NO RULE dir($dir)=$dir_name cmd($cmd)=$cmd_name") if !$rule;

	# set expect_trk flag for commands that return MTA+TRK (GET_TRACK, GET_CUR2)
	# GET_CUR2 reply is RECV BUFFER (same as GET_CUR), so check on SEND direction
	if (($dir == $DIRECTION_SEND && $cmd == $TRACK_CMD_GET_CUR2) ||
		($dir == $DIRECTION_RECV &&
		 ($cmd == $TRACK_REPLY_TRACK || $cmd == $TRACK_REPLY_END)))
	{
		$this->{tx}{expect_trk} = 1;
	}

	my $offset = 4;
	for my $piece (@{$rule->{pieces}})
	{
		$this->parsePiece($packet,$piece,$part,\$offset);
	}

	# post-piece processing for event state
	if ($dir == $DIRECTION_RECV && $cmd == $TRACK_REPLY_EVENT)
	{
		$this->{tx}{is_event} = 1;
		$this->{tx}{evt_mask} |= $this->{tx}{byte};
		warning($dbg_evt,0,"TRACK EVENT($this->{tx}{byte})");
		printConsole(2,$mon,$packet->{color},"TRACK_EVENT($this->{tx}{byte})")
			if $mon & $MON_PARSE;
	}
	elsif ($dir == $DIRECTION_RECV && $cmd == $TRACK_REPLY_CHANGED)
	{
		$this->{tx}{mods} ||= shared_clone([]);
		push @{$this->{tx}{mods}},shared_clone({
			uuid => $this->{tx}{uuid},
			byte => $this->{tx}{byte} });
	}

	# buffer_complete is set by parsePiece for terminal buffer conditions
	if ($this->{buffer_complete})
	{
		delete $this->{buffer_complete};
		my $reply = shared_clone({%{$this->{tx}}});

		# validate track point count
		my $item = $reply->{item};
		if ($item)
		{
			my $cnt1 = $item->{cnt1};
			if (defined($cnt1))
			{
				my $points = $item->{points};
				my $num_points = $points ? scalar(@$points) : 0;
				if ($num_points != $cnt1)
				{
					error("track($reply->{uuid}) bad points($num_points) != expected($cnt1)");
					return undef;
				}
			}
		}
		return $reply;
	}

	if ($rule->{terminal})
	{
		my $reply = shared_clone({%{$this->{tx}}});
		$reply->{seq_num} = 0 if $rule->{is_event};
		return $reply;
	}

	return undef;
}




sub parsePiece
	# State fields use $this->{tx}; $packet carries only display info (mon, color).
	# Sets $this->{buffer_complete} to signal dynamic terminal condition.
{
	my ($this,$packet,$piece,$part,$poffset) = @_;
	my $mon   = $packet->{mon};
	my $color = $packet->{color};

	if ($piece eq 'buffer' && !$this->{tx}{is_dict})
	{
		my $buffer_type =
			$this->{tx}{is_track} ? 'trk' :
			$this->{tx}{is_point} ? 'point' : 'mta';
		my $uuid_field = $buffer_type.'_uuid';
		$this->{tx}{$uuid_field} = $this->{tx}{uuid};

		printConsole(2,$mon,$color,"buffer piece($buffer_type) $uuid_field = $this->{tx}{$uuid_field}")
			if $mon & $MON_PIECES;

		my $buffer = substr($part,$$poffset+4);
		$this->{tx}{item} ||= shared_clone({});
		my $item = $this->{tx}{item};
		mergeHash($item,parseMTA($buffer,$mon,$color)) if $buffer_type eq 'mta';

		if ($buffer_type eq 'trk')
		{
			my $rec = parseTRK($buffer,$mon,$color);
			if ($item->{points})
			{
				push @{$item->{points}},@{$rec->{points}};
			}
			else
			{
				$item->{points} = $rec->{points};
			}
		}
		mergeHash($item,parsePoint($buffer,$mon,$color)) if $buffer_type eq 'point';

		# determine terminal condition for this buffer
		if ($this->{tx}{is_track})
		{
			$this->{buffer_complete} = 1;  # TRK buffer after INFO_END → terminal for GET_TRACK/GET_CUR2
		}
		elsif (!$this->{tx}{expect_trk})
		{
			$this->{buffer_complete} = 1;  # single-buffer commands: MTA, point → terminal
		}
		# else: mta buffer in multi-buffer sequence (GET_TRACK/GET_CUR2); TRK buffer still coming
	}
	elsif ($piece eq 'track_uuid')
	{
		my $uuid = unpack('H*',substr($part,$$poffset,8));
		$this->{tx}{uuid}     = $uuid;
		$this->{tx}{is_track} = 1;
		$$poffset += 8;

		if ($mon & $MON_PIECES)
		{
			printConsole(2,$mon,$color,"is_track=1");
			printConsole(2,$mon,$color,"uuid = $uuid");
		}

		# for dict queries, INFO_END is the terminal (no further buffer follows)
		$this->{buffer_complete} = 1 if $this->{tx}{is_dict};
	}
	else
	{
		return $this->SUPER::parsePiece($packet,$piece,$part,$poffset)
	}

	return 1;
}


1;
