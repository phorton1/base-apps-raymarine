#---------------------------------------------
# e_TRACK.pm
#---------------------------------------------
# TRACK specific packet parser.
# Overrides parsePacket, parseMessage, and parsePiece to
# implement semantic parsing of service specific packets,
# including returning Track Records in $packet->{item}

package e_TRACK;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use a_defs;
use a_utils;
use b_records;
use d_TRACK;
use base qw(a_parser);

my $dbg_tp = 0;


sub new
{
	my ($class, $parent, $def_port) = @_;
	display($dbg_tp,0,"e_TRACK::new($parent->{name}) def_port($def_port)");
	my $this = $class->SUPER::new($parent,$def_port);
	bless $this,$class;
	$this->{name} = 'e_TRACK';
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

	display($dbg_tp,0,"e_TRACK::parsePacket() is_reply($packet->{is_reply})");

	my $rslt = $this->SUPER::parsePacket($packet);
		# returns the packet as confirmation there were no errors

	display_record(0,0,"final packet($packet->{name})",$packet,'payload|points')
		if $packet->{mon} & $MON_DUMP_RECORD;

	return $rslt;
}



sub parseMessage
	# Calls base_clase BEFORE doing WPMGR specific stuff,
	# which particularly involves maintaing the 'what' context
	# across messages, knowing what messages have sequence numbers,
	# and checking twice for rules,
{
	my ($this,$packet,$len,$part,$hdr) = @_;
	display($dbg_tp+2,0,"e_TRACK::parseMessage($len) hdr($hdr)");
	return 0 if !$this->SUPER::parseMessage($packet,$len,$part,$hdr);

	my $cmd_word = unpack('v',substr($part,0,2));
	my $cmd = $cmd_word & 0xff;
	my $dir = $cmd_word & 0xff00;

	my $cmd_name = $packet->{is_reply} ? $TRACK_REPLY_NAME{$cmd} : $TRACK_REQUEST_NAME{$cmd};
	$cmd_name ||= 'WHO CARES?';
	my $dir_name = $DIRECTION_NAME{$dir};
	display($dbg_tp+2,1,"e_TRACK::parseMessage() dir($dir)=$dir_name cmd($cmd)=$cmd_name");;

	my $pad = pad('',9);
	my $mon = $packet->{mon};
	printConsole($packet->{color},$pad."# $dir_name $cmd_name",$mon)
		if $mon & $MON_PARSE;

	# get the rule

	my $rule = $TRACK_PARSE_RULES{ $cmd_word };
	return error("NO RULE dir($dir)=$dir_name cmd($cmd)=$cmd_name") if !$rule;

	# get the seq_num
	
	my $offset = 4;
		# skip cmd_word and sid
	if (@$rule && $$rule[0] ne 'no_seq')
	{
		my $seq = unpack('V',substr($part,$offset,4));
		display($dbg_tp+2,2,"seq=$seq");
		$offset += 4;
		$packet->{seq_num} ||= $seq;
		printConsole($packet->{color},$pad."#     seq_num = $seq",$mon)
			if $mon & $MON_PARSE;
	}

	# parse the pieces

	for my $piece (@$rule)
	{
		next if $piece eq 'no_seq';
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
			warning($dbg_tp-1,0,"TRACK EVENT($packet->{byte})");
			printConsole($packet->{color},$pad."#     TRACK_EVENT($packet->{byte})",$mon)
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
		my $buffer_type =
			$packet->{is_track} ? 'track' :
			$packet->{is_point} ? 'point' : 'mta';

		printConsole($packet->{color},$pad."#     buffer piece($buffer_type)",$mon)
			if $mon & $MON_PIECES;

		# skip biglen
		# Track messages may return more than one buffer per packet,
		# 	particularly an mta and track record in a single packet
		# So we create a merged {item} of any records encountered.

		my $buffer = substr($data,$$pdata+4);
		$packet->{item} ||= shared_clone({});
		my $item = $packet->{item};
		mergeHash($item,shared_clone(parseMTA($buffer))) 	if $buffer_type eq 'mta';
		mergeHash($item,shared_clone(parseTrack($buffer))) 	if $buffer_type eq 'track';
		mergeHash($item,shared_clone(parsePoint($buffer))) 	if $buffer_type eq 'point';
	}


	elsif ($piece eq 'track_uuid')
	{
		my $uuid = unpack('H*',substr($data,$$pdata,8));
		$packet->{track_uuid} = $uuid;
		$packet->{is_track} = 1;
		$$pdata += 8;

		printConsole($packet->{color},$pad."#     track_uuid = $uuid; is_track=1",$mon)
			if $mon & $MON_PIECES;
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
