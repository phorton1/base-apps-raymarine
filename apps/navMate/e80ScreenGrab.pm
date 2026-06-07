#!/usr/bin/perl

package e80ScreenGrab;
use strict;
use warnings;
use IO::Socket::INET;
use Compress::Zlib;
use Pub::Utils qw(display error warning my_mkdir);


BEGIN
{
    use Exporter qw( import );
    our @EXPORT = qw(
        grabE80Screen
        grabE80ScreenImage
        encodeE80Png
    );
}



# ---- debug gates: display(gate, indent, msg) shows when the global debug level is >= gate ----
my $dbg_grab      = 0;              # grabE80Screen* call chain
my $dbg_wire      = 1;             # low-level TCP frame send/recv detail (quiet unless verbose)
my $dbg_composite = 1;             # low-level layer-composite detail (quiet unless verbose)

# ---- E80 connection (TCP diagnostic service, current test unit E80-2) ----
my $E80_IP          = '10.0.240.83';  # the E80 on the test bench
my $DIAG_TCP_PORT   = 6668;           # bulk screen-capture diagnostic port (mod002)
my $GRAB_CMD        = 0xdddd0007;     # GRAB command word (mod002): frame[0]. The conn-thread
                                      # dispatch matches the FULL word (retiring the stock echo
                                      # command 0xdddd0000); the reply echoes it in the header.
my $REPLY_MAGIC     = 0xdddd0007;     # reply header [0..3] -- the echoed GRAB command word

# ---- timeouts (seconds) ----
my $CONNECT_TIMEOUT = 3;              # bound the TCP connect so a dead unit fails, not hangs
my $READ_TIMEOUT    = 8;              # overall bound on receiving the framed snapshot

# ---- output geometry ----
# NOT hardcoded: the panel resolution is DERIVED from the regblock in each reply (see _screenSize),
# so one library serves a 640x480 E80 and an 800x600 E120 unchanged -- the client never supplies it.

# ---- wire: request sequence + reply bound ----
my $SEQ_NEXT        = 0;              # increasing request sequence; the reply header must echo it
my $MAX_BODY        = 8 * 1024 * 1024;  # sanity ceiling on a reply BODY (~1.4 MB E80, ~1.9 MB E120)

# ==== GDC2 register-block layout (INTERNAL: used only by the raw/snapshot + composite path) ====
# The device ships the regblock (incl CLUTs) + each enabled layer's raw buffer; the host parses
# the regblock with the offsets below to drive compositing. None of this is client-visible.
my $REGBLOCK        = 0xD7FD0000;     # GDC2 register block (CPU address); HW-fixed
my $GDC2_TO_CPU     = 0xD6000000;     # CPU address = GDC2-space base + this
my $ENABLE_OFF      = 0x100;          # enable reg: bit (16 + N) = HW layer N on
my $ZORDER_OFF      = 0x180;          # z-order reg: six nibbles, nibble0 = frontmost .. nibble5 = backmost
my @CTRL_OFF        = (0x20, 0x30, 0x40, 0x58, 0x70, 0x88);   # per-layer control reg
my @BASE_OFF        = (0x24, 0x34, 0x44, 0x5c, 0x74, 0x8c);   # per-layer base reg (GDC2 space)
my $WINDOW_OFF      = 0x110;          # per-layer window block at +0x110 + N*0x10 = {fmt, origin, size}
my $DISP_WM1_OFF    = 0x008;          # CRTC: low16 = panel width-1  (E80 0x27f=639). Cross-check only --
my $DISP_HM1_OFF    = 0x014;          # CRTC: high16 = panel height-1 (E80 0x1df=479). semantics inferred.
my @COLORKEY_OFF    = (0x1a0, 0x1a4, 0x1a8, 0x1ac, 0x1b0, 0x1b4); # per-layer colorkey reg
my @CLUT_OFF        = (0x400, 0x800, 0x1000, 0x1400);         # CLUT banks 0..3 (256 x 0x00RRGGBB)
# control reg fields: bit31 = 16bpp (else 8bpp); bits16-23 = pitch-in-tiles (8bpp<<6 / 16bpp<<5 = px);
#                     low 12 bits = height - 1
# colorkey reg:       bit31 = colorkey enable; low 24 bits = key (8bpp uses low byte = palette index)



#----------------------------------------------------------
# API   (published entry points; exported)
#----------------------------------------------------------
# Synchronous; each opens its own TCP session, reads the screen, and returns.
# The capture is read-only -- it never modifies or reboots the unit.


sub grabE80Screen
    # Capture the E80 at $ip and write a PNG to $path. Returns 1/0.
{
    my ($ip, $path, $progress) = @_;

    my $image = grabE80ScreenImage($ip, $progress);
    return 0 if !$image;                            # failure already reported

    $path .= '.png' if $path !~ /\.png$/i;

    my $png = encodeE80Png($image);
    return _fail($progress, "PNG encode failed") || 0 if !defined $png;

    (my $dir = $path) =~ s{[\\/][^\\/]*$}{};        # parent directory of $path
    my_mkdir($dir) if length($dir) && !-d $dir;

    my $fh;
    return _fail($progress, "cannot open $path: $!") || 0 if !open($fh, '>', $path);
    binmode $fh;
    print $fh $png;
    close $fh;

    display($dbg_grab, 0, "grabE80Screen wrote $path");
    return 1;
}


sub grabE80ScreenImage
    # Capture the E80 at $ip; return an rgb24 $image hashref, or undef.
{
    my ($ip, $progress) = @_;

    my $snapshot = grabE80ScreenRaw($ip, $progress);
    return undef if !$snapshot;

    return compositeE80Snapshot($snapshot);
}


sub encodeE80Png
    # ($image) -> PNG byte string (Compress::Zlib; no device access, no temp file). undef on bad input.
{
    my ($image) = @_;
    return undef if !$image || ref($image) ne 'HASH' || ($image->{format} || '') ne 'rgb24';

    my ($w, $h, $px) = @{$image}{ qw(width height pixels) };
    return undef if !$w || !$h || !defined($px) || length($px) != $w * $h * 3;

    my $stride = $w * 3;
    my $raw    = '';
    for my $y (0 .. $h - 1)                          # PNG scanlines: filter-type byte 0 + row
    {
        $raw .= "\x00" . substr($px, $y * $stride, $stride);
    }

    my $png = "\x89PNG\r\n\x1a\n"
            . _pngChunk('IHDR', pack('N2 C5', $w, $h, 8, 2, 0, 0, 0))  # 8bpp truecolor (type 2)
            . _pngChunk('IDAT', Compress::Zlib::compress($raw))
            . _pngChunk('IEND', '');
    return $png;
}



#----------------------------------------------------------
# Internal entry points (NOT exported; callable qualified for diagnostics)
#----------------------------------------------------------
# These expose device-specific structures ($snapshot) and are not part of the
# published API. Use e80ScreenGrab::grabE80ScreenRaw(...) for raw / diff work.


sub grabE80ScreenRaw
    # ($ip [,$progress]) -> $snapshot, or undef. INTERNAL. Device-specific (regblock + raw layers).
{
    my ($ip, $progress) = @_;

    return _fail($progress, "cancelled") if _cancelled($progress);

    my $sock = _open($ip);
    return _fail($progress, "cannot open capture session to $ip") if !$sock;

    if (_cancelled($progress))                          # cancel honored until the bulk transfer begins
    {
        _close($sock);
        return _fail($progress, "cancelled");
    }

    _phase($progress, "Requesting frame", 0, 2);
    my $seq = _nextSeq();
    if (!_sendGrab($sock, $seq))
    {
        _close($sock);
        return _fail($progress, "GRAB request send to $ip failed");
    }

    _phase($progress, "Receiving frame", 1, 2);
    my ($hdr, $body) = _recvFrame($sock, $seq);         # the whole snapshot arrives in one turn
    _close($sock);
    return _fail($progress, "no valid snapshot from $ip") if !$hdr;

    return _decodeSnapshot($body, $seq, $progress);     # parse BODY -> snapshot (shared seam)
}


sub _decodeSnapshot
    # ($body, $seq [,$progress]) -> $snapshot hashref, or undef. INTERNAL.
    # Parse a received frame BODY (format word + GDC2 regblock incl CLUTs + the enabled layers'
    # raw buffers) into the snapshot structure compositeE80Snapshot consumes. Factored out of
    # grabE80ScreenRaw so the LIVE capture and any OFFLINE/diff path share ONE parse.
{
    my ($body, $seq, $progress) = @_;

    my $format = unpack('V', substr($body, 0, 4));      # BODY[0..3] = snapshot layout version
    return _fail($progress, "unsupported snapshot format $format") if $format != 1;

    my $regblock = substr($body, 4, 0x1800);            # BODY[4..] = GDC2 regs + the 4 CLUT banks
    return _fail($progress, "snapshot regblock truncated") if length($regblock) != 0x1800;

    my $manifest = _parseRegblock($regblock);

    # The enabled layers' raw buffers follow the regblock, in ascending layer index. Each is sized
    # by the DEVICE's formula (bytes/row * control-height); slice exactly that to stay aligned.
    my $off = 4 + 0x1800;
    for my $n (0 .. 5)
    {
        my $l = $manifest->{layers}[$n];
        next if !$l->{en};
        my $buf = substr($body, $off, $l->{size});
        return _fail($progress, "snapshot truncated in layer $n buffer")
            if length($buf) != $l->{size};
        display($dbg_wire, 1, sprintf("layer %d: %d bytes at body+0x%x", $n, $l->{size}, $off));
        $l->{buf} = $buf;
        $off += $l->{size};
    }

    my ($sw, $sh) = @{ $manifest->{screen} }{ 'w', 'h' };   # resolution DERIVED from the regblock
    return _fail($progress, "could not derive screen size from regblock") if !$sw || !$sh;

    _phase($progress, "Done", 2, 2);
    display($dbg_grab, 0, sprintf("_decodeSnapshot: %dx%d, %d-byte snapshot, enable=0x%08x",
        $sw, $sh, length($body), $manifest->{enable}));
    return {
        width  => $sw,
        height => $sh,
        seq    => $seq,
        format => $format,
        enable => $manifest->{enable},
        zorder => $manifest->{zorder},
        order  => $manifest->{order},
        clut   => $manifest->{clut},
        layers => $manifest->{layers},
    };
}


sub compositeE80Snapshot
    # ($snapshot) -> rgb24 $image, or undef. INTERNAL. Pure transform (no device access).
{
    my ($snapshot) = @_;
    return undef if !$snapshot;

    my ($SW, $SH) = ($snapshot->{width}, $snapshot->{height});
    my @canvas = map { "\x00\x00\x00" x $SW } 1 .. $SH;     # flat rgb24 canvas, black

    for my $n (@{ $snapshot->{order} })                     # bottom -> top
    {
        my $l = $snapshot->{layers}[$n];
        next if !$l || !$l->{en} || !defined($l->{buf}) || !length($l->{buf});

        my $bpb    = $l->{bpp} == 8 ? 1 : 2;
        my $ppx    = $l->{ppx};
        my $buf    = $l->{buf};
        my $clut   = $snapshot->{clut}[$n & 3];             # 4 HW CLUT banks; bank = layer & 3
        my $keyidx = $l->{ckey} & 0xff;                     # 8bpp color key = palette index
        my $key16  = $l->{ckey} & 0xffff;                   # 16bpp color key = RGB565 value
        my $rows   = $l->{dh} > $l->{hctrl} ? $l->{hctrl} : $l->{dh};

        display($dbg_composite, 1, sprintf("layer %d: %dbpp %dx%d at (%d,%d) pitch %dpx",
            $n, $l->{bpp}, $l->{dw}, $rows, $l->{ox}, $l->{oy}, $ppx));

        for my $r (0 .. $rows - 1)
        {
            my $sy = $l->{oy} + $r;
            next if $sy < 0 || $sy >= $SH;
            my $rowbase = $r * $ppx;
            for my $c (0 .. $l->{dw} - 1)
            {
                my $sx = $l->{ox} + $c;
                next if $sx < 0 || $sx >= $SW;
                my $boff = ($rowbase + $c) * $bpb;
                next if $boff + $bpb > length($buf);
                my ($R, $G, $B);
                if ($bpb == 1)
                {
                    my $idx = ord(substr($buf, $boff, 1));
                    next if $idx == $keyidx;                # color-keyed -> layer beneath shows
                    my $v = $clut->[$idx] || 0;
                    ($R, $G, $B) = (($v >> 16) & 0xff, ($v >> 8) & 0xff, $v & 0xff);
                }
                else
                {
                    my $v = unpack('v', substr($buf, $boff, 2));
                    next if ($v & 0xffff) == $key16;        # color-keyed -> layer beneath shows
                    ($R, $G, $B) = _dec565($v);
                }
                substr($canvas[$sy], $sx * 3, 3) = pack('C3', $R, $G, $B);
            }
        }
    }

    return {
        width  => $SW,
        height => $SH,
        format => 'rgb24',
        pixels => join('', @canvas),
    };
}



# ---- private helpers ----


sub _open
    # ($ip) -> connected TCP socket to the diag service, or undef.
{
    my ($ip) = @_;
    $ip ||= $E80_IP;

    my $sock = IO::Socket::INET->new(
        PeerAddr => $ip,
        PeerPort => $DIAG_TCP_PORT,
        Proto    => 'tcp',
        Timeout  => $CONNECT_TIMEOUT,
    );
    if (!$sock)
    {
        display($dbg_wire, 0, "_open: connect to $ip:$DIAG_TCP_PORT failed: $@");
        return undef;
    }
    binmode $sock;
    display($dbg_wire, 0, "_open: connected to $ip:$DIAG_TCP_PORT");
    return $sock;
}


sub _close
    # ($sock) -- tear down the capture session.
{
    my ($sock) = @_;
    close($sock) if $sock;
}


sub _recvFrame
    # ($sock, $expect_seq) -> ($header_hashref, $payload) validated, or undef. INTERNAL.
{
    my ($sock, $expect_seq) = @_;

    my $hdr = _readN($sock, 16);                        # 16-byte raw header (NOT length-prefixed)
    if (!defined $hdr || length($hdr) != 16)
    {
        display($dbg_wire, 0, "_recvFrame: header read failed/timed out");
        return undef;
    }
    my ($cmd, $seq, $len, $cksum) = unpack('V4', $hdr);
    display($dbg_wire, 0, sprintf("_recvFrame: cmd=0x%08x seq=%u len=%u cksum=0x%08x",
        $cmd, $seq, $len, $cksum));

    if ($cmd != $REPLY_MAGIC)
    {
        display($dbg_wire, 0, sprintf("_recvFrame: bad reply magic 0x%08x", $cmd));
        return undef;
    }
    if (defined $expect_seq && $seq != $expect_seq)
    {
        display($dbg_wire, 0, "_recvFrame: seq mismatch ($seq != $expect_seq)");
        return undef;
    }
    if ($len <= 0 || $len > $MAX_BODY || $len % 4)
    {
        display($dbg_wire, 0, "_recvFrame: implausible body length $len");
        return undef;
    }

    my $body = _readN($sock, $len);
    if (!defined $body || length($body) != $len)
    {
        display($dbg_wire, 0, "_recvFrame: body short (got "
            . (defined $body ? length $body : 0) . " of $len)");
        return undef;
    }

    my $sum = 0;                                        # device checksum = additive 32-bit word-sum,
    $sum = ($sum + $_) % 4294967296 for unpack('V*', $body);   # reduced mod 2^32 PER STEP: on 32-bit
                                                        # Perl a bare "+= then & 0xffffffff" overflows
                                                        # the running total into an NV and saturates to
                                                        # 0xffffffff -- per-step % keeps it exact.
    if ($sum != $cksum)
    {
        display($dbg_wire, 0, sprintf("_recvFrame: checksum mismatch 0x%08x != 0x%08x", $sum, $cksum));
        return undef;
    }

    return ({ cmd => $cmd, seq => $seq, len => $len, cksum => $cksum }, $body);
}


sub _parseRegblock
    # ($regblock_bytes) -> manifest { enable, zorder, order=>\@, clut=>\@, layers=>\@ }. INTERNAL.
{
    my ($reg) = @_;

    my $r32 = sub { unpack('V', substr($reg, $_[0], 4)) };
    my $enable = $r32->($ENABLE_OFF);
    my $zorder = $r32->($ZORDER_OFF);

    my @clut;                                           # 4 banks x 256 entries of 0x00RRGGBB
    for my $b (0 .. 3)
    {
        $clut[$b] = [ unpack('V256', substr($reg, $CLUT_OFF[$b], 256 * 4)) ];
    }

    my @layers;
    for my $n (0 .. 5)
    {
        my $ctrl  = $r32->($CTRL_OFF[$n]);
        my $gbase = $r32->($BASE_OFF[$n]);
        my $tiles = ($ctrl >> 16) & 0xff;               # pitch in tiles
        my $bpp   = ($ctrl >> 31) & 1 ? 16 : 8;
        my $bpr   = $tiles << 6;                         # bytes/row (device: tiles<<6 for BOTH bpp)
        my $ppx   = $bpp == 8 ? ($tiles << 6) : ($tiles << 5);   # pitch in pixels
        my $hctrl = ($ctrl & 0xfff) + 1;                # control-register height (rows allocated)
        my $wo    = $WINDOW_OFF + $n * 0x10;
        my $org   = $r32->($wo + 4);
        my $sz    = $r32->($wo + 8);
        my $dw    = $sz & 0xffff;
        my $dh    = (($sz >> 16) & 0xffff) + 1;
        # a degenerate window (w==0, h<=1, or an absurd value) means "spans to the panel edge":
        # mark it with a 0 SENTINEL and resolve it to the DERIVED screen size below -- never a hardcode.
        $dw = 0 if $dw > 0x4000;
        $dh = 0 if $dh <= 1 || $dh > 0x4000;

        $layers[$n] =
        {
            n     => $n,
            en    => ($enable >> (16 + $n)) & 1,
            ctrl  => $ctrl,
            bpp   => $bpp,
            ppx   => $ppx,
            hctrl => $hctrl,
            size  => $bpr * $hctrl,                      # bytes the device streams for this layer
            base  => $gbase ? ($gbase + $GDC2_TO_CPU) & 0xffffffff : 0,
            fmt   => $r32->($wo),
            ox    => $org & 0xffff,
            oy    => ($org >> 16) & 0xffff,
            dw    => $dw,
            dh    => $dh,
            ckey  => $r32->($COLORKEY_OFF[$n]) & 0xffffff,   # bit31(enable) masked off; low bits = key
        };
    }

    my ($sw, $sh) = _screenSize(\@layers);                  # derive the panel size from the regblock
    for my $l (@layers)                                     # resolve "full-screen" window sentinels
    {
        next if !$l->{en};
        $l->{dw} = $sw - $l->{ox} if !$l->{dw};
        $l->{dh} = $sh - $l->{oy} if !$l->{dh};
        $l->{dw} = 0 if $l->{dw} < 0;
        $l->{dh} = 0 if $l->{dh} < 0;
    }
    display($dbg_wire, 0, sprintf("_parseRegblock: derived screen %dx%d (CRTC +0x08/+0x14 read %dx%d)",
        $sw, $sh, ($r32->($DISP_WM1_OFF) & 0xffff) + 1, (($r32->($DISP_HM1_OFF) >> 16) & 0xffff) + 1));

    my @order = reverse grep { $layers[$_]{en} } 0 .. 5;    # bottom -> top (proven reference order)
    return {
        enable => $enable, zorder => $zorder, clut => \@clut, layers => \@layers,
        order  => \@order, screen => { w => $sw, h => $sh },
    };
}


sub _screenSize
    # (\@layers) -> ($w, $h). Derive the panel resolution from the parsed layers -- NO hardcode, so
    # one library serves both the 640x480 E80 and the 800x600 E120. Primary: the bounding box of the
    # enabled layer windows (the full-screen background spans the panel, so its window == the panel;
    # validated 640x480 on E80). Fallback for degenerate windows: widest pitch / tallest control-height.
{
    my ($layers) = @_;
    my ($w, $h) = (0, 0);

    for my $l (@$layers)                                    # primary: bounding box of layer windows
    {
        next if !$l->{en};
        $w = $l->{ox} + $l->{dw} if $l->{dw} && $l->{ox} + $l->{dw} > $w;
        $h = $l->{oy} + $l->{dh} if $l->{dh} && $l->{oy} + $l->{dh} > $h;
    }
    if (!$w) { $w = $_->{ppx}   > $w ? $_->{ppx}   : $w for grep { $_->{en} } @$layers; }
    if (!$h) { $h = $_->{hctrl} > $h ? $_->{hctrl} : $h for grep { $_->{en} } @$layers; }
    return ($w, $h);
}


sub _nextSeq
    # a monotonically increasing 32-bit request sequence (the reply must echo it).
{
    $SEQ_NEXT = ($SEQ_NEXT + 1) & 0xffffffff;
    return $SEQ_NEXT;
}


sub _sendGrab
    # ($sock, $seq) -> 1/0. Send one length-prefixed GRAB request (native 0xdddd frame).
{
    my ($sock, $seq) = @_;
    my $frame = pack('V', $GRAB_CMD)        # [0..3]  cmd
              . pack('v', 0)                # [4..5]  slot (unused on TCP)
              . pack('v', 4)                # [6..7]  native payload length
              . pack('V', $seq);            # [8..11] seq (the dispatch reads this back)
    my $msg = pack('v', length $frame) . $frame;        # socket-layer 2-byte LE length prefix
    my $ok = _writeAll($sock, $msg);
    display($dbg_wire, 0, sprintf("_sendGrab: seq=%u, %d bytes, %s", $seq, length $msg, $ok ? "ok" : "FAILED"));
    return $ok;
}


sub _writeAll
    # ($sock, $data) -> 1/0. Write every byte, looping over partial writes.
{
    my ($sock, $data) = @_;
    my $off   = 0;
    my $total = length $data;
    while ($off < $total)
    {
        my $n = syswrite($sock, $data, $total - $off, $off);
        return 0 if !defined $n || $n == 0;
        $off += $n;
    }
    return 1;
}


sub _readN
    # ($sock, $n) -> exactly $n bytes, or undef on timeout / EOF / error. Honors $READ_TIMEOUT.
{
    my ($sock, $n) = @_;
    my $buf      = '';
    my $deadline = time() + $READ_TIMEOUT;
    my $rin      = '';
    vec($rin, fileno($sock), 1) = 1;
    while (length($buf) < $n)
    {
        my $remain = $deadline - time();
        last if $remain <= 0;
        my $nf = select(my $r = $rin, undef, undef, $remain);
        last if !defined $nf || $nf <= 0;               # timeout or select error
        my $got = sysread($sock, my $chunk, $n - length($buf));
        return undef if !defined $got;                  # read error
        last if $got == 0;                              # peer closed
        $buf .= $chunk;
    }
    return length($buf) == $n ? $buf : undef;
}


sub _dec565
    # (u16) -> (R,G,B) bytes, expanding RGB565 to 8 bits per channel.
{
    my ($v) = @_;
    my ($r, $g, $b) = (($v >> 11) & 0x1f, ($v >> 5) & 0x3f, $v & 0x1f);
    return (($r << 3) | ($r >> 2), ($g << 2) | ($g >> 4), ($b << 3) | ($b >> 2));
}


sub _phase
    # ($progress, $label, $done, $total) -- coarse progress update (no-op without $progress).
{
    my ($progress, $label, $done, $total) = @_;
    return if !$progress || ref($progress) ne 'HASH';
    $progress->{label} = $label;
    $progress->{done}  = $done;
    $progress->{total} = $total;
}


sub _cancelled
    # ($progress) -> true if the caller has requested cancellation.
{
    my ($progress) = @_;
    return $progress && ref($progress) eq 'HASH' && $progress->{cancelled};
}


sub _pngChunk
    # ($type, $data) -> a length-prefixed, CRC-suffixed PNG chunk.
{
    my ($type, $data) = @_;
    my $body = $type . $data;
    return pack('N', length $data) . $body . pack('N', Compress::Zlib::crc32($body));
}


sub _fail
    # ($progress, $msg) -- log the failure, record it in $progress, and return undef.
{
    my ($progress, $msg) = @_;
    error($msg);
    $progress->{error} = $msg if $progress && ref($progress);
    return undef;
}



1;
