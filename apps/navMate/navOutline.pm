#!/usr/bin/perl
#------------------------------------------
# navOutline.pm
#------------------------------------------
# Persists the winDatabase tree expansion state.
# File: $temp_dir/navMateOutline.json  (JSON array of expanded collection UUIDs)
# Written at clean exit and by explicit Utils->Save Outline command.
# Loaded at program startup; applied to tree during winDatabase construction.

package navOutline;
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use Pub::Utils qw(display error $temp_dir);


BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(
		loadOutlineState
		saveOutlineState
		getExpandedUUIDs
		setExpandedUUIDs
	);
}


my @expanded_uuids;


sub _stateFile { return "$temp_dir/navMateOutline.json" }


sub loadOutlineState
{
	my $file = _stateFile();
	@expanded_uuids = ();
	if (-f $file)
	{
		my $raw = do { local $/; open(my $fh, '<:raw', $file) or die $!; <$fh> };
		my $arr = eval { decode_json($raw) };
		@expanded_uuids = ($arr && ref $arr eq 'ARRAY') ? @$arr : ();
	}
	display(0, 0, 'navOutline: loaded ' . scalar(@expanded_uuids) . ' expanded nodes');
}


sub saveOutlineState
{
	my $file = _stateFile();
	my $json = encode_json(\@expanded_uuids);
	open(my $fh, '>:raw', $file) or do { error("navOutline: cannot write $file: $!"); return; };
	print $fh $json;
	close $fh;
	display(0, 0, 'navOutline: saved ' . scalar(@expanded_uuids) . ' expanded nodes');
}


sub getExpandedUUIDs { return @expanded_uuids }

sub setExpandedUUIDs
{
	my ($ref) = @_;
	@expanded_uuids = (ref $ref eq 'ARRAY') ? @$ref : ();
}


1;