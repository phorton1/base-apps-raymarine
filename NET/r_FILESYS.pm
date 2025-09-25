#---------------------------------------------
# r_FILESYS.pm
#---------------------------------------------

package apps::raymarine::NET::r_FILESYS;
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
use apps::raymarine::NET::r_utils;
use apps::raymarine::NET::r_RAYDP;

my $dbg_fs = 0;


my $FILE_REQUEST_TIMEOUT    = 2;        # seconds

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


		$FILE_STATE_ERROR
		$FILE_STATE_COMPLETE
		$FILE_STATE_IDLE
		$FILE_STATE_STARTED
		$FILE_STATE_PACKETS

        getFileRequestState
        getFileRequestError
        getFileRequestContent

        requestSize
		requestFile
        requestDirectory
    );
}


# command constants



my $COMMAND_DIRECTORY   = 0;		# returns a directory listing without any file or directory sizes (plus some other stuff)
my $COMMAND_GET_SIZE    = 1;		# returns a dword size (success completely understood)
my $COMMAND_GET_FILE    = 2;		# returns the contents of a file (success completely understood)
my $COMMAND_REGISTER    = 9;		# returns a string (plus some other stuff)

my $COMMAND_REQUEST     = pack('C',1);
my $COMMAND_REPLY       = pack('C',0);
my $FUNC_5              = pack('H*','0500');
my $SUCCESS_PATTERN		= pack("H*",'00000400');

my $UNKNOWN_MAGIC_FILE_KEY = '9a9d0100';
	# this is required for $COMMAND_GET_FILE

# FAT attribute bits

my $FAT_READ_ONLY   = 0x01;
my $FAT_HIDDEN      = 0x02;
my $FAT_SYSTEM      = 0x04;
my $FAT_VOLUME_ID   = 0x08;
my $FAT_DIRECTORY   = 0x10;
my $FAT_FILE     	= 0x20;

# shared variables

my $filesys_ip:shared		= '';
my $filesys_port:shared 	= 0;

my $file_state:shared       = 0;
my $file_error:shared       = '';

my $file_command:shared     = 0;
my $file_path:shared        = '';
my $file_content:shared    	= '';
my $request_time:shared    	= 0;	# Shouldn't need to be shared

# these vars are thread local, non-shared

my $file_req_num		= -1;
my $next_seq_num  		= 0;


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


sub requestSize
{
	my ($path) = @_;
	initFileRequest($COMMAND_GET_SIZE,$path);
}

sub requestFile
{
	my ($filename) = @_;
	initFileRequest($COMMAND_GET_FILE,$filename);
}

sub requestDirectory
{
	my ($path) = @_;
	initFileRequest($COMMAND_DIRECTORY,$path);
}



#----------------------------------------------------
# implementation
#----------------------------------------------------

sub fatStr
{
	my ($flag) = @_;
	my $text = sprintf("flag(0x%02x) ",$flag);
	$text .= 'VOL  ' 	if $flag & $FAT_VOLUME_ID;
	$text .= 'DIR  ' 	if $flag & $FAT_DIRECTORY;
	$text .= 'FILE ' 	if $flag & $FAT_FILE;
	$text .= 'r'  		if $flag & $FAT_READ_ONLY;
	$text .= 'h'  		if $flag & $FAT_HIDDEN;
	$text .= 's'  		if $flag & $FAT_SYSTEM;
	$text = pad($text,20);
	return $text;
}

sub commandStr
{
	return "DIRECTORY"	if $file_command == $COMMAND_DIRECTORY;
	return "GET_SIZE" 	if $file_command == $COMMAND_GET_SIZE;
	return "GET_FILE" 	if $file_command == $COMMAND_GET_FILE;
	return "REGISTER" 	if $file_command == $COMMAND_REGISTER;
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
    my ($command,$path) = @_;

	if (!$filesys_port)
	{
		error("No filesys_port in fileRequest($command,$path)");
		return;
	}
	if ($file_state > 0)
	{
		error("requestFile($command,$path) in state($file_state)");
		return;
	}

	$file_command 	= $command;
	$file_path 		= $path;
	$file_content	= '';
	$file_error 	= '';
	$request_time 	= time();
	$file_state 	= $FILE_STATE_STARTED;
}


sub sendRegisterRequest
{
	# interesting an error here put a 0 as the command, with no length or path got a directory
	my $packet = pack('C',$COMMAND_REGISTER);
	$packet .= $COMMAND_REQUEST;
	$packet .= $FUNC_5;
	$packet .= pack('V',$next_seq_num++);
	$packet .= pack('v',$FILESYS_LISTEN_PORT);
    sendUDPPacket(
        'fileRegister',
        $filesys_ip,
        $filesys_port,
        $packet);
}


sub sendFilesysRequest
	# first time I tried this it crashed the E80 with the packet
	# 	02010500 01000000 01482000 5c6a756e 6b5f6461 74615c74 6573745f 64617461   .........H .\junk_data\test_data
	# 	5f696d61 6765312e 6a706700                                                _image1.jpg.
	#
	# command(2) should look like 02010500 06000000 {PORT} 00000000 9a9d0100
	# missing the extra dword(0) and magic_key(9a9d0100) on first try
{
	my ($command,$path) = @_;
	$command ||= $file_command;
	$path 	 ||= $file_path;
		# optional params allow calling from main thread

	my $seq_num = $next_seq_num++;
	my $len = length($path) + 1;
	my $packet = pack('C',$command);
	$packet .= $COMMAND_REQUEST;
	$packet .= $FUNC_5;
	$packet .= pack('V',$seq_num);
	$packet .= pack('v',$FILESYS_LISTEN_PORT);

	$packet .= pack('H*','0000') if $command == $COMMAND_GET_SIZE;
		# add a dword for command get size
	$packet .= pack('H*','00000000'.$UNKNOWN_MAGIC_FILE_KEY) if $command == $COMMAND_GET_FILE;
		# add the extra dword and magic key

	$packet .= pack('v',$len);
	$packet .= $path;
	$packet .= chr(0);

    sendUDPPacket(
        "fileCommand($file_command)",
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
    display(0,0,"filesysThread($FILESYS_LISTEN_PORT) started");

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
    display(0,0,"listen socket opened");

	# get FILESYS ip:port

	my $rayport = findRayPortByName('FILESYS');
	while (!$rayport)
	{
		display(0,1,"waiting for rayport(FILESYS)");
		sleep(1);
		$rayport = findRayPortByName('FILESYS');
	}
	$filesys_ip = $rayport->{ip};
	$filesys_port = $rayport->{port};
	display(0,1,"found rayport(FILESYS) at $filesys_ip:$filesys_port");
	
	# start the loop

	my $reply_sig;
    my $sel = IO::Select->new($sock);
    while (1)
    {
        if ($sel->can_read(0.1))
        {
            display(0,1," filesysThread can_read");

			my $raw;
			recv($sock, $raw, 4096, 0);
			if ($raw)
			{
				setConsoleColor($UTILS_COLOR_LIGHT_MAGENTA);
				display(0,1,"filesysThread() GOT ".length($raw)." BYTES "._lim(unpack("H*",$raw),32));
				setConsoleColor();

				$request_time = time();

				if ($file_state == $FILE_STATE_PACKETS &&
					substr($raw,0,8) eq $reply_sig)
				{
					# the next four bytes should be '00000400', the success pattern

					if (substr($raw,8,4) ne $SUCCESS_PATTERN)
					{
						fileRequestError("operation failed: ".unpack('H*',substr($raw,9)));
					}
					elsif ($file_command == $COMMAND_GET_SIZE)
					{
						my $size = unpack('V',substr($raw,12));
						print "SIZE($file_path) = $size\r\n";
						$file_state = $FILE_STATE_COMPLETE;
					}
					elsif ($file_command == $COMMAND_DIRECTORY)
					{
						# Each entry is word(length) followed by length bytes of name,
						# followed by a 1 byte FAT bit flag.
						#
						#                                         v first length byte
						# 00000500 03000000 00000400 01000100 06000200 2e001002 002e2e10 0e005445   ..............................TE
						# 53545f44 41544131 2e545854 200e0054 4553545f 44415441 322e5458 54201400   ST_DATA1.TXT ..TEST_DATA2.TXT ..
						# 54455354 5f444154 415f494d 41474531 2e4a5047 20140054 4553545f 44415441   TEST_DATA_IMAGE1.JPG ..TEST_DATA
						# 5f494d41 4745322e 4a504720                                                _IMAGE2.JPG
						#
						# There is a dir entry for . followed by a dir entry for ..
						# The entry for . seems to have include null, where as the one for .. doesnt
						#
						# I don't understand these 6 bytes from 12-17. I presume they are num_packets
						# and packet_num to manage large directory listing.
						#
						# 0100 0100 0600

						print "DIR($file_path)\n";
						my $LIST_OFFSET = 18;
						my $offset = $LIST_OFFSET;
						my $raw_len = length($raw);
						while ($offset < $raw_len)
						{
							my $length = unpack('v',substr($raw,$offset,2));
							$offset += 2;
							my $name = substr($raw,$offset,$length);
							$name =~ s/\x00$//;	# remove traling null from '.' directory

							$offset += $length;
							my $flag = unpack('C',substr($raw,$offset,1));
							$offset += 1;

							print "    ".fatStr($flag).pad("len($length)",8).$name."\r\n";
							$file_state = $FILE_STATE_COMPLETE;
						}

					}
					elsif ($file_command == $COMMAND_GET_FILE)
					{
						my ($num_packets,$packet_num,$bytes) = unpack('v3',substr($raw,12,6));
						display(0,2,"command($file_command) packet($packet_num/$num_packets) bytes=$bytes");

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
								my $output_filename = $file_path;
								$output_filename =~ s/^.*\\//;
								display(0,2,"FILE($output_filename) COMPLETED!!");
								printVarToFile(1,$output_filename,$file_content,1);
								$file_state = $FILE_STATE_COMPLETE;
							}
						}	# no length error
					}	# $COMMAND_GET_FILE
				}	# signature matched
			}	# got some bytes
		}	# 	can read

		elsif ($file_state > 0 &&
			   time() > $request_time + $FILE_REQUEST_TIMEOUT)
		{
			my $len = length($file_content);
			fileRequestError("offset($len) TIMEOUT");
		}
		elsif ($file_state == $FILE_STATE_STARTED)
		{
			sendRegisterRequest();
			# build the 8 byte reply signature that
			# means the reply is to our request

			$reply_sig = pack('C',$file_command);
			$reply_sig .= $COMMAND_REPLY;
			$reply_sig .= $FUNC_5;
			$reply_sig .= pack('V',$next_seq_num);
			display(0,2,"reply_sig=".unpack("H*",$reply_sig));
			sendFilesysRequest();
			$file_state = $FILE_STATE_PACKETS;
		}
	}	# while 1
}	# filesysThread



1;