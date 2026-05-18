#!/usr/bin/perl
#------------------------------------------
# navVisibility.pm
#------------------------------------------
# Stores Leaflet map visibility state (which UUIDs are shown) for
# navMate DB objects, E80-DB objects, and FSH objects separately.
# State is persisted in $temp_dir/navMate.json.
# Written only at clean exit or by explicit save command.
#
# OBSERVER PATTERN
# ----------------
# Surfaces that display visibility state (tree checkboxes, editor
# checkboxes, winFind rows) register an observer closure here.  Any
# mutation of the visibility hashes fires a delta notification of the
# form { source => { uuid => new_value, ... }, ... } to every observer.
# new_value is 1 (visible) or 0 (hidden).
#
# This fixes the latent multi-instance winDatabase drift (two DB panes
# disagreeing about a row's checkbox state) as a byproduct, and is what
# lets winFind drive visibility from outside the source pane.
#
# BATCH MODE
# ----------
# Bulk callers (collection toggle, Clear Map, Show-on-Map over multi-
# selection, etc.) wrap their loops with beginBatch/endBatch.  All
# mutations inside the batch accumulate into a single delta hash; one
# notification fires per observer when the outermost endBatch closes.
# Single-item callers (one tree checkbox click) do not wrap -- they get
# one notification per call, naturally.
#
# Observer authors:  treat the delta hash as read-only.  Do not call
# back into navVisibility setters from inside the notification handler
# unless you really want a notification storm.

package navVisibility;
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use Pub::Utils qw(display warning error $temp_dir);


BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(
		loadViewState
		saveViewState
		pruneDbVisible
		getDbVisible
		setDbVisible
		batchSetDbVisible
		clearAllDbVisible
		getE80Visible
		setE80Visible
		clearAllE80Visible
		getAllE80VisibleUUIDs
		batchRemoveE80Visible
		getFSHVisible
		setFSHVisible
		clearAllFSHVisible
		getAllFSHVisibleUUIDs
		batchRemoveFSHVisible
		addVisibilityObserver
		removeVisibilityObserver
		beginVisibilityBatch
		endVisibilityBatch
	);
}


my %db_vis;
my %e80_vis;
my %fsh_vis;

my @observers;       # list of subref closures
my $batch_depth = 0;
my %batch_delta;     # { source => { uuid => new_value } }, accumulated during batch


sub _stateFile { return "$temp_dir/navMate.json" }


#----------------------------------
# observer registration
#----------------------------------

sub addVisibilityObserver
{
	my ($obs) = @_;
	push @observers, $obs;
	return $obs;
}


sub removeVisibilityObserver
{
	my ($obs) = @_;
	return if !$obs;
	@observers = grep { $_ != $obs } @observers;
}


sub beginVisibilityBatch
{
	$batch_depth++;
}


sub endVisibilityBatch
{
	return if $batch_depth <= 0;
	$batch_depth--;
	return if $batch_depth > 0;
	return if !%batch_delta;
	my %delta = %batch_delta;
	%batch_delta = ();
	$_->(\%delta) for @observers;
}


sub _notify
{
	my ($source, $uuid, $val) = @_;
	if ($batch_depth > 0)
	{
		$batch_delta{$source}{$uuid} = $val;
	}
	else
	{
		my %delta = ($source => { $uuid => $val });
		$_->(\%delta) for @observers;
	}
}


#----------------------------------
# load / save
#----------------------------------

sub loadViewState
{
	# Called at startup BEFORE any observers register.  No notifications
	# fire (no observers to notify) -- intentional.
	my $file = _stateFile();
	my %state;
	if (-f $file)
	{
		my $raw = do { local $/; open(my $fh, '<:raw', $file) or die $!; <$fh> };
		my $h = eval { decode_json($raw) };
		%state = ($h && ref $h eq 'HASH') ? %$h : ();
	}

	my $db = $state{db_visibility};
	%db_vis  = ($db  && ref $db  eq 'HASH') ? %$db  : ();

	my $e80 = $state{e80_visibility};
	%e80_vis = ($e80 && ref $e80 eq 'HASH') ? %$e80 : ();

	my $fsh = $state{fsh_visibility};
	%fsh_vis = ($fsh && ref $fsh eq 'HASH') ? %$fsh : ();

	display(0, 0, 'navVisibility: loaded ' . scalar(keys %db_vis) . ' db + ' . scalar(keys %e80_vis) . ' e80 + ' . scalar(keys %fsh_vis) . ' fsh visible objects');
}


sub saveViewState
{
	my $file = _stateFile();
	my $state = {
		db_visibility  => \%db_vis,
		e80_visibility => \%e80_vis,
		fsh_visibility => \%fsh_vis,
	};
	my $json = encode_json($state);
	open(my $fh, '>:raw', $file) or do { error("navVisibility: cannot write $file: $!"); return; };
	print $fh $json;
	close $fh;
	display(0, 0, 'navVisibility: saved view state');
}


#----------------------------------
# DB visibility
#----------------------------------

sub pruneDbVisible
{
	my ($live_ref) = @_;
	my @to_prune = grep { !$live_ref->{$_} } keys %db_vis;
	return if !@to_prune;
	beginVisibilityBatch();
	setDbVisible($_, 0) for @to_prune;
	endVisibilityBatch();
	my $pruned = scalar @to_prune;
	display(0, 0, "navVisibility: pruned $pruned stale entries (" . scalar(keys %db_vis) . " remain)") if $pruned;
}


sub getDbVisible
{
	my ($uuid) = @_;
	return ($uuid && $db_vis{$uuid}) ? 1 : 0;
}


sub setDbVisible
{
	my ($uuid, $val) = @_;
	return if !$uuid;
	my $new = $val ? 1 : 0;
	my $old = $db_vis{$uuid} ? 1 : 0;
	return if $new == $old;
	if ($new) { $db_vis{$uuid} = 1    }
	else      { delete $db_vis{$uuid} }
	_notify('db', $uuid, $new);
}


sub batchSetDbVisible
{
	my ($visible, $uuids_ref) = @_;
	return if !@$uuids_ref;
	beginVisibilityBatch();
	setDbVisible($_, $visible) for @$uuids_ref;
	endVisibilityBatch();
}


sub clearAllDbVisible
{
	my @uuids = keys %db_vis;
	return if !@uuids;
	beginVisibilityBatch();
	setDbVisible($_, 0) for @uuids;
	endVisibilityBatch();
}


#----------------------------------
# E80-DB visibility
#----------------------------------

sub getE80Visible
{
	my ($uuid) = @_;
	return ($uuid && $e80_vis{$uuid}) ? 1 : 0;
}


sub setE80Visible
{
	my ($uuid, $val) = @_;
	return if !$uuid;
	my $new = $val ? 1 : 0;
	my $old = $e80_vis{$uuid} ? 1 : 0;
	return if $new == $old;
	if ($new) { $e80_vis{$uuid} = 1    }
	else      { delete $e80_vis{$uuid} }
	_notify('e80', $uuid, $new);
}


sub clearAllE80Visible
{
	my @uuids = keys %e80_vis;
	return if !@uuids;
	beginVisibilityBatch();
	setE80Visible($_, 0) for @uuids;
	endVisibilityBatch();
}


sub getAllE80VisibleUUIDs { return keys %e80_vis }


sub batchRemoveE80Visible
{
	my ($uuids_ref) = @_;
	return if !@$uuids_ref;
	beginVisibilityBatch();
	setE80Visible($_, 0) for @$uuids_ref;
	endVisibilityBatch();
}


#----------------------------------
# FSH visibility
#----------------------------------

sub getFSHVisible
{
	my ($uuid) = @_;
	return ($uuid && $fsh_vis{$uuid}) ? 1 : 0;
}


sub setFSHVisible
{
	my ($uuid, $val) = @_;
	return if !$uuid;
	my $new = $val ? 1 : 0;
	my $old = $fsh_vis{$uuid} ? 1 : 0;
	return if $new == $old;
	if ($new) { $fsh_vis{$uuid} = 1    }
	else      { delete $fsh_vis{$uuid} }
	_notify('fsh', $uuid, $new);
}


sub clearAllFSHVisible
{
	my @uuids = keys %fsh_vis;
	return if !@uuids;
	beginVisibilityBatch();
	setFSHVisible($_, 0) for @uuids;
	endVisibilityBatch();
}


sub getAllFSHVisibleUUIDs { return keys %fsh_vis }


sub batchRemoveFSHVisible
{
	my ($uuids_ref) = @_;
	return if !@$uuids_ref;
	beginVisibilityBatch();
	setFSHVisible($_, 0) for @$uuids_ref;
	endVisibilityBatch();
}


1;
