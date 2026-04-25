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
		$SCHEMA_VERSION

		$WP_TYPE_NAV
		$WP_TYPE_LABEL
		$WP_TYPE_SOUNDING

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

# Schema version: integer part = breaking change (reimport required),
# decimal part = non-breaking change (advisory).
our $SCHEMA_VERSION = '2.0';

# waypoints.wp_type values
our $WP_TYPE_NAV      = 'nav';
our $WP_TYPE_LABEL    = 'label';
our $WP_TYPE_SOUNDING = 'sounding';

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
