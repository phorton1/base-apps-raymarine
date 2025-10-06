#---------------------------------------------
# r_FILESYS.pm
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

package r_FILESYS;
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
use r_utils;
use r_RAYDP;

my $dbg_fs = 0;


my $FILE_REQUEST_TIMEOUT    = 30;        # seconds

our $FILE_STATE_ILLEGAL   = -9; 	# used only to init change detection in winFILESYS
our $FILE_STATE_INIT 	  = -3;
our $FILE_STATE_ERROR     = -2;
our $FILE_STATE_COMPLETE  = -1;
our $FILE_STATE_IDLE      = 0;
our $FILE_STATE_STARTED   = 1;
our $FILE_STATE_PACKETS   = 2;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

        filesysThread
		setFILESYSRayPort
		isCurrentFILESYSRayport

		$FILE_STATE_ILLEGAL
		$FILE_STATE_INIT
		$FILE_STATE_ERROR
		$FILE_STATE_COMPLETE
		$FILE_STATE_IDLE
		$FILE_STATE_STARTED
		$FILE_STATE_PACKETS

        getFileRequestState
        getFileRequestError
        getFileRequestContent
		clearFileRequestError
		getFileRequestProgress
		
        requestSize
		requestFile
        requestDirectory
		requestCardID

		fileStateName

		$FAT_READ_ONLY
		$FAT_HIDDEN
		$FAT_SYSTEM
		$FAT_VOLUME_ID
		$FAT_DIRECTORY
		$FAT_FILE

    );
}


# used command constants

my $COMMAND_DIRECTORY   = 0;		# returns a directory listing without any file or directory sizes (plus some other stuff)
my $COMMAND_GET_SIZE    = 1;		# returns a dword size of FILES only (success completely understood)
my $COMMAND_GET_FILE    = 2;		# returns the contents of a file (success completely understood)
my $COMMAND_CARD_ID     = 9;		# returns a string (plus some other stuff) that I think is related to the particular CF card
    # the string 0014910F06D62062  returned with my RAY_DATA CF card in the E80
    # the string 0014802A08W79223  returned with Caribbean Navionics CF card in the E80

# unused command constants
# I never got anything from probes of 3 or higher than 9

my $COMMAND_UNKNOWN 	= 3;		# I never got anything back from this in probing
my $COMMAND_GET_ATTR	= 4;		# returns dword size (files only) AND byte of attributes
	# does not return attrs on ROOT dirctory
	# apparently does not require extra inserted word(0)
my $COMMAND_FILE_EXISTS = 5;		# appears to return $FILE_SUCCESS on existing files only, an error otherwise
my $COMMAND_GET_SIZE2	= 6;		# appears to return exactly the same thing as GET_SIZE
	# but apparently does not require extra insered word(0)
my $COMMAND_LOCK		= 7;		# increments an internal lock counter, probably per listener
my $COMMAND_UNLOCK		= 8;		# decrements an internal lock counter, probably per listener
	# LOCKING: it appears as if the intent is that you call $COMMAND_UNLOCK and then
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
# my $KNOWN_ERROR_CODE    = pack('H*','01050480');

my $COMMAND_REQUEST     = pack('C',1);
my $COMMAND_REPLY       = pack('C',0);
my $FUNC_5              = pack('H*','0500');
my $SUCCESS_PATTERN		= pack('H*','00000400');

my $MAXIMUM_FILE_SIZE = 'ffffff01'; #;
	# YAY .. its the maximum file length to retrieve.
	# The highest number I was able to plug in and get a response
	# is 0x1ffffff, which correlate to a maximum file size of 32K.
	# It took me a long time to figure out that the '9a9d0100' I'd
	# seen from RNS was not some kind of a "magic" key.

# FAT attribute bits

our $FAT_READ_ONLY   = 0x01;
our $FAT_HIDDEN      = 0x02;
our $FAT_SYSTEM      = 0x04;
our $FAT_VOLUME_ID   = 0x08;
our $FAT_DIRECTORY   = 0x10;
our $FAT_FILE     	 = 0x20;


# shared variables

my $filesys_ip:shared		= '';
my $filesys_port:shared 	= 0;

sub setFILESYSRayPort
{
	my ($rayport) = @_;
	if ($filesys_ip ne $rayport->{ip} ||
		$filesys_port != $rayport->{port})
	{
		$filesys_ip = $rayport->{ip};
		$filesys_port = $rayport->{port};
		warning(0,0,"changing rayport(FILESYS) to $filesys_ip:$filesys_port");
	}
	else
	{
		warning(0,0,"did not change rayport(FILESYS); already was $filesys_ip:$filesys_port");
	}
}

sub isCurrentFILESYSRayport
{
	my ($rayport) = @_;
	return 1 if
		$filesys_ip eq $rayport->{ip} &&
		$filesys_port == $rayport->{port};
	return 0;
}







my $file_state:shared       = $FILE_STATE_INIT;
my $file_error:shared       = '';

my $file_command:shared     = 0;
my $file_path:shared        = '';
my $file_content:shared    	= '';
my $request_time:shared    	= 0;	# Shouldn't need to be shared
my $output_filename:shared  = '';

# these vars are thread local, non-shared

my $file_req_num		= -1;
my $next_seq_num  		= 0;

our $file_request_cur:shared = 0;
our $file_request_num:shared = 0;


sub getFileRequestProgress
{
	return {
		cur => $file_request_cur,
		num => $file_request_num };
}



#------------------------------------------
# public API
#------------------------------------------

sub getFileRequestState
{
    return $file_state;
}

sub getFileRequestError
{
    return $file_error;
}

sub getFileRequestContent
{
	return $file_content;
}

sub clearFileRequestError
{
	if ($file_state == $FILE_STATE_ERROR)
	{
		$file_error = '';
		$file_state = $FILE_STATE_IDLE;
	}
}


sub requestCardID
{
	return initFileRequest($COMMAND_CARD_ID);
}

sub requestSize
{
	my ($path) = @_;
	return initFileRequest($COMMAND_GET_SIZE,$path);
}

sub requestFile
{
	my ($filename,$ofilename) = @_;
	return initFileRequest($COMMAND_GET_FILE,$filename,$ofilename);
}

sub requestDirectory
{
	my ($path) = @_;
	return initFileRequest($COMMAND_DIRECTORY,$path);
}


sub fileStateName
{
	return "ILLEGAL"   if $file_state == $FILE_STATE_ILLEGAL;
	return "INIT" 	   if $file_state == $FILE_STATE_INIT;
	return "ERROR"     if $file_state == $FILE_STATE_ERROR;
	return "COMPLETE"  if $file_state == $FILE_STATE_COMPLETE;
	return "IDLE"      if $file_state == $FILE_STATE_IDLE;
	return "STARTED"   if $file_state == $FILE_STATE_STARTED;
	return "PACKETS"   if $file_state == $FILE_STATE_PACKETS;
	return "UNKOWN";
}




#----------------------------------------------------
# implementation
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


sub commandStr
{
	return "DIRECTORY"	if $file_command == $COMMAND_DIRECTORY;
	return "GET_SIZE" 	if $file_command == $COMMAND_GET_SIZE;
	return "GET_FILE" 	if $file_command == $COMMAND_GET_FILE;
	return "CARD_ID" 	if $file_command == $COMMAND_CARD_ID;
	return "UNKNOWN COMMAND";
}




sub fileRequestError
{
    my ($err) = @_;
    if ($file_state != $FILE_STATE_ERROR)
    {
        $file_error = "fileRequest($file_command) ".commandStr()."($file_path) - $err";
        $file_state = $FILE_STATE_ERROR;
        error($file_error);
    }
}


sub initFileRequest
{
    my ($command,$path,$ofilename) = @_;
	$ofilename ||= '';
	display($dbg_fs,0,"initFileRequest($command,$path,$ofilename)");

	if (!$filesys_port)
	{
		error("No filesys_port in fileRequest($command,$path)");
		return 0;
	}
	if ($file_state > 0)
	{
		error("requestFile($command,$path) in state($file_state)");
		return 0;
	}

	$file_request_cur = 0;
	$file_request_num = 0;
	
	$file_command 	 = $command;
	$file_path 		 = $path;
	$output_filename = $ofilename;

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

	$file_content 	= '';
	$file_error 	= '';
	$request_time 	= time();
	$file_state 	= $FILE_STATE_STARTED;
	return 1;
}


sub sendFilesysRequest
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
	my ($command,$path,$is_probe,$extra1,$extra2) = @_;
	$is_probe ||= 0;

	# optional params allow probing FILESYS directly
	# from the main thread. $extra1 is inserted before
	# the path, and $extra2 is added at the end of the packet.

	$command ||= $file_command;
	$path 	 ||= $file_path;
	display($dbg_fs,0,"sendFilesysRequest($command,$path)".
		($is_probe?"PROBE ":'').
		(defined($extra1)?" extra1=$extra1":'').
		(defined($extra2)?" extra2=$extra1":''));

	# The header of the command never changes

	my $seq_num = $next_seq_num++;
	my $len = length($path) + 1;
	my $packet = pack('C',$command);
	$packet .= $COMMAND_REQUEST;
	$packet .= $FUNC_5;
	$packet .= pack('V',$seq_num);
	$packet .= pack('v',$FILESYS_LISTEN_PORT);

	# The path is optional on some comannds.
	# The path must be preceded by things on some commands.

	if ($path)
	{
		$packet .= pack('H*',$extra1) if defined($extra1);
		$packet .= pack('H*','0000') if $command == $COMMAND_GET_SIZE;
			# add a dword for GET_SIZE
		$packet .= pack('H*','00000000'.$MAXIMUM_FILE_SIZE) if $command == $COMMAND_GET_FILE;
			# add the extra dword and  maximum file size for GET_FILE
		$packet .= pack('v',$len);
		$packet .= $path;
		$packet .= chr(0);
			# it is not clear if this terminating null is required
			# but it does not hurt anything
	}
	
	$packet .= pack('H*',$extra2) if defined($extra2);
    sendUDPPacket(
        "fileCommand($command)",
		$filesys_ip,
        $filesys_port,
        $packet);
}


#-------------------------------------------------
# filesysThread
#-------------------------------------------------

sub filesysThread
    # blocking unidirectional single port monitoring thread
{
    display($dbg_fs,0,"filesysThread($FILESYS_LISTEN_PORT) started");

	# open listen socket

    my $sock = IO::Socket::INET->new(
            LocalPort => $FILESYS_LISTEN_PORT,
            Proto     => 'udp',
            ReuseAddr => 1 );
    if (!$sock)
    {
        error("Could not open sock in listen_udp_thread($FILESYS_LISTEN_PORT)");
        return;
    }
	setsockopt($sock, SOL_SOCKET, SO_RCVBUF, pack("I", 0x1ffffff));
		# Increasing the udp socket buffer size was required for me to
		# reliably recieve a 1MB ARCHIVE.FSH file.

    display($dbg_fs,0,"listen socket opened");

	# get the FILESYS ip:port from RAYDP

	my $rayport = findRayPortByName('FILESYS');
	while (!$rayport)
	{
		display(0,1,"waiting for rayport(FILESYS)");
		sleep(1);
		$rayport = findRayPortByName('FILESYS');
	}
	$filesys_ip = $rayport->{ip};
	$filesys_port = $rayport->{port};
	display($dbg_fs,1,"found rayport(FILESYS) at $filesys_ip:$filesys_port");
	
	# start the loop

	my $reply_sig;
	$file_state = $FILE_STATE_IDLE;
    my $sel = IO::Select->new($sock);
    while (1)
    {
        if ($sel->can_read(0.1))
        {
			my $raw;
			recv($sock, $raw, 4096, 0);
			if ($raw)
			{
				setConsoleColor($UTILS_COLOR_LIGHT_MAGENTA);
				display($dbg_fs,1,"filesysThread() GOT ".length($raw)." BYTES "._lim(unpack("H*",$raw),32));
				setConsoleColor();

				$request_time = time();

				if ($file_state == $FILE_STATE_PACKETS &&
					substr($raw,0,8) eq $reply_sig)
				{
					# COMMAND_CARD_ID does not use a 00004000 success signature
					# Example for the string 0014910F06D62062 returned with my RAY_DATA CF card in the E80
					#
					#	09000500 nnnnnnnn
					#   	signature w/seq_num
					#	88130000 0100
					#      	unknown leading bytes
					#	1400 20202020 30303134 39313046 30364436 32303632
					#       length and string
					#		 _ _ _ _  0 0 1 4  9 1 0 F  0 6 D 6  2 0 6 2
					#	0f270c
					#		unknown trailing bytes

					if ($file_command == $COMMAND_CARD_ID)
					{
						my $len = unpack('v',substr($raw,14,2));
						my $id = substr($raw,16,$len);
						print "CARD_ID=$id\n";
						$file_content = $id;
						$file_state = $FILE_STATE_COMPLETE;
					}

					# otherwise, for all other commands, the next four bytes should
					# be '00000400', the success pattern

					elsif (substr($raw,8,4) ne $SUCCESS_PATTERN)
					{
						fileRequestError("operation failed: ".unpack('H*',substr($raw,8)));
					}


					elsif ($file_command == $COMMAND_GET_SIZE)
					{
						my $size = unpack('V',substr($raw,12));
						print "SIZE($file_path) = $size\n";
						$file_content = $size;
						$file_state = $FILE_STATE_COMPLETE;
					}
					elsif ($file_command == $COMMAND_DIRECTORY)
					{
						# Each entry is word(length) followed by length bytes of name,
						# followed by a FAT 1 byte bitwise attribute
						#
						#                                         v first length byte
						# 00000500 03000000 00000400 01000100 06000200 2e001002 002e2e10 0e005445   ..............................TE
						# 53545f44 41544131 2e545854 200e0054 4553545f 44415441 322e5458 54201400   ST_DATA1.TXT ..TEST_DATA2.TXT ..
						# 54455354 5f444154 415f494d 41474531 2e4a5047 20140054 4553545f 44415441   TEST_DATA_IMAGE1.JPG ..TEST_DATA
						# 5f494d41 4745322e 4a504720                                                _IMAGE2.JPG
						#
						# There is a dir entry for . followed by a dir entry for ..
						# The entry for . seems to have and included null, where as the one for .. doesnt
						#
						# I don't understand these 6 bytes from 12-17. I presume they are num_packets
						# and packet_num to manage large directory listings
						# 			0100 0100 0600

						print "DIR($file_path)\n";
						my $LIST_OFFSET = 18;
						my $offset = $LIST_OFFSET;
						my $raw_len = length($raw);
						while ($offset < $raw_len)
						{
							my $length = unpack('v',substr($raw,$offset,2));
							$offset += 2;
							my $name = substr($raw,$offset,$length);
							$offset += $length;
							my $attr = unpack('C',substr($raw,$offset,1));
							$offset += 1;

							$name =~ s/\x00//g;								# remove traling null from '.' directory
							$name =~ s/\.//g if $attr & $FAT_VOLUME_ID;		# remove erroneous . in middle of my volume name

							print "    ".dbgFatStr($attr).pad("len($length)",8).$name."\n";

							$file_content .= "\n" if $file_content;
							$file_content .= "$attr\t$name";
						}
						$file_state = $FILE_STATE_COMPLETE;
					}
					elsif ($file_command == $COMMAND_GET_FILE)
					{
						my ($num_packets,$packet_num,$bytes) = unpack('v3',substr($raw,12,6));
						display($dbg_fs,2,"command($file_command) packet($packet_num/$num_packets) bytes=$bytes");

						$file_request_cur = $packet_num;
						$file_request_num = $num_packets;

						my $cur_len = length($file_content);
						if ($cur_len != $packet_num * 1024)
						{
							my $expected = $cur_len / 1024;
							fileRequestError("Unexpected packet_num($packet_num) expected($expected)");
						}
						else
						{
							my $content = substr($raw,18);
							$file_content .= $content;
							if ($packet_num == $num_packets - 1)
							{
								if ($output_filename)
								{
									my $ofilename = "docs/junk/downloads/$output_filename";
									warning(0,2,"writing to $ofilename");
									printVarToFile(1,$ofilename,$file_content,1);
								}
								display($dbg_fs,2,"FILE($file_path) COMPLETED!!");
								$file_state = $FILE_STATE_COMPLETE;
							}
						}	# no length error
					}	#   $COMMAND_GET_FILE
				}	# signature matched
			}	# got some bytes
		}	# 	can read

		else	# !can_read
		{
			if ($file_state > 0 &&
				time() > $request_time + $FILE_REQUEST_TIMEOUT)
			{
				# my $len = length($file_content);
				fileRequestError("TIMEOUT");
			}
			elsif ($file_state == $FILE_STATE_STARTED)
			{
				display($dbg_fs,0,"FILE_STATE_STARTED($file_command)");

				# build the 8 byte reply signature that
				# means the reply is to our request

				$reply_sig = pack('C',$file_command);
				$reply_sig .= $COMMAND_REPLY;
				$reply_sig .= $FUNC_5;
				$reply_sig .= pack('V',$next_seq_num);
				display($dbg_fs+1,2,"reply_sig=".unpack("H*",$reply_sig));
				sendFilesysRequest();
				$file_state = $FILE_STATE_PACKETS;
			}
		}
	}	# while 1
}	# filesysThread



1;