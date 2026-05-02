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
use lib 'migrate';
use Pub::Utils qw(display warning error _def);
use Pub::WX::Frame;
use Pub::WX::Dialogs;
use apps::raymarine::NET::c_RAYDP;
use w_resources;
use nmServer;
use nmOps;
use winBrowser;
use winE80;
use winMonitor;
use _import_kml;
use base qw(Pub::WX::Frame);


sub new
{
	my ($class, $parent) = @_;
	my $rect = Wx::Rect->new(200, 100, 1100, 800);

	Pub::WX::Frame::setHowRestore($RESTORE_ALL);

	my $this = $class->SUPER::new($parent, $rect);

	EVT_MENU($this, $WIN_BROWSER,      \&onCommand);
	EVT_MENU($this, $WIN_E80,          \&onCommand);
	EVT_MENU($this, $WIN_MONITOR,      \&onCommand);
	EVT_MENU($this, $CMD_OPEN_MAP,     \&onCommand);
	EVT_MENU($this, $CMD_IMPORT_KML,   \&onCommand);
	EVT_MENU($this, $CMD_REFRESH_E80,  \&onCommand);
	EVT_IDLE($this, \&onIdle);

	my $sb = Wx::StatusBar->new($this, -1);
	$sb->SetFieldsCount(3);
	$sb->SetStatusWidths(130, -1, 200);
	$this->SetStatusBar($sb);
	$this->{statusbar} = $sb;

	my $base = $sb->GetFont();
	my $bold = Wx::Font->new($base->GetPointSize(), $base->GetFamily(),
		$base->GetStyle(), wxFONTWEIGHT_BOLD);

	$this->{st_wpmgr} = Wx::StaticText->new($sb, -1, 'WPMGR', [5,  3]);
	$this->{st_wpmgr}->SetFont($bold);
	$this->{st_track} = Wx::StaticText->new($sb, -1, 'TRACK', [72, 3]);
	$this->{st_track}->SetFont($bold);

	$this->{color_on}  = Wx::Colour->new(0,   110, 0);
	$this->{color_off} = Wx::Colour->new(180, 0,   0);

	return $this;
}


sub setStatus
{
	my ($this, $text) = @_;
	$this->{statusbar}->SetStatusText($text // '', 1);
}


sub setClipboardStatus
{
	my ($this, $text) = @_;
	$this->{statusbar}->SetStatusText($text // '', 2);
}


sub onIdle
{
	my ($this, $event) = @_;

	my $wpmgr_on = ($raydp && $raydp->findImplementedService('WPMGR', 1)) ? 1 : 0;
	my $track_on = ($raydp && $raydp->findImplementedService('TRACK', 1)) ? 1 : 0;

	if ($wpmgr_on != ($this->{_wpmgr_on} // -1))
	{
		if (!$wpmgr_on)
		{
			$this->{_wpmgr_queried}  = 0;
			$this->{_wpmgr_in_query} = 0;
		}
		$this->{_wpmgr_on} = $wpmgr_on;
		$this->{st_wpmgr}->SetForegroundColour($wpmgr_on ? $this->{color_on} : $this->{color_off});
		$this->{st_wpmgr}->Refresh();
	}
	if ($track_on != ($this->{_track_on} // -1))
	{
		if (!$track_on)
		{
			$this->{_track_queried}  = 0;
			$this->{_track_in_query} = 0;
		}
		$this->{_track_on} = $track_on;
		$this->{st_track}->SetForegroundColour($track_on ? $this->{color_on} : $this->{color_off});
		$this->{st_track}->Refresh();
	}

	my $wpmgr_busy = $apps::raymarine::NET::d_WPMGR::query_in_progress // 0;
	my $track_busy = $apps::raymarine::NET::d_TRACK::query_in_progress // 0;

	# Detect query lifecycle: in-flight → completed
	if ($wpmgr_on && $wpmgr_busy)
	{
		$this->{_wpmgr_in_query} = 1;
	}
	elsif ($this->{_wpmgr_in_query} && !$wpmgr_busy)
	{
		$this->{_wpmgr_in_query} = 0;
		$this->{_wpmgr_queried}  = 1;
	}
	if ($track_on && $track_busy)
	{
		$this->{_track_in_query} = 1;
	}
	elsif ($this->{_track_in_query} && !$track_busy)
	{
		$this->{_track_in_query} = 0;
		$this->{_track_queried}  = 1;
	}

	# Session is stable once WPMGR has completed a real query and no service
	# is currently downloading.  TRACK is optional: if absent, ignore it.
	my $session_stable =
		($wpmgr_on &&
		 !$wpmgr_busy &&
		 ($this->{_wpmgr_queried} // 0) &&
		 (!$track_on || (!$track_busy && ($this->{_track_queried} // 0))))
		? 1 : 0;

	my $prev_stable = $this->{_e80_stable} // -1;
	if ($session_stable != $prev_stable)
	{
		$this->{_e80_stable} = $session_stable;
		my $e80 = $this->findPane($WIN_E80);
		if ($e80)
		{
			if ($session_stable)
			{
				$this->{_e80_version} = apps::raymarine::NET::b_sock::getVersion();
				$e80->onSessionStart();
			}
			else
			{
				$e80->refresh();
			}
		}
	}
	elsif ($session_stable)
	{
		my $was_active = $this->{_dialog_active} // 0;
		my $now_active = Pub::WX::ProgressDialog::isActive() ? 1 : 0;
		$this->{_dialog_active} = $now_active;

		if ($was_active && !$now_active)
		{
			$this->{_e80_dirty_time} = 0;
			my $e80 = $this->findPane($WIN_E80);
			$e80->refresh() if $e80;
		}
		else
		{
			my $v = apps::raymarine::NET::b_sock::getVersion();
			if ($v != ($this->{_e80_version} // -1))
			{
				$this->{_e80_version}    = $v;
				$this->{_e80_dirty_time} = time();
			}
			elsif ($this->{_e80_dirty_time} &&
			       !apps::raymarine::NET::d_WPMGR::getPendingCommands() &&
			       time() > $this->{_e80_dirty_time} + 0.20)
			{
				$this->{_e80_dirty_time} = 0;
				my $e80 = $this->findPane($WIN_E80);
				$e80->refresh() if $e80;
			}
		}
	}

	sleep(0.02);
	$event->RequestMore();
}


sub createPane
{
	my ($this, $id, $book, $data) = @_;
	return error("No id in createPane()") if !$id;
	$book ||= $this->{book};
	display(0, 0, "winMain::createPane($id) book=" . _def($book) . "  data=" . _def($data));
	return winBrowser->new($this, $book, $id, $data)  if $id == $WIN_BROWSER;
	return winE80->new($this, $book, $id, $data)      if $id == $WIN_E80;
	return winMonitor->new($this, $book, $id, $data)  if $id == $WIN_MONITOR;
	return $this->SUPER::createPane($id, $book, $data);
}


sub onCommand
{
	my ($this, $event) = @_;
	my $id = $event->GetId();
	if ($id == $WIN_BROWSER || $id == $WIN_E80 || $id == $WIN_MONITOR)
	{
		my $pane = $this->findPane($id);
		$this->createPane($id) if !$pane;
	}
	elsif ($id == $CMD_OPEN_MAP)
	{
		openMapBrowser() if !isBrowserConnected();
	}
	elsif ($id == $CMD_IMPORT_KML)
	{
		_doImportKML($this);
	}
	elsif ($id == $CMD_REFRESH_E80)
	{
		doRefresh($this);
	}
}


sub _doImportKML
{
	my ($this) = @_;
	display(0,0,"winMain: ImportKML starting");
	my $rc = c_db::resetDB();
	if ($rc <= 0)
	{
		warning(0,0,"winMain: ImportKML aborted — resetDB returned $rc");
		return;
	}
	_import_kml::run();
	my $browser = $this->findPane($WIN_BROWSER);
	$browser->refresh() if $browser;
	display(0,0,"winMain: ImportKML done");
}


1;
