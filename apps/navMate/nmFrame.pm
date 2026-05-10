#!/usr/bin/perl
#-------------------------------------------------------------------------
# nmFrame.pm
#-------------------------------------------------------------------------

package nmFrame;
use strict;
use warnings;
use threads;
use threads::shared;
use Time::HiRes qw(time sleep);
use Wx qw(:everything);
use Wx::Event qw(
	EVT_IDLE
	EVT_MENU
	EVT_UPDATE_UI);
use Pub::Utils qw(display warning error _def);
use Pub::WX::AppConfig;
use Pub::WX::Frame;
use Pub::WX::Dialogs;
use apps::raymarine::NET::c_RAYDP;
use navVisibility qw(saveViewState);
use navSelection;
use nmResources;
use nmDialogs;
use navServer;
use navTest;
use winDatabase;
use winE80;
use winMonitor;
use navOneTimeImport;
use navKML;
use base qw(Pub::WX::Frame);


sub new
{
	my ($class, $parent) = @_;
	my $rect = Wx::Rect->new(200, 100, 1100, 800);

	Pub::WX::Frame::setHowRestore($RESTORE_ALL);

	my $this = $class->SUPER::new($parent, $rect);

	EVT_MENU($this, $WIN_DATABASE,				\&onCommand);
	EVT_MENU($this, $WIN_E80,					\&onCommand);
	EVT_MENU($this, $WIN_MONITOR,				\&onCommand);
	EVT_MENU($this, $COMMAND_OPEN_MAP,			\&onCommand);
	EVT_MENU($this, $COMMAND_IMPORT_KML,		\&onCommand);
	EVT_MENU($this, $COMMAND_REFRESH_WIN_E80,	\&onCommand);
	EVT_MENU($this, $COMMAND_REFRESH_E80_DB,	\&onCommand);
	EVT_MENU($this, $COMMAND_CLEAR_E80_DB,		\&onCommand);
	EVT_MENU($this, $COMMAND_REFRESH_DB,		\&onCommand);
	EVT_MENU($this, $COMMAND_EXPORT_DB_TEXT,	\&onCommand);
	EVT_MENU($this, $COMMAND_IMPORT_DB_TEXT,	\&onCommand);
	EVT_MENU($this, $COMMAND_EXPORT_KML,		\&onCommand);
	EVT_MENU($this, $COMMAND_IMPORT_KML_NM,		\&onCommand);
	EVT_MENU($this, $COMMAND_CLEAR_MAP,			\&onCommand);
	EVT_MENU($this, $COMMAND_REVERT_DB,			\&onCommand);
	EVT_MENU($this, $COMMAND_COMMIT_DB,			\&onCommand);
	EVT_MENU($this, $COMMAND_SAVE_OUTLINE,		\&onCommand);
	EVT_MENU($this, $COMMAND_RESTORE_OUTLINE,	\&onCommand);
	EVT_MENU($this, $COMMAND_SAVE_SELECTION,	\&onCommand);
	EVT_MENU($this, $COMMAND_RESTORE_SELECTION,	\&onCommand);
	EVT_UPDATE_UI($this, $COMMAND_REFRESH_WIN_E80,	\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_REFRESH_E80_DB,	\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_CLEAR_E80_DB,		\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_REVERT_DB,		\&onCommandEnable);
	EVT_UPDATE_UI($this, $COMMAND_COMMIT_DB,		\&onCommandEnable);
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


sub showError
{
	my ($this, $msg) = @_;
	return if $nmDialogs::suppress_error_dialog;
	$this->SUPER::showError($msg);
}


sub onIdle
{
	my ($this, $event) = @_;

	Pub::WX::ProgressDialog::forceCloseActive();
	unless (Pub::WX::ProgressDialog::isActive())
	{
		my $test_cmd = pollTestCommand();
		dispatchTestCommand($this, $test_cmd) if $test_cmd;
	}

	if (pollBrowserConnectEvent())
	{
		my $database = $this->findPane($WIN_DATABASE);
		$database->onBrowserConnect() if $database;
	}
	if (pollClearMapPending())
	{
		my $database = $this->findPane($WIN_DATABASE);
		$database->onClearMap() if $database;
		my $e80 = $this->findPane($WIN_E80);
		$e80->onClearMap() if $e80;
	}

	my $wpmgr_on = ($raydp && $raydp->findImplementedService('WPMGR', 1)) ? 1 : 0;
	my $track_on = ($raydp && $raydp->findImplementedService('TRACK', 1)) ? 1 : 0;

	if ($wpmgr_on != ($this->{_wpmgr_on} // -1))
	{
		$this->{_wpmgr_on} = $wpmgr_on;
		$this->{st_wpmgr}->SetForegroundColour($wpmgr_on ? $this->{color_on} : $this->{color_off});
		$this->{st_wpmgr}->Refresh();
	}
	if ($track_on != ($this->{_track_on} // -1))
	{
		$this->{_track_on} = $track_on;
		$this->{st_track}->SetForegroundColour($track_on ? $this->{color_on} : $this->{color_off});
		$this->{st_track}->Refresh();
	}

	my $wpmgr_busy    = $apps::raymarine::NET::d_WPMGR::query_in_progress // 0;
	my $track_busy    = $apps::raymarine::NET::d_TRACK::query_in_progress // 0;
	my $wpmgr_queried = $apps::raymarine::NET::d_WPMGR::query_completed   // 0;
	my $track_queried = $apps::raymarine::NET::d_TRACK::query_completed    // 0;

	# Session is stable once WPMGR has completed a real query and no service
	# is currently downloading.  TRACK is optional: if absent, ignore it.
	my $session_stable =
		($wpmgr_on &&
		 !$wpmgr_busy &&
		 $wpmgr_queried &&
		 (!$track_on || (!$track_busy && $track_queried)))
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
	display(0, 0, "nmFrame::createPane($id) book=" . _def($book) . "  data=" . _def($data));
	return winDatabase->new($this, $book, $id, $data)  if $id == $WIN_DATABASE;
	return winE80->new($this, $book, $id, $data)       if $id == $WIN_E80;
	return winMonitor->new($this, $book, $id, $data)   if $id == $WIN_MONITOR;
	return $this->SUPER::createPane($id, $book, $data);
}


sub onCommand
{
	my ($this, $event) = @_;
	my $id = $event->GetId();
	if ($id == $WIN_DATABASE || $id == $WIN_E80 || $id == $WIN_MONITOR)
	{
		my $pane = $this->findPane($id);
		if (!$pane)
		{
			$this->createPane($id);
			if ($id == $WIN_E80 && $this->{_e80_stable})
			{
				my $e80 = $this->findPane($WIN_E80);
				$e80->onSessionStart() if $e80;
			}
		}
	}
	elsif ($id == $COMMAND_OPEN_MAP)
	{
		openMapBrowser() if !isBrowserConnected();
	}
	elsif ($id == $COMMAND_IMPORT_KML)
	{
		_doImportKML($this);
	}
	elsif ($id == $COMMAND_REFRESH_WIN_E80)
	{
		my $e80 = $this->findPane($WIN_E80);
		$e80->refresh() if $e80;
	}
	elsif ($id == $COMMAND_REFRESH_E80_DB)
	{
		_doRefreshE80Data($this);
	}
	elsif ($id == $COMMAND_CLEAR_E80_DB)
	{
		navOps::doClearE80DB($this);
	}
	elsif ($id == $COMMAND_REFRESH_DB)
	{
		my $database = $this->findPane($WIN_DATABASE);
		$database->refresh() if $database;
	}
	elsif ($id == $COMMAND_EXPORT_DB_TEXT)
	{
		_doExportDB($this);
	}
	elsif ($id == $COMMAND_IMPORT_DB_TEXT)
	{
		_doImportDB($this);
	}
	elsif ($id == $COMMAND_EXPORT_KML)
	{
		_doExportKML($this);
	}
	elsif ($id == $COMMAND_IMPORT_KML_NM)
	{
		_doImportKMLNM($this);
	}
	elsif ($id == $COMMAND_CLEAR_MAP)
	{
		my $database = $this->findPane($WIN_DATABASE);
		$database->onClearMap() if $database;
		my $e80 = $this->findPane($WIN_E80);
		$e80->onClearMap() if $e80;
	}
	elsif ($id == $COMMAND_REVERT_DB)
	{
		_doRevertDB($this);
	}
	elsif ($id == $COMMAND_COMMIT_DB)
	{
		_doCommitDB($this);
	}
	elsif ($id == $COMMAND_SAVE_OUTLINE)
	{
		my $database = $this->findPane($WIN_DATABASE);
		$database->doSaveOutline() if $database;
	}
	elsif ($id == $COMMAND_RESTORE_OUTLINE)
	{
		my $database = $this->findPane($WIN_DATABASE);
		$database->doRestoreOutline() if $database;
	}
	elsif ($id == $COMMAND_SAVE_SELECTION)
	{
		my $database = $this->findPane($WIN_DATABASE);
		if ($database)
		{
			my $dialog = Wx::TextEntryDialog->new(
				$this, 'Selection set name:', 'Save Selection', '');
			if ($dialog->ShowModal() == wxID_OK)
			{
				my $name = $dialog->GetValue();
				$database->doSaveSelection($name) if $name ne '';
			}
			$dialog->Destroy();
		}
	}
	elsif ($id == $COMMAND_RESTORE_SELECTION)
	{
		my $database = $this->findPane($WIN_DATABASE);
		if ($database)
		{
			my @names = navSelection::getSelectionSetNames();
			if (!@names)
			{
				okDialog($this, 'No saved selection sets.', 'Restore Selection');
			}
			else
			{
				my $dialog = Wx::SingleChoiceDialog->new(
					$this, 'Choose a selection set:', 'Restore Selection', \@names);
				if ($dialog->ShowModal() == wxID_OK)
				{
					my $name = $dialog->GetStringSelection();
					$database->doRestoreSelection($name);
				}
				$dialog->Destroy();
			}
		}
	}
}


sub onCloseFrame
{
	my ($this, $event) = @_;
	my $database = $this->findPane($WIN_DATABASE);
	$database->doSaveOutline() if $database;
	navDB::pruneDbVisibility();
	saveViewState();
	$this->SUPER::onCloseFrame($event);
}


sub onCommandEnable
{
	my ($this, $event) = @_;
	my $id = $event->GetId();
	my $enable = 1;

	if ($id == $COMMAND_REFRESH_WIN_E80)
	{
		$enable = 0 if !$this->findPane($WIN_E80);
	}
	elsif ($id == $COMMAND_REFRESH_E80_DB)
	{
		$enable = 0 if !($raydp && $raydp->findImplementedService('WPMGR', 1));
	}
	elsif ($id == $COMMAND_CLEAR_E80_DB)
	{
		my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR', 1) : undef;
		if (!$wpmgr)
		{
			$enable = 0;
		}
		else
		{
			my $track = $raydp ? $raydp->findImplementedService('TRACK', 1) : undef;
			$enable = 0 unless %{$wpmgr->{routes}    // {}}
			               || %{$wpmgr->{groups}    // {}}
			               || %{$wpmgr->{waypoints} // {}}
			               || ($track && %{$track->{tracks} // {}});
		}
	}
	elsif ($id == $COMMAND_REVERT_DB || $id == $COMMAND_COMMIT_DB)
	{
		my $now = time();
		if (!defined($this->{_db_dirty_time}) || $now - $this->{_db_dirty_time} >= 2)
		{
			$this->{_db_dirty_time} = $now;
			my $out = qx(git -C "C:/dat/Rhapsody" status --porcelain navMate.db 2>&1);
			$this->{_db_dirty} = ($out =~ /\S/) ? 1 : 0;
		}
		$enable = 0 if !$this->{_db_dirty};
	}

	$event->Enable($enable);
}


sub _doExportDB
{
	my ($this) = @_;
	my $default_dir = readConfig('db_backup_dir') || '';
	my $dialog = Wx::FileDialog->new(
		$this, 'Export Database',
		$default_dir, 'navMate_backup.txt',
		'Text files (*.txt)|*.txt|All files (*.*)|*.*',
		wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
	if ($dialog->ShowModal() == wxID_OK)
	{
		my $filename = $dialog->GetPath();
		writeConfig('db_backup_dir', $dialog->GetDirectory());
		my $dbh = navDB::connectDB();
		if ($dbh)
		{
			display(0,0,"nmFrame: exporting database to $filename");
			my $progress = Pub::WX::ProgressDialog->new($this, 'Exporting Database...', 0, 7);
			$dbh->exportDatabaseText($filename, $progress);
			$progress->Destroy();
			navDB::disconnectDB($dbh);
			display(0,0,"nmFrame: export complete");
		}
	}
	$dialog->Destroy();
}


sub _doImportDB
{
	my ($this) = @_;
	return if !yesNoDialog($this,
		"This will REPLACE the entire navMate database with the contents of the backup file.\n\nAre you sure?",
		'Import Database');
	my $default_dir = readConfig('db_backup_dir') || '';
	my $dialog = Wx::FileDialog->new(
		$this, 'Import Database',
		$default_dir, '',
		'Text files (*.txt)|*.txt|All files (*.*)|*.*',
		wxFD_OPEN | wxFD_FILE_MUST_EXIST);
	if ($dialog->ShowModal() == wxID_OK)
	{
		my $filename = $dialog->GetPath();
		writeConfig('db_backup_dir', $dialog->GetDirectory());
		display(0,0,"nmFrame: importing database from $filename");
		navDB::resetDB();
		my $dbh = navDB::connectDB();
		if ($dbh)
		{
			my $progress = Pub::WX::ProgressDialog->new($this, 'Importing Database...', 0, 7);
			$dbh->importDatabase($filename, $progress);
			$progress->Destroy();
			navDB::disconnectDB($dbh);
			my $database = $this->findPane($WIN_DATABASE);
			$database->refresh() if $database;
			display(0,0,"nmFrame: import complete");
		}
	}
	$dialog->Destroy();
}


sub _doExportKML
{
	my ($this) = @_;
	my $default_dir = readConfig('kml_dir') || '';
	my $dialog = Wx::FileDialog->new(
		$this, 'Export KML',
		$default_dir, 'navMate.kml',
		'KML files (*.kml)|*.kml|All files (*.*)|*.*',
		wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
	if ($dialog->ShowModal() == wxID_OK)
	{
		my $filename = $dialog->GetPath();
		writeConfig('kml_dir', $dialog->GetDirectory());
		eval { navKML::exportKML($filename) };
		error("Export KML failed: $@") if $@;
	}
	$dialog->Destroy();
}


sub _doImportKMLNM
{
	my ($this) = @_;
	my $default_dir = readConfig('kml_dir') || '';
	my $dialog = Wx::FileDialog->new(
		$this, 'Import KML',
		$default_dir, '',
		'KML files (*.kml)|*.kml|All files (*.*)|*.*',
		wxFD_OPEN | wxFD_FILE_MUST_EXIST);
	if ($dialog->ShowModal() == wxID_OK)
	{
		my $filename = $dialog->GetPath();
		writeConfig('kml_dir', $dialog->GetDirectory());
		eval { navKML::importKML($filename) };
		if ($@)
		{
			error("Import KML failed: $@");
		}
		else
		{
			my $database = $this->findPane($WIN_DATABASE);
			$database->refresh() if $database;
		}
	}
	$dialog->Destroy();
}


sub _doImportKML
{
	my ($this) = @_;
	return if !yesNoDialog($this,
		"This will DELETE and rebuild the entire navMate database from KML files.\n\nAre you sure?",
		'OneTimeImportKML');
	display(0,0,"nmFrame: ImportKML starting");
	my $rc = navDB::resetDB();
	if ($rc <= 0)
	{
		warning(0,0,"nmFrame: ImportKML aborted - resetDB returned $rc");
		return;
	}
	navOneTimeImport::run();
	my $database = $this->findPane($WIN_DATABASE);
	$database->refresh() if $database;
	display(0,0,"nmFrame: ImportKML done");
}


sub _doRefreshE80Data
{
	my ($parent) = @_;
	my $wpmgr = $raydp ? $raydp->findImplementedService('WPMGR') : undef;
	my $track = $raydp ? $raydp->findImplementedService('TRACK') : undef;
	if (!($wpmgr && $track))
	{
		okDialog($parent, "E80 not connected - cannot refresh.", "Refresh E80");
		return;
	}
	if ($apps::raymarine::NET::d_WPMGR::query_in_progress ||
	    $apps::raymarine::NET::d_TRACK::query_in_progress)
	{
		okDialog($parent, "A query is already in progress - please wait.", "Refresh E80");
		return;
	}
	my $progress = Pub::WX::ProgressDialog::newProgressData(4, 2);
	$progress->{active} = 1;
	my $dlg = Pub::WX::ProgressDialog->new($parent, 'Refreshing E80...', 1, $progress);
	return if !$dlg;
	$wpmgr->queueRefresh($progress);
	$track->queueRefresh($progress);
}


sub _doRevertDB
{
	my ($this) = @_;
	return if !yesNoDialog($this,
		"This will revert navMate.db to the last git-committed version.\n\nAre you sure?",
		'Revert navMate.db');
	my $out = qx(git -C "C:/dat/Rhapsody" restore navMate.db 2>&1);
	if ($?)
	{
		error("Revert navMate.db failed: $out");
		return;
	}
	display(0, 0, "nmFrame: navMate.db reverted to last committed version");
	my $rc = navDB::openDB();
	warning(0, 0, "nmFrame: openDB after revert returned $rc") if $rc <= 0;
	if ($rc > 0)
	{
		navDB::pruneDbVisibility();
		saveViewState();
	}
	my $database = $this->findPane($WIN_DATABASE);
	if ($database)
	{
		$database->refresh();
		$database->onBrowserConnect();
	}
}


sub _doCommitDB
{
	my ($this) = @_;
	my $dialog = Wx::TextEntryDialog->new(
		$this, 'Commit message:', 'Commit navMate.db', 'navMate.db update');
	my $result = $dialog->ShowModal();
	my $msg    = $dialog->GetValue();
	$dialog->Destroy();
	return if $result != wxID_OK || !$msg;

	my $tmp = 'C:/base_data/temp/raymarine/_db_commit_msg.txt';
	my $fh;
	if (!open($fh, '>', $tmp))
	{
		error("Commit navMate.db: cannot write temp file $tmp");
		return;
	}
	print $fh $msg;
	close $fh;

	my $out = qx(git -C "C:/dat/Rhapsody" add navMate.db 2>&1);
	if ($?)
	{
		error("Commit navMate.db git add failed: $out");
		return;
	}
	$out = qx(git -C "C:/dat/Rhapsody" commit -F "$tmp" 2>&1);
	if ($?)
	{
		error("Commit navMate.db git commit failed: $out");
		return;
	}
	display(0, 0, "nmFrame: navMate.db committed: $msg");
}


1;
