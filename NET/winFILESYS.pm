#!/usr/bin/perl
#-------------------------------------------------------------------------
# winFILESYS.pm
#-------------------------------------------------------------------------
# A Window to Access the Removable Media on the MFD (E80)

package winFILESYS;
use strict;
use warnings;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_IDLE
	EVT_SIZE
	EVT_LIST_ITEM_ACTIVATED
	EVT_LIST_COL_CLICK
	EVT_CONTEXT_MENU
	EVT_MENU
	EVT_COMBOBOX );
use Pub::Utils;
use Pub::WX::Window;
use Pub::WX::Dialogs;;
use a_defs;
use a_utils;
use c_RAYSYS;
use d_FILESYS;
use w_resources;
use x_Progress;
use base qw(Pub::WX::Window);

my $dbg_win = 1;		# window basics
my $dbg_sort = 1;		# sorting
my $dbg_dl = -1;			# downloads
my $dbg_rr = -1;			# request and replies


my $ID_SELECT_COMBO = 1002;
my $COMBO_LEFT = 100;
	# from right of window


my $TOP_MARGIN = 50;
my $LEFT_MARGIN = 10;

my $MODE_WIDTH = 80;
my $SIZE_WIDTH = 80;

my $COL_MODE = 0;
my $COL_SIZE = 1;
my $COL_NAME = 2;

my $STAGE_DIRS = 0;
my $STAGE_FILES = 1;

my $ROOT_PATH = '\\';
my $ROOT_NAME = 'ROOT';
my $UP_NAME = 'UP ..';

my $fields = [
	{ name => 'Mode' },
	{ name => 'Size' },
	{ name => 'Name' }, ];
my $sort_indicator = [' ^',' v'];


my $font_fixed = Wx::Font->new(11,wxFONTFAMILY_MODERN,wxFONTSTYLE_NORMAL,wxFONTWEIGHT_BOLD);

my $DEFAULT_SAVE_DIR = 	"/base/apps/raymarine/NET/docs/junk/dowloads";



sub appendPath
{
	my ($path,$terminal) = @_;
	$path = '' if $path eq '\\';
	$path .= "\\$terminal";
	return $path;
}



sub new
{
	my ($class,$frame,$book,$id,$data) = @_;
	my $this = $class->SUPER::new($book,$id);
	display(0,0,"winFILESYS::new() called");
	$this->MyWindow($frame,$book,$id,'FILESYS',$data);

	$this->{vol_id} = '';
	$this->{cur_path} = '';
	$this->{last_state} = $FILE_STATE_ILLEGAL;
	$this->{started} = 0;
	$this->{pending_request} = '';

	$this->{sort_col} = $COL_NAME;
	$this->{sort_field} = 'name';
	$this->{sort_desc} = 0;
	$this->{last_sort_col} = -1;

	$this->{cur_filesys_id} = '';
	$this->{filesys_ports} = {};
	$this->{disconnect_reported} = '';

	$this->{recurse} = undef;

	$this->SetFont($font_fixed);
	$this->{status_ctrl} = Wx::StaticText->new($this,-1,'',[10,10]);
	$this->{command_ctrl} = Wx::StaticText->new($this,-1,'',[100,10]);
	$this->{path_ctrl} = Wx::StaticText->new($this,-1,'',[10,30]);

	$this->{device_combo} = Wx::ComboBox->new($this, $ID_SELECT_COMBO,'',[400,10],[90,25],[],wxCB_READONLY);

    my $ctrl = $this->{list_ctrl} = Wx::ListCtrl->new($this,-1,[0,$TOP_MARGIN],[-1,-1], wxLC_REPORT); # | wxLC_EDIT_LABELS);
    $ctrl->{parent} = $this;
	$ctrl->InsertColumn($COL_MODE, 'Mode');
	$ctrl->InsertColumn($COL_SIZE, 'Size');
	$ctrl->InsertColumn($COL_NAME, 'Name');
	$ctrl->SetColumnWidth($COL_MODE,$MODE_WIDTH);
	$ctrl->SetColumnWidth($COL_SIZE,$SIZE_WIDTH);

	$this->checkFilesysPorts();

	EVT_SIZE($this,\&onSize);
	EVT_IDLE($this,\&onIdle);
    EVT_LIST_ITEM_ACTIVATED($ctrl,-1,\&onDoubleClick);
	EVT_LIST_COL_CLICK($ctrl,-1,\&onClickColHeader);
    EVT_CONTEXT_MENU($ctrl,\&onContextMenu);
	EVT_MENU($this,$CMD_DOWNLOAD,\&downloadSelected);
	EVT_COMBOBOX($this,$ID_SELECT_COMBO,\&onFileDeviceCombo);

	$this->onSize();
	return $this;
}


sub onSize
{
	my ($this,$event) = @_;
	my $sz = $this->GetSize();
    my $width = $sz->GetWidth();
    my $height = $sz->GetHeight();

	my $combo_left = $width - $COMBO_LEFT;
	$this->{device_combo}->Move($combo_left,10);

    my $list_ctrl = $this->{list_ctrl};
	$list_ctrl->SetSize([$width,$height-$TOP_MARGIN]);

	my $mode_width = $list_ctrl->GetColumnWidth($COL_MODE);
	my $size_width = $list_ctrl->GetColumnWidth($COL_SIZE);

	$list_ctrl->SetColumnWidth(0,$mode_width);
	$list_ctrl->SetColumnWidth(1,$SIZE_WIDTH);
	$list_ctrl->SetColumnWidth(2,$width-$mode_width-$SIZE_WIDTH);

}


sub onDoubleClick
    # {this} is the list control
{
    my ($ctrl,$event) = @_;
    my $this = $ctrl->{parent};
	my $filesys = $this->{filesys};
	return error("no filesys") if !$filesys;

    my $item = $event->GetItem();
    my $row = $item->GetData();
    my $entry = $this->{entries}->[$row];
	my $name = $entry->{name};
    my $is_dir = $entry->{is_dir};

    display($dbg_win,1,"onDoubleClick($row) is_dir=$is_dir name=$name");

    if ($is_dir)
    {
        return if $name eq 'ROOT';
        my $path = $this->{cur_path};
        if ($name eq 'UP ..')
        {
            $path =~ /(.*)\\(.+)?$/;
			$path = $1;
			$path = '\\' if !$path;
        }
        else
        {
			$path = appendPath($path,$name);
        }
		$this->changeDirectory($path);
    }

	# double click on file

    else
	{
		$this->downloadOneFile($entry);
	}
}


sub onFileDeviceCombo
	# reset filter and repopulate
	# on any checkbox clicks
{
	my ($this,$event) = @_;
	my $filesys = $this->{filesys};
	return error("no filesys") if !$filesys;

	# my $id = $event->GetId();
	my $combo = $event->GetEventObject();
	my $selected = $combo->GetValue();
	my $service_port = $this->{filesys_ports}->{$selected};
	return error("huh? could not find service_port($selected)")
		if !$service_port;
	display(0,0,"Changing cur_filesys_id to $selected");
	$filesys->setServicePort($service_port);
	$this->{cur_filesys_id} = $selected;
	$this->{started} = 0;	# trigger a get of /
}




#-------------------------------------------------
# commands and replies
#-------------------------------------------------

sub setPendingRequest
{
	my ($this,$request) = @_;
	$this->{pending_request} = $request;
	$this->{command_ctrl}->SetLabel($request);
	$this->{command_ctrl}->SetForegroundColour(wxBLACK);
	# $this->{last_state} = $FILE_STATE_IDLE;
		# make sure we notice a change to $FILE_STATE_COMPLETE or ERROR
		# as we might have left it at FILE_STATE_COMPLETE
}


sub changeDirectory
{
	my ($this,$to) = @_;
	my $filesys = $this->{filesys};
	return error("no filesys") if !$filesys;

	display($dbg_rr,0,"change directory($to)");
	$this->setPendingRequest("dir\t$to");
	$filesys->fileCommand('DIR',$to);
}


sub downloadOneFile
{
	my ($this,$entry) = @_;
	my $filesys = $this->{filesys};
	return error("no filesys") if !$filesys;

	my $name = $entry->{name};
	my $full_name = "$DEFAULT_SAVE_DIR/$name";
	my $d = Wx::FileDialog->new($this,
		"Save As...",
		$full_name,
		$name,
		"Any (*.*)|*.*",
		wxFD_SAVE | wxFD_OVERWRITE_PROMPT);
	my $rslt = $d->ShowModal();
	$d->Destroy();
	return if ($rslt == wxID_CANCEL);

	my $size = $entry->{size};
	if ($size > 1000000)
	{
		my $progress = $this->{progress} = x_Progress->new(
			$this,
			'download',
			1,
			0);
		# $progress->setEntry($full_name);
		$progress->setSubRange(1000,$full_name);
	}

	my $dest = $d->GetPath();
	my $src = appendPath($this->{cur_path},$name);
	display($dbg_rr,0,"download file($src) to\ndest($dest)");
	$this->setPendingRequest("file\t$src\t$dest");
	$filesys->fileCommand('FILE',$src);
}


sub getFileSizes()
{
	my ($this) = @_;
	my $filesys = $this->{filesys};
	return error("no filesys") if !$filesys;

	return if $this->{recurse};
		# JIC
	return if $this->{pending_request};
		# return if in a window request
	my $state = $filesys->getState();
	return if $state > 0;
		# return if FILESYS busy
	if ($state == $FILE_STATE_ERROR)
	{
		# stop if there are any errors
		$this->{sizes_needed} = 0;
		return;
	}

	display($dbg_win,0,"getFileSizes() state=$state");

	my $row = 0;
	my $entries = $this->{entries};
	my $cur_path = $this->{cur_path};
	for my $entry (@$entries)
	{
		my $this_row = $row++;
		next if $entry->{is_dir};
		next if defined($entry->{size});

		my $path = appendPath($cur_path,$entry->{name});
		display($dbg_rr,1,"getFileSize($this_row,$path)");
		$this->setPendingRequest("size\t$this_row\t$path");
		$filesys->fileCommand('SIZE',$path);
		return;
	}
	$this->{sizes_needed} = 0;
}


sub completeRequest
{
	my ($this) = @_;
	my $filesys = $this->{filesys};
	return error("no filesys") if !$filesys;

	my $pending_request = $this->{pending_request} || '';
	display($dbg_rr,0,"completeRequest() pending_request($pending_request)");
	return if !$pending_request;


	if ($pending_request =~ /recurse\t(.*)\t(.*)$/)
	{
		my ($src,$dest) = ($1,$2,$3);

		my $recurse = $this->{recurse};
		my $progress = $this->{progress};
		my $stage = $recurse->{stage};
		my $what_name = $stage ? 'file' : 'dir';
		my $array_name = $what_name.'s';
		my $idx_name = $what_name.'_idx';
		my $idx = $recurse->{$idx_name};
		my $array = $recurse->{$array_name};
		my $num = @$array;

		display($dbg_dl,0,"completeRecurssive($what_name) $idx/$num\nsrc($src)\ndest($dest)");

		$idx++;
		$recurse->{$idx_name} = $idx;
		
		if ($stage)
		{
			$dest =~ s/\\/\//g;
				# switch to unix (perl) delimiter for my_mmkdir
			if (!my_mkdir($dest,1))
			{
				error("Could not create destination directory for file($dest)");
				$this->{pending_request} = '';
				$this->{recurse} = undef;
				return;
			}

			my $content = $filesys->getContent();
			my $len = length($content);
			$recurse->{bytes} += $len;
			
			display($dbg_dl,1,"SAVING RECURSIVE FILE($len) to $dest");
			printVarToFile(1,$dest,$content,1);

			if ($idx >= $num)
			{
				my $num_dirs = @{$recurse->{dirs}};
				my $num_files = @{$recurse->{files}};
				my $bytes = $recurse->{bytes};
				
				my $msg = "RECURSIVE DOWNLOAD FINISHED";
				$msg .= " $num_dirs Dirs" if $num_dirs;
				$msg .= " $num_files Files" if $num_files;
				$msg .= " ".prettyBytes($bytes)." Bytes" if $num_files;

				display($dbg_rr,1,$msg);
				$this->{command_ctrl}->SetLabel($msg);
				$this->{pending_request} = '';
				$this->{recurse} = undef;
				$progress->Destroy();
				return;
			}
			$progress->setDone(0);	# file done
		}
		else
		{
			my $unix_dest = $dest;
			$unix_dest =~ s/\\/\//g;

			if (!my_mkdir($unix_dest))
			{
				error("Could not create destination directory($unix_dest)");
				$this->{pending_request} = '';
				$this->{recurse} = undef;
				return;
			}
			my $dirs = $recurse->{dirs};
			my $files = $recurse->{files};
			my $content = $filesys->getContent();
			my $num_added_files = 0;
			my $num_added_dirs = 0;
			for my $line (split(/\n/,$content))
			{
				my ($attr,$name) = split(/\t/,$line);
				next if $name eq '.';
				next if $name eq '..';
				next if $attr & $FAT_VOLUME_ID;

				my $is_dir = $attr & $FAT_DIRECTORY ? 1 : 0;
				$is_dir ?
					$num_added_dirs++ :
					$num_added_files++;
				display($dbg_dl,1,"add recursive is_dir($is_dir) $name");
				
				my $add_array = $is_dir?$dirs:$files;
				push @$add_array,{
					src => appendPath($src,$name),
					dest => appendPath($dest,$name)};
			}

			$progress->addFilesAndDirs($num_added_files,$num_added_dirs)
				if $num_added_dirs || $num_added_files;
			$progress->setDone(1);	# dir done

			if ($idx >= @$dirs)
			{
				display($dbg_rr,1,"RECURSIVE TRAVERSAL FINISHED");
				$this->{command_ctrl}->SetLabel('RECURSIVE TRAVERSAL FINISHED');
				$recurse->{stage}++;
			}
		}

		$this->{pending_request} = '';
		$recurse->{busy} = 0;
	}
	elsif ($pending_request =~ /size\t(\d+)\t/)
	{
		my $row = $1;
		my $size = $filesys->getContent();
		my $entries = $this->{entries};
		my $entry = $entries->[$row];

		display($dbg_win,1,"setting row($row) size($size) $entry->{name}");
		$entry->{size} = $size;
		my $ctrl = $this->{list_ctrl};

		# grumble, there's no good way to find the index of the list
		# item based on the row. So here we do a brute linear search

		my $item_row = -1;
		my $num_rows = @$entries;
		for (my $i=0; $i<=$num_rows; $i++)
		{
			if ($ctrl->GetItemData($i) == $row)
			{
				$item_row = $i;
				last;
			}
		}
		$ctrl->SetItem($item_row,$COL_SIZE,prettyBytes($size));
		$this->sortList() if $this->{sort_col} == $COL_SIZE;
		$this->{command_ctrl}->SetLabel('');
		$this->{pending_request} = '';
	}
	elsif ($pending_request =~ /dir\t(.*)$/)
	{
		my $path = $1;
		my $ctrl = $this->{list_ctrl};
		$ctrl->DeleteAllItems();

		my $row = 0;
		my $entries = [];
		my $content = $filesys->getContent();
		print "got content: $content\n";
		
		for my $line (split(/\n/,$content))
		{
			my ($attr,$name) = split(/\t/,$line);
			next if $name eq '..';

			my $is_dir = $attr & $FAT_DIRECTORY ? 1 : 0;
			if ($attr & $FAT_VOLUME_ID)
			{
				$is_dir = 1;
				$this->{vol_id} = $name.':';
				$name = $ROOT_NAME;
			}
			elsif ($name eq '.')
			{
				$is_dir = 1;
				$name = $UP_NAME;
			}

			my $mode = '';
			$mode .= 'r' if $attr & $FAT_READ_ONLY;
			$mode .= 'h' if $attr & $FAT_HIDDEN;
			$mode .= 's' if $attr & $FAT_SYSTEM;
			my $entry = {
				is_dir	=> $is_dir,
				name	=> $name,
				mode	=> $mode,
				path	=> appendPath($path,$name),
			};
			push @$entries,$entry;

			$ctrl->InsertStringItem($row,$mode);
			$ctrl->SetItemData($row,$row);
			$ctrl->SetItem($row,$COL_NAME,$name);

			if ($is_dir)
			{
				my $item = $ctrl->GetItem($row);
				$item->SetTextColour($wx_color_blue);
				$ctrl->SetItem($item);
			}
			$row++;
		}

		$this->{cur_path} = $path;
		$this->{path_ctrl}->SetLabel($this->{vol_id}.$path);
		$this->{entries} = $entries;
		$this->sortList();
		$this->{command_ctrl}->SetLabel('');
		$this->{pending_request} = '';
		$this->{sizes_needed} = 1;
	}
	elsif ($pending_request =~ /file\t(.*)\t(.*)$/)
	{
		my ($src,$dest) = ($1,$2);
		my $content = $filesys->getContent();
		my $len = length($content);

		display($dbg_rr,1,"SAVING FILE($len) to $dest");
		printVarToFile(1,$dest,$content,1);
		$this->{command_ctrl}->SetLabel("len($len) $dest");
		$this->{pending_request} = '';
		$this->{progress}->Destroy() if $this->{progress};
		$this->{progress} = undef;
	}
	else
	{
		$this->{pending_request} = '';
	}
}



#----------------------------------------------------
# sort
#----------------------------------------------------

sub onClickColHeader
{
    my ($ctrl,$event) = @_;
    my $this = $ctrl->{parent};
    # return if (!$this->checkConnected());

    my $col = $event->GetColumn();
    my $prev_col = $this->{sort_col};
    display($dbg_sort,0,"onClickColHeader($col) prev_col=$prev_col desc=$this->{sort_desc}");

    # set the new sort specification

    if ($col == $this->{sort_col})
    {
        $this->{sort_desc} = $this->{sort_desc} ? 0 : 1;
    }
    else
    {
        $this->{sort_col} = $col;
        $this->{sort_desc} = 0;
    }

    # sort it

    $this->sortList();

    # remove old indicator

    if ($prev_col != $col)
    {
        my $item = $ctrl->GetColumn($prev_col);
        $item->SetMask(wxLIST_MASK_TEXT);
        $item->SetText($fields->[$prev_col]->{name});
        $ctrl->SetColumn($prev_col,$item);
    }

    # set new indicator

    my $sort_char = $sort_indicator->[$this->{sort_desc}];
    my $item = $ctrl->GetColumn($col);
    $item->SetMask(wxLIST_MASK_TEXT);
    $item->SetText($fields->[$col]->{name}.$sort_char);
    $ctrl->SetColumn($col,$item);

}   # onClickColHeader()



sub comp	# for sort, not for conmpare
{
    my ($this,$sort_col,$desc,$index_a,$index_b) = @_;
	my $ctrl = $this->{list_ctrl};
	# my $entry_a = $ctrl->GetItemText($index_a);
	# my $entry_b = $ctrl->GetItemText($index_b);
	my $entry_a = $this->{entries}->[$index_a];
	my $entry_b = $this->{entries}->[$index_b];

    display($dbg_sort+1,0,"comp $index_a=$entry_a->{name} $index_b=$entry_b->{name}");

    # The ...UP... or ...ROOT... entry is always first

    my $retval;
    if (!$index_a)
    {
        return -1;
    }
    elsif (!$index_b)
    {
        return 1;
    }

    # directories are always at the top of the list

    elsif ($entry_a->{is_dir} && !$entry_b->{is_dir})
    {
        $retval = -1;
        display($dbg_sort+1,1,"comp_dir($entry_a->{name},$entry_b->{name}) returning -1");
    }
    elsif ($entry_b->{is_dir} && !$entry_a->{is_dir})
    {
        $retval = 1;
        display($dbg_sort+1,1,"comp_dir($entry_a->{name},$entry_b->{name}) returning 1");
    }

    elsif ($entry_a->{is_dir} && $sort_col != $COL_NAME)
    {
		# we sort directories ascending except on the name field
		$retval = (lc($entry_a->{name}) cmp lc($entry_b->{name}));
        display($dbg_sort+1,1,"comp_same_dir($entry_a->{name},$entry_b->{name}) returning $retval");
    }
    else
    {
		my $field = lc($fields->[$sort_col]->{name});
        my $val_a = $entry_a->{$field};
        my $val_b = $entry_b->{$field};
        $val_a = '' if !defined($val_a);
        $val_b = '' if !defined($val_b);
        my $val_1 = $desc ? $val_b : $val_a;
        my $val_2 = $desc ? $val_a : $val_b;

        if ($sort_col == $COL_SIZE)     # size uses numeric compare
        {
            $retval = ($val_1 <=> $val_2);
        }
        else
        {
            $retval = (lc($val_1) cmp lc($val_2));
        }

		# i'm not seeing any ext's here

        display($dbg_sort+1,1,"comp($field,$sort_col,$desc,$val_a,$val_b) returning $retval");
    }
    return $retval;

}   # comp() - compare two infos for sorting



sub sortList
{
	my ($this) = @_;

    my $ctrl = $this->{list_ctrl};
    my $sort_col = $this->{sort_col};
    my $sort_desc = $this->{sort_desc};

    display($dbg_sort,0,"sortList($sort_col,$sort_desc)");

	# $a and $b are the indexes into $this->{list]
	# that we set via SetUserData() in the initial setListRow()

    $ctrl->SortItems(sub {
        my ($a,$b) = @_;
		return comp($this,$sort_col,$sort_desc,$a,$b); });

	# now that they are sorted, {list} no longer matches the contents by row

    $this->{last_sortcol} = $sort_col;
    $this->{last_desc} = $sort_desc;

}


#----------------------------------------------------
# recursive download selected items
#----------------------------------------------------

sub onContextMenu
{
    my ($ctrl,$event) = @_;
    my $this = $ctrl->{parent};
    display($dbg_win,0,"onContextMenu()");
    my $menu = Pub::WX::Menu::createMenu('filesys_context_menu');
	$this->PopupMenu($menu,[-1,-1]);
}


sub downloadSelected
{
    my ($this) = @_;
	
	my $cur_path = $this->{cur_path};

	my $files = [];
	my $dirs  = [];
	my @names;

	$this->{recursive} =
    my $ctrl = $this->{list_ctrl};
    my $num_files = 0;
    my $num_dirs = 0;
    my $num = $ctrl->GetItemCount();

    display($dbg_dl,1,"downloadSelected(".$ctrl->GetSelectedItemCount()."/$num) selected items");

    # build a list of the selected entries

	my $default_ug = '';
	my $default_mode = '';
	my $single_entry = '';

    for (my $i=0; $i<$num; $i++)
    {
        if ($ctrl->GetItemState($i,wxLIST_STATE_SELECTED))
        {
            my $row = $ctrl->GetItemData($i);
            my $entry = $this->{entries}->[$row];
			$single_entry = $entry;
			my $name = $entry->{name};
			next if $name eq $ROOT_NAME || $name eq $UP_NAME;
			
            my $is_dir = $entry->{is_dir};

            $num_dirs++ if $is_dir;
            $num_files++ if !$is_dir;

            display($dbg_dl+1,2,"selected is_dir($is_dir) $name");

			push @names,$name;
			my $array = $is_dir?$dirs:$files;
			push @$array,{
				src => appendPath($cur_path,$name),
				dest => $name };
        }
    }

    # build a message saying what will be affected
	# do single file separately

    my $file_and_dirs = '';
    if ($num_files == 0 && $num_dirs == 1)
    {
        $file_and_dirs = "the directory '$names[0]'";
    }
    elsif ($num_dirs == 0 && $num_files == 1)
    {
		$this->downloadOneFile($single_entry);
		return;
    }
    elsif ($num_files == 0)
    {
        $file_and_dirs = "$num_dirs directories";
    }
    elsif ($num_dirs == 0)
    {
        $file_and_dirs = "$num_files files";
    }
    else
    {
        $file_and_dirs = "$num_dirs directories and $num_files files";
    }

	# Folder Selection Dialog

	my $save_dir = "C:$DEFAULT_SAVE_DIR";
	$save_dir =~ s/\//\\/g;

	my $d = Wx::DirDialog->new($this,
		"Select forder to $file_and_dirs?",
		$save_dir,
        wxDD_DEFAULT_STYLE | wxDD_DIR_MUST_EXIST);
	my $rslt = $d->ShowModal();
	$d->Destroy();
	return if ($rslt == wxID_CANCEL);
	my $save_path = $d->GetPath();
	$save_path =~ s/^C://;
	$save_path =~ s/\\/\//g;
	display($dbg_dl,0,"DirDialog() returned path=$save_path");

	# apply the path to all the destinations

	for my $dir (@$dirs)
	{
		$dir->{dest} = appendPath($save_path,$dir->{dest});
	}
	for my $file (@$files)
	{
		$file->{dest} = appendPath($save_path,$file->{dest});
	}

	# start the recursive file download
	
	$this->{progress} = x_Progress->new(
		$this,
		'download',
		$num_files,
		$num_dirs);
	$this->{recurse} = {
		bytes => 0,
		busy => 0,
		stage => $num_dirs ? $STAGE_DIRS : $STAGE_FILES,
		dir_idx => 0,
		file_idx => 0,
		dirs => $dirs,
		files => $files };

}   # doCommandSelected()


sub doOneRecurse
{
	my ($this) = @_;
	my $filesys = $this->{filesys};
	return error("no filesys") if !$filesys;
	
	my $recurse = $this->{recurse};
	$recurse->{busy} = 1;

	my $progress = $this->{progress};
	my $stage = $recurse->{stage};
	my $what_name = $stage ? 'file' : 'dir';

	my $array_name = $what_name.'s';
	my $idx_name = $what_name.'_idx';
	my $array = $recurse->{$array_name};
	my $idx = $recurse->{$idx_name};
	my $item = $array->[$idx];
	my $src = $item->{src};
	my $dest = $item->{dest};
	my $num = @$array;

	display($dbg_rr,0,"doOneRecurse($stage,STAGE_".uc($what_name).") $idx/$num\n".
		"src($src)\ndest($dest)");

	$progress->setEntry($src) if !$stage;
	$progress->setSubRange(1000,$src) if $stage;

	$this->setPendingRequest("recurse\t$src\t$dest");

	$stage ?
		$filesys->fileCommand('FILE',$src) :
		$filesys->fileCommand('DIR',$src);
}



#-----------------------------------
# onIdle
#-----------------------------------

sub onIdle
{
	my ($this,$event) = @_;
	$event->RequestMore(1);
	return if !$this->checkFilesysPorts();

	my $filesys = $this->{filesys};
	my $state = $filesys->getState();
	my $state_name = $FILE_STATE_NAME{$state};

	if (!$this->{started} && (
		$state == $FILE_STATE_IDLE ||
		$state == $FILE_STATE_COMPLETE))
	{
		$this->{started} = 1;
		display($dbg_win,0,"getting root directory",0,$UTILS_COLOR_LIGHT_MAGENTA);
		$this->changeDirectory($ROOT_PATH);
		return;
	}

	my $progress = $this->{progress};
	my $recurse = $this->{recurse};
	my $do_progress = !$recurse || $recurse->{stage};
	if ($progress)
	{
		if ($progress->{cancelled})
		{
			$this->clearEverything($filesys);
			$this->{command_ctrl}->SetLabel("CANCELLED BY USER");
			error("Cancelled by User");
			$progress->Destroy();
			return;
		}

		my ($total,$got) = $filesys->getProgress();
		if (!$got || !$total)
		{
			$progress->updateSubRange(0);
		}
		else
		{
			# fudge 1/20th for problem with bar disappearing
			# before the file is really done
			my $thousandths = int(($got / $total) * 1000);
			$progress->updateSubRange($thousandths);
		}
	}

	if ($state != $this->{last_state})
	{
		my $name = $FILE_STATE_NAME{$state};
		my $old_name = $FILE_STATE_NAME{$this->{last_state}};
		display($dbg_win,0,"onIdle() state($old_name) changed to $name");

		if ($state != $FILE_STATE_BUSY)
		{
			$this->{status_ctrl}->SetLabel($name);
			$this->{status_ctrl}->SetForegroundColour(
				$state == $FILE_STATE_ILLEGAL ?	 $wx_color_light_grey :
				$state == $FILE_STATE_ERROR ? 	 $wx_color_red :
				$state == $FILE_STATE_COMPLETE ? $wx_color_green :
				$state == $FILE_STATE_START ?  	 $wx_color_blue :
				$state == $FILE_STATE_BUSY ?  	 $wx_color_cyan :
				wxBLACK );
		}

		if ($state == $FILE_STATE_COMPLETE)
		{
			$this->completeRequest();
		}
		if ($state == $FILE_STATE_ERROR)
		{
			$this->{recurse} = undef;
			$this->{command_ctrl}->SetLabel($filesys->getError());
			$this->{command_ctrl}->SetForegroundColour($wx_color_red);
			$filesys->clearError();
			$state = $filesys->getState();
		}
		$this->{last_state} = $state;
		return;
	}

	if ($this->{sizes_needed})
	{
		$this->getFileSizes();
		return;
	}

	if ($this->{recurse} &&
		!$this->{recurse}->{busy} &&
		!$this->{pending_request})
	{
		$this->doOneRecurse();
		return;
	}


}


sub clearEverything
{
	my ($this,$filesys) = @_;

	display($dbg_win,0,"clearEverything()",0,$UTILS_COLOR_LIGHT_MAGENTA);

	$filesys->killAllJobs() if $filesys;
	
	$this->{list_ctrl}->DeleteAllItems();
	$this->{device_combo}->Clear();
	$this->{command_ctrl}->SetLabel('');
	$this->{path_ctrl}->SetLabel('');
	$this->{status_ctrl}->SetLabel('');

	$this->{started} = 0;
	$this->{cur_filesys_id} = '';
	$this->{vol_id} = '';
	$this->{cur_path} = '';
	$this->{last_state} = $FILE_STATE_ILLEGAL;
	$this->{pending_request} = '';
	$this->{recurse} = undef;

	$this->{progress}->Destroy() if $this->{progress};
	$this->{progress} = undef;
}



sub checkFilesysPorts
{
	my ($this) = @_;
	lock($raysys);
	
	# see if FILESYS is running, return if not

	my $filesys = $this->{filesys} = $raysys->findImplementedService('FILESYS',1);
	if (!$filesys || !$filesys->{running})
	{
		my $msg = $filesys?
			'FILESYS not running' :
			'NO FILESYS service_port!!';
		if ($this->{disconnect_reported} ne $msg)
		{
			warning($dbg_win-1,0,"No Filesys or not running",0,$UTILS_COLOR_LIGHT_MAGENTA);
			$this->{disconnect_reported} = $msg;
			$filesys->setState($FILE_STATE_IDLE) if $filesys;

			$this->clearEverything($filesys);
			$this->{filesys_ports} = {};
			$this->{status_ctrl}->SetLabel($msg);
			$this->{status_ctrl}->SetForegroundColour($wx_color_red);
		}
		return;
	}
	$this->{disconnect_reported} = '';


	# add and delete local copies of FILESYS service_ports

	my $my_ports = $this->{filesys_ports};
	my $raysys_ports = $raysys->getServicePortsByAddr();

	for my $device_id (sort keys %$my_ports)
	{
		$my_ports->{$device_id}->{found} = 0;
	}

	my $num_added = 0;
	for my $addr (sort keys %$raysys_ports)
	{
		my $service_port = $raysys_ports->{$addr};
		next if $service_port->{name} ne 'FILESYS';

		my $device_id = $service_port->{device_id};

		if ($my_ports->{$device_id})
		{
			$my_ports->{$device_id}->{found} = 1;
		}
		else
		{
			display($dbg_win,0,"adding $service_port->{addr} $device_id",0,$UTILS_COLOR_LIGHT_MAGENTA);
			my $port = $my_ports->{$device_id} = {};
			mergeHash($port,$service_port);
			$port->{found} = 1;
			$num_added++;
		}
	}

	my $num_deleted = 0;
	for my $device_id (sort keys %$my_ports)
	{
		my $port = $my_ports->{$device_id};
		if (!$port->{found})
		{
			display($dbg_win,0,"deleting $port->{addr} $device_id",0,$UTILS_COLOR_LIGHT_MAGENTA);
			delete $my_ports->{$device_id};
			$num_deleted++;
		}
	}

	# handle the combo box and cur_filesys_id

	if ($num_added || $num_deleted)
	{
		my $cur_id = $this->{cur_filesys_id};
		if (!$my_ports->{$cur_id})
		{
			$this->clearEverything($filesys);
			$cur_id = '';
		}
		
		my $combo = $this->{device_combo};
		$combo->Clear();
		
		my @ids = sort keys %$my_ports;
		display($dbg_win,0,"rebuilding combo(".join(' ',@ids).")",0,$UTILS_COLOR_LIGHT_MAGENTA);

		for my $device_id (@ids)
		{
			$combo->Append($device_id);
		}

		if (@ids && !$this->{cur_filesys_id})
		{
			my $device_id = $this->{cur_filesys_id} = $ids[0];
			my $port = $my_ports->{$device_id};
			display($dbg_win,0,"setting cur_filesys_id($port->{addr} $device_id",0,$UTILS_COLOR_LIGHT_MAGENTA);
			$filesys->setServicePort($port);
			$combo->SetValue($device_id);
		}
		elsif ($cur_id)
		{
			$combo->SetValue($cur_id);
		}
	}
	
	return 1;
}


1;
