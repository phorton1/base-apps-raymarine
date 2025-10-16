#---------------------------------------------
# b_sock.pm
#---------------------------------------------
# The base class of a RAYNET socket.
# Sockets are constructed with a (possibly undefined)
#	reference to a packetHandler method, and the following
#   parameters:
#
#	{name} 			REQUIRED
#		a name that is passed in for identification and
#		debugging, that follows my capitalization scheme,
#		and which is used to find the ip:port if
#		they are not passed in during construction.
#	{proto} 		REQUIRED
#		'tcp', 'udp', or 'mcast'
#	{service_id} 	RECOMMENDED
#		The 'service id' of a RAYNET service, for identification
#		and debugging, which may be -1 indicating that the RAYNET
#		service_id has not yet have been identified.
#   {ip} 	optional (based on $AUTO_START_IMPLEMENTED_SERVICES)
#		human readable ip address
#   {port} 	optional (based on $AUTO_START_IMPLEMENTED_SERVICES)
#		a remote port
#
# Optional:
#
#	{DELAY_START}
#		puts a sleep at the top of sockThread and commandThread
#		used to delay starting RAYSYS until shark.pm has settled down
#	{EXIT_ON_CLOSE}
#		if this is passed in, a failure to open the tcp
#		socket, or a failure reading from or writing to
#		the socket, will cause the socket thread to exit
#	{show_raw_input}
#	{show_raw_output}
#	{show_parsed_input}
#	{show_parsed_output}
#	{in_color}
#	{out_color}
#		Show the raw stream input or output as it arrives or is sent
#
# Optional but not used on mcast ports
#
#	{local_port} - useful for identifying traffic
#   {local_ip} - not recommended
#
#
# All sockets implement a listener thread that waits for incoming
# packets. THIS CLASS COMBINES received tcp packets until their
# length is greater than 2 (i.e. until a full Reply is received),
# before further processing.
#
# This class performs no parsing or monitoring of the packets
# that are recieved or sent, although it does containing debugging
# to see raw bytes of the packets to help identify problems in
# higher level (parser) code.
#
# Note that this class *may* constructed without ip:port
# members, in which case, it will call c_RAYSYS findRayportByRayname()
# until the given name is present, from which it can determine
# the ip and port.
#
# However, typically it will work the opposite way.  That when
# c_RAYSYS discovers a port with a known (capitalized or otherwise?)
# name, that c_RAYSYS itself will instantiate the (real) r_service,
# which will, in turn, inherit from this base class.
#
# This class handles loss of tcp connections as identified by
# results to $sock->send() and $sock->receive() and manages (attempts)
# reconnections after a specific interval of time.


package b_sock;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Socket;
use IO::Select;
use IO::Socket::INET;
use IO::Socket::Multicast;
use Pub::Utils;
use a_utils qw(parse_dwords setConsoleColor);

# use a_defs;
# use c_RAYSYS qw(findServicePortByName);
# use a_utils qw(parse_dwords setConsoleColor);
# require "tcpProbe.pm";


my $dbg_api 	= 0;
my $dbg_thread  = 0;
my $dbg_cmd  	= 0;
my $dbg_wait 	= 0;

my $DESTROY_TIMEOUT				= 3;	# must be larger than $STOP_TIMEOUT
my $STOP_TIMEOUT 				= 1;
my $DEFAULT_CONNECT_TIMEOUT 	= 2;
my $DEFAULT_RECONNECT_INTERVAL	= 10;
my $DEFAULT_READ_TIME 			= 0.1;
my $DEFAULT_COMMAND_TIMEOUT 	= 3;


my $global_version:shared = 1;
	# a global version to treat all "real" services
	# as one big database for the h_server to GoogleEarth
my %r_socks:shared;
	# by ip:port while the socket is open
	

my @command_done;


#-----------------------------
# init, destroy, start, and stop
#-----------------------------

sub init
{
	my ($this) = @_;
	display($dbg_api,0,"b_sock init($this->{name},$this->{proto},"._def($this->{ip}).","._def($this->{port}).")");

	# {name}
	# {proto}
	# {service_id}
	# {ip}
	# {port}

    $this->{started}   			= 0;
    $this->{connected} 			= 0;
    $this->{stopping}  			= 0;
    $this->{destroyed} 			= 0;
    $this->{CONNECT_TIMEOUT}    ||= $DEFAULT_CONNECT_TIMEOUT;
    $this->{RECONNECT_INTERVAL} ||= $DEFAULT_RECONNECT_INTERVAL;
    $this->{READ_TIME}          ||= $DEFAULT_READ_TIME;
    $this->{COMMAND_TIMEOUT}    ||= $DEFAULT_COMMAND_TIMEOUT;
    $this->{buffer}             = '';
    $this->{connect_time}       = 0;
    $this->{stop_time}          = 0;
    $this->{out_queue}          = shared_clone([]);
    $this->{next_seqnum}        = 1;
    $this->{command_queue}      = shared_clone([]);
    $this->{replies}            = shared_clone([]);

	# {DELAY_START}
	# {EXIT_ON_CLOSE}
	# {show_raw_input}
	# {show_raw_output}
	# {show_parsed_input}
	# {show_parsed_output}
	# {in_color}
	# {out_color}
	# {local_port} - optional
	# {local_ip} - optional but not recommended
}


sub destroy
{
    my ($this) = @_;
	display($dbg_api,0,"b_sock destroy($this->{name})");

	if ($this->{started} && !$this->{destroyed})
	{
		display($dbg_api,0,"b_sock destroy($this->{name}) stopping threads");
		$this->{stopping} = 1;
		my $start_destroy = time();
		while (!$this->{destroyed} &&
			   time() - $start_destroy < $DESTROY_TIMEOUT)
		{
			sleep 0.1;
		}
		$this->{destroyed} ?
			display($dbg_api,0,"b_sock destroy($this->{name}) threads detroyed") :
			error("timeout in b_sock destroy($this->{name})");
	}

    delete @$this{qw(
        started
		connected
		stopping
		destroyed
        CONNECT_TIMEOUT
		RECONNECT_INTERVAL
		READ_TIME
		COMMAND_TIMEOUT
		DELAY_START
        buffer
		connect_time
		stop_time
		out_queue
		next_seqnum
        command_queue
		replies
		local_ip
		local_port
		local

		EXIT_ON_CLOSE
		show_raw_input
		show_raw_output
		show_parsed_input
		show_parsed_output
		in_color
		out_color

		wait_seq
		wait_name
		
    )};
}



sub start
{
	my ($this) = @_;
	display($dbg_api,1,"b_sock start($this->{name}) called");
	return error("start($this->{name})  already started") if $this->{started};
	return error("start($this->{name}) has been destroyed") if $this->{detroyed};
	$this->{started} = 1;

	# start the listener thread
	my $thread = threads->create(\&sockThread,$this);
	$thread->detach();

	# start the command thread
	my $thread2 = threads->create(\&commandThread,$this);
	$thread2->detach();

	display($dbg_api,1,"b_sock start($this->{name}) returning");
}


sub stop
{
	my ($this) = @_;
	display($dbg_api,1,"b_sock stop($this->{name}) called");
	return error("stop($this->{name}) not started") if !$this->{started};
	return error("stop($this->{name}) already stopping") if $this->{stopping};
	return error("stop($this->{name}) has been destroyed") if $this->{detroyed};
	$this->{stopping} = 1;
}


#------------------------------------------------
# virtual (stub) API
#------------------------------------------------

sub handlePacket
{
	my ($this,$buffer) = @_;
	return undef;
}

sub handleCommand
{
	my ($this,$command) = @_;
	return 0;	# return value not used yet
}


sub onStartSocketThread
{
	my ($this) = @_;
}


#------------------------------------------------
# derived client API
#------------------------------------------------

sub getVersion
{
	return $global_version;
}


sub incVersion
{
	$global_version++;
	display($dbg_cmd+1,0,"incVersion($global_version)");
	return $global_version;
}


sub sendPacket
{
	my ($this,$buffer) = @_;
	display($dbg_cmd,1,"b_sock sendPacket($this->{name}) len(".length($buffer).")");
	return error("sendPacket($this->{name}) not started") if !$this->{started};
	return error("sendPacket($this->{name}) no connection") if !$this->{connected};
	return error("sendPacket($this->{name}) has been destroyed") if $this->{destroyed};
	return error("sendPacket($this->{name}) is stopping") if $this->{stopping};
	push @{$this->{out_queue}},$buffer;
}


sub waitReply
{
	my ($this,$expect_success) = @_;
	my $name = $this->{name};
	my $seq = $this->{wait_seq};
	my $wait_name = $this->{wait_name};
	my $start = time();

	display($dbg_wait,0,"$name waitReply($seq) $wait_name");

	while ($this->{connected} &&
		   !$this->{stopping} &&
		   !$this->{destroyed})
	{
		my $replies = $this->{replies};
		if (@$replies)
		{
			my $reply = shift @$replies;
			# is_event($reply->{is_event};
			display_hash($dbg_wait,1,"$this->{name} got reply seq($reply->{seq_num})",$reply);
			if ($reply->{seq_num} == $seq)
			{
				if ($expect_success)
				{
					my $got_success = $reply->{success} ? 1 : -1;
					if ($got_success != $expect_success)
					{
						error("$name waitReply($seq,$wait_name) expected success($expect_success) but got($got_success)");
						# display_hash($dbg,1,"offending reply",$reply);
						return 0;
					}
				}

				display($dbg_wait,1,"$name waitReply($seq,$wait_name) returning OK reply");
				return $reply;
			}
			else
			{
				# display_hash($dbg+1,1,"skipping reply",$reply);
			}
		}

		if (time() > $start + $this->{COMMAND_TIMEOUT})
		{
			error("$name Command($seq,$wait_name) timed out");
			return '';
		}

		sleep(0.5);
	}

	return error("waitReply($seq) died");
}



#======================================================================================
# sockThread
#======================================================================================


sub _close_socket
{
	my ($this,$sock) = @_;
	display($dbg_thread,0,"closing tcp socket($this->{name})");
	$this->{buffer} = '';
	$this->{out_queue} = shared_clone([]);
	$this->{connected} = 0;
	$sock->close();
	return undef;

}


sub sockThread
{
	my ($this) = @_;
	my $name = $this->{name};

	$dbg_thread < -1 ?
		display_hash($dbg_thread+1,0,"b_sock sockThread($name) starting",$this) :
		display($dbg_thread,0,"b_sock sockThread($name) starting",0,$UTILS_COLOR_LIGHT_MAGENTA);

	if ($this->{DELAY_START})
	{
		display($dbg_thread,1,"DELAYING b_sock sockThread for $this->{DELAY_START} seconds");
		sleep($this->{DELAY_START});
	}

	# ip and port are optional base for implemented services
	# based on $AUTO_START_IMPLEMENTED_SERVICES

	if (!$this->{ip} || !$this->{port})
	{
		my $service_port = findServicePortByName($name);
		while (!$service_port)
		{
			display($dbg_thread-1,1,"waiting for service_port($name)");
			sleep(1);
			$service_port = findServicePortByName($name);
		}
		display($dbg_thread,1,"found service_port($name) at $service_port->{ip}:$service_port->{port}");
		$this->{ip} = $service_port->{ip};
		$this->{port} = $service_port->{port};
	}

	$this->{remote} = "$this->{ip}:$this->{port}";
	$this->{local} = _def($this->{local_ip}).":"._def($this->{local_port});
	$r_socks{$this->{remote}} = $this;

	$this->{running} = 1;
	$this->onStartSocketThread();

	my $sel = undef;
	my $sock = undef;
		# WEIRD - if I don't explicitly assign $sock to undef, it somehow
		# mysteriously gets plugged with the previous (c_RAYSYS mcast) socket!!!
		
	display($dbg_thread,0,"sockThread($name,$this->{remote}) running sock="._def($sock));
	while (1)
	{
		# handle client stopping

		if ($sock)
		{
			if ($this->{stopping} == 1)
			{
				display($dbg_thread,1,"shutting down $name socket($this->{remote})");
				$sock->shutdown(1);	# prevent further writes (allow FIN to be read)
				$this->{stopping} = 2;
				$this->{stop_time} = time();
			}
			elsif ($this->{stopping} == 2 &&
				   time() > $this->{stop_time} + $STOP_TIMEOUT)
			{
				display($dbg_thread+1,1,"$name socket($this->{remote}) shutdown timeout");
				$sock = $this->_close_socket($sock);
				last;
			}
		}

		# open the socket if appropriate

		elsif (!$this->{stopping} &&
				time() > $this->{connect_time} + $this->{RECONNECT_INTERVAL})
		{
			display($dbg_thread,1,"connecting $this->{proto} $name($this->{local}) to socket($this->{remote})");

			if ($this->{proto} eq 'tcp')
			{
				$sock = IO::Socket::INET->new(
					LocalAddr => $this->{local_ip},
					LocalPort => $this->{local_port},
					PeerAddr  => $this->{ip},
					PeerPort  => $this->{port},
					Proto     => $this->{proto},
					ReuseAddr => 1,	# allows open even if windows is timing it out
					Timeout	  => $this->{CONNECT_TIMEOUT} );
			}
			elsif ($this->{proto} eq 'udp')
			{
				# udp service ports merely open a listener
				# and do not use the base class send command
				
				$sock = IO::Socket::INET->new(
					LocalAddr => $this->{local_ip},
					LocalPort => $this->{local_port},
					# PeerAddr  => $this->{ip},
					# PeerPort  => $this->{port},
					Proto     => $this->{proto},
					ReuseAddr => 1,	# allows open even if windows is timing it out
					Timeout	  => $this->{CONNECT_TIMEOUT} );

				setsockopt($sock, SOL_SOCKET, SO_RCVBUF, pack("I", 0x1ffffff)) if $sock;
					# Increasing the udp socket buffer size was required for me to
					# reliably recieve a 1MB ARCHIVE.FSH file in FILESYS.
					# This sets it to 32M.
			}
			elsif ($this->{proto} eq 'mcast')
			{
				$sock = IO::Socket::Multicast->new(
					LocalPort => $this->{port},
					ReuseAddr => 1,
					Proto     => 'udp',
					ReuseAddr => 1,
					Timeout	  => $this->{CONNECT_TIMEOUT} );
				if ($sock && !$sock->mcast_add($this->{ip}))
				{
					error("Couldn't join multicast group: $!");
					$sock->close();
					$sock = undef;
				}
			}
			else
			{
				error("Illegal proto($this->{proto} in b_sock($this->{name}");
				last;
			}

			if ($sock)
			{
				$this->{connected} = 1;
				$this->{local_ip} = $sock->sockhost();
				$this->{local_port} = $sock->sockport();
				$this->{local} = "$this->{local_ip}:$this->{local_port}";
				display($dbg_thread,2,"$name $this->{local} CONNECTED to socket($this->{remote})");
				$sel = IO::Select->new($sock);
			}
			else
			{
				error("Could not connect to $this->{remote}: $!");
				last if $this->{EXIT_ON_CLOSE};
				display($dbg_thread+1,2,"will retry in $this->{RECONNECT_INTERVAL} seconds");
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
				if ($this->{show_raw_output})
				{
					my $header = "$name <-- ".pad(" len($pack_len)",9)." ";
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
					error("sockThread($this->{remote}) read error: $!");
					$sock = $this->_close_socket($sock);
					last if $this->{EXIT_ON_CLOSE};
				}
				elsif ($len == 0)
				{
					warning($dbg_thread,0,"received FIN.");
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
						if ($this->{show_raw_input})
						{
							my $header = "$name --> ".pad(" len($buflen)",9)." ";
							setConsoleColor($this->{in_color}) if $this->{in_color};
							print parse_dwords($header,$client_buffer,1);
							setConsoleColor() if $this->{in_color};
						}

						# hook for probes to not call derived handle packet

						if ($this->{probe_wait})
						{
							display(0,3,"probe WAIT completed");
							$this->{probe_wait} = 0;
						}
						else
						{
							my $reply = $this->handlePacket($client_buffer);
							display(0,0,"sockThread got handlePacket reply="._def($reply)) if $this->{in_color};
							push @{$this->{replies}},$reply if $reply;
						}
					}
					$this->{connect_time} = time();

				}	# got a buffer
			}	# can_read()
		}	# $sock
	}	# while 1


	display($dbg_thread,0,"exiting sockThread($name)");

	delete $r_socks{$this->{remote}};
	$this->{running} = 0;
	$this->{destroyed} = 1;
	$sock = $this->close_socket($sock) if $sock;

}


sub commandThread
{
	my ($this) = @_;
	display($dbg_cmd,0,"b_sock commandThread($this->{name}) started");
	if ($this->{DELAY_START})
	{
		display($dbg_thread,1,"DELAYING b_sock commandThread for $this->{DELAY_START} seconds");
		sleep($this->{DELAY_START});
	}

	while (!$this->{stopping} && !$this->{destroyed})
	{
		if (!$this->{stopping} &&
			$this->{connected} &&
			@{$this->{command_queue}})
		{
			my $command = shift @{$this->{command_queue}};
			display($dbg_cmd,0,"b_sock commandThread($this->{name}) starting command($command->{name})");

			# implicit knowledge of tcpProbe addon

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
				my $rslt = $this->handleCommand($command);
			}

			display($dbg_cmd,0,"b_sock commandThread($this->{name}) finished command($command->{name})");
		}
	}
	warning($dbg_cmd,0,"b_sock commandThread($this->{name}) exiting");
}




1;