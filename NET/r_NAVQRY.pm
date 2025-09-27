#---------------------------------------------
# r_NAVQRY.pm
#---------------------------------------------
# There is a conflict between a completely self contained
# WGR listener, and a tool to explore and learn how to do
# things (i.e. write waypoints).  In the first case we need
# to send out carefully constructed sequennces of messags,
# and then parse expected replies, with error checking, etc.
# In the second case it is interesting to send various messages,
# sometimes alone or sometimes in groups, and see what comes
# back, if anything.
#
# The code currently implements the former with some display
# support for the latter.
#
# See notes in the readme about problems I had with closing
# the TCP socket to a running E80.

package r_NAVQRY;
use strict;
use warnings;
use threads;
use threads::shared;
use POSIX qw(floor pow atan);
use Socket;
use IO::Select;
use IO::Handle;
use IO::Socket::INET;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use r_utils;
use r_RAYDP;

my $dbg = -2;

my $SHOW_OUTPUT = 0;
my $SHOW_INPUT = 0;
my $PARSE_STUFF = 0;

my $COMMAND_TIMEOUT 		= 3;
my $REFRESH_INTERVAL		= 5;
my $RECONNECT_INTERVAL		= 15;

my $STATE_NONE 				= 0;
my $STATE_GET_WP_DICT 		= 1;
my $STATE_PARSE_WP_DICT 	= 2;
my $STATE_GET_WAYPOINTS		= 3;
my $STATE_GET_ROUTE_DICT	= 4;
my $STATE_PARSE_ROUTE_DICT	= 5;
my $STATE_GET_ROUTES		= 6;
my $STATE_GET_GROUP_DICT	= 7;
my $STATE_PARSE_GROUP_DICT	= 8;
my $STATE_GET_GROUPS		= 9;

my $SUCCESS_SIG = '00000400';
my $DICT_END_RECORD_MARKER	= '10000202';


BEGIN
{
 	use Exporter qw( import );
    our @EXPORT = qw(

		navQueryThread

		startNavQuery
		refreshNavQuery
		toggleNavQueryAutoRefresh
    );
}


my $one_time_start:shared = 0;
	# set this to 0 to require startNavQuery() to
	# be called to start the thread.
my $refresh_time:shared = 0;
	# time of the last refresh; 0=immediate-ish
my $auto_refresh:shared = 0;
	# set this to 0 to require refreshNavQuery
	# or toggleNavQueryAutoRefres() to be called.
my $refresh_now:shared = 0;

my $waypoints:shared = shared_clone({});
my $routes:shared = shared_clone({});
my $groups:shared = shared_clone({});
my $state:shared = $STATE_NONE;

# constant command atoms

my $CONTEXT 	= '0800'.	'{sig_byte}001'.'0f00'.'{seq_num}';
my $SET_CONTEXT = '1400'.	'0002'.'0f00'.'{seq_num}'.	'00000000'.'00000000'.'1a000000';
my $SET_BUFFER 	= '3400'.	'0102'.'0f00'.'{seq_num}'.	'28000000'.('00000000'x5).'10270000'.('00000000'x4);
my $DICTIONARY 	= '1000'.	'0202'.'0f00'.'{seq_num}'.	'00000000'.'00000000';

my $GET_DICT 	= $CONTEXT.$SET_CONTEXT.$SET_BUFFER.$DICTIONARY;
my $GET_ITEM	= '1000'.	'{sig_byte}301'.'0f00'.'{seq_num}'.'{uuid}';

my $SIG_DICT	= '{sig_byte}0000f00{seq_num}';
my $SIG_ITEM	= '{sig_byte}6000f00{seq_num}';


# implementation vars

my $sel;
my $sock;
my $nav_ip;
my $nav_port;

my $running = 0;
my $started = 1;
my $next_seqnum = 1;
my $watch_sig = '';


my $command_time = 0;
my $reconnect_time = 0;
my $declared_len;



#----------------------------------
# public API
#----------------------------------

sub startNavQuery
{
	display(0,0,"startNavQuery()");
	$one_time_start = 1;
}

sub refreshNavQuery
{
	if ($state || !$one_time_start)
	{
		error("illegal attempt to refreshNavQuery: state($state) started($one_time_start)");
		return;
	}
	display(0,0,"refreshNavQuery()");
	$refresh_now = 1;
	$refresh_time = 0;
}

sub toggleNavQueryAutoRefresh
{
	my $auto = $auto_refresh ? 0 : 1;
	display(0,0,"toggleNavQueryAutoRefresh($auto)");
	$refresh_time = time() if $auto && !$state;
	$auto_refresh = $auto;
}



#-------------------------------------------
# implementation
#-------------------------------------------

sub kind
{
	my ($sig_byte) = @_;
	return
		$sig_byte eq '8' ? 'GROUP' :
		$sig_byte eq '4' ? 'ROUTE' :
		$sig_byte eq 'b' ? 'DATABASE?' :'WP';
}


sub substitute
{
	my ($text,$sig_byte,$seq_num,$uuid,) = @_;
	my $seq_packed = pack('V',$seq_num);
	my $seq_hex = unpack('H*',$seq_packed);
	$text =~ s/{sig_byte}/$sig_byte/g;
	$text =~ s/{seq_num}/$seq_hex/g;
	$text =~ s/{uuid}/$uuid/g;
	return $text;
}


sub setState
{
	my ($new_state) = @_;
	return if $state == $new_state;
	$state = $new_state;
	my $text =
		$state == $STATE_NONE 				? 'NONE' :
		$state == $STATE_GET_WP_DICT 		? 'GET_WP_DICT' :
		$state == $STATE_PARSE_WP_DICT 		? 'PARSE_WP_DICT' :
		$state == $STATE_GET_WAYPOINTS		? 'GET_WAYPOINTS' :
		$state == $STATE_GET_ROUTE_DICT		? 'GET_ROUTE_DICT' :
		$state == $STATE_PARSE_ROUTE_DICT	? 'PARSE_ROUTE_DICT' :
		$state == $STATE_GET_ROUTES			? 'GET_ROUTES' :
		$state == $STATE_GET_GROUP_DICT		? 'GET_GROUP_DICT' :
		$state == $STATE_PARSE_GROUP_DICT	? 'PARSE_GROUP_DICT' :
		$state == $STATE_GET_GROUPS			? 'GET_GROUPS' :
		'UNKNOWN';
	display($dbg,-1,"setState($state) $text");
}


sub sendCommand
{
	my ($template,$sig_byte,$seq_num,$uuid) = @_;
	if (!$sel->can_write())
	{
		error("Cannot write to socket");
		return 0;
	}
	my $command = substitute($template,$sig_byte,$seq_num,$uuid);
	my $packed = pack("H*",$command);

	my $offset = 0;
	my $command_len = length($packed);
	while ($offset < $command_len)
	{
		my $hdr = substr($packed,$offset,2);
		my $len = unpack('v',$hdr);
		my $data = substr($packed,$offset+2,$len);

		my $show_hdr = unpack("H*",$hdr);
		my $show_data = unpack("H*",$data);

		print pad("$offset,2",7)."<-- $show_hdr\n" if $SHOW_OUTPUT;
		$offset += 2;
		if (!$sock->send($hdr))
		{
			error("Could not send header: $show_hdr\n$!");
			return 0;
		}

		# print pad("$offset,$len",6)."<-- $show_data\n";
		show_dwords(pad("$offset,$len",7)."<-- ",$data,$show_data,0,1) if $SHOW_OUTPUT;
		if (!$sock->send($data))
		{
			error("Could not send data: $show_hdr\n$!");
			return 0;
		}
		$offset += $len;
	}

	my $out_len = unpack('v',substr($packed,0,2));
	my $packet = substr($packed,2);
	characterize($NAVQUERY_PORT,$nav_port,$out_len,$packet) if $PARSE_STUFF;
	$command_time = time();
	return 1;
}



#--------------------------------------
# thread atoms
#--------------------------------------

sub openSocket
	# start/stop = open or close the socket
	# based on running and started, initializing
	# the state as needed
{
	if ($started && !$running)
	{
		display($dbg,0,"opening navQuery socket");
		$sock = IO::Socket::INET->new(
			LocalAddr => $LOCAL_IP,
			LocalPort => $NAVQUERY_PORT,
			PeerAddr  => $nav_ip,
			PeerPort  => $nav_port,
			Proto     => 'tcp',
			Reuse	  => 1,	# allows open even if windows is timing it out
			Timeout	  => 3 );
		if ($sock)
		{
			display($dbg,0,"navQuery socket opened");

			$running = 1;
			$sel = IO::Select->new($sock);
			$waypoints = shared_clone({});
			$routes = shared_clone({});
			$groups = shared_clone({});

			$watch_sig = '';
			$command_time = 0;

			setState($STATE_GET_WP_DICT);
		}
		else
		{
			error("Could not open navQuery socket to $nav_ip:$nav_port\n$!");
			$started = 0;
			$reconnect_time = time();
		}
	}
	elsif ($running && !$started)
	{
		warning(0,0,"closing navQuerySocket");
		$sock->shutdown(2);
		$sock->close();
		$sock = undef;
		$running = 0;
		$sel = undef;

		$watch_sig = '';
		$command_time = 0;
		$refresh_time = 0;
		$reconnect_time = time();
		setState($STATE_NONE);
	}
	if (!$running)
	{
		if ($reconnect_time && time() > $reconnect_time + $RECONNECT_INTERVAL)
		{
			$reconnect_time = 0;
			warning($dbg,0,"AUTO RECONNECTING");
			$started = 1;
		}
		sleep(1);
		return 0;
	}
	return 1;
}


sub readBuf
{
	my $buf;
	if ($sel->can_read(0.1))
	{
		recv($sock, $buf, 4096, 0);
		if ($buf)
		{
			my $hex = unpack("H*",$buf);
			my $len = length($hex);
			show_dwords(pad(length($buf),7)."--> ",$buf,$hex,0,1) if $SHOW_INPUT;

			$declared_len = unpack('v',$buf) if length($buf) == 2;
				# for characterize(), the packet that follows has the
				# 'declared_length' of this packet of length(2) that
				# preceded it.
		}
	}
	return $buf;
}


sub checkTimeout
{
	if ($command_time && time() > $command_time + $COMMAND_TIMEOUT)
	{
		error("Command timed out");
		$watch_sig = '';
		$command_time = 0;
		$started = 0;
		$reconnect_time = time();
		setState($STATE_NONE);
		return 1;
	}
	return 0;
}


sub checkRefresh
{
	if ($state == $STATE_NONE)
	{
		if ($refresh_now)
		{
			warning($dbg,0,"REFRESH NOW");
			$refresh_now = 0;
			$refresh_time = 0;
			setState($STATE_GET_WP_DICT);
		}
		elsif ($auto_refresh && $refresh_time && time() > $refresh_time + $REFRESH_INTERVAL)
		{
			warning($dbg,0,"AUTO REFRESHING");
			$refresh_time = 0;
			setState($STATE_GET_WP_DICT);
		}
	}
}


sub sendDictionaryRequest
	# send the next dictionary request
{
	my $seq_num = $next_seqnum++;
	my $sig_byte =
		$state == $STATE_GET_GROUP_DICT ? '8' :
		$state == $STATE_GET_ROUTE_DICT ? '4' : '0';
	display($dbg+1,0,"getting ".kind($sig_byte)." dictionary");
	if (sendCommand($GET_DICT,$sig_byte,$seq_num))
	{
		$watch_sig = pack('H*',substitute($SIG_DICT,$sig_byte,$seq_num));
		setState($state+1);
	}
	else
	{
		$started = 0;
	}
}


sub sendItemRequest
	# request any pending items
{
	my $hash =
		$state == $STATE_GET_GROUPS ? $groups :
		$state == $STATE_GET_ROUTES ? $routes :
		$waypoints;
	my $sig_byte =
		$state == $STATE_GET_GROUPS ? '8' :
		$state == $STATE_GET_ROUTES ? '4' : '0';

	display($dbg+2,0,"checking ".scalar(keys %$hash)." ".kind($sig_byte)." items");

	my $sent = 0;
	for my $uuid (keys %$hash)
	{
		my $rec = $hash->{$uuid};
		if (!$rec->{requested})
		{
			display($dbg,0,"getting ".kind($sig_byte)." item($uuid)");
			my $seq = $next_seqnum++;
			if (sendCommand($GET_ITEM,$sig_byte,$seq,$uuid))
			{
				$sent = 1;
				$rec->{requested} = time();
				$watch_sig = pack('H*',substitute($SIG_ITEM,$sig_byte,$seq));
			}
			else
			{
				$started = 0;
			}
			last;
		}
	}

	display($dbg+2,0,kind($sig_byte)." items done sent($sent)");
	setState($state == $STATE_GET_GROUPS ? $STATE_NONE : $state+1) if $started && !$sent;
		# finished?
	$refresh_time = time() if $state == $STATE_NONE;
		# finished
}



sub handleDictReply
{
	my ($buf,$sig_byte) = @_;
	my $hash =
		$state == $STATE_PARSE_GROUP_DICT ? $groups :
		$state == $STATE_PARSE_ROUTE_DICT ? $routes :
		$waypoints;

	# TEMPORARY DICTIONARY FIX - Skip 14 bytes at offset 548

	my $num = 0;
	my $any_new = 0;
	my $offset = 13 * 4;	# the 13th dword starts the first uuid
	my $len = length($buf);
	while ($offset < $len + 8) # 8 bytes for 2 dword uuid
	{
		if ($offset == 548)
		{
			warning($dbg,0,"skipping 14 bytes at offset 548");
			$offset += 14
		}
		my $uuid = unpack('H*',substr($buf,$offset,8));
		last if substr($uuid,0,8) eq $DICT_END_RECORD_MARKER;

		my $found = $hash->{$uuid};
		$any_new = 1 if !$found;
		$hash->{$uuid} = shared_clone({}) if !$found;

		display($dbg+1,1,pad($offset,5).pad(" uuid($num)",10).
			"= $uuid".($found ? '' : ' NEW'));

		$offset += 8;
		$num++;
	}
	display($dbg+2,0,"found($num) uuids in ".kind($sig_byte)." dictionary hash=".scalar(keys %$hash));
	setState($state + 1);
}


sub handleItemReply
{
	my ($buf,$sig_byte) = @_;
	my $SELF_ID_OFFSET = 22;
	my $uuid = unpack('H*',substr($buf,$SELF_ID_OFFSET,8));
	my $hash =
		$state == $STATE_GET_GROUPS ? $groups :
		$state == $STATE_GET_ROUTES ? $routes :
		$waypoints;
	my $rec = $hash->{$uuid};
	if ($rec)
	{
		display($dbg+2,0,"parsing ".kind($sig_byte)." item");
	}
	else
	{
		error("Could not find item($uuid)");
		setState($STATE_NONE);
	}
}



#---------------------------------------------------
# navQueryThread
#---------------------------------------------------

sub navQueryThread
{
    display($dbg,0,"starting navQueryThread");

	# get NAVQRY ip:port

	my $rayport = findRayPortByName('NAVQRY');
	while (!$rayport)
	{
		display($dbg,1,"waiting for rayport(NAVQRY)");
		sleep(1);
		$rayport = findRayPortByName('NAVQRY');
	}
	$nav_ip = $rayport->{ip};
	$nav_port = $rayport->{port};
	display($dbg,1,"found rayport(NAVQRY) at $nav_ip:$nav_port");

	while (!$one_time_start)
	{
		display($dbg+1,0,"Waiting for one_time_start");
		sleep(1);
	}
	display($dbg,0,"starting navQuery loop");

    while (1)
    {
		next if !openSocket();

		my $buf = readBuf();
		next if checkTimeout();
		checkRefresh();

		if ($buf && $watch_sig && substr($buf,0,8) eq $watch_sig)
		{
			$watch_sig = '';
			$command_time = 0;
			
			my $sig_byte = unpack('H',$buf);
			display($dbg+2,0,"state($state) ".kind($sig_byte)." sig matched");

			if (unpack('H*',substr($buf,8,4)) ne $SUCCESS_SIG)
			{
				error("Unexpected reply. No SUCCESS_SIG($SUCCESS_SIG)");
				setState($STATE_NONE);
				next;
			}

			if ($state == $STATE_PARSE_WP_DICT ||
				$state == $STATE_PARSE_ROUTE_DICT ||
				$state == $STATE_PARSE_GROUP_DICT)
			{
				handleDictReply($buf,$sig_byte);
			}
			elsif ($state == $STATE_GET_WAYPOINTS ||
				   $state == $STATE_GET_ROUTES ||
				   $state == $STATE_GET_GROUPS)
			{
				handleItemReply($buf,$sig_byte);
			}
			
			characterize($nav_port,$NAVQUERY_PORT,$declared_len,$buf) if $PARSE_STUFF;
		}


		sendDictionaryRequest() if
			$state == $STATE_GET_WP_DICT ||
			$state == $STATE_GET_ROUTE_DICT ||
			$state == $STATE_GET_GROUP_DICT;
		sendItemRequest() if !$watch_sig && (
			$state == $STATE_GET_WAYPOINTS ||
			$state == $STATE_GET_ROUTES ||
			$state == $STATE_GET_GROUPS );
	}

}	#	navQueryThread()



1;