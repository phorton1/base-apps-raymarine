#!/usr/bin/perl
#------------------------------------------
# navVisibility.pm
#------------------------------------------
# Stores Leaflet map visibility state (which UUIDs are shown) for
# navMate DB objects and E80-DB objects separately.
# State is persisted in $temp_dir/navMate.json.
# Written only at clean exit or by explicit save command.
#
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
	);
}


my %db_vis;
my %e80_vis;


sub _stateFile { return "$temp_dir/navMate.json" }


#----------------------------------
# load / save
#----------------------------------

sub loadViewState
{
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

	display(0, 0, 'navVisibility: loaded ' . scalar(keys %db_vis) . ' db + ' . scalar(keys %e80_vis) . ' e80 visible objects');
}


sub saveViewState
{
	my $file = _stateFile();
	my $state = {
		db_visibility  => \%db_vis,
		e80_visibility => \%e80_vis,
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
	my $before = scalar keys %db_vis;
	delete $db_vis{$_} for grep { !$live_ref->{$_} } keys %db_vis;
	my $pruned = $before - scalar(keys %db_vis);
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
	if ($val) { $db_vis{$uuid} = 1    }
	else      { delete $db_vis{$uuid} }
}


sub batchSetDbVisible
{
	my ($visible, $uuids_ref) = @_;
	return if !@$uuids_ref;
	for my $uuid (@$uuids_ref)
	{
		if ($visible) { $db_vis{$uuid} = 1    }
		else          { delete $db_vis{$uuid} }
	}
}


sub clearAllDbVisible { %db_vis = () }


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
	if ($val) { $e80_vis{$uuid} = 1    }
	else      { delete $e80_vis{$uuid} }
}


sub clearAllE80Visible { %e80_vis = () }


sub getAllE80VisibleUUIDs { return keys %e80_vis }


sub batchRemoveE80Visible
{
	my ($uuids_ref) = @_;
	return if !@$uuids_ref;
	delete $e80_vis{$_} for @$uuids_ref;
}


1;