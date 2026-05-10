#!/usr/bin/perl
#------------------------------------------
# navSelection.pm
#------------------------------------------
# Named selection sets for the winDatabase tree.
# File: $temp_dir/navMateSelection.json  (JSON object: name -> [uuid,...])
# Written whenever a named set is saved or deleted (explicit user action only).
# Loaded at startup; NOT applied to the tree automatically.
# NOT saved at program exit -- lifecycle save/restore is for visibility/outline only.

package navSelection;
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use Pub::Utils qw(display error $temp_dir);


BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(
		loadSelectionSets
		getSelectionSetNames
		getSelectionSet
		putSelectionSet
		deleteSelectionSet
	);
}


my %selection_sets;


sub _stateFile { return "$temp_dir/navMateSelection.json" }


sub loadSelectionSets
{
	my $file = _stateFile();
	%selection_sets = ();
	if (-f $file)
	{
		my $raw = do { local $/; open(my $fh, '<:raw', $file) or die $!; <$fh> };
		my $h = eval { decode_json($raw) };
		%selection_sets = ($h && ref $h eq 'HASH') ? %$h : ();
	}
	display(0, 0, 'navSelection: loaded ' . scalar(keys %selection_sets) . ' selection sets');
}


sub _saveSelectionSets
{
	my $file = _stateFile();
	my $json = encode_json(\%selection_sets);
	open(my $fh, '>:raw', $file) or do { error("navSelection: cannot write $file: $!"); return; };
	print $fh $json;
	close $fh;
}


sub getSelectionSetNames { return sort keys %selection_sets }

sub getSelectionSet
{
	my ($name) = @_;
	return $selection_sets{$name} // [];
}

sub putSelectionSet
{
	my ($name, $uuids_ref) = @_;
	$selection_sets{$name} = $uuids_ref;
	_saveSelectionSets();
	display(0, 0, "navSelection: saved '$name' (" . scalar(@$uuids_ref) . ' items)');
}

sub deleteSelectionSet
{
	my ($name) = @_;
	delete $selection_sets{$name};
	_saveSelectionSets();
}


1;