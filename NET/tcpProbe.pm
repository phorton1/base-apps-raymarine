#---------------------------------------------
# tcpProbe.pm
#---------------------------------------------

package tcpProbe;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Socket;
use IO::Select;
use Pub::Utils;
use r_utils;

# temporary implementation
# Try to find the last two unmap TCP client in Raymarine Services Menu

my $E80_1_IP = "10.0.241.54";

# known E80, or previously probed ports
#
#	2048-2055
#   5802
#
# used as mcast ports with explicit mcas address
# and so, are, to me, unlikely candidates
#
#	2560-2563
#	5800,5801
#
# Due to (likely) limitation on number of simultaneous perl threads
# and/or handles, this method is limited to probing 32 sockets at a time


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(
		create

		probeRange
		showAlive

    );
}

my $MAX_PROBES  = 10;
my $MIN_PORT    = 23;
my $MAX_PORT	= 32768;

my $num_probing:shared = 0;
my $num_unprobed:shared = 0;
my $master_started:shared = 0;
my %probes:shared;
my $next_local_port:shared = 12000;

if (0)
{
	$probes{5082} = 1;
	for my $num (2048 .. 2055)
	{
		$probes{$num} = 1;
	}
}


sub showAlive
{
	display(0,0,"The following ports are alive");
	my $num_alive = 0;
	for my $port (sort keys %probes)
	{
		my $exists = $probes{$port} || 0;
		if ($exists > 0)
		{
			display(0,1,"PORT($port) is ALIVE!");
			$num_alive++;
		}
	}
	display(0,1,"There are $num_alive alive ports");
}



sub probeRange
{
	my ($low,$high) = @_;
	$low ||= 0;
	$high ||= $low;
	display(0,0,"probeRange($low,$high)");
	return error("low must be specified") if !$low;
	return error("low must be > $MIN_PORT") if $low<$MIN_PORT;
	return error("low and high must <= $MAX_PORT")
		if $low > $MAX_PORT || $high > $MAX_PORT;
	return error("low($low) must be >= high($high)")
		if $high < $low;

	my $num_new = 0;
	for my $port ($low..$high)
	{
		my $exists = $probes{$port};
		next if defined($exists);
		$num_new++;
		$probes{$port} = 0;
	}

	return warning(0,0,"NO NEW PORTS ADDED TO PROBE RANGE")
		if !$num_new;
	display(0,1,"added $num_new ports to probe range");
	$num_unprobed += $num_new;

	# start the probeMasterThread if !started

	if (!$master_started)
	{
		display(0,1,"creating masterProbeThread");
		my $master_thread = threads->create(\&masterProbeThread);
		display(0,1,"detatching master_thread");
		$master_thread->detach();
		display(0,1,"master_thread detached");
		$master_started = 1;
	}
	else
	{
		display(0,1,"masterProbeThread already running");
	}
}


sub masterProbeThread
{
	display(0,0,"masterProbeThread started");
	while (1)
	{
		while ($num_unprobed>0 && $num_probing < $MAX_PROBES)
		{
			for my $port (sort keys %probes)
			{
				my $probe = $probes{$port};
				if ($probe == 0)
				{
					$num_unprobed--;
					$num_probing++;

					display(0,1,"masterProbeThread creating probeThread($port)");
					my $probe_thread= threads->create(\&probeThread,$port);
					display(0,1,"detatching probe_thread");
					$probe_thread->detach();
					display(0,1,"probe_thread detached");
				}
			}
		}
		sleep(0.1);
	}
}


sub probeThread
{
	my ($port) = @_;
	my $local_port = $next_local_port++;
	display(0,0,"probeThread($port) started with local_port($local_port)");

	my $sock = IO::Socket::INET->new(
		LocalAddr => $LOCAL_IP,
		LocalPort => $local_port++,
		PeerAddr  => $E80_1_IP,
		PeerPort  => $port,
		Proto     => 'tcp',
		Reuse	  => 1,	# allows open even if windows is timing it out
		Timeout	  => 2 );

	if (!$sock)
	{
		error("Could not connect to remote port($port)");
		$probes{$port} = -1;
		$num_probing--;
		return;
	}
	$probes{$port} = 1;
	$num_probing--;
	display(0,1,"CONNECTED TO remote port($port) !!!",0,$UTILS_COLOR_LIGHT_GREEN);

	# keep the thread alive, monitoring traffic
	# until the remote closes it

	my $msg_time = time();
	my $sel = IO::Select->new($sock);
	while (1)
	{
		if ($sel->can_read(2))
		{
			my $buf;
			my $ok = recv($sock,$buf,4096,0);
			if (!defined($ok))
			{
				# connection closed by remote
				warning(0,0,"remote port($port) undef=socket error: $@");
				last;
			}
			elsif (length($buf) == 0)
			{
				warning(0,0,"received FIN. exiting loop");
				last;
			}
			else
			{
				$msg_time = time();
				my $header = "remote($port) --> ";
				print parse_dwords($header,$buf,1);
			}
		}
		if (time() > $msg_time + 10)
		{
			$msg_time = time();
			display(0,0,"remote port($port) alive",0,$UTILS_COLOR_LIGHT_CYAN);
		}
	}

	warning(0,1,"probeThread($port) ending");
	$sock->close();
}



1;