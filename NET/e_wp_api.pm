#---------------------------------------------
# e_wp_api.pm
#---------------------------------------------

package d_WPMGR;	# continued
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Time::Local;
use Pub::Utils;
use a_defs;
use a_utils;
use e_wp_defs;



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
	my ($this,$msg) = @_;
	return if !$this->{show_parsed_output};
	$msg = "\n\n".
		"#------------------------------------------------------------------\n".
		"# $msg\n".
		"#------------------------------------------------------------------\n\n";
	print $msg;
	writeLog($msg,'shark.log');
}



sub queryWaypoints
{
	my ($this) = @_;
	$this->showCommand("queryWaypoints()");
	return $this->queueWPMGRCommand($API_DO_QUERY,0,0,0,0);
}



sub createWaypoint
{
	my ($this,$wp_num) = @_;
	$this->showCommand("createWaypoint($wp_num)");
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
	return $this->queueWPMGRCommand($API_NEW_ITEM,$WHAT_WAYPOINT,$name,$uuid,$data);
}

sub deleteWaypoint
{
	my ($this,$wp_num) = @_;
	$this->showCommand("deleteWaypoint($wp_num)");
	my $uuid = std_uuid($STD_WP_UUID,$wp_num);
	my $name = "testWaypoint$wp_num";
	return $this->queueWPMGRCommand($API_DEL_ITEM,$WHAT_WAYPOINT,$name,$uuid,0);
}



sub createGroup
{
	my ($this,$group_num) = @_;
	$this->showCommand("createGroup($group_num)");
	my $uuid = std_uuid($STD_GROUP_UUID,$group_num);
	my $name = "testGroup$group_num";
	my $data = emptyGroup($name);
	return $this->queueWPMGRCommand($API_NEW_ITEM,$WHAT_GROUP,$name,$uuid,$data);
}

sub deleteGroup
{
	my ($this,$group_num) = @_;
	$this->showCommand("deleteGroup($group_num)");
	my $uuid = std_uuid($STD_GROUP_UUID,$group_num);
	my $name = "testGroup$group_num";
	return $this->queueWPMGRCommand($API_DEL_ITEM,$WHAT_GROUP,$name,$uuid,0);
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
	my ($this,$wp_num,$group_num) = @_;
	$this->showCommand("setWaypointGroup($wp_num) group_num($group_num)");

	my $wp_uuid = std_uuid($STD_WP_UUID,$wp_num);
	my $wp_name = "testWaypoint$wp_num";
	my $group_name = $group_num ? "testGroup$group_num" : 'My Waypoints';
	my $group_uuid;
	my $group;

	if ($group_num)
	{
		$group_uuid = std_uuid($STD_GROUP_UUID,$group_num);
		$group = $this->{groups}->{$group_uuid};
		return error("Could not group($group_uuid)") if !$group;

		display_hash(0,0,"got group",$group);
		push @{$group->{uuids}},$wp_uuid;
	}
	else
	{
		my $wp = $this->{waypoints}->{$wp_uuid};
		return error("Could not find WP($wp_uuid)") if !$wp;
		display_hash(0,1,"got waypoint",$wp);

		my $wp_uuids = $wp->{uuids};
		return error("No uuids on waypoint($wp_uuid)") if !$wp_uuids;

		for my $try_uuid (@$wp_uuids)
		{
			$group = $this->{groups}->{$try_uuid};
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
	return $this->queueWPMGRCommand($API_MOD_ITEM,$WHAT_GROUP,$group_name,$group_uuid,$data);

}




sub createRoute
{
	my ($this,$route_num,$bits) = @_;
	$bits ||= 0;
	$this->showCommand("createRoute($route_num) bits($bits)");
	my $uuid = std_uuid($STD_ROUTE_UUID,$route_num);
	my $name = "testRoute$route_num";
	my $data = emptyRoute($name,$bits);
	return $this->queueWPMGRCommand($API_NEW_ITEM,$WHAT_ROUTE,$name,$uuid,$data);
}

sub deleteRoute
{
	my ($this,$route_num) = @_;
	$this->showCommand("deleteRoute($route_num)");
	my $uuid = std_uuid($STD_ROUTE_UUID,$route_num);
	my $name = "testRoute$route_num";
	return $this->queueWPMGRCommand($API_DEL_ITEM,$WHAT_ROUTE,$name,$uuid,0);
}





#------------------------------------------------
# routeWaypoint command still buggy
#------------------------------------------------
# It's the only UI command that must perform an
# asynchronous operation to get the given route first,
# before queuing an API command  ....
#
# this functionality should probably be moved DOWN
# into the actual WPMGR commandHandler as an atom.


sub _commandBusy
{
	my ($this) = @_;
	return $this->{busy} || @{$this->{command_queue}} ? 1 : 0;
}



sub _wait_queue_command
{
	my ($this,@params) = @_;
	return 0 if !$this->queueWPMGRCommand(@params);
	while ($this->_commandBusy())
	{
		display_hash(0,0,"_wait_queue_command",$this);
		sleep(1);
	}
	error("_wait_queue_command failed") if !$this->{command_rslt};
	display(0,0,"_wait_queue_command returning $this->{command_rslt}");
	return $this->{command_rslt};
}



sub routeWaypoint
{
	my ($this,$route_num,$wp_num,$add) = @_;
	$this->showCommand("routeWaypoint($route_num) wp_num($wp_num) add($add)");
	my $route_uuid = std_uuid($STD_ROUTE_UUID,$route_num);
	my $wp_uuid = std_uuid($STD_WP_UUID,$wp_num);
	my $route_name = "testRoute$route_num";

	return if !$this->_wait_queue_command($API_GET_ITEM,$WHAT_ROUTE,$route_name,$wp_uuid,$wp_uuid);
	my $route = $this->{routes}->{$route_uuid};
	return error("Could not find route($route_name) $route_uuid") if !$route;

	display_hash(0,0,"got route",$route);
	my $uuids = $route->{uuids};
	push @$uuids,$wp_uuid if $add;

	return $this->queueWPMGRCommand($API_MOD_ITEM,$WHAT_ROUTE,$route_name,$route_uuid,$route);
}



1;