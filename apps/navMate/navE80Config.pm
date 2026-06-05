#!/usr/bin/perl

package navE80Config;
use strict;
use warnings;
use threads;
use threads::shared;
use IO::Socket::INET;
use Socket qw(sockaddr_in inet_aton);
use Pub::Utils qw(display error warning my_mkdir);


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
        saveE80Config
        clearE80Config
        restoreE80Config
	);
}



# ---- debug gates: display(gate, indent, msg) shows when the global debug level is >= gate ----
my $dbg_reset   = 0;                # reboot flow (_issueReboot active; _reboot/_dismissDisclaimer/_resetE80 vestigial)
my $dbg_save    = 0;                # saveE80Config    call chain
my $dbg_clear   = 0;                # clearE80Config   call chain
my $dbg_restore = 0;                # restoreE80Config call chain
my $dbg_local   = 1;                # low-level \local file read/write detail (quiet unless verbose)
my $dbg_flob    = 1;                # low-level keyed-flob read/write/delete detail (quiet unless verbose)

# ---- E80 connection (current test unit E80-2) ----
my $E80_IP        = '10.0.240.83';  # the E80 on the test bench
my $DIAG_PORT     = 6667;           # mod001 diagnostic command port on the E80
my $REPLY_PORT    = 9973;           # whitelisted local listener port (host firewall rule _prh_src_e80_TFTP)
my $DIAG_MAGIC    = 0xdddd0005;     # mod001 peek/poke/call command word

# ---- mod001 sub-operations ----
my $SUBOP_PEEK    = 0;              # read memory  -> hex reply
my $SUBOP_POKE    = 1;              # write memory -> no reply
my $SUBOP_CALL    = 2;              # call function(arg0..arg4) -> r0 in hex reply

# ---- reset (active) ----
my $RESET_ADDR    = 0x01835208;     # CPegWatchdog active flag; poke 0 -> feed stops -> clean HW reset

# ==== VESTIGIAL: full unattended reset cycle (NOT wired into the current single-reboot flow) ====
# The constants below (and _reboot / _dismissDisclaimer / _resetE80 and the liveness + PEG-dialog
# functions that use them) implement "reset, WAIT for the diag service to return, then find + DISMISS
# the boot disclaimer". The library no longer calls any of it: a save/clear/restore operation reboots
# exactly ONCE, as its final step (via _issueReboot), and the user presses OK on the boot disclaimer
# by hand -- the wait+dismiss was built for the abandoned multi-reboot-per-operation case. They are
# kept intact -- the vtables, offsets, and phase semantics are expensive to re-derive -- so the cycle
# can be re-hooked simply by pointing clear / restore back at _resetE80.
my $LIVENESS_ADDR = 0x01867730;     # stable PEG-globals address; a valid peek reply proves 6667 is alive
my $RESET_SETTLE  = 4;              # seconds to let the unit drop offline before polling for it

# ---- PEG dialog dismissal (vestigial) ----
my $LOOP_VT       = 0x015dde5c;     # CRayAppletUserMessageLoop instance vtable (static, stable)
my $PHASE_HANDLER = 0x00846fa4;     # pegDialog_phaseHandler1(loop, box, phase)
my $PHASE_CLOSE   = 3;              # phase semantic constant: close the dialog
my $RETURN_HANDLED= 0x00040000;     # phaseHandler1 return value when it handled the close
my $DISCLAIMER    = 'LIMITATIONS';  # caption substring identifying the boot disclaimer

# ---- live object layout (vestigial; heap floats per boot, offsets are stable) ----
my $MAP_OFF       = 0x10;           # loop+0x10 = box-map header pointer
my $BOX_VAL_OFF   = 0x10;           # map node+0x10 = embedded box value (the box struct itself)
my $BOX_WIN_OFF   = 0x14;           # box+0x14 = window (COM object, vtable at word0)
my $BOX_STATE_OFF = 0x24;           # box+0x24 = state word (cleared to 0 when the box closes)
my $WIN_CHILD     = 0x48;           # PEG window first-child pointer
my $WIN_SIBLING   = 0x4c;           # PEG window next-sibling pointer

# ---- address-range sanity (vestigial) ----
my $IMAGE_LO      = 0x00001000;     # firmware image runs in place at VMA 0 (static strings live here)
my $IMAGE_HI      = 0x016b5260;     # end of the firmware image
my $HEAP_LO       = 0x04000000;     # heap window low
my $HEAP_HI       = 0x06000000;     # heap window high
my $SCAN_LO       = 0x04fd0000;     # sub-window the message loop has been observed in
my $SCAN_HI       = 0x05000000;     # ... scanned for the loop vtable

# ---- timeouts (vestigial; seconds) ----
my $SERVICE_TIMEOUT = 150;          # wait for diag 6667 (typ ~20s; one cold boot hit ~68s)
my $DIALOG_TIMEOUT  = 30;           # wait for the disclaimer dialog to appear (typ ~1s after 6667)

# ---- named-file (\local) FS accessor: gestalt layer 1 (page sets) + layer 3 (window selectors) ----
my $FSACC          = 0x0445dd74;    # CLocalPersistence FS-accessor singleton (bss)
my $FSACC_STAT     = 0x00bc49ac;    # vt+0x54  stat(this, pathPtr)               -> status (bit31 set = not found)
my $FSACC_SIZE     = 0x00bc4bcc;    # vt+0x64  getSize(this, pathPtr, &outSize)
my $FSACC_READ     = 0x00bc4cc8;    # vt+0x84  read(this, pathPtr, offset, dest, &len)
my $FSACC_WRITE    = 0x00bc4dfc;    # vt+0x8c  write(this, pathPtr, offset, src, &len)
my $FS_MKSUBDIR    = 0x00bc3644;    # fsAccessor_createSubdirInDir(parentDirObj, namePtr): create a slot
#                                   # dir DIRECT on the live parent (the by-path createDirByPath wrapper
#                                   # 0x00bc4754 returns ok but creates nothing over the diag channel)
my $PAGESETS_PATH  = '\local\slotless\CMainApp0.lp';  # the 5 page-set blocks (+ active-set header)
my $SELECTOR_FILE  = 'CInstrumentatio0.lp';  # the per-window 1-byte panel selector
my $PAGESET_COUNT  = 5;             # Nav / SitAware / Boat / Fishing / Custom
my $PAGESET_LEN    = 600;           # bytes per page-set block
my $PAGESET_BASE   = 8;             # first block starts after an 8-byte header (header carries active-set)
my $PAGESET_IDOFF  = 564;           # block+564 = set id (uint32), for the manifest
my $PAGESET_NAMEOFF= 568;           # block+568 = 25-byte set name, for the manifest

# ---- keyed flob store: gestalt layer 2 (panelsets) ----
my $FLOB           = 0x0471c66c;    # CFlobFilesystem singleton (bss)
my $FLOB_HEAD_OFF  = 0x34;          # +0x34 = RB-tree header / nil sentinel (CFlobGuidList)
my $FLOB_SIZE_OFF  = 0x38;          # +0x38 = record count
my $FLOB_READKEY   = 0x004bbff4;    # readByKey(FS, &outId, keyPtr, dest, len)   -> 0x40000
my $FLOB_WRITEKEY  = 0x004bbda4;    # writeByKey(FS, id, keyPtr, src, len)       -> 0x40000 (create/supersede)
my $FLOB_DELKEY    = 0x004bccd8;    # deleteByKey(FS, keyPtr, 0, 0)              -> 0x40000 (param3 unused, param4 ctx)
my $FLOB_OK        = 0x00040000;    # success return shared by read/write/deleteByKey
my $PANEL_ID       = 0x04;          # record-id of instrument-app config records (Data/Engine/CDI share it)
my $PANEL_MIN_LEN  = 1024;          # a real panelset is the ~1864B grid; id 0x04 ALSO tags many small
                                    # instrument-settings records, so require a full-size body to qualify

# RB-node layout (key = 4 x uint16, then metadata)
my $NODE_LEFT      = 0x00;          # _Left
my $NODE_RIGHT     = 0x08;          # _Right
my $NODE_KEY       = 0x0c;          # 4 x uint16 {owner0, owner1, type, key3}
my $NODE_LEN       = 0x14;          # uint16 record body length
my $NODE_ID        = 0x20;          # uint32 record id (the family tag; 0x04 = panelset)
my $NODE_REC       = 0x24;          # uint32 physical ring offset (independent of the key)
my $NODE_NIL       = 0x29;          # byte: node is the nil sentinel iff != 0
my $NODE_SIZE      = 0x2c;          # bytes to peek per node
my $FLOB_NODECAP   = 6000;          # hard ceiling on tree-node steps

# panelset class tag = record body byte 1 (header word 0x010100dX); dX low nibble routes the class
my @PANEL_CLASS    = ('data', 'engine', 'cdi');   # index 0/1/2 = d0/d1/d2

# ---- \local cached directory tree (for discovering live window-selector files) ----
my $TREE_ROOT_OFF  = 0x34;          # *(FSACC+0x34) = cached dir-tree root
my $DIR_SUBDIR_OFF = 0x4c;          # dir object: subdir std::_Tree header
my $DIR_FILE_OFF   = 0x58;          # dir object: file   std::_Tree header
my $TNODE_NAME     = 0x0c;          # tree node: name pointer
my $TNODE_VALUE    = 0x10;          # tree node: value (child dir-object or file-object)
my $TNODE_ISNIL_W  = 0x14;          # tree node: word whose byte 1 ((w>>8)&0xff) is _Isnil
my $TREE_NODECAP   = 8000;          # hard ceiling on tree-node steps
my $TREE_DEPTHCAP  = 16;            # hard ceiling on directory recursion depth

# ---- pointer-sanity bounds for store / tree walks (peek only; validate before any deref) ----
my $PTR_LO         = 0x01000000;
my $PTR_HI         = 0x08000000;
my $PTR_POISON     = 0x33cc33cc;

# ---- device-side scratch RAM layout (staging for FS / flob call arguments) ----
my $SCRATCH_PATH   = 0x01740000;    # path string  / flob key buffer (reused; ops are sequential)
my $SCRATCH_OUTID  = 0x01740010;    # readByKey out-id cell
my $SCRATCH_SIZE   = 0x01740100;    # getSize out cell
my $SCRATCH_LEN    = 0x01740104;    # read/write in/out length cell
my $SCRATCH_BUF    = 0x01740200;    # data buffer (>= 16 KB of free RAM here)
my $POKE_CHUNK     = 512;           # max bytes per poke datagram

# ---- friendly machine-name map (owner-id string -> name); manifest machine_name is "" if unknown ----
my %MACHINE_NAME   = ( 'b280ad37' => 'E80-2' );

# ---- on-disk gestalt format ----
my $MANIFEST_FILE  = 'e80Config.json';
my $FORMAT_VERSION = 1;


#----------------------------------------------------------
# API
#----------------------------------------------------------
# Exported entry points (synchronous; the client never sees $this)
# Each opens its own session, mutates $progress only, and returns 1/0.


sub saveE80Config
    # Back up the E80 config gestalt at $ip into $folder. Returns 1/0.
{
    my ($ip, $folder, $progress) = @_;
    my $this = _open($ip);
    return _progressFail($progress, "cannot open session to $ip") if !$this;
    my $ok = _saveE80($this, $folder, $progress);
    _close($this);
    return $ok;
}


sub clearE80Config
    # Clear the E80's custom config and reboot it so the result is visible. Returns 1/0.
{
    my ($ip, $progress) = @_;
    my $this = _open($ip);
    return _progressFail($progress, "cannot open session to $ip") if !$this;

    _progressInit($progress, 2);    # static: reset page sets (1) + reboot (1); grows as discovered
    _progressLabel($progress, "Reading store records");
    my @recs   = _flobEnumerate($this, $progress);
    my $owner  = _deviceOwner($this, @recs);
    if (!$owner)
    {
        _close($this);
        return _progressFail($progress, "cannot resolve device owner");
    }
    my @panels = _panelRecords($owner, @recs);
    my @selectors = _localSelectors($this, $progress);
    _progressAddTotal($progress, scalar(@panels) + scalar(@selectors));    # delete panels + reset selectors

    # layer 1: write the factory-default page sets back over CMainApp0.lp
    _progressLabel($progress, "Resetting page sets");
    if (!_localWrite($this, $PAGESETS_PATH, _defaultCMainApp0Lp(), 0))
    {
        _close($this);
        return _progressFail($progress, "cannot reset page sets to default");
    }
    _progressTick($progress);

    my $ok = _clearE80($this, $progress, \@panels, \@selectors)
          && _issueReboot($this, $progress);
    _close($this);
    return $ok;
}


sub restoreE80Config
    # Restore a saved gestalt folder to the E80 at $ip: clear, overlay, then ONE reset+dismiss so the
    # unit adopts everything at boot. Returns 1/0.
{
    my ($ip, $folder, $progress) = @_;
    my $this = _open($ip);
    return _progressFail($progress, "cannot open session to $ip") if !$this;

    my ($nsel, $npanel) = _countFolder($folder);
    # static: write (1 page-set step + nsel selectors + npanel panelsets) + reboot (1); the clear-phase
    # panel/selector counts and the store scans are discovered and grown in below.
    _progressInit($progress, 1 + $nsel + $npanel + 1);
    _progressLabel($progress, "Reading store records");
    my @recs   = _flobEnumerate($this, $progress);
    my $owner  = _deviceOwner($this, @recs);
    if (!$owner)
    {
        _close($this);
        return _progressFail($progress, "cannot resolve device owner");
    }
    my @panels = _panelRecords($owner, @recs);
    my @selectors = _localSelectors($this, $progress);
    _progressAddTotal($progress, scalar(@panels) + scalar(@selectors));    # clear: delete panels + reset selectors

    my $ok = _clearE80($this, $progress, \@panels, \@selectors)
          && _writeE80($this, $folder, $progress, $owner, \@recs)
          && _issueReboot($this, $progress);
    _close($this);
    return $ok;
}



#---------------------------------------------------------
# mod001 diagnostic wire protocol (peek / poke / call)
#---------------------------------------------------------

sub _txn
    # One mod001 diagnostic transaction over $this->{sock} to $this->{ip}:$DIAG_PORT.
    #   $SUBOP_PEEK: @rest = (nbytes)        -> returns the hex string of the bytes read
    #   $SUBOP_POKE: @rest = (raw_bytes)     -> returns '' once sent (no reply expected)
    #   $SUBOP_CALL: @rest = (arg0..argN)    -> returns the hex string of the r0 return
    # Returns undef on failure.
{
    my ($this, $subop, $addr, @rest) = @_;
    my $sock = $this->{sock};
    return undef if !$sock;

    my $tail = '';
    my @slots;
    my $want;                          # expected reply hex length (peek only); undef = any even hex
    if ($subop == $SUBOP_PEEK)
    {
        @slots = ($addr, $rest[0], 0, 0, 0);
        $want  = 2 * $rest[0];
    }
    elsif ($subop == $SUBOP_POKE)
    {
        $tail  = $rest[0];
        @slots = ($addr, length($tail));
    }
    else
    {
        my @args = @rest;
        push(@args, 0) while @args < 5;
        @slots = ($addr, @args[0 .. 4]);
    }

    my $reply_port = $this->{reply_port} || $REPLY_PORT;
    my $pkt = pack('V', $DIAG_MAGIC)
            . pack('v', $reply_port)
            . pack('v', 0)
            . pack('C', $subop)
            . "\x00\x00\x00"
            . pack('V*', @slots)
            . $tail;
    my $dest = sockaddr_in($DIAG_PORT, inet_aton($this->{ip}));

    # retry the send; per try, drain stale datagrams then read several replies, skipping any whose
    # length does not match the expected peek size (mirrors the proven diag scripts' txn).
    my $rin = '';
    vec($rin, fileno($sock), 1) = 1;
    for my $try (1 .. 5)
    {
        while (select(my $drain = $rin, undef, undef, 0.05))
        {
            my $junk;
            $sock->recv($junk, 4096);
        }
        $sock->send($pkt, 0, $dest) or return undef;
        return '' if $subop == $SUBOP_POKE;
        for my $rd (1 .. 8)
        {
            last if !select(my $ready = $rin, undef, undef, 0.6);
            my $resp;
            $sock->recv($resp, 4096);
            my $payload = substr($resp, 10);       # 10-byte reply header precedes the hex
            next if !defined($payload) || $payload !~ /^[0-9a-fA-F]*$/ || length($payload) % 2;
            return $payload if !defined($want) || length($payload) == $want;
        }
    }
    return undef;
}


sub _peekWords
    # Peek $nbytes and return an arrayref of little-endian 32-bit words, or undef.
{
    my ($this, $addr, $nbytes) = @_;
    my $hex = _txn($this, $SUBOP_PEEK, $addr, $nbytes);
    return undef if !defined($hex) || length($hex) != 2 * $nbytes;
    return [ unpack('V*', pack('H*', $hex)) ];
}


sub _peek1
    # Peek a single 32-bit word, or undef.
{
    my ($this, $addr) = @_;
    my $words = _peekWords($this, $addr, 4);
    return $words ? $words->[0] : undef;
}


sub _poke
    # Poke raw bytes at $addr (no reply).
{
    my ($this, $addr, $bytes) = @_;
    return _txn($this, $SUBOP_POKE, $addr, $bytes);
}


sub _call
    # Call $func(arg0..argN) on the device; return its r0 value, or undef.
{
    my ($this, $func, @args) = @_;
    my $hex = _txn($this, $SUBOP_CALL, $func, @args);
    return undef if !defined($hex) || $hex !~ /^[0-9a-fA-F]{8}/;
    return unpack('V', pack('H*', substr($hex, 0, 8)));
}


sub _sleep
    # Fractional-second sleep without pulling in Time::HiRes.
{
    my ($secs) = @_;
    select(undef, undef, undef, $secs);
}


sub _isImage
    # True if $v looks like a pointer into the (in-place) firmware image.
{
    my ($v) = @_;
    return defined($v) && $v >= $IMAGE_LO && $v <= $IMAGE_HI;
}


sub _isHeap
    # True if $v looks like a live heap pointer.
{
    my ($v) = @_;
    return defined($v) && $v >= $HEAP_LO && $v < $HEAP_HI;
}


sub _isPointer
    # True if $v could be a readable string pointer: static (image) or dynamic (heap).
{
    my ($v) = @_;
    return _isImage($v) || _isHeap($v);
}


#---------------------------------------------------------
# $progress shared-hash contract (mutate-only)
# See memory reference-progress-shared-object: workers write fields, the wx
# ProgressDialog::_onIdle reads them. We never call methods on $progress.
#---------------------------------------------------------

sub _progressInit
    # Seed the tick total and reset the counter for this operation.
{
    my ($progress, $total) = @_;
    return if !$progress;
    $progress->{total} = $total;
    $progress->{done}  = 0;
}


sub _progressLabel
    # Set the human-readable label for the current step.
{
    my ($progress, $label) = @_;
    return if !$progress;
    $progress->{label} = $label;
}


sub _progressTick
    # Advance one tick.
{
    my ($progress) = @_;
    return if !$progress;
    $progress->{done}++;
}


sub _progressAddTotal
    # Grow the total by $n newly-discovered work units (each advanced later with _progressTick).
{
    my ($progress, $n) = @_;
    return if !$progress;
    $progress->{total} += $n;
}


sub _progressCancelled
    # True if the UI requested cancellation.
{
    my ($progress) = @_;
    return $progress && $progress->{cancelled};
}


sub _progressFail
    # Record a terminal error on $progress, log it, and return 0 for the caller to propagate.
{
    my ($progress, $msg) = @_;
    $progress->{error} = $msg if $progress;
    error($msg);
    return 0;
}


#---------------------------------------------------------
# Liveness and PEG dialog discovery / dismissal (VESTIGIAL -- used only by the retained
# _resetE80 cycle; see the reboot section banner)
#---------------------------------------------------------

sub _serviceAvailable
    # One peek of a stable always-mapped address; a valid reply proves the diag service
    # on UDP 6667 is alive (the timing race showed 6667 comes up ~1s before ICMP ping).
{
    my ($this) = @_;
    my $w = _peek1($this, $LIVENESS_ADDR);
    return defined($w) ? 1 : 0;
}


sub _scanLoops
    # Scan the heap sub-window for live message loops, identified by their class vtable
    # at word0. Returns the list of loop object addresses found.
{
    my ($this) = @_;
    my @found;
    my $addr = $SCAN_LO;
    while ($addr < $SCAN_HI)
    {
        my $n = ($addr + 480 <= $SCAN_HI) ? 480 : $SCAN_HI - $addr;
        my $blk = _peekWords($this, $addr, $n);
        if ($blk)
        {
            for my $i (0 .. $#$blk)
            {
                push(@found, $addr + $i * 4) if $blk->[$i] == $LOOP_VT;
            }
        }
        $addr += 480;
    }
    return @found;
}


sub _enumBoxes
    # Walk a message loop's box map (loop+0x10) and return [box_addr, window_addr] for
    # each entry that looks like a dialog box: a small integer id at box+0 and a heap
    # window pointer at box+0x14. The box value is embedded inline at map-node+0x10.
{
    my ($this, $loop) = @_;
    my $hdr = _peek1($this, $loop + $MAP_OFF);
    return () if !_isHeap($hdr);
    my $root = _peek1($this, $hdr);
    return () if !_isHeap($root);

    my @boxes;
    my %seen;
    my @queue = ($root);
    my $tries = 0;
    while (@queue && $tries++ < 200)
    {
        my $node = shift(@queue);
        next if $seen{$node}++;

        my $box = $node + $BOX_VAL_OFF;
        my $id  = _peek1($this, $box);
        my $win = _peek1($this, $box + $BOX_WIN_OFF);
        if (defined($id) && $id > 0 && $id <= 0xffff && _isHeap($win))
        {
            push(@boxes, [$box, $win]);
        }

        for my $off (0x00, 0x04, 0x08)
        {
            my $child = _peek1($this, $node + $off);
            push(@queue, $child) if _isHeap($child) && $child != $hdr && !$seen{$child};
        }
    }
    return @boxes;
}


sub _peekString
    # Peek a short buffer at $addr and decode it as a printable string. Tries UTF-16LE
    # first (the E80's UI/legal text is wide-char), then ASCII. Returns the decoded
    # text, or undef if it is not a clean printable string.
{
    my ($this, $addr) = @_;
    my $hex = _txn($this, $SUBOP_PEEK, $addr, 96);
    return undef if !defined($hex) || length($hex) < 8;
    my $raw = pack('H*', $hex);

    # UTF-16LE: printable low byte, zero high byte, until a NUL unit
    my $wide = '';
    for (my $i = 0; $i + 1 < length($raw); $i += 2)
    {
        my $lo = ord(substr($raw, $i,     1));
        my $hi = ord(substr($raw, $i + 1, 1));
        last if $lo == 0 && $hi == 0;
        if ($hi == 0 && $lo >= 0x20 && $lo < 0x7f)
        {
            $wide .= chr($lo);
        }
        else
        {
            $wide = '';
            last;
        }
    }
    return $wide if length($wide) >= 3;

    # ASCII fallback
    my $ascii = '';
    for my $byte (split(//, $raw))
    {
        my $c = ord($byte);
        last if $c == 0;
        if ($c >= 0x20 && $c < 0x7f)
        {
            $ascii .= chr($c);
        }
        else
        {
            $ascii = '';
            last;
        }
    }
    return length($ascii) >= 3 ? $ascii : undef;
}


sub _objCaption
    # Scan the first 0x140 bytes of a PEG window/control object for a pointer to a printable
    # string and return the first decoded string containing $want (the proven shape: a dialog's
    # caption/body text pointer sits deeper than 0x70 in the control). With $want '' returns the
    # first printable string found. Returns undef if none matches.
{
    my ($this, $obj, $want) = @_;
    my $words = _peekWords($this, $obj, 0x140);
    return undef if !$words;
    for my $w (@$words)
    {
        next if !_isPointer($w);
        my $text = _peekString($this, $w);
        next if !defined($text);
        return $text if $want eq '' || index(lc($text), $want) >= 0;
    }
    return undef;
}


sub _captionInSubtree
    # Walk a PEG window subtree rooted at $root (descend via first-child +0x48, then each
    # child's next-sibling +0x4c -- staying inside $root's subtree) and return the first window
    # or control caption/content string containing $want. This is the proven path: the live
    # disclaimer text lives in the dialog window's content controls, not in the box struct.
{
    my ($this, $root, $want) = @_;
    return undef if !_isHeap($root);
    my %seen;
    my @queue = ($root);
    my $visited = 0;
    while (@queue && $visited++ < 24)
    {
        my $node = shift(@queue);
        next if $seen{$node}++;

        my $cap = _objCaption($this, $node, $want);
        return $cap if defined($cap);

        # enqueue all direct children: first-child, then walk its sibling chain
        my $child = _peek1($this, $node + $WIN_CHILD);
        my $guard = 0;
        while (_isHeap($child) && !$seen{$child} && $guard++ < 24)
        {
            push(@queue, $child);
            $child = _peek1($this, $child + $WIN_SIBLING);
        }
    }
    return undef;
}


sub _findOpenPEGDialog
    # Find an open PEG dialog whose live caption/content contains $title. Walks each message
    # loop's box map to enumerate dialog boxes, then reads each box's window subtree (box+0x14)
    # for the live caption text. Returns a handle hashref
    #   { loop => ..., box => ..., id => ..., window => ..., title => <matched caption> }
    # for _dismissPEGDialog(), or undef. With $verbose set, logs every box/caption examined so
    # a miss is never silent.
{
    my ($this, $title, $verbose) = @_;
    my $want = defined($title) ? lc($title) : '';
    my @diag;
    for my $loop (_scanLoops($this))
    {
        for my $entry (_enumBoxes($this, $loop))
        {
            my ($box, $win) = @$entry;
            my $caption = _captionInSubtree($this, $win, $want);
            push(@diag, sprintf("box=0x%08x id=0x%x win=0x%08x cap=%s",
                $box, _peek1($this, $box) || 0, $win, defined($caption) ? "'$caption'" : "-"));
            if (defined($caption))
            {
                return {
                    loop   => $loop,
                    box    => $box,
                    id     => _peek1($this, $box),
                    window => $win,
                    title  => $caption };
            }
        }
    }
    display(0, 1, "find('$title'): examined " . (join(" | ", @diag) || "(no boxes found)")) if $verbose;
    return undef;
}


sub _dismissPEGDialog
    # Close an open PEG dialog by invoking its message loop's phase handler.
    # $win is a handle from _findOpenPEGDialog(); $param is the phase (3 = close).
    # Returns 1 if the call reported "handled" and the box state cleared, else 0.
{
    my ($this, $win, $param) = @_;
    display($dbg_reset, 1, sprintf("dismiss: call 0x%08x(0x%08x, 0x%08x, %d)",
        $PHASE_HANDLER, $win->{loop}, $win->{box}, $param));
    my $ret = _call($this, $PHASE_HANDLER, $win->{loop}, $win->{box}, $param);
    _sleep(0.4);
    my $state = _peek1($this, $win->{box} + $BOX_STATE_OFF);
    display($dbg_reset, 1, sprintf("dismiss: return=%s box.state=%s",
        defined($ret)   ? sprintf("0x%08x", $ret)   : "(none)",
        defined($state) ? sprintf("0x%08x", $state) : "?"));
    return (defined($ret) && $ret == $RETURN_HANDLED && defined($state) && $state == 0) ? 1 : 0;
}


#---------------------------------------------------------
# Reboot (active) + the retained unattended reset cycle (vestigial)
#---------------------------------------------------------

sub _issueReboot
    # Issue a clean watchdog reset and return immediately: poke the CPegWatchdog active flag to 0,
    # so the periodic feed stops and the hardware watchdog starves into a clean reset. One tick.
    # This is the reboot the live clear / restore flows use. An operation reboots exactly ONCE, as
    # its final step, so the library has nothing to do on the far side -- the user presses OK on the
    # boot disclaimer by hand. The retained _reboot / _dismissDisclaimer / _resetE80 below add the
    # (now unused) wait-for-service + auto-dismiss cycle. Does NOT init $progress. Returns 1.
{
    my ($this, $progress) = @_;
    display($dbg_reset, 0, sprintf("_issueReboot: reset via watchdog (poke 0x%08x = 0)", $RESET_ADDR));
    _progressLabel($progress, "Rebooting E80");
    _poke($this, $RESET_ADDR, "\x00\x00\x00\x00");
    _progressTick($progress);
    return 1;
}


#======================================================================================
# VESTIGIAL below -- the full unattended reset cycle (reset, WAIT for the diag service to
# return, then find + DISMISS the boot disclaimer). NOT wired into the current flow: the
# library reboots once via _issueReboot and the user dismisses the disclaimer by hand. Kept
# intact (the vtables, offsets, and phase semantics are expensive to re-derive) so the cycle
# can be re-hooked simply by pointing clear / restore back at _resetE80.
#======================================================================================

sub _reboot
    # VESTIGIAL (see banner above). Reboot the E80 cleanly via the watchdog lever and wait for the
    # diag service to return. Two ticks (reset issued, service back). Does NOT init $progress -- the
    # caller owns the total so this composes inside larger flows. Returns 1 on success, 0 on failure.
{
    my ($this, $progress) = @_;

    # tick -- issue the watchdog reset (poke the CPegWatchdog active flag 0 -> feed stops -> HW reset)
    display($dbg_reset, 0, sprintf("_reboot: reset via watchdog (poke 0x%08x = 0)", $RESET_ADDR));
    _progressLabel($progress, "Resetting E80");
    _poke($this, $RESET_ADDR, "\x00\x00\x00\x00");
    _progressTick($progress);
    _sleep($RESET_SETTLE);
    return _progressFail($progress, "cancelled") if _progressCancelled($progress);

    # tick -- wait for the diag service to come back (6667 comes up ~1s before ICMP ping)
    display($dbg_reset, 0, "_reboot: waiting for the E80 to come back (<= ${SERVICE_TIMEOUT}s)");
    _progressLabel($progress, "Waiting for E80");
    my $t0 = time();
    my $up = 0;
    while (time() - $t0 < $SERVICE_TIMEOUT)
    {
        return _progressFail($progress, "cancelled") if _progressCancelled($progress);
        if (_serviceAvailable($this))
        {
            $up = 1;
            last;
        }
        _sleep(1);
    }
    return _progressFail($progress, "E80 did not come back within ${SERVICE_TIMEOUT}s") if !$up;
    display($dbg_reset, 1, "diag service alive after " . (time() - $t0) . "s");
    _progressTick($progress);
    return 1;
}


sub _dismissDisclaimer
    # VESTIGIAL (see banner above). Find the boot "LIMITATIONS ON USE" disclaimer and dismiss it so
    # the cycle is unattended. Two ticks (dialog found, dialog dismissed). Does NOT init $progress.
    # Returns 1/0.
{
    my ($this, $progress) = @_;

    # tick -- wait for the disclaimer dialog to appear (typ ~1s after the service is back)
    display($dbg_reset, 0, "_dismissDisclaimer: waiting for the '$DISCLAIMER' dialog (<= ${DIALOG_TIMEOUT}s)");
    _progressLabel($progress, "Waiting for disclaimer");
    my $t1 = time();
    my $win;
    while (time() - $t1 < $DIALOG_TIMEOUT)
    {
        return _progressFail($progress, "cancelled") if _progressCancelled($progress);
        $win = _findOpenPEGDialog($this, $DISCLAIMER);
        last if $win;
        _sleep(1.5);
    }
    if (!$win)
    {
        _findOpenPEGDialog($this, $DISCLAIMER, 1);      # dump the boxes/captions we DID see
        return _progressFail($progress, "disclaimer dialog not seen within ${DIALOG_TIMEOUT}s");
    }
    display($dbg_reset, 1, sprintf("found dialog: loop=0x%08x box=0x%08x caption='%s'",
        $win->{loop}, $win->{box}, $win->{title}));
    _progressTick($progress);

    # tick -- dismiss it (call the message loop's phase handler with phase 3 = close)
    _progressLabel($progress, "Dismissing disclaimer");
    return _progressFail($progress, "disclaimer dismiss did not confirm")
        if !_dismissPEGDialog($this, $win, $PHASE_CLOSE);
    _progressTick($progress);
    return 1;
}


sub _resetE80
    # VESTIGIAL (see banner above) -- the live flows call _issueReboot instead. Reboot the E80
    # cleanly and bring it back to a usable state unattended: watchdog reset, wait for the service,
    # then find + dismiss the disclaimer. Four ticks. Does NOT init $progress (the caller owns the
    # total) so it composes as the tail of clear / restore as well as standing alone. Returns 1/0.
{
    my ($this, $progress) = @_;
    return 0 if !_reboot($this, $progress);
    return 0 if !_dismissDisclaimer($this, $progress);
    display($dbg_reset, 0, "_resetE80: complete (reset + reacquire + dismiss)");
    return 1;
}


#---------------------------------------------------------
# Wire helpers shared by the FS / flob walks
#---------------------------------------------------------

sub _peekBytes
    # Peek $n raw bytes from device memory at $addr, chunked into <= $POKE_CHUNK reads.
    # Returns the raw byte string, or undef on any failed chunk.
{
    my ($this, $addr, $n) = @_;
    my $out = '';
    my $off = 0;
    while ($off < $n)
    {
        my $m = $n - $off;
        $m = $POKE_CHUNK if $m > $POKE_CHUNK;
        my $hex = _txn($this, $SUBOP_PEEK, $addr + $off, $m);
        return undef if !defined($hex) || length($hex) != 2 * $m;
        $out .= pack('H*', $hex);
        $off += $m;
    }
    return $out;
}


sub _validPtr
    # True if $p is a plausible aligned heap/image pointer (peek-safe to deref). Mirrors the
    # validity gate the durable diag scripts use for the store / tree walks.
{
    my ($p) = @_;
    return 0 if !defined($p);
    return 0 if $p & 3;
    return 0 if $p < $PTR_LO || $p > $PTR_HI;
    return 0 if $p == $PTR_POISON;
    return 1;
}


#---------------------------------------------------------
# Named-file (\local) FS accessor -- gestalt layers 1 and 3
#---------------------------------------------------------

sub _localStat
    # STAT a \local file by path. Returns the status word (bit31 set = not found), or undef on no reply.
{
    my ($this, $path) = @_;
    _poke($this, $SCRATCH_PATH, $path . "\x00");
    return _call($this, $FSACC_STAT, $FSACC, $SCRATCH_PATH);
}


sub _localExists
    # True if the \local file STATs ok.
{
    my ($this, $path) = @_;
    my $st = _localStat($this, $path);
    return (defined($st) && !($st & 0x80000000)) ? 1 : 0;
}


sub _localSize
    # Logical size (bytes) of a \local file, or undef on no reply. 0 if the file is unwritten/empty.
{
    my ($this, $path) = @_;
    _poke($this, $SCRATCH_PATH, $path . "\x00");
    _poke($this, $SCRATCH_SIZE, pack('V', 0xabababab));    # sentinel: untouched cell == empty
    _call($this, $FSACC_SIZE, $FSACC, $SCRATCH_PATH, $SCRATCH_SIZE);
    my $sz = _peek1($this, $SCRATCH_SIZE);
    return undef if !defined($sz);
    return 0 if $sz == 0xabababab;
    return $sz;
}


sub _localRead
    # Read a whole \local file by path and return its raw bytes ('' if empty), or undef if the file
    # is missing / unreadable. STAT-guards, GET-SIZEs, then reads the file in <= $POKE_CHUNK pieces at
    # successive offsets (the proven read_pageset recipe -- a single whole-file READ can short-copy),
    # peeking each piece back out of scratch.
{
    my ($this, $path) = @_;
    my $st = _localStat($this, $path);
    return undef if !defined($st) || ($st & 0x80000000);
    my $size = _localSize($this, $path);
    return undef if !defined($size);
    return '' if $size == 0;

    my $data = '';
    my $off  = 0;
    while ($off < $size)
    {
        my $chunk = $size - $off;
        $chunk = $POKE_CHUNK if $chunk > $POKE_CHUNK;
        _poke($this, $SCRATCH_PATH, $path . "\x00");
        _poke($this, $SCRATCH_LEN,  pack('V', $chunk));
        _call($this, $FSACC_READ, $FSACC, $SCRATCH_PATH, $off, $SCRATCH_BUF, $SCRATCH_LEN);
        my $copied = _peek1($this, $SCRATCH_LEN);
        return undef if !defined($copied) || $copied != $chunk;
        my $piece = _peekBytes($this, $SCRATCH_BUF, $chunk);
        return undef if !defined($piece);
        $data .= $piece;
        $off  += $chunk;
    }
    return $data;
}


sub _localWrite
    # Write raw $bytes into a \local file by path at $off (default 0), via the FS-accessor WRITE
    # vmethod. By default the file must STAT ok (overwrite in place); pass $create to write a path
    # that does not STAT. Stages the bytes into scratch (chunked pokes) then one WRITE call.
    # Returns 1 on success (ret bit31 clear), 0 otherwise.
{
    my ($this, $path, $bytes, $off, $create) = @_;
    $off = 0 if !defined($off);
    _poke($this, $SCRATCH_PATH, $path . "\x00");
    my $st = _localStat($this, $path);
    if (!defined($st))
    {
        display($dbg_local, 1, "STAT no reply for $path");
        return 0;
    }
    if (($st & 0x80000000) && !$create)
    {
        display($dbg_local, 1, sprintf("STAT not-found 0x%08x for $path (no create)", $st));
        return 0;
    }

    # write in <= $POKE_CHUNK pieces at successive offsets (a single large WRITE can short-copy, the
    # same way a whole-file READ does); the first piece creates the file, later pieces extend it.
    my $len = length($bytes);
    my $o = 0;
    while ($o < $len)
    {
        my $m = $len - $o;
        $m = $POKE_CHUNK if $m > $POKE_CHUNK;
        _poke($this, $SCRATCH_PATH, $path . "\x00");
        _poke($this, $SCRATCH_BUF, substr($bytes, $o, $m));
        _poke($this, $SCRATCH_LEN, pack('V', $m));
        my $ret = _call($this, $FSACC_WRITE, $FSACC, $SCRATCH_PATH, $off + $o, $SCRATCH_BUF, $SCRATCH_LEN);
        if (!defined($ret) || ($ret & 0x80000000))
        {
            display($dbg_local, 1, sprintf("WRITE %s off %d -> %s",
                $path, $off + $o, defined($ret) ? sprintf("0x%08x", $ret) : "(none)"));
            return 0;
        }
        $o += $m;
    }
    display($dbg_local, 1, sprintf("wrote %s off %d (%d bytes) in <=%d-byte pieces", $path, $off, $len, $POKE_CHUNK));
    return 1;
}


sub _findSubdir
    # The live child dir-object named $name directly under dir-object $dir, or undef.
{
    my ($this, $dir, $name) = @_;
    for my $e (_treeEntries($this, $dir, $DIR_SUBDIR_OFF))
    {
        return $e->[1] if lc($e->[0]) eq lc($name) && _validPtr($e->[1]);
    }
    return undef;
}


sub _localMkdir
    # Ensure every directory component of the \local DIR path $path exists (no trailing file name),
    # creating any missing component with the in-dir subdir creator called DIRECTLY on the live parent
    # object (fsAccessor_createSubdirInDir). The firmware's by-path createDirByPath wrapper RETURNS ok
    # but creates nothing over the diag channel, so we walk + create level by level ourselves. Once a
    # dir exists, _localWrite's own STAT vivifies the file. Returns 1/0. Proven on E80-2 (2026-06).
{
    my ($this, $path) = @_;
    my $dir = _peek1($this, $FSACC + $TREE_ROOT_OFF);
    return 0 if !_validPtr($dir);
    for my $name (grep { $_ ne '' } split(/\\/, $path))
    {
        my $child = _findSubdir($this, $dir, $name);
        if (!defined($child))
        {
            _poke($this, $SCRATCH_PATH, $name . "\x00");
            my $r = _call($this, $FS_MKSUBDIR, $dir, $SCRATCH_PATH);
            return 0 if !defined($r) || ($r & 0x80000000);
            $child = _findSubdir($this, $dir, $name);
            return 0 if !defined($child);     # created but not findable -> bail, don't write blind
        }
        $dir = $child;
    }
    return 1;
}


#---------------------------------------------------------
# \local cached directory tree -- discover live window-selector files
#   (STAT-by-path is authoritative; the cached tree can LAG NOR after writes,
#    so we use the tree only to ENUMERATE candidates and STAT each to confirm)
#---------------------------------------------------------

sub _treeNode
    # Read one \local dir-tree node (0x18 bytes). Returns {left,parent,right,name,value,isnil} or undef.
{
    my ($this, $n) = @_;
    return undef if !_validPtr($n);
    my $b = _peekBytes($this, $n, 0x18);
    return undef if !defined($b) || length($b) < 0x18;
    my @w = unpack('V6', $b);
    return {
        left   => $w[0],
        parent => $w[1],
        right  => $w[2],
        name   => $w[3],
        value  => $w[4],
        isnil  => ($w[5] >> 8) & 0xff };
}


sub _treeName
    # Decode a NUL-terminated, printable directory/file name at $p ('' if unreadable).
{
    my ($this, $p) = @_;
    return '' if !_validPtr($p);
    my $b = _peekBytes($this, $p, 48);
    return '' if !defined($b);
    $b =~ s/\x00.*//s;
    $b =~ s/[^\x20-\x7e]//g;
    return $b;
}


sub _treeInorder
    # In-order accumulation of [name, value] entries of one std::_Tree into @$out. $head = nil sentinel.
{
    my ($this, $n, $head, $out) = @_;
    return if @$out > $TREE_NODECAP;
    return if !_validPtr($n) || $n == $head;
    my $f = _treeNode($this, $n);
    return if !$f || $f->{isnil};
    _treeInorder($this, $f->{left}, $head, $out);
    push(@$out, [ _treeName($this, $f->{name}), $f->{value} ]);
    _treeInorder($this, $f->{right}, $head, $out);
}


sub _treeEntries
    # In-order [name, value] entries of the std::_Tree whose _Myhead sits at $dir+$off.
{
    my ($this, $dir, $off) = @_;
    return () if !_validPtr($dir);
    my $head = _peek1($this, $dir + $off);
    return () if !_validPtr($head);
    my $hf = _treeNode($this, $head);
    return () if !$hf;
    my @out;
    _treeInorder($this, $hf->{parent}, $head, \@out);   # root = header->_Parent
    return @out;
}


sub _collectSlotDirs
    # Recurse the dir tree from $dir (full path $prefix) collecting the full paths of every
    # directory named slot<PSPGWW> (6 hex digits). Depth-capped, cycle-guarded.
{
    my ($this, $dir, $prefix, $depth, $seen, $out) = @_;
    return if $depth > $TREE_DEPTHCAP;
    return if $seen->{$dir}++;
    for my $se (_treeEntries($this, $dir, $DIR_SUBDIR_OFF))
    {
        my ($name, $child) = @$se;
        next if $name eq '' || !_validPtr($child);
        my $path = $prefix . "\\" . $name;
        push(@$out, $path) if $name =~ /^slot[0-9a-fA-F]{6}$/;
        _collectSlotDirs($this, $child, $path, $depth + 1, $seen, $out);
    }
}


sub _localSelectors
    # Discover every per-window panel-selector in \local: walk the cached dir tree for slot<PSPGWW>
    # directories, then STAT-confirm <slotdir>\CInstrumentatio0.lp and read its 1-byte value.
    # Returns a list of { ps, pg, win, path, value }.
{
    my ($this, $progress) = @_;
    my $root = _peek1($this, $FSACC + $TREE_ROOT_OFF);
    return () if !_validPtr($root);
    my @dirs;
    my %seen;
    _collectSlotDirs($this, $root, '', 0, \%seen, \@dirs);
    _progressAddTotal($progress, scalar(@dirs)) if $progress;     # dir count known after the walk

    my @sel;
    _progressLabel($progress, "Scanning selectors") if $progress;
    for my $dir (@dirs)
    {
        _progressTick($progress) if $progress;       # advance the bar (one tick per slot dir)
        my $path = $dir . "\\" . $SELECTOR_FILE;
        next if !_localExists($this, $path);
        my $raw = _localRead($this, $path);
        next if !defined($raw) || length($raw) < 1;
        my ($hex) = ($dir =~ /slot([0-9a-fA-F]{6})$/);
        push(@sel, {
            ps    => hex(substr($hex, 0, 2)),
            pg    => hex(substr($hex, 2, 2)),
            win   => hex(substr($hex, 4, 2)),
            path  => $path,
            value => ord(substr($raw, 0, 1)) });
    }
    return @sel;
}


#---------------------------------------------------------
# Keyed flob store -- gestalt layer 2 (panelsets)
#---------------------------------------------------------

sub _flobNode
    # Read one RB-tree node ($NODE_SIZE bytes). Returns {left,right,key=[4],len,id,recptr,isnil} or undef.
{
    my ($this, $n) = @_;
    return undef if !_validPtr($n);
    my $b = _peekBytes($this, $n, $NODE_SIZE);
    return undef if !defined($b) || length($b) < $NODE_SIZE;
    return {
        left   => unpack('V', substr($b, $NODE_LEFT, 4)),
        right  => unpack('V', substr($b, $NODE_RIGHT, 4)),
        key    => [ unpack('v4', substr($b, $NODE_KEY, 8)) ],
        len    => unpack('v', substr($b, $NODE_LEN, 2)),
        id     => unpack('V', substr($b, $NODE_ID, 4)),
        recptr => unpack('V', substr($b, $NODE_REC, 4)),
        isnil  => unpack('C', substr($b, $NODE_NIL, 1)) };
}


sub _flobInorder
{
    my ($this, $n, $head, $out, $progress) = @_;
    return if @$out > $FLOB_NODECAP;
    return if !_validPtr($n) || $n == $head;
    my $f = _flobNode($this, $n);
    return if !$f || $f->{isnil};
    _flobInorder($this, $f->{left}, $head, $out, $progress);
    push(@$out, { key => $f->{key}, len => $f->{len}, id => $f->{id}, recptr => $f->{recptr} });
    _progressTick($progress) if $progress && @$out % 10 == 0;    # advance the bar (one tick per 10 records)
    _flobInorder($this, $f->{right}, $head, $out, $progress);
}


sub _flobEnumerate
    # Enumerate the keyed flob store's RB-tree (in-order, peek-only, node-capped). Returns a list of
    #   { key => [owner0, owner1, type, key3], len, id, recptr }   sorted lexicographically by key.
    # Each node is a separate peek (~13s for a full store). The record count is known up front
    # (FS+0x38), so we add one tick per 10 records to the TOTAL and then ADVANCE done as we walk --
    # the bar genuinely moves AND the label shows the running count.
{
    my ($this, $progress) = @_;
    my $head = _peek1($this, $FLOB + $FLOB_HEAD_OFF);
    return () if !_validPtr($head);
    my $count = _peek1($this, $FLOB + $FLOB_SIZE_OFF) || 0;
    _progressAddTotal($progress, int($count / 10)) if $progress;     # one scan tick per 10 records
    my $root = _peek1($this, $head + 4);                # header->_Parent = root
    my @recs;
    _flobInorder($this, $root, $head, \@recs, $progress);
    display($dbg_flob, 1, "flob: enumerated " . scalar(@recs) . " records");
    return @recs;
}


sub _flobReadByKey
    # Read the body of keyed record {owner0,owner1,type,key3} of $len bytes. Returns raw bytes or undef.
{
    my ($this, $keyref, $len) = @_;
    _poke($this, $SCRATCH_PATH, pack('v4', @$keyref));      # key buffer
    _poke($this, $SCRATCH_OUTID, pack('V', 0xabababab));
    my $ret = _call($this, $FLOB_READKEY, $FLOB, $SCRATCH_OUTID, $SCRATCH_PATH, $SCRATCH_BUF, $len);
    return undef if !defined($ret) || $ret != $FLOB_OK;
    return _peekBytes($this, $SCRATCH_BUF, $len);
}


sub _flobWriteByKey
    # Create-or-supersede keyed record {owner...} with record-id $id and $bytes. Returns 1/0.
{
    my ($this, $keyref, $id, $bytes) = @_;
    my $len = length($bytes);
    _poke($this, $SCRATCH_PATH, pack('v4', @$keyref));
    my $o = 0;
    while ($o < $len)
    {
        my $m = $len - $o;
        $m = $POKE_CHUNK if $m > $POKE_CHUNK;
        _poke($this, $SCRATCH_BUF + $o, substr($bytes, $o, $m));
        $o += $m;
    }
    my $ret = _call($this, $FLOB_WRITEKEY, $FLOB, $id, $SCRATCH_PATH, $SCRATCH_BUF, $len);
    if (!defined($ret) || $ret != $FLOB_OK)
    {
        display($dbg_flob, 1, sprintf("flob writeByKey %04x %04x %04x %04x -> %s",
            @$keyref, defined($ret) ? sprintf("0x%08x", $ret) : "(none)"));
        return 0;
    }
    display($dbg_flob, 1, sprintf("flob writeByKey %04x %04x %04x %04x  id 0x%x  len %d -> ok",
        @$keyref, $id, $len));
    return 1;
}


sub _flobDeleteByKey
    # Delete (supersede-out) keyed record {owner...}. deleteByKey(FS, keyPtr, 0, 0): param3 is unused
    # in the delete path, param4 is a backend context passed 0. Returns 1/0.
{
    my ($this, $keyref) = @_;
    _poke($this, $SCRATCH_PATH, pack('v4', @$keyref));
    my $ret = _call($this, $FLOB_DELKEY, $FLOB, $SCRATCH_PATH, 0, 0);
    if (!defined($ret) || $ret != $FLOB_OK)
    {
        display($dbg_flob, 1, sprintf("flob deleteByKey %04x %04x %04x %04x -> %s",
            @$keyref, defined($ret) ? sprintf("0x%08x", $ret) : "(none)"));
        return 0;
    }
    display($dbg_flob, 1, sprintf("flob deleteByKey %04x %04x %04x %04x -> ok", @$keyref));
    return 1;
}


#---------------------------------------------------------
# Owner resolution / panel classification / key allocation
#---------------------------------------------------------

sub _deviceOwner
    # Resolve the unit's own owner-id [owner0, owner1] from the live store: the modal {key[0],key[1]}
    # across all records (native records dominate). This is the owner the panelset find-scan is
    # scoped to (canonical source SysInfo+0x50; enumeration is used so no extra image anchor is needed
    # and it works on any populated unit). Pass a pre-fetched record list to avoid re-enumerating.
    # Returns [k0, k1] or undef.
{
    my ($this, @recs) = @_;
    @recs = _flobEnumerate($this) if !@recs;
    return undef if !@recs;
    my %count;
    for my $r (@recs)
    {
        $count{ sprintf("%04x:%04x", $r->{key}[0], $r->{key}[1]) }++;
    }
    my ($top) = sort { $count{$b} <=> $count{$a} } keys %count;
    my ($k0, $k1) = map { hex($_) } split(/:/, $top);
    return [ $k0, $k1 ];
}


sub _ownerIdString
    # The conventional owner-id string "%04x%04x" of [owner0, owner1] (e.g. "b280ad37").
{
    my ($k0, $k1) = @_;
    return sprintf("%04x%04x", $k0, $k1);
}


sub _panelClass
    # Classify a panelset body by its leading 0x010100dX header (dX low nibble routes the RayCom leaf
    # class). Returns 'data' / 'engine' / 'cdi', or undef if the header does not match.
{
    my ($body) = @_;
    return undef if length($body) < 4;
    my ($b0, $b1, $b2, $b3) = unpack('C4', substr($body, 0, 4));
    return undef if !(($b0 & 0xf0) == 0xd0 && $b1 == 0x00 && $b2 == 0x01 && $b3 == 0x01);
    my $dx = $b0 & 0x0f;
    return ($dx <= $#PANEL_CLASS) ? $PANEL_CLASS[$dx] : undef;
}


sub _panelRecords
    # Select the keyed records that are real panelset GRIDS for $owner: id 0x04 AND a full-size body.
    # id 0x04 alone also tags many small instrument-settings records, so len discriminates here; the
    # dX body header is the final confirm when each record is actually read/classified.
{
    my ($owner, @recs) = @_;
    return grep {
                   $_->{id} == $PANEL_ID
                && $_->{len} >= $PANEL_MIN_LEN
                && $_->{key}[0] == $owner->[0]
                && $_->{key}[1] == $owner->[1]
               } @recs;
}


sub _allocKeys
    # Allocate $n collision-safe keyed-store keys for pre-writing panelsets onto the target unit.
    # A key is [owner_id:32][value:32]; the 32-bit value is ONE monotonic odometer per owner (the
    # "type"/"key3" halves are just its high/low 16 bits) -- it only ever climbs and never reuses.
    # Rule: take the LOWEST empty 0x10000 (one-epoch) window that has an occupied epoch above it --
    # i.e. the lowest free 64K window below the frontier, which the odometer will never descend into
    # -- and hand out values from the bottom of that window upward. Waypoints (id 0x01, or simply not
    # owner_id-prefixed) don't count toward which epochs are occupied, but their exact values are
    # still avoided. Presumes the store has settled after a reset (owner records present).
    # Returns a list of [owner0, owner1, hi16, lo16] ($n of them), or () if no safe window exists.
{
    my ($this, $owner, $n, @recs) = @_;
    @recs = _flobEnumerate($this) if !@recs;
    my ($k0, $k1) = @$owner;

    my %occ;            # ALL our-owner values -- never place on top of one (incl. owner-prefixed WGRTs)
    my %epoch;          # epochs (value >> 16) holding an our-owner CONFIG record (waypoints excluded)
    for my $r (@recs)
    {
        next if $r->{key}[0] != $k0 || $r->{key}[1] != $k1;     # our owner_id only
        my $v = ($r->{key}[2] << 16) | $r->{key}[3];
        $occ{$v} = 1;
        $epoch{ $r->{key}[2] } = 1 if $r->{id} != 0x01;         # id 0x01 = waypoint -> not a config mark
    }
    my @occupied = sort { $a <=> $b } keys %epoch;
    return () if !@occupied;                                    # store not settled -- no owner config yet
    my $frontier = $occupied[-1];

    # the lowest epoch below the frontier that holds no config record -> fill it from the bottom up
    for (my $e = 0; $e < $frontier; $e++)
    {
        next if $epoch{$e};
        my @keys;
        my $base = $e << 16;
        for (my $v = $base; $v < $base + 0x10000 && @keys < $n; $v++)
        {
            push(@keys, [ $k0, $k1, ($v >> 16) & 0xffff, $v & 0xffff ]) if !$occ{$v};
        }
        return @keys if @keys >= $n;
    }
    return ();
}


#---------------------------------------------------------
# Gestalt-folder I/O (hex-text artifacts + JSON manifest)
#---------------------------------------------------------

sub _writeHexFile
    # Write raw $bytes to $file as a single hex-text line. Returns 1/0.
{
    my ($file, $bytes) = @_;
    open(my $fh, '>', $file) or return 0;
    binmode($fh);
    print $fh unpack('H*', $bytes), "\n";
    close($fh);
    return 1;
}


sub _readHexFile
    # Read a hex-text file written by _writeHexFile and return the raw bytes, or undef.
{
    my ($file) = @_;
    open(my $fh, '<', $file) or return undef;
    binmode($fh);
    local $/;
    my $hex = <$fh>;
    close($fh);
    return undef if !defined($hex);
    $hex =~ s/\s//g;
    return undef if $hex eq '' || $hex !~ /^[0-9a-fA-F]+$/ || length($hex) % 2;
    return pack('H*', $hex);
}


sub _jsonStr
    # JSON-escape and quote a string.
{
    my ($s) = @_;
    $s = '' if !defined($s);
    $s =~ s/([\\"])/\\$1/g;
    $s =~ s/\n/\\n/g;
    $s =~ s/\r/\\r/g;
    $s =~ s/\t/\\t/g;
    $s =~ s/([\x00-\x1f])/sprintf('\\u%04x', ord($1))/ge;
    return '"' . $s . '"';
}


sub _toJson
    # Minimal pretty JSON encoder for the manifest. Handles hashref (key order via a '__order' list),
    # arrayref, and scalars (bare integers, else quoted strings).
{
    my ($val, $indent) = @_;
    $indent = 0 if !defined($indent);
    my $pad  = '  ' x $indent;
    my $pad1 = '  ' x ($indent + 1);
    if (ref($val) eq 'HASH')
    {
        my @keys = $val->{__order} ? @{$val->{__order}} : sort keys %$val;
        @keys = grep { $_ ne '__order' } @keys;
        return "{}" if !@keys;
        my @lines = map { $pad1 . _jsonStr($_) . ": " . _toJson($val->{$_}, $indent + 1) } @keys;
        return "{\n" . join(",\n", @lines) . "\n" . $pad . "}";
    }
    if (ref($val) eq 'ARRAY')
    {
        return "[]" if !@$val;
        my @lines = map { $pad1 . _toJson($_, $indent + 1) } @$val;
        return "[\n" . join(",\n", @lines) . "\n" . $pad . "]";
    }
    return "null" if !defined($val);
    return $val if $val =~ /^-?\d+\z/;
    return _jsonStr($val);
}


sub _writeManifest
    # Write the manifest hashref to $folder/e80Config.json. Returns 1/0.
{
    my ($folder, $manifest) = @_;
    open(my $fh, '>', "$folder/$MANIFEST_FILE") or return 0;
    binmode($fh);
    print $fh _toJson($manifest, 0), "\n";
    close($fh);
    return 1;
}


sub _isoTime
    # Current UTC time as an ISO-8601 stamp, for the manifest.
{
    my @t = gmtime(time());
    return sprintf("%04d-%02d-%02dT%02d:%02d:%02dZ",
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}


sub _countFolder
    # (selector-file count, panelset-file count) in a gestalt folder, for the progress total.
{
    my ($folder) = @_;
    opendir(my $dh, $folder) or return (0, 0);
    my @f = readdir($dh);
    closedir($dh);
    my $nsel   = grep { /^pageset\d+_page\d+_window\d+\.txt$/ } @f;
    my $npanel = grep { /^panelset_.*\.txt$/ } @f;
    return ($nsel, $npanel);
}


#---------------------------------------------------------
# Session ctor / dtor
#---------------------------------------------------------

sub _open
    # Open a session to the E80 at $ip: bind the whitelisted UDP reply port and return a $this
    # session hashref { sock, ip, reply_port }, or undef (with error()) on failure.
{
    my ($ip) = @_;
    my $sock = IO::Socket::INET->new(
        LocalPort => $REPLY_PORT,
        Proto     => 'udp',
        Timeout   => 2 );
    if (!$sock)
    {
        error("navE80Config: cannot bind UDP reply port $REPLY_PORT: $!");
        return undef;
    }
    return { sock => $sock, ip => $ip, reply_port => $REPLY_PORT };
}


sub _close
    # Close a session opened by _open.
{
    my ($this) = @_;
    $this->{sock}->close() if $this && $this->{sock};
}


#---------------------------------------------------------
# Mid-level gestalt operations ($this-based)
#---------------------------------------------------------

sub _saveE80
    # Read the full config gestalt off the live unit into $folder (READ-ONLY). Captures:
    #   layer 1 -- the 5 page-set blocks (pageset0..4.txt) + the active-set header (pagesets.meta.hex)
    #   layer 2 -- the keyed panelsets (panelset_<class>.txt, body-only, classified by dX)
    #   layer 3 -- the per-window selectors (pageset<ps>_page<pg>_window<win>.txt, 1 byte each)
    # plus e80Config.json. Honors {cancelled}. Returns 1/0.
{
    my ($this, $folder, $progress) = @_;
    _progressInit($progress, $PAGESET_COUNT + 1);    # static ticks (5 page sets + manifest); grows as discovered

    _progressLabel($progress, "Reading store records");
    my @recs   = _flobEnumerate($this, $progress);
    my $owner  = _deviceOwner($this, @recs);
    return _progressFail($progress, "cannot resolve device owner (empty store?)") if !$owner;
    my @panels = _panelRecords($owner, @recs);
    my @selectors = _localSelectors($this, $progress);
    _progressAddTotal($progress, scalar(@panels) + scalar(@selectors));    # panelset reads + selector writes
    display($dbg_save, 0, sprintf("_saveE80: %d store records, owner %s, %d panelsets, %d selectors",
        scalar(@recs), _ownerIdString(@$owner), scalar(@panels), scalar(@selectors)));

    if (!-d $folder)
    {
        my_mkdir($folder) or return _progressFail($progress, "cannot create folder $folder");
    }

    # ---- layer 1: page sets ----
    _progressLabel($progress, "Reading page sets");
    my $cmain = _localRead($this, $PAGESETS_PATH);
    return _progressFail($progress, "cannot read $PAGESETS_PATH") if !defined($cmain);
    my @blocks;
    for my $i (0 .. $PAGESET_COUNT - 1)
    {
        return _progressFail($progress, "cancelled") if _progressCancelled($progress);
        my $off = $PAGESET_BASE + $i * $PAGESET_LEN;
        my $blk = substr($cmain, $off, $PAGESET_LEN);
        _writeHexFile("$folder/pageset$i.txt", $blk)
            or return _progressFail($progress, "cannot write pageset$i.txt");
        my $id   = (length($blk) >= $PAGESET_IDOFF + 4)   ? unpack('V', substr($blk, $PAGESET_IDOFF, 4)) : 0;
        my $name = (length($blk) >= $PAGESET_NAMEOFF + 25) ? substr($blk, $PAGESET_NAMEOFF, 25) : '';
        $name =~ s/\x00.*//s;
        $name =~ s/[^\x20-\x7e]//g;
        push(@blocks, { __order => ['index','name','id'], index => $i, name => $name, id => $id });
        _progressTick($progress);          # one tick per page set
    }
    # bytes outside the 5 blocks (8-byte header + any tail) carry the active page set
    my $tailoff = $PAGESET_BASE + $PAGESET_COUNT * $PAGESET_LEN;
    my $meta    = substr($cmain, 0, $PAGESET_BASE)
                . ((length($cmain) > $tailoff) ? substr($cmain, $tailoff) : '');
    _writeHexFile("$folder/pagesets.meta.hex", $meta);

    # ---- layer 2: panelsets ----
    my @panelmeta;
    my %seenclass;
    for my $r (@panels)
    {
        _progressLabel($progress, "Reading panelsets");
        return _progressFail($progress, "cancelled") if _progressCancelled($progress);
        my $body = _flobReadByKey($this, $r->{key}, $r->{len});
        if (!defined($body))
        {
            display($dbg_save, 1, sprintf("panelset %04x %04x %04x %04x unreadable -- skipped", @{$r->{key}}));
            _progressTick($progress);
            next;
        }
        my $class = _panelClass($body) || 'unknown';
        my $nth   = ++$seenclass{$class};
        my $file  = ($nth > 1) ? "panelset_${class}_$nth.txt" : "panelset_${class}.txt";
        _writeHexFile("$folder/$file", $body)
            or return _progressFail($progress, "cannot write $file");
        push(@panelmeta, { __order => ['class','file','type','key3','len'],
                           class => $class, file => $file,
                           type  => sprintf("0x%04x", $r->{key}[2]),
                           key3  => sprintf("0x%04x", $r->{key}[3]),
                           len   => $r->{len} });
        _progressTick($progress);
    }

    # ---- layer 3: per-window selectors ----
    my @selmeta;
    for my $s (@selectors)
    {
        _progressLabel($progress, "Reading window selectors");
        return _progressFail($progress, "cancelled") if _progressCancelled($progress);
        my $file = sprintf("pageset%d_page%d_window%d.txt", $s->{ps}, $s->{pg}, $s->{win});
        _writeHexFile("$folder/$file", chr($s->{value}));
        push(@selmeta, { __order => ['pageset','page','window','value','file'],
                         pageset => $s->{ps}, page => $s->{pg}, window => $s->{win},
                         value   => $s->{value}, file => $file });
        _progressTick($progress);
    }

    # ---- manifest ----
    _progressLabel($progress, "Writing manifest");
    my $ownerid = _ownerIdString(@$owner);
    my $manifest = {
        __order => ['tool','format_version','machine_name','owner_id','device_ip','captured',
                    'page_sets','panelsets','selectors'],
        tool           => 'navE80Config',
        format_version => $FORMAT_VERSION,
        machine_name   => ($MACHINE_NAME{$ownerid} || ''),
        owner_id       => $ownerid,
        device_ip      => $this->{ip},
        captured       => _isoTime(),
        page_sets      => \@blocks,
        panelsets      => \@panelmeta,
        selectors      => \@selmeta };
    _writeManifest($folder, $manifest)
        or return _progressFail($progress, "cannot write manifest");
    _progressTick($progress);

    display($dbg_save, 0, sprintf("_saveE80: saved %d page sets, %d panelsets, %d selectors to %s",
        $PAGESET_COUNT, scalar(@panelmeta), scalar(@selmeta), $folder));
    return 1;
}


sub _defaultCMainApp0Lp
    # Factory-default CMainApp0.lp (3009 B), captured from a reset E80-2.
    # The 5 default page sets; generic (class GUIDs, not the owner-id).
    # clear() writes it to reset gestalt layer 1 (page sets) to factory state.
{
    my $hex =
        '110000000000000031323334000000000000cc333f010000bb00000000000000' .
        '0100000020d192f5f24cf649aeb6362397ba4fc3000000000000000000000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '000000003f010000bb00000080020000780100000133cc333132333400000000' .
        '0000cc333f010000bb00000000000000010000004402a04264e3944cb91f075a' .
        '35c4a7c700000000000000000000000000000000000000000000000000000000' .
        '00000000000000000000000000000000000000003f010000bb00000080020000' .
        '780100000133cc3331343a32330000000000cc333f010000bb00000000000000' .
        '0200000020d192f5f24cf649aeb6362397ba4fc33d18f159966398438e5dadd4' .
        'e1eda25900000000000000000000000000000000000000000000000000000000' .
        '000000003f010000bb00000080020000780100000133cc3331343a3233000000' .
        '0000cc333f010000bb000000000000000200000020d192f5f24cf649aeb63623' .
        '97ba4fc3c753cb302caaeb4a90ee34e5ad7affb8000000000000000000000000' .
        '00000000000000000000000000000000000000003f010000bb00000080020000' .
        '780100000133cc3331343a32330000000000cc333f010000bb00000000000000' .
        '0200000020d192f5f24cf649aeb6362397ba4fc34402a04264e3944cb91f075a' .
        '35c4a7c700000000000000000000000000000000000000000000000000000000' .
        '000000003f010000bb00000080020000780100000133cc330000000000000000' .
        '4e617669676174696f6e00000000000000000000000000000033cc3328000100' .
        '31343a323300cc33cc33cc330000000000000000000000000200000072f839b9' .
        'ab51244d887e766c61b3860220d192f5f24cf649aeb6362397ba4fc300000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '0000000000000000000000000133cc3331343a323300cc33cc33cc3300000000' .
        '0000000000000000020000004402a04264e3944cb91f075a35c4a7c74402a042' .
        '64e3944cb91f075a35c4a7c70000000000000000000000000000000000000000' .
        '000000000000000000000000000000000000000000000000000000000133cc33' .
        '31343a323a330033cc33cc33000000000000000000000000030000004402a042' .
        '64e3944cb91f075a35c4a7c720d192f5f24cf649aeb6362397ba4fc3c672ffe6' .
        'e583ed4db309431281fa82e30000000000000000000000000000000000000000' .
        '0000000000000000000000000133cc3331343a323a330000cc33cc3300000000' .
        '00000000000000000300000020d192f5f24cf649aeb6362397ba4fc3ea4c6570' .
        '44e67d4a90b83856220f9dddc672ffe6e583ed4db309431281fa82e300000000' .
        '000000000000000000000000000000000000000000000000000000000133cc33' .
        '31343a323300cc33cc33cc330000000000000000000000000200000072f839b9' .
        'ab51244d887e766c61b386024402a04264e3944cb91f075a35c4a7c700000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '0000000000000000000000000133cc330000000001000000536974756174696f' .
        '6e616c2041776172656e6573730000000033cc331e000100313233340033cc33' .
        'cc33cc3300000000000000000000000001000000c672ffe6e583ed4db3094312' .
        '81fa82e300000000000000000000000000000000000000000000000000000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '000000000133cc3331323a333400cc33cc33cc33000000000000000000000000' .
        '0200000020d192f5f24cf649aeb6362397ba4fc3c672ffe6e583ed4db3094312' .
        '81fa82e300000000000000000000000000000000000000000000000000000000' .
        '00000000000000000000000000000000000000000133cc333132333400330033' .
        'cc33cc3300000000000000000000000001000000c1d70afa70878d44af036e0f' .
        'a894de7a00000000000000000000000000000000000000000000000000000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '000000000133cc3331323334003a3400cc33cc33000000000000000000000000' .
        '01000000ea4c657044e67d4a90b83856220f9ddd000000000000000000000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '00000000000000000000000000000000000000000133cc3331343a323a330033' .
        'cc33cc330000000000000000000000000300000020d192f5f24cf649aeb63623' .
        '97ba4fc3c1d70afa70878d44af036e0fa894de7aea4c657044e67d4a90b83856' .
        '220f9ddd00000000000000000000000000000000000000000000000000000000' .
        '000000000133cc330000000002000000426f61742053797374656d7300000000' .
        '00000000000000000033cc331f000100313233340033cc33cc33cc3300000000' .
        '0000000000000000010000008205c2766e9e1141800f524d832ae54900000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '000000000000000000000000000000000000000000000000000000000133cc33' .
        '31343a323300cc33cc33cc330000000000000000000000000200000020d192f5' .
        'f24cf649aeb6362397ba4fc372f839b9ab51244d887e766c61b3860200000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '0000000000000000000000000133cc33313a323a33340033cc33cc3300000000' .
        '00000000000000000300000020d192f5f24cf649aeb6362397ba4fc34402a042' .
        '64e3944cb91f075a35c4a7c78205c2766e9e1141800f524d832ae54900000000' .
        '000000000000000000000000000000000000000000000000000000000133cc33' .
        '31323a3334003400cc33cc33000000000000000000000000020000003d18f159' .
        '966398438e5dadd4e1eda2598205c2766e9e1141800f524d832ae54900000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '0000000000000000000000000133cc3331343a323300cc33cc33cc3300000000' .
        '0000000000000000020000008205c2766e9e1141800f524d832ae5494402a042' .
        '64e3944cb91f075a35c4a7c70000000000000000000000000000000000000000' .
        '000000000000000000000000000000000000000000000000000000000133cc33' .
        '000000000300000046697368696e670000000000000000000000000000000000' .
        '0033cc3320000100313233340033cc33cc33cc33000000000000000000000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '00000000000000000000000000000000000000000133cc3331323a333400cc33' .
        'cc33cc3300000000000000000000000000000000000000000000000000000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '000000000133cc3331343a3233000033cc33cc33000000000000000000000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '00000000000000000000000000000000000000000133cc33313a323a333a3400' .
        'cc33cc3300000000000000000000000000000000000000000000000000000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '000000000133cc33313a323a33340033cc33cc33000000000000000000000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '0000000000000000000000000000000000000000000000000000000000000000' .
        '00000000000000000000000000000000000000000133cc330000000004000000' .
        '437573746f6d0000000000000000000000000000000000000033cc3310000100' .
        '01';
    return pack('H*', $hex);
}


sub _clearE80
    # Reboot-free clear of the custom config (the pre-fetched $panels / $selectors come from the
    # caller's pre-scan so the progress total is exact and the work matches what was counted):
    #   layer 2 -- deleteByKey every owner-scoped panelset (apps re-mint defaults at boot).
    #   layer 3 -- reset each present per-window selector to the default panel (0).
    # Layer 1 (page sets) is reset by the CALLER, not here: clearE80Config writes the factory-default
    # CMainApp0.lp and restore writes the SAVED CMainApp0.lp -- so _clearE80 stays layers 2+3 and
    # restore avoids a wasted default-pageset write before its own.
    # Honors {cancelled}. Returns 1/0. (clearE80Config pairs this with _issueReboot so the result shows after boot.)
{
    my ($this, $progress, $panels, $selectors) = @_;

    _progressLabel($progress, "Deleting panelsets");
    for my $r (@$panels)
    {
        return _progressFail($progress, "cancelled") if _progressCancelled($progress);
        _flobDeleteByKey($this, $r->{key})
            or return _progressFail($progress, sprintf("deleteByKey failed for %04x %04x %04x %04x", @{$r->{key}}));
        _progressTick($progress);
    }

    _progressLabel($progress, "Resetting window selectors");
    for my $s (@$selectors)
    {
        return _progressFail($progress, "cancelled") if _progressCancelled($progress);
        _localWrite($this, $s->{path}, "\x00", 0)
            or display($dbg_clear, 1, "could not reset selector $s->{path}");
        _progressTick($progress);
    }

    display($dbg_clear, 0, sprintf("_clearE80: deleted %d panelsets, reset %d selectors",
        scalar(@$panels), scalar(@$selectors)));
    return 1;
}


sub _writeE80
    # Overlay a saved gestalt folder onto the unit (the write half of restore -- does NOT reboot):
    #   layer 1 -- reconstruct CMainApp0.lp = meta header + pageset0..4 blocks + meta tail.
    #   layer 3 -- each pageset<ps>_page<pg>_window<win>.txt -> its \local slot selector.
    #   layer 2 -- each panelset_<class>.txt at an allocator-chosen safe key (dX routes the class).
    # $owner and $recs are the caller's pre-clear scan -- the allocator's lowest-empty-epoch choice is
    # unaffected by the panelset deletes (they sit at the frontier; we place far below it) and
    # delete-before-write covers any residual, so we do NOT re-enumerate. Honors {cancelled}. 1/0.
{
    my ($this, $folder, $progress, $owner, $recs) = @_;
    my @recs = @$recs;

    # ---- layer 1: page sets (one faithful whole-file write) ----
    _progressLabel($progress, "Writing page sets");
    my $meta = _readHexFile("$folder/pagesets.meta.hex");
    return _progressFail($progress, "missing pagesets.meta.hex in $folder") if !defined($meta);
    my $cmain = substr($meta, 0, $PAGESET_BASE);
    for my $i (0 .. $PAGESET_COUNT - 1)
    {
        my $blk = _readHexFile("$folder/pageset$i.txt");
        return _progressFail($progress, "missing pageset$i.txt in $folder") if !defined($blk);
        $cmain .= $blk;
    }
    $cmain .= substr($meta, $PAGESET_BASE) if length($meta) > $PAGESET_BASE;
    _localWrite($this, $PAGESETS_PATH, $cmain, 0)
        or return _progressFail($progress, "cannot write $PAGESETS_PATH");
    _progressTick($progress);
    return _progressFail($progress, "cancelled") if _progressCancelled($progress);

    # ---- layer 3: per-window selectors ----
    opendir(my $dh1, $folder) or return _progressFail($progress, "cannot open $folder");
    my @selfiles = sort grep { /^pageset\d+_page\d+_window\d+\.txt$/ } readdir($dh1);
    closedir($dh1);
    for my $f (@selfiles)
    {
        return _progressFail($progress, "cancelled") if _progressCancelled($progress);
        my ($ps, $pg, $win) = $f =~ /^pageset(\d+)_page(\d+)_window(\d+)\.txt$/;
        my $bytes = _readHexFile("$folder/$f");
        next if !defined($bytes) || length($bytes) < 1;
        my $dir  = sprintf("\\local\\slot%02X%02X%02X", $ps, $pg, $win);   # firmware buildPath is %02X
        my $path = "$dir\\$SELECTOR_FILE";
        _progressLabel($progress, "Writing window selectors");
        # create the slot dir if absent (createSubdirInDir-direct); once it exists, _localWrite's STAT
        # vivifies the 0-length file, then the WRITE fills it. Both steps are now FATAL on failure.
        _localMkdir($this, $dir)
            or return _progressFail($progress, "cannot create slot dir $dir");
        _localWrite($this, $path, $bytes, 0, 1)
            or return _progressFail($progress, "cannot write selector $path");
        _progressTick($progress);
    }

    # ---- layer 2: panelsets at allocator-chosen safe keys ----
    opendir(my $dh2, $folder) or return _progressFail($progress, "cannot open $folder");
    my @panelfiles = sort grep { /^panelset_.*\.txt$/ } readdir($dh2);
    closedir($dh2);
    my @keys = _allocKeys($this, $owner, scalar(@panelfiles), @recs);
    return _progressFail($progress, "cannot allocate " . scalar(@panelfiles)
            . " safe keys (store not settled after reset?)")
        if @keys < @panelfiles;
    my $ki = 0;
    for my $f (@panelfiles)
    {
        return _progressFail($progress, "cancelled") if _progressCancelled($progress);
        my $body = _readHexFile("$folder/$f");
        next if !defined($body);
        _progressLabel($progress, "Writing panelsets");
        my $key = $keys[$ki++];
        _flobDeleteByKey($this, $key);          # clean slate at the target key before writing
        _flobWriteByKey($this, $key, $PANEL_ID, $body)
            or return _progressFail($progress, "writeByKey failed for $f");
        _progressTick($progress);
    }

    display($dbg_restore, 0, sprintf("_writeE80: wrote page sets + %d selectors + %d panelsets",
        scalar(@selfiles), scalar(@panelfiles)));
    return 1;
}



1;


# end of navE80Config.pm
