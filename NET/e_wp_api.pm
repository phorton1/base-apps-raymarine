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
use a_mon;
use a_utils;
use e_wp_defs;

my $TEMP_COLOR = $UTILS_COLOR_CYAN;
my $TEMP_MON = $MON_REC | $MON_REC_DETAILS | $MON_PACK | $MON_PACK_CONTROL | $MON_PACK_UNKNOWN;


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


sub findUUIDByName
{
	my ($this,$what_name,$name) = @_;
	my $hash = $this->{$what_name.'s'};
	for my $uuid (keys %$hash)
	{
		return $uuid if $hash->{$uuid}->{name} eq $name;
	}
	error("Could not find $what_name($name)");
	return undef;
}



sub emptyGroup
{
	my ($name) = @_;
	my $buffer = buildGroup(0,{ name => $name },$TEMP_MON,$TEMP_COLOR);
	my $ret_hex = unpack('H*',$buffer);
	return $ret_hex;
}



my $next_color:shared = 0;

sub emptyRoute
{
	my ($name,$bits) = @_;
	$bits = 0 if !defined($bits);
	my $name_len = length($name);
	my $buffer = buildRoute(0,{

		name => $name,
		bits => $bits,
		color => $next_color++ % $NUM_ROUTE_COLORS,

		# So far nothing has caused the E80 to show a TimePerPoint
		# or the Date, Time, or Actual SOG in the E80 Route Details window

		u1_0 => 123,
		u5   => 456,	# gets overwritten by e80 to 'b8975601'
		u8   => 789,	# gets overwritten by e80 to 7cb7 (0xb78c)

	},$TEMP_MON,$TEMP_COLOR);
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

	my $buffer = buildWaypoint(0,{
		name => $name,
		comment => "wpComment$wp_num",
		lat => int($$lat_lon[0] * $SCALE_LATLON),
		lon => int($$lat_lon[1] * $SCALE_LATLON),
		north => $alt_coords->{north},
		east => $alt_coords->{east},
		sym => 2,
		depth => 10 * $FEET_PER_METER * 10,
		date => int($now / $SECS_PER_DAY),
		time => int($now % $SECS_PER_DAY), },
		$TEMP_MON,$TEMP_COLOR);
	my $data = unpack('H*',$buffer);
	return $this->queueWPMGRCommand($API_NEW_ITEM,$WHAT_WAYPOINT,$name,$uuid,$data);
}

sub deleteWaypoint
{
	my ($this,$name) = @_;
	$this->showCommand("deleteWaypoint($name)");
	my $uuid = $this->findUUIDByName('waypoint',$name);
	return if !$uuid;
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
	my ($this,$name) = @_;
	$this->showCommand("deleteGroup($name)");
	my $uuid = $this->findUUIDByName('group',$name);
	return if !$uuid;
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
		return error("Could not find group($group_uuid)") if !$group;

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

	my $buffer = buildGroup(0,$group,$TEMP_MON,$TEMP_COLOR);
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
	my ($this,$name) = @_;
	$this->showCommand("deleteRoute($name)");
	my $uuid = $this->findUUIDByName('route',$name);
	return if !$uuid;
	return $this->queueWPMGRCommand($API_DEL_ITEM,$WHAT_ROUTE,$name,$uuid,0);
}





#------------------------------------------------
# routeWaypoint command still buggy
#------------------------------------------------


sub routeWaypoint
{
	my ($this,$route_num,$wp_num,$add) = @_;
	$this->showCommand("routeWaypoint($route_num) wp_num($wp_num) add($add)");
	my $route_uuid = std_uuid($STD_ROUTE_UUID,$route_num);
	my $wp_uuid = std_uuid($STD_WP_UUID,$wp_num);

	my $route = $this->{routes}->{$route_uuid};
	return error("Could not find route($route_uuid)") if !$route;
	my $route_name = $route->{name};

	# display_record(1,0,"got route",$route);

	my $exists = 0-1;
	my @uuids = @{$route->{uuids}};
	my @points = @{$route->{points}};
	
	my $num = 0;
	for my $uuid (@uuids)
	{
		if ($uuid eq $wp_uuid)
		{
			$exists = $num;
			last;
		}
		$num++;
	}

	return error("route($route_uuid=$route_name) already contains wp($wp_uuid)")
		if $add && $exists != -1;
	return error("route($route_uuid=$route_name) does not contain wp($wp_uuid)")
		if !$add && $exists == -1;

	if ($add)
	{
		push @uuids,$wp_uuid;
		push @points,shared_clone({});
			# buildRoute will populate the point implicitly, with zero values
			# since the record does not contain any fields.
			# The E80 will then fill in the fields, but we need to get the modified route after the change.
			# For some reason, I'm not getting a MOD event for this change.
	}
	else
	{
		splice @uuids,$exists,1;
		splice @points,$exists,1;
	}


	# @uuids = sort { $this->{waypoints}->{$a}->{name} cmp $this->{waypoints}->{$b}->{name} } @uuids;
		# New added points get their values adjusted.
		# Sorting the list without adjusting the values whacks out the e80, it will NOT
		# recalculate everything. For example, it doesn't set the new 0th record to 0,0,0
		# as hoped.
		
	$route->{uuids} = shared_clone(\@uuids);
	$route->{points} = shared_clone(\@points);

	# display_record(0,0,"new route",$route);

	my $buffer = buildRoute(0,$route,$TEMP_MON,$TEMP_COLOR);
	my $data = unpack('H*',$buffer);
	return $this->queueWPMGRCommand($API_MOD_ITEM,$WHAT_ROUTE,$route_name,$route_uuid,$data);

	# The command appears to be executed OK, and as such, in case of adding a new point,
	# the point's bearing and distances are updated, and the overal route's end lat/lon
	# and distance is updated .  It appears to have self UUIDs as expected, u2_200 is
	# '2000000' as expected, u3 is the familiar but not understood 'b8975601', however
	# u1_0, expected to be zero is 1230 cuze I set it in emptyRoute(), and u6, the
	# unknown is 'c81c'.

	# THE E80 does not send an event mod for the addition of a new point, so it
	# needs to be refreshed.
}


sub showItem
{
	my ($this,$what,$name) = @_;
	my $hash_key = lc($what)."s";
	my $hash = $this->{$hash_key};

	my $found = '';
	for my $uuid (keys %$hash)
	{
		my $rec = $hash->{$uuid};
		if ($rec->{name} eq $name)
		{
			$found = $uuid;
			last;
		}
	}

	return error("Could not find $what($name)") if !$found;
	
	my $rec = $hash->{$found};
	my $text = wpmgrRecordToText($rec,uc($what),2,2,undef,$this);
		# indent = 2
		# detail_level = 2;
		# undef = index
		# $this = $wpmgr
		
	print "----------------------showItem($found=$name) -----------------------------\n$text\n\n";
}



1;