#---------------------------------------------
# tcpBase.pm
#---------------------------------------------
# The base class of a RAYNET tcp socket client.
#
#	my $obj = tcpBase->new($params);
#	$obj->start();
#	$obj->stop();
#
#--------------------------------------
# construcion $params
#--------------------------------------
#	{rayname} - required
#	{EXIT_ON_CLOSE}
#	{local_port} - optional
#	{local_ip} - optional but not recommended
#	{show_input}
#	{show_output}
#	{out_color}
#	{in_color}
#	{CONNECT_TIMEOUT}
#	{RECONNECT_INTERVAL}
#	{READ_TIME} merely the time to wait for a message; NOT AN ERROR
#	{COMMAND_TIMEOUT}
#
# public read-only
#
#	{started}	= indicates that the thread has started
#	{running}	= indicates that the socket has been/is open
#   {stopping}	= indiates the the socket is in the process of closing
#	{connected} = indicatea the socket is currently connected
#
# derived class support
#
#	{next_seqnum};
#	{command_queue}
#	{replies}
#
# private:
#
#	{remote_ip}
#	{remote_port}
#	{stop_time}
#	{connect_time}
#	{out_queue}

#
#-----------------------------------------
# overidden class methods
#-----------------------------------------
#
#	$this->sendPacket($packet) = queue the packet for async sending
#	$this->handlePacket($buffer)
#	$this->commandHandler($this,$command);
#
#------------------
# Ideas:
#------------------
#
#	- built in replay of debugging scripts
#	- built in playing of probe scripts
#	- built in ability to send arbitrary text hex-string encoded packets
#
#	Even for well known RAYNET services, these capabilities might be nice


package tcpBase;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Socket;
use IO::Select;
use Pub::Utils;
use rayports;
use r_defs;
use r_RAYSYS qw(findRayPortByName);
use r_utils qw(parse_dwords setConsoleColor);

my $dbg_tcp = -1;

my $STOP_TIMEOUT = 3;
my $DEFAULT_CONNECT_TIMEOUT = 2;
my $DEFAULT_RECONNECT_INTERVAL = 10;
my $DEFAULT_READ_TIME = 0.1;
my $DEFAULT_COMMAND_TIMEOUT = 3;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(
		findTcpBase
		doProbe

		$SUCCESS_SIG
    );
}

my $global_version:shared = 1;
	# Global local 'database' version


my %tcp_bases:shared;
	# by $rayname
	
sub findTcpBase
{
	my ($rayname) = @_;
	return $tcp_bases{$rayname};
}


sub new
{
	my ($class,$params) = @_;
	display(0,1,"tcpBase::new() called");
	my $this = shared_clone($params);
	bless $this,$class;
	$this->{started}	= 0;
	$this->{connected}	= 0;
	$this->{stopping}	= 0;
	$this->{CONNECT_TIMEOUT} ||= $DEFAULT_CONNECT_TIMEOUT,
	$this->{RECONNECT_INTERVAL}  ||= $DEFAULT_RECONNECT_INTERVAL,
	$this->{READ_TIME} = $DEFAULT_READ_TIME;
	$this->{COMMAND_TIMEOUT} = $DEFAULT_COMMAND_TIMEOUT;
		# {rayname}
		# {EXIT_ON_CLOSE}
		# {local_port} - optional
		# {local_ip} - optional but not recommended
		# {show_input}
		# {show_output}
		# {out_color}
		# {in_color}

	# undefined variables
		# {remote_ip}
		# {remote_port}

	$this->{buffer} = '';
	$this->{connect_time} = 0;
	$this->{stop_time} = 0;
	$this->{out_queue} = shared_clone([]);

	$this->{next_seqnum} = 1;
	$this->{command_queue} = shared_clone([]);
	$this->{replies} = shared_clone([]);

	return $this;
}


sub start
{
	my ($this) = @_;
	display(0,1,"tcpBase::start() called");
	return error("tcpBase already started") if $this->{started};
	$this->{started} = 1;
	my $thread = threads->create(\&tcpBaseThread,$this);
	$thread->detach();
	display(0,1,"tcpBase::start() returning");
}

sub stop
{
	my ($this) = @_;
	display(0,1,"tcpBase::stop() called");
	return error("tcpBase not started") if !$this->{started};
	return error("tcpBase already stopping") if $this->{stopping};
	$this->{stopping} = 1;
}



#----------------------------------------------
# virtual api
#----------------------------------------------

sub waitAddress		{ my ($this) = @_; }
sub handlePacket	{ my ($this,$buffer) = @_; }
sub commandHandler	{ my ($this,$command) = @_; }


#-----------------------------------------------
# probes
#-----------------------------------------------
# A probes filename is {rayname}_probes.txt, and matches the capitalization scheme.
#
# PROBE identifier	identifies a named probe that can be executed from shark
#					by typing "P rayname identifier"
# RAW	hex strings with replacements that will be sent
# MSG	creates word(length) prepended message
# BUMP	bump the sequence number
# WAIT 	wait for any reply
# >>>	text will be output to console
#
# Replacements (in order of operations)
#	{time}	= will be replaced by HH:MM:SS
# 	{seq}	- will be replaced by a dword sequence number that advances once per probe
# 	{func}	= will be replaced by the services word funciton code
# 	{hex16 some name} will be replaced with the hex16 (non zero terminated) name



my $dbg_probe = 0;

sub doProbe
{
	my ($rayname,$ident) = @_;
	display(0,0,"doProbe($rayname,$ident)");
	my $this = findTcpBase($rayname);
	return error("could not find tcpBase($rayname)")
		if !$this;
	my $probes = $this->parseProbes();
	return if !$probes;
	return error("Could not find probe($ident)")
		if !$probes->{$ident};

	my $rayport = findRayPortByName($rayname);
	return error("Could not find rayport($rayname)")
		if !$rayport;
	warning(0,1,"queuing $rayname PROBE($ident)");
	
	my $command = shared_clone({
		name => "PROBE($ident)",
		probes => $probes,
		ident => $ident,
		hex_func => unpack('H*',pack('v',$rayport->{func})), });
	push @{$this->{command_queue}},$command;
}



sub pushStep
{
	my ($probe,$line_num,$step,$step_text) = @_;
	display($dbg_probe+1,1,"pushStep($line_num,$step,$step_text)");
	$step_text =~ s/^\s+|\s+$//g;
	
	if ($step =~ /RAW|MSG/i && !$step_text)
	{
		warning("empty $step section at line $line_num");
	}
	else
	{
		my $text = uc($step);
		$text .= " $step_text" if $step_text;
		push @$probe,$text;
	}
}


sub parseProbes
{
	my ($this) = @_;
	my $rayname = $this->{rayname};
	my $probe_file = "$data_dir/$rayname"."_probes.txt";
	display($dbg_probe,0,"parseProbes($probe_file)");
	my @lines = getTextLines($probe_file);
	return error("missing or empty $probe_file") if !@lines;

	my $probes = shared_clone({});

	my $probe;
	my $step = '';
	my $step_text = '';
	my $num_lines = @lines;
	for (my $i=0; $i<$num_lines; $i++)
	{
		my $line_num = $i + 1;
		my $line = $lines[$i];

		$line =~ s/#.*$//;
		$line =~ s/^\s+|\s+$//g;
		next if !$line;

		if ($line =~ /^PROBE\s+(.*)$/i)
		{
			my $ident = $1;
			display($dbg_probe+1,1,"$line_num: PROBE($ident)");

			pushStep($probe,$line_num,$step,$step_text)
				if $step;
			$step = '';
			$step_text = '';

			$probe = shared_clone([]);
			$probes->{$ident} = $probe;
		}
		elsif ($line =~ /^(RAW|MSG|BUMP|WAIT)(.*)$/)
		{
			my ($sec,$text) = ($1,$2);
			$text =~ s/#.*$//;
			$text =~ s/^\s|\s$//g;
			display($dbg_probe+1,1,"$line_num: $sec $text");

			# push previous step, if any
			pushStep($probe,$line_num,$step,$step_text)
				if $step;
			$step = $sec;
			$step_text = $text;
		}
		elsif ($probe && $line =~ /^>>>/)
		{
			push @$probe,$line;
		}
		elsif ($step && $line)
		{
			$step_text .= $line;
		}
	}

	# push the dangling step if any
	pushStep($probe,$num_lines,$step,$step_text)
		if $step;
	display($dbg_probe+1,0,"parse finished");

	if ($dbg_probe < -1)
	{
		print "-------- probes ----------\n";
		for my $key (sort keys %$probes)
		{
			my $probe = $probes->{$key};
			print "PROBE($key)\n";
			for my $line (@$probe)
			{
				print "    $line\n";
			}
		}
		print "-------------------------\n";
	}
	
	my $num_probes = keys %$probes;
	return error("NO probes found in $probe_file!")
		if !$num_probes;
	display($dbg_probe,0,"parseProbes() returning $num_probes probes");
	return $probes;
}



#----------------------------------------------
# utilities
#----------------------------------------------

sub sendPacket
{
	my ($this,$buffer) = @_;
	return error("sendPacket() no connection to $this->{rayname})")
		if (!$this->{connected});
	push @{$this->{out_queue}},$buffer;
}


#------------------------------------------------
# derived/client API
#------------------------------------------------


sub getVersion
{
	return $global_version;
}


sub incVersion
{
	$global_version++;
	display($dbg_tcp+1,0,"incVersion($global_version)");
	return $global_version;
}


sub waitReply
{
	my ($this,$expect_success) = @_;
	my $rayname = $this->{rayname};
	my $seq = $this->{wait_seq};
	my $wait_name = $this->{wait_name};


	my $start = time();

	display($dbg_tcp+1,0,"$rayname waitReply($seq) $wait_name");

	while ($this->{started})
	{
		my $replies = $this->{replies};
		if (@$replies)
		{
			my $reply = shift @$replies;
			# is_event($reply->{is_event};
			display_hash($dbg_tcp+2,1,"$this->{rayname} got reply seq($reply->{seq_num})",$reply);
			if ($reply->{seq_num} == $seq)
			{
				if ($expect_success)
				{
					my $got_success = $reply->{success} ? 1 : -1;
					if ($got_success != $expect_success)
					{
						error("$rayname waitReply($seq,$wait_name) expected success($expect_success) but got($got_success)");
						# display_hash($dbg,1,"offending reply",$reply);
						return 0;
					}
				}

				display($dbg_tcp,1,"$rayname waitReply($seq,$wait_name) returning OK reply");
				return $reply;
			}
			else
			{
				# display_hash($dbg+1,1,"skipping reply",$reply);
			}
		}

		if (time() > $start + $this->{COMMAND_TIMEOUT})
		{
			error("$rayname Command($seq,$wait_name) timed out");
			return '';
		}

		sleep(0.5);
	}

	return error("waitReply($seq) while !started");
}



#======================================================================================
# tcpBaseThread
#======================================================================================


sub _close_socket
{
	my ($this,$sock) = @_;
	display($dbg_tcp,0,"closing tcp socket($this->{rayname})");
	$this->{buffer} = '';
	$this->{out_queue} = shared_clone([]);
	$this->{connected} = 0;
	$sock->close();
	return undef;

}



sub tcpBaseThread
{
	my ($this) = @_;
	my $rayname = $this->{rayname};

	$dbg_tcp < -1 ?
		display_hash($dbg_tcp+1,0,"tcpBaseThread($rayname) starting",$this) :
		display($dbg_tcp,0,"tcpBaseThread($rayname) starting");

	my $rayport = findRayPortByName($rayname);
	while (!$rayport)
	{
		display($dbg_tcp-1,1,"waiting for rayport($rayname)");
		sleep(1);
		$rayport = findRayPortByName($rayname);
	}
	$this->{remote_ip} = $rayport->{ip};
	$this->{remote_port} = $rayport->{port};
	$this->{remote} = "$this->{remote_ip}:$this->{remote_port}";
	display($dbg_tcp,1,"found rayport($rayname) at $this->{remote}");

	$this->{local} = _def($this->{local_ip}).":"._def($this->{local_port});
	$tcp_bases{$rayname} = $this;

	$this->{running} = 1;

	my $sel;
	my $sock;
	display($dbg_tcp,0,"tcpBaseThread($rayname,$this->{remote}) running");
	while (1)
	{
		# handle client stopping
		
		if ($sock)
		{
			if ($this->{stopping} == 1)
			{
				display($dbg_tcp,1,"shutting down $rayname socket($this->{remote})");
				$sock->shutdown(1);	# prevent further writes (allow FIN to be read)
				$this->{stopping} = 2;
				$this->{stop_time} = time();
			}
			elsif ($this->{stopping} == 2 &&
				   time() > $this->{stop_time} + $STOP_TIMEOUT)
			{
				display($dbg_tcp+1,1,"$rayname socket($this->{remote}) shutdown timeout");
				$sock = $this->_close_socket($sock);
				last;
			}
		}

		# open the socket if appropriate

		elsif (!$this->{stopping} &&
				time() > $this->{connect_time} + $this->{RECONNECT_INTERVAL})
		{
			display($dbg_tcp,1,"connecting $rayname($this->{local}) to socket($this->{remote})");
			$sock = IO::Socket::INET->new(
				LocalAddr => $this->{local_ip},
				LocalPort => $this->{local_port},
				PeerAddr  => $this->{remote_ip},
				PeerPort  => $this->{remote_port},
				Proto     => 'tcp',
				Reuse	  => 1,	# allows open even if windows is timing it out
				Timeout	  => $this->{CONNECT_TIMEOUT} );
			if ($sock)
			{
				$this->{connected} = 1;
				$this->{local_ip} = $sock->sockhost();
				$this->{local_port} = $sock->sockport();
				$this->{local} = "$this->{local_ip}:$this->{local_port}";
				display($dbg_tcp,2,"$rayname $this->{local} CONNECTED to socket($this->{remote})");
				$sel = IO::Select->new($sock);
			}
			else
			{
				error("Could not connect to $this->{remote}: $!");
				last if $this->{EXIT_ON_CLOSE};
				display($dbg_tcp+1,2,"will retry in $this->{RECONNECT_INTERVAL} seconds");
			}
			$this->{connect_time} = time();

		}	# !$sock && !stopping and connect_time>RECONNECT_INTERVAL


		# PROCESSING OF OPEN SOCKET
		# (a) send the next out bound message if any

		if ($sock && !$this->{stopping})
		{
			if ($sel->can_write() && @{$this->{out_queue}})
			{
				my $packet = shift @{$this->{out_queue}};
				my $pack_len = length($packet);
				if ($this->{show_output})
				{
					my $header = "$rayname <-- ".pad(" len($pack_len)",9)." ";
					setConsoleColor($this->{out_color}) if $this->{out_color};
					print parse_dwords($header,$packet,1);
					setConsoleColor() if $this->{out_color};
				}
				my $rslt = $sock->send($packet);
				if (!defined($rslt))
				{
					error("Could not write to $this->{remote}: $!");
					$sock = $this->_close_socket($sock);
					last if $this->{EXIT_ON_CLOSE};
				}
				else
				{
					$this->{connect_time} = time();
				}
			}
		}

		# (b) read the buffer

		if ($sock)
		{
			if ($sel->can_read($this->{READ_TIME}))
			{
				my $buf;
				my $rslt = recv($sock,$buf,4096,0);
				my $len = length($buf);
				if (!defined($rslt))
				{
					# connection closed by remote
					error("tcpBase($this->{remote}) read error: $!");
					$sock = $this->_close_socket($sock);
					last if $this->{EXIT_ON_CLOSE};
				}
				elsif ($len == 0)
				{
					warning($dbg_tcp,0,"received FIN.");
					$sock = $this->_close_socket($sock);
					last if $this->{EXIT_ON_CLOSE};
				}
				elsif (!$this->{stopping})
				{
					$this->{buffer} .= $buf;
					my $buflen = length($this->{buffer});
					if ($buflen > 2)
					{
						my $client_buffer = $this->{buffer};
						$this->{buffer} = '';
						if ($this->{show_input})
						{
							my $header = "$rayname --> ".pad(" len($buflen)",9)." ";
							setConsoleColor($this->{in_color}) if $this->{in_color};
							print parse_dwords($header,$client_buffer,1);
							setConsoleColor() if $this->{in_color};
						}

						# hook for probes to not call derived handle packet
						
						if ($this->{probe_wait})
						{
							display($dbg_probe,0,"probe WAIT completed");
							$this->{probe_wait} = 0;
						}
						# else
						{
							my $reply = $this->handlePacket($client_buffer);
							push @{$this->{replies}},$reply if $reply;
						}
					}
					$this->{connect_time} = time();

				}	# got a buffer
			}	# can_read()
		}	# $sock


		# onIdle

		if ($sock &&
			!$this->{stopping} &&
			!$this->{busy} &&
			@{$this->{command_queue}})
		{
			my $command = shift @{$this->{command_queue}};
			$this->{busy} = 1;

			display($dbg_tcp,0,"creating commandThread($rayname,$command->{name})");
			my $cmd_thread = threads->create(\&commandThread,$this,$command);
			$cmd_thread->detach();
		}

	}	# while 1


	display($dbg_tcp,0,"exiting tcpBaseThread($rayname)");
	delete $tcp_bases{$rayname};
	$this->{running} = 0;
	$sock = $this->close_socket($sock) if $sock;

}





sub commandThread
{
	my ($this,$command) = @_;
	display($dbg_tcp,0,"$this->{rayname} commandThread($command->{name}) started");

	if ($command->{name} =~ /^PROBE/)
	{
		my $save_in = $this->{show_input};
		my $save_out = $this->{show_output};
		$this->{show_input} = 1;
		$this->{show_output} = 1;
		$this->do_probe($command);
		$this->{show_input} = $save_in;
		$this->{show_output} = $save_out;
	}
	else
	{
		$this->handleCommand($command);
	}
	$this->{busy} = 0;
		# Note to self.  I used to pull the command off the queue and use
		# {command} as the busy indicator, then set it to '' here.
		# But I believe that I once again ran into a Perl weirdness
		# that Perl will crash (during garbage collection) if you
		# re-assign a a shared reference to a scalar.
	display($dbg_tcp,0,"$this->{rayname} commandThread($command->{name}) finished");
}


sub do_probe
{
	my ($this,$command) = @_;
	my $ident = $command->{ident};
	my $probes = $command->{probes};
	my $probe = $probes->{$ident};
	my $num_steps = @$probe;
	my $seq = $this->{next_seqnum};

	display(0,0,"do_probe($ident) with $num_steps steps");

	for (my $i=0; $i<$num_steps; $i++)
	{
		my $line = $$probe[$i];
		display($dbg_probe+2,1,"probe line($i) = $line");
		
		if ($line =~ s/^>>>//)
		{
			print "$line\n";
		}
		elsif ($line =~ /&BUMP/)
		{
			$seq = ++$this->{next_seqnum};
		}
		elsif ($line =~ /^(RAW|MSG) (.*)$/)
		{
			my ($cmd,$text) = ($1,$2);
			my $hex_seq = unpack('H*',pack('V',$seq));
			my $now = now();

			$text =~ s/{time}/$now/g;
			$text =~ s/{seq}/$hex_seq/g;
			$text =~ s/{func}/$command->{hex_func}/g;
			
			while ($text =~ s/{hex16\s+(.*?)}/##HERE##/)
			{
				my $name = $1;
				my $hex = name16_hex($name,1);	# no terminator
				my $data = pack('H*',$hex);
				display_bytes($dbg_probe+2,1,"HEX16($name)=$hex",$data);
				$text =~ s/##HERE##/$hex/;
			}

			$text =~ s/\s//g;

			my $data = pack('H*',$text);
			my $len = length($data);
			
			display($dbg_probe,1,"$cmd($len) = $text");

			if ($cmd eq 'MSG')
			{
				display($dbg_probe+1,2,"PROBE: send len($len)");
				$this->sendPacket(pack('v',$len))
			}
			display($dbg_probe+1,2,"PROBE: send $text");
			$this->sendPacket($data);
		}


		# this is where it gets weird
		# by default, this will actually call
		# derived classes handlePacket() method,
		# and *could* actually be used to implement waitReply,
		# BUT especially for testing a variety of messages,
		# we may not want to modify their parsers as we go.

		elsif ($line =~ /^WAIT\s*(.*)$/)
		{
			my $extra = $1;
			my $PROBE_TIMEOUT = 3;
			$this->{probe_wait} = 1;
			my $time = time();
			while ($this->{probe_wait})
			{
				if (time() > $time + $PROBE_TIMEOUT)
				{
					warning($dbg_probe,0,"PROBE WAIT TIMEOUT");
					last;
				}
				sleep(0.1);
			}
			$this->{probe_wait} = 0;
		}
	}

	display(0,0,"PROBE($ident) FINISHED");
}




1;