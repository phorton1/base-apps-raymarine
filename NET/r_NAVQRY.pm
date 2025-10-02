#---------------------------------------------
# r_NEWQRY.pm
#---------------------------------------------
# state of affairs:
#
# Can create and delete Waypoints, Routes, and Groups.
# Deleting a Group with Waypoints in it, moves them to My Waypoints.
# - Cannot delete a Waypoint in a Group
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
use r_parse;
use r_utils;

my $dbg = -1;
my $dbg_wait = 0;

my $COMMAND_TIMEOUT 		= 3;
my $REFRESH_INTERVAL		= 5;
my $RECONNECT_INTERVAL		= 15;

my $SHOW_OUTPUT = 0;
my $SHOW_INPUT = 0;
my $DBG_WAIT = 1;

# my $SUCCESS_SIG = '00000400';
# my $DICT_END_RECORD_MARKER	= '10000202';


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		startNavQuery
		getNavQuery
		doNavQuery
		
		createWaypoint
		deleteWaypoint

		createRoute
		deleteRoute
		routeWaypoint

		setWaypointGroup
		createGroup
		deleteGroup

    );
}


my $API_NONE 			= 0;
my $API_DO_QUERY		= 1;
my $API_GET_ITEM		= 2;
my $API_CREATE_ITEM 	= 3;
my $API_DELETE_ITEM 	= 4;
my $API_MODIFY_ITEM		= 5;



my $NAVQRY_FUNC		= 0x000f;
	# F000 in streams

# WCDD = 0xDDWC

my $DIR_RECV	= 0x000;
my $DIR_SEND	= 0x100;
my $DIR_INFO	= 0x200;

my $WHAT_WAYPOINT	= 0x00;
my $WHAT_ROUTE		= 0x40;
my $WHAT_GROUP		= 0x80;
my $WHAT_DATABASE	= 0xb0;

my $CMD_CONTEXT		= 0x0;
my $CMD_BUFFER    	= 0x1;
my $CMD_LIST     	= 0x2;
my $CMD_ITEM		= 0x3;
my $CMD_EXIST		= 0x4;
my $CMD_EVENT     	= 0x5;
my $CMD_DATA		= 0x6;
my $CMD_MODIFY    	= 0x7;
my $CMD_DELETE      = 0x8;
my $CMD_COUNT     	= 0x9;
my $CMD_AVERB     	= 0xa;
my $CMD_BVERB     	= 0xb;
my $CMD_FIND		= 0xc;
my $CMD_SPACE     	= 0xd;
my $CMD_EVERB    	= 0xe;
my $CMD_FVERB     	= 0xf;

my $STD_WP_UUIDS = [
	'aaaaaaaaaaaaaaaa',
	'bbbbbbbbbbbbbbbb',
	'cccccccccccccccc',
	'dddddddddddddddd', ];

my $STD_ROUTE_UUID = 'eeeeeeeeeeee{int}';
my $STD_GROUP_UUID = 'eeeeeeeeeeef{int}';

my $STD_WP_DATA = {
	# length dword that follows seq_num was 47000000 for all of these
	aaaaaaaaaaaaaaaa =>
		'47000000'.
		'9e449005 ecdbface c16a9f06 ad4a84c5 00000000 00000000 00000000'.
		'02010030 010000ef dc000088 4f000d0a 00000000 74657374 57617970'.
		'6f696e74 31777043 6f6d6d65 6e7431',

		# '32000000'.
		# '02e49705 078af5ce d392a806 dff17dc5 00000000 00000000 00000000'.
		# '02ffffff ffffff71 1c010088 4f000200 00000000 5770',

	bbbbbbbbbbbbbbbb =>
		'47000000'.
		'2fd08605 e09100cf ba0f9406 da1a8bc5 00000000 00000000 00000000'.
		'02010030 010000f0 dc000088 4f000d0a 00000000 74657374 57617970'.
		'6f696e74 32777043 6f6d6d65 6e7432',
	cccccccccccccccc =>
		'47000000'.
		'44558405 84b501cf 41159106 cb768cc5 00000000 00000000 00000000'.
		'02010030 010000f0 dc000088 4f000d0a 00000000 74657374 57617970'.
		'6f696e74 33777043 6f6d6d65 6e7433',
	dddddddddddddddd =>
		'47000000'.
		'30658305 ca4b02cf f5f48f06 142a8dc5 00000000 00000000 00000000'.
		'02010030 010000f1 dc000088 4f000d0a 00000000 74657374 57617970'.
		'6f696e74 34777043 6f6d6d65 6e7434', };

my $SUCCESS_SIG = '00000400';
my $DICT_END_RECORD_MARKER	= '10000202';

my $ROUTE_COLOR_RED 	= 0;
my $ROUTE_COLOR_YELLOW 	= 1;
my $ROUTE_COLOR_GREEN	= 2;
my $ROUTE_COLOR_BLUE	= 3;
my $ROUTE_COLOR_PURPLE	= 4;
my $ROUTE_COLOR_BLACK	= 5;
	# red, yellow, green, blue, purple, black



my $self:shared;

sub getNavQuery
{
	return $self;
}

sub apiCommandName
{
	my ($cmd) = @_;
	return 'DO_QUERY' 	 if $cmd == $API_DO_QUERY;
	return 'GET_ITEM'	 if $cmd == $API_GET_ITEM;
	return 'CREATE_ITEM' if $cmd == $API_CREATE_ITEM;
	return 'DELETE_ITEM' if $cmd == $API_DELETE_ITEM;
	return 'MODIFY_ITEM' if $cmd == $API_MODIFY_ITEM;
	return "UNKNOWN API COMMAND";
}

#---------------------
# param massages
#---------------------

sub std_uuid
{
	my ($template,$int) = @_;
	my $pack = pack('v',$int);
	my $hex = unpack('H4',$pack);
	$template =~ s/{int}/$hex/;
	return $template;
}

sub name16_hex
	# return hex representation of max16 name + null
{
	my ($name,$opt_end) = @_;
	while (length($name) < 16) { $name .= "\x00" }
	$name .= $opt_end ? pack('H*',$opt_end) : "\x00";
	return unpack('H*',$name);
}


#--------------------------------------
# API
#--------------------------------------

sub startNavQuery
{
	my ($class) = @_;
	display(0,0,"initing $class");
	my $this = shared_clone({});
	bless $this,$class;
	$this->{started} = 1;
	$this->{running} = 0;
	$this->{next_seqnum} = 1;
	$this->{command_queue} = shared_clone([]);
	$this->{waypoints} = shared_clone({});
	$this->{routes} = shared_clone({});
	$this->{groups} = shared_clone({});
		# hashes of buffers by uuid, where the
		# buffer starts with the big_len

	$self = $this;

	display(0,0,"creating listen_thread");
    my $listen_thread = threads->create(\&listenerThread,$this);
    display(0,0,"listen_thread created");
    $listen_thread->detach();
    display(0,0,"listen_thread detached");
}


sub showCommand
{
	my ($msg) = @_;

	$msg = "\n\n".
		"#------------------------------------------------------------------\n".
		"# $msg\n".
		"#------------------------------------------------------------------\n\n";
	print $msg;
	navQueryLog($msg,'shark.log');
}



sub doNavQuery
{
	showCommand("doNavQuery()");
	return queue_command($self,$API_DO_QUERY,0,0,0,undef);
}


sub createWaypoint
{
	my ($wp_num) = @_;
	showCommand("createWaypoint($wp_num)");
	my $uuid = $STD_WP_UUIDS->[$wp_num-1];
	my $name = "testWaypoint$wp_num";
	my $data = $STD_WP_DATA->{$uuid};
	return queue_command($self,$API_CREATE_ITEM,$WHAT_WAYPOINT,$name,$uuid,$data);
}

sub deleteWaypoint
{
	my ($wp_num) = @_;
	showCommand("deleteWaypoint($wp_num)");
	my $uuid = $STD_WP_UUIDS->[$wp_num-1];
	my $name = "testWaypoint$wp_num";
	return queue_command($self,$API_DELETE_ITEM,$WHAT_WAYPOINT,$name,$uuid,undef);
}


sub createRoute
{
	my ($route_num,$bits) = @_;
	$bits |= 0;
	showCommand("createRoute($route_num) bits($bits)");
	my $uuid = std_uuid($STD_ROUTE_UUID,$route_num);
	my $name = "testRoute$route_num";
	my $data = emptyRoute($name,$uuid,$bits); # ,$STD_WP_UUIDS->[0]);
	return queue_command($self,$API_CREATE_ITEM,$WHAT_ROUTE,$name,$uuid,$data);
}

sub deleteRoute
{
	my ($route_num) = @_;
	showCommand("deleteRoute($route_num)");
	my $uuid = std_uuid($STD_ROUTE_UUID,$route_num);
	my $name = "testRoute$route_num";
	return queue_command($self,$API_DELETE_ITEM,$WHAT_ROUTE,$name,$uuid,undef);
}

sub routeWaypoint
{
	my ($route_num,$wp_num,$add) = @_;
	showCommand("outeWaypoint($route_num) wp_num($wp_num) add($add)");

	my $uuid = std_uuid($STD_ROUTE_UUID,$route_num);
	my $wp_uuid = $STD_WP_UUIDS->[$wp_num-1];
	my $name = "testRoute$route_num";

	my $data = emptyRoute($name,$uuid,$wp_uuid);

	# my $old_data = $self->{routes}->{$uuid};
	# return error("Could not find this->route->($uuid)") if !$old_data;
	# my $data = modifyRoute($old_data,$wp_uuid,$add);
	# return if !$data;

	return queue_command($self,$API_MODIFY_ITEM,$WHAT_ROUTE,$name,$uuid,$data);
}

sub createGroup
{
	my ($group_num) = @_;
	showCommand("createGroup($group_num)");
	my $uuid = std_uuid($STD_GROUP_UUID,$group_num);
	my $name = "testGroup$group_num";
	my $data = emptyGroup($name);
	return queue_command($self,$API_CREATE_ITEM,$WHAT_GROUP,$name,$uuid,$data);
}

sub deleteGroup
{
	my ($group_num) = @_;
	showCommand("deleteGroup($group_num)");
	my $uuid = std_uuid($STD_GROUP_UUID,$group_num);
	my $name = "testGroup$group_num";
	return queue_command($self,$API_DELETE_ITEM,$WHAT_GROUP,$name,$uuid,undef);
}


sub commandBusy
{
	my ($this) = @_;
	return $this->{command} || @{$this->{command_queue}} ? 1 : 0;
}


sub getWaypointRecord
{
	my ($this,$uuid) = @_;
	my $data = $this->{waypoints}->{$uuid};
	return error("could not getWaypointRecord($uuid)") if !$data;
	my $rec = shared_clone({});
	parseNavQueryWaypointBuffer($data,0,$rec);
	return $rec;
}



sub wait_queue_command
{
	my ($this,@params) = @_;
	$this->queue_command(@params);
	while ($this->commandBusy())
	{
		display_hash(0,0,"wait_queue_command",$this);
		sleep(1);
	}
	error("wait_queue_command failed") if !$this->{command_rslt};
	display(0,0,"wait_queue_command returning $this->{command_rslt}");
	return $this->{command_rslt};
}


sub setWaypointGroup
	# 0 = My Waypoints
	# This introduces the need for a list of atomic commands per
	# high level API command and a real desire to keep "records"
	# instead of buffers, as the hash elements.
	#
	# 	get the waypoint, see if it's already in a group
	#	- remove it from the old group if it is in one
	#   - add it to the new group if it's not My Waypoints
	
{
	my ($wp_num,$group_num) = @_;
	showCommand("setWaypointGroup($wp_num) group_num($group_num)");

	my $wp_uuid = $STD_WP_UUIDS->[$wp_num-1];
	my $wp_name = "testWaypoint$wp_num";
	my $group_name = $group_num ? "testGroup$group_num" : 'My Waypoints';
	my $group_uuid = $group_num ? std_uuid($STD_GROUP_UUID,$group_num) : '';

	return if !$self->wait_queue_command($API_GET_ITEM,$WHAT_WAYPOINT,$wp_name,$wp_uuid,undef);
	my $wp = $self->getWaypointRecord($wp_uuid);
	display_hash(0,0,"got waypoint",$wp);
	return;
	
	# requires a query, first, at this time
	my $data;


	if ($group_num)
	{
		my $old_data = $self->{groups}->{$group_uuid};
		return error("Could not find this->groups->($group_uuid)") if !$old_data;
		my $group_rec = {};
		parseNavQueryGroupBuffer($old_data,0,$group_rec);
		push @{$group_rec->{uuids}},$wp_uuid;
		$data = groupRecordToBuffer($group_rec);
	}

	return queue_command($self,$API_MODIFY_ITEM,$WHAT_GROUP,$group_name,$group_uuid,$data);
}



sub queue_command
{
	my ($this,$api_command,$what,$name,$uuid,$data,$params) = @_;
	return error("No 'this' in queue_command") if !$this;
	return error("Not started") if !$this->{started};
	return error("Not running") if !$this->{running};

	my $cmd_name = apiCommandName($api_command);
	my $msg = "# queue_command($api_command=$cmd_name) what($what) name($name) uuid($uuid) data(".($data?length($data):'empty').")\n";
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
# commandThread support
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
	$text .= parseNavPacket(0,$NAVQUERY_PORT,$request);

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

	display($dbg_wait+1,0,"waitReply($seq) $name");

	while ($this->{started})
	{
		my $replies = $this->{replies};
		if (@$replies)
		{
			my $reply = shift @$replies;
			my $got_seq = unpack('V',substr($reply,6,4));
			display($dbg_wait+1,1,"got_seq($got_seq)");
			if ($got_seq == $seq)
			{
				if ($expect_success)
				{
					my $sig = unpack('H*',substr($reply,10,4));
					my $cmp = $sig eq $SUCCESS_SIG ? 1 : -1;
					if ($cmp != $expect_success)
					{
						error("waitReply($seq) expect($expect_success) SUCCESS_SIG vs got($sig)");
						return 0;
					}
				}

				display($dbg_wait,1,"waitReply() returning ".length($reply)." bytes");
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

	return '';
}


sub parseDict
{
	my ($reply,$what_name) = @_;
	display(0,0,"parseDict($what_name)");
	my $offset = 14 + 22;	# offset to the BUFFER message within reply
	$offset += 14;			# offset to the uuid count in the BUFFER message
	my $num_s = substr($reply,$offset,4);
	my $num = unpack('V',$num_s);
	display(0,1,"found ".unpack('H*',$num_s)."=$num $what_name uuids");
	$offset += 4;			# pointing at first uuid

	my @uuids;
	for (my $i=0; $i<$num; $i++)
	{
		my $uuid = unpack('H*',substr($reply,$offset,8));
		display($dbg,1,pad($offset,5).pad(" uuid($i)",10)."= $uuid");
		push @uuids,$uuid;
		$offset += 8;
	}
	return \@uuids;
}



sub groupRecordToBuffer
{
	my ($rec) = @_;
	display_hash(0,0,"groupRecordToBuffer",$rec);
	my $name_len = length($rec->{name});
	my $cmt_len = $rec->{comment} ? length($rec->{comment}) : 0;
	my $uuids = $rec->{uuids};
	my $num_uuids = @$uuids;
	
	my $buffer = '';
	$buffer .= pack('C',$name_len);
	$buffer .= pack('C',$cmt_len);
	$buffer .= pack('v',$num_uuids);
	$buffer .= $rec->{name};
	$buffer .= $rec->{comment} if $cmt_len;
	for my $uuid (@$uuids)
	{
		$buffer .= pack('H*',$uuid);
	}
	$buffer = pack('V',length($buffer)).$buffer;
	
	my $hex_buffer = unpack('H*',$buffer);
	display(0,0,"groupRecordToBuffer=$hex_buffer");
	display(0,1,parseNavQueryGroupBuffer($buffer,20));
	return $hex_buffer;

										   
}


sub emptyGroup
{
	my ($name) = @_;
	my $name_len = length($name);

	my $HDR1_SIZE = 8;
	my $big_len = $HDR1_SIZE + $name_len + 8 + 8; 	# 8 for the self uuid, and 8 for wp uuid
	my $buffer = pack('V',$big_len);

	$buffer .= pack('C',$name_len);		# name_len
	$buffer .= pack('C',0);				# cmt_len
	$buffer .= pack('v',0);				# num_uuids
	$buffer .= $name;

	display(0,0,"emptyGroup($name) biglen($big_len) length=".length($buffer));
	my $ret_hex = unpack('H*',$buffer);
	# print "emptyGroup = ".$ret_hex."\n";
	return $ret_hex;
}


my $next_color:shared = 0;

sub emptyRoute
{
	my ($name,$self_uuid,$bits,$wpt_uuid) = @_;
	$bits = 0 if !defined($bits);
	my $name_len = length($name);
	
	my $NUM_WPTS = $wpt_uuid ? 1 : 0;
	
	my $HDR1_SIZE = 8;
	my $HDR2_SIZE = 46;
	my $big_len = $HDR1_SIZE + $HDR2_SIZE + $name_len + 8; 	# 8 for the single waypoint uuid
	my $latlon = pack('H*','9e449005ecdbface');		# two dwords = 8 bytes
	my $buffer = pack('V',$big_len);

	# hdr1
	$buffer .= pack('v',0);				# u1_0
	$buffer .= pack('C',$name_len);		# name_len
	$buffer .= pack('C',0);				# cmt_len
	$buffer .= pack('v',$NUM_WPTS);		# num_wpts
	$buffer .= pack('C',$bits);			# '05');			# u2_05
		# Changing this from 05 to 00 caused the routes to be persistent
		# and not overwrite themselves.
		#
		# 1 = appears to be something like "temporary current route"
		#     and re-uses the top 'slot' on the E80 and doesnt show in RNS
		# 2 = appears to be something like "don't transfer to rns"
		#
		# In any case, the bits are persistent.
		
	my $color = $next_color++ % 6;
	$buffer .= pack('C',$color);		# color byte

	# name and no uuids
	$buffer .= $name;
	$buffer .= pack('H*',$wpt_uuid) if $NUM_WPTS;

	my $zero_uuid = '0000000000000000';

	# hdr2
	$buffer .= $latlon;					# start
	$buffer .= $latlon;					# end
	$buffer .= pack('H*','00000000');	# distance

	$buffer .= pack('H*','02000000'); 	# 02000000');	# u4_0200
	$buffer .= pack('H*','00000000');	# b8975601');	# u5 = b8975601 data? end marker?	$buffer .= pack('H*',$self_uuid);	# u6_self
	$buffer .= pack('H*',$self_uuid);	# u7_self
	$buffer .= pack('H*','0000');		# 1234, 7856, 181d'		# u8  = 'H4';


	if ($NUM_WPTS)
	{
		$buffer .= pack('H*','0000');		# p_u0_0
		$buffer .= pack('H*','0000');		# p_depth
		$buffer .= pack('H*','00000000');	# p_u1_0
		$buffer .= pack('H*','0000');		# p_sym
	}
	
	display(0,0,"emptyRoute($name) biglen($big_len) length=".length($buffer));
	my $ret_hex = unpack('H*',$buffer);
	# print "emptyRoute = ".$ret_hex."\n";
	return $ret_hex;
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


sub query_one
{
	my ($this,$sock,$sel,$what) = @_;
	my $what_name = $NAV_WHAT{$what};
	display(0,0,"query_one($what_name)");

	my $seq = $this->{next_seqnum}++;
	my $request =
		createMsg($seq,$DIR_SEND,$CMD_CONTEXT,$what).
		createMsg($seq,$DIR_INFO,$CMD_CONTEXT,0,$dict_context).
		createMsg($seq,$DIR_INFO,$CMD_BUFFER,0,$dict_buffer).
		createMsg($seq,$DIR_INFO,$CMD_LIST,0,'00000000 00000000');

	return 0 if !$this->sendRequest($sock,$sel,$seq,"$what_name DICT",$request);
	my $reply = $this->waitReply(1);
	return 0 if !$reply;
	my $uuids = parseDict($reply,$what_name);

	my $num = 0;
	for my $uuid (@$uuids)
	{
		$seq = $this->{next_seqnum}++;
		$request = createMsg($seq,$DIR_SEND,$CMD_ITEM,$what,$uuid);

		my $ok = 1;
		$this->{NAVQRY_HASH} = lc($what_name)."s";
		$this->{NAVQRY_UUID} = $uuid;
		$ok ||= $this->sendRequest($sock,$sel,$seq,"$what_name ITEM($num)",$request);
		$ok ||= $this->waitReply(1);
		$this->{NAVQRY_HASH} = '';
		$this->{NAVQRY_UUID} = '';
		return 0 if !$ok;

		display(0,1,"keys($this->{NAVQRY_HASH}) = ".join(" ",keys %{$this->{$this->{NAVQRY_HASH}}} ));
		$num++;
	}

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
	# $this->{NAVQRY_HASH} = lc($what_name)."s";
	# $this->{NAVQRY_UUID} = $uuid;
	
	display($dbg,0,"create_item($what=$what_name) $uuid $name");

	# check the name

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIR_SEND,$CMD_FIND,$what,name16_hex($name));
	return 0 if !$this->sendRequest($sock,$sel,$seq,"$what_name name must not exist",$request);
	return 0 if !$this->waitReply(-1);

	# check the uuid

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

	return 0 if !$this->sendRequest($sock,$sel,$seq,"create $what_name",$request);
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
	# $this->{NAVQRY_HASH} = lc($what_name)."s";
	# $this->{NAVQRY_UUID} = $uuid;

	display($dbg,0,"modify_item($what=$what_name) $uuid $name");
	display($dbg,1,"data=".unpack('H*',$data));

	# These messages are sent separatly by RNS for groups

	my $request;
	my $seq = $this->{next_seqnum}++;

	# MUST apparently do $CMD_EXIST before the $CMD_DATA
	
	$request = createMsg($seq,$DIR_SEND,$CMD_EXIST,$what,'07000000'.$uuid);	# '15000000'.$uuid);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"modify1 $what_name",$request);
	return 0 if !$this->waitReply(1);

	$seq = $this->{next_seqnum}++;
	$request = createMsg($seq,$DIR_SEND,$CMD_DATA,		$what,	'07000000'.$uuid);	# '15000000'.$uuid);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"modify1 $what_name",$request);

	$request = createMsg($seq,$DIR_INFO,$CMD_CONTEXT,	0,		$uuid.'03000000');	#.'00000000').
	return 0 if !$this->sendRequest($sock,$sel,$seq,"modify2 $what_name",$request);

	$request = createMsg($seq,$DIR_INFO,$CMD_BUFFER,	0,		$data);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"modify3 $what_name",$request);

	$request = createMsg($seq,$DIR_INFO,$CMD_LIST,		0,		$uuid);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"modify4 $what_name",$request);
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
	my $request = createMsg($seq,$DIR_SEND,$CMD_DELETE,$what,$uuid);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"delete $what_name",$request);
	return 0 if !$this->waitReply(1);

	my $hash_name = lc($what_name)."s";
	delete $this->{$hash_name}->{$uuid};

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

	my $ok = 1;
	$this->{NAVQRY_HASH} = lc($what_name)."s";
	$this->{NAVQRY_UUID} = $uuid;
	$ok = 0 if !$this->sendRequest($sock,$sel,$seq,"GET $what_name $uuid",$request);
	$ok = 0 if $ok && !$this->waitReply(1);
	$this->{NAVQRY_HASH} = '';
	$this->{NAVQRY_UUID} = '';

	display(0,0,"get_item returning $ok");
	return $ok;
}



sub commandThread
{
	my ($this,$sock,$sel) = @_;
	my $command = $this->{command};
	my $api_command = $command->{api_command};
	my $cmd_name = apiCommandName($api_command);
	display(0,0,"commandThread($api_command=$cmd_name) started");

	my $rslt;

	$rslt = $this->get_item($sock,$sel,$command) 		if $api_command == $API_GET_ITEM;
	$rslt = $this->do_query($sock,$sel,$command) 		if $api_command == $API_DO_QUERY;
	$rslt = $this->create_item($sock,$sel,$command) 	if $api_command == $API_CREATE_ITEM;
	$rslt = $this->delete_item($sock,$sel,$command) 	if $api_command == $API_DELETE_ITEM;
	$rslt = $this->modify_item($sock,$sel,$command) 	if $api_command == $API_MODIFY_ITEM;

	error("API $cmd_name failed") if !$rslt;

	$this->{command_rslt} = $rslt;
	$this->{command} = '';
	display(0,0,"commandThread($api_command=$cmd_name) finished");
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

			$this->{reply} = '';
			$this->{replies} = shared_clone([]);
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
		warning(0,0,"closing navQuerySocket");
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


sub readBuf
{
	my ($this,$sock,$sel) = @_;

	my $buf;
	if ($sel->can_read(0.1))
	{
		recv($sock, $buf, 4096, 0);
		if ($buf)
		{
			$this->{reply} .= $buf;
		}
	}

	if (length($this->{reply}) > 2)
	{
		push @{$this->{replies}},$this->{reply};

		my $text = parseNavPacket(1,$NAVQUERY_PORT,$this->{reply},$this);
		my $color = $UTILS_COLOR_LIGHT_BLUE;
		setConsoleColor($color) if $color;
		print $text;
		setConsoleColor() if $color;
		navQueryLog($text,'shark.log');
		
		$this->{reply} = '';
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
		next if $this->readBuf($sock,$sel) < 0;

		if (!$this->{command} && @{$this->{command_queue}})
		{
			$this->{command} = shift @{$this->{command_queue}};
			
			display(0,0,"creating cmd_thread");
			my $cmd_thread = threads->create(\&commandThread,$this,$sock,$sel);
			display(0,0,"nav_thread cmd_thread");
			$cmd_thread->detach();
			display(0,0,"cmd_thread detached");
		}
	}

}	# listenerThread



1;