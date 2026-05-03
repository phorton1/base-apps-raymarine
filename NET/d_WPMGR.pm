#---------------------------------------------
# d_WPMGR.pm
#---------------------------------------------
# WPMGR is the Waypoints, Routes, and Groups manager service
#
# current status:
#
# Can create and delete Waypoints, Routes, and Groups.
# Deleting a Group with Waypoints in it, moves them to My Waypoints.
# Cannot delete a Waypoint that is in a Group (must remove from group first).
#
# Can add/remove Waypoints to/from Groups and move Waypoints between Groups.
# - Moving between Groups is two steps: remove from old, add to new.
# - The command_queue sequences multi-step operations automatically.
#
# Can add/remove Waypoints to/from Routes.
# - E80 does not send a MOD event on route point changes; GET_ITEM is queued explicitly.


package apps::raymarine::NET::d_WPMGR;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_utils;
use apps::raymarine::NET::a_mon;
use apps::raymarine::NET::b_records;
use apps::raymarine::NET::e_wp_defs;
require apps::raymarine::NET::e_wp_api;
use apps::raymarine::NET::c_RAYDP;
use base qw(apps::raymarine::NET::b_sock);


my $dbg = 0;
my $dbg_got = 0;
my $dbg_mods = 0;


our $query_in_progress :shared = 0;
our $pending_commands  :shared = 0;
my $delete_progress = shared_clone({progress => undef});

my $WPMGR_SERVICE_ID = 15;
	# 15 = 0xf0 == 'F000' in streams

my %BUFFER_CHUNK = (
	$WHAT_WAYPOINT	=> 498,
	$WHAT_ROUTE		=> 498,
	$WHAT_GROUP		=> 498,
);



sub init
{
	my ($this) = @_;
	display($dbg,0,"d_WPMGR init($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto}");
	$this->SUPER::init();
	$this->{local_ip}			= $LOCAL_IP;

	$this->{waypoints} = shared_clone({});
	$this->{routes} = shared_clone({});
	$this->{groups} = shared_clone({});
		# hashes of buffers by uuid, where the
		# buffer starts with the big_len
	return $this;
}



sub destroy
{
	my ($this) = @_;
	display($dbg,0,"d_WPMGR destroy($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto}");

	$this->SUPER::destroy();

    delete @$this{qw(waypoints routes groups)};
	return $this;
}



#--------------------------------------
# API
#--------------------------------------

sub getPendingCommands { return $pending_commands; }


sub apiCommandName
{
	my ($cmd) = @_;
	return 'DO_QUERY'	if $cmd == $API_DO_QUERY;
	return 'GET_ITEM'	if $cmd == $API_GET_ITEM;
	return 'NEW_ITEM'	if $cmd == $API_NEW_ITEM;
	return 'DEL_ITEM'	if $cmd == $API_DEL_ITEM;
	return 'MOD_ITEM'		if $cmd == $API_MOD_ITEM;
	return "UNKNOWN API COMMAND";
}


sub queueWPMGRCommand
{
	my ($this,$api_command,$what,$name,$uuid,$data,$progress,$front) = @_;
	$data ||= 0;
	display_hash($dbg+2,0,"queueWPCommand($this)",$this);
	
	return error("No 'this' in queueWPMGRCommand") if !$this;
	return error("Not started") if !$this->{started};
	return error("Not running") if !$this->{running};

	my $cmd_name = apiCommandName($api_command);

	if ($this->{show_parsed_output})
	{
		my $msg = "# queueWPMGRCommand($api_command=$cmd_name) what($what) name($name) uuid($uuid) data(".($data?length($data):'empty').")\n";
		c_print($msg);
		writeLog($msg,"shark.log");
	}

	for my $exist (@{$this->{command_queue}})
	{
		if ($exist->{api_command} == $api_command &&
			$exist->{what} == $what	&&
			$exist->{name} eq $name	&&
			$exist->{uuid} eq $uuid	&&
			$exist->{data} eq $data)
		{
			warning($dbg_mods,0,"not enquiing duplicate api_command($api_command)");
			return 1;
		}
	}
	my $command = shared_clone({
		api_command => $api_command,
		what => $what,
		name => $name,
		uuid => $uuid,
		data => $data });
	$command->{progress} = $progress if $progress;
	$delete_progress->{progress} = $progress
		if $progress && $progress->{_counting_get_items} &&
		   ($api_command == $API_DEL_ITEM || $api_command == $API_NEW_ITEM) &&
		   ($what == $WHAT_ROUTE || $what == $WHAT_GROUP);
	$pending_commands++;
	if ($front)
	{
		my @q = @{$this->{command_queue}};
		unshift @q, $command;
		$this->{command_queue} = shared_clone(\@q);
	}
	else
	{
		push @{$this->{command_queue}}, $command;
	}

	return 1;
}


#-------------------------------------------------
# utilities
#-------------------------------------------------


sub createMsg
{
	my ($seq,$dir,$cmd,$what,$hex_data) = @_;
	$what ||= 0;
	$hex_data = '' if !defined($hex_data);

	display($dbg+2,0,sprintf("createMsg(%03x,%02x,%01x) seq($seq) hex_data($hex_data)",$dir,$what,$cmd));

	$hex_data =~ s/\s//g;
	my $cmd_word = $dir | $cmd | $what;
	my $data = $hex_data ? pack('H*',$hex_data) : '';
	my $len = length($data) + 4 + ($seq >= 0?4:0) ;
	my $msg =
		pack('v',$len).
		pack('v',$cmd_word).
		pack('v',$WPMGR_SERVICE_ID).
		($seq >= 0 ? pack('V',$seq) : '').
		$data;

	display($dbg+3,1,"msg=".unpack('H*',$msg));
	return $msg;
}


sub buildBufferMsgs
	# Split a hex-encoded buffer (big_len prefix + payload) into 512-byte-safe
	# BUFFER messages.  The E80 rejects individual messages > 512 bytes, so any
	# payload longer than 498 bytes must be sent as multiple BUFFER messages,
	# each with its own big_len prefix, exactly mirroring how the E80 itself
	# chunks large route/group buffers on the receive side.
{
	my ($seq, $hex_data, $what) = @_;
	my $bin     = pack('H*', $hex_data);
	my $payload = substr($bin, 4);		# strip the big_len prefix
	my $msgs    = '';
	my $CHUNK   = $BUFFER_CHUNK{$what // 0} // 498;
	my $offset  = 0;
	while ($offset < length($payload))
	{
		my $n     = length($payload) - $offset;
		$n = $CHUNK if $n > $CHUNK;
		my $chunk = substr($payload, $offset, $n);
		$msgs    .= createMsg($seq, $DIRECTION_INFO, $CMD_BUFFER, 0,
		                      unpack('H*', pack('V',$n) . $chunk));
		$offset  += $n;
	}
	return $msgs;
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
# commandThread atoms
#============================================================

my $dict_context = '00000000 00000000 1a000000';
	# RMS seems to consistently send this out with the leading CMD_CONTEXT
	# in a request, and seems to recieve 19000000 as the leading CMD_CONTEXT
	# in a reply.

my $dict_buffer = '28000000 00000000 00000000 00000000 00000000 00000000'.
                  'ffff0000 00000000 00000000 00000000 00000000';
    #             '{magic}0000 00000000 00000000 00000000 00000000';
    #              '10270000 00000000 00000000 00000000 00000000';
	# I only use this in query, and query is working.
	# I used to think it mattered, '1027' for Waypoints, '9600' for Routes,
	# and '6400' for Groups, but now i just think that is an optimization
	# for the client to tell the E80 a maximum size reply it can handle,
	# so I changed it to ffff (64K) for the index. Note that d_FILESYS
	# extends it even further to get 32M files via UDP.


sub update_item_request
{
	my ($this,$seq,$what,$name,$uuid,$request) = @_;
	my $what_name = $NAV_WHAT{$what};
	return 0 if !$this->sendRequest($seq,"$name $what_name",$request);
	my $reply = $this->waitReply(1);
	return 0 if !$reply;
	return error("No {item} in $name $what_name reply") if !$reply->{item};

	display($dbg_got,0,"got $what_name($uuid) = '$reply->{item}->{name}'");

	my $hash_name = lc($what_name)."s";
	my $hash = $this->{$hash_name};

	my $item = $reply->{item};
	$item->{version} = $this->incVersion();
	$hash->{$uuid} = $item;
			# notify UI
	return 1;
}


sub query_one
{
	my ($this, $what, $progress) = @_;
	my $what_name = $NAV_WHAT{$what};
	display($dbg,0,"query_one($what_name)");

	my $seq = $this->{next_seqnum}++;
	my $request =
		createMsg($seq,$DIRECTION_SEND,$CMD_CONTEXT,$what).
		createMsg($seq,$DIRECTION_INFO,$CMD_CONTEXT,0,$dict_context).
		createMsg($seq,$DIRECTION_INFO,$CMD_BUFFER,0,$dict_buffer).
		createMsg($seq,$DIRECTION_INFO,$CMD_LIST,0,'00000000 00000000');

	return 0 if !$this->sendRequest($seq,"$what_name DICT",$request);
	my $reply = $this->waitReply(1);
	return 0 if !$reply;
	return error("dictionary $what_name reply does not have is_dict(1) or {dict_uuids}")
		if !$reply->{is_dict} || !$reply->{dict_uuids};
	my $uuids = $reply->{dict_uuids};

	$progress->{total} += scalar(@$uuids) if $progress;

	my $hash_name = lc($what_name)."s";
	my $hash = $this->{$hash_name};
	my $num = 0;
	for my $uuid (@$uuids)
	{
		$seq = $this->{next_seqnum}++;
		$request = createMsg($seq,$DIRECTION_SEND,$CMD_ITEM,$what,$uuid);
		return 0 if !$this->update_item_request($seq,$what,"query($num)",$uuid,$request);
		if ($progress)
		{
			$progress->{label} = $hash->{$uuid}{name} // '';
			$progress->{done}++;
		}
		$num++;
	}

	display($dbg+1,1,"keys($hash_name) = ".join(" ",keys %$hash));
	return 1;
}


sub do_query
	# get all Waypoints, Routes, and Groups from the E80.
	# Clears in-memory state first so stale items (deleted on E80) don't persist.
{
	my ($this, $command) = @_;
	c_print("do_query()\n");

	$this->{waypoints} = shared_clone({});
	$this->{routes}    = shared_clone({});
	$this->{groups}    = shared_clone({});

	my $progress = (ref($command) eq 'HASH') ? $command->{progress} : undef;

	$query_in_progress++;
	my $ok =
		$this->query_one($WHAT_WAYPOINT, $progress) &&
		$this->query_one($WHAT_ROUTE,    $progress) &&
		$this->query_one($WHAT_GROUP,    $progress);
	$query_in_progress--;

	if ($progress && exists $progress->{workers})
	{
		$progress->{error} = 'WPMGR query failed' if !$ok;
		$progress->{workers}--;
	}

	return $ok ? 1 : 0;
}


sub queueRefresh
{
	my ($this, $progress) = @_;
	return $this->queueWPMGRCommand($API_DO_QUERY, 0, 'refresh', 0, '', $progress);
}



sub create_item
{
	my ($this,$command) = @_;
	my $what = $command->{what};
	my $what_name = $NAV_WHAT{$what};
	my $uuid = $command->{uuid};
	my $name = $command->{name};
	my $data = $command->{data};
	display($dbg,0,"create_item($what=$what_name) $uuid $name");

	my $hash_name = lc($what_name).'s';
	return error("create_item: $what_name($uuid) already in memory") if $this->{$hash_name}{$uuid};

	# check the name

	if (0)	# ALLOW DUPLICATE ITEM NAMES ON THE E80
	{
		my $seq = $this->{next_seqnum}++;
		my $request = createMsg($seq,$DIRECTION_SEND,$CMD_FIND,$what,name16_hex($name));
		return 0 if !$this->sendRequest($seq,"$what_name name must not exist",$request);
		return 0 if !$this->waitReply(-1);
	}

	# check the uuid

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIRECTION_SEND,$CMD_ITEM,$what,$uuid);
	return 0 if !$this->sendRequest($seq,"$what_name uuid must not exist",$request);
	return 0 if !$this->waitReply(-1);

	# create the item
	# These messages are sent separatly by RNS for groups

	$seq = $this->{next_seqnum}++;
	$request =
		createMsg($seq,$DIRECTION_SEND,$CMD_MODIFY,		$what,	$uuid).
		createMsg($seq,$DIRECTION_INFO,$CMD_CONTEXT,	0,		$uuid.'03000000').	#.'00000000').
		buildBufferMsgs($seq, $data, $what).
		createMsg($seq,$DIRECTION_INFO,$CMD_LIST,		0,		'00000000 00000000'); # $uuid);

	return 0 if !$this->sendRequest($seq,"$name $what_name",$request);
	return $this->waitReply(1);
}



sub modify_item
{
	my ($this,$command) = @_;
	my $what = $command->{what};
	my $what_name = $NAV_WHAT{$what};
	my $uuid = $command->{uuid};
	my $name = $command->{name};
	my $data = $command->{data};

	display($dbg,0,"modify_item($what=$what_name) $uuid $name");
	display($dbg+1,1,"data=".unpack('H*',$data));

	my $hash_name = lc($what_name).'s';
	return error("modify_item: $what_name($uuid) not in memory") if !$this->{$hash_name}{$uuid};

	my $request;
	my $seq = $this->{next_seqnum}++;

	# MUST apparently do $CMD_EXIST before the $CMD_DATA
	
	$request = createMsg($seq,$DIRECTION_SEND,$CMD_EXIST,$what,'07000000'.$uuid);	# '15000000'.$uuid);
	return 0 if !$this->sendRequest($seq,"modify1 $what_name",$request);
	return 0 if !$this->waitReply(1);

	# These messages are sent separatly by RNS for groups
	
	$seq = $this->{next_seqnum}++;
	$request =
		createMsg($seq,$DIRECTION_SEND,$CMD_DATA,		$what,	'07000000'.$uuid).	# '15000000'.$uuid);
		createMsg($seq,$DIRECTION_INFO,$CMD_CONTEXT,	0,		$uuid.'00000000').	#.'03000000').
		buildBufferMsgs($seq, $data, $what).
		createMsg($seq,$DIRECTION_INFO,$CMD_LIST,		0,		$uuid);
	return 0 if !$this->sendRequest($seq,"modify $what_name",$request);
	return 0 if !$this->waitReply(1);
	return 1;
}


sub delete_item
	 # name just included for nicety debugging
{
	my ($this,$command) = @_;
	my $what = $command->{what};
	my $what_name = $NAV_WHAT{$what};
	my $uuid = $command->{uuid};
	my $name = $command->{name};
	display($dbg,0,"delete_item($what=$what_name) $uuid $name");

	my $hash_name = lc($what_name).'s';
	return error("delete_item: $what_name($uuid) not in memory") if !$this->{$hash_name}{$uuid};

	if (0)
	{
		# hypothetical fix for MRD problem to prime the E80 before deleting the big michelle route
		# did not fix the problem; code left temporarily as reminder that we tried it.
		my $seq = $this->{next_seqnum}++;
		my $request = createMsg($seq,$DIRECTION_SEND,$CMD_FIND,$what,name16_hex($name));
		return 0 if !$this->sendRequest($seq,"find $what_name",$request);
		return 0 if !$this->waitReply(1);
	}

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIRECTION_SEND,$CMD_UUID,$what,$uuid);
	return 0 if !$this->sendRequest($seq,"delete $what_name",$request);
	return 0 if !$this->waitReply(1);

	delete $this->{$hash_name}->{$uuid};
	$this->incVersion();		# notify UI
	return 1;
}


sub get_item
{
	my ($this,$command) = @_;
	my $what = $command->{what};
	my $what_name = $NAV_WHAT{$what};
	my $uuid = $command->{uuid};
	my $name = $command->{name};
	display($dbg,0,"get_item($what=$what_name) $uuid $name");

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIRECTION_SEND,$CMD_ITEM,$what,$uuid);
	return $this->update_item_request($seq,$what,'get',$uuid,$request);
}









sub handleCommand
{
	my ($this,$command) = @_;
	my $api_command = $command->{api_command};
	my $cmd_name = apiCommandName($api_command);
	display($dbg,0,"$this->{name} handleCommand($api_command=$cmd_name) started");

	my $progress = $command->{progress};
	my $what_raw   = $NAV_WHAT{$command->{what} // 0} // '';
	my $what_label = $what_raw eq 'WAYPOINT' ? 'WP' : ucfirst(lc($what_raw));

	# Skip user-visible commands silently if this operation was cancelled
	if ($progress && $progress->{cancelled} &&
		($api_command == $API_NEW_ITEM ||
		 $api_command == $API_DEL_ITEM ||
		 $api_command == $API_MOD_ITEM))
	{
		$this->{command_rslt} = 1;
		$pending_commands--;
		display($dbg,0,"$this->{name} handleCommand($api_command=$cmd_name) SKIPPED (cancelled)");
		return;
	}

	my $rslt;

	$rslt = $this->get_item($command) 		if $api_command == $API_GET_ITEM;
	$rslt = $this->do_query($command) 		if $api_command == $API_DO_QUERY;
	$rslt = $this->create_item($command) 	if $api_command == $API_NEW_ITEM;
	$rslt = $this->delete_item($command) 	if $api_command == $API_DEL_ITEM;
	$rslt = $this->modify_item($command) 	if $api_command == $API_MOD_ITEM;

	if ($progress && ($api_command == $API_NEW_ITEM ||
	                  $api_command == $API_DEL_ITEM ||
	                  $api_command == $API_MOD_ITEM ||
	                  $api_command == $API_GET_ITEM))
	{
		if ($rslt)
		{
			if ($api_command != $API_GET_ITEM)
			{
				$progress->{label} = "$what_label: $command->{name}" if defined $command->{name};
			}
			$progress->{done}++;
		}
		else
		{
			$progress->{error}     = "$cmd_name($what_label) failed: $command->{name}";
			$progress->{cancelled} = 1;
		}
	}


	error("API $cmd_name failed") if !$rslt;

	$this->{command_rslt} = $rslt;
	$pending_commands--;
		
	display($dbg,0,"$this->{name} handleCommand($api_command=$cmd_name) finished");
}




#========================================================================
# overriden tcpBase methods
#========================================================================

sub onConnect
{
	my ($this) = @_;
	$this->queueWPMGRCommand($API_DO_QUERY,0,'auto_populate',0,'')
		if $this->{auto_populate};
}




sub handleEvent
	# handles any Events or Mods that the packet might have,
	# DOES NOT RETURN UNDEF because a 'mod-only' response is
	# the proper reply to a modify_item call.
{
	my ($this,$packet) = @_;
	my $mods = $packet->{mods};
	return $packet if
		!$mods ||
		$packet->{item};

	warning($dbg_mods+1,1,"found ".scalar(@$mods)." mods");
	my $evt_mask = $packet->{evt_mask} || 0;
	for my $mod (@$mods)
	{
		my $hash_name = lc($NAV_WHAT{$mod->{what}}).'s';
		warning($dbg_mods+1,2,sprintf(
			"MOD(%02x=%s) uuid(%s) bits(%02x) evt_mask(%08x)",
			$mod->{what},
			$hash_name,
			$mod->{uuid},
			$mod->{bits},
			$evt_mask));

		# delete it, or ..

		if ($mod->{bits} & 1)
		{
			my $hash = $this->{$hash_name};
			my $exists = $hash->{$mod->{uuid}};
			if ($exists)
			{
				warning($dbg_mods,2,"deleting $hash_name($mod->{uuid}) $exists->{name}");
				delete $hash->{$mod->{uuid}};
				$this->incVersion();
			}
		}
		else
		{
			warning($dbg_mods,0,"enquing mod($mod->{what}) uuid($mod->{uuid})");
			$this->queueWPMGRCommand($API_GET_ITEM,$mod->{what},'mod_item',$mod->{uuid},undef,$delete_progress->{progress},1);
		}

	}	# for each mod

	return $packet;
		# packets with mods && no {item} will go to
		# the reply queue.  They are needed for modify_item
		# but may stack up for those silly waypoint events
		# that happen continuously while underway.

}	# handleEvent()




1;