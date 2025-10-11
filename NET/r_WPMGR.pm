#---------------------------------------------
# r_WPMGR.pm
#---------------------------------------------
# WPMGR is the Waypoints, Routes, and Groups manager service
#
# current status:
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


package r_WPMGR;
use strict;
use warnings;
use threads;
use threads::shared;
# use Socket;
# use IO::Select;
# use IO::Handle;
# use IO::Socket::INET;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use r_utils;
use r_RAYSYS;
use wp_parse;
use wp_packet;
use r_utils;
use base qw(tcpBase);


my $dbg = 0;


my $WITH_MOD_PROCESSING = 0;


my $COMMAND_TIMEOUT 		= 3;


our $DEFAULT_WPMGR_TCP_INPUT:shared 	= 0;
our $DEFAULT_WPMGR_TCP_OUTPUT:shared 	= 0;
our $SHOW_WPMGR_PARSED_INPUT:shared 	= 0;
our $SHOW_WPMGR_PARSED_OUTPUT:shared 	= 0;
                                  

my $DBG_WAIT = 1;


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

		startWPMGR
		$wpmgr

		$API_NONE
		$API_DO_QUERY
		$API_GET_ITEM
		$API_NEW_ITEM
		$API_DEL_ITEM
		$API_MOD_ITEM

		apiCommandName
		queueWPMGRCommand

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

		$SHOW_WPMGR_PARSED_INPUT
		$SHOW_WPMGR_PARSED_OUTPUT

	);
}


our $wpmgr:shared;


my $WPMGR_FUNC		= 0x000f;
	# 16 = 0xf0 == 'F000' in streams


our $ROUTE_COLOR_RED 	= 0;
our $ROUTE_COLOR_YELLOW = 1;
our $ROUTE_COLOR_GREEN	= 2;
our $ROUTE_COLOR_BLUE	= 3;
our $ROUTE_COLOR_PURPLE	= 4;
our $ROUTE_COLOR_BLACK	= 5;
our $NUM_ROUTE_COLORS   = 6;


my $out_color = $UTILS_COLOR_LIGHT_CYAN;
my $in_color = $UTILS_COLOR_LIGHT_BLUE;



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


sub startWPMGR
{
	my ($class) = @_;
	display($dbg,0,"startWPMGR($class)");
	my $this = $class->SUPER::new({
		rayname => 'WPMGR',
		local_port => $WPMGR_PORT,
		show_input  => $DEFAULT_WPMGR_TCP_INPUT,
		show_output => $DEFAULT_WPMGR_TCP_OUTPUT,
		in_color	=> $UTILS_COLOR_BROWN,
		out_color   => $UTILS_COLOR_LIGHT_CYAN,  });

	$this->{waypoints} = shared_clone({});
	$this->{routes} = shared_clone({});
	$this->{groups} = shared_clone({});
		# hashes of buffers by uuid, where the
		# buffer starts with the big_len

	$wpmgr = $this;
	$this->start();
}



sub queueWPMGRCommand
{
	my ($this,$api_command,$what,$name,$uuid,$data) = @_;
	$data ||= 0;
	display_hash($dbg+2,0,"queueWPCommand($this)",$this);
	
	return error("No 'this' in queueWPMGRCommand") if !$this;
	return error("Not started") if !$this->{started};
	return error("Not running") if !$this->{running};

	my $cmd_name = apiCommandName($api_command);

	if ($SHOW_WPMGR_PARSED_OUTPUT)
	{
		my $msg = "# queueWPMGRCommand($api_command=$cmd_name) what($what) name($name) uuid($uuid) data(".($data?length($data):'empty').")\n";
		print $msg;
		navQueryLog($msg,"shark.log");
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
		# params => $params });
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
		pack('v',$WPMGR_FUNC).
		($seq >= 0 ? pack('V',$seq) : '').
		$data;

	display($dbg+3,1,"msg=".unpack('H*',$msg));
	return $msg;
}


sub sendRequest
{
	my ($this,$seq,$name,$request) = @_;

	if ($SHOW_WPMGR_PARSED_OUTPUT)
	{
		my $text = "# sendRequest($seq) $name\n";
		my $rec = parseWPMGR($SHOW_WPMGR_PARSED_OUTPUT,0,$WPMGR_PORT,$request);
		$text .= $rec->{text};
		# 1=with_text, 0=is_reply		$text .= $rec->{text};
		setConsoleColor($out_color) if $out_color;
		print $text;
		setConsoleColor() if $out_color;
		navQueryLog($text,'shark.log');
	}

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
	# so I changed it to ffff (64K) for the index. Note that r_FILESYS
	# extends it even further to get 32M files via UDP.


sub update_item_request
{
	my ($this,$seq,$what,$name,$uuid,$request) = @_;
	my $what_name = $NAV_WHAT{$what};
	return 0 if !$this->sendRequest($seq,"$name $what_name",$request);
	my $reply = $this->waitReply(1);
	return 0 if !$reply;
	return error("No {item} in $name $what_name reply") if !$reply->{item};

	my $dbg_got = 1;
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
		createMsg($seq,$DIR_SEND,$CMD_CONTEXT,$what).
		createMsg($seq,$DIR_INFO,$CMD_CONTEXT,0,$dict_context).
		createMsg($seq,$DIR_INFO,$CMD_BUFFER,0,$dict_buffer).
		createMsg($seq,$DIR_INFO,$CMD_LIST,0,'00000000 00000000');

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
		$request = createMsg($seq,$DIR_SEND,$CMD_ITEM,$what,$uuid);
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
	print "do_query()\n";

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

	# check the name

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIR_SEND,$CMD_FIND,$what,name16_hex($name));
	return 0 if !$this->sendRequest($seq,"$what_name name must not exist",$request);
	return 0 if !$this->waitReply(-1);

	# check the uuid

	$seq = $this->{next_seqnum}++;
	$request = createMsg($seq,$DIR_SEND,$CMD_ITEM,$what,$uuid);
	return 0 if !$this->sendRequest($seq,"$what_name uuid must not exist",$request);
	return 0 if !$this->waitReply(-1);

	# create the item
	# These messages are sent separatly by RNS for groups

	$seq = $this->{next_seqnum}++;
	$request =
		createMsg($seq,$DIR_SEND,$CMD_MODIFY,	$what,	$uuid).
		createMsg($seq,$DIR_INFO,$CMD_CONTEXT,	0,		$uuid.'03000000').	#.'00000000').
		createMsg($seq,$DIR_INFO,$CMD_BUFFER,	0,		$data).
		createMsg($seq,$DIR_INFO,$CMD_LIST,		0,		'00000000 00000000'); # $uuid);

	return 0 if !$this->sendRequest($seq,"$name $what_name",$request);
	return 0 if !$this->waitReply(1);
	return 1;
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

	my $request;
	my $seq = $this->{next_seqnum}++;

	# MUST apparently do $CMD_EXIST before the $CMD_DATA
	
	$request = createMsg($seq,$DIR_SEND,$CMD_EXIST,$what,'07000000'.$uuid);	# '15000000'.$uuid);
	return 0 if !$this->sendRequest($seq,"modify1 $what_name",$request);
	return 0 if !$this->waitReply(1);

	# These messages are sent separatly by RNS for groups
	
	$seq = $this->{next_seqnum}++;
	$request =
		createMsg($seq,$DIR_SEND,$CMD_DATA,		$what,	'07000000'.$uuid).	# '15000000'.$uuid);
		createMsg($seq,$DIR_INFO,$CMD_CONTEXT,	0,		$uuid.'00000000').	#.'03000000').
		createMsg($seq,$DIR_INFO,$CMD_BUFFER,	0,		$data).
		createMsg($seq,$DIR_INFO,$CMD_LIST,		0,		$uuid);
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

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIR_SEND,$CMD_UUID,$what,$uuid);
	return 0 if !$this->sendRequest($seq,"delete $what_name",$request);
	return 0 if !$this->waitReply(1);

	my $hash_name = lc($what_name)."s";
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


	my $request = createMsg($seq,$DIR_SEND,$CMD_ITEM,$what,$uuid);
	return $this->update_item_request($seq,$what,'get',$uuid,$request);
}



sub handleCommand
{
	my ($this,$command) = @_;
	my $api_command = $command->{api_command};
	my $cmd_name = apiCommandName($api_command);
	display($dbg,0,"$this->{rayname} handleCommand($api_command=$cmd_name) started");

	my $rslt;

	$rslt = $this->get_item($command) 		if $api_command == $API_GET_ITEM;
	$rslt = $this->do_query($command) 		if $api_command == $API_DO_QUERY;
	$rslt = $this->create_item($command) 	if $api_command == $API_NEW_ITEM;
	$rslt = $this->delete_item($command) 	if $api_command == $API_DEL_ITEM;
	$rslt = $this->modify_item($command) 	if $api_command == $API_MOD_ITEM;

	error("API $cmd_name failed") if !$rslt;

	$this->{command_rslt} = $rslt;
	$this->{busy} = 0;
		# Note to self.  I used to pull the command off the queue and use
		# {command} as the busy indicator, then set it to '' here.
		# But I believe that I once again ran into a Perl weirdness
		# that Perl will crash (during garbage collection) if you
		# re-assign a a shared reference to a scalar.
		
	display($dbg,0,"$this->{rayname} handleCommand($api_command=$cmd_name) finished");
}




#========================================================================
# overriden tcpBase methods
#========================================================================


sub handlePacket
{
	my ($this,$buffer) = @_;

	warning($dbg+1,0,"handlePacket(".length($buffer).") called");

	my $reply = parseWPMGR($SHOW_WPMGR_PARSED_INPUT,1,$WPMGR_PORT,$buffer);
		# 1=is_reply

	if ($SHOW_WPMGR_PARSED_INPUT)
	{
		my $text = $reply->{text};
		setConsoleColor($in_color);
		print $text;
		setConsoleColor() if $in_color;
		navQueryLog($text,'shark.log');
	}

	# EVENTS are not pushed onto the reply queue
	# Instead, they can generate additional API_GET_ITEM commands

	if ($WITH_MOD_PROCESSING)
	{
		my $mods = $reply->{mods};
		# delete $reply->{mods} if $mods;
		if ($mods && !$reply->{item})
		{
			warning($dbg+1,1,"found ".scalar(@$mods)." mods");
			my $evt_mask = $reply->{evt_mask} || 0;
			for my $mod (@$mods)
			{
				my $hash_name = lc($NAV_WHAT{$mod->{what}}).'s';
				warning($dbg+1,2,sprintf(
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
						warning($dbg,2,"deleting $hash_name($mod->{uuid}) $exists->{name}");
						delete $hash->{$mod->{uuid}};
						$this->incVersion();
					}
				}
				else	# enque a GET_ITEM command for th emod
				{
					warning($dbg,0,"enquing mod($mod->{what}) uuid($mod->{uuid})");
					$this->queueWPMGRCommand($API_GET_ITEM,$mod->{what},'mod_item',$mod->{uuid},undef,undef);
				}

			}	# for each mod
		}	# $mods
	}	# $WITH_MOD_PROCESSING

	return $reply;

}






1;