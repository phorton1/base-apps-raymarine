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

sendEverb
listDatabase
database

		
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
my $API_CREATE_ITEM 	= 2;
my $API_DELETE_ITEM 	= 3;
my $API_MODIFY_ITEM		= 4;
# my $API_WAYPOINT_GROUP  = 5;

my $API_LIST_DATABASE   = 94;
my $API_EVERB			= 85;
my $API_DATABASE		= 96;



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
	$this->{command} = 0;
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



sub doNavQuery
{
	display(0,0,"doNavQuery()");
	return init_command($self,$API_DO_QUERY,0,0,0,undef);
}

sub listDatabase
{
	display(0,0,"listDatabase");
	return init_command($self,$API_LIST_DATABASE);
}
sub sendEverb
{
	display(0,0,"sendEverb");
	return init_command($self,$API_EVERB);
}
sub database
{
	display(0,0,"database");
	return init_command($self,$API_DATABASE);
}



sub createWaypoint
{
	my ($wp_num) = @_;
	display(0,0,"createWaypoint($wp_num)");
	my $uuid = $STD_WP_UUIDS->[$wp_num-1];
	my $name = "testWaypoint$wp_num";
	my $data = $STD_WP_DATA->{$uuid};
	return init_command($self,$API_CREATE_ITEM,$WHAT_WAYPOINT,$name,$uuid,$data);
}

sub deleteWaypoint
{
	my ($wp_num) = @_;
	display(0,0,"deleteWaypoint($wp_num)");
	my $uuid = $STD_WP_UUIDS->[$wp_num-1];
	my $name = "testWaypoint$wp_num";
	return init_command($self,$API_DELETE_ITEM,$WHAT_WAYPOINT,$name,$uuid,undef);
}


sub createRoute
{
	my ($route_num) = @_;
	display(0,0,"createRoute($route_num)");
	my $uuid = std_uuid($STD_ROUTE_UUID,$route_num);
	my $name = "testRoute$route_num";
	my $data = emptyRoute($name,$uuid);
	return init_command($self,$API_CREATE_ITEM,$WHAT_ROUTE,$name,$uuid,$data);
}

sub deleteRoute
{
	my ($route_num) = @_;
	display(0,0,"deleteRoute($route_num)");
	my $uuid = std_uuid($STD_ROUTE_UUID,$route_num);
	my $name = "testRoute$route_num";
	return init_command($self,$API_DELETE_ITEM,$WHAT_ROUTE,$name,$uuid,undef);
}

sub routeWaypoint
{
	my ($route_num,$wp_num,$add) = @_;
	display(0,0,"routeWaypoint($route_num) wp_num($wp_num) add($add)");

	my $uuid = std_uuid($STD_ROUTE_UUID,$route_num);
	my $wp_uuid = $STD_WP_UUIDS->[$wp_num-1];
	my $name = "testRoute$route_num";

	my $data = emptyRoute($name,$uuid,$wp_uuid);

	# my $old_data = $self->{routes}->{$uuid};
	# return error("Could not find this->route->($uuid)") if !$old_data;
	# my $data = modifyRoute($old_data,$wp_uuid,$add);
	# return if !$data;

	return init_command($self,$API_MODIFY_ITEM,$WHAT_ROUTE,$name,$uuid,$data);
}

sub createGroup
{
	my ($group_num) = @_;
	display(0,0,"createGroup($group_num)");
	my $uuid = std_uuid($STD_GROUP_UUID,$group_num);
	my $name = "testGroup$group_num";
	my $data = emptyGroup($name);
	return init_command($self,$API_CREATE_ITEM,$WHAT_GROUP,$name,$uuid,$data);
}

sub deleteGroup
{
	my ($group_num) = @_;
	display(0,0,"deleteGroup($group_num)");
	my $uuid = std_uuid($STD_GROUP_UUID,$group_num);
	my $name = "testGroup$group_num";
	return init_command($self,$API_DELETE_ITEM,$WHAT_GROUP,$name,$uuid,undef);
}

#	sub setWaypointGroup
#		# 0 = My Waypoints
#	{
#		my ($wp_num,$group_num) = @_;
#		display(0,0,"setWaypointGroup($wp_num) group_num($group_num)");
#		return init_command($self,$API_WAYPOINT_GROUP,$wp_num,0,$group_num);
#	}

sub init_command
{
	my ($this,$command,$what,$name,$uuid,$data) = @_;
	return error("No 'this' in init_command") if !$this;
	return error("Not started") if !$this->{started};
	return error("Not running") if !$this->{running};
	return error("BUSY WITH COMMAND($this->{command})") if $this->{command};
	return error("BUSY WITH PENDING COMMAND($this->{pending_command})") if $this->{pending_command};

	print "-----------------------------------------------------------------\n";
	print "init_command($command) what($what) name($name) uuid($uuid) data(".($data?length($data):'empty').")\n";
	print "-----------------------------------------------------------------\n";
	$this->{what} = $what;
	$this->{name} = $name;
	$this->{uuid} = $uuid;
	$this->{data} = $data;
	$this->{command} = $command;
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

	display($dbg,0,"sendRequest($seq) $name");
	my $text = parseNavPacket(0,$NAVQUERY_PORT,$request);

	my $color = $UTILS_COLOR_LIGHT_CYAN;
	setConsoleColor($color) if $color;
	print $text;
	setConsoleColor() if $color;

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

	navQueryLog($text);
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



sub emptyRoute
	# This method returns the $data for a empty route buffer with
	# the given name (no waypoints or pts). It will use the lat/lon
	# copied from the 0th standard waypoint, and the passed in uuid
	# or 00000000 00000000
	#
	# The leading dword(big_len) will be prepended  at the end
	#
	# that worked.
	# gonna try a route with no waypoints
{
	my ($name) = @_;
	my $name_len = length($name);
	
	my $HDR1_SIZE = 8;
	my $HDR2_SIZE = 46;
	my $big_len = $HDR1_SIZE + $HDR2_SIZE + $name_len + 8; 	# 8 for the single waypoint uuid
	my $latlon = pack('H*','9e449005ecdbface');		# two dwords = 8 bytes
	my $buffer = pack('V',$big_len);

	# hdr1
	$buffer .= pack('v',0);				# u1_0
	$buffer .= pack('C',$name_len);		# name_len
	$buffer .= pack('C',0);				# cmt_len
	$buffer .= pack('v',0);				# num_wpts
	$buffer .= pack('H*','05');			# u2_05
	$buffer .= pack('C',$ROUTE_COLOR_PURPLE);		# color byte

	# name and no uuids
	$buffer .= $name;

	my $zero_uuid = '0000000000000000';

	# hdr2
	$buffer .= $latlon;					# start
	$buffer .= $latlon;					# end
	$buffer .= pack('H*','00000000');	# distance
	$buffer .= pack('H*','02000000');	# u4_0200
	$buffer .= pack('H*','00000000');	# u5 = b8975601 data? end marker?
	$buffer .= pack('H*',$zero_uuid);	# u6_self
	$buffer .= pack('H*',$zero_uuid);	# u7_self
	$buffer .= pack('H*','0000');		# 'H4';

	# no pointa
	#	if ($NUM_WPTS)
	#	{
	#		$buffer .= pack('H*','0000');		# p_u0_0
	#		$buffer .= pack('H*','0000');		# p_depth
	#		$buffer .= pack('H*','00000000');	# p_u1_0
	#		$buffer .= pack('H*','0000');		# p_sym
	#	}
	
	display(0,0,"emptyRoute($name) biglen($big_len) length=".length($buffer));
	my $ret_hex = unpack('H*',$buffer);
	# print "emptyRoute = ".$ret_hex."\n";
	return $ret_hex;
}


sub modifyRoute
{
	my ($buffer,$wp_uuid,$add) = @_;
	display(0,0,"modifyRoute($wp_uuid) add($add)");
	display(0,1,"buffer=".unpack('H*',$buffer));

	my $offset = 0;
	my $big_len = unpack('V',substr($buffer,$offset,4));
	$offset += 4;
	my $skip_word = substr($buffer,$offset,2);
	$offset += 2;
	my $name_len = unpack('C',substr($buffer,$offset++,1));
	my $cmt_len = unpack('C',substr($buffer,$offset++,1));
	my $num_uuids = unpack('v',substr($buffer,$offset,2));
	$offset += 2;
	display(0,1,"name_len($name_len) cmt_len($cmt_len) num_uuids($num_uuids)");

	my $HDR1_SIZE = 12;						# includes big_len && main_dword
	my $PT_SIZE = 10;
	my $UUID_OFFSET = $HDR1_SIZE + $name_len + $cmt_len;

	my $left = substr($buffer,$offset,$UUID_OFFSET-$offset);
	my $uuids = substr($buffer,$UUID_OFFSET,$num_uuids * 8);
	my $right = substr($buffer,$UUID_OFFSET + $num_uuids * 8);

	display(0,1,"left=".unpack('H*',$left));
	display(0,1,"uuids=".unpack('H*',$uuids));
	display(0,1,"right=".unpack('H*',$right));

	if ($add)
	{
		$uuids .= pack('H*',$wp_uuid);
		$buffer =
			pack('V',$big_len + $PT_SIZE + 8).
			$skip_word.
			pack('C',$name_len).
			pack('C',$cmt_len).
			pack('v',$num_uuids+1).
			$left.
			$uuids.
			$right.
			pack('H*','00' x $PT_SIZE);

		my $hex_buffer = unpack('H*',$buffer);
		display(0,2,"buffer=$hex_buffer");

		my $text = parseNavQueryRouteBuffer($buffer,8);
		print $text;
		return $hex_buffer;
	}
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

		$this->{NAVQRY_HASH} = lc($what_name)."s";
		$this->{NAVQRY_UUID} = $uuid;
		return 0 if !$this->sendRequest($sock,$sel,$seq,"$what_name ITEM($num)",$request);
		return 0 if !$this->waitReply(1);

		display(0,1,"keys($this->{NAVQRY_HASH}) = ".join(" ",keys %{$this->{$this->{NAVQRY_HASH}}} ));
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
	my ($this,$sock,$sel) = @_;
	my $what = $this->{what};
	my $what_name = $NAV_WHAT{$what};
	my $uuid = $this->{uuid};
	my $name = $this->{name};
	my $data = $this->{data};
	display($dbg,0,"create_item($what=$what_name) $uuid $name");

	# check the name

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIR_SEND,$CMD_FIND,$what,name16_hex($name));
	return 0 if !$this->sendRequest($sock,$sel,$seq,"$what_name name must not exist",$request);
	return 0 if !$this->waitReply(-1);

	# check the uuid

	$request = createMsg($seq,$DIR_SEND,$CMD_ITEM,$what,$uuid);
	$this->{NAVQRY_HASH} = lc($what_name)."s";
	$this->{NAVQRY_UUID} = $uuid;
	return 0 if !$this->sendRequest($sock,$sel,$seq,"$what_name uuid must not exist",$request);
	return 0 if !$this->waitReply(-1);
	
	# create the item
	# These messages are sent separatly by RNS for groups

	$seq = $this->{next_seqnum}++;
	$request =
		createMsg($seq,$DIR_SEND,$CMD_MODIFY,	$what,	$uuid).
		createMsg($seq,$DIR_INFO,$CMD_CONTEXT,	0,		$uuid).		#.'02000000');	#.'00000000').
		createMsg($seq,$DIR_INFO,$CMD_BUFFER,	0,		$data).
		createMsg($seq,$DIR_INFO,$CMD_LIST,		0,		$uuid);

	return 0 if !$this->sendRequest($sock,$sel,$seq,"create $what_name",$request);
	return 0 if !$this->waitReply(1);
	return 1;
}



sub modify_item
{
	my ($this,$sock,$sel) = @_;
	my $what = $this->{what};
	my $what_name = $NAV_WHAT{$what};
	my $uuid = $this->{uuid};
	my $name = $this->{name};
	my $data = $this->{data};

	display($dbg,0,"modify_item($what=$what_name) $uuid $name");
	display($dbg,1,"data=".unpack('H*',$data));

	# These messages are sent separatly by RNS for groups

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIR_SEND,$CMD_DATA,		$what,	'15000000'.$uuid);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"modify1 $what_name",$request);

	$request = createMsg($seq,$DIR_INFO,$CMD_CONTEXT,	0,		$uuid.'02000000');	#.'00000000').
	return 0 if !$this->sendRequest($sock,$sel,$seq,"modify2 $what_name",$request);

	$request = createMsg($seq,$DIR_INFO,$CMD_BUFFER,	0,		$data);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"modify3 $what_name",$request);

	$request = createMsg($seq,$DIR_INFO,$CMD_LIST,		0,		$uuid);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"modify4 $what_name",$request);
	return 0 if !$this->waitReply(1);
	return 1;
}



# NAVQRY <-- 62586  1400 46010f00 49010000 15000000 eeeeeeee eeee0100                              F...I...............
#     set nav_context(62586) = ROUTE(64)
#      # send: DATA ROUTE
# NAVQRY <-- 62586  1400 00020f00 49010000 eeeeeeee eeee0100 02000000                              ....I...............
#      # info: CONTEXT ROUTE eeeeeeeeeeee0100 bits(02)
# NAVQRY <-- 62586  5e00 01020f00 49010000 52000000 00000a00 01000005 74657374 526f7574 6531aaaa   ....I...R...........testRoute1..
#                        aaaaaaaa aaaa0000 00000000 00000000 00000000 00000000 0000eeee eeeeeeee   ................................
#                        01000200 00006c90 19008830 5e030000 00007873 00000000 00000000 0000       ......l....0^.....xs..........
#      # info: BUFFER ROUTE ITEM
# NAVQRY <-- 62586  1000 02020f00 49010000 eeeeeeee eeee0100                                       ....I...........
#      # info: LIST ROUTE


sub delete_item
	 # name just included for nicety debugging
{
	my ($this,$sock,$sel) = @_;

	my $what = $this->{what};
	my $what_name = $NAV_WHAT{$what};
	my $uuid = $this->{uuid};
	my $name = $this->{name};

	display($dbg,0,"delete_item($what=$what_name) $uuid $name");

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIR_SEND,$CMD_DELETE,$what,$uuid);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"delete $what_name",$request);
	return 0 if !$this->waitReply(1);
	return 1;
}





sub commandThread
{
	my ($this,$sock,$sel,$command) = @_;
	display(0,0,"commandThread($command) started");

	$this->do_query($sock,$sel) 	if $command == $API_DO_QUERY;
	$this->create_item($sock,$sel) 	if $command == $API_CREATE_ITEM;
	$this->delete_item($sock,$sel) 	if $command == $API_DELETE_ITEM;
	$this->modify_item($sock,$sel) 	if $command == $API_MODIFY_ITEM;

	$this->do_list_database($sock,$sel) if $command == $API_LIST_DATABASE;
	$this->do_everb($sock,$sel) if $command == $API_EVERB;
	$this->do_database($sock,$sel) if $command == $API_DATABASE;

	$this->{pending_command} = $API_NONE;
}


sub do_list_database
{
	my ($this,$sock,$sel) = @_;

	display($dbg,0,"do_list_database(");

	my $request = createMsg(-1,$DIR_SEND,$CMD_LIST,$WHAT_DATABASE);
	return 0 if !$this->sendRequest($sock,$sel,-1,"list database",$request);
		# NAVQRY <-- 61901  0400 b2010f00                                                                  ....
		#     set nav_context(61901) = DATABASE(176)
		#      # send: LIST DATABASE

	my $seq = $this->{next_seqnum}++;
	$request = createMsg($seq,$DIR_SEND,$CMD_EVERB,$WHAT_GROUP);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"everb",$request);
		# NAVQRY <-- 61901  0800 8e010f00 15000000                                                         ........
		# 	set nav_context(61901) = GROUP(128)
		# 	# send: EVERB GROUP

	return 0 if !$this->waitReply(-1);
	return 1;
}


sub do_everb
{
	my ($this,$sock,$sel) = @_;

	display($dbg,0,"do_everb(");
	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIR_SEND,$CMD_EVERB,$WHAT_GROUP);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"everb",$request);
		# NAVQRY <-- 61901  0800 8e010f00 15000000                                                         ........
		# 	set nav_context(61901) = GROUP(128)
		# 	# send: EVERB GROUP

	return 0 if !$this->waitReply(-1);
	return 1;
}


sub do_database
{
	my ($this,$sock,$sel) = @_;

	display($dbg,0,"do_database(");

	my $seq = $this->{next_seqnum}++;
	my $request = createMsg($seq,$DIR_SEND,$CMD_CONTEXT,$WHAT_DATABASE);
	return 0 if !$this->sendRequest($sock,$sel,$seq,"database check",$request);
	return 0 if !$this->waitReply(-1);
		#	NAVQRY <-- 61550  0800 0d010f00 8b000000                                                         ........
		#	    set nav_context(61550) = WAYPOINT(0)
		#	     # send: SPACE WAYPOINT
		#	NAVQRY --> 61550  0c00 09000f00 8b000000 01000000                                                ............
		#	     # recv: COUNT WAYPOINT number=1
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
		navQueryLog($text);

		my $color = $UTILS_COLOR_LIGHT_BLUE;
		setConsoleColor($color) if $color;
		print $text;
		setConsoleColor() if $color;

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

		if ($this->{command} && !$this->{pending_command})
		{
			my $command = $this->{command};
			$this->{pending_command} = $command;
			$this->{command} = '';
			
			display(0,0,"creating cmd_thread");
			my $cmd_thread = threads->create(\&commandThread,$this,$sock,$sel,$command);
			display(0,0,"nav_thread cmd_thread");
			$cmd_thread->detach();
			display(0,0,"cmd_thread detached");
		}
	}

}	# listenerThread



1;