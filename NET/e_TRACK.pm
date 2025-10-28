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
	my ($class, $mon_def, $mctrl_device) = @_;
	display($dbg_tp,0,"e_TRACK::new()");
	my $this = $class->SUPER::new($mon_def,$mctrl_device);
	bless $this,$class;
	return $this;
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
		is_dict 	=> 0,
		is_point	=> 0,
		is_event 	=> 0,
		evt_mask	=> 0, });

	my $mon_key = $MCTRL_WHAT_TRACK;
	my $mon_dir = $packet->{is_reply} ? $RX : $TX;
	my $dir_def = $this->{$mon_dir};
	my $mon_spec = $packet->{mon_spec} = $dir_def->{$mon_key};

	my $mon = $mon_spec->{mon} || 0;
	my $ctrl = $mon_spec->{ctrl} || 0;
	display($dbg_tp,0,sprintf("e_TRACK::parsePacket($mon_dir) ctrl(%04x) mon(%08x)",$ctrl,$mon));

	my $rslt = $this->SUPER::parsePacket($packet);

	# temp debugging
	display_record(0,0,"packet",$packet,'payload|points') if $mon & $MON_PIECE;

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
	printConsole($packet->{color},$pad."# $dir_name $cmd_name")
		if $mon & ($MON_PARSE | $MON_PIECE);

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
		printConsole($packet->{color},$pad."#     seq_num = $seq")
			if $mon & ($MON_PARSE | $MON_PIECE);
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
			printConsole($packet->{color},$pad."#     TRACK_EVENT($packet->{byte})")
				if $mon & ($MON_PARSE | $MON_PIECE);
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

		printConsole($packet->{color},$pad."#     buffer piece($buffer_type)")
			if $mon & $MON_PIECE;

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

		printConsole($packet->{color},$pad."#     track_uuid = $uuid; is_track=1")
			if $mon & $MON_PIECE;
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
