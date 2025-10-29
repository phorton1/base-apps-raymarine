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
use Win32::SerialPort;
use Win32::Console;
use w_resources;
use winRAYSYS;
use winFILESYS;
use winDBNAV;
use winSniffer;
use base qw(Pub::WX::Frame);


sub new
{
	my ($class, $parent) = @_;
	my $rect = Wx::Rect->new(200,100,1100,800);

	Pub::WX::Frame::setHowRestore(
		# $RESTORE_MAIN_RECT);
		$RESTORE_ALL);

	my $this = $class->SUPER::new($parent,$rect);

	EVT_MENU($this, $WIN_RAYSYS, \&onCommand);
	EVT_MENU($this, $WIN_SNIFFER, \&onCommand);
	EVT_MENU($this, $WIN_FILESYS, \&onCommand);
	EVT_MENU($this, $WIN_DBNAV,	\&onCommand);
    EVT_IDLE($this, \&onIdle);

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
	return winRAYSYS->new($this,$book,$id,$data) if $id == $WIN_RAYSYS;
	return winSniffer->new($this,$book,$id,$data) if $id == $WIN_SNIFFER;
	return winFILESYS->new($this,$book,$id,$data) if $id == $WIN_FILESYS;
	return winDBNAV->new($this,$book,$id,$data) if $id == $WIN_DBNAV;
    return $this->SUPER::createPane($id,$book,$data);
}


sub onCommand
{
    my ($this,$event) = @_;
    my $id = $event->GetId();
	if ($id == $WIN_RAYSYS ||
		$id == $WIN_SNIFFER ||
		$id == $WIN_FILESYS ||
		$id == $WIN_DBNAV)
	{
    	my $pane = $this->findPane($id);
		display(0,0,"$appName onCommand($id) pane="._def($pane));
    	$this->createPane($id) if !$pane;
	}
}


1;
