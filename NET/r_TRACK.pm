#---------------------------------------
#	r_TRACK.pm
#---------------------------------------
# tracks are stored as their MTA uuids

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

my $WITH_MOD_PROCESSING = 0;


my $COMMAND_TIMEOUT 		= 3;


our $DEFAULT_TRACK_TCP_INPUT:shared 	= 1;
our $DEFAULT_TRACK_TCP_OUTPUT:shared 	= 1;
our $SHOW_TRACK_PARSED_INPUT:shared 	= 1;
our $SHOW_TRACK_PARSED_OUTPUT:shared 	= 1;


my $DBG_WAIT = 1;

# my $SUCCESS_SIG = '00000400';
# my $DICT_END_RECORD_MARKER	= '10000202';

our $API_NONE 		= 0;
our $API_GET_TRACKS	= 1;
our $API_GET_TRACK	= 2;

my $out_color = $UTILS_COLOR_LIGHT_CYAN;
my $in_color = $UTILS_COLOR_LIGHT_BLUE;

our $track_mgr:shared;

my $TRACK_PORT 		= 12002;
my $TRACK_FUNC		= 0x0013;	# 19
	# 13 = 0x13 == '1300' in streams

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




my $TRACK_DIR_INFO 		= 0x000;
my $TRACK_DIR_SEND 		= 0x100;
my $TRACK_DIR_REPLY 	= 0x200;



# commands

my $TRACK_CMD_CONTEXT   = 0x00;
my $TRACK_CMD_BUFFER	= 0x01;
my $TRACK_CMD_END		= 0x02;		# LIST
my $TRACK_CMD_TRACK		= 0x04;		# EXIST
my $TRACK_CMD_GET_TRACK = 0x05;		# :-( EVENT
my $TRACK_CMD_DICT		= 0x07;		# MODIFY?!?
my $TRACK_CMD_GET_MTAS	= 0x0c;		# FIND
# my $TRACK_CMD_MTA		= 0x45;

# from WPMGR
#	our $CMD_CONTEXT	= 0x0;
#	our $CMD_BUFFER    	= 0x1;
#	our $CMD_LIST     	= 0x2;
#	our $CMD_ITEM		= 0x3;
#	our $CMD_EXIST		= 0x4;
#	our $CMD_EVENT     	= 0x5;
#	our $CMD_DATA		= 0x6;
#	our $CMD_MODIFY    	= 0x7;
#	our $CMD_UUID    	= 0x8;
#	our $CMD_NUMBER     = 0x9;
#	our $CMD_AVERB     	= 0xa;
#	our $CMD_BVERB     	= 0xb;
#	our $CMD_FIND		= 0xc;
#	our $CMD_COUNT     	= 0xd;
#	our $CMD_EVERB    	= 0xe;
#	our $CMD_FVERB     	= 0xf;

# replies

my %TRACK_COMMAND_NAME = (
	$TRACK_CMD_CONTEXT		=> 'CONTEXT',
	$TRACK_CMD_BUFFER			=> 'DATA',
	$TRACK_CMD_END			=> 'END',
	$TRACK_CMD_TRACK		=> 'TRACK',
	$TRACK_CMD_GET_TRACK 	=> 'GET_TRACK',
	$TRACK_CMD_DICT			=> 'DICT',
	$TRACK_CMD_GET_MTAS		=> 'GET_MTAS',
);


my %PARSE_RULES = (

	$TRACK_DIR_INFO 	| $TRACK_CMD_DICT 		=>	[ 'success' ],					# header for dictionary replies
	$TRACK_DIR_REPLY	| $TRACK_CMD_CONTEXT   	=>	[ 'uuid','context_bits' ],		# uuid context for the reply; bits 01n determines dictionary
	$TRACK_DIR_REPLY	| $TRACK_CMD_BUFFER		=> 	[ 'buffer' ],					# either a track, or a dict, based on context_bits
	$TRACK_DIR_REPLY	| $TRACK_CMD_END		=> 	[ 'track_uuid' ],

	$TRACK_DIR_INFO 	| $TRACK_CMD_TRACK 		=>	[ 'success' ],					# header for track replies
	$TRACK_DIR_SEND		| $TRACK_CMD_END		=> 	[ 'uuid' ],						# repeats the mta uuid with no bits

);




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
	my $rec = shared_clone({is_dict=>0});
	for my $part (@parts)
	{
		my $offset = 0;
		my $len = length($part);
		my ($cmd_word,$func,$seq) = unpack('vvV',substr($part,$offset,10));
		my $cmd = $cmd_word & 0xff;
		my $dir = $cmd_word & 0xff00;
		my $dir_hex = sprintf("%0x",$dir);
		
		my $cmd_name = $TRACK_COMMAND_NAME{$cmd} || 'WHO CARES';
		display($dbg_parse,1,"parsePart($num) offset($offset) len($len) dir($dir_hex) cmd($cmd)=$cmd_name seq($seq) part="._lim(unpack('H*',$part),40));
		$offset += 8;
		$num++;

		$rec->{seq_num} ||= $seq;

		my $rule = $PARSE_RULES{ $cmd_word };
		if (!$rule)
		{
			error("NO RULE");
			next;
		}
		
		for my $piece (@$rule)
		{
			parsePiece(
				$rec,
				$piece,
				$part,
				\$offset );	# indent buffer records a bit
		}
	}

	display_hash($dbg_parse+1,1,"parseTRACK returning",$rec);
	return $rec;
}




sub parsePiece
{
	my ($rec,$piece,$part,$poffset) = @_;

	my $text = '';

	if ($piece eq 'buffer')
	{
		display($dbg_parse,1,"piece(buffer) is_dict($rec->{is_dict}) is_track="._def($rec->{is_track}));
		if (!$rec->{is_dict})
		{
			# skip biglen
			my $buffer = substr($part,$$poffset+4);
			mergeHash($rec,parseTrack($buffer)) if $rec->{is_track};
			mergeHash($rec,parseMTA($buffer)) if !$rec->{is_track};
		}
		else	# if ($context->{is_reply})
		{
			$$poffset += 4;	# skip biglen
			my $num = unpack('V',substr($part,$$poffset,4));
			$$poffset += 4;

			display($dbg_parse,1,"piece(buffer) is_dict found $num uuids");
			my $uuids = $rec->{uuids};
			for (my $i=0; $i<$num; $i++)
			{
				my $uuid = unpack('H*',substr($part,$$poffset,8));
				$$poffset += 8;
				push @$uuids,$uuid;
				display($dbg_parse,2,"uuid($i)=$uuid");
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
	else
	{
		my $str = substr($part,$$poffset,4);
		my $value = unpack('V',$str);
		$$poffset += 4;

		display($dbg_parse,1,"rec($piece) = '$value'");
				
		$rec->{$piece} = $value;

		if ($piece eq 'context_bits')
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
	my ($this,$api_command,$uuid) = @_;
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
		uuid => $uuid,});
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

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$TRACK_CMD_GET_MTAS,0);
	return 0 if !$this->sendRequest($seq,"TRACKS DICT",$request);
	my $reply = $this->waitReply(1);
	return 0 if !$reply;

	my $uuids = $reply->{uuids};

	my $num = 0;
	for my $uuid (@$uuids)
	{
		$this->queueTRACKCommand($API_GET_TRACK,$uuid);
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
	display($dbg,0,"get_track($uuid)");

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$TRACK_CMD_GET_TRACK,$uuid);
	return 0 if !$this->sendRequest($seq,"get_track($uuid)",$request);
	my $reply = $this->waitReply(1);
	return 0 if !$reply;

	#	my $track = $reply->{track};
	#	return error("No {track} in get)track reply") if !$track;
	#	my $mta = $reply->{mta};
	#	return error("No {mta} in get)track reply") if !$mta;

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

	# EVENTS are not pushed onto the reply queue
	# Instead, they can generate additional API_GET_ITEM commands

	#	if ($WITH_MOD_PROCESSING)
	#	{
	#		my $mods = $reply->{mods};
	#		# delete $reply->{mods} if $mods;
	#		if ($mods && !$reply->{item})
	#		{
	#			warning($dbg+1,1,"found ".scalar(@$mods)." mods");
	#			my $evt_mask = $reply->{evt_mask} || 0;
	#			for my $mod (@$mods)
	#			{
	#				my $hash_name = lc($NAV_WHAT{$mod->{what}}).'s';
	#				warning($dbg+1,2,sprintf(
	#					"MOD(%02x=%s) uuid(%s) bits(%02x) evt_mask(%08x)",
	#					$mod->{what},
	#					$hash_name,
	#					$mod->{uuid},
	#					$mod->{bits},
	#					$evt_mask));
    #
	#				# delete it, or ..
    #
	#				if ($mod->{bits} == 1)
	#				{
	#					my $hash = $this->{$hash_name};
	#					my $exists = $hash->{$mod->{uuid}};
	#					if ($exists)
	#					{
	#						warning($dbg,2,"deleting $hash_name($mod->{uuid}) $exists->{name}");
	#						delete $hash->{$mod->{uuid}};
	#						$this->incVersion();
	#					}
	#				}
	#				else	# enque a GET_ITEM command for th emod
	#				{
	#					warning($dbg,0,"enquing mod($mod->{what}) uuid($mod->{uuid})");
	#					$this->queueTRACKCommand($API_GET_ITEM,$mod->{what},'mod_item',$mod->{uuid},undef,undef);
	#				}
    #
	#			}	# for each mod
	#		}	# $mods
	#	}	# $WITH_MOD_PROCESSING

	return $reply;

}





1;