#-----------------------------------------------------------------------------
# write_track_bocas.pl
#
# Test harness for the TRACK writing protocol described in
# C:/base/apps/raymarine/NET/docs/notes/TRACK_writing.md.
#
# Fetches the BOCAS1-001 track from navMate /api/fsh, encodes its MTA and
# 11 trackpoints per b_records.pm SPECS, opens a single-track-per-session
# TCP connection to the E80 TRACK service (10.0.166.121:2053), and walks
# the wire sequence:
#
#     SEND RECORD                 (seq = correlation token)
#     INFO CONTEXT/BUFFER/END     (MTA body group)
#     INFO CONTEXT/BUFFER/END     (point batch body group, single batch)
#     RECV SAVED                  (success = 0x00040000 expected)
#
# Run as:
#     /c/Perl/bin/perl.exe -I/base /c/base_data/temp/raymarine/write_track_bocas.pl \
#         >/c/base_data/temp/raymarine/write_track_bocas.out 2>&1
#-----------------------------------------------------------------------------

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use JSON;
use Time::HiRes qw(time);

$| = 1;

my $E80_IP        = '10.0.166.121';
my $TRACK_PORT    = 2053;
my $FSH_URL       = 'http://localhost:9883/api/fsh';
my $TRACK_NAME    = 'BOCAS1-001';
my $REPLY_TIMEOUT = 10;
my $FSH_TMP       = 'C:/base_data/temp/raymarine/_fsh_tmp.json';

# Wire constants (mirror NET/a_defs.pm, NET/d_TRACK.pm, TRACK_writing.md)
my $TRACK_SERVICE_ID   = 19;
my $DIRECTION_RECV     = 0x000;
my $DIRECTION_SEND     = 0x100;
my $DIRECTION_INFO     = 0x200;

my $TRACK_CMD_RECORD   = 0x11;
my $TRACK_INFO_CONTEXT = 0x00;
my $TRACK_INFO_BUFFER  = 0x01;
my $TRACK_INFO_END     = 0x02;
my $TRACK_REPLY_SAVED  = 0x0f;

my $SUCCESS_SIG = 0x00040000;


#-----------------------------------------
# logging
#-----------------------------------------

my $t0 = time();

sub say_log
{
	my ($msg) = @_;
	printf("%7.3f %s\n", time() - $t0, $msg);
}

sub hexdump
{
	my ($bytes) = @_;
	return unpack('H*', $bytes);
}

sub fatal
{
	my ($msg) = @_;
	say_log("FATAL: $msg");
	exit 2;
}


#-----------------------------------------
# wire envelope
#-----------------------------------------

# createMsg mirrors d_TRACK.pm::createMsg but takes the direction
# as an explicit argument instead of hard-coding SEND, so it can
# emit INFO frames.  seq is omitted from the envelope when 0
# (matches existing reader-side handling for headerless INFO frames).

sub createMsg
{
	my ($seq, $dir, $cmd, $payload) = @_;
	$payload = '' if !defined $payload;
	my $data = pack('v', $cmd | $dir) . pack('v', $TRACK_SERVICE_ID);
	$data .= pack('V', $seq) if $seq;
	$data .= $payload;
	return pack('v', length($data)) . $data;
}


# wrapBuffer prefixes a buffer payload with a 4-byte little-endian
# length (the standard RAYNET 'buffer' wire form: u32 biglen then
# biglen bytes of content).  The 'buffer' piece-parser in
# e_TRACK.pm at line 179 consumes this biglen via substr +4.

sub wrapBuffer
{
	my ($content) = @_;
	return pack('V', length($content)) . $content;
}


#-----------------------------------------
# encoders -- mirror b_records.pm SPECS
#-----------------------------------------

sub encodeMTA
{
	my ($r, $cnt) = @_;
	my $name = defined($r->{name}) ? $r->{name} : '';
	my $buf =
		  pack('c',  1)                          # k1_1 = 0x01 writer-side
		. pack('s',  $cnt)                       # cnt1: number of points we will deliver
		. pack('s',  $cnt)                       # cnt2: same as cnt1
		. pack('s',  0)                          # k2_0 = 0
		. pack('l',  $r->{length})
		. pack('l',  $r->{north_start})
		. pack('l',  $r->{east_start})
		. pack('S',  $r->{temp_k_start})
		. pack('V',  $r->{depth_start})
		. pack('l',  $r->{north_end})
		. pack('l',  $r->{east_end})
		. pack('S',  $r->{temp_k_end})
		. pack('V',  $r->{depth_end})
		. pack('c',  $r->{color})
		. pack('Z16', $name)
		. pack('C',  0)                          # u1 = 0 writer-side
	;
	my $len = length($buf);
	fatal("encodeMTA produced $len bytes, expected 57") if $len != 57;
	return $buf;
}

sub encodeTRKBatch
{
	my ($a_start, $pts) = @_;
	my $cnt = scalar @$pts;
	my $buf = pack('V', $a_start) . pack('v', $cnt) . pack('v', 0);
	for my $p (@$pts)
	{
		$buf .= pack('l', $p->{north})
		      . pack('l', $p->{east})
		      . pack('v', $p->{temp_k})
		      . pack('V', $p->{depth});
	}
	my $expected = 8 + $cnt * 14;
	my $got = length($buf);
	fatal("encodeTRKBatch produced $got bytes, expected $expected") if $got != $expected;
	return $buf;
}

sub uuidBytes
{
	my ($u) = @_;
	(my $h = $u) =~ s/-//g;
	$h = lc $h;
	fatal("uuid $u does not have 16 hex digits") if length($h) != 16;
	return pack('H*', $h);
}


#-----------------------------------------
# 1. fetch the FSH track
#-----------------------------------------

say_log("fetch $TRACK_NAME from $FSH_URL");

my $rc = system('curl', '-s', '-o', $FSH_TMP, $FSH_URL);
fatal("curl failed rc=$rc") if $rc != 0;

open(my $fh, '<', $FSH_TMP) or fatal("open $FSH_TMP: $!");
local $/;
my $json_raw = <$fh>;
close $fh;

my $j = decode_json($json_raw);
my $track;
my $track_uuid_dashed;
for my $u (keys %{$j->{tracks} || {}})
{
	my $r = $j->{tracks}{$u};
	if (defined($r->{name}) && $r->{name} eq $TRACK_NAME)
	{
		$track = $r;
		$track_uuid_dashed = $u;
		last;
	}
}
fatal("track $TRACK_NAME not found in /api/fsh") if !$track;

my $pts = $track->{points};
fatal("track $TRACK_NAME has no points") if !$pts || !@$pts;

say_log(sprintf("found %s uuid=%s fsh_cnt=%s actual_points=%d",
	$TRACK_NAME,
	$track_uuid_dashed,
	defined($track->{cnt}) ? $track->{cnt} : 'undef',
	scalar @$pts));


#-----------------------------------------
# 2. build wire messages
#-----------------------------------------

my $uuid_bytes = uuidBytes($track_uuid_dashed);
my $mta_buf    = encodeMTA($track, scalar @$pts);
my $pts_buf    = encodeTRKBatch(0, $pts);
my $seq_token  = 0xCAFEBABE;

say_log(sprintf("mta_buf len=%d", length($mta_buf)));
say_log("mta_buf hex=" . hexdump($mta_buf));
say_log(sprintf("pts_buf len=%d (header 8 + %d * 14)",
	length($pts_buf), scalar @$pts));
say_log("pts_buf hex=" . hexdump($pts_buf));

my $zero4 = "\0" x 4;

# INFO_CONTEXT: pieces = [seq, uuid, context_bits]  -- 16-byte payload
# INFO_BUFFER:  pieces = [seq, buffer]              -- buffer = biglen + content
# INFO_END:     pieces = [seq, uuid]                -- 12-byte payload
# All INFO frames share $seq_token with RECORD per spec.

my $msg_record  = createMsg($seq_token, $DIRECTION_SEND, $TRACK_CMD_RECORD, $zero4);

my $msg_mta_ctx = createMsg($seq_token, $DIRECTION_INFO, $TRACK_INFO_CONTEXT, $uuid_bytes . $zero4);
my $msg_mta_buf = createMsg($seq_token, $DIRECTION_INFO, $TRACK_INFO_BUFFER,  wrapBuffer($mta_buf));
my $msg_mta_end = createMsg($seq_token, $DIRECTION_INFO, $TRACK_INFO_END,     $uuid_bytes);

my $msg_pts_ctx = createMsg($seq_token, $DIRECTION_INFO, $TRACK_INFO_CONTEXT, $uuid_bytes . $zero4);
my $msg_pts_buf = createMsg($seq_token, $DIRECTION_INFO, $TRACK_INFO_BUFFER,  wrapBuffer($pts_buf));
my $msg_pts_end = createMsg($seq_token, $DIRECTION_INFO, $TRACK_INFO_END,     $uuid_bytes);


#-----------------------------------------
# 3. connect + send + await SAVED
#-----------------------------------------

say_log("connect tcp $E80_IP:$TRACK_PORT");
my $sock = IO::Socket::INET->new(
	PeerHost => $E80_IP,
	PeerPort => $TRACK_PORT,
	Proto    => 'tcp',
	Timeout  => 5,
);
fatal("connect failed: $!") if !$sock;
$sock->autoflush(1);
say_log("connected from " . $sock->sockhost() . ":" . $sock->sockport());

my @sends = (
	[ 'RECORD',     $msg_record  ],
	[ 'MTA_CTX',    $msg_mta_ctx ],
	[ 'MTA_BUF',    $msg_mta_buf ],
	[ 'MTA_END',    $msg_mta_end ],
	[ 'PTS_CTX',    $msg_pts_ctx ],
	[ 'PTS_BUF',    $msg_pts_buf ],
	[ 'PTS_END',    $msg_pts_end ],
);

for my $i (0..$#sends)
{
	if ($i > 0)
	{
		say_log("--- pause 5s ---");
		sleep 5;
	}
	my ($label, $bytes) = @{$sends[$i]};
	say_log(sprintf("SEND %-8s len=%-3d %s", $label, length($bytes), hexdump($bytes)));
	my $n = syswrite($sock, $bytes);
	if (!defined($n) || $n != length($bytes))
	{
		fatal("syswrite $label wrote " . (defined $n ? $n : 'undef') . " of " . length($bytes));
	}
}

say_log("awaiting SAVED reply (timeout=${REPLY_TIMEOUT}s)");

my $sel      = IO::Select->new($sock);
my $deadline = time() + $REPLY_TIMEOUT;
my $recv_buf = '';
my $saved    = 0;
my $finned   = 0;

while (!$saved)
{
	my $remaining = $deadline - time();
	last if $remaining <= 0;
	my @ready = $sel->can_read($remaining);
	last if !@ready;

	my $chunk;
	my $n = sysread($sock, $chunk, 4096);
	if (!defined $n)
	{
		say_log("sysread error: $!");
		last;
	}
	if ($n == 0)
	{
		$finned = 1;
		say_log("FIN from E80 (peer closed)");
		last;
	}
	$recv_buf .= $chunk;
	say_log(sprintf("RECV %d bytes hex=%s", $n, hexdump($chunk)));

	while (length($recv_buf) >= 2)
	{
		my $len = unpack('v', substr($recv_buf, 0, 2));
		last if length($recv_buf) < 2 + $len;
		my $msg = substr($recv_buf, 2, $len);
		$recv_buf = substr($recv_buf, 2 + $len);

		my $cmd = unpack('v', substr($msg, 0, 2));
		my $sid = unpack('v', substr($msg, 2, 2));
		say_log(sprintf("  parsed msg cmd=0x%04x sid=%d payload_len=%d",
			$cmd, $sid, $len - 4));

		if ($cmd == ($DIRECTION_RECV | $TRACK_REPLY_SAVED))
		{
			my $seq    = unpack('V', substr($msg, 4, 4));
			my $status = unpack('V', substr($msg, 8, 4));
			my $ok_seq = ($seq    == $seq_token) ? 'match' : sprintf('expected 0x%08x', $seq_token);
			my $ok_sts = ($status == $SUCCESS_SIG) ? 'match' : sprintf('expected 0x%08x', $SUCCESS_SIG);
			say_log(sprintf("  SAVED  seq=0x%08x [%s]  success=0x%08x [%s]",
				$seq, $ok_seq, $status, $ok_sts));
			$saved = 1 if $seq == $seq_token && $status == $SUCCESS_SIG;
		}
	}
}

close $sock;

if ($saved)
{
	say_log("SUCCESS: track $TRACK_NAME written and SAVED ack received");
	exit 0;
}
elsif ($finned)
{
	say_log("FAILURE: E80 closed before SAVED reply (malformed packet on our side?)");
	exit 1;
}
else
{
	say_log("FAILURE: no SAVED reply within ${REPLY_TIMEOUT}s");
	exit 1;
}
