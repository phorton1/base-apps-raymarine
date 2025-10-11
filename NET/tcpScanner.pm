#---------------------------------------------
# tcpPortScanner.pm
#---------------------------------------------
# An object for scanning tcpPorts at a given IP address

package tcpScanner;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Socket;
use IO::Select;
use Pub::Utils;
# use r_utils;	was used for uneeded $LOCAL_IP

# temporary implementation
# Try to find the last two unmapped TCP client in Raymarine Services Menu

my $TARGET_IP = "10.0.241.54";
	# $E80_1_IP

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

		scanRange
		showAliveScans

    );
}

my $MAX_SCANS  = 10;
my $MIN_PORT    = 23;
my $MAX_PORT	= 32768;

my $num_scanning:shared = 0;
my $num_unscanned:shared = 0;
my $master_started:shared = 0;
my %scans:shared;
my $next_local_port:shared = 12000;

if (0)
{
	$scans{5082} = 1;
	for my $num (2048 .. 2055)
	{
		$scans{$num} = 1;
	}
}


sub showAliveScans
{
	display(0,0,"The following ports are alive");
	my $num_alive = 0;
	for my $port (sort keys %scans)
	{
		my $exists = $scans{$port} || 0;
		if ($exists > 0)
		{
			display(0,1,"PORT($port) is ALIVE!");
			$num_alive++;
		}
	}
	display(0,1,"There are $num_alive alive ports");
}



sub scanRange
{
	my ($low,$high) = @_;
	$low ||= 0;
	$high ||= $low;
	display(0,0,"scanRange($low,$high)");
	return error("low must be specified") if !$low;
	return error("low must be > $MIN_PORT") if $low<$MIN_PORT;
	return error("low and high must <= $MAX_PORT")
		if $low > $MAX_PORT || $high > $MAX_PORT;
	return error("low($low) must be >= high($high)")
		if $high < $low;

	my $num_new = 0;
	for my $port ($low..$high)
	{
		my $exists = $scans{$port};
		next if defined($exists);
		$num_new++;
		$scans{$port} = 0;
	}

	return warning(0,0,"NO NEW PORTS ADDED TO PROBE RANGE")
		if !$num_new;
	display(0,1,"added $num_new ports to probe range");
	$num_unscanned += $num_new;

	# start the scanMasterThread if !started

	if (!$master_started)
	{
		display(0,1,"creating scanMasterThread");
		my $master_thread = threads->create(\&scanMasterThread);
		display(0,1,"detatching master_thread");
		$master_thread->detach();
		display(0,1,"master_thread detached");
		$master_started = 1;
	}
	else
	{
		display(0,1,"scanMasterThread already running");
	}
}


sub scanMasterThread
{
	display(0,0,"scanMasterThread started");
	while (1)
	{
		while ($num_unscanned>0 && $num_scanning < $MAX_SCANS)
		{
			for my $port (sort keys %scans)
			{
				my $scan = $scans{$port};
				if ($scan == 0)
				{
					$num_unscanned--;
					$num_scanning++;

					display(0,1,"scanMasterThread creating scanThread($port)");
					my $thread = threads->create(\&scanThread,$port);
					display(1,1,"detatching thread");
					$thread->detach();
					display(1,1,"thread detached");
				}
			}
		}
		sleep(0.1);
	}
}


sub scanThread
{
	my ($port) = @_;
	my $local_port = $next_local_port++;
	display(0,0,"scanThread($port) started with local_port($local_port)");

	my $sock = IO::Socket::INET->new(
		# LocalAddr => $LOCAL_IP,
		LocalPort => $local_port++,
		PeerAddr  => $TARGET_IP,
		PeerPort  => $port,
		Proto     => 'tcp',
		Reuse	  => 1,	# allows open even if windows is timing it out
		Timeout	  => 2 );

	if (!$sock)
	{
		error("Could not connect to remote port($port)");
		$scans{$port} = -1;
		$num_scanning--;
		return;
	}
	$scans{$port} = 1;
	$num_scanning--;
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

	warning(0,1,"scanThread($port) ending");
	$sock->close();
}



1;