#---------------------------------------------
# b_probe.pm
#---------------------------------------------
# Addon functionaliy extensions to b_sock.
# The proper way to do this kind of addon is to use require in the parent package file,
# but the addon code still must declare that packet name here for namespace resolution.
#
# A probes filename is {name}_probes.txt, and matches the capitalization scheme.
#
# PROBE 	identifier	identifies a named probe that can be executed from shark
#				by typing "P name identifier"
# RAW		hex strings with replacements that will be sent
# MSG		creates word(length) prepended message
# INC_SEQ	bump the sequence number
# UDP_DEST	change the destination IP address; useful for testing FILESYS without doing a DIR first
# WAIT 		wait for any reply
# >>>		text will be output to console
#
# Replacements (in order of operations)
#	{time}	will be replaced by HH:MM:SS
# 	{seq}	will be replaced by a dword sequence number that advances once per probe
# 	{sid}	will be replaced by the service_id
#   {port}  will be replaced with the local_port (for udp probes)
#   {string some_name} will be replaced by a word(length) delimited string
# 	{name16 some name} will be replaced with the hex16 (non zero terminated) name
#	{params} whatever was passed to doProbe(), after the $ident, in $full_params
#
# Note that udp probes are sent with global sendUDPPacket() in a_utils.

package b_sock;	# continued ...
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(sleep time);
use Pub::Utils;
use a_utils;


my $dbg_probe 	= 0;


#-----------------------------------------------
# clieant API doProbe and probe file parsing
#-----------------------------------------------

sub doProbe
{
	my ($this,$full_params) = @_;
	my ($ident,@params) = split(/\s+/,$full_params);
	my $params = join(' ',@params) || '';

	display($dbg_probe,0,"doProbe($this->{name},$ident,$params) full_params=$full_params");
	my $probes = $this->parseProbes();
	return if !$probes;
	return error("Could not find probe($ident)")
		if !$probes->{$ident};

	# not changing this isolated use of vestigial 'func'
	# for time being
	
	my $command = shared_clone({
		name => "PROBE($ident)",
		probes => $probes,
		ident => $ident,
		params => $params });
	push @{$this->{command_queue}},$command;
}



sub pushStep
{
	my ($probe,$line_num,$step,$step_text) = @_;
	display($dbg_probe+1,1,"pushStep($line_num,$step,$step_text)");
	$step_text =~ s/^\s+|\s+$//g;

	if ($step =~ /RAW|MSG/i && !$step_text)
	{
		warning("empty $step section at line $line_num");
	}
	else
	{
		my $text = uc($step);
		$text .= " $step_text" if $step_text;
		push @$probe,$text;
	}
}


sub parseProbes
{
	my ($this) = @_;
	my $name = $this->{name};
	my $probe_file = "$data_dir/$name"."_probes.txt";
	display($dbg_probe,0,"parseProbes($probe_file)");
	my @lines = getTextLines($probe_file);
	return error("missing or empty $probe_file") if !@lines;

	my $probes = shared_clone({});

	my $probe;
	my $step = '';
	my $step_text = '';
	my $num_lines = @lines;
	for (my $i=0; $i<$num_lines; $i++)
	{
		my $line_num = $i + 1;
		my $line = $lines[$i];

		$line =~ s/#.*$//;
		$line =~ s/^\s+|\s+$//g;
		next if !$line;

		if ($line =~ /^PROBE\s+(.*)$/i)
		{
			my $ident = $1;
			display($dbg_probe+1,1,"$line_num: PROBE($ident)");

			pushStep($probe,$line_num,$step,$step_text)
				if $step;
			$step = '';
			$step_text = '';

			$probe = shared_clone([]);
			$probes->{$ident} = $probe;
		}
		elsif ($line =~ /^(RAW|MSG|INC_SEQ|WAIT)(.*)$/)
		{
			my ($sec,$text) = ($1,$2);
			$text =~ s/#.*$//;
			$text =~ s/^\s|\s$//g;
			display($dbg_probe+1,1,"$line_num: $sec $text");

			# push previous step, if any
			pushStep($probe,$line_num,$step,$step_text)
				if $step;
			$step = $sec;
			$step_text = $text;
		}
		elsif ($probe && $line =~ /^>>>/)
		{
			push @$probe,$line;
		}
		elsif ($step && $line)
		{
			$step_text .= $line;
		}
	}

	# push the dangling step if any
	pushStep($probe,$num_lines,$step,$step_text)
		if $step;
	display($dbg_probe+1,0,"parse finished");

	if ($dbg_probe < -1)
	{
		print "-------- probes ----------\n";
		for my $key (sort keys %$probes)
		{
			my $probe = $probes->{$key};
			print "PROBE($key)\n";
			for my $line (@$probe)
			{
				print "    $line\n";
			}
		}
		print "-------------------------\n";
	}

	my $num_probes = keys %$probes;
	return error("NO probes found in $probe_file!")
		if !$num_probes;
	display($dbg_probe,0,"parseProbes() returning $num_probes probes");
	return $probes;
}



#---------------------------------------------
# do_probe called from tcpBase commandThread
#---------------------------------------------

sub do_probe
{
	my ($this,$command) = @_;
	my $ident = $command->{ident};
	my $probes = $command->{probes};
	my $probe = $probes->{$ident};
	my $num_steps = @$probe;
	my $seq = $this->{next_seqnum};

	my $save_ip = $this->{ip};
	my $save_raw_input  = $this->{show_raw_input};
	my $save_raw_output = $this->{show_raw_output};
	$this->{show_raw_input} = 1;
	$this->{show_raw_output} = 1;

	display(0,0,"PROBE($this->{name},$this->{proto},$ident,$command->{params}) with $num_steps steps");

	for (my $i=0; $i<$num_steps; $i++)
	{
		my $line = $$probe[$i];
		display($dbg_probe+2,1,"probe line($i) = $line");

		if ($line =~ s/^>>>//)
		{
			print "$line\n";
		}
		elsif ($line =~ /INC_SEQ/)
		{
			$seq = ++$this->{next_seqnum};
		}
		elsif ($line =~ /^(UDP_DEST)\s+(.*)$/)
		{
		}
		elsif ($line =~ /^(RAW|MSG)\s+(.*)$/)
		{
			my ($cmd,$text) = ($1,$2);
			my $hex_seq = unpack('H*',pack('V',$seq));
			my $hex_sid = unpack('H*',pack('v',$this->{service_id})),
			my $hex_port = unpack('H*',pack('v',$this->{local_port})),

			my $now = now();

			$text =~ s/{params}/$command->{params}/g;
			$text =~ s/{time}/$now/g;
			$text =~ s/{seq}/$hex_seq/g;
			$text =~ s/{sid}/$hex_sid/g;
			$text =~ s/{port}/$hex_port/g;

			while ($text =~ s/{string\s+(.*?)}/##HERE##/)
			{
				my $name = $1;
				my $len = length($name);
				my $hex_len = unpack('H*',pack('v',$len));
				my $hex_name = unpack('H*',$name);
				display($dbg_probe+2,1,"STRING($name)=$hex_len $hex_name");
				$text =~ s/##HERE##/$hex_len$hex_name/;
			}

			while ($text =~ s/{name16\s+(.*?)}/##HERE##/)
			{
				my $name = $1;
				my $hex = name16_hex($name,1);	# no terminator
				my $data = pack('H*',$hex);
				display_bytes($dbg_probe+2,1,"HEX16($name)=$hex",$data);
				$text =~ s/##HERE##/$hex/;
			}

			$text =~ s/\s//g;
			my $data = pack('H*',$text);
			my $len = length($data);
			display($dbg_probe,1,"$cmd($len) = $text");

			if ($this->{proto} eq 'tcp' && $cmd eq 'MSG')
			{
				display($dbg_probe+1,2,"PROBE: send len($len)");
				$this->sendPacket(pack('v',$len))
			}
			display($dbg_probe+1,2,"PROBE: send $text");
			$this->{proto} eq 'udp' ?
				sendUDPPacket("PROBE($ident)",$this->{ip},$this->{port},$data) :
				$this->sendPacket($data);
		}


		# this is where it gets weird
		# by default, this will actually call
		# derived classes handlePacket() method,
		# and *could* actually be used to implement waitReply,
		# BUT especially for testing a variety of messages,
		# we may not want to modify their parsers as we go.

		elsif ($line =~ /^WAIT\s*(.*)$/)
		{
			my $extra = $1;
			my $PROBE_TIMEOUT = $1 || 3;
			$this->{probe_wait} = 1;
			my $time = time();
			while ($this->{probe_wait})
			{
				if (time() > $time + $PROBE_TIMEOUT)
				{
					warning($dbg_probe,0,"PROBE WAIT($PROBE_TIMEOUT) TIMEOUT");
					last;
				}
				sleep(0.1);
			}
			$this->{probe_wait} = 0;
		}
	}

	$this->{ip} = $save_ip;
	$this->{show_raw_input}  = $save_raw_input;
	$this->{show_raw_output} = $save_raw_output;
	display(0,0,"PROBE($this->{name},$this->{proto},$ident,$command->{params}) FINISHED");
}



1;