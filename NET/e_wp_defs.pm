#---------------------------------------------
# e_wp_defs.pm
#---------------------------------------------

package apps::raymarine::NET::e_wp_defs;	
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time sleep);
use Pub::Utils;
use apps::raymarine::NET::a_defs;
my $dbg_wpp = -1;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(

		$API_NONE
		$API_DO_QUERY
		$API_GET_ITEM
		$API_NEW_ITEM
		$API_DEL_ITEM
		$API_MOD_ITEM

		%NAV_WHAT
		%NAV_COMMAND

		$WHAT_WAYPOINT
		$WHAT_ROUTE
		$WHAT_GROUP
		$WHAT_DATABASE

		$CMD_CONTEXT
		$CMD_BUFFER
		$CMD_LIST
		$CMD_ITEM
		$CMD_EXIST
		$CMD_EVENT
		$CMD_DATA
		$CMD_MODIFY
		$CMD_UUID
		$CMD_NUMBER
		$CMD_AVERB
		$CMD_BVERB
		$CMD_FIND
		$CMD_COUNT
		$CMD_EVERB
		$CMD_FVERB

		%WPMGR_PARSE_RULES

    );
}

our $API_NONE 		= 0;
our $API_DO_QUERY	= 1;
our $API_GET_ITEM	= 2;
our $API_NEW_ITEM 	= 3;
our $API_DEL_ITEM 	= 4;
our $API_MOD_ITEM		= 5;


our $WHAT_WAYPOINT	= 0x00;
our $WHAT_ROUTE		= 0x40;
our $WHAT_GROUP		= 0x80;
our $WHAT_DATABASE	= 0xb0;

our $CMD_CONTEXT	= 0x0;
our $CMD_BUFFER    	= 0x1;
our $CMD_LIST     	= 0x2;
our $CMD_ITEM		= 0x3;
our $CMD_EXIST		= 0x4;
our $CMD_EVENT     	= 0x5;
our $CMD_DATA		= 0x6;
our $CMD_MODIFY    	= 0x7;
our $CMD_UUID    	= 0x8;
our $CMD_NUMBER     = 0x9;
our $CMD_AVERB     	= 0xa;
our $CMD_BVERB     	= 0xb;
our $CMD_FIND		= 0xc;
our $CMD_COUNT     	= 0xd;
our $CMD_EVERB    	= 0xe;
our $CMD_FVERB     	= 0xf;


our %NAV_WHAT = (
	$WHAT_WAYPOINT  => 'WAYPOINT',
	$WHAT_ROUTE		=> 'ROUTE',
	$WHAT_GROUP		=> 'GROUP',
	$WHAT_DATABASE  => 'DATABASE',
);


our %NAV_COMMAND = (
	$CMD_CONTEXT => 'CONTEXT',
	$CMD_BUFFER  => 'BUFFER',
	$CMD_LIST    => 'LIST',
	$CMD_ITEM	 => 'ITEM',
	$CMD_EXIST	 => 'EXIST',
	$CMD_EVENT   => 'EVENT',
	$CMD_DATA	 => 'DATA',
	$CMD_MODIFY  => 'MODIFY',
	$CMD_UUID    => 'UUID',
	$CMD_NUMBER  => 'NUMBER',
	$CMD_AVERB   => 'AVERB',
	$CMD_BVERB   => 'BVERB',
	$CMD_FIND	 => 'FIND',
	$CMD_COUNT   => 'COUNT',
	$CMD_EVERB   => 'EVERB',
	$CMD_FVERB   => 'FVERB',
);


# SENDS and RECEIVES establish context

my $CTX_DATABASE = $WHAT_DATABASE | $CMD_CONTEXT;
my $LST_DATABASE = $WHAT_DATABASE | $CMD_LIST;
my $BUF_DATABASE = $WHAT_DATABASE | $CMD_BUFFER ;

# This list includes every Request and Reply I have ever
# seen between the E80 and RNS.  We use most of them.


our %WPMGR_PARSE_RULES = (

	# SEND (request) messages - terminal=0 (client sends; dispatchTCPSendMsg monitors only)

	$DIRECTION_SEND | $CMD_COUNT    => { pieces => ['seq'],              terminal => 0 },
	$DIRECTION_SEND | $CMD_EVERB    => { pieces => ['seq'],              terminal => 0 },
	$DIRECTION_SEND | $CMD_CONTEXT  => { pieces => ['seq'],              terminal => 0 },
	$DIRECTION_SEND | $CTX_DATABASE => { pieces => [],                   terminal => 0 },
	$DIRECTION_SEND | $LST_DATABASE => { pieces => [],                   terminal => 0 },
	$DIRECTION_SEND | $BUF_DATABASE => { pieces => [],                   terminal => 0 },
	$DIRECTION_SEND | $CMD_ITEM     => { pieces => ['seq','uuid'],       terminal => 0 },
	$DIRECTION_SEND | $CMD_MODIFY   => { pieces => ['seq','uuid'],       terminal => 0 },
	$DIRECTION_SEND | $CMD_UUID     => { pieces => ['seq','uuid'],       terminal => 0 },
	$DIRECTION_SEND | $CMD_FIND     => { pieces => ['seq','name16'],     terminal => 0 },
	$DIRECTION_SEND | $CMD_EXIST    => { pieces => ['seq','magic','uuid'], terminal => 0 },
	$DIRECTION_SEND | $CMD_DATA     => { pieces => ['seq','magic','uuid'], terminal => 0 },

	# RECV (reply) messages

	$DIRECTION_RECV | $CMD_NUMBER   => { pieces => ['seq','db_count'],   terminal => 1 },
	$DIRECTION_RECV | $CTX_DATABASE => { pieces => ['seq','db_version'], terminal => 1 },
	$DIRECTION_RECV | $CMD_AVERB    => { pieces => ['seq','amagic'],     terminal => 1 },
	$DIRECTION_RECV | $CMD_CONTEXT  => { pieces => ['seq','success'],    terminal => 0 },  # non-terminal: INFO messages follow
	$DIRECTION_RECV | $CMD_LIST     => { pieces => ['seq','success'],    terminal => 1 },  # modify_item DATA step
	$DIRECTION_RECV | $CMD_DATA     => { pieces => ['seq','success'],    terminal => 0 },  # dynamic: terminal only when success==0
	$DIRECTION_RECV | $CMD_ITEM     => { pieces => ['seq','success'],    terminal => 1 },  # create_item MODIFY step
	$DIRECTION_RECV | $CMD_BUFFER   => { pieces => ['seq','success'],    terminal => 0 },  # non-terminal
	$DIRECTION_RECV | $CMD_EXIST    => { pieces => ['seq','success'],    terminal => 1 },  # delete_item
	$DIRECTION_RECV | $CMD_UUID     => { pieces => ['seq','success','uuid'], terminal => 1 },  # FIND

	# EVENT messages - unsolicited, no seq_num

	$DIRECTION_RECV | $CMD_EVENT    => { pieces => ['evt_flag'],         terminal => 1, is_event => 1 },
	$DIRECTION_RECV | $CMD_MODIFY   => { pieces => ['uuid','mod_bits'],  terminal => 1, is_event => 1 },

	# INFO messages - client sends and E80 sends; INFO_LIST is terminal for several operations

	$DIRECTION_INFO | $CMD_LIST     => { pieces => ['seq','uuid'],       terminal => 1 },  # do_query, get_item(found), modify_item EXIST
	$DIRECTION_INFO | $CMD_CONTEXT  => { pieces => ['seq','uuid','context_bits'], terminal => 0 },
	$DIRECTION_INFO | $CMD_BUFFER   => { pieces => ['seq','buffer'],     terminal => 0 },

);




1;

