#---------------------------------------------
# wp_api.pm
#---------------------------------------------

package wp_api;
use strict;
use warnings;
use threads;
use threads::shared;
use Socket;
use IO::Select;
use IO::Handle;
use IO::Socket::INET;
use Time::HiRes qw(sleep time);
use Time::Local;
use Pub::Utils;
use r_units;
use r_utils;
use r_RAYSYS;
use r_WPMGR;
use wp_parse;



BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		queryWaypoints

		createWaypoint
		deleteWaypoint

		createRoute
		deleteRoute
		routeWaypoint

		createGroup
		deleteGroup
		setWaypointGroup

    );
}


my $STD_WP_UUID	   = 'aaaaaaaaaaaa{int}';
my $STD_ROUTE_UUID = 'bbbbbbbbbbbb{int}';
my $STD_GROUP_UUID = 'cccccccccccc{int}';

my $LAT_LON = [
	[ 9.334083,-82.242050 ],
	[ 9.272120,-82.204624 ],
	[ 9.255866,-82.197158 ],
	[ 9.249720,-82.193311 ],
	[ 9.231067,-82.180733 ],
	[ 9.227000,-82.165517 ],
	[ 9.208679,-82.155577 ],
	[ 9.202670,-82.157985 ],
	[ 9.200271,-82.152427 ],
	[ 9.200832,-82.145835 ],
];


#-----------------------------------
# utilities
#-----------------------------------


sub std_uuid
{
	my ($template,$int) = @_;
	my $pack = pack('v',$int);
	my $hex = unpack('H4',$pack);
	$template =~ s/{int}/$hex/;
	return $template;
}

sub emptyGroup
{
	my ($name) = @_;
	my $buffer = buildWPGroup({ name => $name });
	my $ret_hex = unpack('H*',$buffer);
	return $ret_hex;
}



my $next_color:shared = 0;

sub emptyRoute
{
	my ($name,$bits) = @_;
	$bits = 0 if !defined($bits);
	my $name_len = length($name);
	my $buffer = buildWPRoute({
		name => $name,
		bits => $bits,
		color => $next_color++ % $NUM_ROUTE_COLORS, });
	my $ret_hex = unpack('H*',$buffer);
	return $ret_hex;
}



#--------------------------------------
# API
#--------------------------------------

sub showCommand
{
	my ($msg) = @_;
	return if !$SHOW_WPMGR_PARSED_OUTPUT;	# in r_WPMGR.pm
	$msg = "\n\n".
		"#------------------------------------------------------------------\n".
		"# $msg\n".
		"#------------------------------------------------------------------\n\n";
	print $msg;
	navQueryLog($msg,'shark.log');
}



sub queryWaypoints
{
	showCommand("queryWaypoints()");
	return queueWPMGRCommand($wpmgr,$API_DO_QUERY,0,0,0,0);
}



sub createWaypoint
{
	my ($wp_num) = @_;
	showCommand("createWaypoint($wp_num)");
	my $uuid = std_uuid($STD_WP_UUID,$wp_num);
	my $name = "testWaypoint$wp_num";
	my $lat_lon = $$LAT_LON[$wp_num-1];
	my $alt_coords = latLonToNorthEast($$lat_lon[0],$$lat_lon[1]);
	my $now = timegm(localtime());
		# local epoch seconds
		# The E80 appears to display Waypoint times without regards
		# to the Menu-System Settings-Date and Time-Offset that might be entered.
		# So, for now, I send them as local times for clarity in debugging.

	my $buffer = buildWPWaypoint({
		name => $name,
		comment => "wpComment$wp_num",
		lat => int($$lat_lon[0] * $SCALE_LATLON),
		lon => int($$lat_lon[1] * $SCALE_LATLON),
		north => $alt_coords->{north},
		east => $alt_coords->{east},
		sym => 2,
		depth => 10 * $FEET_PER_METER * 10,
		date => int($now / $SECS_PER_DAY),
		time => int($now % $SECS_PER_DAY), });
	my $data = unpack('H*',$buffer);
	return queueWPMGRCommand($wpmgr,$API_NEW_ITEM,$WHAT_WAYPOINT,$name,$uuid,$data);
}

sub deleteWaypoint
{
	my ($wp_num) = @_;
	showCommand("deleteWaypoint($wp_num)");
	my $uuid = std_uuid($STD_WP_UUID,$wp_num);
	my $name = "testWaypoint$wp_num";
	return queueWPMGRCommand($wpmgr,$API_DEL_ITEM,$WHAT_WAYPOINT,$name,$uuid,0);
}


sub createRoute
{
	my ($route_num,$bits) = @_;
	$bits ||= 0;
	showCommand("createRoute($route_num) bits($bits)");
	my $uuid = std_uuid($STD_ROUTE_UUID,$route_num);
	my $name = "testRoute$route_num";
	my $data = emptyRoute($name,$bits);
	return queueWPMGRCommand($wpmgr,$API_NEW_ITEM,$WHAT_ROUTE,$name,$uuid,$data);
}

sub deleteRoute
{
	my ($route_num) = @_;
	showCommand("deleteRoute($route_num)");
	my $uuid = std_uuid($STD_ROUTE_UUID,$route_num);
	my $name = "testRoute$route_num";
	return queueWPMGRCommand($wpmgr,$API_DEL_ITEM,$WHAT_ROUTE,$name,$uuid,0);
}

sub routeWaypoint
{
	my ($route_num,$wp_num,$add) = @_;
	showCommand("routeWaypoint($route_num) wp_num($wp_num) add($add)");
	my $route_uuid = std_uuid($STD_ROUTE_UUID,$route_num);
	my $wp_uuid = std_uuid($STD_WP_UUID,$wp_num);
	my $route_name = "testRoute$route_num";

	return if !wait_queue_command($API_GET_ITEM,$WHAT_ROUTE,$route_name,$wp_uuid,$wp_uuid);
	my $route = $wpmgr->{routes}->{$route_uuid};
	return error("Could not find route($route_name) $route_uuid") if !$route;
				 
	display_hash(0,0,"got route",$route);
	my $uuids = $route->{uuids};
	push @$uuids,$wp_uuid if $add;

	return queueWPMGRCommand($wpmgr,$API_MOD_ITEM,$WHAT_ROUTE,$route_name,$route_uuid,$route);
}

sub createGroup
{
	my ($group_num) = @_;
	showCommand("createGroup($group_num)");
	my $uuid = std_uuid($STD_GROUP_UUID,$group_num);
	my $name = "testGroup$group_num";
	my $data = emptyGroup($name);
	return queueWPMGRCommand($wpmgr,$API_NEW_ITEM,$WHAT_GROUP,$name,$uuid,$data);
}

sub deleteGroup
{
	my ($group_num) = @_;
	showCommand("deleteGroup($group_num)");
	my $uuid = std_uuid($STD_GROUP_UUID,$group_num);
	my $name = "testGroup$group_num";
	return queueWPMGRCommand($wpmgr,$API_DEL_ITEM,$WHAT_GROUP,$name,$uuid,0);
}


sub commandBusy
{
	return $wpmgr->{busy} || @{$wpmgr->{command_queue}} ? 1 : 0;
}



sub wait_queue_command
{
	my (@params) = @_;
	return 0 if !queueWPMGRCommand($wpmgr,@params);
	while (commandBusy())
	{
		display_hash(0,0,"wait_queue_command",$wpmgr);
		sleep(1);
	}
	error("wait_queue_command failed") if !$wpmgr->{command_rslt};
	display(0,0,"wait_queue_command returning $wpmgr->{command_rslt}");
	return $wpmgr->{command_rslt};
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

	my $wp_uuid = std_uuid($STD_WP_UUID,$wp_num);
	my $wp_name = "testWaypoint$wp_num";
	my $group_name = $group_num ? "testGroup$group_num" : 'My Waypoints';
	my $group_uuid;
	my $group;

	if ($group_num)
	{
		$group_uuid = std_uuid($STD_GROUP_UUID,$group_num);
		$group = $wpmgr->{groups}->{$group_uuid};
		return error("Could not group($group_uuid)") if !$group;

		display_hash(0,0,"got group",$group);
		push @{$group->{uuids}},$wp_uuid;
	}
	else
	{
		my $wp = $wpmgr->{waypoints}->{$wp_uuid};
		return error("Could not find WP($wp_uuid)") if !$wp;
		display_hash(0,1,"got waypoint",$wp);

		my $wp_uuids = $wp->{uuids};
		return error("No uuids on waypoint($wp_uuid)") if !$wp_uuids;

		for my $try_uuid (@$wp_uuids)
		{
			$group = $wpmgr->{groups}->{$try_uuid};
			$group_uuid = $try_uuid if $group;
			last if $group;
		}

		return error("Could not find wp group_uuid") if !$group;
		display_hash(0,1,"got group($group_uuid)",$group);

		my $num = 0;
		my $index = -1;
		my $uuids = $group->{uuids};
		for my $uuid (@$uuids)
		{
			if ($uuid eq $wp_uuid)
			{
				$index = $num;
				last;
			}
			$num++;
		}

		return error("Could not find wp_uuid($wp_uuid) in group($group->{name})")
			if $index == -1;
		display(0,1,"removing wp_uuid($wp_uuid) at index($index)");

		my @unshared_uuids = @$uuids;
		splice @unshared_uuids,$index,1;
		$group->{uuids} = shared_clone(\@unshared_uuids);
	}

	my $buffer = buildWPGroup($group);
	my $data = unpack('H*',$buffer);
	return queueWPMGRCommand($wpmgr,$API_MOD_ITEM,$WHAT_GROUP,$group_name,$group_uuid,$data);

}



1;