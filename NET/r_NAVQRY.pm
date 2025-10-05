#---------------------------------------------
# r_NEWQRY.pm
#---------------------------------------------
# state of affairs:
#
# Can create and delete Waypoints, Routes, and Groups.
# Deleting a Group with Waypoints in it, moves them to My Waypoints.
# Cannot delete a Waypoint that is in a Group.
#
# I know how to add a waypoint to a Group.
# - Moving waypoints between folders is a multi-step process.
# - The waypoints probably need to be removed from the
#   the group before deleting them
# - The command_queue is probably overkill.
#
# - Don't know how to move a Waypoint to a Group or back to My Waypoints
# - Dont know how to add or remove Waypoints from Routes.


package r_NAVQRY;
use strict;
use warnings;
use threads;
use threads::shared;
use Socket;
use IO::Select;
use IO::Handle;
use IO::Socket::INET;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use r_utils;
use r_RAYDP;
use nq_parse;
use nq_packet;
use r_utils;

my $dbg = 0;


my $WITH_MOD_PROCESSING = 1;


my $COMMAND_TIMEOUT 		= 3;
my $REFRESH_INTERVAL		= 5;
my $RECONNECT_INTERVAL		= 15;

my $SHOW_OUTPUT = 0;
my $SHOW_INPUT = 0;
my $DBG_WAIT = 1;

# my $SUCCESS_SIG = '00000400';
# my $DICT_END_RECORD_MARKER	= '10000202';

our $API_NONE 		= 0;
our $API_DO_QUERY	= 1;
our $API_GET_ITEM	= 2;
our $API_NEW_ITEM 	= 3;
our $API_DEL_ITEM 	= 4;
our $API_MOD_ITEM	= 5;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		startNavQuery
		$navqry

		$API_NONE
		$API_DO_QUERY
		$API_GET_ITEM
		$API_NEW_ITEM
		$API_DEL_ITEM
		$API_MOD_ITEM

		apiCommandName
		queueNQCommand

		$WHAT_WAYPOINT
		$WHAT_ROUTE
		$WHAT_GROUP
		$WHAT_DATABASE

		$ROUTE_COLOR_RED
		$ROUTE_COLOR_YELLOW
		$ROUTE_COLOR_GREEN
		$ROUTE_COLOR_BLUE
		$ROUTE_COLOR_PURPLE
		$ROUTE_COLOR_BLACK
		$NUM_ROUTE_COLORS

	);
}





our $NAVQRY_FUNC		= 0x000f;
	# F000 in streams

# WCDD = 0xDDWC



our $ROUTE_COLOR_RED 	= 0;
our $ROUTE_COLOR_YELLOW = 1;
our $ROUTE_COLOR_GREEN	= 2;
our $ROUTE_COLOR_BLUE	= 3;
our $ROUTE_COLOR_PURPLE	= 4;
our $ROUTE_COLOR_BLACK	= 5;
our $NUM_ROUTE_COLORS   = 6;

	# red, yellow, green, blue, purple, black



our $navqry:shared;



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
	return 'MOD_ITEM'	if $cmd == $API_MOD_ITEM;
	return "UNKNOWN API COMMAND";
}


sub startNavQuery
{
	my ($class) = @_;
	display($dbg,0,"initing $class");
	my $this = shared_clone({});
	bless $this,$class;
	$this->{started} = 1;
	$this->{running} = 0;
	$this->{next_seqnum} = 1;
	$this->{command_queue} = shared_clone([]);
	$this->{replies} = shared_clone([]);
	$this->{version} = 0;
	$this->{waypoints} = shared_clone({});
	$this->{routes} = shared_clone({});
	$this->{groups} = shared_clone({});
		# hashes of buffers by uuid, where the
		# buffer starts with the big_len

	$navqry = $this;

	display($dbg,0,"creating listen_thread");
    my $listen_thread = threads->create(\&listenerThread,$this);
    display($dbg,0,"listen_thread created");
    $listen_thread->detach();
    display($dbg,0,"listen_thread detached");
}



sub queueNQCommand
{
	my ($this,$api_command,$what,$name,$uuid,$data,$params) = @_;
	return error("No 'this' in queueNQCommand") if !$this;
	return error("Not started") if !$this->{started};
	return error("Not running") if !$this->{running};

	my $cmd_name = apiCommandName($api_command);
	my $msg = "# queueNQCommand($api_command=$cmd_name) what($what) name($name) uuid($uuid) data(".($data?length($data):'empty').")\n";
	print $msg;
	navQueryLog($msg,"shark.log");
	
	my $command = shared_clone({
		api_command => $api_command,
		what => $what,
		name => $name,
		uuid => $uuid,
		data => $data,
		params => $params });
	push @{$this->{command_queue}},$command;

	return 1;
}


#-------------------------------------------------
# utilities
#-------------------------------------------------

sub incVersion
{
	my ($this) = @_;
	$this->{version}++;
	display($dbg,0,"incVersion($this->{version})");
}

sub name16_hex
	# return hex representation of max16 name + null
{
	my ($name,$opt_end) = @_;
	while (length($name) < 16) { $name .= "\x00" }
	$name .= $opt_end ? pack('H*',$opt_end) : "\x00";
	return unpack('H*',$name);
}


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
		pack('v',$NAVQRY_FUNC).
		($seq >= 0 ? pack('V',$seq) : '').
		$data;

	display($dbg+3,1,"msg=".unpack('H*',$msg));
	return $msg;
}


sub sendRequest
{
	my ($this,$sock,$sel,$seq,$name,$request) = @_;
	if (!$sel->can_write())
	{
		error("Cannot write sendRequest($seq): $!");
		return 0;
	}

	my $text = "# sendRequest($seq) $name\n";
	my $rec = parseNQPacket(1,0,$NAVQUERY_PORT,$request);
		# 1=with_text, 0=is_reply
	$text .= $rec->{text};
	
	my $color = $UTILS_COLOR_LIGHT_CYAN;
	setConsoleColor($color) if $color;
	print $text;
	setConsoleColor() if $color;
	navQueryLog($text,'shark.log');

	my $hdr = substr($request,0,2);
	my $data = substr($request,2);
	if (!$sock->send($hdr))
	{
		error("Could not send header($seq)\n$!");
		return 0;
	}
	if (!$sock->send($data))
	{
		error("Could not send header($seq)\n$!");
		return 0;
	}

	$this->{wait_seq} = $seq;
	$this->{wait_name} = $name;
	return 1
}


sub waitReply
{
	my ($this,$expect_success) = @_;
	my $seq = $this->{wait_seq};
	my $name = $this->{wait_name};
	my $start = time();

	display($dbg+1,0,"waitReply($seq) $name");

	while ($this->{started})
	{
		my $replies = $this->{replies};
		if (@$replies)
		{
			my $reply = shift @$replies;
			display($dbg+1,1,"got reply seq($reply->{seq_num}) is_event($reply->{is_event})",$reply);
			if ($reply->{seq_num} == $seq)
			{
				if ($expect_success)
				{
					my $got_success = $reply->{success} ? 1 : -1;
					if ($got_success != $expect_success)
					{
						error("waitReply($seq) expected success($expect_success) but got($got_success)");
						return 0;
					}
				}

				display($dbg,1,"waitReply($seq) returning OK reply");
				return $reply;
			}
		}

		if (time() > $start + $COMMAND_TIMEOUT)
		{
			error("Command($seq) $name timed out");
			# $this->{started} = 0;
			# $this->{reconnect_time} = time();
			return '';
		}

		sleep(0.5);
	}

	return error("waitReply($seq) while !started");
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
	# so I changed it to ffff (64K) for the index. Note that r_FILESYS
	# extends it even further to get 32M files via UDP.


sub update_item_request
{
	my ($this,$sock,$sel,$seq,$what,$name,$uuid,$request) = @_;
	my $what_name = $NAV_WHAT{$what};
	return 0 if !$this->sendRequest($sock,$sel,$seq,"$name $what_name",$request);
	my $reply = $this->waitReply(1);
	return 0 if !$reply;
	return error("No {item} in $name $what_name reply") if !$reply->{item};

	my $hash_name = lc($what_name)."s";
	my $hash = $this->{$hash_name};
	$hash->{$uuid} = $reply->{item};
	$this->incVersion();		# notify UI
	return 1;
}


sub query_one
{
	my ($this,$sock,$sel,$what) = @_;
	my $what_name = $NAV_WHAT{$what};
	display($dbg,0,"query_one($what_name)");

	my $seq = $this->{next_seqnum}++;
	my $request =
		createMsg($seq,$DIR_SEND,$CMD_CONTEXT,$what).
		createMsg($seq,$DIR_INFO,$CMD_CONTEXT,0,$dict_context).
		createMsg($seq,$DIR_INFO,$CMD_BUFFER,0,$dict_buffer).
		createMsg($seq,$DIR_INFO,$CMD_LIST,0,'00000000 00000000');

	return 0 if !$this->sendRequest($sock,$sel,$seq,"$what_name DICT",$request);
	my $reply = $this->waitReply(1);
	return 0 if !$reply;
	return error("dictionary $what_name reply does not have is_dict(1) or {dict_uuids}")
		if !$reply->{is_dict} || !$reply->{dict_uuids};
	my $uuids = $reply->{dict_uuids};

	my $num = 0;
	for my $uuid (@$uuids)
	{
		$seq = $this->{next_seqnum}++;
		$request = createMsg($seq,$DIR_SEND,$CMD_ITEM,$what,$uuid);
		return 0 if !$this->update_item_request($sock,$sel,$seq,$what,"query($num)",$uuid,$request);
		$num++;
	}

	my $hash_name = lc($what_name)."s";
	my $hash = $this->{$hash_name};
	warning($dbg,1,"keys($hash_name) = ".join(" ",keys %$hash));
	return 1;
}


sub do_query
	# get all Waypoints, Routes, and Groups from the E80
{
	my ($this,$sock,$sel) = @_;
	print "do_query()\n";

	return 0 if !$this->query_one($sock,$sel,$WHAT_WAYPOINT);
	return 0 if !$this->query_one($sock,$sel,$WHAT_ROUTE);
	return 0 if !$this->query_one($sock,$sel,$WHAT_GROUP);
	return 1;
}



sub create_item
{
	my ($this,$sock,$sel,$command) = @_;
	my $what = $command->{what};
	my $what_name = $NAV_WHAT{$what};
	my $uuid = $command->{uuid};
	my $name = $command->{name};
	my $data = $command->{data};
	display($dbg,0,"create_item($what=$what_name) $uuid $name");

	# check the name

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIR_SEND,$CMD_FIND,$what,name16_hex($name));
	return 0 if !$this->sendRequest($sock,$sel,$seq,"$what_name name must not exist",$request);
	return 0 if !$this->waitReply(-1);

	# check the uuid

	$seq = $this->{next_seqnum}++;
	$request = createMsg($seq,$DIR_SEND,$CMD_ITEM,$what,$uuid);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"$what_name uuid must not exist",$request);
	return 0 if !$this->waitReply(-1);

	# create the item
	# These messages are sent separatly by RNS for groups

	$seq = $this->{next_seqnum}++;
	$request =
		createMsg($seq,$DIR_SEND,$CMD_MODIFY,	$what,	$uuid).
		createMsg($seq,$DIR_INFO,$CMD_CONTEXT,	0,		$uuid.'03000000').	#.'00000000').
		createMsg($seq,$DIR_INFO,$CMD_BUFFER,	0,		$data).
		createMsg($seq,$DIR_INFO,$CMD_LIST,		0,		'00000000 00000000'); # $uuid);

	return 0 if !$this->sendRequest($sock,$sel,$seq,"$name $what_name",$request);
	return 0 if !$this->waitReply(1);
	return 1;
}



sub modify_item
{
	my ($this,$sock,$sel,$command) = @_;
	my $what = $command->{what};
	my $what_name = $NAV_WHAT{$what};
	my $uuid = $command->{uuid};
	my $name = $command->{name};
	my $data = $command->{data};

	display($dbg,0,"modify_item($what=$what_name) $uuid $name");
	display($dbg+1,1,"data=".unpack('H*',$data));

	my $request;
	my $seq = $this->{next_seqnum}++;

	# MUST apparently do $CMD_EXIST before the $CMD_DATA
	
	$request = createMsg($seq,$DIR_SEND,$CMD_EXIST,$what,'07000000'.$uuid);	# '15000000'.$uuid);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"modify1 $what_name",$request);
	return 0 if !$this->waitReply(1);

	# These messages are sent separatly by RNS for groups
	
	$seq = $this->{next_seqnum}++;
	$request =
		createMsg($seq,$DIR_SEND,$CMD_DATA,		$what,	'07000000'.$uuid).	# '15000000'.$uuid);
		createMsg($seq,$DIR_INFO,$CMD_CONTEXT,	0,		$uuid.'00000000').	#.'03000000').
		createMsg($seq,$DIR_INFO,$CMD_BUFFER,	0,		$data).
		createMsg($seq,$DIR_INFO,$CMD_LIST,		0,		$uuid);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"modify $what_name",$request);
	return 0 if !$this->waitReply(1);
	return 1;
}


sub delete_item
	 # name just included for nicety debugging
{
	my ($this,$sock,$sel,$command) = @_;
	my $what = $command->{what};
	my $what_name = $NAV_WHAT{$what};
	my $uuid = $command->{uuid};
	my $name = $command->{name};
	display($dbg,0,"delete_item($what=$what_name) $uuid $name");

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIR_SEND,$CMD_UUID,$what,$uuid);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"delete $what_name",$request);
	return 0 if !$this->waitReply(1);

	my $hash_name = lc($what_name)."s";
	delete $this->{$hash_name}->{$uuid};
	$this->incVersion();		# notify UI
	return 1;
}


sub get_item
{
	my ($this,$sock,$sel,$command) = @_;
	my $what = $command->{what};
	my $what_name = $NAV_WHAT{$what};
	my $uuid = $command->{uuid};
	my $name = $command->{name};
	display($dbg,0,"get_item($what=$what_name) $uuid $name");

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIR_SEND,$CMD_ITEM,$what,$uuid);
	return $this->update_item_request($sock,$sel,$seq,$what,'get',$uuid,$request);
}



sub commandThread
{
	my ($this,$sock,$sel,$command) = @_;
	my $api_command = $command->{api_command};
	my $cmd_name = apiCommandName($api_command);
	display($dbg,0,"commandThread($api_command=$cmd_name) started");

	my $rslt;

	$rslt = $this->get_item($sock,$sel,$command) 		if $api_command == $API_GET_ITEM;
	$rslt = $this->do_query($sock,$sel,$command) 		if $api_command == $API_DO_QUERY;
	$rslt = $this->create_item($sock,$sel,$command) 	if $api_command == $API_NEW_ITEM;
	$rslt = $this->delete_item($sock,$sel,$command) 	if $api_command == $API_DEL_ITEM;
	$rslt = $this->modify_item($sock,$sel,$command) 	if $api_command == $API_MOD_ITEM;

	error("API $cmd_name failed") if !$rslt;

	$this->{command_rslt} = $rslt;
	$this->{busy} = 0;
		# Note to self.  I used to pull the command off the queue and use
		# {command} as the busy indicator, then set it to '' here.
		# But I believe that I once again ran into a Perl weirdness
		# that Perl will crash (during garbage collection) if you
		# re-assign a a shared reference to a scalar.
		
	display($dbg,0,"commandThread($api_command=$cmd_name) finished");
}




#========================================================================
# listener thread
#========================================================================


sub openSocket
	# start/stop = open or close the socket
	# based on running and started, initializing
	# the state as needed
{
	my ($this,$psock,$psel) = @_;
	if ($this->{started} && !$this->{running})
	{
		display($dbg,0,"opening navQuery socket");
		my $sock = IO::Socket::INET->new(
			LocalAddr => $LOCAL_IP,
			LocalPort => $NAVQUERY_PORT,
			PeerAddr  => $this->{nav_ip},
			PeerPort  => $this->{nav_port},
			Proto     => 'tcp',
			Reuse	  => 1,	# allows open even if windows is timing it out
			Timeout	  => 3 );
		if ($sock)
		{
			display($dbg,0,"navQuery socket opened");

			$this->{running} = 1;
			$$psock = $sock;
			$$psel = IO::Select->new($sock);

			$this->{buffer} = '';
			return 1;
		}
		else
		{
			error("Could not open navQuery socket to $this->{nav_ip}:$this->{nav_port}\n$!");
			$this->{started} = 0;
			$this->{reconnect_time} = time();
			return 0;
		}
	}
	elsif ($this->{running} && !$this->{started})
	{
		warning($dbg,0,"closing navQuerySocket");
		$$psock->shutdown(2);
		$$psock->close();
		$$psock = undef;
		$$psel = undef;

		$this->{running} = 0;
		$this->{command_time} = 0;
		$this->{reconnect_time} = time();
		return 0;
	}
	if (!$this->{running})
	{
		if ($this->{reconnect_time} &&
			time() > $this->{reconnect_time} + $RECONNECT_INTERVAL)
		{
			$this->{reconnect_time} = 0;
			warning($dbg,0,"AUTO RECONNECTING");
			$this->{started} = 1;
		}
		sleep(1);
		return 0;
	}
	return 1;
}


sub readSocket
{
	my ($this,$sock,$sel) = @_;

	my $buf;
	if ($sel->can_read(0.1))
	{
		recv($sock, $buf, 4096, 0);
		if ($buf)
		{
			$this->{buffer} .= $buf;
		}
	}

	if (length($this->{buffer}) > 2)
	{
		my $WITH_TEXT = 1;
		my $reply = parseNQPacket($WITH_TEXT,1,$NAVQUERY_PORT,$this->{buffer},$this);
			# 1=is_reply

		if ($WITH_TEXT)
		{
			my $text = $reply->{text};
			my $color = $UTILS_COLOR_LIGHT_BLUE;
			setConsoleColor($color) if $color;
			print $text;
			setConsoleColor() if $color;
			navQueryLog($text,'shark.log');
		}

		# EVENTS are not pushed onto the reply queue
		# Instead, they can generate additional API_GET_ITEM commands

		my $mods = $reply->{mods};
		if ($mods)
		{
			my $evt_mask = $reply->{evt_mask} || 0;
			for my $mod (@$mods)
			{
				my $hash_name = lc($NAV_WHAT{$mod->{what}}).'s';
				warning($dbg,1,sprintf(
					"MOD(%02x=%s) uuid(%s) bits(%02x) evt_mask(%08x)",
					$mod->{what},
					$hash_name,
					$mod->{uuid},
					$mod->{bits},
					$evt_mask));
				if ($mod->{bits} == 1)
				{
					my $hash = $this->{$hash_name};
					my $exists = $hash->{$mod->{uuid}};
					if ($exists)
					{
						warning($dbg,2,"deleting $hash_name($mod->{uuid}) $exists->{name}");
						delete $hash->{$mod->{uuid}};
						$this->incVersion();
					}
				}
				else
				{
					$this->queueNQCommand($API_GET_ITEM,$mod->{what},'event_item',$mod->{uuid},undef,undef)
						if $WITH_MOD_PROCESSING;
				}
			}
		}
		push @{$this->{replies}},$reply;
		$this->{buffer} = '';
		return 1;
	}

	return 0;
}


sub listenerThread
{
	my ($this) = @_;
    display($dbg,0,"starting listenerThread");

	# get NAVQRY ip:port

	my $rayport = findRayPortByName('NAVQRY');
	while (!$rayport)
	{
		display($dbg,1,"waiting for rayport(NAVQRY)");
		sleep(1);
		$rayport = findRayPortByName('NAVQRY');
	}
	$this->{nav_ip} = $rayport->{ip};
	$this->{nav_port} = $rayport->{port};
	display($dbg,1,"found rayport(NAVQRY) at $this->{nav_ip}:$this->{nav_port}");
	display($dbg,0,"starting listenerThread loop");

	my $sock;
	my $sel;
    while (1)
    {
		next if !$this->openSocket(\$sock,\$sel);
		next if $this->readSocket($sock,$sel) < 0;

		if (!$this->{busy} && @{$this->{command_queue}})
		{
			my $command = shift @{$this->{command_queue}};
			$this->{busy} = 1;
			
			display($dbg,0,"creating cmd_thread");
			my $cmd_thread = threads->create(\&commandThread,$this,$sock,$sel,$command);
			display($dbg,0,"nav_thread cmd_thread");
			$cmd_thread->detach();
			display($dbg,0,"cmd_thread detached");
		}
	}

}	# listenerThread



1;