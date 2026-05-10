#---------------------------------------------
# n_defs.pm
#---------------------------------------------

package n_defs;
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

		$CTX_CMD_SYNC

	);
}


our $NAVMATE_DATABASE = 'C:/dat/Rhapsody/navMate.db';

# Schema version: integer part = breaking change (reimport required),
# decimal part = non-breaking change (advisory).
our $SCHEMA_VERSION = '11.0';

# waypoints.wp_type values
our $WP_TYPE_NAV      = 'nav';
our $WP_TYPE_LABEL    = 'label';
our $WP_TYPE_SOUNDING = 'sounding';

# ts_source values (waypoints.ts_source, tracks.ts_source)
our $TS_SOURCE_E80          = 'e80';
our $TS_SOURCE_KML_TIMESPAN = 'kml_timespan';
our $TS_SOURCE_PHORTON      = 'phorton';
our $TS_SOURCE_IMPORT       = 'import';

# collections.node_type values (DB-level only; import uses transient 'routes'/'groups'/'tracks' strings internally)
our $NODE_TYPE_BRANCH = 'branch';
our $NODE_TYPE_GROUP  = 'group';

# Context menu command IDs
our $CTX_CMD_COPY				= 10200;
our $CTX_CMD_CUT				= 10201;

our $CTX_CMD_PASTE				= 10210;
our $CTX_CMD_PASTE_NEW			= 10211;
our $CTX_CMD_PASTE_BEFORE		= 10212;
our $CTX_CMD_PASTE_AFTER		= 10213;
our $CTX_CMD_PASTE_NEW_BEFORE	= 10214;
our $CTX_CMD_PASTE_NEW_AFTER	= 10215;

our $CTX_CMD_DELETE_WAYPOINT	= 10220;
our $CTX_CMD_DELETE_GROUP		= 10221;
our $CTX_CMD_DELETE_GROUP_WPS	= 10222;
our $CTX_CMD_DELETE_ROUTE		= 10223;
our $CTX_CMD_REMOVE_ROUTEPOINT	= 10224;
our $CTX_CMD_DELETE_TRACK		= 10225;
our $CTX_CMD_DELETE_BRANCH		= 10226;

our $CTX_CMD_NEW_WAYPOINT		= 10230;
our $CTX_CMD_NEW_GROUP			= 10231;
our $CTX_CMD_NEW_ROUTE			= 10232;
our $CTX_CMD_NEW_BRANCH			= 10233;

our $CTX_CMD_SYNC				= 10250;


1;
