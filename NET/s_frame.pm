#!/usr/bin/perl
#-------------------------------------------------------------------------
# s_frame.pm
#-------------------------------------------------------------------------

package s_frame;
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
use s_resources;
use winRAYDP;
use winFILESYS;


use base qw(Pub::WX::Frame);


sub new
{
	my ($class, $parent) = @_;
	my $this = $class->SUPER::new($parent);

	EVT_MENU($this, $WIN_RAYDP, \&onCommand);
	EVT_MENU($this, $WIN_FILESYS, \&onCommand);
    EVT_IDLE($this, \&onIdle);

	my $data = undef;
	$this->createPane($WIN_RAYDP,$this->{book},$data,"test237");
	# $this->createPane($WIN_FILESYS,$this->{book},$data,"test237");
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
	return winRAYDP->new($this,$book,$id,"test236 $id") if $id == $WIN_RAYDP;
	return winFILESYS->new($this,$book,$id,"test236 $id") if $id == $WIN_FILESYS;
    return $this->SUPER::createPane($id,$book,$data,"test237");
}


sub onCommand
{
    my ($this,$event) = @_;
    my $id = $event->GetId();
	if ($id == $WIN_RAYDP ||
		$id == $WIN_FILESYS)
	{
    	my $pane = $this->findPane($id);
		display(0,0,"$appName onCommand($id) pane="._def($pane));
    	$this->createPane($id) if !$pane;
	}
}


1;
