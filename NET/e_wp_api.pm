#---------------------------------------------
# e_wp_api.pm
#---------------------------------------------

package apps::raymarine::NET::d_WPMGR;	# continued
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Time::Local;
use Pub::Utils;
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_mon;
use apps::raymarine::NET::a_utils;
use apps::raymarine::NET::e_wp_defs;

my $TEMP_COLOR = $UTILS_COLOR_CYAN;
my $TEMP_MON   = $MONITOR_API_BUILDS;

my $next_color:shared = 0;


#-----------------------------------
# utilities
#-----------------------------------

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


sub showCommand
{
	my ($this,$msg) = @_;
	return if !$this->{show_parsed_output};
	$msg = "\n\n".
		"#------------------------------------------------------------------\n".
		"# $msg\n".
		"#------------------------------------------------------------------\n\n";
	c_print($msg);
	writeLog($msg,'shark.log');
}


sub _removeFromGroup
	# Remove $wp_uuid from whatever group it currently belongs to by queuing
	# an API_MOD_ITEM for that group.
	#
	# Called before deleteWaypoint and from setWaypointGroup (My Waypoints move).
	# FIFO queue guarantees removal executes before any subsequent caller commands.
	#
	# Returns 1 immediately if the WP has no group memberships.
	# Returns 0 on error, 1 on success (command queued).
{
	my ($this,$wp_uuid) = @_;

	my $wp = $this->{waypoints}->{$wp_uuid};
	return error("_removeFromGroup: WP($wp_uuid) not in memory") if !$wp;

	my $wp_uuids = $wp->{uuids};
	return 1 if !$wp_uuids || !@$wp_uuids;

	my ($group,$group_uuid);
	for my $try_uuid (@$wp_uuids)
	{
		$group = $this->{groups}->{$try_uuid};
		if ($group) { $group_uuid = $try_uuid; last; }
	}
	return error("_removeFromGroup: group for WP($wp_uuid) not in memory") if !$group;

	my @new_uuids = grep { $_ ne $wp_uuid } @{$group->{uuids}};
	$group->{uuids} = shared_clone(\@new_uuids);

	my $buffer = buildGroup(0,$group,$TEMP_MON,$TEMP_COLOR);
	my $data = unpack('H*',$buffer);
	return $this->queueWPMGRCommand($API_MOD_ITEM,$WHAT_GROUP,$group->{name},$group_uuid,$data);
}


#--------------------------------------
# Waypoints
#--------------------------------------

sub createWaypoint
{
	my ($this,$hash) = @_;
	my $name    = $hash->{name};
	my $uuid    = $hash->{uuid};
	my $lat     = $hash->{lat};
	my $lon     = $hash->{lon};
	my $sym     = $hash->{sym}     // 25;
	my $ts      = $hash->{ts}      // timegm(localtime());
	my $comment = $hash->{comment} // '';
	my $depth   = $hash->{depth}   // 0;
	$this->showCommand("createWaypoint($name) uuid($uuid)");
	my $alt_coords = latLonToNorthEast($lat,$lon);
	my $buffer = buildWaypoint(0,{
		name    => $name,
		comment => $comment,
		lat     => int($lat * $SCALE_LATLON),
		lon     => int($lon * $SCALE_LATLON),
		north   => $alt_coords->{north},
		east    => $alt_coords->{east},
		sym     => $sym,
		depth   => $depth,
		date    => int($ts / $SECS_PER_DAY),
		time    => int($ts % $SECS_PER_DAY),
	},$TEMP_MON,$TEMP_COLOR);
	my $data = unpack('H*',$buffer);
	return $this->queueWPMGRCommand($API_NEW_ITEM,$WHAT_WAYPOINT,$name,$uuid,$data);
}


sub modifyWaypoint
{
	my ($this,$hash) = @_;
	my $uuid = $hash->{uuid};
	my $wp   = $this->{waypoints}{$uuid};
	return error("modifyWaypoint: uuid($uuid) not in memory") if !$wp;
	for my $key (keys %$hash)
	{
		next if $key eq 'uuid';
		$wp->{$key} = $hash->{$key};
	}
	$this->showCommand("modifyWaypoint($wp->{name}) uuid($uuid)");
	my $buffer = buildWaypoint(0,$wp,$TEMP_MON,$TEMP_COLOR);
	my $data = unpack('H*',$buffer);
	return $this->queueWPMGRCommand($API_MOD_ITEM,$WHAT_WAYPOINT,$wp->{name},$uuid,$data);
}


sub deleteWaypoint
{
	my ($this,$uuid) = @_;
	my $wp = $this->{waypoints}{$uuid};
	return error("deleteWaypoint: uuid($uuid) not in memory") if !$wp;
	my $name = $wp->{name};
	$this->showCommand("deleteWaypoint($name) uuid($uuid)");
	return if !$this->_removeFromGroup($uuid);
	return $this->queueWPMGRCommand($API_DEL_ITEM,$WHAT_WAYPOINT,$name,$uuid,0);
}


#--------------------------------------
# Groups
#--------------------------------------

sub createGroup
{
	my ($this,$hash) = @_;
	my $name    = $hash->{name};
	my $uuid    = $hash->{uuid};
	my $comment = $hash->{comment} // '';
	my $members = $hash->{members} // [];
	$this->showCommand("createGroup($name) uuid($uuid) members(".scalar(@$members).")");
	my $buffer = buildGroup(0,{
		name    => $name,
		comment => $comment,
		uuids   => shared_clone($members),
	},$TEMP_MON,$TEMP_COLOR);
	my $data = unpack('H*',$buffer);
	return $this->queueWPMGRCommand($API_NEW_ITEM,$WHAT_GROUP,$name,$uuid,$data);
}


sub modifyGroup
{
	my ($this,$hash) = @_;
	my $uuid  = $hash->{uuid};
	my $group = $this->{groups}{$uuid};
	return error("modifyGroup: uuid($uuid) not in memory") if !$group;
	if (exists $hash->{members})
	{
		$group->{uuids} = shared_clone($hash->{members});
	}
	for my $key (keys %$hash)
	{
		next if $key eq 'uuid' || $key eq 'members';
		$group->{$key} = $hash->{$key};
	}
	$this->showCommand("modifyGroup($group->{name}) uuid($uuid)");
	my $buffer = buildGroup(0,$group,$TEMP_MON,$TEMP_COLOR);
	my $data = unpack('H*',$buffer);
	return $this->queueWPMGRCommand($API_MOD_ITEM,$WHAT_GROUP,$group->{name},$uuid,$data);
}


sub deleteGroup
{
	my ($this,$uuid) = @_;
	my $group = $this->{groups}{$uuid};
	return error("deleteGroup: uuid($uuid) not in memory") if !$group;
	my $name = $group->{name};
	$this->showCommand("deleteGroup($name) uuid($uuid)");
	return $this->queueWPMGRCommand($API_DEL_ITEM,$WHAT_GROUP,$name,$uuid,0);
}


sub setWaypointGroup
	# Move $wp_uuid into $group_uuid.
	# $group_uuid = undef or 0 -> My Waypoints (no group).
	# Removes from existing group first; FIFO queue ensures ordering.
{
	my ($this,$wp_uuid,$group_uuid) = @_;
	my $wp = $this->{waypoints}{$wp_uuid};
	return error("setWaypointGroup: wp($wp_uuid) not in memory") if !$wp;

	if (!$group_uuid)
	{
		$this->showCommand("setWaypointGroup($wp->{name}) -> My Waypoints");
		return $this->_removeFromGroup($wp_uuid);
	}

	my $group = $this->{groups}{$group_uuid};
	return error("setWaypointGroup: group($group_uuid) not in memory") if !$group;
	$this->showCommand("setWaypointGroup($wp->{name}) -> $group->{name}");

	for my $try_uuid (@{$wp->{uuids} || []})
	{
		my $old_group = $this->{groups}{$try_uuid};
		next if !$old_group || $try_uuid eq $group_uuid;
		my $old_name = $old_group->{name};
		display(0,0,"removing wp($wp->{name}) from old group($old_name)");
		my @old_uuids = grep { $_ ne $wp_uuid } @{$old_group->{uuids}};
		$old_group->{uuids} = shared_clone(\@old_uuids);
		my $old_buf  = buildGroup(0,$old_group,$TEMP_MON,$TEMP_COLOR);
		my $old_data = unpack('H*',$old_buf);
		$this->queueWPMGRCommand($API_MOD_ITEM,$WHAT_GROUP,$old_name,$try_uuid,$old_data);
		last;
	}

	push @{$group->{uuids}},$wp_uuid;
	my $buffer = buildGroup(0,$group,$TEMP_MON,$TEMP_COLOR);
	my $data = unpack('H*',$buffer);
	return $this->queueWPMGRCommand($API_MOD_ITEM,$WHAT_GROUP,$group->{name},$group_uuid,$data);
}


#--------------------------------------
# Routes
#--------------------------------------

sub createRoute
{
	my ($this,$hash) = @_;
	my $name      = $hash->{name};
	my $uuid      = $hash->{uuid};
	my $comment   = $hash->{comment}   // '';
	my $color     = $hash->{color}     // $next_color++ % $NUM_ROUTE_COLORS;
	my $waypoints = $hash->{waypoints} // [];
	$this->showCommand("createRoute($name) uuid($uuid) wps(".scalar(@$waypoints).")");
	my @pts = map { shared_clone({}) } @$waypoints;
	my $buffer = buildRoute(0,{
		name    => $name,
		comment => $comment,
		bits    => 0,
		color   => $color,
		uuids   => shared_clone($waypoints),
		points  => shared_clone(\@pts),
	},$TEMP_MON,$TEMP_COLOR);
	my $data = unpack('H*',$buffer);
	return $this->queueWPMGRCommand($API_NEW_ITEM,$WHAT_ROUTE,$name,$uuid,$data);
}


sub modifyRoute
	# UNTESTED: whether MOD_ITEM with a full waypoints list replaces the E80 route sequence.
{
	my ($this,$hash) = @_;
	my $uuid  = $hash->{uuid};
	my $route = $this->{routes}{$uuid};
	return error("modifyRoute: uuid($uuid) not in memory") if !$route;
	if (exists $hash->{waypoints})
	{
		my @pts = map { shared_clone({}) } @{$hash->{waypoints}};
		$route->{uuids}  = shared_clone($hash->{waypoints});
		$route->{points} = shared_clone(\@pts);
	}
	for my $key (keys %$hash)
	{
		next if $key eq 'uuid' || $key eq 'waypoints';
		$route->{$key} = $hash->{$key};
	}
	$this->showCommand("modifyRoute($route->{name}) uuid($uuid)");
	my $buffer = buildRoute(0,$route,$TEMP_MON,$TEMP_COLOR);
	my $data = unpack('H*',$buffer);
	return $this->queueWPMGRCommand($API_MOD_ITEM,$WHAT_ROUTE,$route->{name},$uuid,$data);
}


sub deleteRoute
{
	my ($this,$uuid) = @_;
	my $route = $this->{routes}{$uuid};
	return error("deleteRoute: uuid($uuid) not in memory") if !$route;
	my $name = $route->{name};
	$this->showCommand("deleteRoute($name) uuid($uuid)");
	return $this->queueWPMGRCommand($API_DEL_ITEM,$WHAT_ROUTE,$name,$uuid,0);
}


sub routeWaypoint
	# Add or remove a single waypoint from an existing route.
	# $add: 1=add, 0=remove.
{
	my ($this,$route_uuid,$wp_uuid,$add) = @_;
	my $route = $this->{routes}{$route_uuid};
	return error("routeWaypoint: route($route_uuid) not in memory") if !$route;
	my $wp = $this->{waypoints}{$wp_uuid};
	return error("routeWaypoint: wp($wp_uuid) not in memory") if !$wp;
	my $route_name = $route->{name};
	$this->showCommand("routeWaypoint($route_name) wp($wp->{name}) add($add)");

	my @uuids  = @{$route->{uuids}};
	my @points = @{$route->{points}};
	my $exists = -1;
	for my $i (0..$#uuids)
	{
		if ($uuids[$i] eq $wp_uuid) { $exists = $i; last; }
	}
	return error("route($route_name) already contains wp($wp->{name})")  if  $add && $exists != -1;
	return error("route($route_name) does not contain wp($wp->{name})")  if !$add && $exists == -1;

	if ($add)
	{
		push @uuids,$wp_uuid;
		push @points,shared_clone({});
	}
	else
	{
		splice @uuids,$exists,1;
		splice @points,$exists,1;
	}

	$route->{uuids}  = shared_clone(\@uuids);
	$route->{points} = shared_clone(\@points);

	my $buffer = buildRoute(0,$route,$TEMP_MON,$TEMP_COLOR);
	my $data = unpack('H*',$buffer);
	$this->queueWPMGRCommand($API_MOD_ITEM,$WHAT_ROUTE,$route_name,$route_uuid,$data);
	return $this->queueWPMGRCommand($API_GET_ITEM,$WHAT_ROUTE,$route_name,$route_uuid,undef);
}


#--------------------------------------
# Query / display
#--------------------------------------

sub queryWaypoints
{
	my ($this) = @_;
	$this->showCommand("queryWaypoints()");
	return $this->queueWPMGRCommand($API_DO_QUERY,0,0,0,0);
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
		if ($rec->{name} eq $name) { $found = $uuid; last; }
	}
	return error("Could not find $what($name)") if !$found;
	my $rec  = $hash->{$found};
	my $text = wpmgrRecordToText($rec,uc($what),2,2,undef,$this);
	c_print("----------------------showItem($found=$name) -----------------------------\n$text\n\n");
}


1;
