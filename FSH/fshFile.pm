#--------------------------------------
# fshFile.pm
#--------------------------------------
# Based on the C code at https://github.com/rahra/parsefsh,
# which I hsve unzipped in /src/vsCode/parsefsh.
#
# This code mimics the C data structures from the parsefsh C
# code using perl unpack() calls.
#
# ARCHIVE.FSH is made up of 64K chunks called "flobs".
# Each Flob can have "blocks".
#
# fshFileToBlocks() parses the file and returns $all_blocks
# for further processing by fshBlocks.pm.

package apps::raymarine::FSH::fshFile;
use strict;
use warnings;
use POSIX qw(floor pow atan);
use Fcntl qw(:seek);
use Time::Local;
use Pub::Utils;
use apps::raymarine::FSH::fshUtils;


my $dbg_file = 1;
my $dbg_flobs = 1;
my $dbg_blocks = 0;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw (

        fshFileToBlocks
    );
}



my $global_blk_num = 0;
my $file_offset = 0;
my $all_blocks = [];

my $FSH_FILE_HEADER_SIZE = 28;
my $FSH_FLOB_HEADER_SIZE = 14;
my $FSH_BLOCK_HEADER_SIZE = 14;
my $FILE_SIG = "RL90 FLASH FILE";
my $FLOB_SIG = "RAYFLOB1";
my $FLOB_SIZE = 0x10000;



sub showOffset
{
    return sprintf("%08X  ",$file_offset);
}


sub getFileHeader
    #   // total length 28 bytes
    #   typedef struct fsh_file_header
    #   {
    #       char rl90[16];    //!< constant terminated string "RL90 FLASH FILE"
    #       int16_t flobs;    //!< # of FLOBs, 0x10 (16) or 0x80 (128)
    #       int16_t a;        //!< always 0
    #       int16_t b;        //!< always 0
    #       int16_t c;        //!< always 1
    #       int16_t d;        //!< always 1
    #       int16_t e;        //!< always 1
    #   }
{
    my ($fh) = @_;
    my $header;
    read($fh, $header, $FSH_FILE_HEADER_SIZE) ||
        return error("Could not read file header at ".showOffset().": $!");
    my ($file_sig, $num_flobs, $a, $b, $c, $d, $e) = unpack("A16 s6", $header);
        # A16 = read 16 bytes as string (including null terminators
        # s6 = read six signed short integers
        #   a = always 0
        #   b = always 0
        #   c = always 1
        #   d = always 1
        #   e = always 1
    return error(showOffset()."Invalid FSH file: $file_sig") if $file_sig ne $FILE_SIG;
    display($dbg_file,0,showOffset()."num_flobs=$num_flobs ($a,$b,$c,$d,$e)");
    $file_offset += $FSH_FILE_HEADER_SIZE;
    return $num_flobs;
}


sub getFlobHeader
    #   // total length 14 bytes
    #   typedef struct fsh_flob_header
    #   {
    #       char rflob[8];    //!< constant unterminated string "RAYFLOB1"
    #       int16_t f;        //!< always 1
    #       int16_t g;        //!< always 1
    #       int16_t h;        //!< 0xfffe, 0xfffc, or 0xfff0
    #   }
{
    my ($fh,$num) = @_;
    my $flob_header;

    read($fh, $flob_header, $FSH_FLOB_HEADER_SIZE) ||
        return error("Could not read FLOB[$num] header at ".showOffset().": $!");
    my ($flob_sig, $a, $b, $c) = unpack("A8 s3", $flob_header);
        # A8 = read 8 bytes as string (including null terminators
        # s3 = read 3 signed short integers
        #   a = always 1
        #   b = always 1
        #   c = 0xfffe, 0xfffc, or 0xfff0

    return error(showOffset()."Invalid FLOB[$num] header: $flob_sig") if $flob_sig ne $FLOB_SIG;
    display($dbg_flobs,0,showOffset()."FLOB[$num] ($a,$b,$c)");
    $file_offset += $FSH_FLOB_HEADER_SIZE;
    return 1;
}


sub getBlock
    #   // total length 14 bytes
    #   typedef struct fsh_block_header
    #   {
    #       uint16_t len;     //!< length of block in bytes excluding this header
    #       uint64_t guid;    //!< unique ID of block
    #       uint16_t type;    //!< type of block
    #       uint16_t unknown; //!< always 0x4000 ?
    #   }
{
    my ($fh) = @_;
    my $block_header;

    if ($file_offset & 1)    # blocks must start on even bytes
    {
        $file_offset++;
        seek($fh,$file_offset,0);
    }

    read($fh, $block_header, $FSH_BLOCK_HEADER_SIZE) ||
        return error("Could not read FLOB header at ".showOffset().": $!");
    my ($len, $guid, $type, $unknown) = unpack('SA8SS', $block_header);
        # S = unsigned 16 bit integer
        # A8 = 8 byte (uint64) guid
        # S = type
        # S = unknown (always 0x40000?)

    my $block_type = blockTypeToStr($type);
    my $block_num = ($type == $FSH_BLK_ILL) ? '' : $global_blk_num++;
    my $msg = sprintf("[%-3s] %s guid(%s) len(%d)", # type(0x%04x) unknown(0x%04x)",
        $block_num,
        $block_type,
        guidToStr($guid),
        $len); #,

    display($dbg_blocks,1,showOffset().$msg);
    return error("Illegal block type at ".showOffset())
        if $type > $FSH_BLK_GRP && $type != $FSH_BLK_ILL;
    $file_offset += $FSH_BLOCK_HEADER_SIZE;

    my $bytes = '';
    if ($type <= $FSH_BLK_GRP)
    {
        read($fh, $bytes, $len) ||
            return error("Could not read BLOCK($len) at ".showOffset().": $!");
    }
    $file_offset += $len;
    return {
        type => $type,
        guid => $guid,
        bytes => $bytes };
}


sub getFlobBlocks
{
    my ($fh) = @_;
    my $blk_num = 0;
    my $block = getBlock($fh);
    return 0 if !$block;

    while ($block && $block->{type} <= $FSH_BLK_GRP)
    {
        push @$all_blocks,$block;
        $block = getBlock($fh);
        return 0 if !$block;
    }
    return 1;
}


sub fshFileToBlocks
    # the process closes the file if this fails
{
    my ($filename) = @_;
    display(0,0,"fshFileToBlocks($filename)");
    open(my $fh, '<:raw', $filename) or die "Could not open file: $!";

    $file_offset = 0;
    $all_blocks = [];
    my $num_flobs = getFileHeader($fh);
    return error("Empty file (no flobs)") if !$num_flobs;

	display($dbg_flobs,0,"num_flobs=$num_flobs");

    for (my $i = 0; $i < $num_flobs; $i++)
    {
		display($dbg_flobs,1,"getting flob($i)");
        $file_offset = $FSH_FILE_HEADER_SIZE + $i * $FLOB_SIZE;
        return error("Could not seek to FLOB[$i] at ".showOffset())
            if !seek($fh,$file_offset,0);

        # flobs are 0x10000 (64K) in length, and start at 0x1c
        # within them are blocks that are stream oriented

        return 0 if !getFlobHeader($fh,$i);
        return 0 if !getFlobBlocks($fh);
    }

    close($fh);
    display(0,0,"fshFileToBlocks() got ".scalar(@$all_blocks)." blocks in $num_flobs flobs");
    return $all_blocks;

}   # fshFileToBlocks()




1;  #end of fshFile.pm