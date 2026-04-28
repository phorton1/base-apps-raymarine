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



my $WITH_MOD_PROCESSING = 1;

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

sub apiCommandName
{
	my ($cmd) = @_;
	return 'DO_QUERY'	if $cmd == $API_DO_QUERY;
	return 'GET_ITEM'	if $cmd == $API_GET_ITEM;
	return 'NEW_ITEM'	if $cmd == $API_NEW_ITEM;
	return 'DEL_ITEM'	if $cmd == $API_DEL_ITEM;
	return 'MOD_ITEM'		if $cmd == $API_MOD_ITEM;
	return 'DO_BATCH'	if $cmd == $API_DO_BATCH;
	return "UNKNOWN API COMMAND";
}


sub queueWPMGRCommand
{
	my ($this,$api_command,$what,$name,$uuid,$data,$progress) = @_;
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
			warning($dbg-1,0,"not enquiing duplicate api_command($api_command)");
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
	push @{$this->{command_queue}},$command;

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
	my ($this,$what) = @_;
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

	my $num = 0;
	for my $uuid (@$uuids)
	{
		$seq = $this->{next_seqnum}++;
		$request = createMsg($seq,$DIRECTION_SEND,$CMD_ITEM,$what,$uuid);
		return 0 if !$this->update_item_request($seq,$what,"query($num)",$uuid,$request);
		$num++;
	}

	my $hash_name = lc($what_name)."s";
	my $hash = $this->{$hash_name};
	display($dbg+1,1,"keys($hash_name) = ".join(" ",keys %$hash));
	return 1;
}


sub do_query
	# get all Waypoints, Routes, and Groups from the E80
{
	my ($this) = @_;
	c_print("do_query()\n");

	return 0 if !$this->query_one($WHAT_WAYPOINT);
	return 0 if !$this->query_one($WHAT_ROUTE);
	return 0 if !$this->query_one($WHAT_GROUP);
	return 1;
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

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIRECTION_SEND,$CMD_FIND,$what,name16_hex($name));
	return 0 if !$this->sendRequest($seq,"$what_name name must not exist",$request);
	return 0 if !$this->waitReply(-1);

	# check the uuid

	$seq = $this->{next_seqnum}++;
	$request = createMsg($seq,$DIRECTION_SEND,$CMD_ITEM,$what,$uuid);
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
	my $ok = $this->waitReply(1);
	if ($ok && $what != $WHAT_WAYPOINT)
	{
		$this->get_item({what=>$what, name=>$name, uuid=>$uuid});
	}
	return $ok;
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
		# Reply contains MOD events; handleEvent() processes them and queues
		# GET_ITEM for each changed item ($WITH_MOD_PROCESSING=1).
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



sub do_batch
	# Process an ordered list of WPMGR ops synchronously, one at a time,
	# with full E80 handshaking between each.  Caller owns ordering:
	# del routes before del groups, del groups before del waypoints.
	# del_wp ops skip _removeFromGroup — caller guarantees group is gone.
{
	my ($this,$command) = @_;
	my $ops  = $command->{ops};
	my $prog = $command->{progress};
	my $mon  = $MONITOR_API_BUILDS;
	my $col  = $UTILS_COLOR_CYAN;

	$this->{batch_active} = 1;
	for my $op (@$ops)
	{
		last if $prog && $prog->{cancelled};

		my $type = $op->{type};
		my $uuid = $op->{uuid};
		my ($rslt,$name,$what_label);

		if ($type eq 'del_route')
		{
			my $item = $this->{routes}{$uuid};
			if (!$item) { warning(0,0,"do_batch: route($uuid) not in memory"); next; }
			$name       = $item->{name};
			$what_label = 'Route';
			$rslt = $this->delete_item({what=>$WHAT_ROUTE, uuid=>$uuid, name=>$name});
		}
		elsif ($type eq 'del_group')
		{
			my $item = $this->{groups}{$uuid};
			if (!$item) { warning(0,0,"do_batch: group($uuid) not in memory"); next; }
			$name       = $item->{name};
			$what_label = 'Group';
			$rslt = $this->delete_item({what=>$WHAT_GROUP, uuid=>$uuid, name=>$name});
		}
		elsif ($type eq 'del_wp')
		{
			my $item = $this->{waypoints}{$uuid};
			if (!$item) { warning(0,0,"do_batch: wp($uuid) not in memory"); next; }
			$name       = $item->{name};
			$what_label = 'WP';
			$rslt = $this->delete_item({what=>$WHAT_WAYPOINT, uuid=>$uuid, name=>$name});
		}
		elsif ($type eq 'new_wp')
		{
			$name       = $op->{name};
			$what_label = 'WP';
			my $lat = $op->{lat};
			my $lon = $op->{lon};
			my $ts  = $op->{ts} // 0;
			my $alt = latLonToNorthEast($lat,$lon);
			my $buffer = buildWaypoint(0,{
				name    => $name,
				comment => $op->{comment} // '',
				lat     => int($lat * $SCALE_LATLON),
				lon     => int($lon * $SCALE_LATLON),
				north   => $alt->{north},
				east    => $alt->{east},
				sym     => $op->{sym}   // 25,
				depth   => $op->{depth} // 0,
				date    => int($ts / $SECS_PER_DAY),
				time    => int($ts % $SECS_PER_DAY),
			},$mon,$col);
			$rslt = $this->create_item({
				what => $WHAT_WAYPOINT,
				uuid => $uuid,
				name => $name,
				data => unpack('H*',$buffer),
			});
		}
		elsif ($type eq 'new_group')
		{
			$name       = $op->{name};
			$what_label = 'Group';
			my $buffer = buildGroup(0,{
				name    => $name,
				comment => $op->{comment} // '',
				uuids   => shared_clone($op->{members} // []),
			},$mon,$col);
			$rslt = $this->create_item({
				what => $WHAT_GROUP,
				uuid => $uuid,
				name => $name,
				data => unpack('H*',$buffer),
			});
		}
		elsif ($type eq 'new_route')
		{
			$name       = $op->{name};
			$what_label = 'Route';
			my $wps = $op->{waypoints} // [];
			my @pts = map { shared_clone({}) } @$wps;
			my $buffer = buildRoute(0,{
				name    => $name,
				comment => $op->{comment} // '',
				bits    => 0,
				color   => $op->{color} // 0,
				uuids   => shared_clone($wps),
				points  => shared_clone(\@pts),
			},$mon,$col);
			$rslt = $this->create_item({
				what => $WHAT_ROUTE,
				uuid => $uuid,
				name => $name,
				data => unpack('H*',$buffer),
			});
		}
		else
		{
			warning(0,0,"do_batch: unknown op type '$type'");
			next;
		}

		if ($prog)
		{
			if ($rslt)
			{
				$prog->{label} = "$what_label: $name" if defined $name;
				$prog->{done}++;
			}
			else
			{
				$prog->{error}     = "batch $type failed: $name";
				$prog->{cancelled} = 1;
			}
		}
		elsif (!$rslt)
		{
			error("do_batch: $type($name) failed");
		}
	}
	$this->{batch_active} = 0;
	return 1;
}


sub handleCommand
{
	my ($this,$command) = @_;
	my $api_command = $command->{api_command};
	my $cmd_name = apiCommandName($api_command);
	display($dbg,0,"$this->{name} handleCommand($api_command=$cmd_name) started");

	my $prog = $command->{progress};
	my $what_raw   = $NAV_WHAT{$command->{what} // 0} // '';
	my $what_label = $what_raw eq 'WAYPOINT' ? 'WP' : ucfirst(lc($what_raw));

	# Skip user-visible commands silently if this operation was cancelled
	if ($prog && $prog->{cancelled} &&
		($api_command == $API_NEW_ITEM ||
		 $api_command == $API_DEL_ITEM ||
		 $api_command == $API_MOD_ITEM))
	{
		$this->{command_rslt} = 1;
		display($dbg,0,"$this->{name} handleCommand($api_command=$cmd_name) SKIPPED (cancelled)");
		return;
	}

	my $rslt;

	$rslt = $this->get_item($command) 		if $api_command == $API_GET_ITEM;
	$rslt = $this->do_query($command) 		if $api_command == $API_DO_QUERY;
	$rslt = $this->create_item($command) 	if $api_command == $API_NEW_ITEM;
	$rslt = $this->delete_item($command) 	if $api_command == $API_DEL_ITEM;
	$rslt = $this->modify_item($command) 	if $api_command == $API_MOD_ITEM;
	$rslt = $this->do_batch($command) 		if $api_command == $API_DO_BATCH;

	if ($prog && ($api_command == $API_NEW_ITEM || $api_command == $API_DEL_ITEM))
	{
		if ($rslt)
		{
			$prog->{label} = "$what_label: $command->{name}" if defined $command->{name};
			$prog->{done}++;
		}
		else
		{
			$prog->{error}     = "$cmd_name($what_label) failed: $command->{name}";
			$prog->{cancelled} = 1;
		}
	}
	error("API $cmd_name failed") if !$rslt;

	$this->{command_rslt} = $rslt;
		
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
		!$WITH_MOD_PROCESSING ||
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

		if ($mod->{bits} == 1)
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
		elsif (!$this->{batch_active})
		{
			warning($dbg_mods,0,"enquing mod($mod->{what}) uuid($mod->{uuid})");
			$this->queueWPMGRCommand($API_GET_ITEM,$mod->{what},'mod_item',$mod->{uuid},undef);
		}

	}	# for each mod

	return $packet;
		# packets with mods && no {item} will go to
		# the reply queue.  They are needed for modify_item
		# but may stack up for those silly waypoint events
		# that happen continuously while underway.

}	# handleEvent()




1;