#---------------------------------------------
# e_wp_defs.pm
#---------------------------------------------

package e_wp_defs;	
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time sleep);
use Pub::Utils;
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

		%NAV_DIRECTION
		%NAV_WHAT
		%NAV_COMMAND

		$DIR_RECV
		$DIR_SEND
		$DIR_INFO

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
our $API_MOD_ITEM	= 5;


our $DIR_RECV		= 0x000;
our $DIR_SEND		= 0x100;
our $DIR_INFO		= 0x200;

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


our %NAV_DIRECTION = (
	$DIR_RECV => 'recv',
	$DIR_SEND => 'send',
	$DIR_INFO => 'info',
);

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
# seen between the E80 and RNS.  We only use some (most) of them.

our %WPMGR_PARSE_RULES = (

	# monadic

	$DIR_SEND	| $CMD_COUNT	=> [],		# returns NUMBER; can this count Routes & Groups?
	$DIR_SEND	| $CMD_EVERB	=> [],		# returns AVERB; only ever seen $WHAT_GROUP
	$DIR_SEND	| $CMD_CONTEXT  => [],		# both ways, establishes WHAT context;

	$DIR_SEND	| $CTX_DATABASE => [],		# WHAT_DATABASE is a special case
	$DIR_SEND	| $LST_DATABASE => [],		# WHAT_DATABASE is a special case
	$DIR_SEND	| $BUF_DATABASE => [],		# WHAT_DATABASE is a special case

	# single dword parameter
	# CMD_EVENT consists of a series of messages, starting with
	# FIND CMD_EVENT(0)'s ending with WHAT CMD_EVENT(1)'s bracketing
	# zero or more MODIFY messages

	$DIR_RECV	| $CMD_EVENT	=> [ 'evt_flag'  ],
		# Does not have a sequence number, uhm,
		# That dword is 0 or 1 inicating start, and end of an event series.
		# Indicates, generrally that WHAT items/dictinoaries have changed.
		# Brackets MODIFY messages with more detail about what changed.

	$DIR_RECV	| $CMD_NUMBER	=> [ 'db_count'	],		# count of used items (per WHAT?)
	$DIR_RECV	| $CTX_DATABASE	=> [ 'db_version' ],	# DATABASE is a specific non standard reply
	$DIR_RECV	| $CMD_AVERB	=> [ 'amagic'	],		# non standard, not understood reply

	$DIR_RECV	| $CMD_CONTEXT	=> [ 'success'  ],  	# can establish WHAT context
	$DIR_RECV	| $CMD_LIST		=> [ 'success'	],		# establishes WHAT context
	$DIR_RECV	| $CMD_DATA		=> [ 'success'	],		# establishes WHAT context
	$DIR_RECV	| $CMD_ITEM		=> [ 'success'	],		# reply to a successful delete (from sending UUID)
	$DIR_RECV	| $CMD_BUFFER	=> [ 'success'	],		# a response to an EXIST uuid call to delete a folder (no actual buffer)
	$DIR_RECV	| $CMD_EXIST	=> [ 'success'	],		# reply to a successful delete (from sending UUID)

	# success & uuid

	$DIR_RECV	| $CMD_UUID		=> [ 'success',	'uuid' ],	# reply to FIND

	# single parameter

	$DIR_SEND	| $CMD_ITEM		=> [ 'uuid'		],		# atomic command, returns DATA;
	$DIR_SEND	| $CMD_MODIFY 	=> [ 'uuid'		],		# I send this with no bits to start create_item()
	$DIR_SEND	| $CMD_UUID		=> [ 'uuid'		],		# REALLY seems to mean 'delete' on a send, and info on a recv
	$DIR_INFO	| $CMD_LIST		=> [ 'uuid'		],		# 00000000 00000000 = send/receive for listing indexes
	$DIR_INFO	| $CMD_LIST		=> [ 'uuid'		],		# received with uuid at end of DATA series
	$DIR_SEND	| $CMD_FIND		=> [ 'name16' 	],		# atomic command, returns UUID

	# uuid and bits

	$DIR_RECV	| $CMD_MODIFY	=> [ 'uuid', 'mod_bits' ],
		# Does not have a sequence number.
		# Received alone, or within EVENT series
		# CMD_MODIFY (which doesn't have a sequence number) are out of band messages where bits
		#		0 = new
		#		1 = deleted
		#		2 = changed

	$DIR_INFO	| $CMD_CONTEXT	=> [ 'uuid', 'context_bits' ],
		# 00000000 00000000 1n00000000	1n indicates DICTIONARY, n is 9,a,c
		# zzzzzzzz zzzzzzzz 0n00000000	0n indicates ITEM		 n is 0,1,2,3
		# zzzzzzzz zzzzzzzz 0300000000	I send for create_item() and modify_item()

	# leading magic number and uuid

	$DIR_SEND	| $CMD_EXIST	=> [ 'magic', 'uuid' ],		# atomic command BUT required for modify_item()
	$DIR_SEND	| $CMD_DATA		=> [ 'magic', 'uuid' ],		# I use this, after EXIST, for modify_item
		# 07000000 	cccccccc cccf0100
		# 0a000000 	dc82a921 f567e68e 	deleting a folder

	$DIR_INFO 	| $CMD_BUFFER 	=> [ 'buffer' ],
		# $CMD_BUFFER is handled specially
		# bits(1n00000) = dict_buffer_data	on send, CONTEXT bits(0x1n) the buffer is some kind of allocation scheme
		#									on recv, CONTEXT bits(0x1n) indicatss an INDEX (or dictionary if you prefer)
		# bits(0n00000) = item buffer 		on send/recv bits(0x0n) indicates an ITEM buffer, uuid given previously in series
);




1;
