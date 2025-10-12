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
use r_RAYSYS;
use r_utils;
use wp_parse;	# temporary?
use tcpBase;
use base qw(tcpBase);


my $dbg = 0;
my $dbg_parse = 0;


my $WITH_MOD_PROCESSING = 1;


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
		getTracks

		$track_mgr

		$SHOW_TRACK_PARSED_INPUT
		$SHOW_TRACK_PARSED_OUTPUT

	);
}

our $track_mgr:shared;


#-----------------------------
# API commands
#-----------------------------

our $API_NONE 		= 0;
our $API_GET_TRACKS	= 1;
our $API_GET_TRACK	= 2;

my %API_COMMAND_NAME = (
	$API_GET_TRACKS	 => 'GET_TRACKS',
	$API_GET_TRACK	 => 'GET_TRACK', );


#----------------------------------
# TRACK PROTOCOL
#-----------------------------------
# Direction Nibble

our $TRACK_DIR_RECV		= 0x000;
our $TRACK_DIR_SEND		= 0x100;
our $TRACK_DIR_INFO		= 0x200;

# Command Niblle
# E80 closes TCP connection on 0x12 and higher
									# request
my $TRACK_CMD_CONTEXT   = 0x00;		# GET {seq} {nth} Current Track Point
my $TRACK_CMD_BUFFER	= 0x01;		# NAME {seq} {hex16} Current Track
my $TRACK_CMD_END		= 0x02;		# GET_CUR2 CurrentTrack MTA and points
my $TRACK_CMD_CURRENT   = 0x03;		# GET_CUR Current Track MTA
my $TRACK_CMD_TRACK		= 0x04;		# SAVE
my $TRACK_CMD_GET_TRACK = 0x05;		# GET TRACK {seq} {uuid} by uuid - funky results with Current Track uuid
my $TRACK_CMD_DICT		= 0x07;		# ERASE TRACK {seq} {uuid} - only for saved tracks
my $TRACK_CMD_8			= 0x08; 	# 0801 {func} {seq} 000000000 - appears to do a core dump of some part of the program
my $TRACK_CMD_START		= 0x09;		# START	starts Current Track tracking
my $TRACK_CMD_EVENT		= 0x0a;		# STOP stops Current Track
	# received events with bits,
	# 1,3 = started
	# 0   = point added
	# 0,2 = renamed
my $TRACK_CMD_CHANGED   = 0x0b;		# DISCARD current track, but only after stop and not saved
	# events uith uuid and change bits
my $TRACK_CMD_GET_MTAS	= 0x0c;		# GET DICTIONARY {seq_num} - gets index of saved tracks uuids
my $TRACK_CMD_D			= 0x0d;		# STOPPABLE - returns 1 if the stop button is enabled via CMD_8
my $TRACK_CMD_E			= 0x0e;		# returns an event with byte=6, no useful function I can see
my $TRACK_CMD_F			= 0x0f;		# never got a return
my $TRACK_CMD_BUMP_NAME = 0x10;		# BUMP the next track name, talk about useless
my $TRACK_CMD_11		= 0x11;		# never got a return


my %TRACK_COMMAND_NAME = (
	$TRACK_CMD_CONTEXT		=> 'CONTEXT',
	$TRACK_CMD_BUFFER		=> 'BUFFER',
	$TRACK_CMD_END			=> 'END',
	$TRACK_CMD_CURRENT		=> 'CURRENT',
	$TRACK_CMD_TRACK		=> 'TRACK',
	$TRACK_CMD_GET_TRACK 	=> 'GET_TRACK',
	$TRACK_CMD_DICT			=> 'DICT',
	$TRACK_CMD_8			=> 'CMD_8',
	$TRACK_CMD_START		=> 'START',
	$TRACK_CMD_EVENT		=> 'EVENT',
	$TRACK_CMD_CHANGED		=> 'CHANGED',
	$TRACK_CMD_GET_MTAS		=> 'GET_MTAS',
	$TRACK_CMD_D	        => 'CMD_D',
    $TRACK_CMD_E	        => 'CMD_E',
    $TRACK_CMD_F	        => 'CMD_F',
	$TRACK_CMD_BUMP_NAME	=> 'BUMP_NAME',
	$TRACK_CMD_11			=> 'CMD_11',
);


#----------------------------------------------------------------------
# Packet Parser
#----------------------------------------------------------------------

my %PARSE_RULES = (

	# currently only what is needed to parse replies

	$TRACK_DIR_RECV 	| $TRACK_CMD_DICT 		=>	[ 'success', 'is_dict'],		# header for dictionary replies
	$TRACK_DIR_RECV 	| $TRACK_CMD_TRACK 		=>	[ 'success' ],					# header for track replies
	$TRACK_DIR_RECV 	| $TRACK_CMD_END 		=>	[ 'success' ],					# header for get 'full' current track
	$TRACK_DIR_RECV 	| $TRACK_CMD_BUFFER 	=>	[ 'success' ],					# header for get 'mta' current track
	$TRACK_DIR_RECV 	| $TRACK_CMD_CONTEXT 	=>	[ 'success', 'is_point' ],		# header for get nth track point
	$TRACK_DIR_RECV		| $TRACK_CMD_D			=>  [ 'success' ],					# confirms name change (in an event packet) with sequence number
	$TRACK_DIR_RECV		| $TRACK_CMD_8			=>  [ 'no_seq','junk','stopable',],	# reply to 0xd Tracking state inquiry
	$TRACK_DIR_RECV		| $TRACK_CMD_CURRENT	=>  [ 'success' ],					# reply to 0x04=SAVE

	
	$TRACK_DIR_INFO		| $TRACK_CMD_CONTEXT   	=>	[ 'uuid','context_bits' ],		# uuid context for the reply; bits 01n
	$TRACK_DIR_INFO		| $TRACK_CMD_BUFFER		=> 	[ 'buffer' ],					# dictionary, MTA, or Track depending on state
	$TRACK_DIR_INFO		| $TRACK_CMD_END		=> 	[ 'track_uuid' ],				# actually carries mta_uuid, but sets is_track=1

	# events

	$TRACK_DIR_RECV		| $TRACK_CMD_CHANGED	=> 	[ 'no_seq', 'uuid','byte' ],
	$TRACK_DIR_RECV		| $TRACK_CMD_EVENT		=> 	[ 'no_seq', 'byte' ],

);

# GET_MTAS results in
#	recv	DICT		success
#	info	CONTEXT		uuid(0000)		context bits 0x19
#	info	BUFFER		<dict>
#	info	END			uuid(0000)
#
# GET_TRACK results in
#
#	recv	TRACK 		success
#	info	CONTEXT		mta_uuid 		context_bits 0x12
#	info	BUFFER		<mta>
#	info	END			'track_uuid'							actualy mta_uuid, but we set is_track based on the rule
#	info 	CONTEXT		other_uuid		context_bits 0x11
#	info	BUFFER		<trk>


sub parseTRACK
{
	my ($buffer) = @_;
	my $offset = 0;
	my $pack_len = length($buffer);
	display($dbg_parse,0,"parseTRACK pack_len($pack_len)");

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

		my $cmd_name = $TRACK_COMMAND_NAME{$cmd} || 'WHO CARES';
		display($dbg_parse,1,"parsePart($num) offset($offset) len($len) dir($dir_hex) cmd($cmd)=$cmd_name part="._lim(unpack('H*',$part),200));
		$offset += 4;
		$num++;

		# get the rule
		my $rule = $PARSE_RULES{ $cmd_word };
		if (!$rule)
		{
			error("NO RULE");
			next;
		}

		if ($$rule[0] ne 'no_seq')
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

		if ($cmd == $TRACK_CMD_EVENT)
		{
			$rec->{is_event} = 1;
			$rec->{evt_mask} |= $rec->{byte};
		}
		elsif ($cmd == $TRACK_CMD_CHANGED)
		{
			$rec->{is_event} = 1;
			$rec->{mods} ||= shared_clone([]);
			push @{$rec->{mods}},shared_clone({
				uuid=>$rec->{uuid},
				byte=>$rec->{byte} });
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

			warning(0,0,"msg_len($msg_len) big_len($big_hex)=$big_len");
			error("NOT PLUS 12") if $big_len + 12 != $msg_len;
			
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




#--------------------------
# ctor
#--------------------------


sub startTRACK
{
	my ($class) = @_;
	display($dbg,0,"startTRACK($class)");
	my $this = $class->SUPER::new({
		rayname => 'TRACK',
		local_port => $TRACK_PORT,
		show_input  => $DEFAULT_TRACK_TCP_INPUT,
		show_output => $DEFAULT_TRACK_TCP_OUTPUT,
		in_color	=> $UTILS_COLOR_BROWN,
		out_color   => $UTILS_COLOR_LIGHT_CYAN, });

	$this->{tracks} = shared_clone({});
	$track_mgr = $this;
	$this->start();
}


#--------------------------------------
# API
#--------------------------------------

sub apiCommandName
{
	my ($cmd) = @_;
	return 'GET_TRACKS'	if $cmd == $API_GET_TRACKS;
	return 'GET_TRACK'	if $cmd == $API_GET_TRACK;
	return "UNKNOWN API COMMAND";
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
	navQueryLog($msg,'shark.log');
}



sub getTracks
{
	showCommand("getTracks()");
	return queueTRACKCommand($track_mgr,$API_GET_TRACKS,0);
}


sub queueTRACKCommand
{
	my ($this,$api_command,$uuid,$extra) = @_;
	display_hash($dbg+2,0,"queueTRACKCommand($this)",$this);

	return error("No 'this' in queueTRACKCommand") if !$this;
	return error("Not started") if !$this->{started};
	return error("Not running") if !$this->{running};

	my $cmd_name = apiCommandName($api_command);

	if ($SHOW_TRACK_PARSED_OUTPUT)
	{
		my $msg = "# queueTRACKCommand($api_command=$cmd_name) uuid($uuid)\n";
		print $msg;
		navQueryLog($msg,"shark.log");
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
		name => $API_COMMAND_NAME{$api_command},
		uuid => $uuid,
		extra => $extra });
	push @{$this->{command_queue}},$command;
	return 1;
}



#-------------------------------------------------
# utilities
#-------------------------------------------------



sub createMsg
{
	my ($seq,$cmd,$uuid) = @_;
	my $cmd_name = $TRACK_COMMAND_NAME{$cmd} || 'HUH?';
	display($dbg,0,"createMsg($seq,$cmd,$uuid) $cmd_name");
	my $data =
		pack('v',$cmd | $TRACK_DIR_SEND).
		pack('v',$TRACK_FUNC).
		pack('V',$seq);
	$data .= pack('H*',$uuid) if $uuid;
	my $len = length($data);
	my $packet = pack('v',$len).$data;
	display($dbg,1,"msg=".unpack('H*',$packet));
	return $packet;
}



sub sendRequest
{
	my ($this,$seq,$name,$request) = @_;

	#	if ($SHOW_TRACK_PARSED_OUTPUT)
	#	{
	#		my $text = "# sendRequest($seq) $name\n";
	#		my $rec = parseTRACK($SHOW_TRACK_PARSED_OUTPUT,0,$TRACK_PORT,$request);
	#		$text .= $rec->{text};
	#		# 1=with_text, 0=is_reply		$text .= $rec->{text};
	#		setConsoleColor($out_color) if $out_color;
	#		print $text;
	#		setConsoleColor() if $out_color;
	#		navQueryLog($text,'shark.log');
	#	}

	$this->sendPacket($request);
	$this->{wait_seq} = $seq;
	$this->{wait_name} = $name;
	return 1
}







#============================================================
# commandThread atoms
#============================================================


sub get_tracks
	# get all track_mts uuids, then all tracks
{
	my ($this) = @_;
	print "get_tracks()\n";

	my $seq;
	my $request;
	my $reply;

	if (1)
	{
		# get the current track works better with 0201 {func}{seq}
		# however, this at least fails when the track is not recording

		$seq = $this->{next_seqnum}++;
		$request = createMsg($seq,$TRACK_CMD_END,0);
		return 0 if !$this->sendRequest($seq,"CURRENT TRACK",$request);
		$reply = $this->waitReply(1);
		
		if ($reply)
		{
			my $uuid = $reply->{uuid};
			my $tracks = $this->{tracks};
			$tracks->{$uuid} = $reply;
			$reply->{version} = $this->incVersion();
		}
	}

	# get the dictionary

	$seq = $this->{next_seqnum}++;
	$request = createMsg($seq,$TRACK_CMD_GET_MTAS,0);
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

}


sub get_track
{
	my ($this,$command) = @_;
	my $uuid = $command->{uuid};
	my $extra = $command->{extra} || '';

	if (1)
	{
		sleep(1);
		print "--------------------  $extra $uuid -----------------------------\n";
	}
	
	display($dbg,0,"get_track($uuid)");

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$TRACK_CMD_GET_TRACK,$uuid);
	return 0 if !$this->sendRequest($seq,"get_track($uuid)",$request);

	if (1)
	{
		sleep(1);
		print "-----------------------------------------------------------------\n";
	}

	my $reply = $this->waitReply(1);
	return 0 if !$reply;

	my $dbg_got = 0;
	warning($dbg_got,0,"got track($uuid) = '$reply->{name}'");

	my $tracks = $this->{tracks};
	$tracks->{$uuid} = $reply;
	$reply->{version} = $this->incVersion();
	return 1;
}                                 






sub handleCommand
{
	my ($this,$command) = @_;
	my $api_command = $command->{api_command};
	my $cmd_name = apiCommandName($api_command);
	display($dbg,0,"$this->{rayname} handleCommand($api_command=$cmd_name) started");

	my $rslt;
	$rslt = $this->get_tracks($command) if $api_command == $API_GET_TRACKS;
	$rslt = $this->get_track($command) 	if $api_command == $API_GET_TRACK;

	error("API $cmd_name failed") if !$rslt;
	display($dbg,0,"$this->{rayname} handleCommand($api_command=$cmd_name) finished");
}




#========================================================================
# overriden tcpBase methods
#========================================================================


sub handlePacket
{
	my ($this,$buffer) = @_;

	warning($dbg+1,0,"handlePacket(".length($buffer).") called");

	my $reply = parseTRACK($buffer);
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

	if ($reply->{is_event})
	{
		# evt_mask
		#	start track 		= 1 , 3
		#	discard 			= 2 , 1
		#	save track 			= 2 , 4 , 1
		#	new track point 	= 0
		#	cur track mod   	= 6
		#   cur track discarded = 5

		if ($reply->{mods} && $WITH_MOD_PROCESSING)
		{
			for my $mod (@{$reply->{mods}})
			{
				my $byte = $mod->{byte};
				my $uuid = $mod->{uuid};

				display($dbg,1,"TRACK_CHANGED($uuid,$byte)");

				if ($byte == 2)	# delete it
				{
					my $tracks = $this->{tracks};
					my $exists = $tracks->{$uuid};
					if ($exists)
					{
						warning($dbg,2,"deleting tracks($uuid) $exists->{name}");
						delete $tracks->{$uuid};
						$this->incVersion();
					}
				}
				else	# enqueue a GET_TRACK command
				{
					warning($dbg,2,"enquing GET_TRACK($uuid)");
					$this->queueTRACKCommand($API_GET_TRACK,$uuid);
				}
			}	# $mods
		}	# $WITH_MOD_PROCESSING

		$reply = undef;	# event handled

	}	# is_event

	return $reply;

}





1;