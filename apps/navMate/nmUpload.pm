#---------------------------------------------
# nmUpload.pm
#---------------------------------------------
# Upload navMate collection to E80 via direct WPMGR API calls.
# Skips any item whose UUID is already in E80 in-memory state.
# Returns the number of items submitted (0 if nothing to do).
#
# uploadCollectionToE80 and uploadRouteToE80 call individual API functions
# directly with $progress threaded through, in guaranteed order:
#   Phase 1: waypoints (must exist on E80 before routes/groups reference them)
#   Phase 2: routes
#   Phase 3: groups
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
	my ($coll_uuid, $coll_name, $progress_data) = @_;

	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR') : undef;
	if (!$wpmgr)
	{
		warning(0,0,"uploadCollectionToE80: WPMGR not connected");
		return 0;
	}

	my %e80_wps    = map { $_ => 1 } keys %{$wpmgr->{waypoints} // {}};
	my %e80_routes = map { $_ => 1 } keys %{$wpmgr->{routes}    // {}};
	my %e80_groups = map { $_ => 1 } keys %{$wpmgr->{groups}    // {}};

	my $dbh    = connectDB();
	my $wrgt   = getCollectionWRGTs($dbh, $coll_uuid);
	my $groups = getCollectionGroups($dbh, $coll_uuid);

	my @wps      = grep { !$e80_wps{$_->{uuid}}    } @{$wrgt->{waypoints}};
	my @groups_q = grep { !$e80_groups{$_->{uuid}} } @$groups;

	my @routes_q;
	for my $r (@{$wrgt->{routes}})
	{
		next if $e80_routes{$r->{uuid}};
		my $route_wps = getRouteWaypoints($dbh, $r->{uuid});
		push @routes_q, { route => $r, wps => $route_wps };
	}
	disconnectDB($dbh);

	my $total = scalar(@wps) + scalar(@routes_q) + scalar(@groups_q);
	display(0,0,"upload($coll_name): $total ops (".
		scalar(@wps)." wps, ".scalar(@routes_q)." routes, ".scalar(@groups_q)." groups)");
	return 0 if !$total;

	if ($progress_data)
	{
		$progress_data->{total}  = $total;
		$progress_data->{active} = 1;
	}

	for my $wp (@wps)
	{
		$wpmgr->createWaypoint({
			name     => $wp->{name},
			uuid     => $wp->{uuid},
			lat      => $wp->{lat},
			lon      => $wp->{lon},
			sym      => $wp->{sym} // 25,
			ts       => $wp->{created_ts} // 0,
			comment  => $wp->{comment} // '',
			progress => $progress_data,
		});
	}

	for my $entry (@routes_q)
	{
		my $r        = $entry->{route};
		my @wp_uuids = map { $_->{uuid} } @{$entry->{wps}};
		$wpmgr->createRoute({
			name      => $r->{name},
			uuid      => $r->{uuid},
			color     => ($r->{color} // 0) + 0,
			waypoints => \@wp_uuids,
			progress  => $progress_data,
		});
	}

	for my $grp (@groups_q)
	{
		my @wp_uuids = map { $_->{uuid} } @{$grp->{waypoints}};
		$wpmgr->createGroup({
			name     => $grp->{name},
			uuid     => $grp->{uuid},
			members  => \@wp_uuids,
			progress => $progress_data,
		});
	}

	return $total;
}


sub uploadRouteToE80
{
	my ($route_uuid, $route_name, $route_color, $progress_data) = @_;

	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR') : undef;
	if (!$wpmgr)
	{
		warning(0,0,"uploadRouteToE80: WPMGR not connected");
		return 0;
	}

	my %e80_wps    = map { $_ => 1 } keys %{$wpmgr->{waypoints} // {}};
	my %e80_routes = map { $_ => 1 } keys %{$wpmgr->{routes}    // {}};

	if ($e80_routes{$route_uuid})
	{
		display(0,0,"uploadRouteToE80($route_name): already on E80, skipping");
		return 0;
	}

	my $dbh = connectDB();
	my $wps = getRouteWaypoints($dbh, $route_uuid);
	disconnectDB($dbh);

	my @new_wps  = grep { !$e80_wps{$_->{uuid}} } @$wps;
	my $total    = scalar(@new_wps) + 1;
	display(0,0,"uploadRouteToE80($route_name): $total ops");

	if ($progress_data)
	{
		$progress_data->{total}  = $total;
		$progress_data->{active} = 1;
	}

	for my $wp (@new_wps)
	{
		$wpmgr->createWaypoint({
			name     => $wp->{name},
			uuid     => $wp->{uuid},
			lat      => $wp->{lat},
			lon      => $wp->{lon},
			sym      => $wp->{sym} // 25,
			ts       => $wp->{created_ts} // 0,
			comment  => $wp->{comment} // '',
			progress => $progress_data,
		});
	}

	my @wp_uuids = map { $_->{uuid} } @$wps;
	$wpmgr->createRoute({
		name      => $route_name,
		uuid      => $route_uuid,
		color     => ($route_color // 0) + 0,
		waypoints => \@wp_uuids,
		progress  => $progress_data,
	});

	return $total;
}


sub uploadWaypointToE80
{
	my ($wp, $progress_data) = @_;

	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR') : undef;
	if (!$wpmgr)
	{
		warning(0,0,"uploadWaypointToE80: WPMGR not connected");
		return 0;
	}

	my %e80_wps = map { $_ => 1 } keys %{$wpmgr->{waypoints} // {}};
	if ($e80_wps{$wp->{uuid}})
	{
		display(0,0,"uploadWaypointToE80($wp->{name}): already on E80, skipping");
		return 0;
	}

	if ($progress_data)
	{
		$progress_data->{total}  = 1;
		$progress_data->{active} = 1;
	}

	display(0,1,"uploading wp($wp->{name})");
	$wpmgr->createWaypoint({
		name     => $wp->{name}, uuid => $wp->{uuid},
		lat      => $wp->{lat},  lon  => $wp->{lon},
		sym      => $wp->{sym}  // 25,
		ts       => $wp->{created_ts},
		progress => $progress_data,
	});

	display(0,0,"uploadWaypointToE80($wp->{name}): queued");
	return 1;
}


1;
