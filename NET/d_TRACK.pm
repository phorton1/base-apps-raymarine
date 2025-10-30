#---------------------------------------
# d_TRACK.pm
#---------------------------------------
# Client for RAYSYS func(19) == 0x13 == '1300'
#
# Get or erase saved Tracks from E80, and can start,
# stop, save, discard, and rename the 'Current Track'.
#
# Cannot create or modify Tracks otherwise.
# Cannot even set the color of the 'Current Track'

package d_TRACK;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use a_utils;
use a_defs;
use b_records;	# temporary name
# use c_RAYSYS  loaded by shark.pm
use base qw(b_sock);


my $dbg 		= 1;
my $dbg_parse 	= 1;
my $dbg_got 	= 0;		# for returned tracks (including Current Track)
my $dbg_events 	= -1;
my $dbg_mods 	= -1;


my $WITH_EVENT_PROCESSING	= 1;
my $WITH_MOD_PROCESSING 	= 1;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(

		$TRACK_CMD_GET_NTH
		$TRACK_CMD_SET_NAME
		$TRACK_CMD_GET_CUR2
		$TRACK_CMD_GET_CUR
		$TRACK_CMD_SAVE
		$TRACK_CMD_GET_TRACK
		$TRACK_CMD_GET_MTA
		$TRACK_CMD_ERASE
		$TRACK_CMD_RENAME
		$TRACK_CMD_START
		$TRACK_CMD_STOP
		$TRACK_CMD_DISCARD
		$TRACK_CMD_GET_DICT
		$TRACK_CMD_GET_STATE
		$TRACK_CMD_USELESS_E
		$TRACK_CMD_NOREPLY_F
		$TRACK_CMD_BUMP_NAME
		$TRACK_CMD_NO_REPLY_11

		$TRACK_REPLY_CONTEXT
		$TRACK_REPLY_BUFFER
		$TRACK_REPLY_END
		$TRACK_REPLY_CURRENT
		$TRACK_REPLY_TRACK
		$TRACK_REPLY_MTA
		$TRACK_REPLY_ERASED
		$TRACK_REPLY_DICT
		$TRACK_REPLY_STATE
		$TRACK_REPLY_EVENT
		$TRACK_REPLY_CHANGED
		$TRACK_REPLY_NAMED
		$TRACK_REPLY_RENAMED

		%TRACK_REPLY_NAME
		%TRACK_REQUEST_NAME
		%TRACK_PARSE_RULES 
	);
}



my $TRACK_SERVICE_ID = 19;
	# 19 == 0x13 == '1300' in streams


sub init
{
	my ($this) = @_;
	display($dbg,0,"d_TRACK init($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto}");
	$this->SUPER::init();
	$this->{local_ip} = $LOCAL_IP;
	
	$this->{tracks} = shared_clone({});
	$this->{current_track_uuid} = '';
	return $this;
}



sub destroy
{
	my ($this) = @_;
	display($dbg,0,"d_TRACK destroy($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto}");

	$this->SUPER::destroy();

    delete @$this{qw(tracks current_track_uuid)};
	return $this;
}





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





sub showCommand
{
	my ($this,$msg) = @_;
	return if !$this->{show_parsed_output};
	$msg = "\n\n".
		"#------------------------------------------------------------------\n".
		"# $msg\n".
		"#------------------------------------------------------------------\n\n";
	print $msg;
	# writeLog($msg,'shark.log');
}



sub trackUICommand
{
	my ($this,$rpart) = @_;
	$this->showCommand("trackUICommand($rpart)");
	return $rpart ?
		queueTRACKCommand($this,$API_GENERAL_CMD,0,$rpart) :
		queueTRACKCommand($this,$API_GET_TRACKS,0);
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

	if (1)
	{
		my $msg = "# queueTRACKCommand($api_command=$cmd_name) uuid($uuid) extra($extra)\n";
		print $msg;
		# writeLog($msg,"shark.log");
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
# Command Nibble

# E80 closes TCP connection on 0x12 and higher
# The commands nibbles have completely different semantics in
# Requests, when used as commands, as opposed to Replies, when
# getting info from the server. Only some are parsed in replies.

										# Reply			Request (command)
our $TRACK_CMD_GET_NTH   	= 0x00;		# recv,info		GET_NTH {seq} {nth} 		Current Track Point
our $TRACK_CMD_SET_NAME		= 0x01;		# recv,info		SET_NAME {seq} {hex16} 		Current Track
our $TRACK_CMD_GET_CUR2		= 0x02;		# recv,info		GET_CUR2 					Current Track MTA and points
our $TRACK_CMD_GET_CUR   	= 0x03;		# recv			GET_CUR 					Current Track MTA
our $TRACK_CMD_SAVE			= 0x04;		# recv			SAVE						Current Track
our $TRACK_CMD_GET_TRACK 	= 0x05;		# 				GET_TRACK {seq} {uuid} 		Get Saved Track - funky results with Current Track uuid
our $TRACK_CMD_GET_MTA		= 0x06;		# recv			GET_MTA   {seq} {uuid}		GEt Track MTA
our $TRACK_CMD_ERASE		= 0x07;		# recv			ERASE_TRACK {seq} {uuid} 	Saved Track only
our $TRACK_CMD_RENAME		= 0x08; 	# recv			RENAME {seq} {uuid} {hex16} Renames a saved track
our $TRACK_CMD_START		= 0x09;		#  				START						starts Current Track tracking
our $TRACK_CMD_STOP			= 0x0a;		# recv			STOP 						stops Current Track
our $TRACK_CMD_DISCARD   	= 0x0b;		# info			DISCARD 					current track, but only after stop and not saved
our $TRACK_CMD_GET_DICT		= 0x0c;		# recv			GET_DICT {seq_num}			gets Saved Tracks (MTAs) index
our $TRACK_CMD_GET_STATE	= 0x0d;		# recv			GET_STATE					returns {stopable} = 1 if Current Track Stop button is enabled
our $TRACK_CMD_USELESS_E	= 0x0e;		# 				useless						returns an event with byte=6, possibly to event others?
our $TRACK_CMD_NOREPLY_F	= 0x0f;		# 				xxxx						never got a reply
our $TRACK_CMD_BUMP_NAME 	= 0x10;		# 				BUMP 						Increment the default Current Track name, talk about useless
our $TRACK_CMD_NO_REPLY_11	= 0x11;		# 				xxxx						never got a reply


# Synonyms for known nibbles that come in replies

our $TRACK_REPLY_CONTEXT   	= 0x00;
our $TRACK_REPLY_BUFFER		= 0x01;
our $TRACK_REPLY_END		= 0x02;
our $TRACK_REPLY_CURRENT   	= 0x03;
our $TRACK_REPLY_TRACK		= 0x04;
our $TRACK_REPLY_MTA 		= 0x05;
our $TRACK_REPLY_ERASED		= 0x06;
our $TRACK_REPLY_DICT		= 0x07;
our $TRACK_REPLY_STATE		= 0x08;
# our $TRACK_REPLY_START	= 0x09;
our $TRACK_REPLY_EVENT		= 0x0a;
our $TRACK_REPLY_CHANGED  	= 0x0b;
# our $TRACK_REPLY_GET_DICT	= 0x0c;
our $TRACK_REPLY_NAMED		= 0x0d;
our $TRACK_REPLY_RENAMED	= 0x0e;
# our $TRACK_REPLY_F		= 0x0f;
# our $TRACK_REPLY_BUMP_NAME = 0x10;
# our $TRACK_REPLY_11		= 0x11;


our %TRACK_REPLY_NAME = (							# recv
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
	$TRACK_REPLY_NAMED			=> 'NAMED',			# success for CMD_SET_NAME
    $TRACK_REPLY_RENAMED		=> 'RENAMED',		# success for CMD_RENAME
    # $TRACK_CMD_NOREPLY_F		=> 'CMD_F',
	# $TRACK_CMD_BUMP_NAME		=> 'BUMP_NAME',
	# $TRACK_CMD_NO_REPLY_11	=> 'CMD_11',
);


our %TRACK_REQUEST_NAME = (
	$TRACK_CMD_GET_NTH		=> 'GET_NTH',
	$TRACK_CMD_SET_NAME		=> 'SET_NAME',
	$TRACK_CMD_GET_CUR2		=> 'GET_CUR2',
	$TRACK_CMD_GET_CUR		=> 'GET_CUR',
	$TRACK_CMD_SAVE			=> 'SAVE',
	$TRACK_CMD_GET_TRACK 	=> 'GET TRACK',
	$TRACK_CMD_GET_MTA		=> 'GET_MTA',
	$TRACK_CMD_ERASE		=> 'ERASE_TRACK',
	$TRACK_CMD_RENAME		=> 'RENAME',
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
# Parse rules
#----------------------------------------------------------------------

our %TRACK_PARSE_RULES = (

	# Replies

	$DIRECTION_RECV | $TRACK_REPLY_CONTEXT 		=>	[ 'success', 'is_point' ],		# header for get nth track point
	$DIRECTION_RECV | $TRACK_REPLY_BUFFER 		=>	[ 'success' ],					# header for get 'mta' current track
	$DIRECTION_RECV | $TRACK_REPLY_END 			=>	[ 'success' ],					# header for get 'full' current track
	$DIRECTION_RECV	| $TRACK_REPLY_CURRENT		=>  [ 'success' ],					# reply to 0x04=SAVE
	$DIRECTION_RECV | $TRACK_REPLY_TRACK 		=>	[ 'success' ],					# header for track replies
	$DIRECTION_RECV | $TRACK_REPLY_MTA 			=>	[ 'success' ],					# header for mta replies
	$DIRECTION_RECV	| $TRACK_REPLY_ERASED		=>  [ 'success' ],					# reply to 0x07=ERASE
	$DIRECTION_RECV | $TRACK_REPLY_DICT 		=>	[ 'success', 'is_dict'],		# header for dictionary replies
	$DIRECTION_RECV	| $TRACK_REPLY_STATE		=>  [ 'stopable',],					# reply to 0x0d Tracking state inquiry
	$DIRECTION_RECV	| $TRACK_REPLY_NAMED		=>  [ 'success' ],					# confirms name set (in an event packet) with sequence number
	$DIRECTION_RECV	| $TRACK_REPLY_RENAMED		=>  [ 'success' ],					# confirms name change (as RECV with RECV CHANGED)

	# events
	$DIRECTION_RECV	| $TRACK_REPLY_CHANGED		=> 	[ 'no_seq', 'uuid','byte' ],
	$DIRECTION_RECV	| $TRACK_REPLY_EVENT		=> 	[ 'no_seq', 'byte' ],
	# infos
	$DIRECTION_INFO	| $TRACK_REPLY_CONTEXT  	=>	[ 'uuid','context_bits' ],		# uuid context for the reply; bits 01n
	$DIRECTION_INFO	| $TRACK_REPLY_BUFFER		=> 	[ 'buffer' ],					# dictionary, MTA, or Track depending on state
	$DIRECTION_INFO	| $TRACK_REPLY_END			=> 	[ 'track_uuid' ],				# actually carries mta_uuid, but sets is_track=1
	$DIRECTION_INFO	| $TRACK_REPLY_RENAMED		=>  [ 'success' ],					# confirms name change (in an event packet) with sequence number

	# Requests

	$DIRECTION_SEND | $TRACK_CMD_GET_NTH		=> 	[ 'point_number' ],
	$DIRECTION_SEND | $TRACK_CMD_SET_NAME		=> 	[ 'name16' ],
	$DIRECTION_SEND | $TRACK_CMD_GET_CUR2		=> 	[],
	$DIRECTION_SEND | $TRACK_CMD_GET_CUR		=> 	[],
	$DIRECTION_SEND | $TRACK_CMD_SAVE			=> 	[ 'no_seq', ],
	$DIRECTION_SEND | $TRACK_CMD_GET_TRACK 		=> 	[ 'uuid', ],
	$DIRECTION_SEND | $TRACK_CMD_GET_MTA		=> 	[ 'uuid', ],
	$DIRECTION_SEND | $TRACK_CMD_ERASE			=> 	[ 'uuid', ],
	$DIRECTION_SEND | $TRACK_CMD_RENAME			=> 	[ 'uuid', 'name16' ],
	$DIRECTION_SEND | $TRACK_CMD_START			=> 	[ 'no_seq', ],
	$DIRECTION_SEND | $TRACK_CMD_STOP			=> 	[ 'no_seq', ],
	$DIRECTION_SEND | $TRACK_CMD_DISCARD		=> 	[ 'no_seq', ],
	$DIRECTION_SEND | $TRACK_CMD_GET_DICT		=> 	[],
	$DIRECTION_SEND | $TRACK_CMD_GET_STATE		=> 	[],
    # $DIRECTION_SEND | $TRACK_CMD_USELESS_E	=> 	[],
    # $DIRECTION_SEND | $TRACK_CMD_NOREPLY_F	=> 	[],
	$DIRECTION_SEND | $TRACK_CMD_BUMP_NAME		=> 	[ 'name16', ],
	# $DIRECTION_SEND | $TRACK_CMD_NO_REPLY_11	=>  [],


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
#


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
		pack('v',$cmd | $DIRECTION_SEND).
		pack('v',$TRACK_SERVICE_ID);
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

	if (0)
	{
		my $rec = parseTRACKPacket(0,$request);
		# my $text = "# sendRequest($seq) $name\n";
		# $text .= $rec->{text};
		# # 1=with_text, 0=is_reply		$text .= $rec->{text};
		# setConsoleColor($OUT_COLOR) if $OUT_COLOR;
		# print $text;
		# setConsoleColor() if $OUT_COLOR;
		# writeLog($text,'shark.log');
	}

	display($dbg,0,"sendRequest() calling b_sock::sendPacket()");
	$this->sendPacket($request);
	$this->{wait_seq} = $seq;
	$this->{wait_name} = $name;
	return 1
}



#============================================================
# virtual handleCommand and class specific atoms
#============================================================


sub onConnect
{
	my ($this) = @_;
	$this->trackUICommand('')
		if $this->{auto_populate};
}


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
		return 0 if !$this->sendRequest($seq,"get_state",$request);
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
			return 0 if !$this->sendRequest($seq,"get_cur2",$request);
			$reply = $this->waitReply(1);

			if ($reply)
			{
				my $uuid = $reply->{uuid};
				my $item = $reply->{item};
				my $tracks = $this->{tracks};
				$tracks->{$uuid} = $item;
				$item->{version} = $this->incVersion();
				$this->{current_track_uuid} = $uuid;
			}
		}
	}

	# get the dictionary

	$seq = $this->{next_seqnum}++;
	$request = createMsg($seq,$TRACK_CMD_GET_DICT,0,0);
	return 0 if !$this->sendRequest($seq,"get_dict",$request);
	$reply = $this->waitReply(1);
	return 0 if !$reply;
	
	# enqueue from dictionary

	my $uuids = $reply->{dict_uuids};
	my $num = 0;
	for my $uuid (@$uuids)
	{
		$this->queueTRACKCommand($API_GET_TRACK,$uuid,"get_track($uuid) from dict($num)");
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
		print "--------------------  get_track($uuid) '$extra' ------------------------\n";
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


	# my $uuid = $reply->{uuid};
	my $item = $reply->{item};
	my $tracks = $this->{tracks};
	$tracks->{$uuid} = $item;
	$item->{version} = $this->incVersion();

	warning($dbg_got,0,"got track($uuid) = '$item->{name}'");
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

	# Current or Saved Track commands with {seq} and single parameter

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
			for my $track_uuid (sort keys %$tracks)
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

	# Only command with with two parameters: Rename Saved Track
	# Not that assuming names are unique is not true on E80,
	# but only by convention for me here and in erase above.
	# both will take the first one found by sorted uuid, which
	# is not even sorted correctly as I use hex strings rather
	# than qwords.

	elsif ($rpart =~ /^rename\s+(\S+)\s(\S+)$/)
	{
		my ($old_name, $new_name) = ($1,$2);

		$cmd = $TRACK_CMD_RENAME;

		my $tracks = $this->{tracks};
		for my $track_uuid (sort keys %$tracks)
		{
			my $track = $tracks->{$track_uuid};
			if (lc($track->{name}) eq lc($old_name))
			{
				$uuid = $track_uuid;
				last;
			}
		}

		return error("Could not find track(".lc($old_name).") for rename")
			if !$uuid;

		display($dbg,1,"renaming (".lc($old_name).")=$uuid to '$new_name'");
		$param = pack('H*',name16_hex($new_name));
	}

	# Send the request

	my $request = createMsg($seq,$cmd,$uuid,$param);
	return 0 if !$this->sendRequest($seq,"$rpart",$request);
	my $reply = $expect_reply ? $this->waitReply(1) : 1;
	return 0 if !$reply;

	# the below *may* be obviated by event handling

	if ($returns_current_track)
	{
		my $ct_uuid = $reply->{uuid};
		my $item 	= $reply->{item};
		my $tracks = $this->{tracks};

		warning($dbg_got,0,"got Current Track($ct_uuid) = '$item->{name}'");
	
		$tracks->{$ct_uuid} = $item;
		$item->{version} = $this->incVersion();
		$this->{current_track_uuid} = $ct_uuid;
	}

	return 1;

}	# do_general()




sub handleCommand
{
	my ($this,$command) = @_;
	my $api_command = $command->{api_command};
	my $cmd_name = $API_COMMAND_NAME{$api_command} || 'HUH237?';
	display($dbg,0,"$this->{name} handleCommand($api_command=$cmd_name) started");

	my $rslt;
	$rslt = $this->get_tracks($command) if $api_command == $API_GET_TRACKS;
	$rslt = $this->get_track($command) 	if $api_command == $API_GET_TRACK;
	$rslt = $this->do_general($command) if $api_command == $API_GENERAL_CMD;

	error("API $cmd_name failed") if !$rslt;
	display($dbg,0,"$this->{name} handleCommand($api_command=$cmd_name) finished");
	return 0;
}



#========================================================================
# implemented derived class specific event handler
#========================================================================
# Only called on replies via $parent->handleEvent($packet) from specific
# derived parsePacket() methods

sub handleEvent
	# handles any Events or Mods that the packet might have,
	# returning undef if the packet has been completely handled.
{
	my ($this,$packet) = @_;
	return $packet if (
		!($WITH_EVENT_PROCESSING && $packet->{is_event}) &&
		!($WITH_MOD_PROCESSING   && $packet->{mods}) );

	my $skip_reply = 0;
	if ($packet->{is_event})
	{
		$skip_reply = 1;
		my $mask = $packet->{evt_mask};
		display($dbg_events,0,"handleEvent EVT_MASK($mask)",0,$UTILS_COLOR_LIGHT_MAGENTA);

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
				warning($dbg_events,1,"removing current track($this->{current_track_uuid})");
				delete $this->{tracks}->{$this->{current_track_uuid}};
				$this->{current_track_uuid} = '';
				$this->incVersion();
			}
		}
		if ($mask != 1)
		{
			warning($dbg_events,1,"enquing GET_CUR2");
			$this->queueTRACKCommand($API_GENERAL_CMD,0,'cur2');
		}
	}

	if ($packet->{mods})
	{
		$skip_reply = 1;
		for my $mod (@{$packet->{mods}})
		{
			my $byte = $mod->{byte};
			my $uuid = $mod->{uuid};

			display($dbg_mods,0,"handleEvent TRACK_CHANGED($uuid,$byte)");

			if ($byte == 2)	# delete it
			{
				my $tracks = $this->{tracks};
				my $exists = $tracks->{$uuid};
				if ($exists)
				{
					warning($dbg_mods,1,"deleting tracks($uuid) $exists->{name}");
					delete $tracks->{$uuid};
					$this->incVersion();
				}
			}
			else	# enqueue a GET_TRACK command
			{
				warning($dbg_mods,1,"enquing GET_TRACK($uuid)");
				$this->queueTRACKCommand($API_GET_TRACK,$uuid);
			}
		}	# for each $mod
	}	# {mods} && $WITH_MOD_PROCESSING

	warning(0,0,"handleEvent() returning undef");
	return undef;

}	# handleEvent()


1;