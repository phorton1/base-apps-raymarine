#---------------------------------------------
# tcpListener.pm
#---------------------------------------------
# A package that can open a tcp port and
# send a script or series of commands to it
#
# Implements a tcp listener socket that can also
# 	replay previously captured debugging output.
# The sleeps are because s_sniffer takes a while to get
# 	the packets and it is possible for us to write after
# 	we have received the reply, but before sniffer got
# 	a chance to show the full reply.

package tcpListener;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Socket;
use IO::Select;
use Pub::Utils;
use r_utils;
use r_RAYSYS;




BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(
		startTcpListener
		startTcpProbe

		sendTCPMessage
		tcpNumberedProbe
		
    );
}

my $REPLY_TIMEOUT = 2;



my $PROBE_STATE_ERROR 	= -2;	# problem running the script
my $PROBE_STATE_DONE 	= -1;	# probe script finished
my $PROBE_STATE_NONE 	= 0;	# idle
my $PROBE_STATE_START 	= 1;	# start the probe script
my $PROBE_STATE_STOP 	= 2;	# stop the probe script
my $PROBE_STATE_RUNNING	= 3;	# probe script is running



my $next_tcp_port:shared = 11000;
	# something I can identify in traffic
my %listeners:shared;
	# key = $rayname
my $most_recent_listener:shared = shared_clone({});




sub stopTcpListener
{
	my ($ip,$port) = @_;
	my $rayport = findRayPort($ip,$port);
	my $rayname = $rayport ? $rayport->{name} : "UNKNOWN.$ip.$port)";
	display(0,0,"stopTcpListener($ip:$port) '$rayname'");
	my $this = $listeners{$rayname};
	return error("Could not find listener($rayname)") if !$this;
	return error("listener($rayname) is not running") if !$this->{running};
	return error("listener($rayname) already stopping($this->{stopping})") if $this->{stopping};
	$this->{stopping} = 1;
}



sub startTcpListener
{
	my ($class,$ip,$port) = @_;
	my $rayport = findRayPort($ip,$port);
	my $rayname = $rayport ? $rayport->{name} : "UNKNOWN.$ip.$port)";
	display(0,0,"startTcpListener($ip:$port) '$rayname'");

	my $this = shared_clone({
		ip			=> $ip,
		port		=> $port,
		rayname 	=> $rayname,
		running		=> 0,
		stopping	=> 0,
		seq			=> 1,
		error		=> '',
		state   	=> $PROBE_STATE_NONE,
		fileroot	=> lc($rayname), });
	bless $this,$class;
	$listeners{$rayname} = $this;
	$most_recent_listener = $this;
	my $tcp_thread = threads->create(\&tcpListenerThread,$this);
	display(0,1,"$rayname tcp_thread created");
	$tcp_thread->detach();
	display(0,1,"$rayname tcp_thread detached");
}


sub probeFilename
	# These files are basically monitoring output that is replayed to the port.
	# They are obtained by setting up to monitor  TCP ip:port, clearing rns.log,
	# and copying rns.log to "$data_dir/".lc($rayport->{name})."Probe.txt".
{
	my ($this) = @_;
	my $number = $this->{probe_number} || '';
	return "$data_dir/$this->{fileroot}"."Probe$number.txt";
}

sub probeStateName
{
	my ($state) = @_;
	return 'ERROR' 		if $state == $PROBE_STATE_ERROR;
	return 'NONE' 		if $state == $PROBE_STATE_NONE;
	return 'START' 		if $state == $PROBE_STATE_START;
	return 'STOP' 		if $state == $PROBE_STATE_STOP;
	return 'RUNNING'	if $state == $PROBE_STATE_RUNNING;
	return 'DONE' 		if $state == $PROBE_STATE_DONE;
	return 'UNKNOWN';
}

sub setProbeState
{
	my ($this,$state,$msg) = @_;
	$msg ||= '';
	display(0,0,sprintf("setProbeState(%s,%s) $msg",
		$this->{rayname},
		probeStateName($state)));
	$this->{state} = $state;
	if ($state == $PROBE_STATE_ERROR)
	{
		$msg ||= "probe error";
		$this->{error} = $msg;
		error("tcpProbe($this->{rayname} line($this->{line_num}): $msg");
 	}
}



sub tcpNumberedProbe
	# send a numbered probe to the most recent listener
{
	my ($number) = @_;
	my $listener = $most_recent_listener;
	display(0,0,"tcpNumberedProbe($listener->{rayname},$number)");
	$listener->{probe_number} = $number;
	startTcpProbe($listener->{rayname},1);
	$most_recent_listener
}



sub startTcpProbe
{
	my ($rayname,$start) = @_;
	display(0,0,"startTcpProbe($rayname,$start)");
	my $this = $listeners{$rayname};
	return error("Could not find listener($rayname)") if !$this;
	return error("listener($rayname) is not running") if !$this->{running};
	my $state = $this->{state};

	if ($start)
	{
		return error(sprintf("Probe already at state($state=%s",probeStateName($state))) if
			$state == $PROBE_STATE_START ||
			$state == $PROBE_STATE_STOP ||
			$state == $PROBE_STATE_RUNNING;
			
		my $filename = $this->probeFilename();
		return error("No probe file($filename)") if !-f $filename;
		my @lines = getTextLines($filename);
		return error("Empty probe file($filename)") if !@lines;
		display(0,1,"found ".scalar(@lines)." in $filename");

		$this->{filename} = $filename;
		# $this->{seq} = 0;
		$this->{lines} = shared_clone(\@lines);
		$this->{line_num} = 0;
		$this->{num_lines} = @lines;
	}
	else
	{
		return error(sprintf("Cannot stop at state($state=%s",probeStateName($state))) if
			$state == $PROBE_STATE_STOP ||
			$state != $PROBE_STATE_RUNNING;
	}
	
	my $new_state = $start ? $PROBE_STATE_START : $PROBE_STATE_STOP;
	$this->setProbeState($new_state);
}


#-----------------------------------------
# script handler
#-----------------------------------------

sub subSend
	# Send one packet parsed from a script (captured debug output)
{
	my ($sock,$seq,$template,) = @_;
	my $hex_seq = unpack('H*',pack('V',$seq));
	$template =~ s/\s+//g;
	$template =~ s/{seq}/$hex_seq/g;
	my $ok = $sock->send(pack('H*',$template));
	sleep(0.1) if length($template) <= 4;
	return $ok;
}


sub sendNextRequest
	# Continue parsing the script
	#
	# 	(a) get to the next line <-- to the given port
	#	(b) send that line as a packet
	#	(c) continue parsing and sending lines until
	#       you get to a --> from the port, or
	#		we run out of script
	#
	# Needs to be more robust to work with scripts that
	# have intermingled events, or output to/from other
	# ports. Currently works with docs/junk/rnsDatabaseStartup.txt
{

	my ($this,$sock) = @_;
	my $seq = $this->{seq}++;
	my $lines = $this->{lines};
	my $hex_seq = unpack('H*',pack('V',$seq));

	print "script($this->{line_num}/$this->{num_lines}) seq($seq)\n";

	# find next request start

	my $send_arrow = '<--';
	my $recv_arrow = '-->';

	my $started = 0;

	while (1)
	{
		my $line = shift @$lines || '';
		$this->{line_num}++;

		# echo outdented comments
		
		if ($line =~ /^#/)
		{
			print $line."\n";
			next;
		}

		# get rid of any other comments

		$line =~ s/#.*$//;

		my $arrow = '';

		$arrow = $1 if $line =~ s/.*?($send_arrow|$recv_arrow)\s+\d+\.\d+\.\d+\.\d+:\d+\s+//;

		# print "started($started) $arrow '$line'\n";

		return 1 if $arrow eq $recv_arrow && $started;
		if ($arrow eq $send_arrow)
		{
			$line =~ s/   .*$// if $line =~ /   .*$/;
			my @dwords = split(/\s+/,$line);
			print "line='$line\n";
			print "dwords(".scalar(@dwords).") = ".join(' ',@dwords)."\n";
			$dwords[1] = '{seq}' if @dwords > 2;
			my $new_line = join(' ',@dwords);
			# print "sending $new_line\n";
			my $ok = subSend($sock,$seq,$new_line);
			if (!$ok)
			{
				$this->setProbeState($PROBE_STATE_ERROR,"Could not send to $this->{port}:$this->{ip}\n$!");
				return 0;
			}
			$started = 1;
		}
		else
		{
			# print "skipping $arrow '$line'\n";
		}
		if (!@$lines)
		{
			$this->setProbeState($PROBE_STATE_DONE,"END OF SCRIPT1");
			return 0;
		}
	}
}



sub handleProbe
{
	my ($this,$sock,$sel) = @_;
	my $state = $this->{state};
	
	if ($state == $PROBE_STATE_STOP)
	{
		display(0,0,"stopping $this->{name} probe");
		$this->setProbeState($PROBE_STATE_NONE);
		return;
	}

	if ($state == $PROBE_STATE_START)
	{
		$this->setProbeState($PROBE_STATE_RUNNING);
	}

	# PROBE_STATE_RUNNING

	if (!@{$this->{lines}})
	{
		$this->setProbeState($PROBE_STATE_DONE,"END OF SCRIPT2");
		return;
	}

	my $continue = sendNextRequest($this,$sock);

	if ($continue)
	{
		my $reply = '';
		my $time = time();
		while (length($reply) <= 4)
		{
			if ($sel->can_read(2))
			{
				my $buf;
				recv($sock,$buf,4096,0);
				$reply .= $buf if $buf;
			}
			if (time() > $time + $REPLY_TIMEOUT)
			{
				warning(0,0,"probe($this->{rayname}) timeout at line($this->{line_num})");
				# $this->setProbeState($PROBE_STATE_ERROR,"Send Timeout");
				last;
			}
		}
	}
	sleep(0.2);
}


#-------------------------------------
# tcpListenerThread
#--------------------------------------
# keep alive for Database:
#	else
#	{
#		$sock->send(pack('H*','0400'));
#		$sock->send(pack('H*','00051000'));
#		sleep(2);
#	}

sub tcpListenerThread
	# Simply establishes a TCP connection (or fails) and listens.
	# Relies on s_sniffer to see the packets via tshark.
{
	my ($this) = @_;
	my $ip = $this->{ip};
	my $port = $this->{port};
	my $rayname = $this->{rayname};
	display(0,0,"tcpListenerThread($ip,$port) '$rayname' started");

	my $sock = IO::Socket::INET->new(
		LocalAddr => $LOCAL_IP,
		LocalPort => $next_tcp_port++,
		PeerAddr  => $ip,
		PeerPort  => $port,
		Proto     => 'tcp',
		Reuse	  => 1,	# allows open even if windows is timing it out
		Timeout	  => 3 );
	if (!$sock)
	{
		my $msg = "Could not open tcpListener($rayname) socket $ip:$port\n$!";
		$this->{error} = $msg;
		error($msg);
		return;
	}

	display(0,0,"tcpListener($rayname) started on $ip:$port");
	$this->{running} = 1;
	startTcpProbe($rayname,1) if $rayname eq 'Database';	# port 2050
	
	my $sel = IO::Select->new($sock);
	while ($this->{running})
	{
		if ($this->{stopping} == 1)
		{
			warning(0,0,"stopping==1 sending(FIN) shutdown()");
			$this->setProbeState($PROBE_STATE_NONE,"SHUTTING DOWN");
			$sock->shutdown(1);
			$this->{stop_time} = time();
			$this->{stopping} = 2;
		}
		elsif ($this->{stopping} == 2 &&
			   time() > $this->{stop_time} + 3)
		{
			warning(0,0,"stopping==2 timeout waiting for (FIN) shutdown()");
		}
		elsif ($this->{state} > 0)
		{
			$this->handleProbe($sock,$sel);
		}
		else
		{
			if ($sel->can_read(2))
			{
				my $buf;
				my $ok = recv($sock,$buf,4096,0);
				if (!defined($ok))
				{
					# connection closed by remote
					warning(0,0,"undef=socket error: $@");
					last;
				}
				elsif (length($buf) == 0)
				{
					warning(0,0,"received FIN. exiting loop");
					last;
				}
			}
		}
	}
	display(0,0,"tcpListener($rayname) ending on $ip:$port");
	$sock->close();
}



1;