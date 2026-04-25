#!/usr/bin/perl
#-------------------------------------------------------------------------
# winMain.pm
#-------------------------------------------------------------------------

package winMain;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_IDLE
	EVT_MENU);
use Time::HiRes qw(time sleep);
use Pub::Utils qw(display warning error _def);
use Pub::WX::Frame;
use w_resources;
use nmServer;
use winCollections;
use base qw(Pub::WX::Frame);


sub new
{
	my ($class, $parent) = @_;
	my $rect = Wx::Rect->new(200, 100, 1100, 800);

	Pub::WX::Frame::setHowRestore($RESTORE_ALL);

	my $this = $class->SUPER::new($parent, $rect);

	EVT_MENU($this, $WIN_COLLECTIONS, \&onCommand);
	EVT_MENU($this, $CMD_OPEN_MAP,    \&onCommand);
	EVT_IDLE($this, \&onIdle);

	$this->createPane($WIN_COLLECTIONS) if !$this->findPane($WIN_COLLECTIONS);

	return $this;
}


sub onIdle
{
	my ($this, $event) = @_;
}


sub createPane
{
	my ($this, $id, $book, $data) = @_;
	return error("No id in createPane()") if !$id;
	$book ||= $this->{book};
	display(0, 0, "winMain::createPane($id) book=" . _def($book) . "  data=" . _def($data));
	return winCollections->new($this, $book, $id, $data) if $id == $WIN_COLLECTIONS;
	return $this->SUPER::createPane($id, $book, $data);
}


sub onCommand
{
	my ($this, $event) = @_;
	my $id = $event->GetId();
	if ($id == $WIN_COLLECTIONS)
	{
		my $pane = $this->findPane($id);
		$this->createPane($id) if !$pane;
	}
	elsif ($id == $CMD_OPEN_MAP)
	{
		openMapBrowser() unless isBrowserConnected();
	}
}


1;
