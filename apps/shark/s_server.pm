#-----------------------------------------------------
# s_server.pm
#-----------------------------------------------------
# Shark-specific HTTP server.  Extends h_server.pm.
# Port 9882.
#
# Adds:
#   /api/colormap   - per-service color assignments from SHARK_DEFAULTS
#
# Extends handleCommand with shark-specific commands:
#   i               - DB service uiInit
#   fids            - DB parser showFids
#   v               - DBNAV showValues
#   f <cmd> <path>  - FILESYS fileCommand
#   s               - clear shark.log
#   r               - clear rns.log
#   log <msg>       - mark both log files
#   scan [lo hi]    - TCP port scan
#   udp [lo hi]     - UDP port scan
#   p <svc> [args]  - probe a service
#   write           - fshWriter::write

package s_server;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use Pub::ServerUtils;
use Pub::HTTP::Response qw(http_ok http_error);
use apps::raymarine::NET::a_defs;
use apps::raymarine::NET::a_mon;
use apps::raymarine::NET::a_utils;
use apps::raymarine::NET::c_RAYDP;
use apps::raymarine::NET::fshWriter;
use apps::raymarine::NET::h_server;
use s_harness;
use tcpScanner;
use udpScanner;
use base qw(apps::raymarine::NET::h_server);


my $dbg = 0;

my $SERVER_PORT = 9882;
my $SRC_DIR     = '/base/apps/raymarine/apps/shark';

my $ray_server;


BEGIN
{
	use Exporter qw( import );
	our @EXPORT = qw(
		startHTTPServer
		dispatchCommand
	);
}


#-----------------------
# startHTTPServer / dispatchCommand
#-----------------------

sub startHTTPServer
{
	display($dbg,0,"starting s_server");
	$logfile = "$temp_dir/shark_api.log" if !$logfile;
	$ray_server = s_server->new();
	$ray_server->start();
	display($dbg,0,"finished starting s_server");
}


sub dispatchCommand
{
	my ($lpart,$rpart) = @_;
	$ray_server->handleCommand($lpart,$rpart) if $ray_server;
}


sub new
{
	my ($class) = @_;
	my $no_cache = shared_clone({ 'cache-control' => 'max-age: 603200' });
	my $params = {
		HTTP_DEBUG_SERVER    => -1,
		HTTP_DEBUG_REQUEST   => 0,
		HTTP_DEBUG_RESPONSE  => 0,
		HTTP_DEBUG_QUIET_RE  => 'raysys\.kml|/api/',
		HTTP_MAX_THREADS     => 5,
		HTTP_KEEP_ALIVE      => 0,
		HTTP_PORT            => $SERVER_PORT,
		HTTP_DOCUMENT_ROOT   => "$SRC_DIR/site",
		HTTP_GET_EXT_RE      => 'html|js|css|jpg|png|ico',
		HTTP_DEFAULT_HEADERS_JPG => $no_cache,
		HTTP_DEFAULT_HEADERS_PNG => $no_cache,
	};
	my $this = $class->SUPER::new($params);
	$this->{stop_service} = 0;
	return $this;
}


#-----------------------------------------
# handle_request - shark-specific routes
#-----------------------------------------

sub handle_request
{
	my ($this, $client, $request) = @_;
	my $uri = $request->{uri} || '';

	if ($uri eq '/api/colormap')
	{
		return $this->api_colormap($request);
	}

	return $this->SUPER::handle_request($client,$request);
}


#-----------------------------------------
# handleCommand - shark-specific commands
#-----------------------------------------

sub handleCommand
{
	my ($this, $lpart, $rpart) = @_;

	# DB service

	if ($lpart eq 'i')
	{
		my $db = $raydp->findImplementedService('DB');
		display(0,0,"db="._def($db));
		$db->uiInit() if $db;
	}
	elsif ($lpart eq 'fids')
	{
		my $db        = $raydp->findImplementedService('DB');
		my $db_parser = $db ? $db->{parser} : 0;
		display(0,0,"db="._def($db)." db_parser="._def($db_parser));
		$db_parser->showFids() if $db_parser;
	}

	# DBNAV

	elsif ($lpart eq 'v')
	{
		my $dbnav = $raydp->findImplementedService('DBNAV');
		$dbnav->showValues() if $dbnav;
	}

	# FILESYS

	elsif ($lpart eq 'f')
	{
		my ($cmd,$path) = split(/\s+/,$rpart);
		my $filesys = $raydp->findImplementedService('FILESYS');
		$filesys->fileCommand($cmd,$path) if $filesys;
	}

	# Log files

	elsif ($lpart eq 's')
	{
		display(0,0,"Clear Shark Log File");
		clearLog("shark.log");
	}
	elsif ($lpart eq 'r')
	{
		display(0,0,"Clear RNS Log File");
		clearLog("rns.log");
	}
	elsif ($lpart eq 'log')
	{
		my $msg =
			"\n=======================================================================\n".
			"# $rpart\n".
			"========================================================================\n\n";
		writeLog($msg,'rns.log');
		writeLog($msg,'shark.log');
	}

	# Port scans

	elsif ($lpart eq 'scan')
	{
		my ($low,$high) = split(/\s+/,$rpart);
		return error("No tcpScanner!") if !$tcp_scanner;
		$rpart
			? $tcp_scanner->scanRange($low,$high)
			: $tcp_scanner->showAliveScans();
	}
	elsif ($lpart eq 'udp')
	{
		my $aggressive = $rpart =~ s/a// ? 1 : 0;
		$rpart =~ s/^\s+|\s+$//g;
		my ($low,$high) = split(/\s+/,$rpart);
		return error("No udpScanner!") if !$udp_scanner;
		$rpart
			? $udp_scanner->scanRange($low,$high,$aggressive)
			: $udp_scanner->showAliveScans();
	}

	# Probe

	elsif ($lpart eq 'p')
	{
		my ($name,@params) = split(/\s+/,$rpart);
		my $args = join(' ',@params) || '';
		$name = 'TRACK'   if $name eq 't';
		$name = 'WPMGR'   if $name eq 'w';
		$name = 'FILESYS' if $name eq 'f';
		$name = 'DB'      if $name eq 'd';
		my $service_port =
			$raydp->findImplementedService($name,1) ||
			$raydp->findServicePortByName($name,1);
		return error("service $name("._def($service_port).") doesn't exist or is not connected")
			if !($service_port && $service_port->{connected});
		$service_port->doProbe($args);
	}

	# fshWriter

	elsif ($lpart eq 'write')
	{
		apps::raymarine::NET::fshWriter::write();
	}

	# WPMGR debug commands (shark-only; require test harness or name translation)

	elsif ($lpart =~ /^(create|route|wp|group|mod)$/)
	{
		my $wpmgr = $raydp->findImplementedService('WPMGR');
		return if !$wpmgr;

		if ($lpart eq 'create')
		{
			my ($what,$num) = split(/\s+/,$rpart);
			$what = lc($what // '');
			s_harness::createTestWaypoint($wpmgr,$num) if $what eq 'wp';
			s_harness::createTestRoute($wpmgr,$num)    if $what eq 'route';
			s_harness::createTestGroup($wpmgr,$num)    if $what eq 'group';
		}
		elsif ($lpart eq 'route')
		{
			my ($route_id,$op,$wp_id) = split(/\s+/,$rpart);
			if ($op && ($op eq '+' || $op eq '-'))
			{
				my $route_uuid = s_harness::resolveUUID($wpmgr,'route',$route_id);
				my $wp_uuid    = s_harness::resolveUUID($wpmgr,'waypoint',$wp_id);
				$wpmgr->routeWaypoint($route_uuid,$wp_uuid,$op eq '+')
					if $route_uuid && $wp_uuid;
			}
			else
			{
				$wpmgr->showItem('route',$rpart);
			}
		}
		elsif ($lpart eq 'wp')
		{
			my ($wp_id,$group_id) = split(/\s+/,$rpart);
			if (defined $group_id)
			{
				my $wp_uuid    = s_harness::resolveUUID($wpmgr,'waypoint',$wp_id);
				my $group_uuid = (!$group_id || $group_id eq '0')
					? 0
					: s_harness::resolveUUID($wpmgr,'group',$group_id);
				$wpmgr->setWaypointGroup($wp_uuid,$group_uuid) if $wp_uuid;
			}
			else
			{
				$wpmgr->showItem('waypoint',$rpart);
			}
		}
		elsif ($lpart eq 'group')
		{
			$wpmgr->showItem('group',$rpart);
		}
		elsif ($lpart eq 'mod')
		{
			my ($what,$item_name,@kvs) = split(/\s+/,$rpart);
			$what = lc($what) if $what;
			if (!$what || !$item_name || !@kvs)
			{
				error("usage: mod <wp> <name> key=val [key=val ...]");
			}
			elsif ($what eq 'wp')
			{
				my $uuid = $wpmgr->findUUIDByName('waypoint',$item_name);
				if ($uuid)
				{
					my %changes = (uuid => $uuid);
					for my $kv (@kvs)
					{
						my ($k,$v) = split(/=/,$kv,2);
						$changes{$k} = $v;
					}
					$changes{sym}  += 0 if exists $changes{sym};
					$changes{date} += 0 if exists $changes{date};
					$changes{time} += 0 if exists $changes{time};
					$wpmgr->modifyWaypoint(\%changes);
				}
			}
			else
			{
				error("mod: unknown type '$what'");
			}
		}
	}

	# Shared NET-layer commands

	else
	{
		$this->SUPER::handleCommand($lpart,$rpart);
	}
}


#==================================================================================
# commandHelp - shark-specific [sig, desc] pairs (prepended to inherited list)
#==================================================================================

sub commandHelp
{
	my ($this) = @_;
	my @mine = (
		[ 'i',                           'DB service uiInit'                   ],
		[ 'fids',                        'DB parser showFids'                  ],
		[ 'v',                           'DBNAV showValues'                    ],
		[ 'f <cmd> <path>',              'FILESYS fileCommand'                 ],
		[ 's',                           'clear shark.log'                     ],
		[ 'r',                           'clear rns.log'                       ],
		[ 'log <msg>',                   'mark both log files'                 ],
		[ 'scan [lo hi]',                'TCP port scan'                       ],
		[ 'udp [lo hi]',                 'UDP port scan'                       ],
		[ 'p <svc> [args]',              'probe a service'                     ],
		[ 'write',                       'fshWriter::write'                    ],
		[ 'create <wp|route|group> <n>', 'create N test objects of given type' ],
		[ 'route <id> [<+|-> <wp>]',     'add/remove waypoint or show route'   ],
		[ 'wp <id> [group_id]',          'set waypoint group or show waypoint' ],
		[ 'group <id>',                  'show group item'                     ],
		[ 'mod <wp> <name> k=v [...]',   'modify waypoint fields'              ],
	);
	return [ @mine, @{$this->SUPER::commandHelp()} ];
}


#==================================================================================
# /api/colormap
#==================================================================================

sub api_colormap
{
	my ($this, $request) = @_;

	my %color_names = (
		0x00 => 'BLACK',       0x01 => 'BLUE',
		0x02 => 'GREEN',       0x03 => 'CYAN',
		0x04 => 'RED',         0x05 => 'MAGENTA',
		0x06 => 'BROWN',       0x07 => 'LIGHT_GRAY',
		0x08 => 'GRAY',        0x09 => 'LIGHT_BLUE',
		0x0A => 'LIGHT_GREEN', 0x0B => 'LIGHT_CYAN',
		0x0C => 'LIGHT_RED',   0x0D => 'LIGHT_MAGENTA',
		0x0E => 'YELLOW',      0x0F => 'WHITE',
	);

	my %map;
	for my $port (sort { $a <=> $b } keys %SHARK_DEFAULTS)
	{
		my $def = $SHARK_DEFAULTS{$port};
		next if !$def->{name};
		my $entry = { name => $def->{name}, port => $port+0 };
		if ($def->{in_colors})
		{
			my @in  = @{$def->{in_colors}};
			my @out = @{$def->{out_colors}};
			$entry->{in_colors}       = \@in;
			$entry->{out_colors}      = \@out;
			$entry->{in_color_names}  = [ map { $color_names{$_} || "color_$_" } @in  ];
			$entry->{out_color_names} = [ map { $color_names{$_} || "color_$_" } @out ];
			$entry->{what_order}      = ['waypoint','route','group'];
		}
		else
		{
			my $ic = ($def->{in_color}  || 0) + 0;
			my $oc = ($def->{out_color} || 0) + 0;
			$entry->{in_color}       = $ic;
			$entry->{out_color}      = $oc;
			$entry->{in_color_name}  = $color_names{$ic} || "color_$ic";
			$entry->{out_color_name} = $color_names{$oc} || "color_$oc";
		}
		$map{$port} = $entry;
	}
	return $this->api_json_response($request,\%map);
}


1;

