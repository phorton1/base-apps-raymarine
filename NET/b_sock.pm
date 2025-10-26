#---------------------------------------------
# b_sock.pm
#---------------------------------------------
# The base class of a RAYNET socket.
# Sockets are constructed with the following parameters:
#
#	{name} 			REQUIRED
#		a name that is passed in for identification and
#		debugging, that follows my capitalization scheme,
#		and which is used to find the ip:port if
#		they are not passed in during construction.
#	{proto} 		REQUIRED
#		'tcp', 'udp', or 'mcast'
#	{service_id} 	REQUIRED
#		The 'service id' of a RAYNET service, for identification
#		and debugging, which may be -1 indicating that the RAYNET
#		service_id has not yet have been identified.
#
# The connection addresses are treated differently depending on {proto}.
# IP:PORT are the Advertised service_port addresses gotten by c_RAYSYS
#
# 	{ip}:{port}
#		TCP: 		the remote tcp peer ip:port to connect to
#		MCAST:		the local ip:port (multicast group and port) to open
#		UDP:		unused by this code; client code uses remote {ip}:{port}
#			    	to send request to
#
#	{local_ip}		will be (re) set to whatever the socket returns after open
#		TCP: 		optional, may be the specific adapter ip on this machine or left undef
#		MCAST:  	optional, may be the specific adapter ip on this machine or left undef
#		MCAST:  	optional, may be the specific adapter ip on this machine or left undef
#
#	{local_port}	will be (re) set to whatever the socket returns after open
#						which *may* be important for monitoring tcp connections
#		TCP:		not used. if it was used, Windows enforces a 60+ second TIME_WAIT
#						between reconnects which I found unacceptable
#		MCAST:		not used. The LocalAddr is set to the advertised IP
#		UDP:		may be (probably *should* be) specified as a constant per
#					service_port for easier monitoring
#
# Optional:
#
#	{DELAY_START}
#		puts a sleep at the top of sockThread and commandThread
#		used to delay starting RAYSYS and implemented services
#       until the E80 has settled down
#	{EXIT_ON_CLOSE}
#		if this is passed in, a failure to open the tcp
#		socket, or a failure reading from or writing to
#		the socket, will cause the threada to exit
#
# Monitoring used at this level are passed in from a_defs.pm
#
#	{in_color}
#	{out_color}
#	{show_raw_in}
#	{show_raw_ou}
#	{in_multi}
#	{out_multi}
#
# And are passed (along with the protocol) to a_utils::parseRawPacket
#
# All sockets implement a listener thread that waits for incoming
# packets and a commandThread that acts on the {command_queue} if
# there are any elements in it.
#
# THIS CLASS COMBINES received tcp packets until their
# length is greater than 2 (i.e. until a full Reply is received),
# before further processing.
#
# if !WITH_EXIT_ON_CLOSE this class handles loss of tcp connections
# as identified by results to $sock->send() and $sock->receive() and
# attempts reconnections after a specific interval of time.


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

BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		$SHUTDOWN_NONE
		$SHUTDOWN_START
		$SHUTDOWN_SENT
		$SHUTDOWN_DONE

		@SHUTDOWN_NAME
	);
}



my $dbg_api 	= 1;
my $dbg_thread  = 0;
my $dbg_cmd  	= 1;
my $dbg_wait 	= 1;

my $DESTROY_TIMEOUT				= 3;
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


my $SHUTDOWN_TIMEOUT 	= 2;		# How long to wait for FIN after shutdown(1)

our $SHUTDOWN_NONE 		= 0;		# attempt reconnections after timeout or hard close socket on destruction
our $SHUTDOWN_START 	= 1;		# start disconnection cycle
our $SHUTDOWN_SENT		= 2;		# $sock->shutdown(1) has been sent; waiting for FIN or timeout
our $SHUTDOWN_DONE		= 3;		# socket has been closed,

our @SHUTDOWN_NAME = qw(NONE START SENT DONE);


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

	$this->{created}			= 1;
    $this->{started}   			= 0;
	$this->{running}			= 0;
    $this->{connected} 			= 0;
    $this->{destroyed} 			= 0;
	$this->{shutdown}			= 0;
		# this is a command that carries state
		# 0 = don't change connection state
		# 1 = connect subject to reconnect time (normal)
		# 2 = connect immediately (goes to 1)

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
	display($dbg_api,0,"b_sock destroy($this->{name}) called",0,$UTILS_COLOR_BROWN);

	if ($this->{started} && !$this->{destroyed})
	{
		display($dbg_api,1,"b_sock destroy($this->{name}) stopping threads",0,$UTILS_COLOR_BROWN);
		$this->{running} = 0;
			# object is being destroyed.
			# exit loop post-hasted
		my $start_destroy = time();
		while (!$this->{destroyed} &&
			   time() - $start_destroy < $DESTROY_TIMEOUT)
		{
			sleep 0.1;
		}
		$this->{destroyed} ?
			display($dbg_api,1,"b_sock destroy($this->{name}) threads destroyed",0,$UTILS_COLOR_BROWN) :
			error("timeout in b_sock destroy($this->{name})");
	}

    delete @$this{qw(
		created
        started
		running
		connected
		shutdown
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
		shutdown
		
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
	display($dbg_api,0,"b_sock destroy($this->{name}) returning",0,$UTILS_COLOR_BROWN);
}



sub start
{
	my ($this) = @_;
	display($dbg_api,1,"b_sock start($this->{name}) called");
	# return error("start($this->{name}) already created") if $this->{created};
	return error("start($this->{name}) already started") if $this->{started};
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



sub connect
	# This method is not appropriate for EXIT_ON_CLOSE sockets
	# 1 = connect immediately
	# 0 = disconnect with shutdown cycle
{
	my ($this,$connect) = @_;
	warning($dbg_cmd,1,"b_sock connect($this->{name},$connect=".($connect?"CONNECT":"DISCONNECT").")");
	return error("connect($this->{name}) not started") if !$this->{started};
	return error("connect($this->{name}) is not running") if !$this->{running};
	return error("connect($this->{name}) has been destroyed") if $this->{destroyed};

	if ($connect)
	{
		return error("connect($this->{name}) already connected") if $this->{connected};
		return error("connect($this->{name}) is in shutdown state($this->{shutdown})")
			if $this->{shutdown} && $this->{shutdown} != $SHUTDOWN_DONE;
		$this->{shutdown} = $SHUTDOWN_NONE;
		$this->{connect_time} = -$this->{RECONNECT_INTERVAL};
	}
	else
	{
		return error("connect($this->{name}) not connected") if !$this->{connected};
		return error("connect($this->{name}) is in shutdown state($this->{shutdown})")
			if $this->{shutdown};
		$this->{shutdown} = $SHUTDOWN_START;
	}
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
	# called when thread is started
	# allows c_RAYSYS to send wakeup packets
{
	my ($this) = @_;
}


sub onConnect
	# called upon a connection
	# allows d_WPMGR and d_TRACK to queue populate commands
{
	my ($this) = @_;
}


sub onIdle
	# called from commandThread when no commands in queue
	# allows c_RAYSYS to cull unadvertised service_port timeouts
{
	my ($this) = @_;
}


#------------------------------------------------
# derived client API
#------------------------------------------------

sub getVersion
	# for treating the entirety of shark
	# as a single versioned 'database'
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
	return error("sendPacket($this->{name}) is not running") if !$this->{running};
	return error("sendPacket($this->{name}) no connection") if !$this->{connected};
	return error("sendPacket($this->{name}) is in shutdown state($this->{shutdown})") if $this->{shutdown};
	return error("sendPacket($this->{name}) has been destroyed") if $this->{destroyed};
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
		   $this->{running} &&
		   !$this->{shutdown} &&
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
		}
		if (time() > $start + $this->{COMMAND_TIMEOUT})
		{
			error("$name Command($seq,$wait_name) timed out");
			return '';
		}
		sleep(0.01);
	}

	return error("waitReply($seq) died");
}



#======================================================================================
# sockThread
#======================================================================================
use Devel::Peek;


sub _shutdown_socket
{
	my ($this,$psock,$psel) = @_;
	lock($this);
	my $shutdown = $this->{shutdown};
	display($dbg_thread,0,"shutting down tcp socket($this->{name}) shutdown($shutdown=$SHUTDOWN_NAME[$shutdown]) sock=$$psock sel=".($psel?$$psel:'undef'));
	if ($this->{connected})
	{
		display($dbg_thread,0,"clearing connection members");
		$this->{buffer} = '';
		$this->{out_queue} = shared_clone([]) if !@{$this->{out_queue}};
		$this->{connected} = 0;
	}
	if ($this->{shutdown} == $SHUTDOWN_START)
	{
		$this->{shutdown} = $SHUTDOWN_SENT;
		$$psock->shutdown(1);		# disable further sends
		display($dbg_thread,1,"_shutdown_socket short return");
		return;
	}
	if ($this->{shutdown} == $SHUTDOWN_SENT)
	{
		$$psock->shutdown(2);
		$this->{shutdown} = $SHUTDOWN_DONE;
		sleep(0.5);
	}

	setsockopt($$psock, SOL_SOCKET, SO_LINGER, pack("II", 1, 0));  # Linger active, timeout 0

	$$psock->close();
	$$psock = undef;
	$$psel = undef;
	display($dbg_thread,1,"_shutdown_socket closed socket")
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
	while ($this->{running})
	{
		# (a) OPEN THE SOCKET if appropriate

		if (!$sock &&
			$this->{running} &&
			!$this->{shutdown} &&
			time() > $this->{connect_time} + $this->{RECONNECT_INTERVAL})
		{
			display($dbg_thread,1,"connecting $this->{proto} $name($this->{local}) to socket($this->{remote})");

			if ($this->{proto} eq 'tcp')
			{
				$sock = IO::Socket::INET->new(
					LocalAddr => $this->{local_ip},
					# LocalPort => $this->{local_port},
					PeerAddr  => $this->{ip},
					PeerPort  => $this->{port},
					Proto     => $this->{proto},
					ReuseAddr => 1,	# allows open even if windows is timing it out
					Timeout	  => $this->{CONNECT_TIMEOUT} );
			}
			elsif ($this->{proto} eq 'udp')
			{
				# udp service ports merely open a listener
				# and do not use the base class sendPacket method
				
				$sock = IO::Socket::INET->new(
					LocalAddr => $this->{local_ip},
					LocalPort => $this->{local_port},
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
					LocalHost => $this->{local_ip},
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
				$this->onConnect();
			}
			else
			{
				error("Could not connect to $this->{remote}: $!");
				last if $this->{EXIT_ON_CLOSE};
				display($dbg_thread+1,2,"will retry in $this->{RECONNECT_INTERVAL} seconds");
			}
			$this->{connect_time} = time();

		}	# !$sock && running and connect_time>RECONNECT_INTERVAL


		# (b) SEND THE NEXT OUT BOUND PACKET if any

		if ($sock &&
			$this->{running} &&
			$this->{connected} &&
			!$this->{shutdown})
		{
			if ($sel->can_write() && @{$this->{out_queue}})
			{
				my $packet = shift @{$this->{out_queue}};
				showRawPacket(0,$this,$packet,1) if $this->{mon_raw_out};

				my $rslt = $this->{proto} eq 'mcast' ?
					$sock->mcast_send($packet, "$this->{ip}:$this->{port}") :
					$sock->send($packet);
				if (!defined($rslt))
				{
					error("Could not write to $this->{remote}: $!");
					$this->_shutdown_socket(\$sock,\$sel);
					last if $this->{EXIT_ON_CLOSE};
				}
				$this->{connect_time} = time();
			}
		}

		# (c) READ THE SOCKET

		if ($sock &&
			$this->{running} &&
			$this->{shutdown} != $SHUTDOWN_DONE)
		{
			# handle SHUTDOWN_START pre-read
			
			if ($this->{shutdown} == $SHUTDOWN_START)
			{
				# $sock= not needed as this will merely call shutdown(1)
				$this->_shutdown_socket(\$sock,\$sel);
			}

			if ($sock && $sel->can_read($this->{READ_TIME}))
			{
				my $buf;
				my $rslt = recv($sock,$buf,4096,0);
				my $len = length($buf);
				if (!defined($rslt))
				{
					# connection closed by remote
					error("sockThread($this->{remote}) read error: $!");
					$this->_shutdown_socket(\$sock,\$sel);
					last if $this->{EXIT_ON_CLOSE};
				}
				elsif ($len == 0)
				{
					warning($dbg_thread,0,"received FIN.");
					$this->_shutdown_socket(\$sock,\$sel);
					last if $this->{EXIT_ON_CLOSE};
				}
				elsif ($this->{running} && $this->{connected})
				{
					# my ($port, $ip) = sockaddr_in($rslt);
					# my $sender_ip = inet_ntoa($ip);
					# print "ip:addr=$sender_ip:$port\n";

					$this->{buffer} .= $buf;
					my $buflen = length($this->{buffer});
					if ($buflen > 2)
					{
						my $client_buffer = $this->{buffer};
						$this->{buffer} = '';
						showRawPacket(0,$this,$client_buffer,0) if $this->{mon_raw_in};

						# hook for probes to not call derived handle packet

						if ($this->{probe_wait})
						{
							display(0,3,"probe WAIT completed");
							$this->{probe_wait} = 0;
						}
						else
						{
							my $reply = $this->handlePacket($client_buffer);
							display($dbg_thread+1,0,"sockThread got handlePacket reply="._def($reply)) if $this->{in_color};
							push @{$this->{replies}},$reply if $reply;
						}
					}
				}	# got a buffer

				$this->{connect_time} = time();

			}	# can_read()

			# handle shutdown timeout POST read

			if ($this->{shutdown} == $SHUTDOWN_SENT &&
				time() > $this->{connect_time} + $SHUTDOWN_TIMEOUT)
			{
				display($dbg_thread+1,"NOTE: $this->{name} SHUTDOWN_TIMEOUT",0,$UTILS_COLOR_RED);
				$this->_shutdown_socket(\$sock,\$sel);
			}

		}	# $sock
	}	# while 1


	display($dbg_thread,1,"finishing sockThread($name)");

	$sock->close() if $sock;
	delete $r_socks{$this->{remote}};
	$this->{running} = 0;
	$this->{destroyed} = 1;

	warning($dbg_thread,0,"exiting sockThread($name)");
}



#===============================================
# commandThread
#===============================================

sub commandThread
{
	my ($this) = @_;
	display($dbg_cmd,0,"b_sock commandThread($this->{name}) started");
	if ($this->{DELAY_START})
	{
		display($dbg_thread,1,"DELAYING b_sock commandThread for $this->{DELAY_START} seconds");
		sleep($this->{DELAY_START});
	}

	while ($this->{running} &&
		   !$this->{destroyed})
	{
		if ($this->{running} &&
			$this->{connected} &&
			!$this->{shutdown} &&
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
		else
		{
			$this->onIdle();
			sleep(0.01);
		}
	}
	warning($dbg_cmd,0,"b_sock commandThread($this->{name}) exiting");
}




1;