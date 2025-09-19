#!/usr/bin/perl
#-------------------------------------------------------------------------
# s_frame.pm
#-------------------------------------------------------------------------

package apps::raymarine::NET::s_frame;
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
use Win32::SerialPort;
use Win32::Console;
use apps::raymarine::NET::s_resources;
use apps::raymarine::NET::winRAYDP;


use base qw(Pub::WX::Frame);


sub new
{
	my ($class, $parent) = @_;
	my $this = $class->SUPER::new($parent);

	EVT_MENU($this, $WIN_RAYDP, \&onCommand);
    EVT_IDLE($this, \&onIdle);

	my $data = undef;
	$this->createPane($WIN_RAYDP,$this->{book},$data,"test237");

	return $this;
}




sub onIdle
{
    my ($this,$event) = @_;
	# $event->RequestMore(1);
}



sub createPane
	# factory method must be implemented if derived
    # classes want their windows restored on opening.
{
	my ($this,$id,$book,$data) = @_;
	return error("No id in createPane()") if (!$id);
    $book ||= $this->{book};
	display(0,0,"minimumFrame::createPane($id) book="._def($book)."  data="._def($data));
	return apps::raymarine::NET::winRAYDP->new($this,$book,$id,"test236 $id") if $id == $WIN_RAYDP;
    return $this->SUPER::createPane($id,$book,$data,"test237");
}


sub onCommand
{
    my ($this,$event) = @_;
    my $id = $event->GetId();
	if ($id == $WIN_RAYDP)
	{
    	my $pane = $this->findPane($id);
		display(0,0,"$appName onCommand($id) pane="._def($pane));
    	$this->createPane($id) if !$pane;
	}
}


1;
