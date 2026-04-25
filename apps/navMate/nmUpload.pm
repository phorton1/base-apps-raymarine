#---------------------------------------------
# nmUpload.pm
#---------------------------------------------
# Upload navMate collection to E80 via WPMGR.
# Skips any item whose UUID is already in E80 in-memory state.
#
# Phase 1: waypoints (createNamedWaypoint — queued, WPMGR processes serially)
# Phase 2: routes (buildRoute with all waypoints embedded — one NEW_ITEM per route)
# Groups and tracks are not uploaded.

package nmUpload;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils qw(display warning error);
use apps::raymarine::NET::b_records;
use apps::raymarine::NET::e_wp_defs;
use apps::raymarine::NET::c_RAYDP;
use c_db;


BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(
		isWPMGRConnected
		uploadCollectionToE80
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
		$wpmgr->createNamedWaypoint(
			$wp->{name}, $wp->{uuid},
			$wp->{lat},  $wp->{lon},
			$wp->{sym}  // 25);
		$wp_count++;
	}
	display(0,0,"upload($coll_name): queued $wp_count waypoints");

	# Phase 2: routes — build complete buffer with all waypoints embedded

	my $route_count = 0;
	for my $r (@{$wrgt->{routes}})
	{
		next if $e80_routes{$r->{uuid}};
		my $wps      = getRouteWaypoints($dbh, $r->{uuid});
		my @wp_uuids = map { $_->{uuid}       } @$wps;
		my @pts      = map { shared_clone({}) } @$wps;

		my $buffer = buildRoute(0, {
			name   => $r->{name},
			bits   => 0,
			color  => ($r->{color} // 0) + 0,
			uuids  => shared_clone(\@wp_uuids),
			points => shared_clone(\@pts),
		}, 0, 0);
		my $data = unpack('H*', $buffer);

		display(0,1,"uploading route($r->{name}) " . scalar(@$wps) . " wps");
		$wpmgr->queueWPMGRCommand($API_NEW_ITEM, $WHAT_ROUTE,
			$r->{name}, $r->{uuid}, $data);
		$route_count++;
	}

	disconnectDB($dbh);
	display(0,0,"upload($coll_name): queued $route_count routes");
}


1;
