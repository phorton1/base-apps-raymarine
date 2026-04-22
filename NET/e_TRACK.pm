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
	return $this;
}


sub parsePacket
	# Sets up class specific state members, then
	# calls base class to do all the work.
{
	my ($this,$packet) = @_;
		# the packet namespace is crowded and it is crucial
		# that no base class names are overwritten by derived classes
	mergeHash($packet,{
		is_dict 	=> 0,
		is_point	=> 0,
		is_event 	=> 0,
		evt_mask	=> 0, });
	display($dbg_tp+1,0,"apps::raymarine::NET::e_TRACK::parsePacket() is_reply($packet->{is_reply})");
	$packet = $this->SUPER::parsePacket($packet);

	my $item = $packet ? $packet->{item} : undef;
	if ($item)
	{
		my $cnt1 = $item->{cnt1};
		if (defined($cnt1))		# expected number of points
		{
			my $points = $item->{points};
			my $num_points = $points ? @$points : 0;
			if ($num_points != $cnt1)
			{
				error("track($packet->{uuid}) $item->{name} bad number points($num_points) != expected($cnt1)");
				return undef;
			}
		}
	}
	return $packet;
}



sub parseMessage
	# Calls base_clase BEFORE doing WPMGR specific stuff,
	# which particularly involves maintaing the 'what' context
	# across messages, knowing what messages have sequence numbers,
	# and checking twice for rules,
{
	my ($this,$packet,$len,$part) = @_;
	display($dbg_tp+2,0,"apps::raymarine::NET::e_TRACK::parseMessage($len)");
	return undef if !$this->SUPER::parseMessage($packet,$len,$part);

	my $cmd_word = unpack('v',substr($part,0,2));
	my $cmd = $cmd_word & 0xff;
	my $dir = $cmd_word & 0xff00;

	my $cmd_name = $packet->{is_reply} ? $TRACK_REPLY_NAME{$cmd} : $TRACK_REQUEST_NAME{$cmd};
	$cmd_name ||= 'WHO CARES?';
	my $dir_name = $DIRECTION_NAME{$dir};
	display($dbg_tp+2,1,"apps::raymarine::NET::e_TRACK::parseMessage() dir($dir)=$dir_name cmd($cmd)=$cmd_name");;

	my $mon = $packet->{mon};
	printConsole(1,$mon,$packet->{color},"$dir_name $cmd_name")
		if $mon & $MON_PARSE;

	# get the rule

	my $rule = $TRACK_PARSE_RULES{ $cmd_word };
	return error("NO RULE dir($dir)=$dir_name cmd($cmd)=$cmd_name") if !$rule;

	# parse the pieces

	my $offset = 4;				# skip cmd_word and sid
	for my $piece (@$rule)
	{
		$this->parsePiece(
			$packet,
			$piece,
			$part,
			\$offset);			# for checking big_len
	}

	# post pieces processing

	if ($packet->{is_reply})
	{
		if ($cmd == $TRACK_REPLY_EVENT)
		{
			$packet->{is_event} = 1;
			$packet->{evt_mask} |= $packet->{byte};
			warning($dbg_evt,0,"TRACK EVENT($packet->{byte})");
			printConsole(2,$mon,$packet->{color},"TRACK_EVENT($packet->{byte})")
				if $mon & $MON_PARSE;
		}
		elsif ($cmd == $TRACK_REPLY_CHANGED)
		{
			$packet->{mods} ||= shared_clone([]);
			push @{$packet->{mods}},shared_clone({
				uuid=>$packet->{uuid},
				byte=>$packet->{byte} });
		}
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
		my $buffer_type =
			$packet->{is_track} ? 'trk' :
			$packet->{is_point} ? 'point' : 'mta';
		my $uuid_field = $buffer_type.'_uuid';
		$packet->{$uuid_field} = $packet->{uuid};

		printConsole(2,$mon,$color,"buffer piece($buffer_type) $uuid_field = $packet->{$uuid_field}")
			if $mon & $MON_PIECES;

		# +4 == skip biglen
		# Track messages may return more than one buffer per packet,
		# 	particularly an mta and track record in a single packet
		# So we create a merged {item} of any records encountered.

		my $color = $packet->{color};
		my $buffer = substr($part,$$poffset+4);
		$packet->{item} ||= shared_clone({});
		my $item = $packet->{item};
		mergeHash($item,parseMTA($buffer,$mon,$color)) 	 if $buffer_type eq 'mta';

		# there may be more than one TRK per Track, so here we DONT merge hash,
		# but specifically ADD the points from the parse to the $item;

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
	}
	elsif ($piece eq 'track_uuid')
	{
		my $uuid = unpack('H*',substr($part,$$poffset,8));
		$packet->{uuid} = $uuid;
		$packet->{is_track} = 1;
		$$poffset += 8;

		if ($mon & $MON_PIECES)
		{
			printConsole(2,$mon,$color,"is_track=1");
			printConsole(2,$mon,$color,"uuid = $uuid");
		}

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
