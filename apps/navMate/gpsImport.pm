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
use n_defs;
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


sub _leaf_name
{
	my ($file_path) = @_;
	my $base = (split /[\/\\]/, $file_path)[-1];
	$base =~ s/\.(gpx|gdb)$//i;
	return $base;
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

	my @waypoints = @{$parsed->{waypoints}};
	my @routes    = @{$parsed->{routes}};
	my @tracks    = @{$parsed->{tracks}};

	my $leaf = _leaf_name($file_path);
	my $file_branch = insertCollection($dbh, $leaf, $coll_uuid, $NODE_TYPE_BRANCH, '');
	return { error => "Failed to create file branch '$leaf'" } if !$file_branch;

	my $groups_branch;
	if (@waypoints || @routes)
	{
		$groups_branch = insertCollection($dbh, 'Groups', $file_branch, $NODE_TYPE_BRANCH, '');
	}

	if (@waypoints)
	{
		my $my_wpts = insertCollection($dbh, 'My Waypoints', $groups_branch, $NODE_TYPE_GROUP, '');
		for my $wpt (@waypoints)
		{
			insertWaypoint($dbh,
				name            => $wpt->{name},
				lat             => $wpt->{lat},
				lon             => $wpt->{lon},
				comment         => $wpt->{comment},
				created_ts      => $wpt->{ts} // 0,
				ts_source       => defined($wpt->{ts}) ? 'gdb' : 'import',
				source          => undef,
				collection_uuid => $my_wpts);
		}
	}

	my @route_groups;
	for my $rte (@routes)
	{
		my $rg = insertCollection($dbh, $rte->{name}, $groups_branch, $NODE_TYPE_GROUP, '');
		my @wp_uuids;
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
				collection_uuid => $rg);
			push @wp_uuids, $wp_uuid;
		}
		push @route_groups, { route => $rte, wp_uuids => \@wp_uuids };
	}

	if (@routes)
	{
		my $routes_branch = insertCollection($dbh, 'Routes', $file_branch, $NODE_TYPE_BRANCH, '');
		for my $rg (@route_groups)
		{
			my $rte = $rg->{route};
			my $route_uuid = insertRoute($dbh, $rte->{name}, undef, '', $routes_branch);
			my $rp_pos = 0;
			for my $wp_uuid (@{$rg->{wp_uuids}})
			{
				appendRouteWaypoint($dbh, $route_uuid, $wp_uuid, $rp_pos);
				$rp_pos++;
			}
		}
	}

	if (@tracks)
	{
		my $tracks_branch = insertCollection($dbh, 'Tracks', $file_branch, $NODE_TYPE_BRANCH, '');
		for my $trk (@tracks)
		{
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
				collection_uuid => $tracks_branch);
			insertTrackPoints($dbh, $uuid, \@pts);
		}
	}

	my $n_wpts   = scalar @waypoints;
	my $n_routes = scalar @routes;
	my $n_tracks = scalar @tracks;
	display(0,0,"gpsImport: imported $n_tracks tracks, $n_wpts waypoints, $n_routes routes into branch '$leaf' from $file_path");
	return { tracks => $n_tracks, waypoints => $n_wpts, routes => $n_routes, branch => $leaf };
}

1;
