#---------------------------------------------
# a_packet.pm
#---------------------------------------------

package a_packet;
use strict;
use warnings;
use threads;
use threads::shared;
use Pub::Utils;
use a_defs;
use a_utils;


BEGIN
{
 	use Exporter qw( import );
	our @EXPORT = qw(
	);
}



sub new
{
	my ($class, $params) = @_;
	my $this = shared_clone($params);
	bless $this,$class;
		# required
		# 	proto
		# 	src_ip
		# 	src_port
		# 	dst_ip
		# 	dst_port
		#	payload
		#
		# optional
		#	color
		#
		#	src_name
		#	dst_name

	$this->parseMessages();
		# messages

	$this->handleMessages();
	return $this;
}




sub parseMessages
{
	my ($this) = @_;
	my $payload = $this->{payload};
	$this->{messages} = shared_clone([]);

	if ($this->{proto} ne 'tcp')
	{
		$this->parseMessage(length($payload),$payload);
		return;
	}

	my $offset = 0;
	my $packet_len = length($payload);
	while ($packet_len - $offset >= 4)
	{
		my $len = unpack('v',substr($payload,$offset,2));
		my $part = substr($payload,$offset,$len+2);
		$this->parseMessage($len,$part);
		$offset += $len + 2;
	}
}


sub parseMessage
{
	my ($this,$len,$part) = @_;
	my $msg = shared_clone({
		len		 => $len,
		cmd_word => substr($part,0,2),
		sid 	 => substr($part,2,2),
		bytes 	 => substr($part,4),
	});
	push @{$this->{messages}},$msg;
}


sub handleMessages
{
	my ($this) = @_;

	my $text =
		pad("$this->{src_ip}:$this->{src_port}",20).
		"--> ".
		pad("$this->{dst_ip}:$this->{dst_port}",20).
		" $this->{proto} ".
		"len(".length($this->{payload}).")".
		"\n";

	my $is_tcp = $this->{proto} eq 'tcp';

	for my $msg (@{$this->{messages}})
	{
		my $hdr = '    ';
		$hdr .= $is_tcp ? unpack('H*',$msg->{len})." " : pad('',5);
		$hdr .= unpack('H*',$msg->{cmd_word})." ";
		$hdr .= unpack('H*',$msg->{sid})." ";
		$text .= parse_dwords($hdr,$msg->{bytes},1);
	}

	setConsoleColor($UTILS_COLOR_BROWN) if $this->{src_ip} eq '10.0.241.200';
	print $text;
	setConsoleColor() if $this->{src_ip} eq '10.0.241.200'; # if $this->{color};
}




1;
