#---------------------------------------
# d_TRACK_writer.pm
#---------------------------------------
# Transient one-track-per-session writer for the E80 TRACK service.
# See NET/docs/notes/TRACK_writing.md for the protocol spec and
# NET/docs/notes/example_write_track_bocas.pl for the reference
# wire-level behavior this class encapsulates.
#
# Architecture:
#
#   - Subclass of b_sock with proto=tcp pointing at the E80's
#     advertised TRACK service (ip:port from RAYDP).
#   - parser_class = e_TRACK; the dual-role %TRACK_PARSE_RULES table
#     in d_TRACK.pm covers both reader-side queries AND writer-side
#     uploads, so no new parser is needed.  The SAVED reply emerges
#     through the existing parseMessage path as a {seq_num, success}
#     reply hash that we await via b_sock::waitReply.
#   - One instance = one track upload = one TCP session.  No reuse;
#     callers instantiate, run(), and discard.
#
# Usage:
#
#   my $writer = apps::raymarine::NET::d_TRACK_writer->new(
#       ip       => '10.0.166.121',
#       port     => 2053,
#       mta_rec  => $rec,           # hash compatible with buildMTA's $rec arg
#       points   => \@points,       # arrayref of point hashes {north,east,temp_k,depth}
#       uuid_hex => 'aa4ebabe...',  # MTA-CONTEXT UUID (16 hex chars)
#       progress => $progress,      # optional shared hash {total,done,workers,label}
#   );
#   my $ok = $writer->run();
#   if (!$ok) { warning(0,0,"track write failed: $writer->{error}") }
#
# Chunking: points are split into 35-per-batch body groups (498-byte
# BUFFER ceiling, matching the WPMGR convention).  cnt1 in the MTA
# always equals the total point count -- chunking is invisible to
# the E80 beyond per-batch CONTEXT/BUFFER/END framing.

package apps::raymarine::NET::d_TRACK_writer;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use apps::raymarine::NET::a_utils;
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_mon;
use apps::raymarine::NET::b_records;
use apps::raymarine::NET::d_TRACK;
use base qw(apps::raymarine::NET::b_sock);

# Track-writer monitoring colors (echo the SHARK_DEFAULTS values for
# $SPORT_TRACK so writer traffic visually matches reader traffic in
# the shark monitor).
my $WRITER_IN_COLOR  = $UTILS_COLOR_LIGHT_BLUE;
my $WRITER_OUT_COLOR = $UTILS_COLOR_LIGHT_CYAN;


my $dbg_tw = 0;     # default 0: display($dbg_tw,...) shows major protocol
                    # steps; display($dbg_tw+1/+2,...) finer detail surfaces
                    # when $dbg_tw is lowered to -1 / -2.

# Chunking ceiling: 498 bytes per BUFFER content, mirroring the WPMGR
# pattern.  TRACK_HEADER is 8 bytes, each TRACK_PT is 14 bytes, so
# 35 points * 14 + 8 = 498.
my $BUFFER_CHUNK     = 498;
my $POINTS_PER_BATCH = int(($BUFFER_CHUNK - 8) / 14);   # 35

# Lifecycle timeouts (seconds)
my $CONNECT_TIMEOUT  = 5;
my $REPLY_TIMEOUT    = 10;

# Frames-per-track inner-progress accounting: 1 RECORD + 3 (MTA body group)
# + 3*N (point body groups) + 1 SAVED.  Callers wanting deep progress
# should set $progress->{inner_total} accordingly; see _innerTotal().



#-----------------------------------------------
# new() / init() / destroy()
#-----------------------------------------------
# d_TRACK_writer instances are constructed directly (not via c_RAYDP
# discovery, since they're transient and not advertised services).
# new() prepares the hash, blesses, and calls b_sock::init().
# Callers then call run() which drives start->send->wait->destroy.

sub new
{
	my ($class, %args) = @_;

	for my $req (qw(ip mta_rec points uuid_hex))
	{
		if (!defined $args{$req})
		{
			error("d_TRACK_writer::new missing required arg '$req'");
			return undef;
		}
	}

	# mon_defs hash is consumed by a_parser::newParser to set the
	# parser's sid (required for the BAD_SID check) and its monitoring
	# preferences (color, monitor bits).  c_RAYDP populates this for
	# discovered services from a_mon.pm's SHARK_DEFAULTS; we construct
	# it directly here since the writer is not RAYDP-discovered.
	#
	# active / mon_in / mon_out / log are snapshotted from
	# $SHARK_DEFAULTS{$SPORT_TRACK} at construction time so that the UI
	# / config bits set for the main TRACK service automatically apply
	# to writer sessions (otherwise writer traffic was silently
	# invisible regardless of TRACK monitor configuration).  Name and
	# colors stay writer-specific so writer frames remain distinguishable
	# from main-TRACK-service frames in the monitor output.
	my $track_def  = $SHARK_DEFAULTS{$SPORT_TRACK} || {};
	my $mon_defs = shared_clone({
		name        => 'TRACK_WRITER',
		sid         => $TRACK_SERVICE_ID,
		is_shark    => 1,
		is_sniffer  => 0,
		active      => $track_def->{active}  // 0,
		mon_in      => $track_def->{mon_in}  // 0,
		mon_out     => $track_def->{mon_out} // 0,
		in_color    => $WRITER_IN_COLOR,
		out_color   => $WRITER_OUT_COLOR,
		log         => $track_def->{log}     // 0,
	});

	my $this = shared_clone({
		# b_sock-required fields
		name         => 'TRACK_WRITER',
		proto        => 'tcp',
		service_id   => $TRACK_SERVICE_ID,
		sid          => $TRACK_SERVICE_ID,   # alias also consulted by some helpers
		ip           => $args{ip},
		port         => $args{port} || 2053,
		parser_class => 'apps::raymarine::NET::e_TRACK',
		mon_defs     => $mon_defs,

		# writer-session state
		mta_rec      => shared_clone({ %{$args{mta_rec}} }),
		points       => shared_clone([ @{$args{points}} ]),
		uuid_hex     => lc($args{uuid_hex}),
		seq_token    => $args{seq_token} || (time() & 0xffffffff) || 1,
		progress     => $args{progress},

		# result
		error        => '',
		saved        => 0,

		# control
		EXIT_ON_CLOSE => 0,            # we drive destruction ourselves via destroy()
	});

	bless $this, $class;
	$this->init();
	display($dbg_tw,0,"d_TRACK_writer::new($this->{ip}:$this->{port}) uuid=$this->{uuid_hex} points=".scalar(@{$this->{points}}));
	return $this;
}



#-----------------------------------------------
# run() -- synchronous driver
#-----------------------------------------------
# Returns 1 on confirmed save, 0 on any failure (with $this->{error}
# populated).  Caller is expected to be running off the wx main thread
# because run() blocks for the duration of the TCP session.

sub run
{
	my ($this) = @_;
	display($dbg_tw,0,"d_TRACK_writer::run() starting");

	# 1. Start b_sock threads (sockThread + commandThread).
	#    Connection happens asynchronously inside sockThread.
	$this->start();

	# 2. Wait for the TCP connection, polling $this->{connected}.
	display($dbg_tw,1,"connecting to $this->{ip}:$this->{port}");
	my $deadline = time() + $CONNECT_TIMEOUT;
	while (!$this->{connected} && time() < $deadline)
	{
		sleep 0.05;
	}
	if (!$this->{connected})
	{
		$this->{error} = "connect to $this->{ip}:$this->{port} failed within ${CONNECT_TIMEOUT}s";
		$this->destroy();
		return 0;
	}
	display($dbg_tw,1,"d_TRACK_writer connected from $this->{local}");

	# 3. Build the full frame sequence (RECORD + body groups).
	my @frames = $this->_buildFrames();
	if (!@frames)
	{
		# _buildFrames already set $this->{error}
		$this->destroy();
		return 0;
	}

	# 4. Send each frame via sendPacket (b_sock pushes onto out_queue;
	#    commandThread / out_queue drainer writes to socket).  One
	#    syscall per frame -- the existing d_TRACK / d_WPMGR pattern.
	#    TCP / Nagle may coalesce on the wire; that's transparent.
	display($dbg_tw,1,"sending ".scalar(@frames)." frames");
	for my $msg (@frames)
	{
		$this->sendPacket($msg);
		$this->_progressFrameTick();
	}

	# 5. Wait for the SAVED reply.  e_TRACK::parseMessage emits a
	#    reply hash with {seq_num, success} when the SAVED frame
	#    arrives (terminal=1 in %TRACK_PARSE_RULES).
	$this->{wait_seq}  = $this->{seq_token};
	$this->{wait_name} = 'SAVED';
	display($dbg_tw,1,"awaiting SAVED ack");

	# b_sock::waitReply uses $apps::raymarine::NET::b_sock::command_timeout
	# which is 10s; that's our $REPLY_TIMEOUT budget.
	my $reply = $this->waitReply(0);   # do NOT pass expect_success; we evaluate ourselves

	# 6. Evaluate result.
	if (!$reply)
	{
		$this->{error} = "no SAVED reply within ${REPLY_TIMEOUT}s";
	}
	elsif (!ref $reply)
	{
		$this->{error} = "waitReply returned non-reply value '$reply'";
	}
	elsif ($reply->{success})
	{
		$this->{saved} = 1;
		display($dbg_tw,1,"d_TRACK_writer SAVED ok (seq=0x".sprintf('%08x',$this->{seq_token}).")");
	}
	else
	{
		$this->{error} = sprintf("SAVED non-success (seq=0x%08x); see TRACK_writing.md for status codes (e.g. UUID-collision = 0x80040f07)",
			$reply->{seq_num} // 0);
	}

	# 7. Tear down.  Whether success or failure, the writer session is
	#    over: TCP close discards on the E80 side per spec, and the
	#    writer instance is single-use.
	$this->destroy();

	return $this->{saved};
}



#-----------------------------------------------
# Frame construction
#-----------------------------------------------
# A writer session emits:
#
#   1 RECORD frame
#   3 MTA body-group frames (CONTEXT, BUFFER, END)
#   3 * N point body-group frames (CONTEXT, BUFFER, END per chunk)
#
# Total frame count = 1 + 3 + 3 * ceil(points / 35).
#
# All frames carry the same seq (the writer-chosen correlation
# token, returned in SAVED).  The MTA-CONTEXT UUID is the saved
# track's identity on E80; the points-CONTEXT UUID is ignored by
# E80 (it mints its own internal trk_uuid) and we send the same
# value everywhere for simplicity.

sub _buildFrames
{
	my ($this) = @_;

	# UUID handling: caller provides 16-char hex (32 nibbles? no, 16 hex chars = 8 bytes).
	# Normalize and pack.
	my $uuid_hex = $this->{uuid_hex};
	$uuid_hex =~ s/-//g;
	$uuid_hex = lc $uuid_hex;
	if (length($uuid_hex) != 16)
	{
		$this->{error} = "uuid_hex '$this->{uuid_hex}' must be 16 hex chars (got ".length($uuid_hex).")";
		return ();
	}
	my $uuid_bytes = pack('H*', $uuid_hex);

	my $points   = $this->{points};
	my $cnt      = scalar @$points;
	my $mta_rec  = $this->{mta_rec};
	my $mta_buf  = buildMTA($mta_rec, $cnt);
	if (!defined $mta_buf)
	{
		$this->{error} = "buildMTA returned undef";
		return ();
	}

	my $seq   = $this->{seq_token};
	my $zero4 = "\0" x 4;
	my $zero8 = "\0" x 8;
	my @frames;

	# 1 RECORD (SEND direction; payload = 4 zero bytes per spec)
	push @frames, _writerMsg($seq, $DIRECTION_SEND, $TRACK_CMD_RECORD, $zero4);

	# 3 MTA body group frames -- MTA's CONTEXT/END carries the canonical
	# track UUID (this is the durable identity E80 stores for the track).
	push @frames, _writerMsg($seq, $DIRECTION_INFO, $TRACK_INFO_CONTEXT, $uuid_bytes . $zero4);
	push @frames, _writerMsg($seq, $DIRECTION_INFO, $TRACK_INFO_BUFFER,  _wrapBuffer($mta_buf));
	push @frames, _writerMsg($seq, $DIRECTION_INFO, $TRACK_INFO_END,     $uuid_bytes);

	# 3*N point body group frames, chunked at $POINTS_PER_BATCH.
	# The TRACK_HEADER 'a' field is the running buffer-position
	# offset on the E80 side; spec requires monotonic, no-gap-no-overlap.
	#
	# EXPERIMENT (2026-05-29): per-chunk CONTEXT/END uuids are sent as
	# zeros, not as the track uuid.  Read-side trace shows E80 emits
	# distinct per-chunk uuids (incrementing a low-byte counter) that
	# are NOT the track identity -- they appear to be transient chunk
	# markers.  Hypothesis: E80 doesn't care what's in the per-chunk
	# CONTEXT/END uuid slots; they're convenience markers only.
	# Probing this with zeros to see if E80 accepts the upload and
	# whether the round-trip identity (via MTA's uuid) is preserved.
	my $a = 0;
	for (my $i = 0; $i < $cnt; $i += $POINTS_PER_BATCH)
	{
		my $end = $i + $POINTS_PER_BATCH;
		$end = $cnt if $end > $cnt;
		my @batch = @{$points}[$i .. $end - 1];

		my $pts_buf = buildTRKBatch($a, \@batch);
		if (!defined $pts_buf)
		{
			$this->{error} = "buildTRKBatch returned undef at a=$a batch_size=".scalar(@batch);
			return ();
		}

		push @frames, _writerMsg($seq, $DIRECTION_INFO, $TRACK_INFO_CONTEXT, $zero8 . $zero4);
		push @frames, _writerMsg($seq, $DIRECTION_INFO, $TRACK_INFO_BUFFER,  _wrapBuffer($pts_buf));
		push @frames, _writerMsg($seq, $DIRECTION_INFO, $TRACK_INFO_END,     $zero8);

		$a += scalar @batch;
	}

	display($dbg_tw+1,1,"d_TRACK_writer _buildFrames produced ".scalar(@frames)." frames for $cnt points");
	return @frames;
}



#-----------------------------------------------
# Low-level wire helpers (private)
#-----------------------------------------------
# These mirror the harness's wire format exactly.  They're file-scope
# subs (not OO methods) since they take no instance state.

sub _writerMsg
{
	my ($seq, $dir, $cmd, $payload) = @_;
	$payload //= '';
	my $data = pack('v', $cmd | $dir) . pack('v', $TRACK_SERVICE_ID);
	$data .= pack('V', $seq) if $seq;
	$data .= $payload;
	return pack('v', length($data)) . $data;
}

sub _wrapBuffer
{
	# Standard RAYNET 'buffer' wire form: u32 biglen + biglen bytes content.
	# e_TRACK::parsePiece consumes the biglen via substr +4 inside the
	# 'buffer' piece handler.
	my ($content) = @_;
	return pack('V', length($content)) . $content;
}



#-----------------------------------------------
# Progress hooks
#-----------------------------------------------
# Progress model -- the $progress shared hash carries:
#   total  -- total frame count for the whole batch; the CALLER sizes it
#             before run() by summing framesForTrack(point_count) over its
#             tracks (the preflight, see framesForTrack below).
#   done   -- frames sent so far; bumped here once per frame so the dialog
#             gauge advances smoothly and monotonically across the batch.
#   workers-- caller-side worker semaphore (not touched here).
#   label  -- user-visible "Writing '<name>'" string; the CALLER owns it.
#
# The macro protocol steps (connecting / sending / awaiting ack / saved)
# are emitted as display($dbg_tw,...) debug, NOT pushed to {label}: the
# dialog is end-user UI, the protocol phases are for debugging.  This is
# the debug-vs-UI separation -- the writer never writes the dialog text.

sub _progressFrameTick
	# One tick per frame sent -- bumps the shared {done} the dialog reads.
	# OPT-IN: only fires when the caller set $progress->{frame_ticks}, i.e.
	# it sized {total} by summing framesForTrack (the frame-granular paste
	# worker).  Per-track callers (PUSH, the synchronous fallback loops)
	# leave frame_ticks unset and bump {done} once per track themselves, so
	# the writer must not touch {done} for them.  When enabled, the
	# run()-driving worker thread is the single writer of {done}: no lock.
{
	my ($this) = @_;
	my $progress = $this->{progress};
	return if !$progress;
	return if !$progress->{frame_ticks};
	$progress->{done}++;
	display($dbg_tw+2,2,"frame tick: done=".($progress->{done}//0)."/".($progress->{total}//0));
}



#-----------------------------------------------
# Frame-count helper -- the per-track preflight
#-----------------------------------------------
# Static method: the exact number of frame-ticks one track of
# $point_count points will emit (RECORD + MTA group + ceil(N/35) point
# groups), matching _progressFrameTick's per-frame bumps one-for-one.
# Callers sum this over a batch to size the ProgressDialog {total} before
# dispatching the writes -- see navOps::_dispatchTrackWritesAsync.
#   d_TRACK_writer::framesForTrack(scalar @points)

sub framesForTrack
{
	my ($point_count) = @_;
	$point_count = 0 if !defined $point_count || $point_count < 0;
	my $batches = int(($point_count + $POINTS_PER_BATCH - 1) / $POINTS_PER_BATCH);
	$batches = 1 if !$point_count;   # safeguard; zero-point tracks should fail preflight anyway
	return 1 + 3 + 3 * $batches;     # RECORD + MTA group + N point groups
}

sub pointsPerBatch
{
	return $POINTS_PER_BATCH;
}



1;
