#!/usr/bin/perl
#-----------------------------------------------------------------------
# gpsImport.pm -- import .gpx or .gdb files into a navMate collection
#-----------------------------------------------------------------------
# Supported formats:
#   .gpx  -- parsed directly
#   .gdb  -- converted to GPX via gpsbabel, then parsed
#
# Routes: each rtept becomes a full waypoint in the collection; the route
# record references those waypoints via route_waypoints. Same model as
# navMate's native routes.
#
# gpsbabel is optional. If not found, .gdb import returns an error.
# Default path: C:/Program Files/GPSBabel/gpsbabel.exe

package gpsImport;
use strict;
use warnings;
use Exporter 'import';
use POSIX qw(mktime);
use XML::Simple qw(:strict);
use Pub::Utils qw(display warning error);
use navDB;

our @EXPORT = qw(import_gps_file find_gpsbabel);

my $GPSBABEL_DEFAULT = 'C:/Program Files/GPSBabel/gpsbabel.exe';


sub find_gpsbabel
{
	return -f $GPSBABEL_DEFAULT ? $GPSBABEL_DEFAULT : undef;
}


sub _parse_iso8601
{
	my ($s) = @_;
	return undef unless defined $s;
	return undef unless $s =~ /(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/;
	return mktime($6, $5, $4, $3, $2-1, $1-1900);
}


sub _parse_gpx_text
{
	my ($text) = @_;
	my $xml = XML::Simple->new(
		ForceArray => ['trk','trkseg','trkpt','wpt','rte','rtept'],
		KeyAttr    => []);
	my $gpx = eval { $xml->XMLin($text) };
	if ($@)
	{
		warning(0,0,"gpsImport::_parse_gpx_text XML parse error: $@");
		return undef;
	}

	my @tracks;
	for my $trk (@{$gpx->{trk} // []})
	{
		my @pts;
		for my $seg (@{$trk->{trkseg} // []})
		{
			for my $pt (@{$seg->{trkpt} // []})
			{
				push @pts, {
					lat => $pt->{lat} + 0,
					lon => $pt->{lon} + 0,
					ts  => _parse_iso8601($pt->{time}),
				};
			}
		}
		next unless @pts;
		push @tracks, { name => $trk->{name} // 'Track', points => \@pts };
	}

	my @waypoints;
	for my $wpt (@{$gpx->{wpt} // []})
	{
		push @waypoints, {
			name    => $wpt->{name} // 'Waypoint',
			lat     => $wpt->{lat} + 0,
			lon     => $wpt->{lon} + 0,
			ts      => _parse_iso8601($wpt->{time}),
			comment => $wpt->{desc} // $wpt->{cmt} // '',
		};
	}

	my @routes;
	for my $rte (@{$gpx->{rte} // []})
	{
		my @pts;
		for my $pt (@{$rte->{rtept} // []})
		{
			push @pts, {
				name    => $pt->{name} // 'WP',
				lat     => $pt->{lat} + 0,
				lon     => $pt->{lon} + 0,
				comment => $pt->{desc} // $pt->{cmt} // '',
			};
		}
		next unless @pts;
		push @routes, { name => $rte->{name} // 'Route', points => \@pts };
	}

	return { tracks => \@tracks, waypoints => \@waypoints, routes => \@routes };
}


sub _max_item_pos
{
	my ($dbh, $coll_uuid) = @_;
	my $rec = $dbh->get_record(qq{
		SELECT MAX(max_p) AS p FROM (
			SELECT MAX(position) AS max_p FROM waypoints WHERE collection_uuid=?
			UNION ALL
			SELECT MAX(position) AS max_p FROM routes    WHERE collection_uuid=?
			UNION ALL
			SELECT MAX(position) AS max_p FROM tracks    WHERE collection_uuid=?
		) t},
		[$coll_uuid, $coll_uuid, $coll_uuid]);
	return $rec ? ($rec->{p} // 0) : 0;
}


sub import_gps_file
{
	my ($dbh, $file_path, $coll_uuid) = @_;

	my $gpx_text;
	my $tmp_file;

	if ($file_path =~ /\.gpx$/i)
	{
		open my $fh, '<', $file_path
			or return { error => "Cannot open $file_path: $!" };
		local $/;
		$gpx_text = <$fh>;
		close $fh;
	}
	elsif ($file_path =~ /\.gdb$/i)
	{
		my $gbs = find_gpsbabel();
		if (!$gbs)
		{
			return { error => "gpsbabel not found at $GPSBABEL_DEFAULT -- .gdb import unavailable" };
		}
		$tmp_file = ($ENV{TEMP} // $ENV{TMP} // 'C:/Windows/Temp') . "/navmate_gps_import_$$.gpx";
		my $cmd = qq{"$gbs" -i gdb -f "$file_path" -o gpx -F "$tmp_file" 2>NUL};
		my $rc  = system($cmd);
		if ($rc || !-f $tmp_file)
		{
			unlink $tmp_file if $tmp_file;
			return { error => "gpsbabel failed (rc=$rc) for $file_path" };
		}
		open my $fh, '<', $tmp_file
			or do { unlink $tmp_file; return { error => "Cannot read gpsbabel output: $!" } };
		local $/;
		$gpx_text = <$fh>;
		close $fh;
		unlink $tmp_file;
	}
	else
	{
		return { error => "Unsupported file type: $file_path" };
	}

	my $parsed = _parse_gpx_text($gpx_text);
	if (!$parsed)
	{
		return { error => "Failed to parse GPX from $file_path" };
	}

	my ($n_tracks, $n_wpts, $n_routes) = (0, 0, 0);
	my $pos = _max_item_pos($dbh, $coll_uuid);

	for my $trk (@{$parsed->{tracks}})
	{
		$pos += 1;
		my @pts   = @{$trk->{points}};
		my @times = sort { $a <=> $b } grep { defined $_ } map { $_->{ts} } @pts;
		my $ts_start  = $times[0];
		my $ts_end    = $times[-1];
		my $ts_source = defined $ts_start ? 'gdb' : 'import';
		my $uuid = insertTrack($dbh,
			name            => $trk->{name},
			ts_start        => $ts_start // 0,
			ts_end          => $ts_end,
			ts_source       => $ts_source,
			point_count     => scalar @pts,
			collection_uuid => $coll_uuid,
			position        => $pos);
		insertTrackPoints($dbh, $uuid, \@pts);
		$n_tracks++;
	}

	for my $wpt (@{$parsed->{waypoints}})
	{
		$pos += 1;
		my $uuid = insertWaypoint($dbh,
			name            => $wpt->{name},
			lat             => $wpt->{lat},
			lon             => $wpt->{lon},
			comment         => $wpt->{comment},
			created_ts      => $wpt->{ts} // 0,
			ts_source       => defined($wpt->{ts}) ? 'gdb' : 'import',
			source          => undef,
			collection_uuid => $coll_uuid,
			position        => $pos);
		$n_wpts++;
	}

	for my $rte (@{$parsed->{routes}})
	{
		$pos += 1;
		my $route_uuid = insertRoute($dbh, $rte->{name}, undef, '', $coll_uuid, $pos);
		my $rp_pos = 0;
		for my $pt (@{$rte->{points}})
		{
			my $wp_uuid = insertWaypoint($dbh,
				name            => $pt->{name},
				lat             => $pt->{lat},
				lon             => $pt->{lon},
				comment         => $pt->{comment},
				created_ts      => 0,
				ts_source       => 'import',
				source          => undef,
				collection_uuid => $coll_uuid,
				position        => $pos + 0.001 * $rp_pos);
			appendRouteWaypoint($dbh, $route_uuid, $wp_uuid, $rp_pos);
			$rp_pos++;
		}
		$n_routes++;
	}

	display(0,0,"gpsImport: imported $n_tracks tracks, $n_wpts waypoints, $n_routes routes from $file_path");
	return { tracks => $n_tracks, waypoints => $n_wpts, routes => $n_routes };
}

1;
