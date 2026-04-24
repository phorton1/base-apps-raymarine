#---------------------------------------------
# a_utils.pm
#---------------------------------------------

package a_utils;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time);
use Pub::Utils;
use a_defs;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		$appGroup
		makeUUID
	);
}


#---------------------------------
# main
#---------------------------------

our $appGroup = 'raymarine';

$USE_SHARED_LOCK_SEM = 1;
Pub::Utils::initUtils();
setStandardTempDir($appGroup);
setStandardDataDir($appGroup);


#---------------------------------
# makeUUID
#---------------------------------

sub makeUUID
	# Generate a navMate UUID (16 hex chars = 8 bytes).
	# Byte 1 = 0x4E ('N') identifies navMate-created objects.
	# Bytes 4-5 hold the persistent counter (little-endian).
	# Byte 0 and bytes 2-3 are random; bytes 6-7 are intra-tick random.
{
	my ($counter) = @_;
	return sprintf("%02x4e%04x%s%04x",
		int(rand(256)),
		int(rand(65536)),
		unpack('H*', pack('v', $counter)),
		int(rand(65536)));
}


1;
