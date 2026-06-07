#!/usr/bin/perl
#-------------------------------------------------------------------------
# nmE80DirectOps.pm
#-------------------------------------------------------------------------
# navMate-side orchestration for the "direct" E80 operations that drive a live
# unit over its diagnostic network channel: configuration save / restore / clear
# (e80Config) and live screen capture (e80ScreenGrab).  Each wraps its on-device
# cleanroom library with the navMate layer: device selection (RAYDP FILESYS),
# folder / file selection and validation, a worker thread driving a
# Pub::WX::ProgressDialog, and a success confirmation.  The same cores are reachable
# headlessly through apiOp() (/api/e80config) and apiGrab() (/api/e80grab).
#
# Two front-ends, one core:
#   - interactive (menu): _doInteractive -> pickers/dialogs -> _launch (worker + dialog)
#   - headless (/api):    apiOp / apiGrab -> direct blocking library call on the HTTP thread
#
# See docs/e80_config.md and e80ScreenGrab_API.md.

package nmE80DirectOps;
use strict;
use warnings;
use threads;
use threads::shared;
use JSON::PP qw(decode_json);
use Wx qw(:everything);
use Pub::Utils qw(display getAppFrame);
use Pub::WX::Dialogs;
use apps::raymarine::NET::a_defs qw(%KNOWN_SERVER_IPS);
use apps::raymarine::NET::c_RAYDP;
use e80Config;
use e80ScreenGrab;

my $dbg = 0;

# session default for the directory dialog (the configuration library); remembered in memory only
my $CONFIG_LIBRARY = 'C:/dat/Rhapsody/E80Configs';
my $last_folder    = $CONFIG_LIBRARY;

# session default for the screen-grab file dialog (separate from the config library, per request);
# remembered in memory only.  The library my_mkdir's the parent on write, so it need not pre-exist.
my $GRAB_LIBRARY   = 'C:/dat/Rhapsody/E80Screens';
my $last_grab_dir  = $GRAB_LIBRARY;

# the configuration manifest (written last by a successful save).  Its presence is the
# practical marker (the folder is a config); its validity is the formal check.
my $MANIFEST_FILE = 'e80Config.json';

# one direct E80 op at a time -- the config library binds a single fixed reply port and clear/restore
# reboot the unit, and the interactive path has one pending-success slot and one ProgressDialog.
# Guards interactive-vs-api and api-vs-api across threads.  (Screen grab is read-only and needs no
# exclusivity for correctness, but it shares the guard so the single-dialog discipline holds.)
my $op_busy :shared = 0;

# interactive success pending: { progress, message, frame, op }.  Set when an interactive op
# launches; nmFrame::onIdle calls onIdle() which raises the okDialog once the ProgressDialog
# has closed cleanly.  Main-thread only, so not shared.
my $pending_success;


#-------------------------------------------------------
# device discovery / naming
#-------------------------------------------------------

sub filesysDevices
    # Live E80 units advertising the RAYDP FILESYS service, as ({ip, device_id}, ...) sorted by
    # ip.  Every E80 advertises FILESYS, so this is the reliable target list.
{
    my $raydp = apps::raymarine::NET::c_RAYDP::getRayDP();
    return () if !$raydp;
    my $ports = $raydp->getServicePortsByAddr();
    return () if !$ports;
    my @devs;
    for my $addr (keys %$ports)
    {
        my $sp = $ports->{$addr};
        next if !$sp || ($sp->{name} // '') ne 'FILESYS';
        my $ip = $sp->{ip};
        $ip = $1 if !$ip && $addr =~ /^([^:]+):/;       # fall back to the addr's ip half
        next if !$ip;
        push(@devs, { ip => $ip, device_id => $sp->{device_id} // '' });
    }
    @devs = sort { $a->{ip} cmp $b->{ip} } @devs;   # not "return sort ..." -- sort in scalar context is undef
    return @devs;
}


sub deviceCount
{
    return scalar(filesysDevices());
}


sub deviceLabel
    # Colloquial name for $ip from a_defs, else the RAYDP device id in parentheses.
{
    my ($ip, $device_id) = @_;
    return $KNOWN_SERVER_IPS{$ip} if $ip && $KNOWN_SERVER_IPS{$ip};
    return "($device_id)" if defined($device_id) && $device_id ne '';
    return "($ip)";
}


#-------------------------------------------------------
# folder identification / validation
#-------------------------------------------------------

sub _manifestPath
    # The path of the configuration manifest in $folder, or undef if not present.
{
    my ($folder) = @_;
    my $path = "$folder/$MANIFEST_FILE";
    return -f $path ? $path : undef;
}


sub isConfigPractical
    # Quick recognition: a folder holding the manifest (e80Config.json).
{
    my ($folder) = @_;
    return -f "$folder/$MANIFEST_FILE" ? 1 : 0;
}


sub readManifest
    # Parse the configuration manifest, or undef if missing / unparseable / not ours.
{
    my ($folder) = @_;
    my $path = _manifestPath($folder);
    return undef if !$path;
    my $text = '';
    if (open(my $fh, '<', $path))
    {
        local $/;
        $text = <$fh>;
        close($fh);
    }
    return undef if !defined($text) || $text eq '';
    my $mf = eval { decode_json($text) };
    return undef if !$mf || ref($mf) ne 'HASH';
    return undef if ($mf->{tool} // '') ne 'e80Config';
    return $mf;
}


sub validateConfigFormal
    # 1 if $folder is a valid configuration: manifest present, ours, and a supported version.
{
    my ($folder) = @_;
    my $mf = readManifest($folder);
    return 0 if !$mf;
    return 0 if (($mf->{format_version} // 0) + 0) < 1;
    return 1;
}


sub _dirEntries
    # The non-dot entries of $folder.
{
    my ($folder) = @_;
    return () if !-d $folder;
    opendir(my $dh, $folder) or return ();
    my @e = grep { $_ ne '.' && $_ ne '..' } readdir($dh);
    closedir($dh);
    return @e;
}


sub _clearFolder
    # Delete every file in a (validated) configuration folder, in its entirety, so the save
    # writes into an empty directory.  Returns 1 if the folder ends up empty, else 0.
{
    my ($folder) = @_;
    for my $e (_dirEntries($folder))
    {
        my $p = "$folder/$e";
        unlink($p) if -f $p;
    }
    my @rem = _dirEntries($folder);
    return (scalar(@rem) == 0) ? 1 : 0;
}


sub _prepareSaveFolder
    # Enforce the save-destination policy on $folder.  Returns ('ok') to proceed, or
    # ('refused', $reason) to abort.  An empty folder proceeds; a non-empty non-configuration
    # folder is refused; a non-empty configuration is cleared in full after confirmation
    # ($suppress skips the confirm; $frame is the dialog parent).
{
    my ($folder, $suppress, $frame) = @_;
    my @rem = _dirEntries($folder);
    return ('ok') if !@rem;

    if (!validateConfigFormal($folder))
    {
        return ('refused', "The folder is not empty and is not an E80 configuration -- refusing to overwrite it.");
    }

    if (!$suppress)
    {
        my $mf  = readManifest($folder);
        my $who = $mf ? ($mf->{machine_name} || $mf->{owner_id} || 'unknown') : 'unknown';
        my $yes = yesNoDialog($frame,
            "'$folder' already holds a saved E80 configuration (from $who).\n\n"
            . "Saving will permanently overwrite its ENTIRE contents.\n\nContinue?",
            "Overwrite Configuration");
        return ('refused', 'cancelled') if !$yes;
    }

    return ('refused', "Could not clear the existing configuration folder.") if !_clearFolder($folder);
    return ('ok');
}


#-------------------------------------------------------
# message composition
#-------------------------------------------------------

sub _sourceIdFromManifest
    # The 'source of the format' identity for a restore message, from the manifest.
{
    my ($folder) = @_;
    my $mf = readManifest($folder);
    return '?' if !$mf;
    return $mf->{machine_name} if ($mf->{machine_name} // '') ne '';
    my $oid = $mf->{owner_id} // '';
    return $oid ne '' ? "($oid)" : '?';
}


sub _folderName
{
    my ($folder) = @_;
    my $name = $folder // '';
    $name =~ s{[\\/]+$}{};
    $name =~ s{.*[\\/]}{};
    return $name;
}


sub successMessage
{
    my ($op, $folder, $source_id, $target_id) = @_;
    my $name = _folderName($folder);
    return "Configuration '$name' ($source_id) saved to $folder"       if $op eq 'save';
    return "Configuration '$name' ($source_id) restored to $target_id" if $op eq 'restore';
    return "Configuration cleared on $target_id"                       if $op eq 'clear';
    return "Screen captured from $target_id to $folder"                if $op eq 'grab';
    return '';
}


#-------------------------------------------------------
# single-op guard
#-------------------------------------------------------

sub _acquire
    # Test-and-set the single-op guard.  Returns 1 if acquired, 0 if already busy.
{
    lock($op_busy);
    return 0 if $op_busy;
    $op_busy = 1;
    return 1;
}


sub _release
{
    lock($op_busy);
    $op_busy = 0;
}


#-------------------------------------------------------
# interactive entry points (menu)
#-------------------------------------------------------

sub doSave    { _doInteractive($_[0], 'save'); }
sub doRestore { _doInteractive($_[0], 'restore'); }
sub doClear   { _doInteractive($_[0], 'clear'); }
sub doGrab    { _doInteractive($_[0], 'grab'); }


sub _doInteractive
{
    my ($frame, $op) = @_;
    $frame ||= getAppFrame();

    if (Pub::WX::ProgressDialog::isActive() || $op_busy)
    {
        okDialog($frame, "Another operation is in progress -- please wait.", "E80 Configuration");
        return;
    }

    my $dev = _pickDevice($frame);
    return if !$dev;
    my $target_id = deviceLabel($dev->{ip}, $dev->{device_id});
    my $source_id = $target_id;             # for save, the source IS the live unit

    my $folder;
    if ($op eq 'save' || $op eq 'restore')
    {
        $folder = _pickFolder($frame, $op);
        return if !defined($folder);

        if ($op eq 'save')
        {
            my ($status, $reason) = _prepareSaveFolder($folder, $nmDialogs::suppress_confirm, $frame);
            if ($status ne 'ok')
            {
                okDialog($frame, $reason, "Save Configuration")
                    if $reason ne 'cancelled' && !$nmDialogs::suppress_confirm;
                return;
            }
        }
        else
        {
            if (!validateConfigFormal($folder))
            {
                okDialog($frame, "'$folder' is not a valid E80 configuration (no manifest).", "Restore Configuration")
                    if !$nmDialogs::suppress_confirm;
                return;
            }
            $source_id = _sourceIdFromManifest($folder);
        }
    }
    elsif ($op eq 'grab')
    {
        $folder = _pickPngFile($frame);     # $folder carries the destination .png path for grab
        return if !defined($folder);
    }
    else        # clear
    {
        if (!$nmDialogs::suppress_confirm)
        {
            my $yes = yesNoDialog($frame,
                "Reset the E80 display configuration on $target_id to factory defaults and reboot it?",
                "Clear Configuration");
            return if !$yes;
        }
    }

    my $message = successMessage($op, $folder // '', $source_id, $target_id);
    _launch($frame, $op, $dev->{ip}, $folder, $message);
}


sub _pickDevice
    # 0 devices -> error + undef; 1 -> that device; 2+ -> a chooser.  Returns {ip,device_id} or undef.
{
    my ($frame) = @_;
    my @devs = filesysDevices();
    if (!@devs)
    {
        okDialog($frame, "No E80 is reachable on the network.", "E80 Configuration");
        return undef;
    }
    return $devs[0] if @devs == 1;

    my @labels = map { deviceLabel($_->{ip}, $_->{device_id}) . "  --  $_->{ip}" } @devs;
    my $dlg = Wx::SingleChoiceDialog->new($frame, "Select the target E80:", "E80 Configuration", \@labels);
    my $sel = ($dlg->ShowModal() == wxID_OK) ? $dlg->GetSelection() : -1;
    $dlg->Destroy();
    return ($sel >= 0) ? $devs[$sel] : undef;
}


sub _pickFolder
    # wxDirDialog rooted at the remembered library folder.  Returns a forward-slashed path or undef.
{
    my ($frame, $op) = @_;
    my $prompt = ($op eq 'save')
        ? "Choose or create a folder to save the configuration into:"
        : "Choose a saved configuration folder to restore from:";
    # 3-arg form: rely on wxDirDialog's default style (includes the New Folder button) so we
    # do not depend on wxDD_* constants being exported here.
    my $dlg = Wx::DirDialog->new($frame, $prompt, $last_folder);
    my $path  = ($dlg->ShowModal() == wxID_OK) ? $dlg->GetPath() : undef;
    $dlg->Destroy();
    if (defined($path))
    {
        $path =~ s{\\}{/}g;             # normalize (library + our checks build "$folder/file")
        $last_folder = $path;
    }
    return $path;
}


sub _pickPngFile
    # wxFileDialog (Save) rooted at the remembered grab directory.  Returns a forward-slashed path
    # or undef; the ".png" extension is left for the library to append if the user omits it.
{
    my ($frame) = @_;
    my $dlg = Wx::FileDialog->new(
        $frame, "Save the E80 screen capture as:",
        $last_grab_dir, '',
        "PNG image (*.png)|*.png|All files (*.*)|*.*",
        wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
    my $path = ($dlg->ShowModal() == wxID_OK) ? $dlg->GetPath() : undef;
    $last_grab_dir = $dlg->GetDirectory() if defined($path);    # remember for next time
    $dlg->Destroy();
    $path =~ s{\\}{/}g if defined($path);                       # normalize (library builds the path)
    return $path;
}


sub _launch
    # Spawn the worker thread that runs the (blocking) library op behind a ProgressDialog, and
    # arm the success confirmation that nmFrame::onIdle raises once the dialog closes cleanly.
{
    my ($frame, $op, $ip, $folder, $message) = @_;

    return if !_acquire();          # defensive against a double-launch race

    my $progress = Pub::WX::ProgressDialog::newProgressData(0, 1);   # workers=1: close on worker-done
    $progress->{active} = 1;

    my $title = ($op eq 'save')    ? "Saving E80 Configuration..."
              : ($op eq 'restore') ? "Restoring E80 Configuration..."
              : ($op eq 'grab')    ? "Capturing E80 Screen..."
              :                      "Clearing E80 Configuration...";

    my $dlg = Pub::WX::ProgressDialog->new($frame, $title, 1, $progress);
    if (!$dlg)
    {
        _release();
        return;
    }

    $pending_success = { progress => $progress, message => $message, frame => $frame, op => $op };

    display($dbg, 0, "nmE80DirectOps::_launch($op,$ip,".($folder // '-').")");

    threads->create(sub {
        my $ok =
            ($op eq 'save')    ? saveE80Config($ip, $folder, $progress) :
            ($op eq 'restore') ? restoreE80Config($ip, $folder, $progress) :
            ($op eq 'grab')    ? grabE80Screen($ip, $folder, $progress) :
                                 clearE80Config($ip, $progress);
        $progress->{workers} = 0;    # success -> dialog auto-closes; failure already set {error} -> terminal
        _release();
    })->detach();
}


sub onIdle
    # Called from nmFrame::onIdle every cycle.  Raises the success confirmation for an
    # interactive op once its ProgressDialog has fully closed without error or cancel.
{
    my ($frame) = @_;
    return if !$pending_success;
    return if Pub::WX::ProgressDialog::isActive();      # dialog still up -> not finished

    my $p = $pending_success;
    $pending_success = undef;

    my $progress = $p->{progress};
    my $clean = ($progress && !($progress->{error} // '') && !($progress->{cancelled} // 0)) ? 1 : 0;
    if ($clean && !$nmDialogs::suppress_confirm)
    {
        okDialog($p->{frame} || $frame, $p->{message}, "E80 Configuration");
    }
}


#-------------------------------------------------------
# headless entry (/api/e80config, /api/e80grab)
#-------------------------------------------------------

sub apiOp
    # Run save/restore/clear directly (blocking) on the calling (HTTP) thread, with no dialogs.
    # Returns { ok => 1, message => ... } or { error => ... }.
{
    my ($op, $ip, $folder) = @_;
    $op = '' if !defined($op);
    $ip = '' if !defined($ip);

    return { error => "unknown op '$op'" } if $op ne 'save' && $op ne 'restore' && $op ne 'clear';
    return { error => 'missing ip' }       if $ip eq '';
    return { error => 'missing folder' }    if ($op eq 'save' || $op eq 'restore') && (!defined($folder) || $folder eq '');

    $folder =~ s{\\}{/}g if defined($folder);

    return { error => 'another E80 direct operation is in progress' } if !_acquire();

    # device identity for the message: match the ip against the live FILESYS set for a device id
    my $device_id = '';
    for my $d (filesysDevices()) { if ($d->{ip} eq $ip) { $device_id = $d->{device_id}; last; } }
    my $target_id = deviceLabel($ip, $device_id);

    if ($op eq 'save')
    {
        my ($status, $reason) = _prepareSaveFolder($folder, 1, undef);
        if ($status ne 'ok')
        {
            _release();
            return { error => $reason };
        }
    }
    elsif ($op eq 'restore')
    {
        if (!validateConfigFormal($folder))
        {
            _release();
            return { error => "'$folder' is not a valid E80 configuration (no manifest)" };
        }
    }

    my $source_id = ($op eq 'restore') ? _sourceIdFromManifest($folder) : $target_id;

    my $progress = Pub::WX::ProgressDialog::newProgressData(0);   # no dialog reads it; library mutates it
    $progress->{active} = 1;

    my $ok = eval {
        ($op eq 'save')    ? saveE80Config($ip, $folder, $progress) :
        ($op eq 'restore') ? restoreE80Config($ip, $folder, $progress) :
                             clearE80Config($ip, $progress);
    };
    _release();

    return { ok => 1, message => successMessage($op, $folder // '', $source_id, $target_id) } if $ok;
    return { error => ($progress->{error} || "$op failed") };
}


sub apiGrab
    # Headless screen capture for /api/e80grab, blocking on the calling (HTTP) thread, no dialogs.
    # With $path: write the PNG to $path and return { ok => 1, message => ..., path => ... }.
    # Without $path: capture in memory and return { png => <PNG bytes> } for the caller to stream
    # as image/png (no file written).  { error => ... } on failure.
{
    my ($ip, $path) = @_;
    $ip = '' if !defined($ip);
    return { error => 'missing ip' } if $ip eq '';

    return { error => 'another E80 direct operation is in progress' } if !_acquire();

    # device identity for the message: match the ip against the live FILESYS set for a device id
    my $device_id = '';
    for my $d (filesysDevices()) { if ($d->{ip} eq $ip) { $device_id = $d->{device_id}; last; } }
    my $target_id = deviceLabel($ip, $device_id);

    my $progress = Pub::WX::ProgressDialog::newProgressData(0);   # no dialog reads it; library mutates it
    $progress->{active} = 1;

    my $result;
    if (defined($path) && $path ne '')
    {
        $path =~ s{\\}{/}g;
        my $ok = eval { grabE80Screen($ip, $path, $progress); };
        $path .= '.png' if $path !~ /\.png$/i;      # mirror the library's append for the reported path
        $result = $ok
            ? { ok => 1, message => successMessage('grab', $path, $target_id, $target_id), path => $path }
            : { error => ($progress->{error} || 'grab failed') };
    }
    else
    {
        my $image = eval { grabE80ScreenImage($ip, $progress); };
        my $png   = $image ? encodeE80Png($image) : undef;
        $result = defined($png)
            ? { png => $png }
            : { error => ($progress->{error} || 'grab failed') };
    }
    _release();
    return $result;
}


1;
