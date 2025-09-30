#---------------------------------------------
# r_NEWQRY.pm
#---------------------------------------------
# Re-implementation of r_NAVQRY.pm
# test API - works with testWaypointN, testRouteN, and testGroupN
# wpGroup(0) = My Waypoints, i.e. none

package r_NEWQRY;
use strict;
use warnings;
use threads;
use threads::shared;
use IO::Select;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use r_utils;

my $SHOW_OUTPUT = 0;
my $SHOW_INPUT = 0;
my $DBG_WAIT = 0;

# my $SUCCESS_SIG = '00000400';
# my $DICT_END_RECORD_MARKER	= '10000202';


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		newNavqueryThread

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
my $API_CREATE_WAYPOINT = 1;
my $API_CREATE_ROUTE 	= 2;
my $API_CREATE_GROUP 	= 3;
my $API_DELETE_WAYPOINT = 4;
my $API_DELETE_ROUTE 	= 5;
my $API_DELETE_GROUP 	= 6;
my $API_ROUTE_WAYPOINT  = 7;
my $API_WAYPOINT_GROUP  = 8;


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


# vars

my $api_command:shared = $API_NONE;
my $api_wp_num:shared = 0;
my $api_route_num:shared = 0;
my $api_group_num:shared = 0;

my $next_seqnum:shared = 1;


#--------------------------------------
# API
#--------------------------------------

sub createWaypoint
{
	my ($wp_num) = @_;
	display(0,0,"createWaypoint($wp_num)");
	return init_command($API_CREATE_WAYPOINT,$wp_num,0,0);
}

sub deleteWaypoint
{
	my ($wp_num) = @_;
	display(0,0,"deleteWaypoint($wp_num)");
	return init_command($API_DELETE_WAYPOINT,$wp_num,0,0);
}


sub createRoute
{
	my ($route_num) = @_;
	display(0,0,"createRoute($route_num)");
	return init_command($API_CREATE_ROUTE,0,$route_num,0);
}

sub deleteRoute
{
	my ($route_num) = @_;
	display(0,0,"deleteRoute($route_num)");
	return init_command($API_DELETE_ROUTE,0,$route_num,0);
}

sub routeWaypoint
{
	my ($route_num,$wp_num,$add) = @_;
	display(0,0,"routeWaypoint($route_num) wp_num($wp_num) add($add)");
	return init_command($API_ROUTE_WAYPOINT,$wp_num,$route_num,0);
}



sub createGroup
{
	my ($group_num) = @_;
	display(0,0,"createGroup($group_num)");
	return init_command($API_CREATE_GROUP,0,0,$group_num);
}

sub deleteGroup
{
	my ($group_num) = @_;
	display(0,0,"deleteGroup($group_num)");
	return init_command($API_DELETE_GROUP,0,0,$group_num);
}

sub setWaypointGroup
	# 0 = My Waypoints
{
	my ($wp_num,$group_num) = @_;
	display(0,0,"setWaypointGroup($wp_num) group_num($group_num)");
	return init_command($API_WAYPOINT_GROUP,$wp_num,0,$group_num);
}

sub init_command
{
	my ($command,$wp_num,$route_num,$group_num) = @_;
	return error("BUSY WITH ($api_command)") if $api_command;
	print "-----------------------------------------------------------------\n";
	print "init_command($command) wp_num($wp_num) route_num($route_num) group_num($group_num)\n";
	print "-----------------------------------------------------------------\n";
	$api_wp_num		= $wp_num;
	$api_route_num	= $route_num;
	$api_group_num	= $group_num;
	$api_command	= $command;
}


#-------------------------------------------------
# methods
#-------------------------------------------------

sub createMsg
{
	my ($seq,$dir,$cmd,$what,$hex_data) = @_;
	$hex_data =~ s/\s//g;
	my $cmd_word = $dir | $cmd | $what;
	my $data = pack('H*',$hex_data);
	my $len = length($data) + 4 + ($seq >= 0?4:0) ;
	my $msg =
		pack('v',$len).
		pack('v',$cmd_word).
		pack('v',$NAVQRY_FUNC).
		($seq >= 0 ? pack('V',$seq) : '').
		$data;
	return $msg;
}


sub sendRequest
{
	my ($seq,$sock,$sel,$request,$delay_first) = @_;
	print "sendRequest($seq)\n" if $DBG_WAIT;
	if (!$sel->can_write())
	{
		error("Cannot write sendRequest($seq): $!");
		return 0;
	}

	my $num = 0;
	my $offset = 0;
	my $request_len = length($request);
	while ($offset < $request_len)
	{
		my $hdr = substr($request,$offset,2);
		my $len = unpack('v',$hdr);
		my $data = substr($request,$offset+2,$len);

		my $show_hdr = unpack('H*',$hdr);
		my $show_data = unpack('H*',$data);
		
		print pad("$offset,2",7)."<-- $show_hdr\n" if $SHOW_OUTPUT;
		if (!$sock->send($hdr))
		{
			error("Could not send header($num): $show_hdr\n$!");
			return 0;
		}
		$offset += 2;
		sleep(0.1);
		
		if ($len)
		{
			show_dwords(pad("$offset,$len",7)."<-- ",$data,$show_data,0,1) if $SHOW_OUTPUT;
			if (!$sock->send($data))
			{
				error("Could not send data($num): $show_data\n$!");
				return 0;
			}
			$offset += $len;
		}
		sleep(2) if !$num && $delay_first;
		$num++;
	}
	print "sendRequest($seq) done\n" if $DBG_WAIT;
	return 1;
}


sub waitReply
{
	my ($sock,$sel,$seq) = @_;
	my $TIMEOUT = 3;

	print "waitReply($seq)\n" if $DBG_WAIT;

	my $reply = '';
	my $start = time();
	while (length($reply) <= 2)
	{
		if (time() > $start + $TIMEOUT)
		{
			error("TIMEOUT SEQ($seq)");
			return 1;
		}

		my $buf;
		if ($sel->can_read(0.1))
		{
			recv($sock, $buf, 4096, 0);
			if ($buf)
			{
				my $hex = unpack("H*",$buf);
				my $len = length($hex);
				show_dwords(pad(length($buf),7)."--> ",$buf,$hex,0,1) if $SHOW_INPUT;
				$reply .= $buf;
				$start = time()
			}
		}
	}

	print "waitReply($seq) finished\n" if $DBG_WAIT;
	return $reply;
}



#============================================================
# atoms
#============================================================


sub doCreateWP
	# After this the Waypoint exists on the E80, but
	# it doesn't show until you move the screen.
{
	my ($sock,$sel) = @_;
	my $wp_num = $api_wp_num;
	my $uuid = $STD_WP_UUIDS->[$wp_num-1];
	my $data = $STD_WP_DATA->{$uuid};
	my $wp_name = "testWaypoint$wp_num";
	print "doCreateWP($api_wp_num) $uuid $wp_name\n";

	my $seq;
	my $request;
	my $reply;

	$request = createMsg(-1,$DIR_SEND,$CMD_BUFFER,$WHAT_DATABASE,'');
	return 0 if !sendRequest(-1,$sock,$sel,$request);
	$reply = waitReply($sock,$sel,-1);
		# NAVQRY <--51412  0400 b1010f00                                                                  ....
		#      # send: BUFFER DATABASE
	$request = createMsg(-2,$DIR_SEND,$CMD_BUFFER,$WHAT_DATABASE,'');
	return 0 if !sendRequest(-2,$sock,$sel,$request);
		# no reply expected on second

	# 1

	$seq = $next_seqnum++;
	$request = createMsg($seq,$DIR_SEND,$CMD_SPACE,0,'');
	return 0 if !sendRequest($seq,$sock,$sel,$request);
	$reply = waitReply($sock,$sel,$seq);
	# return 0 if !defined($reply);
		# NAVQRY <--51412  0800 0d010f00 9b010000                                                         ........
		#	# send: SPACE DATABASE
		# NAVQRY -->51412  0c00 09000f00 9b010000 00000000                                                ............
		# 	# recv: COUNT DATABASE number=0

	# 2

	$seq = $next_seqnum++;
	$request = createMsg($seq,$DIR_SEND,$CMD_ITEM,$WHAT_WAYPOINT,$uuid);
	return 0 if !sendRequest($seq,$sock,$sel,$request);
	$reply = waitReply($sock,$sel,$seq);
	# return 0 if !defined($reply);
		# NAVQRY <--51412  1000 03010f00 9c010000 aaaaaaaa aaaaaaaa                                       ................
		#      # send: ITEM WAYPOINT aaaaaaaaaaaaaaaa
		# NAVQRY -->51412  0c00 06000f00 9c010000 030b0480                                                ............
		#      # recv: DATA WAYPOINT failed

	# 3

	$seq = $next_seqnum++;
	my $wp_name_16 = $wp_name;
	while (length($wp_name_16) < 16) { $wp_name_16 .= "\x00" }
	$wp_name_16 .= "\x00";
	my $wp_name_hex = unpack('H*',$wp_name_16);
	$request = createMsg($seq,$DIR_SEND,$CMD_FIND,$WHAT_WAYPOINT,$wp_name_hex);
	return 0 if !sendRequest($seq,$sock,$sel,$request);
	$reply = waitReply($sock,$sel,$seq);
	# return 0 if !defined($reply);
		# NAVQRY <--51412  1900 0c010f00 9d010000 74657374 57617970 6f696e74 31007b60 10                  ........testWaypoint1..`.
		#      # send: FIND WAYPOINT 'testWaypoint1'
		# NAVQRY -->51412  1400 08000f00 9d010000 030b0480 00000000 00000000                              ....................
		#      # recv: UUID WAYPOINT failed

	# 4

	$seq = $next_seqnum++;
	$request =
		createMsg($seq,$DIR_SEND,$CMD_MODIFY,	$WHAT_WAYPOINT,	$uuid).
		createMsg($seq,$DIR_INFO,$CMD_CONTEXT,	$WHAT_WAYPOINT,	$uuid.'01000000').
		createMsg($seq,$DIR_INFO,$CMD_BUFFER,	$WHAT_WAYPOINT,	$data).
		createMsg($seq,$DIR_INFO,$CMD_LIST,		$WHAT_WAYPOINT,	$uuid);
	return 0 if !sendRequest($seq,$sock,$sel,$request,1);
	$reply = waitReply($sock,$sel,$seq);
	# return 0 if !defined($reply);
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


	# try sending two ITEM WAYPOINT messages after creation like RNS does
	# didn't help.  Have to move the chart for it to show.
	# Grumble.  Once I create a waypoint, until I reboot both RNS
	# and the E80, no waypoints created, or chanaged, on RNS show
	# until you move the chart.
	#
	# It appears that if you reboot the E80, you must restart RNS.
	#
	# Perhaps the E80 is waiting for me to answer the events?
	
	

	$seq = $next_seqnum++;
	$request = createMsg($seq,$DIR_SEND,$CMD_ITEM,$WHAT_WAYPOINT,$uuid);
	return 0 if !sendRequest($seq,$sock,$sel,$request);
	$reply = waitReply($sock,$sel,$seq);

	$seq = $next_seqnum++;
	$request = createMsg($seq,$DIR_SEND,$CMD_ITEM,$WHAT_WAYPOINT,$uuid);
	return 0 if !sendRequest($seq,$sock,$sel,$request);
	$reply = waitReply($sock,$sel,$seq);
	
	return 1;
}



sub newNavqueryThread
{
	my ($sock,$sel) = @_;
	
	return 1 if !$api_command;
	print "newNavqueryThread($api_command) wp_num($api_wp_num) route_num($api_route_num) group_num($api_group_num)\n";

	my $ok;
	$ok = doCreateWP($sock,$sel) if $api_command == $API_CREATE_WAYPOINT;
	error("FUNCTION FAILED") if !$ok;
	
	# finished
	$api_command = 0;
	return $ok;
}



1;