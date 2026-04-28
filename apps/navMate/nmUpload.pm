#---------------------------------------------
# nmUpload.pm
#---------------------------------------------
# Upload navMate collection to E80 via WPMGR submitBatch.
# Skips any item whose UUID is already in E80 in-memory state.
# Returns the number of ops submitted (0 if nothing to do).
#
# uploadCollectionToE80 and uploadRouteToE80 build an ordered ops list and
# call submitBatch once.  All ops execute serially in commandThread with full
# E80 handshaking between each, so ordering is guaranteed:
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
	my ($coll_uuid, $coll_name, $prog_data) = @_;

	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR') : undef;
	unless ($wpmgr)
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

	my @ops;

	for my $wp (@wps)
	{
		push @ops, {
			type    => 'new_wp',
			uuid    => $wp->{uuid},
			name    => $wp->{name},
			lat     => $wp->{lat},
			lon     => $wp->{lon},
			sym     => $wp->{sym} // 25,
			ts      => $wp->{created_ts} // 0,
			comment => $wp->{comment} // '',
		};
	}

	for my $entry (@routes_q)
	{
		my $r        = $entry->{route};
		my @wp_uuids = map { $_->{uuid} } @{$entry->{wps}};
		push @ops, {
			type      => 'new_route',
			uuid      => $r->{uuid},
			name      => $r->{name},
			color     => ($r->{color} // 0) + 0,
			waypoints => \@wp_uuids,
		};
	}

	for my $grp (@groups_q)
	{
		my @wp_uuids = map { $_->{uuid} } @{$grp->{waypoints}};
		push @ops, {
			type    => 'new_group',
			uuid    => $grp->{uuid},
			name    => $grp->{name},
			members => \@wp_uuids,
		};
	}

	my $total = scalar @ops;
	display(0,0,"upload($coll_name): $total ops (".
		scalar(@wps)." wps, ".scalar(@routes_q)." routes, ".scalar(@groups_q)." groups)");
	return 0 unless $total;

	if ($prog_data)
	{
		$prog_data->{total}  = $total;
		$prog_data->{active} = 1;
	}

	$wpmgr->submitBatch(\@ops, $prog_data);
	return $total;
}


sub uploadRouteToE80
{
	my ($route_uuid, $route_name, $route_color, $prog_data) = @_;

	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR') : undef;
	unless ($wpmgr)
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

	my @ops;
	for my $wp (grep { !$e80_wps{$_->{uuid}} } @$wps)
	{
		push @ops, {
			type    => 'new_wp',
			uuid    => $wp->{uuid},
			name    => $wp->{name},
			lat     => $wp->{lat},
			lon     => $wp->{lon},
			sym     => $wp->{sym} // 25,
			ts      => $wp->{created_ts} // 0,
			comment => $wp->{comment} // '',
		};
	}

	my @wp_uuids = map { $_->{uuid} } @$wps;
	push @ops, {
		type      => 'new_route',
		uuid      => $route_uuid,
		name      => $route_name,
		color     => ($route_color // 0) + 0,
		waypoints => \@wp_uuids,
	};

	my $total = scalar @ops;
	display(0,0,"uploadRouteToE80($route_name): $total ops");

	if ($prog_data)
	{
		$prog_data->{total}  = $total;
		$prog_data->{active} = 1;
	}

	$wpmgr->submitBatch(\@ops, $prog_data);
	return $total;
}


sub uploadWaypointToE80
{
	my ($wp, $prog_data) = @_;

	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR') : undef;
	unless ($wpmgr)
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

	if ($prog_data)
	{
		$prog_data->{total}  = 1;
		$prog_data->{active} = 1;
	}

	display(0,1,"uploading wp($wp->{name})");
	$wpmgr->createWaypoint({
		name     => $wp->{name}, uuid => $wp->{uuid},
		lat      => $wp->{lat},  lon  => $wp->{lon},
		sym      => $wp->{sym}  // 25,
		ts       => $wp->{created_ts},
		progress => $prog_data,
	});

	display(0,0,"uploadWaypointToE80($wp->{name}): queued");
	return 1;
}


1;
