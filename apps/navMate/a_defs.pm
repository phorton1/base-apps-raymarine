#---------------------------------------------
# a_defs.pm
#---------------------------------------------

package a_defs;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(

		$WITH_WX

		$NODE_TYPE_BRANCH
		$NODE_TYPE_WAYPOINTS
		$NODE_TYPE_ROUTES
		$NODE_TYPE_TRACKS

		$TS_SOURCE_E80
		$TS_SOURCE_KML_TIMESPAN
		$TS_SOURCE_PHORTON
		$TS_SOURCE_IMPORT

		$OBJ_TYPE_WAYPOINT
		$OBJ_TYPE_ROUTE
		$OBJ_TYPE_TRACK

	);
}


our $WITH_WX = 1;

# collections.node_type values
our $NODE_TYPE_BRANCH    = 'branch';
our $NODE_TYPE_WAYPOINTS = 'waypoints';
our $NODE_TYPE_ROUTES    = 'routes';
our $NODE_TYPE_TRACKS    = 'tracks';

# ts_source values (waypoints.ts_source, tracks.ts_source)
our $TS_SOURCE_E80          = 'e80';
our $TS_SOURCE_KML_TIMESPAN = 'kml_timespan';
our $TS_SOURCE_PHORTON      = 'phorton';
our $TS_SOURCE_IMPORT       = 'import';

# working_set_members.object_type values
our $OBJ_TYPE_WAYPOINT = 'waypoint';
our $OBJ_TYPE_ROUTE    = 'route';
our $OBJ_TYPE_TRACK    = 'track';


1;
