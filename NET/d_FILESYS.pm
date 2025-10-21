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
		
		$FAT_READ_ONLY
		$FAT_HIDDEN
		$FAT_SYSTEM
		$FAT_VOLUME_ID
		$FAT_DIRECTORY
		$FAT_FILE

    );
}



my $FILESYS_SERVICE_ID = 5;
	# 5 = 0x005 = '0500'
my $FILESYS_PORT = $LOCAL_UDP_PORT_BASE + $FILESYS_SERVICE_ID;


my $MAXIMUM_FILE_SIZE = 'ffffff01'; #;
	# Agrees with buffer size set for udp sockets in b_sock.
	# YAY .. its the maximum file length to retrieve.
	# The highest number I was able to plug in and get a response
	# is 0x1ffffff, which correlate to a maximum file size of 32K.
	# It took me a long time to figure out that the '9a9d0100' I'd
	# seen from RNS was not some kind of a "magic" key.

my $LONG_TIMEOUT    = 60;        # file replies can take a  long time
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
my $COMMAND_GET_FILE    = 2;		# returns the contents of a file (success completely understood)
my $COMMAND_CARD_ID     = 9;		# returns a string (plus some other stuff) that I think is related to the particular CF card
    # the string 0014910F06D62062  returned with my RAY_DATA CF card in the E80
    # the string 0014802A08W79223  returned with Caribbean Navionics CF card in the E80

my %COMMAND_NAME = (
	$COMMAND_DIRECTORY	=> 'DIR',
	$COMMAND_GET_SIZE	=> 'SIZE',
	$COMMAND_GET_FILE	=> 'FILE',
	$COMMAND_CARD_ID	=> 'ID',
);

my %COMMAND_NUMBER = (
	'DIR'	=> $COMMAND_DIRECTORY,
	'SIZE'	=> $COMMAND_GET_SIZE,
	'FILE'	=> $COMMAND_GET_FILE,
	'ID'	=> $COMMAND_CARD_ID,
);



#------ unused command constants
# I probed these, and did not find them useful to the implementation
# I never got anything from probes of 3 or higher than 9

my $COMMAND_UNKNOWN 	= 3;		# I never got anything back from this in probing
my $COMMAND_GET_ATTR	= 4;		# returns dword size (files only) AND byte of attributes
	# does not return attrs on ROOT dirctory
	# apparently does not require extra inserted word(0)
my $COMMAND_FILE_EXISTS = 5;		# appears to return $FILE_SUCCESS on existing files only, an error otherwise
my $COMMAND_GET_SIZE2	= 6;		# appears to return exactly the same thing as GET_SIZE
	# but apparently does not require extra insered word(0)
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

	$this->{file_state}       = $FILE_STATE_IDLE;
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
	$this->{file_state} = $FILE_STATE_IDLE;
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
	$this->{file_state} 	= $FILE_STATE_START;

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



sub handleCommand
	# Note that it is possible to crash the E80 with this method.
	# First time I tried this it crashed the E80 with the packet
	#
	# 	02010500 01000000 01482000 5c6a756e 6b5f6461 74615c74 6573745f 64617461   .........H .\junk_data\test_data
	# 	5f696d61 6765312e 6a706700                                                _image1.jpg.
	#
	# in which I did not include the exter dword(0) and dword(maximum_file_size)
	# that I observed when RNS made this call.  Presumably it crashed because
	# it has a fixed buffer size and/or tried to allocate a buffer of 7461 (0x6174)
	# bytes and either failed the allocate or read past the buffer.
	#
	# So, some care must be taken when probing the E80, and therefore, for
	# the time being I invariantly add the needed extra words for the GET_SIZE
	# and GET_FILE commands, which I already know work.
{
	my ($this,$command) = @_;
	my $command_name = $command->{name};
	my $cmd = $this->{file_command};
	my $path = $this->{file_path};

	display($dbg_fs,0,"handleCommand($cmd=$command_name) path($path)");
		# show the place keeper command, but the
		# command actually runs off $this member variables

	#-------------------------------
	# Build the request packet
	#-------------------------------
	# The header of the request never changes

	my $seq = $this->{next_seqnum}++;
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
			# add a dword for GET_SIZE
		$packet .= pack('H*','00000000'.$MAXIMUM_FILE_SIZE) if $cmd == $COMMAND_GET_FILE;
			# add the extra dword and  maximum file size for GET_FILE
		$packet .= pack('v',$len);
		$packet .= $path;
		$packet .= chr(0);
			# it is not clear if this terminating null is required
			# but it does not hurt anything
	}

	#-------------------------------
	# Send the request packet
	#-------------------------------
	# The packet is sent directly to the registered service
	# PRH TODO - modernize and handle sendUDPPacket failures
	
	return if $this->{file_state} != $FILE_STATE_START;

		# in case command was interrupted by killAllJobs();
    sendUDPPacket(
        "fileCommand($command_name)",
		$this->{ip},
        $this->{port},
        $packet);
	$this->{file_state} = $FILE_STATE_BUSY;
	if ($this->{show_raw_output})
	{
		setConsoleColor($this->{out_color}) if $this->{out_color};
		print "FILESYS <-- ".unpack('H*',$packet)."\n";
		setConsoleColor() if $this->{out_color};
	}

	#---------------------------------------------------
	# Wait for a reply (from our packetHandler)
	#---------------------------------------------------
	# OK, this is where it is weird.
	# We don't have a thread, so we use waitReply
	# to deliver a timeout error ...

	$this->{wait_seq} = $seq;
	$this->{wait_name} = $command_name;
	$this->{COMMAND_TIMEOUT} = $cmd == $COMMAND_GET_FILE ?
		$LONG_TIMEOUT : $SHORT_TIMEOUT;

	my $reply = $this->waitReply(1);
	$this->fileRequestError($seq,"$command_name failed") if !$reply;
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
		$this->{file_state} = $FILE_STATE_ERROR;
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
	return $this->fileError("unexpected file_state($state)") if $state != $FILE_STATE_BUSY;

	my $cmd = $this->{file_command};	# THE ONE WE SENT

	my ($cmd_word,$service_id,$seq) = unpack('vvV',$packet);
	display($dbg_fs,1,"GOT cmd_word($cmd_word) service_id($service_id) seq($seq) in response to cmd($cmd)");
	my $offset = 8;

	return $this->fileError(-1,"unexpected service_id($service_id)")
		if $service_id != $FILESYS_SERVICE_ID;
	return $this->fileError($seq,"unexpected seq_num($seq)")
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

		$this->{file_cur_buf_num} = $packet_num;
		$this->{file_num_buffers} = $num_packets;

		my $cur_len = length($this->{file_content});
		if ($cur_len != $packet_num * 1024)
		{
			my $expected = $cur_len / 1024;
			return $this->fileRequestError($seq,"Unexpected packet_num($packet_num) expected($expected)");
		}
		else
		{
			my $content = substr($packet,$offset);
			$this->{file_content} .= $content;
			if ($packet_num == $num_packets - 1)
			{
				display($dbg_fs,2,"FILE($this->{file_path}) COMPLETED!!");
				$success = 1;
			}
		}	# got the next expected buffer
	}	#   $COMMAND_GET_FILE


	#---------------------------------------------
	# possibly return 'reply' to b_sock
	#---------------------------------------------

	if ($success)
	{
		display($dbg_fs,0,"FILESYS handlePacket() returning success");
		$this->{file_state} = $FILE_STATE_COMPLETE;
		return shared_clone({
			seq_num => $seq,
			success => $success });
	}

	display($dbg_fs,0,"FILESYS handlePacket() returning undef");
	return undef;	# still processing file packets

}	# handlePacket()



1;