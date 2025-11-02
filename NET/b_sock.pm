#---------------------------------------------
# b_sock.pm
#---------------------------------------------
# WORK IN PROGRESS
#
#
# A service_port carries its monitoring preferences and may be
# promototed to a b_sock, still carrying those.
#
# There is a single a_parser associated with a b_sock, either
# the generic base class, or the derived IMPLEMENTED classes.
#
# In any case, the parser gets its monitoring prefs from
# its parent, THIS BSOCK.  Sniffer needs a major rework.



#-------------------------------------------------
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
# MONITORING is undocumented WIP
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
use a_defs;
use a_mon;
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


my $dbg_mon 	= 0;		# monitor bits

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


#------------------------------------------------------
# global single instance $LOCAL_UDP_SOCKET
#------------------------------------------------------
# The global $UDP_SEND_SOCKET is opened
# in the main thread at the outer perl
# level so-as to be available from threads
# PRH TODO - modernize and handle sendUDP failures
# in case command was interrupted by killAllJobs();


my $LOCAL_UDP_SOCKET = IO::Socket::INET->new(
        LocalAddr => $LOCAL_IP,
        LocalPort => $LOCAL_UDP_SEND_PORT,
        Proto     => 'udp',
        ReuseAddr => 1);
$LOCAL_UDP_SOCKET ?
	display(0,0,"LOCAL_UDP_SOCKET opened") :
	error("Could not open UDP_SEND_SOCKET");



sub wakeup_e80
	# needed to open multicast RAYSYS sockeet on Windows.
{
	if (!$LOCAL_UDP_SOCKET)
	{
		error("wakeup_e80() fail because UDP_SEND_SOCKET is not open");
		return;
	}
    for (my $i = 0; $i < 10; $i++)
    {
		display(0,1,"sending RAYDP_INIT_PACKET");
        $LOCAL_UDP_SOCKET->send($RAYSYS_WAKEUP_PACKET, 0, $RAYSYS_ADDR);
        sleep(0.001);
    }

	return 1;
}


my $dbg_udp_send = 1;



sub sendUDP
{
	my ($this,$name,$payload) = @_;
	my $dest_ip = $this->{ip};
	my $dest_port = $this->{port};
    display($dbg_udp_send, 1, "sending $dest_ip:$dest_port $name packet: " . unpack('H*', $payload));

	if (1)
	{
		if ($this->{is_probe})
		{
			printConsole(0,0,$UTILS_COLOR_WHITE,"$this->{name} --> $dest_ip:$dest_port $name");
			printConsole(0,0,parse_dwords(pad('',13),$payload,1));
		}
		else
		{
			my $packet = $this->make_packet(0,$payload);
			$this->{parser}->doParse($packet);
		}
	}

    if (!$LOCAL_UDP_SOCKET)
    {
        error("LOCAL_UDP_SOCKET not open in sendUDPPacket");
        return 0;
    }

    my $dest_addr = pack_sockaddr_in($dest_port, inet_aton($dest_ip));
    my $sent = $LOCAL_UDP_SOCKET->send($payload, 0, $dest_addr);

    if (!defined($sent))
    {
        error("send() failed for $dest_ip:$dest_port: $!");
        return 0;
    }

    return 1;
}





#------------------------------------------------------
# monitor definitions high priority
#------------------------------------------------------

sub setMonDefs
{
	my ($this,$packet) = @_;
	my $is_reply = $packet->{is_reply};
	my $mon = $is_reply ? $this->{mon_out} : $this->{mon_in};
	my $color = $is_reply ? $this->{out_color} : $this->{in_color};
	my $name = "p_$this->{name}";
	display($dbg_mon,0,sprintf("b_sock::setMonDefs($name) mon(%04x) color($color)",$mon));
	$packet->{name} = $name;
	$packet->{mon} = $mon;
	$packet->{color} = $color;
}


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

	my $parser_class = $this->{parser_class} || 'a_parser';
	$this->{parser} = $parser_class->newParser($this->{mon_defs}) if !$this->{parser};

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

		wait_seq
		wait_name
		
		parser

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



#----------------------------------
# virtual overrides
#----------------------------------

sub handleCommand
{
	my ($this,$command) = @_;
	return 0;	# return value not used yet
}

sub handleEvent
{
	my ($this,$reply) = @_;
	return $reply;
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

	display($dbg_wait+1,0,"$name waitReply($seq) $wait_name");

	while ($this->{connected} &&
		   $this->{running} &&
		   !$this->{shutdown} &&
		   !$this->{destroyed})
	{
		my $replies = $this->{replies};
		if (@$replies)
		{
			my $reply = shift @$replies;
			if ($reply)
			{
				$dbg_wait >= 0 ?
					display($dbg_wait+1,1,"$this->{name} waitReply got seq($reply->{seq_num})") :
					display_hash($dbg_wait+1,1,"$this->{name} waitReply got seq($reply->{seq_num})",$reply,'payload');

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
			else
			{
				warning($dbg_wait,"$this->{name} empty reply in waitReply: "._def($reply));
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

sub make_packet
{
	my ($this,$is_reply,$payload) = @_;
	my $packet = shared_clone({
		is_reply 	=> $is_reply,
		is_sniffer	=> 0,
		is_shark	=> 1,
		client_name => "$this->{name}(shark)",
		server_name => "$this->{name}($this->{device_id})",

		proto		=> $this->{proto},

		src_ip		=> $this->{local_ip},
		src_port	=> $this->{local_port},
		dst_ip		=> $this->{ip},
		dst_port	=> $this->{port},

		client_ip	=> $this->{local_ip},
		client_port	=> $this->{local_port},
		server_ip	=> $this->{ip},
		server_port => $this->{port},

		payload 	=> $payload,
	});
	return $packet;
}


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
				my $payload = shift @{$this->{out_queue}};
				my $packet = $this->make_packet(0,$payload);
				$this->{parser}->doParse($packet);

				my $rslt = $this->{proto} eq 'mcast' ?
					$sock->mcast_send($payload, "$this->{ip}:$this->{port}") :
					$sock->send($payload);
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

						my $packet = $this->make_packet(1,$client_buffer);
						my $reply =	$this->{parser}->doParse($packet);
						display($dbg_thread+1,0,"sockThread got parsePacket reply="._def($reply))
							if $this->{name} ne 'RAYSYS';
						if ($this->{is_probe})
						{
							$this->{probe_wait} = 0;
						}
						else
						{
							$reply = $this->handleEvent($reply);
								# derived classes that handle events (WPMGR, TRACK) should
								# define handleEvent methods on reply packets, and return
								# the packet, or undef if it is completely handled.
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
	display($dbg_thread,0,"b_sock commandThread($this->{name}) started");
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
	warning($dbg_thread,0,"b_sock commandThread($this->{name}) exiting");
}




1;