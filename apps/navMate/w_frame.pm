#!/usr/bin/perl
#-------------------------------------------------------------------------
# w_frame.pm
#-------------------------------------------------------------------------

package w_frame;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_IDLE
	EVT_MENU);
use Time::HiRes qw(time sleep);
use Pub::Utils;
use Pub::WX::Frame;
use w_resources;
use base qw(Pub::WX::Frame);


sub new
{
	my ($class, $parent) = @_;
	my $rect = Wx::Rect->new(200,100,1100,800);

	Pub::WX::Frame::setHowRestore(
		$RESTORE_ALL);

	my $this = $class->SUPER::new($parent,$rect);

	EVT_IDLE($this, \&onIdle);

	return $this;
}


sub onIdle
{
	my ($this,$event) = @_;
}


sub createPane
{
	my ($this,$id,$book,$data) = @_;
	return $this->SUPER::createPane($id,$book,$data);
}


1;
