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
		$API_DO_BATCH

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
our $API_DO_BATCH		= 6;


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

	# SEND (request) messages

	$DIRECTION_SEND	| $CMD_COUNT	=> [ 'seq' ],		# returns NUMBER; can this count Routes & Groups?
	$DIRECTION_SEND	| $CMD_EVERB	=> [ 'seq' ],		# unused by me; returns AVERB; only ever seen $WHAT_GROUP
	$DIRECTION_SEND	| $CMD_CONTEXT  => [ 'seq' ],		# both ways, establishes WHAT context;

	$DIRECTION_SEND	| $CTX_DATABASE => [ ],		# unused by me; monadic command (no sequence number) WHAT_DATABASE is a special case
	$DIRECTION_SEND	| $LST_DATABASE => [ ],		# unused by me; monadic command (no sequence number) WHAT_DATABASE is a special case
	$DIRECTION_SEND	| $BUF_DATABASE => [ ],		# unused by me; monadic command (no sequence number) WHAT_DATABASE is a special case

	$DIRECTION_SEND	| $CMD_ITEM		=> [ 'seq','uuid'	],		# atomic command, returns DATA;
	$DIRECTION_SEND	| $CMD_MODIFY 	=> [ 'seq','uuid'	],		# I send this with no bits to start create_item()
	$DIRECTION_SEND	| $CMD_UUID		=> [ 'seq','uuid'	],		# REALLY seems to mean 'delete' on a send, and info on a recv
	$DIRECTION_INFO	| $CMD_LIST		=> [ 'seq','uuid'	],		# 00000000 00000000 = send/receive for listing indexes
	$DIRECTION_INFO	| $CMD_LIST		=> [ 'seq','uuid'	],		# received with uuid at end of DATA series
	$DIRECTION_SEND	| $CMD_FIND		=> [ 'seq','name16' ],		# atomic command, returns UUID

	$DIRECTION_SEND	| $CMD_EXIST	=> [ 'seq','magic','uuid' ],	# atomic command BUT required for modify_item()
	$DIRECTION_SEND	| $CMD_DATA		=> [ 'seq','magic','uuid' ],	# I use this, after EXIST, for modify_item
		# 07000000 	cccccccc cccf0100
		# 0a000000 	dc82a921 f567e68e 	deleting a folder

	# RECV (reply) messages

	$DIRECTION_RECV	| $CMD_NUMBER	=> [ 'seq','db_count'	],		# count of used items (per WHAT?)
	$DIRECTION_RECV	| $CTX_DATABASE	=> [ 'seq','db_version' ],		# unused by me; DATABASE is a specific non standard reply
	$DIRECTION_RECV	| $CMD_AVERB	=> [ 'seq','amagic'	],			# unused by me; non standard, not understood reply

	$DIRECTION_RECV	| $CMD_CONTEXT	=> [ 'seq','success' 	],  	# can establish WHAT context
	$DIRECTION_RECV	| $CMD_LIST		=> [ 'seq','success'	],		# establishes WHAT context
	$DIRECTION_RECV	| $CMD_DATA		=> [ 'seq','success'	],		# establishes WHAT context
	$DIRECTION_RECV	| $CMD_ITEM		=> [ 'seq','success'	],		# reply to a successful delete (from sending UUID)
	$DIRECTION_RECV	| $CMD_BUFFER	=> [ 'seq','success'	],		# a response to an EXIST uuid call to delete a folder (no actual buffer)
	$DIRECTION_RECV	| $CMD_EXIST	=> [ 'seq','success'	],		# reply to a successful delete (from sending UUID)
	$DIRECTION_RECV	| $CMD_UUID		=> [ 'seq','success','uuid' ],	# reply to FIND


	# EVENT messages
	# CMD_EVENT consists of a series of messages, starting with
	# FIND CMD_EVENT(0)'s ending with WHAT CMD_EVENT(1)'s bracketing
	# zero or more MODIFY messages

	$DIRECTION_RECV	| $CMD_EVENT	=> [ 'evt_flag'  ],
		# Does not have a sequence number.
		# The evt_flag dword is 0 or 1 inicating start, and end of an event series.
		# Indicates, generrally that WHAT items/dictinoaries have changed.
		# Brackets MODIFY messages with more detail about what changed.

	$DIRECTION_RECV	| $CMD_MODIFY	=> [ 'uuid','mod_bits' ],
		# Does not have a sequence number.
		# Received alone, or within EVENT series
		# CMD_MODIFY (which doesn't have a sequence number) are out of band messages where bits
		#		0 = new
		#		1 = deleted
		#		2 = changed


	# INFO messages (within requests/replies)

	$DIRECTION_INFO	| $CMD_CONTEXT	=> [ 'seq','uuid','context_bits' ],
		# 00000000 00000000 1n00000000	1n indicates DICTIONARY, n is 9,a,c
		# zzzzzzzz zzzzzzzz 0n00000000	0n indicates ITEM		 n is 0,1,2,3
		# zzzzzzzz zzzzzzzz 0300000000	I send for create_item() and modify_item()
	$DIRECTION_INFO | $CMD_BUFFER 	=> [ 'seq','buffer' ],
		# $CMD_BUFFER is handled specially
		# bits(1n00000) = dict_buffer_data	on send, CONTEXT bits(0x1n) the buffer is some kind of allocation scheme
		#									on recv, CONTEXT bits(0x1n) indicatss an INDEX (or dictionary if you prefer)
		# bits(0n00000) = item buffer 		on send/recv bits(0x0n) indicates an ITEM buffer, uuid given previously in series

);




1;
