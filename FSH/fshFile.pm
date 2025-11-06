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
#
# WHEN THEY SAY "ARCHIVE" THEY MEAN IT.
# Subsequent saves of Routes, at least, and I will confirm for Groups and
# Waypoints, MARK the existing Blocks for those items as "deleted" (see
# PRH NEWLY DISCOVERED) and NEW ONES ARE WRITTEN with 0x4000 for the
# (new) Block 'active' field.  Generally speaking, one could/should SKIP the unused
# blocks while parsing, or implement a "collection by UUID" for WRG's and
# thus, only take the last one of a particular uuid found, I suppose.

package apps::raymarine::FSH::fshFile;
use strict;
use warnings;
use POSIX qw(floor pow atan);
use Fcntl qw(:seek);
use Time::Local;
use Pub::Utils;
use apps::raymarine::FSH::fshUtils;

my $ACTIVE_BLOCKS_ONLY = 1;


my $dbg_file = 0;
my $dbg_flobs = 0;
my $dbg_blocks = 0;


my $FSH_FILE_HEADER_SIZE = 28;
my $FSH_FLOB_HEADER_SIZE = 14;
my $FSH_BLOCK_HEADER_SIZE = 14;
my $FILE_SIG = "RL90 FLASH FILE";
my $FLOB_SIG = "RAYFLOB1";
my $FLOB_SIZE = 0x10000;
my $FLOB_ACTIVE = 0x4000;
my $MIN_FLOBS = 16;



sub new
{
    my ($class,$filename) = @_;
	$filename ||= '';
    display(0,0,"new fshFile($filename)");
	my $this = {
		filename 	=> $filename,
		file_offset => 0,
		blocks 		=> [],

		track_points => {},  # BLK_TRK are parsed into arrays of points by uuid
		tracks => [],        # BLK_MTA track meta info records ARE the 'tracks'
			# E80 BLK_MTA's always come after their BLK_TRKS, so we can do
			# everything in a single loop through all blocks.  For each BLK_MTA
			# we find the track_points based on the MTA's 1st (only) sub-uuid,
			# and set the {points} member on the "track" record from that.
		waypoints => [],          # BLK_WPT recs from the inner common_waypoint
			# with {uuid} and {inner_uuid} members added to by the block
		routes => [],		# BLK_RTE very complicated data structures,
			# but each record has, at least, a NAME, possible COMMENT, and
			# an array of {wpts}
		groups => [],
			# groups have a name element and a {wpts} array
			# the waypoints have a {int_lat, and int_lon} members
			# which are the actual values * 1E7, as opposed to the
			# mercator projectsion lat/lon from northEastToLatLon()
	};

	bless $this,$class;


	if ($filename)
	{
		my $fh;
		if (!open($fh, '<:raw', $filename))
		{
			error "Could not open file($filename): $!";
			return undef;
		}

		my $num_flobs = $this->getFileHeader($fh);
		if ($num_flobs <= 0)
		{
			close $fh;
			error("Empty file (no flobs) $filename") if $num_flobs == 0;
			return undef;
		}

		display($dbg_file,0,"num_flobs=$num_flobs");

		for (my $i = 0; $i < $num_flobs; $i++)
		{
			display($dbg_flobs,1,"getting flob($i)");

			$this->{file_offset} = $FSH_FILE_HEADER_SIZE + $i * $FLOB_SIZE;
			if (!seek($fh,$this->{file_offset},0))
			{
				close $fh;
				error("Could not seek to FLOB[$i] at ".$this->showOffset());
				return undef;
			}


			# flobs are 0x10000 (64K) in length, and start at 0x1c
			# within them are blocks that are stream oriented

			if (!$this->getFlobHeader($fh,$i))
			{
				close $fh;	# error already reported
				return undef;
			}

			if (!$this->getFlobBlocks($fh,$i))
			{
				close $fh;	# error already reported
				return undef;
			}

		}

		close($fh);
		display(0,0,"fshFile got ".
			scalar(@{$this->{blocks}}).
			($ACTIVE_BLOCKS_ONLY ? ' active' : '').
			" blocks in $num_flobs flobs");

		display(0,0,"processing blocks ...");
		for my $block (@{$this->{blocks}})
		{
			return if !$this->decodeBlock($block);
		}
	}

	return $this;

}   # fshFile ctor






sub showOffset
{
	my ($this) = @_;
    return sprintf("%08X  ",$this->{file_offset});
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
    my ($this,$fh) = @_;
    my $header;
    if (!read($fh, $header, $FSH_FILE_HEADER_SIZE))
	{
		error("Could not read file header at ".$this->showOffset().": $!");
		return -1;
	}
    my ($file_sig, $num_flobs, $a, $b, $c, $d, $e) = unpack("A16 s6", $header);
        # A16 = read 16 bytes as string (including null terminator)
        # s6 = read six signed short integers
        #   a = always 0
        #   b = always 0
        #   c = always 1
        #   d = always 1
        #   e = always 1
	if ($file_sig ne $FILE_SIG)
	{
		error($this->showOffset()."Invalid FSH file: $file_sig");
		return -1;
	}
    display($dbg_file,0,$this->showOffset()."num_flobs=$num_flobs ($a,$b,$c,$d,$e)");
	$this->{file_offset} += $FSH_FILE_HEADER_SIZE;
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
    my ($this,$fh,$num) = @_;
    my $flob_header;

    if (!read($fh, $flob_header, $FSH_FLOB_HEADER_SIZE))
	{
		error("Could not read FLOB[$num] header at ".$this->showOffset().": $!");
		return 0;
	}
    my ($flob_sig, $a, $b, $c) = unpack("A8 s3", $flob_header);
        # A8 = read 8 bytes as string (no null terminator)
        # s3 = read 3 signed short integers
        #   a = always 1
        #   b = always 1
        #   c = 0xfffe, 0xfffc, or 0xfff0

    if ($flob_sig ne $FLOB_SIG)
	{
		error($this->showOffset()."Invalid FLOB[$num] header: $flob_sig");
		return 0;
	}
    display($dbg_flobs,0,$this->showOffset().sprintf("FLOB[$num] ($a,$b,0x%04x)",$c));
    $this->{file_offset} += $FSH_FLOB_HEADER_SIZE;
    return 1;
}


sub getBlock
    #   // total length 14 bytes
    #   typedef struct fsh_block_header
    #   {
    #       uint16_t len;     // length of block in bytes excluding this header
    #       uint64_t uuid;    // unique ID of block
    #       uint16_t type;    // type of block
    #       uint16_t active;  // PRH NEWLY DISCOVERED. 0x0000=deleted, 0x4000=active
    #   }
	#
	# I believe 0x4000 means "in use" and 0x0000 means 'free space' or 'deleted',
	# but the file keeps EVERYTHING you ever save.
{
    my ($this,$fh,$flob_num) = @_;
    my $block_header;

    if ($this->{file_offset} & 1)    # blocks must start on even bytes
    {
        $this->{file_offset}++;
        seek($fh,$this->{file_offset},0);
    }

    if (!read($fh, $block_header, $FSH_BLOCK_HEADER_SIZE))
	{
        error("Could not read FLOB header at ".$this->showOffset().": $!");
		return 0;
	}
	my ($len, $uuid, $type, $active) = unpack('Sa8SS', $block_header);
        # S = unsigned 16 bit integer
        # a8 = 8 byte (uint64) uuid
        # S = type
        # v = active = 0x4000 if in use; 0x0000 if unused (deleted/free space)
    my $block_type = blockTypeToStr($type);

    my $block_num = @{$this->{blocks}};
    my $msg = sprintf("flob($flob_num) [%-3s] %s uuid(%s) len(%d) active(0x%04x)",
		$block_num,
        _def($block_type),
        uuidToStr($uuid),
        $len,
		$active);
    display($dbg_blocks,1,$this->showOffset().$msg);

	if (!$block_type)
	{
	    error("UNKNOWN BLOCK TYPE ".sprintf("0x%04X",$type));
		return 0;
	}
    $this->{file_offset} += $FSH_BLOCK_HEADER_SIZE;

	return -1 if $type == $FSH_BLK_ILL;
		# no more blocks in this flob

	my $bytes = '';
	if (!read($fh, $bytes, $len))
	{
		error("Could not read BLOCK($len) at ".$this->showOffset().": $!");
		return 0;
	}
	if ($active || !$ACTIVE_BLOCKS_ONLY)
	{
		my $block = {
			flob_num => $flob_num,
			num => $block_num,
			type => $type,
			uuid => $uuid,
			active => $active,
			bytes => $bytes };
		push @{$this->{blocks}},$block;
	}
	
	$this->{file_offset} += $len;
	return 1;
}



sub getFlobBlocks
{
    my ($this,$fh,$flob_num) = @_;
    my $rslt = 1;
	while ($rslt>0)
	{
		$rslt = $this->getBlock($fh,$flob_num);
    }
    return $rslt;
}




#=======================================================
# write
#=======================================================
# Initial implementation
#
#	- packed WRGTs from shark are stuck into the empty fshFile structure
#     by shark.  At this time the FSH layer doesn't know how to pack records
#   - shark should not include pure 'waypoints' that are in 'groups',
#     i.e. it 'creates' the 'My Waypoints' folder, as it were.
#
#   - a whole new file is written, there are no 'inactive' blocks
#   - the minimum number of flobs are used
#   - the end of the last used flob is filled to FLOBSIZE with 0xff (marking remaining blocks as BLK_ILL)
#   - the file is filled out to 1MB with empty flobs

my $dbg_write = 0;
my $dbg_wflob = 0;
my $dbg_wblock = 0;


sub writeFileHeader
{
	my ($this,$fh,$num_flobs) = @_;
	display($dbg_write,0,"writeFileHeader() num_flobs($num_flobs)");
    my $header = $FILE_SIG.chr(0);
		# 16 bytes exactly
	$header .= pack("s6", $num_flobs,0,0,1,1,1);
        #   a = always 0
        #   b = always 0
        #   c = always 1
        #   d = always 1
        #   e = always 1
	if (!$fh->seek(0,SEEK_SET))
	{
		error("Could not seek to zero: $!");
		return 0;
	}
	if (!$fh->write($header))
	{
		error("Could not writeFileHeader: $!");
		return 0;
	}
	$this->{file_offset} += $FSH_FILE_HEADER_SIZE;
	return 1;
}


sub writeFlobHeader
{
	my ($this,$fh,$flob_num,$empty) = @_;
	display($dbg_wflob,0,"writeFlobHeader($flob_num)");

	my $indicator = $empty ? 0xfffe : 0xfffc;
		# dunno the semantics of this
	my $flob_header = $FLOB_SIG;
		# eight bytes exactly
    $flob_header .= pack("s3",1,1,$indicator);
        #   a = always 1
        #   b = always 1
        #   c = 0xfffe, 0xfffc, or 0xfff0
	if (!$fh->write($flob_header))
	{
		error("Could not writeFlobHeader($flob_num) at ".$this->showOffset().": $!");
		return 0;
	}
	$this->{file_offset} += $FSH_FLOB_HEADER_SIZE;
	return 1;
}


sub writeBlock
{
	my ($this,$fh,$block) = @_;
	my $uuid = $block->{uuid};
	my $type = $block->{type};
	my $active = $block->{active} ? $FLOB_ACTIVE : 0;
	my $num = $block->{num};
	my $bytes = $block->{bytes};
	my $len = length($bytes);
	if ($len & 1)
	{
		$bytes .= chr(0);
		$len++;
	}

	my $block_type = blockTypeToStr($type);
	my $show_uuid = uuidToStr($uuid);

	display($dbg_wblock,1,$this->showOffset()." writeBlock($num) type($block_type) uuid=$show_uuid  len($len) ");

	my $block_header = pack('SA8SS', $len,$uuid,$type,$active);
	    # S = unsigned 16 bit integer
        # A8 = 8 byte (uint64) uuid
        # S = type
        # S = active = 0x4000 if in use; 0x0000 if unused (deleted/free space)
	if (!$fh->write($block_header))
	{
		error("Could not writeBlock($num) header at ".$this->showOffset().": $!");
		return 0;
	}
    $this->{file_offset} += $FSH_BLOCK_HEADER_SIZE;

	if (!$fh->write($bytes))
	{
		error("Could not writeBlock($num) len($len) ".$this->showOffset().": $!");
		return 0;
	}
	$this->{file_offset} += $len;

	return 1;
}





sub write
{
	my ($this,$ofilename) = @_;
	my $num_blocks = @{$this->{blocks}};
	display($dbg_write,0,"WRITING $num_blocks blocks to '$ofilename'");

	my $fh;
	if (!open($fh,">$ofilename"))
	{
		error "Could not open file($ofilename) for writing: $!";
		return 0;
	}
	binmode($fh);

	# write empty file header

	$this->{file_offset} = 0;
	if (!$this->writeFileHeader($fh,0))
	{
		close($fh);
		return 0;
	}

	# first test case; see if we can simply write the same file we parsed
	# with the existing blocks but new flobs

	my $flob_num = -1;
	my $flob_offset = 0;
	for my $block (@{$this->{blocks}})
	{
		# we need to allow room for one illegal block to terminate the flob
		# display_hash(0,0,"block",$block);
		
		my $len = length($block->{bytes});
		$len++ if $len & 1;		# no odd size blocks

		my $block_size = $FSH_BLOCK_HEADER_SIZE + $len;
		if ($flob_num<0 || $flob_offset + $block_size + $FSH_BLOCK_HEADER_SIZE > $FLOB_SIZE)
		{
			$flob_num++;
			if (!$this->writeFlobHeader($fh,$flob_num))
			{
				close $fh;
				return 0;
			}
			$flob_offset = $FSH_FLOB_HEADER_SIZE;
		}

		if (!$this->writeBlock($fh,$block))
		{
			close $fh;
			return 0;
		}
		$flob_offset += $block_size;
	}

	# finish off the flob
	# questions whether a file with no flobs is valid
	# or if a file really needs to be 1MB.  I think
	# raymarine just pads it all out in case.

	if ($flob_offset < $FLOB_SIZE)
	{
		my $num = $FLOB_SIZE - $flob_offset;
		display($dbg_write,1,"padding flob($flob_num) with $num bytes");
		if (!$fh->write(chr(0xff) x $num))
		{
			close $fh;
			error("Could not write flob($flob_num) remainder($num) ".$this->showOffset().": $!");
			return 0;
		}
		$this->{file_offset} += $num;
		$flob_num++;
	}

	while ($flob_num < $MIN_FLOBS)
	{
		display($dbg_write,1,"writing empty flob($flob_num)");
		if (!$this->writeFlobHeader($fh,$flob_num,1))
		{
			close $fh;
			return 0;
		}
		if (!$fh->write(chr(0xff) x ($FLOB_SIZE - $FSH_FLOB_HEADER_SIZE)))
		{
			error("Could not write empty flob($flob_num) ".$this->showOffset().": $!");
			return 0;
		}
		$this->{file_offset} += $FLOB_SIZE - $FSH_FLOB_HEADER_SIZE;
		$flob_num++;
	}
	
	my $file_size = $this->{file_offset};
	if (!$this->writeFileHeader($fh,$flob_num))
	{
		close($fh);
		return 0;
	}

	close($fh);
	display(0,0,"Wrote $flob_num flobs with $num_blocks blocks in $file_size bytes to $ofilename!!");
	return 1;
}




1;  #end of fshFile.pm