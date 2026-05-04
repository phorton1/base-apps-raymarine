#---------------------------------------
# d_TRACK.pm
#---------------------------------------
# Client for RAYDP func(19) == 0x13 == '1300'
#
# Get or erase saved Tracks from E80, and can start,
# stop, save, discard, and rename the 'Current Track'.
#
# Cannot create or modify Tracks otherwise.
# Cannot even set the color of the 'Current Track'

package apps::raymarine::NET::d_TRACK;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use apps::raymarine::NET::a_utils;
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::b_records;	# temporary name
# use c_RAYDP  loaded by shark.pm
use base qw(apps::raymarine::NET::b_sock);


my $dbg 		= 1;
my $dbg_got 	= 0;		# for returned tracks (including Current Track)
my $dbg_events 	= -1;
my $dbg_mods 	= -1;


my $WITH_EVENT_PROCESSING	= 1;
my $WITH_MOD_PROCESSING 	= 1;

our $query_in_progress :shared = 0;


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

our $API_NONE 				= 0;
our $API_GET_TRACKS			= 1;
our $API_GET_TRACK			= 2;
our $API_GENERAL_CMD_NAME	= 3;
our $API_GENERAL_CMD		= 4;

my %API_COMMAND_NAME = (
	$API_GET_TRACKS		   => 'GET_TRACKS',
	$API_GET_TRACK		   => 'GET_TRACK',
	$API_GENERAL_CMD_NAME  => 'GENERAL_COMMAND_NAME',
	$API_GENERAL_CMD       => 'GENERAL_COMMAND' );





sub showCommand
{
	my ($this,$msg) = @_;
	return if !$this->{show_parsed_output};
	$msg = "\n\n".
		"#------------------------------------------------------------------\n".
		"# $msg\n".
		"#------------------------------------------------------------------\n\n";
	c_print($msg);
	# writeLog($msg,'shark.log');
}



sub trackUICommand
{
	my ($this,$rpart) = @_;
	$this->showCommand("trackUICommand($rpart)");
	return $rpart ?
		queueTRACKCommand($this,$API_GENERAL_CMD_NAME,0,$rpart) :
		queueTRACKCommand($this,$API_GET_TRACKS,0);
}


sub queueTRACKCommand
{
	my ($this,$api_command,$uuid,$extra,$gen_error,$progress) = @_;
	$uuid ||= '';
	$extra ||= '';
	$gen_error ||= '';

	display_hash($dbg+2,0,"queueTRACKCommand($this)",$this);

	return error("No 'this' in queueTRACKCommand") if !$this;
	return error("Not started") if !$this->{started};
	return error("Not running") if !$this->{running};

	my $cmd_name = $API_COMMAND_NAME{$api_command} || 'HUH235?';

	if (1)
	{
		my $msg = "# queueTRACKCommand($api_command=$cmd_name) uuid($uuid) extra($extra) gen_error($gen_error)\n";
		c_print($msg);
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
		extra => $extra,
		gen_error => $gen_error, });
	$command->{progress} = $progress if $progress;
	push @{$this->{command_queue}},$command;
	return 1;
}


sub queueRefresh
{
	my ($this, $progress) = @_;
	return $this->queueTRACKCommand($API_GET_TRACKS, 0, '', '', $progress);
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

	# Replies — simple single-reply commands are terminal=1; multi-message headers are terminal=0

	$DIRECTION_RECV | $TRACK_REPLY_CONTEXT  => { pieces => ['seq','success','is_point'], terminal => 0 },  # header: INFO_BUFFER follows
	$DIRECTION_RECV | $TRACK_REPLY_BUFFER   => { pieces => ['seq','success'],            terminal => 0 },  # header: GET_CUR MTA; INFO_BUFFER follows
	$DIRECTION_RECV | $TRACK_REPLY_END      => { pieces => ['seq','success'],            terminal => 0 },  # header: GET_CUR2 full; INFO_BUFFER+END follow
	$DIRECTION_RECV | $TRACK_REPLY_CURRENT  => { pieces => ['seq','success'],            terminal => 1 },  # SAVE reply
	$DIRECTION_RECV | $TRACK_REPLY_TRACK    => { pieces => ['seq','success'],            terminal => 0 },  # header: GET_TRACK; INFO messages follow
	$DIRECTION_RECV | $TRACK_REPLY_MTA      => { pieces => ['seq','success'],            terminal => 0 },  # header: GET_MTA; INFO_BUFFER follows
	$DIRECTION_RECV | $TRACK_REPLY_ERASED   => { pieces => ['seq','success'],            terminal => 1 },  # ERASE reply
	$DIRECTION_RECV | $TRACK_REPLY_DICT     => { pieces => ['seq','success','is_dict'],  terminal => 0 },  # header: GET_DICT; INFO_BUFFER+END follow
	$DIRECTION_RECV | $TRACK_REPLY_STATE    => { pieces => ['seq','stopable'],           terminal => 1 },  # GET_STATE reply
	$DIRECTION_RECV | $TRACK_REPLY_NAMED    => { pieces => ['seq','success'],            terminal => 1 },  # SET_NAME reply
	$DIRECTION_RECV | $TRACK_REPLY_RENAMED  => { pieces => ['seq','success'],            terminal => 1 },  # RENAME reply

	# Events — unsolicited, no seq_num

	$DIRECTION_RECV | $TRACK_REPLY_CHANGED  => { pieces => ['uuid','byte'],              terminal => 1, is_event => 1 },
	$DIRECTION_RECV | $TRACK_REPLY_EVENT    => { pieces => ['byte'],                     terminal => 1, is_event => 1 },

	# INFO messages — terminal handled dynamically via buffer_complete flag in parsePiece

	$DIRECTION_INFO | $TRACK_REPLY_CONTEXT  => { pieces => ['seq','uuid','context_bits'], terminal => 0 },
	$DIRECTION_INFO | $TRACK_REPLY_BUFFER   => { pieces => ['seq','buffer'],              terminal => 0 },  # buffer_complete set by parsePiece
	$DIRECTION_INFO | $TRACK_REPLY_END      => { pieces => ['seq','track_uuid'],          terminal => 0 },  # buffer_complete set by parsePiece for dict
	$DIRECTION_INFO | $TRACK_REPLY_RENAMED  => { pieces => ['seq','success'],             terminal => 0 },

	# Requests — terminal=0 (monitored by dispatchTCPSendMsg, never returned as reply)

	$DIRECTION_SEND | $TRACK_CMD_GET_NTH    => { pieces => ['seq','point_number'], terminal => 0 },
	$DIRECTION_SEND | $TRACK_CMD_SET_NAME   => { pieces => ['seq','name16'],       terminal => 0 },
	$DIRECTION_SEND | $TRACK_CMD_GET_CUR2   => { pieces => ['seq'],                terminal => 0 },
	$DIRECTION_SEND | $TRACK_CMD_GET_CUR    => { pieces => ['seq'],                terminal => 0 },
	$DIRECTION_SEND | $TRACK_CMD_SAVE       => { pieces => [],                     terminal => 0 },
	$DIRECTION_SEND | $TRACK_CMD_GET_TRACK  => { pieces => ['seq','uuid'],         terminal => 0 },
	$DIRECTION_SEND | $TRACK_CMD_GET_MTA    => { pieces => ['seq','uuid'],         terminal => 0 },
	$DIRECTION_SEND | $TRACK_CMD_ERASE      => { pieces => ['seq','uuid'],         terminal => 0 },
	$DIRECTION_SEND | $TRACK_CMD_RENAME     => { pieces => ['seq','uuid','name16'],terminal => 0 },
	$DIRECTION_SEND | $TRACK_CMD_START      => { pieces => [],                     terminal => 0 },
	$DIRECTION_SEND | $TRACK_CMD_STOP       => { pieces => [],                     terminal => 0 },
	$DIRECTION_SEND | $TRACK_CMD_DISCARD    => { pieces => [],                     terminal => 0 },
	$DIRECTION_SEND | $TRACK_CMD_GET_DICT   => { pieces => ['seq'],                terminal => 0 },
	$DIRECTION_SEND | $TRACK_CMD_GET_STATE  => { pieces => ['seq'],                terminal => 0 },
	$DIRECTION_SEND | $TRACK_CMD_BUMP_NAME  => { pieces => ['seq','name16'],       terminal => 0 },

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
	display($dbg+1,0,"sendRequest() calling apps::raymarine::NET::b_sock::sendPacket()");
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
	# get all track_mts uuids, then all tracks.
	# Clears in-memory state first so stale items (deleted on E80) don't persist.
{
	my ($this, $command) = @_;
	c_print("get_tracks()\n");

	$this->{tracks}              = shared_clone({});
	$this->{current_track_uuid}  = '';

	my $progress = (ref($command) eq 'HASH') ? $command->{progress} : undef;
	$this->{_active_progress} = $progress;

	$query_in_progress++;

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
		if (!$this->sendRequest($seq,"get_state",$request))
		{
			$this->{_active_progress} = undef;
			if ($progress && exists $progress->{workers}) { $progress->{workers}--; }
			$query_in_progress--;
			return 0;
		}
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
			if (!$this->sendRequest($seq,"get_cur2",$request))
			{
				$this->{_active_progress} = undef;
				if ($progress && exists $progress->{workers}) { $progress->{workers}--; }
				$query_in_progress--;
				return 0;
			}
			$reply = $this->waitReply(1);

			if ($reply)
			{
				my $mta_uuid = $reply->{mta_uuid};
				my $item = $reply->{item};
				my $tracks = $this->{tracks};
				$tracks->{$mta_uuid} = $item;
				$item->{version} = $this->incVersion();
				$this->{current_track_uuid} = $mta_uuid;
					# only time that d_TRACK uses the uuid from the parsed record
					# is for the current track.  Otherwise it 'knows' what uuid it
					# is dealing with (from the dictionary)

				warning($dbg_got,0,"got Current Track($mta_uuid) = '$item->{name}'");
			}
		}
	}

	# get the dictionary

	$seq = $this->{next_seqnum}++;
	$request = createMsg($seq,$TRACK_CMD_GET_DICT,0,0);
	if (!$this->sendRequest($seq,"get_dict",$request))
	{
		$this->{_active_progress} = undef;
		if ($progress && exists $progress->{workers}) { $progress->{workers}--; }
		$query_in_progress--;
		return 0;
	}
	$reply = $this->waitReply(1);
	if (!$reply)
	{
		$this->{_active_progress} = undef;
		if ($progress && exists $progress->{workers}) { $progress->{workers}--; }
		$query_in_progress--;
		return 0;
	}

	# enqueue from dictionary; add one count per queued get_track so the
	# flag stays non-zero until the last track is received

	my $uuids = $reply->{dict_uuids};
	$query_in_progress += scalar(@$uuids);
	if ($progress)
	{
		$progress->{total} += scalar(@$uuids);
		$progress->{done}++;
	}

	my $num = 0;
	for my $uuid (@$uuids)
	{
		$this->queueTRACKCommand($API_GET_TRACK,$uuid,"get_track($uuid) from dict($num)");	# ,$num==3);
			# dont call waitReply on $num==3 to test out of band handling in bsock
		$num++;
	}

	my $tracks = $this->{tracks};
	display($dbg+1,1,"keys(tracks) = ".join(" ",keys %$tracks));
	$query_in_progress--;	# get_tracks itself done; N get_track calls still pending

	# If no saved tracks at all, close out progress here (get_track won't run)
	if (!@$uuids && $progress && exists $progress->{workers})
	{
		$progress->{workers}--;
		$this->{_active_progress} = undef;
	}

	return 1;

}	# get_tracks()



sub get_track
{
	my ($this,$command) = @_;
	my $uuid = $command->{uuid};
	my $extra = $command->{extra} || '';

	if (1 && $dbg <= 0)
	{
		c_print("--------------------  get_track($uuid) '$extra' ------------------------\n");
	}
	
	display($dbg,0,"get_track($uuid)");

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$TRACK_CMD_GET_TRACK,$uuid,0);
	return 0 if !$this->sendRequest($seq,"get_track($uuid)",$request);

	if (1 && $dbg <= 0)
	{
		c_print("-----------------------------------------------------------------\n");
	}

	return 1 if $command->{gen_error};
		# test out of band bsock message handling
	
	my $reply = $this->waitReply(1);
	return 0 if !$reply;

	# NOTE that we KNOW the uuid of the item we are getting

	my $item = $reply->{item};
	my $tracks = $this->{tracks};
	$tracks->{$uuid} = $item;
	$item->{version} = $this->incVersion();

	warning($dbg_got,0,"got track($uuid) = '$item->{name}'");
	$query_in_progress-- if $query_in_progress > 0;

	my $progress = $this->{_active_progress};
	if ($progress)
	{
		$progress->{label} = $item->{name} // '';
		$progress->{done}++;
		if ($query_in_progress == 0)
		{
			$progress->{workers}-- if exists $progress->{workers};
			$this->{_active_progress} = undef;
		}
	}

	return 1;

}   # get_track()



sub do_general_name
{
	my ($this,$command) = @_;
	my $rpart = $command->{extra} || '';
	display($dbg,0,"do_general_name($rpart)");

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

	elsif ($rpart eq 'dict')
	{
		return $this->get_tracks($command);
	}

	else
	{
		return error("do_general_name: unrecognized command '$rpart'");
	}

	# Send the request

	my $request = createMsg($seq,$cmd,$uuid,$param);
	return 0 if !$this->sendRequest($seq,"$rpart",$request);
	my $reply = $expect_reply ? $this->waitReply(1) : 1;
	return 0 if !$reply;

	# the below *may* be obviated by event handling

	if ($returns_current_track)
	{
		my $mta_uuid = $reply->{mta_uuid};
		my $item 	= $reply->{item};
		my $tracks = $this->{tracks};

		warning($dbg_got,0,"received Current Track($mta_uuid) = '$item->{name}'");
	
		$tracks->{$mta_uuid} = $item;
		$item->{version} = $this->incVersion();
		$this->{current_track_uuid} = $mta_uuid;
	}

	return 1;

}	# do_general_name()


sub do_general
	# UUID-based general commands.  $command->{uuid} is the target track.
	# $command->{extra} is the operation: 'erase', 'mta', 'rename <new_name>'.
{
	my ($this,$command) = @_;
	my $uuid  = $command->{uuid} || '';
	my $rpart = $command->{extra} || '';
	display($dbg,0,"do_general(uuid=$uuid rpart=$rpart)");

	return error("do_general: no uuid") if !$uuid;

	my $seq   = $this->{next_seqnum}++;
	my $cmd;
	my $param         = 0;
	my $expect_reply  = 0;

	if ($rpart eq 'erase')
	{
		$cmd = $TRACK_CMD_ERASE;
	}
	elsif ($rpart eq 'mta')
	{
		$cmd = $TRACK_CMD_GET_MTA;
		$expect_reply = 1;
	}
	elsif ($rpart =~ /^rename\s+(.+)$/)
	{
		$cmd   = $TRACK_CMD_RENAME;
		$param = pack('H*',name16_hex($1));
	}
	else
	{
		return error("do_general: unrecognized command '$rpart'");
	}

	my $request = createMsg($seq,$cmd,$uuid,$param);
	return 0 if !$this->sendRequest($seq,"do_general/$rpart",$request);
	return $expect_reply ? $this->waitReply(1) : 1;

}	# do_general()


sub handleCommand
{
	my ($this,$command) = @_;
	my $api_command = $command->{api_command};
	my $cmd_name = $API_COMMAND_NAME{$api_command} || 'HUH237?';
	display($dbg,0,"$this->{name} handleCommand($api_command=$cmd_name) started");

	my $rslt;
	$rslt = $this->get_tracks($command)    if $api_command == $API_GET_TRACKS;
	$rslt = $this->get_track($command)     if $api_command == $API_GET_TRACK;
	$rslt = $this->do_general_name($command) if $api_command == $API_GENERAL_CMD_NAME;
	$rslt = $this->do_general($command)    if $api_command == $API_GENERAL_CMD;

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
			$this->queueTRACKCommand($API_GENERAL_CMD_NAME,0,'cur2');
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