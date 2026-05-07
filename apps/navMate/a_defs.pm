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

		$NAVMATE_DATABASE

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

		$NODE_TYPE_BRANCH
		$NODE_TYPE_GROUP

		$CTX_CMD_COPY
		$CTX_CMD_CUT

		$CTX_CMD_PASTE
		$CTX_CMD_PASTE_NEW
		$CTX_CMD_PASTE_BEFORE
		$CTX_CMD_PASTE_AFTER
		$CTX_CMD_PASTE_NEW_BEFORE
		$CTX_CMD_PASTE_NEW_AFTER

		$CTX_CMD_DELETE_WAYPOINT
		$CTX_CMD_DELETE_GROUP
		$CTX_CMD_DELETE_GROUP_WPS
		$CTX_CMD_DELETE_ROUTE
		$CTX_CMD_REMOVE_ROUTEPOINT
		$CTX_CMD_DELETE_TRACK
		$CTX_CMD_DELETE_BRANCH

		$CTX_CMD_NEW_WAYPOINT
		$CTX_CMD_NEW_GROUP
		$CTX_CMD_NEW_ROUTE
		$CTX_CMD_NEW_BRANCH

	);
}


our $NAVMATE_DATABASE = 'C:/dat/Rhapsody/navMate.db';

# Schema version: integer part = breaking change (reimport required),
# decimal part = non-breaking change (advisory).
our $SCHEMA_VERSION = '10.0';

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

# collections.node_type values (DB-level only; import uses transient 'routes'/'groups'/'tracks' strings internally)
our $NODE_TYPE_BRANCH = 'branch';
our $NODE_TYPE_GROUP  = 'group';

# Context menu command IDs
our $CTX_CMD_COPY = 10010;
our $CTX_CMD_CUT  = 10110;

our $CTX_CMD_PASTE           = 10300;
our $CTX_CMD_PASTE_NEW       = 10301;
our $CTX_CMD_PASTE_BEFORE    = 10302;
our $CTX_CMD_PASTE_AFTER     = 10303;
our $CTX_CMD_PASTE_NEW_BEFORE = 10304;
our $CTX_CMD_PASTE_NEW_AFTER  = 10305;

our $CTX_CMD_DELETE_WAYPOINT   = 10410;
our $CTX_CMD_DELETE_GROUP      = 10420;
our $CTX_CMD_DELETE_GROUP_WPS  = 10421;
our $CTX_CMD_DELETE_ROUTE      = 10430;
our $CTX_CMD_REMOVE_ROUTEPOINT = 10431;
our $CTX_CMD_DELETE_TRACK      = 10440;
our $CTX_CMD_DELETE_BRANCH     = 10450;

our $CTX_CMD_NEW_WAYPOINT = 10510;
our $CTX_CMD_NEW_GROUP    = 10520;
our $CTX_CMD_NEW_ROUTE    = 10530;
our $CTX_CMD_NEW_BRANCH   = 10550;


1;
