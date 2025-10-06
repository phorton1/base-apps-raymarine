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
use r_utils;
use r_RAYDP;
use r_FILESYS;
use s_resources;
use dlgProgress;
use base qw(Wx::Window MyWX::Window);

my $dbg_win = 1;		# window basics
my $dbg_sort = 1;		# sorting
my $dbg_dl = 1;			# downloads
my $dbg_rr = 0;			# request and replies


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


sub checkFileSysPorts
{
	my ($this) = @_;

	$this->{cur_filesys_id} ||= '';
	$this->{filesys_ids} ||= [];
	$this->{filesys_rayports} ||= {};

	my $any_added = 0;
	my $my_ids = $this->{filesys_ids};
	my $my_rayports = $this->{filesys_rayports};
	my $global_rayports = getRayPorts();
	for my $rayport (@$global_rayports)
	{
		next if $rayport->{name} ne 'FILESYS';
		my $id = raydpIdIfKnown($rayport->{id});	# ID or known name
		$this->{cur_filesys_id} = $id if isCurrentFILESYSRayport($rayport);
		next if $my_rayports->{$id};	# already know about it
		push @$my_ids,$id;
		$my_rayports->{$id} = $rayport;
		$any_added++;
	}
	return $any_added;
}


sub new
{
	my ($class,$frame,$book,$id,$data) = @_;
	my $this = $class->SUPER::new($book,$id);
	display(0,0,"winFILESYS::new() called");
	$this->MyWindow($frame,$book,$id,"FILESYS");

	$this->SetFont($font_fixed);
	$this->{status_ctrl} = Wx::StaticText->new($this,-1,'',[10,10]);
	$this->{command_ctrl} = Wx::StaticText->new($this,-1,'',[100,10]);

	$this->checkFileSysPorts();
	$this->{device_combo} = Wx::ComboBox->new($this, $ID_SELECT_COMBO,
		$this->{cur_filesys_id}, [400,10],[90,25],
		$this->{filesys_ids},wxCB_READONLY);

	$this->{path_ctrl} = Wx::StaticText->new($this,-1,'',[10,30]);
    my $ctrl = Wx::ListCtrl->new($this,-1,[0,$TOP_MARGIN],[-1,-1],
		wxLC_REPORT); # | wxLC_EDIT_LABELS);

	$ctrl->InsertColumn($COL_MODE, 'Mode');
	$ctrl->InsertColumn($COL_SIZE, 'Size');
	$ctrl->InsertColumn($COL_NAME, 'Name');
	$ctrl->SetColumnWidth($COL_MODE,$MODE_WIDTH);
	$ctrl->SetColumnWidth($COL_SIZE,$SIZE_WIDTH);

    $ctrl->{parent} = $this;
	$this->{list_ctrl} = $ctrl;

	$this->{vol_id} = '';
	$this->{cur_path} = '';
	$this->{last_state} = $FILE_STATE_ILLEGAL;
	$this->{started} = 0;
	$this->{pending_request} = '';

	$this->{sort_col} = $COL_NAME;
	$this->{sort_field} = 'name';
	$this->{sort_desc} = 0;
	$this->{last_sort_col} = -1;
	
	$this->SetFont($font_fixed);

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
		$this->downloadOneFile($name);
	}
}


sub onFileDeviceCombo
	# reset filter and repopulate
	# on any checkbox clicks
{
	my ($this,$event) = @_;
	# my $id = $event->GetId();
	my $combo = $event->GetEventObject();
	my $selected = $combo->GetValue();
	my $rayport = $this->{filesys_rayports}->{$selected};
	return error("huh? could not find rayport($selected)")
		if !$rayport;
	display(0,0,"Changing cur_filesys_id to $selected");
	setFILESYSRayPort($rayport);
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
}


sub changeDirectory
{
	my ($this,$to) = @_;
	display($dbg_rr,0,"change directory($to)");
	$this->setPendingRequest("dir\t$to");
	requestDirectory($to);
}


sub downloadOneFile
{
	my ($this,$name) = @_;
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

	my $dest = $d->GetPath();
	my $src = appendPath($this->{cur_path},$name);
	display($dbg_rr,0,"download file($src) to\ndest($dest)");
	$this->setPendingRequest("file\t$src\t$dest");
	requestFile($src);
}


sub getFileSizes()
{
	my ($this) = @_;

	return if $this->{recurse};
		# JIC
	return if $this->{pending_request};
		# return if in a window request
	my $state = getFileRequestState();
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
		requestSize($path);
		return;
	}
	$this->{sizes_needed} = 0;
}


sub completeRequest
{
	my ($this) = @_;
	return if !$this->{pending_request};
	display($dbg_rr,0,"completeRequest($this->{pending_request})");

	if ($this->{pending_request} =~ /recurse\t(.*)\t(.*)$/)
	{
		my ($src,$dest) = ($1,$2,$3);

		my $recurse = $this->{recurse};
		my $progress = $recurse->{progress};
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

			my $content = getFileRequestContent();
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
			my $content = getFileRequestContent();
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
	elsif ($this->{pending_request} =~ /size\t(\d+)\t/)
	{
		my $row = $1;
		my $size = getFileRequestContent();
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
	elsif ($this->{pending_request} =~ /dir\t(.*)$/)
	{
		my $path = $1;
		my $ctrl = $this->{list_ctrl};
		$ctrl->DeleteAllItems();

		my $row = 0;
		my $entries = [];
		my $content = getFileRequestContent();
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
				$item->SetTextColour($color_blue);
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
	elsif ($this->{pending_request} =~ /file\t(.*)\t(.*)$/)
	{
		my ($src,$dest) = ($1,$2);
		my $content = getFileRequestContent();
		my $len = length($content);

		display($dbg_rr,1,"SAVING FILE($len) to $dest");
		printVarToFile(1,$dest,$content,1);
		$this->{command_ctrl}->SetLabel("len($len) $dest");
		$this->{pending_request} = '';
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

    for (my $i=0; $i<$num; $i++)
    {
        if ($ctrl->GetItemState($i,wxLIST_STATE_SELECTED))
        {
            my $row = $ctrl->GetItemData($i);
            my $entry = $this->{entries}->[$row];
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
		$this->downloadOneFile($names[0]);
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
	
	my $progress = dlgProgress->new(
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
		files => $files,
		progress => $progress };

}   # doCommandSelected()


sub doOneRecurse
{
	my ($this) = @_;
	my $recurse = $this->{recurse};
	$recurse->{busy} = 1;

	my $progress = $recurse->{progress};
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
		requestFile($src) :
		requestDirectory($src);
}



#-----------------------------------
# onIdle
#-----------------------------------


sub onIdle
{
	my ($this,$event) = @_;

	my $state = getFileRequestState();
	if (!$this->{started} && (
		$state == $FILE_STATE_IDLE ||
		$state == $FILE_STATE_COMPLETE))
	{
		$this->{started} = 1;
		display($dbg_win,0,"getting root directory");
		$this->changeDirectory($ROOT_PATH);
	}

	elsif ($state != $this->{last_state})
	{
		display($dbg_win,0,"onIdle() state($this->{last_state}) changed to $state");
		my $name = fileStateName($state);
		$this->{status_ctrl}->SetLabel($name);
		$this->{status_ctrl}->SetForegroundColour(
			$state == $FILE_STATE_INIT ? $color_light_grey :
			$state == $FILE_STATE_ERROR ? $color_red :
			$state == $FILE_STATE_COMPLETE ? $color_green :
			$state == $FILE_STATE_STARTED ? $color_blue :
			$state == $FILE_STATE_PACKETS ? $color_cyan :
			wxBLACK );

		if ($state == $FILE_STATE_COMPLETE)
		{
			$this->completeRequest();
		}
		if ($state == $FILE_STATE_ERROR)
		{
			$this->{recurse} = undef;
			$this->{command_ctrl}->SetLabel(getFileRequestError());
			$this->{command_ctrl}->SetForegroundColour($color_red);
			clearFileRequestError();
			$state = getFileRequestState();
		}

		$this->{last_state} = $state;
	}
	elsif ($this->{sizes_needed})
	{
		$this->getFileSizes();
	}
	elsif ($this->{recurse} &&
		   !$this->{recurse}->{busy} &&
		   !$this->{pending_request})
	{
		$this->doOneRecurse();
	}
	elsif ($this->{recurse})
	{
		my $recurse = $this->{recurse};
		my $progress = $recurse->{progress};
		if ($progress->{cancelled})
		{
			$this->{pending_request} = '';
			$this->{recurse} = undef;
			$this->{command_ctrl}->SetLabel("CANCELLED BY USER");
			error("Cancelled by User");
			$progress->Destroy();
			return;
		}
		if ($recurse->{stage})
		{
			my $prog = getFileRequestProgress();
			if ($prog->{num} == 1)
			{
				$progress->updateSubRange(1000);
			}
			else
			{
				my $thousandths = int(($prog->{cur} / ($prog->{num}-1)) * 1000);
				$progress->updateSubRange($thousandths);
			}
		}
	}

	$event->RequestMore(1);
}



1;
