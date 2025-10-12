#---------------------------------------
# r_TRACK.pm
#---------------------------------------
# Client for RAYSYS func(19) == 0x13 == '1300'
#
# Get or erase saved Tracks from E80, and can start,
# stop, save, discard, and rename the 'Current Track'.
#
# Cannot create or modify Tracks otherwise.
# Cannot even set the color of the 'Current Track'

package r_TRACK;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use r_utils;
use r_defs;
use r_RAYSYS;
use wp_parse;	# temporary name
use tcpBase;
use base qw(tcpBase);


my $dbg 		= 1;
my $dbg_parse 	= 1;
my $dbg_got 	= 0;		# for returned tracks (including Current Track)
my $dbg_events 	= 0;
my $dbg_mods 	= 1;


my $WITH_EVENT_PROCESSING	= 1;
my $WITH_MOD_PROCESSING 	= 1;


my $TRACK_PORT 		= 12002;
my $TRACK_FUNC		= 0x0013;
	# 19 == 0x13 == '1300' in streams


our $DEFAULT_TRACK_TCP_INPUT:shared 	= 1;
our $DEFAULT_TRACK_TCP_OUTPUT:shared 	= 1;
our $SHOW_TRACK_PARSED_INPUT:shared 	= 1;
our $SHOW_TRACK_PARSED_OUTPUT:shared 	= 1;

my $out_color = $UTILS_COLOR_LIGHT_CYAN;
my $in_color = $UTILS_COLOR_LIGHT_BLUE;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		startTRACK
		trackUICommand

		$track_mgr

		$SHOW_TRACK_PARSED_INPUT
		$SHOW_TRACK_PARSED_OUTPUT

	);
}

our $track_mgr:shared;


#--------------------------------------
# API
#---------------------------------------

our $API_NONE 			= 0;
our $API_GET_TRACKS		= 1;
our $API_GET_TRACK		= 2;
our $API_GENERAL_CMD	= 3;

my %API_COMMAND_NAME = (
	$API_GET_TRACKS	 => 'GET_TRACKS',
	$API_GET_TRACK	 => 'GET_TRACK',
	$API_GENERAL_CMD  => 'GENERAL_COMMAND' );



sub startTRACK
{
	my ($class) = @_;
	display($dbg,0,"startTRACK($class)");
	my $this = $class->SUPER::new({
		rayname => 'TRACK',
		local_port  => $TRACK_PORT,
		show_input  => $DEFAULT_TRACK_TCP_INPUT,
		show_output => $DEFAULT_TRACK_TCP_OUTPUT,
		in_color	=> $UTILS_COLOR_BROWN,
		out_color   => $UTILS_COLOR_LIGHT_CYAN, });

	$this->{tracks} = shared_clone({});
	$this->{current_track_uuid} = '';
	$track_mgr = $this;
	$this->start();
}



sub showCommand
{
	my ($msg) = @_;
	return if !$SHOW_TRACK_PARSED_OUTPUT;	# in r_WPMGR.pm
	$msg = "\n\n".
		"#------------------------------------------------------------------\n".
		"# $msg\n".
		"#------------------------------------------------------------------\n\n";
	print $msg;
	# navQueryLog($msg,'shark.log');
}



sub trackUICommand
{
	my ($rpart) = @_;
	showCommand("trackUICommand($rpart)");
	return $rpart ?
		queueTRACKCommand($track_mgr,$API_GENERAL_CMD,0,$rpart) :
		queueTRACKCommand($track_mgr,$API_GET_TRACKS,0);
}


sub queueTRACKCommand
{
	my ($this,$api_command,$uuid,$extra) = @_;
	$uuid ||= '';
	$extra ||= '';
	display_hash($dbg+2,0,"queueTRACKCommand($this)",$this);

	return error("No 'this' in queueTRACKCommand") if !$this;
	return error("Not started") if !$this->{started};
	return error("Not running") if !$this->{running};

	my $cmd_name = $API_COMMAND_NAME{$api_command} || 'HUH235?';

	if ($SHOW_TRACK_PARSED_OUTPUT)
	{
		my $msg = "# queueTRACKCommand($api_command=$cmd_name) uuid($uuid) extra($extra)\n";
		print $msg;
		# navQueryLog($msg,"shark.log");
	}

	for my $exist (@{$this->{command_queue}})
	{
		if ($exist->{api_command} == $api_command &&
			$exist->{uuid} eq $uuid)
		{
			warning($dbg-1,0,"not enquiing duplicate api_command($api_command)");
			return 1;
		}
	}
	my $command = shared_clone({
		api_command => $api_command,
		name => $API_COMMAND_NAME{$api_command} || 'HUH236?',
		uuid => $uuid,
		extra => $extra });
	push @{$this->{command_queue}},$command;
	return 1;
}





#----------------------------------
# TRACK PROTOCOL
#-----------------------------------
# Direction Nibble

our $TRACK_DIR_RECV		= 0x000;
our $TRACK_DIR_SEND		= 0x100;
our $TRACK_DIR_INFO		= 0x200;

# Command Nibble
# E80 closes TCP connection on 0x12 and higher
# The commands nibbles have completely different semantics in
# Requests, when used as commands, as opposed to Replies, when
# getting info from the server. Only some are parsed in replies.

										# Reply			Request (command)
my $TRACK_CMD_GET_NTH   	= 0x00;		# recv,info		GET_NTH {seq} {nth} 		Current Track Point
my $TRACK_CMD_SET_NAME		= 0x01;		# recv,info		SET_NAME {seq} {hex16} 		Current Track
my $TRACK_CMD_GET_CUR2		= 0x02;		# recv,info		GET_CUR2 					Current Track MTA and points
my $TRACK_CMD_GET_CUR   	= 0x03;		# recv			GET_CUR 					Current Track MTA
my $TRACK_CMD_SAVE			= 0x04;		# recv			SAVE						Current Track
my $TRACK_CMD_GET_TRACK 	= 0x05;		# 				GET_TRACK {seq} {uuid} 		Get Saved Track - funky results with Current Track uuid
my $TRACK_CMD_GET_MTA		= 0x06;		# recv			GET_MTA   {seq} {uuid}		GEt Track MTA
my $TRACK_CMD_ERASE			= 0x07;		# recv			ERASE_TRACK {seq} {uuid} 	Saved Track only
my $TRACK_CMD_CRASHER8		= 0x08; 	# recv			0801 {func} {seq} 000000000 as a command, crashes with core dump
my $TRACK_CMD_START			= 0x09;		#  				START						starts Current Track tracking
my $TRACK_CMD_STOP			= 0x0a;		# recv			STOP 						stops Current Track
my $TRACK_CMD_DISCARD   	= 0x0b;		# info			DISCARD 					current track, but only after stop and not saved
my $TRACK_CMD_GET_DICT		= 0x0c;		# recv			GET_DICT {seq_num}			gets Saved Tracks (MTAs) index
my $TRACK_CMD_GET_STATE		= 0x0d;		# recv			GET_STATE					returns {stopable} = 1 if Current Track Stop button is enabled
my $TRACK_CMD_USELESS_E		= 0x0e;		# 				useless						returns an event with byte=6, possibly to event others?
my $TRACK_CMD_NOREPLY_F		= 0x0f;		# 				xxxx						never got a reply
my $TRACK_CMD_BUMP_NAME 	= 0x10;		# 				BUMP 						Increment the default Current Track name, talk about useless
my $TRACK_CMD_NO_REPLY_11	= 0x11;		# 				xxxx						never got a reply


# Synonyms for known nibbles that come in replies

my $TRACK_REPLY_CONTEXT   	= 0x00;
my $TRACK_REPLY_BUFFER		= 0x01;
my $TRACK_REPLY_END			= 0x02;
my $TRACK_REPLY_CURRENT   	= 0x03;
my $TRACK_REPLY_TRACK		= 0x04;
my $TRACK_REPLY_MTA 		= 0x05;
my $TRACK_REPLY_ERASED		= 0x06;
my $TRACK_REPLY_DICT		= 0x07;
my $TRACK_REPLY_STATE		= 0x08;
# my $TRACK_REPLY_START		= 0x09;
my $TRACK_REPLY_EVENT		= 0x0a;
my $TRACK_REPLY_CHANGED  	= 0x0b;
# my $TRACK_REPLY_GET_DICT	= 0x0c;
my $TRACK_REPLY_RENAMED		= 0x0d;
# my $TRACK_REPLY_E			= 0x0e;
# my $TRACK_REPLY_F			= 0x0f;
# my $TRACK_REPLY_BUMP_NAME = 0x10;
# my $TRACK_REPLY_11		= 0x11;


my %TRACK_REPLY_NAME = (							# recv
	$TRACK_REPLY_CONTEXT		=> 'CONTEXT',		# header for get nth track point
	$TRACK_REPLY_BUFFER			=> 'BUFFER',        # header for get 'mta' current track
	$TRACK_REPLY_END			=> 'END',           # header for get 'full' current track
	$TRACK_REPLY_CURRENT		=> 'CURRENT',       # reply to 0x04=SAVE
	$TRACK_REPLY_TRACK			=> 'TRACK',         # header for GET_TRACK track replies
	$TRACK_REPLY_MTA 			=> 'MTA',			# header for GET_MTA replies
	$TRACK_REPLY_ERASED			=> 'ERASED',		# reply to 0x07=ERASE
	$TRACK_REPLY_DICT			=> 'DICT',          # header for dictionary replies
	$TRACK_REPLY_STATE			=> 'STATE',         # reply to 0x0d Tracking state inquiry
	# $TRACK_CMD_START			=> 'START',
	$TRACK_REPLY_EVENT			=> 'EVENT',			# event byte
	$TRACK_REPLY_CHANGED		=> 'CHANGED',       # track changed byte
	# $TRACK_REPLY_GET_DICT		=> 'GET_DICT',
	$TRACK_REPLY_RENAMED		=> 'RENAMED',		# success for CMD_RENAME
    # $TRACK_CMD_USELESS_E		=> 'CMD_E',
    # $TRACK_CMD_NOREPLY_F		=> 'CMD_F',
	# $TRACK_CMD_BUMP_NAME		=> 'BUMP_NAME',
	# $TRACK_CMD_NO_REPLY_11	=> 'CMD_11',
);


my %TRACK_REQUEST_NAME = (
	$TRACK_CMD_GET_NTH		=> 'GET_NTH',
	$TRACK_CMD_SET_NAME		=> 'SET_NAME',
	$TRACK_CMD_GET_CUR2		=> 'GET_CUR2',
	$TRACK_CMD_GET_CUR		=> 'GET_CUR',
	$TRACK_CMD_SAVE			=> 'SAVE',
	$TRACK_CMD_GET_TRACK 	=> 'GET TRACK',
	$TRACK_CMD_GET_MTA		=> 'GET_MTA',
	$TRACK_CMD_ERASE		=> 'ERASE_TRACK',
	$TRACK_CMD_CRASHER8		=> 'crasher8',
	$TRACK_CMD_START		=> 'START',
	$TRACK_CMD_STOP			=> 'STOP',
	$TRACK_CMD_DISCARD		=> 'DISCARD',
	$TRACK_CMD_GET_DICT		=> 'GET_DICT',
	$TRACK_CMD_GET_STATE	=> 'GET_STATE',
    $TRACK_CMD_USELESS_E	=> 'uselessE',
    $TRACK_CMD_NOREPLY_F	=> 'no_replyF',
	$TRACK_CMD_BUMP_NAME	=> 'BUMP_NAME',
	$TRACK_CMD_NO_REPLY_11	=> 'no_reply11',
);


# $TRACK_REPLY_CHANGED reply bits
# events uith uuid and change bits
#	2	= deleted	(delete from $this->{tracks})
#	0	= new		(queue API_GET_TRACK)
#   1   = changed	(queue API_GET_TRACK)

# $TRACK_REPLY_EVENT byte (bits)
# received events with bits,
#
# 	1,3 = start
# 	0   = point added
# 	2,0 = stop
# 	4   = renamed
#	1   = discard
#	1	= save
#
#  save results in CMD_CHANGED with the saved uuid for regular [mods] handling
#  which can sort of be ignored, except, for consistency, the current track
#  should be refreshed, which will give a new empty, non tracking Current Track
#
#  Semantically, I think it goes bitwise like this:
#
#	0	= point added, 				reget the Current Track
#   1	= new Current Track uuid	remove the (possibly not started yet) new Current Track
#   2   = changed					reget the Current Track
#	4	= modified					reget the Current Track
#
# The thing is, there is ALWAYS a Current Track on the E80, but it doesn't
# show until it is started (or weirdly renamed before being started)

#----------------------------------------------------------------------
# Packet Parser
#----------------------------------------------------------------------

my %PARSE_RULES = (

	# Replies

	$TRACK_DIR_RECV | $TRACK_REPLY_CONTEXT 		=>	[ 'success', 'is_point' ],		# header for get nth track point
	$TRACK_DIR_RECV | $TRACK_REPLY_BUFFER 		=>	[ 'success' ],					# header for get 'mta' current track
	$TRACK_DIR_RECV | $TRACK_REPLY_END 			=>	[ 'success' ],					# header for get 'full' current track
	$TRACK_DIR_RECV	| $TRACK_REPLY_CURRENT		=>  [ 'success' ],					# reply to 0x04=SAVE
	$TRACK_DIR_RECV | $TRACK_REPLY_TRACK 		=>	[ 'success' ],					# header for track replies
	$TRACK_DIR_RECV | $TRACK_REPLY_MTA 			=>	[ 'success' ],					# header for mta replies
	$TRACK_DIR_RECV	| $TRACK_REPLY_ERASED		=>  [ 'success' ],					# reply to 0x07=ERASE
	$TRACK_DIR_RECV | $TRACK_REPLY_DICT 		=>	[ 'success', 'is_dict'],		# header for dictionary replies
	$TRACK_DIR_RECV	| $TRACK_REPLY_STATE		=>  [ 'stopable',],					# reply to 0x0d Tracking state inquiry
	$TRACK_DIR_RECV	| $TRACK_REPLY_RENAMED		=>  [ 'success' ],					# confirms name change (in an event packet) with sequence number
	# events
	$TRACK_DIR_RECV	| $TRACK_REPLY_CHANGED		=> 	[ 'no_seq', 'uuid','byte' ],
	$TRACK_DIR_RECV	| $TRACK_REPLY_EVENT		=> 	[ 'no_seq', 'byte' ],
	# infos
	$TRACK_DIR_INFO	| $TRACK_REPLY_CONTEXT  	=>	[ 'uuid','context_bits' ],		# uuid context for the reply; bits 01n
	$TRACK_DIR_INFO	| $TRACK_REPLY_BUFFER		=> 	[ 'buffer' ],					# dictionary, MTA, or Track depending on state
	$TRACK_DIR_INFO	| $TRACK_REPLY_END			=> 	[ 'track_uuid' ],				# actually carries mta_uuid, but sets is_track=1

	# Requests

	$TRACK_DIR_SEND | $TRACK_CMD_GET_NTH		=> 	[ 'point_number' ],
	$TRACK_DIR_SEND | $TRACK_CMD_SET_NAME		=> 	[ 'name16' ],
	$TRACK_DIR_SEND | $TRACK_CMD_GET_CUR2		=> 	[],
	$TRACK_DIR_SEND | $TRACK_CMD_GET_CUR		=> 	[],
	$TRACK_DIR_SEND | $TRACK_CMD_SAVE			=> 	[ 'no_seq', ],
	$TRACK_DIR_SEND | $TRACK_CMD_GET_TRACK 		=> 	[ 'uuid', ],
	$TRACK_DIR_SEND | $TRACK_CMD_GET_MTA		=> 	[ 'uuid', ],
	$TRACK_DIR_SEND | $TRACK_CMD_ERASE			=> 	[ 'uuid', ],
	# $TRACK_DIR_SEND | $TRACK_CMD_CRASHER8		=> 	[],
	$TRACK_DIR_SEND | $TRACK_CMD_START			=> 	[ 'no_seq', ],
	$TRACK_DIR_SEND | $TRACK_CMD_STOP			=> 	[ 'no_seq', ],
	$TRACK_DIR_SEND | $TRACK_CMD_DISCARD		=> 	[ 'no_seq', ],
	$TRACK_DIR_SEND | $TRACK_CMD_GET_DICT		=> 	[],
	$TRACK_DIR_SEND | $TRACK_CMD_GET_STATE		=> 	[],
    # $TRACK_DIR_SEND | $TRACK_CMD_USELESS_E	=> 	[],
    # $TRACK_DIR_SEND | $TRACK_CMD_NOREPLY_F	=> 	[],
	$TRACK_DIR_SEND | $TRACK_CMD_BUMP_NAME		=> 	[ 'name16', ],
	# $TRACK_DIR_SEND | $TRACK_CMD_NO_REPLY_11	=>  [],


);

# $TRACK_CMD_GET_DICT results in
#	recv	REPLY_DICT		success
#	info	REPLY_CONTEXT	uuid(0000)		context bits 0x19
#	info	REPLY_BUFFER	<dict>
#	info	REPLY_END		uuid(0000)
#
# $TRACK_CMD_GET_TRACK results in
#
#	recv	REPLY_TRACK 	success
#	info	REPLY_CONTEXT	mta_uuid 		context_bits 0x12
#	info	REPLY_BUFFER	<mta>
#	info	REPLY_END		'track_uuid'							actualy mta_uuid, but we set is_track based on the rule
#	info 	REPLY_CONTEXT	other_uuid		context_bits 0x11
#	info	REPLY_BUFFER	<trk>


sub parseTRACK
{
	my ($is_reply, $buffer) = @_;
	my $offset = 0;
	my $pack_len = length($buffer);
	my $r_name = $is_reply ? "Reply" : "Request";
	display($dbg_parse,0,"parseTRACK($r_name) pack_len($pack_len)");

	my @parts;
	my $num = 0;
	while ($offset < $pack_len)
	{
		my $len = unpack('v',substr($buffer,$offset,2));
		$offset += 2;
		my $part = substr($buffer,$offset,$len);
		push @parts,$part;
		display($dbg_parse+1,2,"part($num) offset($offset) len($len) = ".unpack('H*',$part));
		$offset += $len;
		$num++;
	}

	$num = 0;
	my $rec = shared_clone({is_dict=>0, is_point=>0, is_event=>0, evt_mask=>0, });
	for my $part (@parts)
	{
		my $offset = 0;
		my $len = length($part);
		my ($cmd_word,$func) = unpack('vv',substr($part,$offset,4));
		my $cmd = $cmd_word & 0xff;
		my $dir = $cmd_word & 0xff00;
		my $dir_hex = sprintf("%0x",$dir);

		my $cmd_name = $is_reply ?
			$TRACK_REPLY_NAME{$cmd} :
			$TRACK_REQUEST_NAME{$cmd};
		$cmd_name ||= 'WHO CARES';
		display($dbg_parse,1,"parsePart($num) offset($offset) len($len) dir($dir_hex) cmd($cmd)=$cmd_name part="._lim(unpack('H*',$part),200));
		$offset += 4;
		$num++;

		# get the rule
		my $rule = $PARSE_RULES{ $cmd_word };
		if (!$rule)
		{
			error("NO RULE dir($dir_hex) cmd($cmd=$cmd_name)");
			next;
		}

		if (@$rule && $$rule[0] ne 'no_seq')
		{
			my $seq = unpack('V',substr($part,$offset,4));
			display($dbg_parse,2,"seq=$seq");
			$offset += 4;
			$rec->{seq_num} ||= $seq;
		}

		for my $piece (@$rule)
		{
			parsePiece(
				$rec,
				$piece,
				$part,
				\$offset,
				$len);			# for checking big_len
		}

		# post pieces processing

		if ($is_reply)
		{
			if ($cmd == $TRACK_REPLY_EVENT)
			{
				$rec->{is_event} = 1;
				$rec->{evt_mask} |= $rec->{byte};
				warning($dbg_parse-1,0,"TRACK EVENT($rec->{byte})");
			}
			elsif ($cmd == $TRACK_REPLY_CHANGED)
			{
				$rec->{mods} ||= shared_clone([]);
				push @{$rec->{mods}},shared_clone({
					uuid=>$rec->{uuid},
					byte=>$rec->{byte} });
			}
		}
		
	}	# for each part

	display_hash($dbg_parse+1,1,"parseTRACK returning",$rec);
	return $rec;
}



sub parsePiece
{
	my ($rec,$piece,$part,$poffset,$msg_len) = @_;
	return if $piece eq 'no_seq';

	my $text = '';
	if ($piece eq 'buffer')
	{
		display($dbg_parse,1,"piece(buffer) is_dict($rec->{is_dict}) is_track="._def($rec->{is_track}));
		if (!$rec->{is_dict})
		{
			# skip biglen
			my $big_data = substr($part,$$poffset,4);
			my $big_hex = unpack('H*',$big_data);
			my $big_len = unpack('V',$big_data);

			# warning(0,0,"msg_len($msg_len) big_len($big_hex)=$big_len");
			# error("NOT PLUS 12") if $big_len + 12 != $msg_len;
			
			my $buffer = substr($part,$$poffset+4);
			mergeHash($rec,parsePoint($buffer)) if $rec->{is_point};
			mergeHash($rec,parseTrack($buffer)) if $rec->{is_track};
			mergeHash($rec,parseMTA($buffer)) if !$rec->{is_track} && !$rec->{is_point};
		}
		else	# if ($context->{is_reply})
		{
			$$poffset += 4;	# skip biglen
			my $num = unpack('V',substr($part,$$poffset,4));
			$$poffset += 4;

			display($dbg_parse,1,"piece(buffer) is_dict found $num uuids");
			return error("too many uuids!!") if $num>1024;
			$rec->{uuids} ||= shared_clone([]);
			my $uuids = $rec->{uuids};
			for (my $i=0; $i<$num; $i++)
			{
				my $uuid = unpack('H*',substr($part,$$poffset,8));
				$$poffset += 8;
				push @$uuids,$uuid;
				display($dbg_parse,2,"uuids($i)=$uuid");
			}
		}
	}
	elsif ($piece eq 'uuid')
	{
		my $uuid = unpack('H*',substr($part,$$poffset,8));
		my $field = $rec->{is_track} ? 'track_uuid' : 'uuid';
		$rec->{$field} = $uuid;
		display($dbg_parse,1,"uuid($field)=$uuid");
		$$poffset += 8;
	}
	elsif ($piece eq 'track_uuid')
	{
		my $uuid = unpack('H*',substr($part,$$poffset,8));
		$rec->{track_uuid} = $uuid;
		display($dbg_parse,1,"piece(track_uuid)=$uuid");
		$rec->{is_track} = 1;
		$$poffset += 8;
	}
	elsif ($piece eq 'success')
	{
		my $status = unpack('H*',substr($part,$$poffset,4));
		my $ok = $status eq $SUCCESS_SIG ? 1 : 0;
		display($dbg_parse,1,"success=$ok");
		$rec->{success} =1 if $ok;
		$$poffset += 4;
	}
	elsif ($piece =~ /byte|stopable/)	# one byte flag on events
	{
		my $byte = unpack('C',substr($part,$$poffset++,1));
		display($dbg_parse,1,"$piece=$byte");
		$rec->{$piece} = $byte;
	}
	elsif ($piece eq 'bits')	# one word flag on changed events
	{
		my $bits = unpack('v',substr($part,$$poffset,2));
		display($dbg_parse,1,"bits=$bits");
		$rec->{$piece} = $bits;
		$$poffset += 2;
	}
	elsif ($piece =~ /is_dict|is_point/)
	{
		display($dbg_parse,1,"$piece = 1");
		$rec->{$piece} = 1;
	}
	else
	{
		my $str = substr($part,$$poffset,4);
		my $value = unpack('V',$str);
		$$poffset += 4;

		$value = unpack('H*',$str) if $piece eq 'junk';

		display($dbg_parse,1,"rec($piece) = '$value'");
				
		$rec->{$piece} = $value;

		if (0 && $piece eq 'context_bits')
		{
			if ($value & 0x10)
			{
				$rec->{is_dict} = 1;
				$rec->{uuids} = shared_clone([]);
				display($dbg_parse,2,"setting is_dict bit");
			}
		}

	}
}





#-------------------------------------------------
# utilities
#-------------------------------------------------

sub createMsg
{
	my ($seq,$cmd,$uuid,$param) = @_;
	$uuid ||= 0;
	$param ||= 0;
	my $cmd_name = $TRACK_REQUEST_NAME{$cmd} || 'HUH?';
	display($dbg,0,"createMsg($seq,$cmd,$uuid,$param) $cmd_name");
	my $data =
		pack('v',$cmd | $TRACK_DIR_SEND).
		pack('v',$TRACK_FUNC);
	$data .= pack('V',$seq) if $seq;
	$data .= pack('H*',$uuid) if $uuid;
	$data .= $param if $param;
	my $len = length($data);
	my $packet = pack('v',$len).$data;
	display($dbg,1,"msg=".unpack('H*',$packet));
	return $packet;
}


sub sendRequest
{
	my ($this,$seq,$name,$request) = @_;

	if ($SHOW_TRACK_PARSED_OUTPUT)
	{
		my $rec = parseTRACK(0,$request);
		# my $text = "# sendRequest($seq) $name\n";
		# $text .= $rec->{text};
		# # 1=with_text, 0=is_reply		$text .= $rec->{text};
		# setConsoleColor($out_color) if $out_color;
		# print $text;
		# setConsoleColor() if $out_color;
		# navQueryLog($text,'shark.log');
	}

	$this->sendPacket($request);
	$this->{wait_seq} = $seq;
	$this->{wait_name} = $name;
	return 1
}



#============================================================
# virtual handleCommand and class specific atoms
#============================================================

sub get_tracks
	# get all track_mts uuids, then all tracks
{
	my ($this) = @_;
	print "get_tracks()\n";

	my $seq;
	my $request;
	my $reply;

	# get_tracks shall not assume the current track is recording
	# so it needs to call $TRACK_CMD_GET_STATE, wait for the
	# $TRACK_REPLY_STATE and see if {stopable} is true, and only
	# then should it queue the $TRACK_CMD_GET_CUR2.

	if (1)
	{
		my $get_current_track = 0;

		$seq = $this->{next_seqnum}++;
		$request = createMsg($seq,$TRACK_CMD_GET_STATE,0,0);
		return 0 if !$this->sendRequest($seq,"CURRENT TRACK",$request);
		$reply = $this->waitReply(0);
			# GET_STATE does not return a success code
			# so it is sufficient to wait for matching {seq} only
		if ($reply)
		{
			$get_current_track = $reply->{stopable};
		}

		if ($get_current_track)
		{
			$seq = $this->{next_seqnum}++;
			$request = createMsg($seq,$TRACK_CMD_GET_CUR2,0,0);
			return 0 if !$this->sendRequest($seq,"CURRENT TRACK",$request);
			$reply = $this->waitReply(1);

			if ($reply)
			{
				my $uuid = $reply->{uuid};
				my $tracks = $this->{tracks};
				$tracks->{$uuid} = $reply;
				$reply->{version} = $this->incVersion();
				$this->{current_track_uuid} = $uuid;
			}
		}
	}

	# get the dictionary

	$seq = $this->{next_seqnum}++;
	$request = createMsg($seq,$TRACK_CMD_GET_DICT,0,0);
	return 0 if !$this->sendRequest($seq,"TRACKS DICT",$request);
	$reply = $this->waitReply(1);
	return 0 if !$reply;
	
	# enqueue from dictionary

	my $uuids = $reply->{uuids};
	my $num = 0;
	for my $uuid (@$uuids)
	{
		$this->queueTRACKCommand($API_GET_TRACK,$uuid,"from index($num");
		$num++;
	}

	my $tracks = $this->{tracks};
	display($dbg+1,1,"keys(tracks) = ".join(" ",keys %$tracks));
	return 1;

}	# get_tracks()



sub get_track
{
	my ($this,$command) = @_;
	my $uuid = $command->{uuid};
	my $extra = $command->{extra} || '';

	if (1 && $dbg <= 0)
	{
		print "--------------------  $extra $uuid -----------------------------\n";
	}
	
	display($dbg,0,"get_track($uuid)");

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$TRACK_CMD_GET_TRACK,$uuid,0);
	return 0 if !$this->sendRequest($seq,"get_track($uuid)",$request);

	if (1 && $dbg <= 0)
	{
		print "-----------------------------------------------------------------\n";
	}

	my $reply = $this->waitReply(1);
	return 0 if !$reply;

	warning($dbg_got,0,"got track($uuid) = '$reply->{name}'");

	my $tracks = $this->{tracks};
	$tracks->{$uuid} = $reply;
	$reply->{version} = $this->incVersion();
	return 1;

}   # get_track()



sub do_general
{
	my ($this,$command) = @_;
	my $rpart = $command->{extra} || '';
	display($dbg,0,"do_general($rpart)");

	my $cmd = -1;
	my $seq = $this->{next_seqnum}++;
	my $uuid = 0;
	my $param = 0;
	my $returns_current_track = 0;
	my $expect_reply = 0;

	# monadic Current Track commands
	# all except 'state' and 'bump' will get EVENT replies,
	
	if ($rpart =~ /^(start|stop|save|discard|state|bump)$/)
	{
		$cmd =
			$rpart eq 'start' 	? $TRACK_CMD_START :
			$rpart eq 'stop' 	? $TRACK_CMD_STOP :
			$rpart eq 'save' 	? $TRACK_CMD_SAVE :
			$rpart eq 'discard' ? $TRACK_CMD_DISCARD :
			$rpart eq 'state' 	? $TRACK_CMD_START :
			$rpart eq 'bump' 	? $TRACK_CMD_BUMP_NAME : -1;
		$seq = 0 if $rpart !~ /state|bump/;
	}

	# Current Track commands with {seq} and no parameter

	elsif ($rpart =~ /^(cur|cur2)/)
	{
		$cmd = $rpart eq 'cur' ?
			$TRACK_CMD_GET_CUR :
			$TRACK_CMD_GET_CUR2;
		$returns_current_track = 1 if $rpart eq 'cur2';
		$expect_reply = 1;
	}

	# Current or Saved Track commands with {seq} and parameter

	elsif ($rpart =~ /^(mta|name|nth|erase)\s(.*$)/)
	{
		my ($what, $rvalue) = ($1,$2);

		$cmd = $TRACK_CMD_SET_NAME if $what eq 'name';
		$cmd = $TRACK_CMD_GET_NTH if $what eq 'nth';
		$cmd = $TRACK_CMD_ERASE if $what eq 'erase';
		$cmd = $TRACK_CMD_GET_MTA if $what eq 'mta';

		$expect_reply = 1 if $cmd eq 'nth' || $cmd eq 'mta';

		# params for name and nth
		
		$param = pack('H*',name16_hex($rvalue)) if $what eq 'name';
		$param = pack('v',$rvalue) if $what eq 'nth';

		# implement erase to find the track uuid by name
		# but use lc() for ease of use
		
		if ($what eq 'mta' || $what eq 'erase')
		{
			my $tracks = $this->{tracks};
			for my $track_uuid (keys %$tracks)
			{
				my $track = $tracks->{$track_uuid};
				if (lc($track->{name}) eq lc($rvalue))
				{
					$uuid = $track_uuid;
					last;
				}
			}

			$uuid ?
				display($dbg,1,"found $rpart(".lc($rvalue)." at uuid=uuid") :
				return error("Could not find $rpart name(".lc($rvalue).")");
		}
	}

	my $request = createMsg($seq,$cmd,$uuid,$param);
	return 0 if !$this->sendRequest($seq,"$rpart",$request);
	my $reply = $expect_reply ? $this->waitReply(1) : 1;
	return 0 if !$reply;

	# the below *may* be obviated by event handling

	if ($returns_current_track)
	{
		my $ct_uuid = $reply->{uuid};
		warning($dbg_got,0,"got Current Track($ct_uuid) = '$reply->{name}'");
	
		my $tracks = $this->{tracks};
		$tracks->{$ct_uuid} = $reply;
		$reply->{version} = $this->incVersion();
		$this->{current_track_uuid} = $ct_uuid;
	}

	return 1;

}	# do_general()




sub handleCommand
{
	my ($this,$command) = @_;
	my $api_command = $command->{api_command};
	my $cmd_name = $API_COMMAND_NAME{$api_command} || 'HUH237?';
	display($dbg,0,"$this->{rayname} handleCommand($api_command=$cmd_name) started");

	my $rslt;
	$rslt = $this->get_tracks($command) if $api_command == $API_GET_TRACKS;
	$rslt = $this->get_track($command) 	if $api_command == $API_GET_TRACK;
	$rslt = $this->do_general($command) if $api_command == $API_GENERAL_CMD;

	error("API $cmd_name failed") if !$rslt;
	display($dbg,0,"$this->{rayname} handleCommand($api_command=$cmd_name) finished");
}



#========================================================================
# virtual handlePacket method
#========================================================================

sub handlePacket
{
	my ($this,$buffer) = @_;

	warning($dbg+1,0,"handlePacket(".length($buffer).") called");

	my $reply = parseTRACK(1,$buffer);
		# 1=is_reply

	if (0 && $SHOW_TRACK_PARSED_INPUT)
	{
		my $text = $reply->{text};
		setConsoleColor($in_color);
		print $text;
		setConsoleColor() if $in_color;
		navQueryLog($text,'shark.log');
	}

	# EVENTS do nothing
	# CHANGED deletes a record or generates $API_GET_TRACK command

	my $skip_reply = 0;
	if ($reply->{is_event} && $WITH_EVENT_PROCESSING)
	{
		$skip_reply = 1;
		my $mask = $reply->{evt_mask};
		display($dbg_events,0,"readbuf reply EVT_MASK($mask)",0,$UTILS_COLOR_LIGHT_MAGENTA);

			# 	1,3 = start
			# 	0   = point added
			# 	2,0 = stop
			# 	4   = renamed
			#	1   = discard
			#	1	= save

			#	0	= point added, 				reget the Current Track
			#   1	= new Current Track uuid	remove the (possibly not started yet) new Current Track
			#   2   = changed					reget the Current Track
			#	4	= modified					reget the Current Track

		if ($mask & 1)
		{
			if ($this->{current_track_uuid})
			{
				warning($dbg_events,0,"removing current track($this->{current_track_uuid})");
				delete $this->{tracks}->{$this->{current_track_uuid}};
				$this->{current_track_uuid} = '';
				$this->incVersion();
			}
		}
		if ($mask != 1)
		{
			warning($dbg_events,2,"enquing GET_CUR2");
			$this->queueTRACKCommand($API_GENERAL_CMD,0,'cur2');
		}
	}

	if ($reply->{mods} && $WITH_MOD_PROCESSING)
	{
		$skip_reply = 1;
		for my $mod (@{$reply->{mods}})
		{
			my $byte = $mod->{byte};
			my $uuid = $mod->{uuid};

			display($dbg_mods,1,"TRACK_CHANGED($uuid,$byte)");

			if ($byte == 2)	# delete it
			{
				my $tracks = $this->{tracks};
				my $exists = $tracks->{$uuid};
				if ($exists)
				{
					warning($dbg_mods,2,"deleting tracks($uuid) $exists->{name}");
					delete $tracks->{$uuid};
					$this->incVersion();
				}
			}
			else	# enqueue a GET_TRACK command
			{
				warning($dbg_mods,2,"enquing GET_TRACK($uuid)");
				$this->queueTRACKCommand($API_GET_TRACK,$uuid);
			}
		}	# for each $mod
	}	# {mods} && $WITH_MOD_PROCESSING

	$reply = undef if $skip_reply;	# event handled
	# warning(0,0,"handlePacket() returning reply="._def($reply));
	return $reply;

}	# handlePacket()


1;