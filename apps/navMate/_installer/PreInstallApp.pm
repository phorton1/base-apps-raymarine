#---------------------------------------------
# PreInstallApp.pm  (navMate)
#---------------------------------------------
# Run by Cava Packager after the build but BEFORE the Inno Setup compile.
# Cava (2.0, abandonware) emits an innosetup.iss for an older Inno Setup;
# this script rewrites it for the installed Inno Setup 5.5.9, which would
# otherwise fail the compile.  Modelled on apps/buddy/_installer/PreInstallApp.pm,
# trimmed to just the 5.5.9 compatibility fixups (navMate needs no PATH code).
#
# Cava invokes:   perl PreInstallApp.pm <release_dir> <installer_dir>
# The file rewritten is <installer_dir>/innosetup.iss.
#
# Fixups (each is an ISCC fatal under 5.5.9):
#   MinVersion=,<nt>           legacy two-part (9x,NT) form; 9x support was
#                              dropped in 5.5.x so the comma form is invalid.
#   OutputManifestFile=<path>  a path is no longer accepted; reduced to the
#                              bare filename (re-emitted in [Setup]).
#   [Languages] ...            Cava lists ~20 languages incl. Basque/Slovak
#                              whose .isl files no longer ship; the whole
#                              section is removed (default English messages).

use strict;
use warnings;

my $unused_release_dir = $ARGV[0];
my $installer_dir      = $ARGV[1];
my $iss_file           = "$installer_dir/innosetup.iss";

my $in_languages = 0;


sub processLine
{
	my ($line) = @_;

	# The [Languages] section runs to EOF; comment all of it out.
	if ($in_languages)
	{
		return $line =~ /\S/ ? "; $line" : $line;
	}
	if ($line eq '[Languages]')
	{
		$in_languages = 1;
		return "; [Languages] removed by PreInstallApp.pm ".
			"(Basque/Slovak .isl no longer ship in Inno 5.5.9)\n; $line";
	}

	# Re-emit the 5.5.9-safe directives right after the [Setup] header.
	if ($line eq '[Setup]')
	{
		return $line."\n".
			"; added by PreInstallApp.pm\n".
			"CloseApplications=force\n".
			"OutputManifestFile=innosetup.manifest";
	}

	# Drop the lines Inno 5.5.9 rejects.
	if ($line =~ /^MinVersion=/ ||         # legacy 9x,NT form -- invalid
		$line =~ /^OutputManifestFile=/)   # path form -- re-added bare in [Setup]
	{
		return "; commented by PreInstallApp.pm\n; $line";
	}

	return $line;
}


# Read, rewrite, write back.  No die/exit -- a failure just warns (Cava
# captures it) and leaves the file untouched.

my $in;
if (open($in, '<', $iss_file))
{
	my @lines = <$in>;
	close($in);

	my $text = '';
	for my $line (@lines)
	{
		chomp $line;
		$text .= processLine($line)."\n";
	}

	my $out;
	if (open($out, '>', $iss_file))
	{
		print $out $text;
		close($out);
		print "PreInstallApp: rewrote $iss_file for Inno 5.5.9\n";
	}
	else
	{
		warn "PreInstallApp: cannot write $iss_file: $!\n";
	}
}
else
{
	warn "PreInstallApp: cannot read $iss_file: $!\n";
}

1;
