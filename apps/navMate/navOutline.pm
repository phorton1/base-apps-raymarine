#!/usr/bin/perl
#------------------------------------------
# navOutline.pm
#------------------------------------------
# Persists tree expansion state for named panels.
# Labels: 'db' => nmDBOutline.json, 'fsh' => nmFSHOutline.json
# Call loadOutline($label) at startup, saveOutline($label) on exit.

package navOutline;
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);
use Pub::Utils qw(display error $temp_dir);


BEGIN
{
	use Exporter qw(import);
	our @EXPORT = qw(
		loadOutline
		saveOutline
		getExpanded
		setExpanded
	);
}


my %_expanded;


sub _file
{
	my ($label) = @_;
	if ($label eq 'db')
	{
		my $new = "$temp_dir/nmDBOutline.json";
		my $old = "$temp_dir/navMateOutline.json";
		return (-f $new || !-f $old) ? $new : $old;
	}
	if ($label eq 'fsh')
	{
		return "$temp_dir/nmFSHOutline.json";
	}
	return "$temp_dir/nmOutline_$label.json";
}


sub loadOutline
{
	my ($label) = @_;
	my $file = _file($label);
	$_expanded{$label} = [];
	if (-f $file)
	{
		my $raw = do { local $/; open(my $fh, '<:raw', $file) or die $!; <$fh> };
		my $arr = eval { decode_json($raw) };
		$_expanded{$label} = ($arr && ref $arr eq 'ARRAY') ? $arr : [];
	}
	display(0, 0, "navOutline($label): loaded " . scalar(@{$_expanded{$label}}) . ' expanded nodes');
}


sub saveOutline
{
	my ($label) = @_;
	my $file = _file($label);
	my $json = encode_json($_expanded{$label} // []);
	open(my $fh, '>:raw', $file) or do { error("navOutline: cannot write $file: $!"); return; };
	print $fh $json;
	close $fh;
	display(0, 0, "navOutline($label): saved " . scalar(@{$_expanded{$label}}) . ' expanded nodes');
}


sub getExpanded
{
	my ($label) = @_;
	return @{$_expanded{$label} // []};
}


sub setExpanded
{
	my ($label, $ref) = @_;
	$_expanded{$label} = (ref $ref eq 'ARRAY') ? $ref : [];
}


1;