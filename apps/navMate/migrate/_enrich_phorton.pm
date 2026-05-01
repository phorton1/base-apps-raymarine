#-----------------------------------------
# migrate/_enrich_phorton.pm
#-----------------------------------------
# Run from apps/navMate/ as: perl migrate/_enrich_phorton.pm
# Must run after _import_kml.pm.

package _enrich_phorton;
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use Time::Local qw(timegm);
use Pub::Utils;
use a_defs;
use a_utils;
use c_db;


my $MAP_DATA_DIR = 'C:/var/www/phorton/map_data';

# Map from map_index filename to the clean source name used in the DB.
my %MAP_INDEX_TO_SOURCE = (
	'RhapsodyLogs.map_index' => 'RhapsodyLogs',
	'MandalaLogs.map_index'  => 'MandalaLogs',
);


c_db::openDB();
_run();
display(0,0,"_enrich_phorton done");


#---------------------------------
# _run
#---------------------------------

sub _run
{
	for my $index_file (sort keys %MAP_INDEX_TO_SOURCE)
	{
		my $path   = "$MAP_DATA_DIR/$index_file";
		my $source = $MAP_INDEX_TO_SOURCE{$index_file};

		if (!-f $path)
		{
			warning("_enrich_phorton: not found: $path");
			next;
		}

		display(0,0,"enriching from $index_file -> $source");
		_enrichFromIndex($path, $source);
	}
}


#---------------------------------
# _enrichFromIndex
#---------------------------------

sub _enrichFromIndex
{
	my ($path, $source) = @_;
	my ($enriched, $already_stamped, $not_found, $no_tracks) = (0, 0, 0, 0);

	open(my $fh, '<:encoding(UTF-8)', $path)
		or die "_enrich_phorton: cannot open $path: $!";

	while (my $line = <$fh>)
	{
		chomp $line;
		# Split on first 6 commas; field[6] = description (may contain commas)
		my @f = split /,/, $line, 7;
		next if !(@f >= 6);

		# Story rows: f[1]='' (blank level sub-field), f[2]=date
		next if !($f[1] eq '' && $f[2] =~ /^\d{4}-\d{2}-\d{2}$/);

		my @track_names = grep { $_ ne '' } split /:/, $f[5];
		if (!@track_names)
		{
			$no_tracks++;
			next;
		}

		my $ts_start = _parseDate($f[2]);
		next if !$ts_start;

		for my $name (@track_names)
		{
			next if $name =~ /~$/;    # skip visual overlay references

			my $uuid = findTrackByNameAndSource($name);
			if (!$uuid)
			{
				display(0,1,"  not found: $name");
				$not_found++;
				next;
			}

			my $existing = getTrackTsSource($uuid);
			if ($existing eq $TS_SOURCE_IMPORT)
			{
				# No existing timestamp: set from phorton date
				updateTrackTimestamps($uuid, $ts_start, undef, $TS_SOURCE_PHORTON);
				$enriched++;
			}
			elsif ($existing eq $TS_SOURCE_KML_TIMESPAN)
			{
				# Already has precise UTC timestamps from KML; leave them alone
				$already_stamped++;
			}
			# ts_source='phorton' means already enriched on a prior run; skip
		}
	}

	close $fh;
	display(0,0,"  enriched=$enriched  already_stamped=$already_stamped  not_found=$not_found  no_tracks=$no_tracks");
}


#---------------------------------
# _parseDate
#---------------------------------

sub _parseDate
{
	my ($s) = @_;
	return 0 if !($s && $s =~ /^(\d{4})-(\d{2})-(\d{2})$/);
	return eval { timegm(0, 0, 0, $3, $2-1, $1-1900) } // 0;
}


1;
