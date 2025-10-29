#---------------------------------------------
# d_FILESYS.pm
#---------------------------------------------
# Provides read-only access to the removable media (CF card)
# on the MFD (E80).
#
# The FILESYS protocol works by setting up a UDP listener
# and then sending requests to the FILESYS udp port which
# then sends reponses to the listener.
#
# As far as I can tell, FILESYS is read-only and cannot
# modify the removable media.

package d_FILESYS;
use strict;
use warnings;
use threads;
use threads::shared;
use Socket;
use IO::Select;
use IO::Handle;
use IO::Socket::INET;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use a_defs;
use a_utils;
# use c_RAYSYS;
use base qw(b_sock);

# It is almost a shame to change this simply quirky code into
# more complex quirky code by implementing an E_PARSER, making
# the command-reply lifecycle live in two files.




my $dbg_fs = 1;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		$FILE_STATE_ILLEGAL
		$FILE_STATE_INIT
		$FILE_STATE_ERROR
		$FILE_STATE_COMPLETE
		$FILE_STATE_IDLE
		$FILE_STATE_START
		$FILE_STATE_BUSY
		%FILE_STATE_NAME
		
		$FAT_READ_ONLY
		$FAT_HIDDEN
		$FAT_SYSTEM
		$FAT_VOLUME_ID
		$FAT_DIRECTORY
		$FAT_FILE

    );
}






my $MAXIMUM_FILE_SIZE = 0x01ffffff;
	#  'ffffff01'; #;
	# Agrees with buffer size set for udp sockets in b_sock.
	# YAY .. its the maximum file length to retrieve.
	# The highest number I was able to plug in and get a response
	# is 0x1ffffff, which correlate to a maximum file size of 32M.
	# It took me a long time to figure out that the '9a9d0100' I'd
	# seen from RNS was not some kind of a "magic" key.

my $LONG_TIMEOUT    = 60;        # depends on setting of $BYTES_PER_REQUEST
my $SHORT_TIMEOUT   = 2;		 #

# implemented as a state machine that handles a single
# ui fileCommand, which sets START. The commandHandler
# sets BUSY and ends with COMPLETE or ERROR.
# Most commands are a single packet, excelt GET_FILE.
# If COMPLETE, {file_content} will contain the results, or
# on ERROR {file_error } will contain the 'error code'.

our $FILE_STATE_ILLEGAL   = -3; 	# used only by client winFILESYS to detect existence
our $FILE_STATE_ERROR     = -2;
our $FILE_STATE_COMPLETE  = -1;
our $FILE_STATE_IDLE      = 0;
our $FILE_STATE_START     = 1;
our $FILE_STATE_BUSY      = 2;

our %FILE_STATE_NAME = (
	$FILE_STATE_ILLEGAL		=>	'ILLEGAL',
	$FILE_STATE_ERROR		=>  'ERROR',
	$FILE_STATE_COMPLETE	=>  'COMPLETE',
	$FILE_STATE_IDLE		=>  'IDLE',
	$FILE_STATE_START		=>  'STARTED',
	$FILE_STATE_BUSY		=>  'BUSY',
);


# I could optimize fileCommand('DIR') to perform
# the 'get sizes' loop in handlePacket but that
# also would slow down recursive downloads.

#-----------------------
# FAT attribute bits
#-----------------------

our $FAT_READ_ONLY   = 0x01;
our $FAT_HIDDEN      = 0x02;
our $FAT_SYSTEM      = 0x04;
our $FAT_VOLUME_ID   = 0x08;
our $FAT_DIRECTORY   = 0x10;
our $FAT_FILE     	 = 0x20;


#-------------------------------
# commands
#-------------------------------

my $COMMAND_REQUEST     = pack('C',1);
my $COMMAND_REPLY       = pack('C',0);

#----- used command constants

my $COMMAND_DIRECTORY   = 0;		# returns a directory listing without any file or directory sizes (plus some other stuff)
my $COMMAND_GET_SIZE    = 1;		# returns a dword size of FILES only (success completely understood)
my $COMMAND_GET_FILE    = 2;		# returns the contents of a file (success completely understood) from a given offset
my $COMMAND_CARD_ID     = 9;		# returns a string (plus some other stuff) that I think is related to the particular CF card
    # the string 0014910F06D62062  returned with my RAY_DATA CF card in the E80
    # the string 0014802A08W79223  returned with Caribbean Navionics CF card in the E80

#------ unused command constants
# I probed these, and did not find them useful to the implementation
# I never got anything from probes of 3 or higher than 9

my $COMMAND_UNKNOWN 	= 3;		# I never got anything back from this in probing
my $COMMAND_GET_ATTR	= 4;		# returns dword size (files only) AND byte of attributes
	# does not return attrs on ROOT dirctory
	# apparently does not require extra inserted word(0)
my $COMMAND_FILE_EXISTS = 5;		# appears to return $FILE_SUCCESS on existing files only, an error otherwise
my $COMMAND_GET_SIZE2	= 6;		# appears to return exactly the same thing as GET_SIZE
	# but apparently does not want the extra insered word(0)
my $COMMAND_LOCK		= 7;		# increments an internal lock counter
my $COMMAND_UNLOCK		= 8;		# decrements an internal lock counter
	# LOCKING: it appears as if this implements an advisory database locking scheme.
	# The intent appaears to be that you call $COMMAND_UNLOCK and then
	# if it returns an error, you are free to increment the counter with $COMMAND_LOCK
	# which always returns $SUCCESS.  UNLOCK will return $SUCCEESS for as many times
	# as you called LOCK, and then start returning errors again.
	# I have not tested if the LOCK prevents modification to the CF card by the E80
	# while asserted, and as far as I can tell there is no way to modify the CF card
	# using the FILESYS protocol.

# ERROR CODES: If the operation fails, FILESYS returns
# something other than the $SUCCESS_CODE 00000400 after
# the sequence number. As far as I have seen it always
# returns at least the dword('01050480'), but on some
# calls it returns an extra dword that appears to contain
# buffer junk from whatever followed the 00000400 in the
# most recent success reply.



# GRUMBLE - MAJOR ISSUES EVEN WITH READ-ONLY
# (a) Once I GET_FILE archive.fsh, I can no longer save to the ARCHIVE.FSH
# (b) Even if you save WRGT's to ARCHIVE.FSH, you must removeCFCard before
#     those changes are actually written to the disk
#
# The fact of (a) really made me think FILESYS was writable and I spent
# 	a hard 14 hours probing it with no joy; still no response from cmd(3)
# Combined, these facts push us back to the notion that the use of ARCHIVE.FSH,
#	even with FILESYS remains an oneroous manual process


my %COMMAND_NUMBER = (
	'DIR'	=> $COMMAND_DIRECTORY,
	'SIZE'	=> $COMMAND_GET_SIZE,
	'FILE'	=> $COMMAND_GET_FILE,
	'ID'	=> $COMMAND_CARD_ID,
);

my %COMMAND_NAME = (
	$COMMAND_DIRECTORY	=> 'CMD_DIR',
	$COMMAND_GET_SIZE	=> 'CMD_GET_SIZE',
	$COMMAND_GET_FILE	=> 'CMD_GET_FILE',
	$COMMAND_UNKNOWN	=> 'CMD_UNKNOWN3',
	$COMMAND_GET_ATTR	=> 'CMD_GET_ATTR',
	$COMMAND_FILE_EXISTS=> 'CMD_FILE_EXISTS',
	$COMMAND_GET_SIZE2	=> 'CMD_GET_SIZE2',
	$COMMAND_LOCK		=> 'CMD_LOCK',
	$COMMAND_UNLOCK		=> 'CMD_UNLOCK',
	$COMMAND_CARD_ID	=> 'CMD_CARD_ID',
);

#---------------------------------------------------------
# instantiation
#---------------------------------------------------------
# 'become' and 'unbecome' a 'real' service with a socket

our $SHOW_FILESYS_RAW_INPUT 	= 1;
our $SHOW_FILESYS_RAW_OUTPUT	= 1;
our $SHOW_FILESYS_PARSED_INPUT  = 0;
our $SHOW_FILESYS_PARSED_OUTPUT	= 0;

my $IN_COLOR = $UTILS_COLOR_LIGHT_BLUE;
my $OUT_COLOR = $UTILS_COLOR_LIGHT_CYAN;


sub init
{
	my ($this) = @_;
	display($dbg_fs,0,"d_FILESYS init($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto} local_port=$FILESYS_PORT");

	$this->SUPER::init();
	
	$this->{local_ip}			= $LOCAL_IP;
	$this->{local_port}			= $FILESYS_PORT;
	$this->{COMMAND_TIMEOUT}	= $SHORT_TIMEOUT;

	$this->{show_raw_input} 	= $SHOW_FILESYS_RAW_INPUT;
	$this->{show_raw_output} 	= $SHOW_FILESYS_RAW_OUTPUT;
	$this->{show_parsed_input}  = $SHOW_FILESYS_PARSED_INPUT;
	$this->{show_parsed_output} = $SHOW_FILESYS_PARSED_OUTPUT;
	$this->{in_color} 			= $IN_COLOR;
	$this->{out_color} 			= $OUT_COLOR;

	$this->{file_state}       = $FILE_STATE_IDLE;
	$this->{file_error}       = '';
	$this->{file_command}     = 0;
	$this->{file_path}        = '';
	$this->{file_content}     = '';

	$this->{file_num_buffers} = 0;
	$this->{file_cur_buf_num} = 0;

	return $this;
}



sub destroy
{
	my ($this) = @_;
	display($dbg_fs,0,"d_FILESYS destroy($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto} local_port=$FILESYS_PORT");

	$this->SUPER::destroy();

    delete @$this{qw(
		file_state
		file_error
		file_command
		file_path
		file_content
	    file_num_buffers
	    file_cur_buf_num
	)};
	return $this;
}


sub setState
{
	my ($this,$new_state) = @_;
	lock($this);
	my $state = $this->{file_state};
	if (!( ($state == $FILE_STATE_START && $new_state == $FILE_STATE_BUSY) ||
		   ($state == $FILE_STATE_BUSY  && $new_state == $FILE_STATE_START) ))
	{
		my $old_name = $FILE_STATE_NAME{$state};
		my $new_name = $FILE_STATE_NAME{$new_state};
		display($dbg_fs,0,"setState(old=$old_name) ==> $new_name");
	}
	$this->{file_state} = $new_state;
}




#----------------------------------------------------
# winFILESYS specific API
#----------------------------------------------------

sub killAllJobs
{
	my ($this) = @_;

	my $TIMEOUT = 2;
	$this->{command_queue} 	  = shared_clone([]);
	$this->{COMMAND_TIMEOUT} = 0;

	my $start = time();
	while (time() <= $start + $TIMEOUT && $this->{file_state} > 0)
	{
		sleep(0.1);
	}

	$this->setState($FILE_STATE_IDLE);
	$this->{file_error}       = '';
	$this->{file_command}     = 0;
	$this->{file_path}        = '';
	$this->{file_content}     = '';
}


sub clearFileRequestError
{
	my ($this) = @_;
	return error("clearFileRequestError() called in $this->{file_state}")
		if $this->{file_state} != $FILE_STATE_ERROR;
	$this->{file_error} = '';
	$this->setState($FILE_STATE_IDLE);
}


sub setServicePort
{
	my ($this,$other) = @_;
	if ($this->{ip} ne $other->{ip} ||
		$this->{port} != $other->{port})
	{
		$this->{ip} = $other->{ip} ;
		$this->{port} = $other->{port};
		warning(0,0,"changing service_port(FILESYS) to $this->{ip}:$this->{port}");
	}
	else
	{
		warning(0,0,"did not change service_port(FILESYS); already was $this->{ip}:$this->{port}");
	}
}




#---------------------------------------------
# UI COMMAND
#---------------------------------------------
# ID
# DIR path
# SIZE path
# FILE path

sub fileCommand
{
	my ($this,$command_str,$path) = @_;
	$command_str = uc($command_str);
	$path |= '';
	display($dbg_fs,0,"fileCommand($command_str,$path)");

	my $cmd = $COMMAND_NUMBER{$command_str};
	return error("unknown fileCommand($command_str)") if !defined($cmd);

	my $state = $this->{file_state};
	return error("busy in state $FILE_STATE_NAME{$state}") if $state > 0;

	return error("FILESYS not running") 	if !$this->{running};
	return error("FILESYS not connected") 	if !$this->{connected};
	return error("FILESYS stopping") 		if $this->{stopping};
	return error("FILESYS destroyed") 		if $this->{destroyed};

	$this->{file_cur_buf_num} = 0;
	$this->{file_num_buffers} = 0;
	$this->{file_command} 	 = $cmd;
	$this->{file_path} 		 = $path;

	# Perl weirdness: if I set $file_content='' here, and then do a directory
	# listing which sets it to a shared_clone([]), it works the first time.
	# If I then do a second command of any kind, Perl seems to crash on the
	# second $file_content='' here, as if there's a problem in changing the
	# type of the var from a shared array to a scalar.  But if I set
	# $file_content=shared_clone([]) here, then I can do multiple directories
	# in a row. But then of course, my current code for getting a file breaks
	# and if I try to fix it by setting $file_content='' if ref($file_content)
	# then Perl dies at that statement.  Therefore, directory contents are
	# delivered as \n delimited lines of tab delimited fields in a known order.

	$this->{file_content} 	= '';
	$this->{file_error} 	= '';
	$this->setState($FILE_STATE_START);

	# push a place keeper command

	my $command = shared_clone({
		name => $command_str, });
	push @{$this->{command_queue}},$command;
	return 1;
}



#----------------------------------------------------
# handleCommand()
#----------------------------------------------------
# The FILE command is modified to do GET_SIZE2 before
# calling GET_FILE, in order to get the file size, and
# then to download 1K at a time in handshake individual
# request/reply sequemces, for the 1st 10K to see if I
# can get encrypted navionics charts.


sub dbgFatStr
{
	my ($attr) = @_;
	my $text = sprintf("flag(0x%02x) ",$attr);
	$text .= 'VOL  ' 	if $attr & $FAT_VOLUME_ID;
	$text .= 'DIR  ' 	if $attr & $FAT_DIRECTORY;
	$text .= 'FILE ' 	if $attr & $FAT_FILE;
	$text .= 'r'  		if $attr & $FAT_READ_ONLY;
	$text .= 'h'  		if $attr & $FAT_HIDDEN;
	$text .= 's'  		if $attr & $FAT_SYSTEM;
	$text = pad($text,20);
	return $text;
}


sub buildCommand
{
	my ($this,$cmd,$seq,$path,$offset,$size) = @_;

	$offset = 0 if !defined($offset);
	$size = $MAXIMUM_FILE_SIZE if !defined($size);

	my $offset_packed = pack('V',$offset);
	my $size_packed = pack('V',$size);

	#-------------------------------
	# Build the request packet
	#-------------------------------
	# The header of the request never changes

	my $len = length($path) + 1;
	my $packet = pack('C',$cmd);
	$packet .= $COMMAND_REQUEST;
	$packet .= pack('v',$FILESYS_SERVICE_ID);
	$packet .= pack('V',$seq);
	$packet .= pack('v',$FILESYS_PORT);

	# The path is optional on some comannds.
	# The path must be preceded by things on some commands.

	if ($path)
	{
		$packet .= pack('H*','0000') if $cmd == $COMMAND_GET_SIZE;
			# add a dword for GET_SIZE; no idea of its semantic
		$packet .= $offset_packed.$size_packed if $cmd == $COMMAND_GET_FILE;
			# '00000000' = offset within the file to start getting from
		$packet .= pack('v',$len);
		$packet .= $path;
		$packet .= chr(0);
			# it is not clear if this terminating null is required
			# but it does not hurt anything
	}
	return $packet;
}



sub doOneIteration
{
	my ($this,$cmd,$path,$offset,$size) = @_;
	my $seq = $this->{next_seqnum}++;
	display($dbg_fs,0,"doOneIteration($cmd) path($path) offset($offset) size($size)");

	my $packet = $this->buildCommand($cmd,$seq,$path,$offset,$size);

	#-------------------------------
	# Send the request packet
	#-------------------------------
	# The packet is sent directly to the registered service
	# PRH TODO - modernize and handle sendUDPPacket failures
	# in case command was interrupted by killAllJobs();
	
	return if $this->{file_state} != $FILE_STATE_START;
	$this->setState($FILE_STATE_BUSY);
	showRawPacket(0,$this,$packet,1) if 0; #$this->{mon_raw_out};

	my $command_name = $COMMAND_NAME{$cmd};
	$this->{file_command} = $cmd;
	$this->{wait_seq} = $seq;
	$this->{wait_name} = $command_name;
	
    sendUDPPacket(
        "fileCommand($command_name)",
		$this->{ip},
        $this->{port},
        $packet);


	#---------------------------------------------------
	# Wait for a reply (from our packetHandler)
	#---------------------------------------------------
	# OK, this is where it is weird.
	# We don't have a thread, so we use waitReply
	# to deliver a timeout error ...


	$this->{COMMAND_TIMEOUT} = $cmd == $COMMAND_GET_FILE ?
		$LONG_TIMEOUT : $SHORT_TIMEOUT;

	my $reply = $this->waitReply(1);
	if (!$reply)
	{
		$this->fileRequestError($seq,"$command_name failed");
		return 0;
	}
	return 1;
}





sub handleCommand
	# Note that it is possible to crash the E80 generally
	# with packets with bad string lengths.
{
	my ($this,$command) = @_;
	my $command_name = $command->{name};
	my $cmd = $this->{file_command};
	my $path = $this->{file_path};

	display($dbg_fs,0,"handleCommand($cmd=$command_name) path($path)");
		# show the place keeper command, but the
		# command actually runs off $this member variables


	# Weird temporqry implementation usess specially modified
	# behavior for GET_FILE and GET_SIZE2.

	my $ok;
	if ($cmd == $COMMAND_GET_FILE)
	{
		$ok = $this->doOneIteration($COMMAND_GET_SIZE2,$path,0,0);
		my $total = $this->{file_content};
		$this->{file_content} = '';
		display($dbg_fs,1,"FILE_SIZE2 returned ok($ok) size='$total'");
		
		if ($ok)
		{
			my $offset = 0;
			$this->{file_total} = $total;
			$this->{got_len} = 0;
			my $BYTES_PER_REQUEST = 2048000;	# $MAXIMUM_FILE_SIZE / 2;
				# It doesn't download chartcat.xml correctly with 1024,
				# and there is NO actual error checking, checksums or anything
				# to actually determine if a file download worked. I have
				# seen requests for a given file offset, return a completely
				# different file offset, but have the correct sequence number.
				#
				# It is undoubtedly more reliable when the whole file is downloaded
				# in one request, as the E80 seems pretty good at not getting confused.
				#
				# But the e80 takes a very long time to start replying, and
				# reboots if I try to download a big chart file all at once.
				#
				# When it does fail, it's typically on the last request,
				# and the E80 gives me something entirely wrong.
				#
				# At 2M I know I am getting ARCHIVE.FSH and chartcat.xml.
				#
				# The situation seemed to improve when I
				# 	(a) modified the handler to crop the last buffer to the total size
				# 	(b) modified this code to always request multiples of 1024 bytes
				# and now I am able to download large files and \base\bat\hex_compare
				# them with no errors against files I copied directly from a CF card,
				# although there is STILL NO REAL ERROR CHECKING
				
			while ($ok && $offset<$total)
			{
				my $left = $total-$offset;
				my $to_read = $left;
				$to_read = $BYTES_PER_REQUEST if $to_read > $BYTES_PER_REQUEST;
				if ($to_read < $BYTES_PER_REQUEST && ($to_read % 1024))
				{
					# round up to even 1024 packets and let the completion code handle it
					$to_read = (int($to_read / 1024) + 1) * 1024
				}
				print "total($total) offset($offset) left($left) to_read=$to_read\n";
				$this->{file_offset} = $offset;
				# sleep(0.001);
				$this->setState($FILE_STATE_START);
				$ok = $this->doOneIteration($cmd,$path,$offset,$to_read);
				$offset += $BYTES_PER_REQUEST;
			}
		}
	}
	else
	{
		$ok = $this->doOneIteration($cmd,$path,0,$MAXIMUM_FILE_SIZE);
	}

	$this->setState($FILE_STATE_COMPLETE) if $ok;
	return 1;

	# ... however, WE have to return the reply in handlePacket() below
	# 	  for waitReply to see it ...
}



sub fileRequestError
	# ... in an error, we return a 'reply' with success=0 and the correct seq_num
{
    my ($this,$seq,$err) = @_;
    if ($this->{file_state} != $FILE_STATE_ERROR)
    {
		my $cmd = $this->{file_command};
		my $cmd_name = $COMMAND_NAME{$cmd};
        my $file_error = "fileRequest($cmd=$cmd_name,$this->{file_path}) - $err";
		$this->{file_error} = $file_error;
		$this->setState($FILE_STATE_ERROR);
        error($file_error);
    }
	return shared_clone({ seq_num=>$seq, success=>0 });
}


#-----------------------------------
# handlePacket()
#-----------------------------------

sub handlePacket
	# .... so, we have to parse the packet for success, contents, etc,
	# and return a record 'reply' with seq_num and success==1  when the
	# commandis complete, or call fileRequestError() above, in either case
	# to free up the above waitReply call.
{
	my ($this,$packet) = @_;

	my $packet_len = length($packet);
	display($dbg_fs,0,"FILSYS handlePacket($packet_len)");

	#----------------------------
	# parse the packet header
	#----------------------------
	
	my $state = $this->{file_state};
	return $this->fileRequestError(-1,"unexpected file_state($state)") if $state != $FILE_STATE_BUSY;

	my $cmd = $this->{file_command};	# THE ONE WE SENT

	my ($cmd_word,$service_id,$seq) = unpack('vvV',$packet);
	display($dbg_fs,1,"GOT cmd_word($cmd_word) service_id($service_id) seq($seq) in response to cmd($cmd)");
	my $offset = 8;

	return $this->fileRequestError(-1,"unexpected service_id($service_id)")
		if $service_id != $FILESYS_SERVICE_ID;
	return $this->fileRequestError($seq,"unexpected seq_num($seq) != $this->{wait_seq}")
		 if $seq != $this->{wait_seq};
	
	#------------------------------------
	# parse card_id or success
	#------------------------------------
	# Example for the string 0014910F06D62062 returned with my RAY_DATA CF card in the E80
	#
	#	0900 0500 nnnnnnnn
	#   	cmd, service_id, seq_num
	#
	#	88130000 0100
	#      	unknown leading bytes
	#	1400 20202020 30303134 39313046 30364436 32303632
	#       length and string
	#		 _ _ _ _  0 0 1 4  9 1 0 F  0 6 D 6  2 0 6 2
	#	0f270c
	#		unknown trailing bytes
	#
	# otherwise, for all other commands, the next four bytes should
	# be '00000400', the success pattern

	my $success = 0;
	if ($cmd == $COMMAND_CARD_ID)
	{
		my $len = unpack('v',substr($packet,14,2));
		my $id = substr($packet,16,$len);
		print "CARD_ID=$id\n";
		$this->{file_content} = $id;
		$success = 1;
	}
	else
	{
		my $code = unpack('H*',substr($packet,$offset,4));
		display($dbg_fs,2,"GOT success($code)");
		$offset += 4;
		return $this->fileRequestError($seq,"operation failed: $code")
			if $code ne $SUCCESS_SIG;
	}

	#-----------------------
	# parse the data ...
	#-----------------------
	# GET_FILE only sets $success to 1 on the last packet

	if ($cmd == $COMMAND_GET_SIZE)
	{
		my $size = unpack('V',substr($packet,$offset));
		print "SIZE($this->{file_path}) = $size\n";
		$this->{file_content} = $size;
		$success = 1;
	}
	elsif ($cmd == $COMMAND_GET_SIZE2)
	{
		my $size = unpack('V',substr($packet,$offset));
		print "SIZE2($this->{file_path}) = $size\n";
		$this->{file_content} = $size;
		$success = 2;
	}
	elsif ($cmd == $COMMAND_DIRECTORY)
	{
		# Each entry is word(length) followed by length bytes of name,
		# followed by a FAT 1 byte bitwise attribute
		#
		#									  v num_entries
		#                                         v first length byte
		# 00000500 03000000 00000400 01000100 06000200 2e001002 002e2e10 0e005445   ..............................TE
		# 53545f44 41544131 2e545854 200e0054 4553545f 44415441 322e5458 54201400   ST_DATA1.TXT ..TEST_DATA2.TXT ..
		# 54455354 5f444154 415f494d 41474531 2e4a5047 20140054 4553545f 44415441   TEST_DATA_IMAGE1.JPG ..TEST_DATA
		# 5f494d41 4745322e 4a504720                                                _IMAGE2.JPG
		#
		# There is a dir entry for . followed by a dir entry for ..
		# The entry for . seems to have an included null, where as the one for .. doesn't
		#
		# I don't understand the 4th dword 01000100

		print "DIR($this->{file_path})\n";
		$offset += 4;	# skip unknown dword
		my $num_entries = unpack('v',substr($packet,$offset,2));
		display($dbg_fs,2,"num_entries($num_entries)");
		$offset += 2;

		$this->{file_content} = '';
		for (my $i=0; $i<$num_entries; $i++)
		{
			my $length = unpack('v',substr($packet,$offset,2));
			$offset += 2;
			my $name = substr($packet,$offset,$length);
			$offset += $length;
			my $attr = unpack('C',substr($packet,$offset,1));
			$offset += 1;

			$name =~ s/\x00//g;								# remove traling null from '.' directory
			$name =~ s/\.//g if $attr & $FAT_VOLUME_ID;		# remove erroneous . in middle of my volume name

			print "    ".dbgFatStr($attr).pad("len($length)",8).$name."\n";

			$this->{file_content} .= "\n" if $this->{file_content};
			$this->{file_content} .= "$attr\t$name";
		}
		$success = 1;
	}

	# GET_FILE only sets $success=1 on the last packet
	# We don't assert the $bytes == $packet_len-$offset, but it does.
	# The length of the packet, except for the last, is always
	# 1042 bytes == the header and 1024 bytes of content
	#
	#	0200 0500 0c000000 00000400
	#	  	cmd,service_id,seq_num,success_code
	#
	#	8c00 0600 0004
	#		num_packets, packet_num, bytes=0x400 = 1024
	#
	#   50542c33 2e302c30 2e302a35 340d0a0d 0a527820 30303030 38342024 57494d57   PT,3.0,0.0*54....Rx 000084 $WIMWV,
	#	  	content ....
	
	elsif ($cmd == $COMMAND_GET_FILE)
	{
		my ($num_packets,$packet_num,$bytes) = unpack('v3',substr($packet,$offset,6));
		display($dbg_fs,2,"command($cmd) packet($packet_num/$num_packets) bytes=$bytes");
		$offset += 6;

		my $cur_len = $this->{got_len};
		my $expected_len = $this->{file_offset} + $packet_num * 1024;
		if ($cur_len != $expected_len)
		{
			my $expected = $cur_len / 1024;
			return $this->fileRequestError($seq,"Unexpected length($cur_len) != expected($expected_len) = ".
				"$this->{file_offset} + (1024*$packet_num=".(1024*$packet_num).")");
			# return $this->fileRequestError($seq,"Unexpected packet_num($packet_num) expected($expected)");
		}
		else
		{

			my $content = substr($packet,$offset);
			my $this_len = length($content);
			my $total_len = $this->{file_total};
			if ($this->{got_len} + $this_len > $total_len)
			{
				my $new_this = $total_len - $this->{got_len};
				warning(0,0,"pruning last packet from $this_len to $new_this = $total_len-$this->{got_len}");
				$this_len = $new_this;
				$content = substr($content,0,$this_len);
			}

			$this->{file_content} .= $content;
			$this->{got_len} += $this_len;

			if ($packet_num == $num_packets - 1)
			{
				if ($this->{got_len} >= $total_len)
				{
					display($dbg_fs,2,"FILE($this->{file_path}) COMPLETED!!");
					$success = 1;
				}
				else
				{
					display($dbg_fs,2,"FILE($this->{file_path}) GOT $this->{got_len}/$total_len bytes!!");
					$success = 2;
				}
			}
		}	# got the next expected buffer
	}	#   $COMMAND_GET_FILE


	#---------------------------------------------
	# possibly return 'reply' to b_sock
	#---------------------------------------------

	if ($success)
	{
		display($dbg_fs,0,"FILESYS handlePacket() returning success packet");
		return shared_clone({
			seq_num => $seq,
			success => $success });
	}

	display($dbg_fs,0,"FILESYS handlePacket() returning undef");
	return undef;	# still processing file packets

}	# handlePacket()



#=================================================================
# e_FILESYS - PARSER
#=================================================================
# MUST PLAY NICELY WITH b_sock::waitReply and existing onCommand() handler.
# Optionally constructed in context of the real d_FILESYS?
# We started off by just implementing it efficiently on top of sniffer,
# without barfing.
#
# I originally thought it might be necessary to implement actual file
# downloads via sniffer to get at the 'unencrypted' Navionic charts,
# but now I believe that RNS gets the same thing I do, and that
# they are likely (a) not actually encrypted, but that (b) the E80 and
# RNS just "know" if there is a Navionics card in the slot.  I *may*
# be able to prove this by more sniffing por-que Navionics can ONLY
# find it out via RAYNET, and perhaps I could spoof RNS into using
# *my* charts, but no way I'm ever gonna get the E80 to use a
# non-Navionic chart card.  So even a BACKUP still implies it gets
# copied to a real Navionic chart card, and the only way to use
# these files with openCPN is if I effing figure them out and essentially
# convert them to a format (i.e. S57) that openCPN knows.
#
# The primary role of a parser is to return a packet that is a complete
# reply with parsed informtation and secondarily to display requests.
# In sniffer the parser is assumed to be 'context' free and generally
# not carry any state, or worry about any command_queue or parent b_sock
# processing, or for that matter, return value.
#
# but for FILESYS, this isn't sufficient as GET_FILE replies  happen over
# many packets, and a full file download involves multiple ones of those.
#
# Therefore there must be SOMETHING on the e_FILESYS parser that tells it
# that it is in the context of d_FILEYSYS and needs to respect the reply
# conventions for waitReply to trigger a a response, as opposed to sniffer
# where it may just blindly parse packets (including comands not used in
# in d_FILESYS) and return nothing.
#
# Hence derived parsers may have a {parent} member, and if that is set
# may have intimate knowledge of the parent's (i.e. d_FILESYS) state
# and/or modify it.



package e_FILESYS;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use a_defs;
use a_utils;
use base qw(a_parser);

my $dbg_fp = 0;


sub new
{
	my ($class, $parent, $def_port) = @_;
	display($dbg_fp,0,"e_FILESYS::new($parent->{name}) def_port($def_port)");
	my $this = $class->SUPER::new($parent,$def_port);
	bless $this,$class;

	$this->{name} = 'e_FILESYS';

	$this->{file_content} = '';
	$this->{file_cur_buf_num} = 0;
	$this->{file_num_buffers} = 0;
	
	return $this;
}


#	sub parsePacket
#		# Calls base clase AFTER figuring out what mon_spec to use.
#		# We pass the {mon_spec} member back to the base class
#	{
#		my ($this,$packet) = @_;
#		my $payload = $packet->{payload};
#
#		my $mon_key = $MCTRL_WHAT_DEFAULT;
#		my $mon_dir = $packet->{is_reply} ? $RX : $TX;
#		my $dir_def = $this->{$mon_dir};
#		my $mon_spec = $packet->{mon_spec} = $dir_def->{$mon_key};
#
#		my $mon = $mon_spec->{mon} || 0;
#		my $ctrl = $mon_spec->{ctrl} || 0;
#		display($dbg_fp+1,0,sprintf("e_FILESYS::parsePacket($mon_dir) ctrl(%04x) mon(%08x)",$ctrl,$mon));
#
#		my $rslt = $this->SUPER::parsePacket($packet);
#
#		# temp debugging
#		# display_record(0,0,"packet",$packet,'payload|points') if $mon & $MON_PIECE;
#
#		return $rslt;
#	}




sub parseMessage
	# Calls base_clase BEFORE doing WPMGR specific stuff,
	# which particularly involves maintaing the 'what' context
	# across messages, knowing what messages have sequence numbers,
	# and checking twice for rules,
{
	my ($this,$packet,$len,$part,$hdr) = @_;
	display($dbg_fp+2,0,"e_FILESYS::parseMessage($len) hdr($hdr)");
	return 0 if !$this->SUPER::parseMessage($packet,$len,$part,$hdr);

	my ($cmd_word,$sid,$seq) = unpack('vvV',substr($part,0,8));
	my $cmd = $cmd_word & 0xff;
	my $dir = $cmd_word & 0xff00;
	my $offset = 8;

	my $cmd_name = $COMMAND_NAME{$cmd};
	$cmd_name ||= 'WHO CARES?';
	my $dir_name = $DIRECTION_NAME{$dir};
	display($dbg_fp+2,1,"e_FILESYS::parseMessage() dir($dir)=$dir_name seq($seq) cmd($cmd)=$cmd_name");;

	my $pad = pad('',13);
	my $mon = $packet->{mon};
	printConsole($packet->{color},$pad."# $dir_name $cmd_name cmd($cmd) seq($seq)",$mon)
		if $mon & $MON_PARSE;

	# Requests and replies have completely different layouts

	if (!$packet->{is_reply})
	{
		my $port_str = substr($part,$offset,2);
		my $port = unpack('v',$port_str);
		my $port_hex = unpack('H*',$port_str);
		$offset += 2;

		my $text = $pad."#    port($port_hex)=$port";

		# virtually all commands have a path
		
		if ($cmd != $COMMAND_CARD_ID &&
			$cmd != $COMMAND_LOCK &&
			$cmd != $COMMAND_UNLOCK)
		{
			if ($cmd == $COMMAND_GET_SIZE)
			{
				my $uw = unpack('H*',substr($part,$offset,2));
				$offset += 2;
				$text .= "\n$pad#    unknown_word($uw)";
			}
			elsif ($cmd == $COMMAND_GET_FILE)
			{
				my $foff_str = substr($part,$offset,4);
				my $fsize_str = substr($part,$offset+4,4);
				$offset += 8;
				my $foff_hex = unpack('H*',$foff_str);
				my $fsize_hex = unpack('H*',$fsize_str);
				my $foff = unpack('V',$foff_str);
				my $fsize = unpack('V',$fsize_str);

				$text .= "\n$pad#    offset($foff_hex)=$foff  size($fsize_hex)=$fsize";
			}
			my $name_len = unpack('v',substr($part,$offset,2));
			$offset += 2;
			my $path = unpack('A*',substr($part,$offset,$name_len));
			$offset += $name_len;
			$text .= "\n$pad#    len($name_len) path = '$path'";
		}

		printConsole($packet->{color},$text,$mon)
			if $mon & $MON_PARSE;

		return undef;	# packet not needed

	}


	#------------------------------------
	# parse card_id or success
	#------------------------------------
	# Example for the string 0014910F06D62062 returned with my RAY_DATA CF card in the E80
	#
	#	0900 0500 nnnnnnnn
	#   	cmd, service_id, seq_num
	#
	#	88130000 0100
	#      	unknown leading bytes 0x1388 == 5000, a version number or success code of its own
	#
	#	1400 20202020 30303134 39313046 30364436 32303632
	#       length and string
	#		 _ _ _ _  0 0 1 4  9 1 0 F  0 6 D 6  2 0 6 2
	#	0f270c
	#		unknown trailing bytes
	#
	# otherwise, for all other commands, the next four bytes should
	# be '00000400', the success pattern

	my $success = 0;
	$packet->{content} ||= '';

	if ($cmd == $COMMAND_CARD_ID)
	{
		my ($u1,$u2,$len) = unpack('vH8v',substr($part,$offset,8));
		$offset += 8;
		my $id = substr($part,$offset,$len);
		$id =~ s/^\s*|\s*$//g;
		$offset += $len;
		my ($u3,$u4) = unpack('vC',substr($part,$offset,6));
		$offset += 6;
		
		# display_bytes(0,0,"id",$id);

		printConsole($packet->{color},$pad.
			sprintf("#    u1(0x%04x=$u1) u2($u2) u3(0x%04x=$u3) u4(%02x) len($len) CARD_ID = '$id'",$u1,$u3,$u4),
			$mon) if $mon & $MON_PARSE;

		$packet->{content} = $id;
		$success = $packet->{success} = 1;
	}
	else
	{
		my $code = unpack('H*',substr($part,$offset,4));
		$success = $code eq $SUCCESS_SIG ? 1 : 0;
		$offset += 4;
		$packet->{success} = $success;

		printConsole($packet->{color},$pad."#    success = $success ".($success?'':" code($code)"),$mon)
			if $mon & $MON_PARSE;

		if ($success)
		{
			if ($cmd == $COMMAND_GET_SIZE ||
				$cmd == $COMMAND_GET_SIZE2)
			{
				my $size = unpack('V',substr($part,$offset));
				printConsole($packet->{color},$pad."# SIZE = $size",$mon)
					if $mon & $MON_PARSE;
				$packet->{content} = $size;
			}
			elsif ($cmd == $COMMAND_DIRECTORY)
			{
				# Each entry is word(length) followed by length bytes of name,
				# followed by a FAT 1 byte bitwise attribute
				#
				#									  v num_entries
				#                                         v first length byte
				# 00000500 03000000 00000400 01000100 06000200 2e001002 002e2e10 0e005445   ..............................TE
				# 53545f44 41544131 2e545854 200e0054 4553545f 44415441 322e5458 54201400   ST_DATA1.TXT ..TEST_DATA2.TXT ..
				# 54455354 5f444154 415f494d 41474531 2e4a5047 20140054 4553545f 44415441   TEST_DATA_IMAGE1.JPG ..TEST_DATA
				# 5f494d41 4745322e 4a504720                                                _IMAGE2.JPG
				#
				# There is a dir entry for . followed by a dir entry for ..
				# The entry for . seems to have an included null, where as the one for .. doesn't
				#
				# I don't understand the 4th dword 01000100

				my ($u1,$num_entries) = unpack('H8v',substr($part,$offset,6));
				$offset += 6;

				my $text = $pad."# DIR LISTING entries($num_entries) unknown($u1)\n";

				for (my $i=0; $i<$num_entries; $i++)
				{
					my $length = unpack('v',substr($part,$offset,2));
					$offset += 2;
					my $name = substr($part,$offset,$length);
					$offset += $length;
					my $attr = unpack('C',substr($part,$offset,1));
					$offset += 1;

					$name =~ s/\x00//g;								# remove traling null from '.' directory
					$name =~ s/\.//g if $attr & $FAT_VOLUME_ID;		# remove erroneous . in middle of my volume name

					$text .= $pad."#    ".d_FILESYS::dbgFatStr($attr).pad("len($length)",8).$name."\n";

					$packet->{content} .= "\n" if $packet->{content};
					$packet->{content} .= "$attr\t$name";
				}

				printConsole($packet->{color},$text,$mon)
					if $mon & $MON_PARSE;
			}

			# GET_FILE only sets $success=1 on the last packet
			# We don't assert the $bytes == $packet_len-$offset, but it does.
			# The length of the packet, except for the last, is always
			# 1042 bytes == the header and 1024 bytes of content
			#
			#	0200 0500 0c000000 00000400
			#	  	cmd,service_id,seq_num,success_code
			#
			#	8c00 0600 0004
			#		num_packets, packet_num, bytes=0x400 = 1024
			#
			#   50542c33 2e302c30 2e302a35 340d0a0d 0a527820 30303030 38342024 57494d57   PT,3.0,0.0*54....Rx 000084 $WIMWV,
			#	  	content ....

			elsif ($cmd == $COMMAND_GET_FILE)
			{
				my ($num_packets,$packet_num,$bytes) = unpack('v3',substr($part,$offset,6));
				display($dbg_fp,2,"FILE packet($packet_num/$num_packets) bytes=$bytes");
				$offset += 6;

				printConsole($packet->{color},$pad."#    num_packets($num_packets) packet_num($packet_num) bytes($bytes)",$mon)
					if $mon & $MON_PARSE;

				$this->{file_content} = '' if !$packet_num;
				$this->{file_cur_buf_num} = $packet_num;
				$this->{file_num_buffers} = $num_packets;

				my $cur_len = length($this->{file_content});
				if ($cur_len != $packet_num * 1024)
				{
					my $expected = $cur_len / 1024;
					my $msg = "Unexpected packet_num($packet_num) expected($expected)";
					error($msg);
					$packet->{success} = 0;
					printConsole($UTILS_COLOR_RED,$pad."#     ERROR: $msg",$mon)
						if $mon & $MON_PARSE;

				}
				else
				{
					my $content = substr($part,$offset);
					$this->{file_content} .= $content;
					if ($packet_num == $num_packets - 1)
					{
						display($dbg_fs,2,"FILE COMPLETED!!");
						printConsole($UTILS_COLOR_YELLOW,$pad."# FILE COMPLETED!!",$mon)
							if $mon & $MON_PARSE;
						$success = 1;
					}
					else	# continue by returning no packet ...
					{
						$packet = undef;
					}

				}	# got the next expected buffer
			}	# $COMMAND_GET_FILE
		}	# success
	}	# !$COMMAND_CARD_ID

	# this doesnt work!
	return $packet;

}	# e_FILESYS::parseMessage()



1;