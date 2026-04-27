#---------------------------------------------
# nmUpload.pm
#---------------------------------------------
# Upload navMate collection to E80 via WPMGR.
# Skips any item whose UUID is already in E80 in-memory state.
#
# Phase 1: waypoints uploaded via createWaypoint hash API
# Phase 2: routes uploaded via createRoute with embedded waypoint UUID list
# Phase 3: groups uploaded via createGroup with embedded member UUID list
# Tracks are not uploaded.

package nmUpload;
use strict;
use warnings;
use threads;
use Pub::Utils qw(display warning error);
use apps::raymarine::NET::c_RAYDP;
use c_db;


BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(
		isWPMGRConnected
		uploadCollectionToE80
		uploadRouteToE80
		uploadWaypointToE80
	);
}


sub isWPMGRConnected
{
	return $raydp && !!$raydp->findImplementedService('WPMGR', 1);
}


sub uploadCollectionToE80
{
	my ($coll_uuid, $coll_name) = @_;

	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR') : undef;
	unless ($wpmgr)
	{
		warning(0,0,"uploadCollectionToE80: WPMGR not connected");
		return;
	}

	my %e80_wps    = map { $_ => 1 } keys %{$wpmgr->{waypoints} // {}};
	my %e80_routes = map { $_ => 1 } keys %{$wpmgr->{routes}    // {}};
	my %e80_groups = map { $_ => 1 } keys %{$wpmgr->{groups}    // {}};

	display(0,0,"upload($coll_name): E80 has " .
		scalar(keys %e80_wps) . " wps, " .
		scalar(keys %e80_routes) . " routes");

	my $dbh  = connectDB();
	my $wrgt = getCollectionWRGTs($dbh, $coll_uuid);

	# Phase 1: waypoints

	my $wp_count = 0;
	for my $wp (@{$wrgt->{waypoints}})
	{
		next if $e80_wps{$wp->{uuid}};
		display(0,1,"uploading wp($wp->{name})");
		$wpmgr->createWaypoint({
			name => $wp->{name}, uuid => $wp->{uuid},
			lat  => $wp->{lat},  lon  => $wp->{lon},
			sym  => $wp->{sym}  // 25,
			ts   => $wp->{created_ts},
		});
		$wp_count++;
	}
	display(0,0,"upload($coll_name): queued $wp_count waypoints");

	# Phase 2: routes
	# Large routes are split across multiple 498-byte BUFFER messages by buildBufferMsgs
	# inside create_item; no size limit on the upload side.

	my $route_count = 0;
	for my $r (@{$wrgt->{routes}})
	{
		next if $e80_routes{$r->{uuid}};
		my $wps = getRouteWaypoints($dbh, $r->{uuid});
		display(0,1,"uploading route($r->{name}) " . scalar(@$wps) . " wps");

		my @wp_uuids = map { $_->{uuid} } @$wps;
		$wpmgr->createRoute({
			name      => $r->{name},
			uuid      => $r->{uuid},
			color     => ($r->{color} // 0) + 0,
			waypoints => \@wp_uuids,
		});
		$route_count++;
	}

	# Phase 3: groups
	# Each sub-collection that directly owns waypoints becomes one E80 group.
	# The group buffer is pre-populated with all member UUIDs so that a single
	# NEW_ITEM creates the group and its membership in one round-trip.
	# Phase 1 waypoints are queued before Phase 3 groups, so by the time the
	# E80 processes the group command all referenced waypoints already exist.

	my $groups = getCollectionGroups($dbh, $coll_uuid);
	my $grp_count = 0;
	for my $grp (@$groups)
	{
		next if $e80_groups{$grp->{uuid}};
		my @wp_uuids = map { $_->{uuid} } @{$grp->{waypoints}};
		display(0,1,"uploading group($grp->{name}) " . scalar(@wp_uuids) . " wps");
		$wpmgr->createGroup({
			name    => $grp->{name},
			uuid    => $grp->{uuid},
			members => \@wp_uuids,
		});
		$grp_count++;
	}

	disconnectDB($dbh);
	display(0,0,"upload($coll_name): queued $route_count routes, $grp_count groups");
}


sub uploadRouteToE80
{
	my ($route_uuid, $route_name, $route_color) = @_;

	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR') : undef;
	unless ($wpmgr)
	{
		warning(0,0,"uploadRouteToE80: WPMGR not connected");
		return;
	}

	my %e80_wps    = map { $_ => 1 } keys %{$wpmgr->{waypoints} // {}};
	my %e80_routes = map { $_ => 1 } keys %{$wpmgr->{routes}    // {}};

	if ($e80_routes{$route_uuid})
	{
		display(0,0,"uploadRouteToE80($route_name): already on E80, skipping");
		return;
	}

	my $dbh = connectDB();
	my $wps = getRouteWaypoints($dbh, $route_uuid);

	my $wp_count = 0;
	for my $wp (@$wps)
	{
		next if $e80_wps{$wp->{uuid}};
		display(0,1,"uploading wp($wp->{name})");
		$wpmgr->createWaypoint({
			name => $wp->{name}, uuid => $wp->{uuid},
			lat  => $wp->{lat},  lon  => $wp->{lon},
			sym  => $wp->{sym}  // 25,
			ts   => $wp->{created_ts},
		});
		$wp_count++;
	}

	display(0,1,"uploading route($route_name) " . scalar(@$wps) . " wps");
	my @wp_uuids = map { $_->{uuid} } @$wps;
	$wpmgr->createRoute({
		name      => $route_name,
		uuid      => $route_uuid,
		color     => ($route_color // 0) + 0,
		waypoints => \@wp_uuids,
	});

	disconnectDB($dbh);
	display(0,0,"uploadRouteToE80($route_name): queued $wp_count waypoints + route");
}


sub uploadWaypointToE80
{
	my ($wp) = @_;

	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR') : undef;
	unless ($wpmgr)
	{
		warning(0,0,"uploadWaypointToE80: WPMGR not connected");
		return;
	}

	my %e80_wps = map { $_ => 1 } keys %{$wpmgr->{waypoints} // {}};
	if ($e80_wps{$wp->{uuid}})
	{
		display(0,0,"uploadWaypointToE80($wp->{name}): already on E80, skipping");
		return;
	}

	display(0,1,"uploading wp($wp->{name})");
	$wpmgr->createWaypoint({
		name => $wp->{name}, uuid => $wp->{uuid},
		lat  => $wp->{lat},  lon  => $wp->{lon},
		sym  => $wp->{sym}  // 25,
		ts   => $wp->{created_ts},
	});
	display(0,0,"uploadWaypointToE80($wp->{name}): queued");
}


1;
