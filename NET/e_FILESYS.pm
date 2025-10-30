#---------------------------------------------
# e_FILESYS.pm
#---------------------------------------------
# Parser for FILESYS packets

package e_FILESYS;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use a_defs;
use a_mon;
use a_utils;
use d_FILESYS;
use base qw(a_parser);


my $dbg_fp = 0;


sub newParser
{
	my ($class, $mon_defs) = @_;
	display($dbg_fp,0,"e_FILESYS::newParser($mon_defs->{name})");
	my $this = $class->SUPER::newParser($mon_defs);
	bless $this,$class;

	$this->{name} = 'e_FILESYS';

	$this->clearFileParser();
	return $this;
}


sub clearFileParser
{
	my ($this) = @_;
	$this->{file_error}  	= '';
	$this->{file_command}	= 0;
	$this->{file_path}   	= '';
	$this->{file_content}	= '';
	$this->{file_offset}	= 0;
	$this->{got_len}		= 0;
}


sub clearError
{
	my ($this) = @_;
	$this->{file_error} = '';
}



sub fileReplyError
	# ... in an error, we return a 'reply' with success=0 and the correct seq_num
{
    my ($this,$cmd,$seq,$err) = @_;
	my $cmd_name = $FILE_CMD_NAME{$cmd};
	my $file_error = "cmd($cmd=$cmd_name) path($this->{file_path}): $err";
	$this->{file_error} = $file_error;
	error($file_error);
	return shared_clone({
		seq_num => $seq,
		success => 0 });
}



sub parsePacket
{
	my ($this,$packet) = @_;
	my $payload = $packet->{payload};
	my $packet_len = length($payload);
	my ($cmd_word,$sid,$seq) = unpack('vvV',substr($payload,0,8));
	
	display($dbg_fp+1,0,"e_FILESYS::parsePacket len($packet_len)");

	$this->{file_error} = '';
	$packet = $this->SUPER::parsePacket($packet);
	return shared_clone({ seq_num=>$seq, success=>0 }) if $this->{file_error};

	display($dbg_fp+1,0,"e_FILESYS::parsePacket returning "._def($packet));
	return $packet;
}


sub parseMessage
{
	my ($this,$packet,$len,$part,$hdr) = @_;

	my ($cmd_word,$sid,$seq) = unpack('vvV',substr($part,0,8));
	my $cmd = $cmd_word & 0xff;
	my $dir = $cmd_word & 0xff00;
	my $offset = 8;

	my $cmd_name = $FILE_CMD_NAME{$cmd};
	$cmd_name ||= 'WHO CARES?';
	my $dir_name = $DIRECTION_NAME{$dir};
	display($dbg_fp+2,1,"e_FILESYS::parseMessage dir($dir)=$dir_name seq($seq) cmd($cmd)=$cmd_name");;

	$this->SUPER::parseMessage($packet,$len,$part,$hdr);

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

		if ($cmd != $FILE_CMD_CARD_ID &&
			$cmd != $FILE_CMD_LOCK &&
			$cmd != $FILE_CMD_UNLOCK)
		{
			if ($cmd == $FILE_CMD_GET_SIZE)
			{
				my $uw = unpack('H*',substr($part,$offset,2));
				$offset += 2;
				$text .= "\n$pad#    unknown_word($uw)";
			}
			elsif ($cmd == $FILE_CMD_GET_FILE)
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

		return $packet;
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

	if ($cmd == $FILE_CMD_CARD_ID)
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

		$this->{file_content} = $id;
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
			if ($cmd == $FILE_CMD_GET_SIZE ||
				$cmd == $FILE_CMD_GET_SIZE2)
			{
				my $size = unpack('V',substr($part,$offset));
				printConsole($packet->{color},$pad."# SIZE = $size",$mon)
					if $mon & $MON_PARSE;
				$this->{file_content} = $size;
			}
			elsif ($cmd == $FILE_CMD_DIRECTORY)
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
				$this->{file_content} = '';
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

					$this->{file_content} .= "\n" if $this->{file_content};
					$this->{file_content} .= "$attr\t$name";
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

			elsif ($cmd == $FILE_CMD_GET_FILE)
			{
				my ($num_packets,$packet_num,$bytes) = unpack('v3',substr($part,$offset,6));
				$offset += 6;

				my $file_offset = $this->{file_offset};
				my $cur_len = $this->{got_len};
				my $expected_len = $file_offset + $packet_num * 1024;

				my $msg = "packet($packet_num/$num_packets) offset($file_offset) cur_len($cur_len) bytes=$bytes";
				display($dbg_fp+2,2,$msg);
				printConsole($packet->{color},$pad.$msg) if $mon & $MON_PARSE;

				if (!$packet->{is_sniffer})		# do 'real' file content management
				{
					$success = 2;
					$this->{file_content} = '' if !$file_offset && !$packet_num;

					if ($cur_len != $expected_len)
					{
						my $expected = $cur_len / 1024;
						return $this->fileReplyError($cmd,$seq,"Unexpected length($cur_len) != expected($expected_len) = ".
							"$file_offset + (1024*$packet_num=".(1024*$packet_num).")");
						# return $this->fileRequestError($seq,"Unexpected packet_num($packet_num) expected($expected)");
					}
					else
					{
						my $content = substr($part,$offset);
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
								display($dbg_fp,2,"FILE($this->{file_path}) COMPLETED!!");
								$success = 1;
							}
							else
							{
								display($dbg_fp,2,"FILE($this->{file_path}) GOT $this->{got_len}/$total_len bytes!!");
							}
						}
					}	# got the next expected buffer
				}	# 'real' content management
			}	# $FILE_CMD_GET_FILE
		}	# success
	}	# !$FILE_CMD_CARD_ID

	#---------------------------------------------
	# possibly return 'reply' to b_sock
	#---------------------------------------------

	if ($success == 1)
	{
		display($dbg_fp+2,0,"FILESYS parseMessage() returning success packet");
		return shared_clone({
			seq_num => $seq,
			success => $success });
	}

	display($dbg_fp+2,0,"FILESYS parseMessage() returning undef");
	return undef;	# still processing file packets


}	# e_FILESYS::parsePacket()



1;