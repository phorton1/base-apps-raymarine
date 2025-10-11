#---------------------------------------------
# tcpBase.pm
#---------------------------------------------
# The base class of a tcp socket handler.
#
#	my $obj = tcpBase->new($params);
#	$obj->start();
#	$obj->stop();
#
#--------------------------------------
# construcion $params
#--------------------------------------
#
#	{name} - optional, they are identified by ip:port
#	{remote_ip}
#	{remote_port}
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
#
# private:
#
#	{started}	= indicates that the thread has started
#	{running}	= indicates that the socket has been/is open
#   {stopping}	= indiates the the socket is in the process of closing
#	{connected} = indicatea the socket is currently connected
#
#	{stop_time}
#	{connect_time}
#	{out_queue}

#
#-----------------------------------------
# overidden class methods
#-----------------------------------------
#
#	$this->waitAddress() = set remote_ip and port and return
#	$this->sendPacket($packet) = queue the packet for async sending
#	$this->handlePacket($buffer)
#	$this->onIdle();
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
use r_utils qw(parse_dwords setConsoleColor);

my $dbg_tcp = -1;

my $STOP_TIMEOUT = 3;
my $DEFAULT_CONNECT_TIMEOUT = 2;
my $DEFAULT_RECONNECT_INTERVAL = 10;
my $DEFAULT_READ_TIME = 0.1;


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(
		findTcpBase
    );
}


my %tcp_bases:shared;
	# for objects with identified ip addresses
sub findTcpBase
{
	my ($ip,$port) = @_;
	return $tcp_bases{"$ip:$port"};
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
		# {remote_ip}
		# {remote_port}
		# {EXIT_ON_CLOSE}
		# {local_port} - optional
		# {local_ip} - optional but not recommended
		# {show_input}
		# {show_output}
		# {out_color}
		# {in_color}
	$this->{buffer} = '';
	$this->{connect_time} = 0;
	$this->{stop_time} = 0;
	$this->{out_queue} = shared_clone([]);
	return $this;
}


sub start
{
	my ($this) = @_;
	display(0,1,"tcpBase::start() called");
	return error("tcpBase already started") if $this->{started};
	$this->{started} = 1;
	my $thread = threads->create(\&tcpBase,$this);
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


sub waitAddress		{ my ($this) = @_; }
sub handlePacket	{ my ($this,$buffer) = @_; }
sub onIdle			{ my ($this) = @_; }


sub sendPacket
{
	my ($this,$buffer) = @_;
	return error("sendPacket() no connection to $this->{remote})")
		if (!$this->{connected});
	push @{$this->{out_queue}},$buffer;
}





sub _close_socket
{
	my ($this,$sock) = @_;
	display($dbg_tcp,0,"closing tcp socket($this->{remote})");
	$this->{buffer} = '';
	$this->{out_queue} = '';
	$this->{connected} = 0;
	$sock->close();
	return undef;

}


sub tcpBase
{
	my ($this) = @_;
	$dbg_tcp < -1 ?
		display_hash($dbg_tcp+1,0,"tcpBase() starting",$this) :
		display($dbg_tcp,0,"tcpBase("._def($this->{name}).") "._def($this->{remote_ip}).":"._def($this->{remote_port})." starting");

	$this->waitAddress() if !$this->{remote_ip} || !$this->{remote_port};
	if (!$this->{remote_ip} || !$this->{remote_port})
	{
		return error("tcpBase::waitAddress called, which means DEATH to the thread (implementation error)");
	}
	$this->{remote} = "$this->{remote_ip}:$this->{remote_port}";
	$this->{local} = _def($this->{local_ip}).":"._def($this->{local_port});
	$tcp_bases{$this->{remote}} = $this;

	$this->{running} = 1;

	my $sel;
	my $sock;
	display($dbg_tcp,0,"tcpBase($this->{remote}) running");
	while (1)
	{
		# handle client stopping
		
		if ($sock)
		{
			if ($this->{stopping} == 1)
			{
				display($dbg_tcp,1,"shutting down socket($this->{remote})");
				$sock->shutdown(1);	# prevent further writes (allow FIN to be read)
				$this->{stopping} = 2;
				$this->{stop_time} = time();
			}
			elsif ($this->{stopping} == 2 &&
				   time() > $this->{stop_time} + $STOP_TIMEOUT)
			{
				display($dbg_tcp+1,1,"socket($this->{remote}) shutdown timeout");
				$sock = $this->_close_socket($sock);
				last;
			}
		}

		# open the socket if appropriate

		elsif (!$this->{stopping} &&
				time() > $this->{connect_time} + $this->{RECONNECT_INTERVAL})
		{
			display($dbg_tcp,1,"connecting $this->{local} to socket($this->{remote})");
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
				display($dbg_tcp,1,"$this->{local} connected to socket($this->{remote})");
				$sel = IO::Select->new($sock);
			}
			else
			{
				error("Could not connect to $this->{remote}: $!");
				last if $this->{EXIT_ON_CLOSE};
				display($dbg_tcp+1,1,"will retry in $this->{RECONNECT_INTERVAL} seconds");
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
					my $header = pad($this->{remote},20)." <-- ".pad($this->{local},20).pad(" len($pack_len)",9)." ";
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
					error($dbg_tcp,0,"tcpBase($this->{remote}) read error: $!");
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
							my $header = pad($this->{remote},20)." --> ".pad($this->{local},20).pad(" len($buflen)",9)." ";
							setConsoleColor($this->{in_color}) if $this->{in_color};
							print parse_dwords($header,$client_buffer,1);
							setConsoleColor() if $this->{in_color};
						}
						$this->handlePacket($client_buffer);
					}
					$this->{connect_time} = time();

				}	# got a buffer
			}	# can_read()
		}	# $sock

		$this->onIdle($sock,$sel)
			if $sock &&
			   # synonym: $this->{connected} &&
			   !$this->{stopping};

	}	# while 1


	display($dbg_tcp,0,"exiting thread($this->{remote})");
	delete $tcp_bases{$this->{remote}};
	$this->{running} = 0;
	$sock = $this->close_socket($sock) if $sock;

}




1;