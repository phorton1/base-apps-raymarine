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
#
# This implementation provides the archetype for an implemented
# service port with a parser that must maintin significant state
# between udp packets.


package d_FILESYS;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use a_defs;
use a_utils;
use base qw(b_sock);


my $dbg_fs = 0;


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
		
		$FILE_CMD_DIRECTORY
		$FILE_CMD_GET_SIZE
		$FILE_CMD_GET_FILE
		$FILE_CMD_UNKNOWN
		$FILE_CMD_GET_ATTR
		$FILE_CMD_FILE_EXISTS
		$FILE_CMD_GET_SIZE2
		$FILE_CMD_LOCK
		$FILE_CMD_UNLOCK
		%FILE_CMD_NAME 
		$FILE_CMD_CARD_ID

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
# Most commands are a single packet, except GET_FILE.
# If COMPLETE, getContent() will contain the results, or
# on ERROR getError() will contain the 'error code'.

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
# used command constants

our $FILE_CMD_DIRECTORY   	= 0;		# returns a directory listing without any file or directory sizes (plus some other stuff)
our $FILE_CMD_GET_SIZE    	= 1;		# returns a dword size of FILES only (success completely understood)
our $FILE_CMD_GET_FILE    	= 2;		# returns the contents of a file (success completely understood) from a given offset
our $FILE_CMD_CARD_ID     	= 9;		# returns a string (plus some other stuff) that I think is related to the particular CF card
    # the string 0014910F06D62062  returned with my RAY_DATA CF card in the E80
    # the string 0014802A08W79223  returned with Caribbean Navionics CF card in the E80

#------ unused command constants
# I probed these, and did not find them useful to the implementation
# I never got anything from probes of 3 or higher than 9

our $FILE_CMD_UNKNOWN 		= 3;		# I never got anything back from this in probing
our $FILE_CMD_GET_ATTR		= 4;		# returns dword size (files only) AND byte of attributes
	# does not return attrs on ROOT dirctory
	# apparently does not require extra inserted word(0)
our $FILE_CMD_FILE_EXISTS	= 5;		# appears to return $FILE_SUCCESS on existing files only, an error otherwise
our $FILE_CMD_GET_SIZE2		= 6;		# appears to return exactly the same thing as GET_SIZE
	# but apparently does not want the extra insered word(0)
our $FILE_CMD_LOCK			= 7;		# increments an internal lock counter
our $FILE_CMD_UNLOCK		= 8;		# decrements an internal lock counter
	# LOCKING: it appears as if this implements an advisory database locking scheme.
	# The intent appaears to be that you call $FILE_CMD_UNLOCK and then
	# if it returns an error, you are free to increment the counter with $FILE_CMD_LOCK
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


my %FILE_CMD_NUMBER= (
	'DIR'	=> $FILE_CMD_DIRECTORY,
	'SIZE'	=> $FILE_CMD_GET_SIZE,
	'FILE'	=> $FILE_CMD_GET_FILE,
	'ID'	=> $FILE_CMD_CARD_ID,
);

our %FILE_CMD_NAME = (
	$FILE_CMD_DIRECTORY	=> 'CMD_DIR',
	$FILE_CMD_GET_SIZE	=> 'CMD_GET_SIZE',
	$FILE_CMD_GET_FILE	=> 'CMD_GET_FILE',
	$FILE_CMD_UNKNOWN	=> 'CMD_UNKNOWN3',
	$FILE_CMD_GET_ATTR	=> 'CMD_GET_ATTR',
	$FILE_CMD_FILE_EXISTS=> 'CMD_FILE_EXISTS',
	$FILE_CMD_GET_SIZE2	=> 'CMD_GET_SIZE2',
	$FILE_CMD_LOCK		=> 'CMD_LOCK',
	$FILE_CMD_UNLOCK		=> 'CMD_UNLOCK',
	$FILE_CMD_CARD_ID	=> 'CMD_CARD_ID',
);







#---------------------------------------------------------
# instantiation
#---------------------------------------------------------
# 'become' and 'unbecome' a 'real' service with a socket.



sub init
{
	my ($this) = @_;
	display($dbg_fs,0,"d_FILESYS init($this->{name},$this->{ip}:$this->{port}) proto=$this->{proto} local_port=$FILESYS_PORT");

	$this->SUPER::init();
	$this->{local_ip}			= $LOCAL_IP;
	$this->{local_port}			= $FILESYS_PORT;
	$this->{COMMAND_TIMEOUT}	= $SHORT_TIMEOUT;

	# this object maintains the API command state

	$this->{file_state}		= $FILE_STATE_IDLE;
	$this->{file_command}	= 0;
	$this->{file_path}		= '';
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

sub getState
{
	my ($this) = @_;
	return $this->{file_state};
}

sub getContent
{
	my ($this) = @_;
	return $this->{parser} ? $this->{parser}->{file_content} : '';
}

sub getProgress
{
	my ($this) = @_;
	my $parser = $this->{parser};
	return (0,0) if !$parser;
	return ($parser->{file_total},$parser->{got_len});
}

sub getError
{
	my ($this) = @_;
	return $this->{parser} ? $this->{parser}->{file_error} : '';
}


sub killAllJobs
{
	my ($this) = @_;

	my $TIMEOUT = 2;
	$this->{command_queue} = shared_clone([]);
	$this->{COMMAND_TIMEOUT} = 0;

	my $start = time();
	while (time() <= $start + $TIMEOUT && $this->{file_state} > 0)
	{
		sleep(0.1);
	}

	$this->{parser}->clearFileParser() if $this->{parser};
	$this->setState($FILE_STATE_IDLE);
	
}


sub clearError
{
	my ($this) = @_;
	return error("clearFileRequestError() called in $this->{file_state}")
		if $this->{file_state} != $FILE_STATE_ERROR;

	$this->{parser}->clearError() if $this->{parser};
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

	my $cmd = $FILE_CMD_NUMBER{$command_str};
	return error("unknown fileCommand($command_str)") if !defined($cmd);

	my $state = $this->{file_state};
	return error("busy in state $FILE_STATE_NAME{$state}") if $state > 0;

	return error("FILESYS not running") 	if !$this->{running};
	return error("FILESYS not connected") 	if !$this->{connected};
	return error("FILESYS stopping") 		if $this->{stopping};
	return error("FILESYS destroyed") 		if $this->{destroyed};

	$this->{file_command} 	 = $cmd;
	$this->{file_path} 		 = $path;
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
	# build a udp command packet based on the parameters
	# where $offset and $size are passed in for iterative
	# GET_FILE requests.
{
	my ($this,$cmd,$seq,$path,$offset,$size) = @_;

	my $packet = pack('C',$cmd);
	$packet .= pack('C',1); # DIRECTION_SEND
	$packet .= pack('v',$FILESYS_SERVICE_ID);
	$packet .= pack('V',$seq);
	$packet .= pack('v',$FILESYS_PORT);

	# The path is optional on some comannds.
	# The path must be preceded by things on some commands.

	if ($path)
	{
		$packet .= pack('H*','0000') if $cmd == $FILE_CMD_GET_SIZE;
			# add a dword for GET_SIZE; no idea of its semantic

		if ($cmd == $FILE_CMD_GET_FILE)
		{
			my $offset_packed = pack('V',$offset);
			my $size_packed = pack('V',$size);
			$packet .= $offset_packed.$size_packed ;
		}

		my $len = length($path) + 1;
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

	return if $this->{file_state} != $FILE_STATE_START;
	$this->setState($FILE_STATE_BUSY);

	#-------------------------------
	# Build and Send the request packet
	#-------------------------------
	# The packet is sent directly to the registered service
	# PRH TODO - modernize and handle sendUDPPacket failures
	# in case command was interrupted by killAllJobs();

	my $packet = $this->buildCommand($cmd,$seq,$path,$offset,$size);
	my $command_name = $FILE_CMD_NAME{$cmd};
	
	$this->{file_command} = $cmd;
	$this->{wait_seq} = $seq;
	$this->{wait_name} = $command_name;
	$this->{COMMAND_TIMEOUT} = $cmd == $FILE_CMD_GET_FILE ?
		$LONG_TIMEOUT : $SHORT_TIMEOUT;
	
    sendUDPPacket(
        "fileCommand($command_name)",
		$this->{ip},
        $this->{port},
        $packet);


	#---------------------------------------------------
	# Wait for a reply (from our parser)
	#---------------------------------------------------

	my $reply = $this->waitReply(1);
	if (!$reply)
	{
		$this->setState($FILE_STATE_ERROR);
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

	my $ok;
	if ($cmd == $FILE_CMD_GET_FILE)
	{
		$ok = $this->doOneIteration($FILE_CMD_GET_SIZE2,$path,0,0);
		my $total = $this->getContent() || 0;
		display($dbg_fs,1,"FILE_SIZE2 returned ok($ok) size='$total'");
		
		if ($ok)
		{
			my $BYTES_PER_REQUEST = 2048000;

			# DIRECT ACCESS TO PARSER MEMBERS
			
			my $parser = $this->{parser};
			return error("no parser in handleCommand") if !$parser;			$parser->{file_total} = $total;
			$parser->{got_len} = 0;
				# constant chosen after much trial and tribulation

			# loop sending requests and getting replies
			
			my $offset = 0;
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
				$parser->{file_offset} = $offset;
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
}


1;