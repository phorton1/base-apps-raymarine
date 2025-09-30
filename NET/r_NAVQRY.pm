#---------------------------------------------
# r_NEWQRY.pm
#---------------------------------------------
# Re-implementation of r_NAVQRY.pm
# test API - works with testWaypointN, testRouteN, and testGroupN
# wpGroup(0) = My Waypoints, i.e. none

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
my $API_CREATE_WAYPOINT = 2;
my $API_CREATE_ROUTE 	= 3;
my $API_CREATE_GROUP 	= 4;
my $API_DELETE_WAYPOINT = 5;
my $API_DELETE_ROUTE 	= 6;
my $API_DELETE_GROUP 	= 7;
my $API_ROUTE_WAYPOINT  = 8;
my $API_WAYPOINT_GROUP  = 9;


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
my $CMD_UUID      	= 0x8;
my $CMD_COUNT     	= 0x9;
my $CMD_AVERB     	= 0xa;
my $CMD_BVERB     	= 0xb;
my $CMD_FIND		= 0xc;
my $CMD_SPACE     	= 0xd;
my $CMD_DELETE    	= 0xe;
my $CMD_FVERB     	= 0xf;

my $STD_GROUP_UUID = 'eeeeeeeeeeeeeeee';
my $STD_WP_UUIDS = [
	'aaaaaaaaaaaaaaaa',
	'bbbbbbbbbbbbbbbb',
	'cccccccccccccccc',
	'dddddddddddddddd', ];
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


my $self:shared;


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
	$this->{api_command} = 0;
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
	return init_command($self,$API_DO_QUERY,0,0,0);
}

sub createWaypoint
{
	my ($wp_num) = @_;
	display(0,0,"createWaypoint($wp_num)");
	return init_command($self,$API_CREATE_WAYPOINT,$wp_num,0,0);
}

sub deleteWaypoint
{
	my ($wp_num) = @_;
	display(0,0,"deleteWaypoint($wp_num)");
	return init_command($self,$API_DELETE_WAYPOINT,$wp_num,0,0);
}


sub createRoute
{
	my ($route_num) = @_;
	display(0,0,"createRoute($route_num)");
	return init_command($self,$API_CREATE_ROUTE,0,$route_num,0);
}

sub deleteRoute
{
	my ($route_num) = @_;
	display(0,0,"deleteRoute($route_num)");
	return init_command($self,$API_DELETE_ROUTE,0,$route_num,0);
}

sub routeWaypoint
{
	my ($route_num,$wp_num,$add) = @_;
	display(0,0,"routeWaypoint($route_num) wp_num($wp_num) add($add)");
	return init_command($self,$API_ROUTE_WAYPOINT,$wp_num,$route_num,0);
}

sub createGroup
{
	my ($group_num) = @_;
	display(0,0,"createGroup($group_num)");
	return init_command($self,$API_CREATE_GROUP,0,0,$group_num);
}

sub deleteGroup
{
	my ($group_num) = @_;
	display(0,0,"deleteGroup($group_num)");
	return init_command($self,$API_DELETE_GROUP,0,0,$group_num);
}

sub setWaypointGroup
	# 0 = My Waypoints
{
	my ($wp_num,$group_num) = @_;
	display(0,0,"setWaypointGroup($wp_num) group_num($group_num)");
	return init_command($self,$API_WAYPOINT_GROUP,$wp_num,0,$group_num);
}

sub init_command
{
	my ($this,$command,$wp_num,$route_num,$group_num) = @_;
	return error("No 'this' in init_command") if !$this;
	return error("Not started") if !$this->{started};
	return error("Not running") if !$this->{running};
	return error("BUSY WITH API_COMMAND($this->{api_command})") if $this->{api_command};

	print "-----------------------------------------------------------------\n";
	print "init_command($command) wp_num($wp_num) route_num($route_num) group_num($group_num)\n";
	print "-----------------------------------------------------------------\n";
	$this->{api_wp_num}		= $wp_num;
	$this->{api_route_num}	= $route_num;
	$this->{api_group_num}	= $group_num;
	$this->{api_command}	= $command;
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


#============================================================
# commandThread atoms
#============================================================

my $dict_context = '00000000 00000000 1a000000';
my $dict_buffer = '28000000 00000000 00000000 00000000 00000000 00000000'.
                  '10270000 00000000 00000000 00000000 00000000';


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
		$request = createMsg($seq,$DIR_SEND,$CMD_ITEM,$WHAT_WAYPOINT,$uuid);
		return 0 if !$this->sendRequest($sock,$sel,$seq,"$what_name ITEM($num)",$request);
		return 0 if !$this->waitReply(1);
	}
	return 1;
}



sub do_query
	# After this the Waypoint exists on the E80, but
	# it doesn't show until you move the screen.
{
	my ($this,$sock,$sel) = @_;
	print "do_query()\n";

	return 0 if !$this->query_one($sock,$sel,$WHAT_WAYPOINT);
	return 0 if !$this->query_one($sock,$sel,$WHAT_ROUTE);
	return 0 if !$this->query_one($sock,$sel,$WHAT_GROUP);
	return 1;
}



sub create_wp
	# After this the Waypoint exists on the E80, but
	# it doesn't show until you move the screen.
{
	my ($this,$sock,$sel) = @_;
	my $wp_num = $this->{api_wp_num};
	my $uuid = $STD_WP_UUIDS->[$wp_num-1];
	my $data = $STD_WP_DATA->{$uuid};
	my $wp_name = "testWaypoint$wp_num";
	display($dbg,0,"create_wp($wp_num) $uuid $wp_name");

	my $seq;
	my $request;

	# we send this twice, once we *might* get a reply

	if (0)	# database checks
	{
		$request = createMsg(-1,$DIR_SEND,$CMD_BUFFER,$WHAT_DATABASE);
		return 0 if !$this->sendRequest($sock,$sel,-1,'init1',$request);
			# NAVQRY <--51412  0400 b1010f00                                                                  ....
			#      # send: BUFFER DATABASE
		$request = createMsg(-2,$DIR_SEND,$CMD_BUFFER,$WHAT_DATABASE);
		return 0 if !$this->sendRequest($sock,$sel,-2,'init2',$request);
			# no reply expected on second


		$seq = $this->{next_seqnum}++;
		$request = createMsg($seq,$DIR_SEND,$CMD_SPACE);
		return 0 if !$this->sendRequest($sock,$sel,$seq,'space',$request);
		return 0 if !$this->waitReply();
			# NAVQRY <--51412  0800 0d010f00 9b010000                                                         ........
			#	# send: SPACE DATABASE
			# NAVQRY -->51412  0c00 09000f00 9b010000 00000000                                                ............
			# 	# recv: COUNT DATABASE number=0
	}

	if (0)	# check alrady exists
	{
		$seq = $this->{next_seqnum}++;
		$request = createMsg($seq,$DIR_SEND,$CMD_ITEM,$WHAT_WAYPOINT,$uuid);
		return 0 if !$this->sendRequest($sock,$sel,$seq,'check_uuid',$request);
		return 0 if !$this->waitReply(-1);
			# NAVQRY <--51412  1000 03010f00 9c010000 aaaaaaaa aaaaaaaa                                       ................
			#      # send: ITEM WAYPOINT aaaaaaaaaaaaaaaa
			# NAVQRY -->51412  0c00 06000f00 9c010000 030b0480                                                ............
			#      # recv: DATA WAYPOINT failed


		my $wp_name_16 = $wp_name;
		while (length($wp_name_16) < 16) { $wp_name_16 .= "\x00" }
		$wp_name_16 .= "\x00";
		my $wp_name_hex = unpack('H*',$wp_name_16);

		$seq = $this->{next_seqnum}++;
		$request = createMsg($seq,$DIR_SEND,$CMD_FIND,$WHAT_WAYPOINT,$wp_name_hex);
		return 0 if !$this->sendRequest($sock,$sel,$seq,'check_name',$request);
		return 0 if !$this->waitReply(-1);
			# NAVQRY <--51412  1900 0c010f00 9d010000 74657374 57617970 6f696e74 31007b60 10                  ........testWaypoint1..`.
			#      # send: FIND WAYPOINT 'testWaypoint1'
			# NAVQRY -->51412  1400 08000f00 9d010000 030b0480 00000000 00000000                              ....................
			#      # recv: UUID WAYPOINT failed
	}
	
	# create the waypoint

	$seq = $this->{next_seqnum}++;
	$request =
		createMsg($seq,$DIR_SEND,$CMD_MODIFY,	$WHAT_WAYPOINT,	$uuid).
		createMsg($seq,$DIR_INFO,$CMD_CONTEXT,	$WHAT_WAYPOINT,	$uuid.'01000000').
		createMsg($seq,$DIR_INFO,$CMD_BUFFER,	$WHAT_WAYPOINT,	$data).
		createMsg($seq,$DIR_INFO,$CMD_LIST,		$WHAT_WAYPOINT,	$uuid);
	return 0 if !$this->sendRequest($sock,$sel,$seq,'create_wp',$request);
	return 0 if !$this->waitReply(1);
		# NAVQRY <--51412  1000 07010f00 9e010000 aaaaaaaa aaaaaaaa                                       ................
		#      # send: MODIFY WAYPOINT aaaaaaaaaaaaaaaa
		# NAVQRY <--51412  1400 00020f00 9e010000 aaaaaaaa aaaaaaaa 01000000                              ....................
		#      # info: CONTEXT WAYPOINT aaaaaaaaaaaaaaaa bits(01)
		# NAVQRY <--51412  5300 01020f00 9e010000 47000000 9e449005 ecdbface c16a9f06 ad4a84c5 00000000   ........G....D.......j...J......
		#                       00000000 00000000 02010030 010000ef dc000088 4f000d0a 00000000 74657374   ...........0........O.......test
		#                       57617970 6f696e74 31777043 6f6d6d65 6e7431                                Waypoint1wpComment1
		#      # info: BUFFER WAYPOINT 470000009e449005 bits(ec)
		# NAVQRY <--51412  1000 02020f00 9e010000 aaaaaaaa aaaaaaaa                                       ................
		#      # info: LIST WAYPOINT
		# NAVQRY -->51412  0c00 03000f00 9e010000 00000400                                                ............
		#      # recv: ITEM WAYPOINT ok
		#                  1000 07000f00 aaaaaaaa aaaaaaaa 00000000                                       ................
		#      # recv: MODIFY WAYPOINT aaaaaaaaaaaaaaaa bits(00)



	if (0)
	{
		# try sending two ITEM WAYPOINT messages after creation like RNS does
		# didn't help.  Have to move the chart for it to show.
		# Grumble.  Once I create a waypoint, until I reboot both RNS
		# and the E80, no waypoints created, or chanaged, on RNS show
		# until you move the chart.
		#
		# It appears that if you reboot the E80, you must restart RNS.
		#
		# Perhaps the E80 is waiting for me to answer the events?

		$seq = $this->{next_seqnum}++;
		$request = createMsg($seq,$DIR_SEND,$CMD_ITEM,$WHAT_WAYPOINT,$uuid);
		return 0 if !$this->sendRequest($sock,$sel,$seq,'readback1',$request);
		return 0 if !$this->waitReply(1);

		return 0 if !$this->sendRequest($sock,$sel,$seq,'readback2',$request);
		return 0 if !$this->waitReply(1);
	}

	return 1;
}


sub commandThread
{
	my ($this,$sock,$sel,$api_command) = @_;
	display(0,0,"commandThread($this->{api_command}) started");
	my $ok = 1;
	$ok = $this->do_query($sock,$sel) 	if $api_command == $API_DO_QUERY;
	$ok = $this->create_wp($sock,$sel) 	if $api_command == $API_CREATE_WAYPOINT;
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

		my $text = parseNavPacket(1,$NAVQUERY_PORT,$this->{reply});
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

		if ($this->{api_command})
		{
			my $api_command = $this->{api_command};
			$this->{api_command} = $API_NONE;
			display(0,0,"creating cmd_thread");
			my $cmd_thread = threads->create(\&commandThread,$this,$sock,$sel,$api_command);
			display(0,0,"nav_thread cmd_thread");
			$cmd_thread->detach();
			display(0,0,"cmd_thread detached");
		}
	}

}



1;