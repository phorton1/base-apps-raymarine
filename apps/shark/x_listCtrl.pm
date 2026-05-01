package x_listCtrl;
use strict;
use warnings;
use threads;
use threads::shared;
use Wx qw(:everything);
use Wx::Event qw(
	EVT_SIZE
	EVT_PAINT
	EVT_MOUSEWHEEL
	EVT_SCROLLWIN
	EVT_LEFT_UP );
use apps::raymarine::NET::a_utils;
use Pub::Utils;
use base qw(Wx::ScrolledWindow);

my $dbg = 0;

my $CHANGE_TIMEOUT = 5;

my $LINE_SCALING   = 1.1;		# * CHAR_HEIGHT
my $HEADER_SIZE	   = 1.5;		# * LINE_HEIGHT
my $HEADER_MARGIN  = 0.3;		# * LINE_HEIGHT

my @fonts = map { Wx::Font->new($_, wxFONTFAMILY_MODERN, wxFONTSTYLE_NORMAL, wxFONTWEIGHT_BOLD) } (3..36);


sub new
{
    my ($class, $parent, $parent_top, $columns) = @_;
    my $sz = $parent->GetSize();
    my $width = $sz->GetWidth();
    my $height = $sz->GetHeight() - $parent_top;
    my $this = $class->SUPER::new($parent, -1, [0, $parent_top], [$width, $height]);
    bless $this, $class;

    $this->{parent} = $parent;
	$this->{parent_top} = $parent_top;
    $this->{columns} = $columns;
    $this->{recs} = {};
    $this->{zoom_level} = 6;
    $this->{LINE_HEIGHT} = 0;
    $this->{CHAR_WIDTH} = 0;
	$this->{LONGEST_LAST} = 0;
    $this->{redraw_all} = 1;
	$this->{scroll_y} = 0;
	$this->{scroll_x} = 0;
	$this->{last_scroll_y} = 0;
	$this->{last_scroll_x} = 0;
	$this->{sort_col} = 0;
	$this->{sort_desc} = 0;
	$this->{sorted_keys} = [];

    my $line_chars = 0;
    for (my $i=0; $i<@$columns-1; $i++)
	{
        $line_chars += $$columns[$i]->{width};
    }
    $this->{LINE_CHARS} = $this->{ALL_BUT_LAST} = $line_chars;
	display($dbg+1,0,"ALL_BUT_LAST=$line_chars");

    $this->SetBackgroundColour(wxWHITE);
    $this->SetBackgroundStyle(wxBG_STYLE_CUSTOM);
    $this->setZoomLevel($this->{zoom_level});

    EVT_SIZE($this, \&onSize);
    EVT_PAINT($this, \&onPaint);
    EVT_MOUSEWHEEL($this, \&onMouseWheel);
	EVT_SCROLLWIN($this,\&onScroll);
	EVT_LEFT_UP($this, \&onMouseDown);
    return $this;
}


sub onScroll
{
    my ($this, $event) = @_;
	my $pos = $event->GetPosition();             # Scroll position in scroll units
    my $orientation = $event->GetOrientation();  # wxVERTICAL or wxHORIZONTAL
	$this->{scroll_y} = $pos if $orientation == wxVERTICAL;
	$this->{scroll_x} = $pos if $orientation == wxHORIZONTAL;
	display($dbg+1,0,"scroll xy($this->{scroll_x},$this->{scroll_y})");
    $this->{redraw_all} = 1;
    $this->Refresh();
}


sub onSize
{
    my ($this, $event) = @_;
	my $parent = $this->{parent};
    my $sz = $parent->GetSize();
    my $width = $sz->GetWidth();
    my $height = $sz->GetHeight() - $this->{parent_top};
	$this->SetSize($width,$height);
    $this->{redraw_all} = 1;
    $this->Refresh();

	$this->{scroll_y} = $this->GetScrollPos(wxVERTICAL);
	$this->{scroll_x} = $this->GetScrollPos(wxHORIZONTAL);
}


sub onMouseWheel
{
    my ($this, $event) = @_;
    if ($event->GetWheelRotation && $event->ControlDown())
	{
        my $delta = $event->GetWheelRotation();
        $this->setZoomLevel($this->{zoom_level} + ($delta > 0 ? 1 : -1));
    }
	else
	{
        $event->Skip;
    }
}

sub onMouseDown
{
    my ($this, $event) = @_;
    my $x = $event->GetX();
    my $y = $event->GetY();

	display($dbg+2,0,"onMouseDown($x,$y)");

    my $line_height = $this->{LINE_HEIGHT};
    # Only respond to clicks within header row
	# in abs coordinates
    return if !($y <= $line_height * $HEADER_SIZE);

    my $char_width = $this->{CHAR_WIDTH};
    my $cols = $this->{columns};
    my $last_col = @$cols - 1;
    my $col_x = 0;

    for my $i (0..$last_col)
	{
        my $field_width = $char_width * ($i == $last_col ?
            $this->{LONGEST_LAST} + 20 :
            $cols->[$i]->{width});

        if ($x >= $col_x && $x < $col_x + $field_width)
		{
            $this->onClickHeaderCol($i);
            last;
        }

        $col_x += $field_width;
    }
}



#-------------------------------------------------
# window handling
#-------------------------------------------------

sub setZoomLevel
{
    my ($this, $level) = @_;
    $level = 0 if $level < 0;
    $level = @fonts - 1 if $level > @fonts - 1;
    $this->{zoom_level} = $level;

    my $dc = Wx::ClientDC->new($this);
    $dc->SetFont($fonts[$level]);
    $this->{CHAR_WIDTH} = $dc->GetCharWidth();
    $this->{LINE_HEIGHT} = int($dc->GetCharHeight() * $LINE_SCALING);

    $this->SetScrollRate($this->{CHAR_WIDTH}, $this->{LINE_HEIGHT});
    $this->setPageHeight();
    $this->{redraw_all} = 1;
    $this->Refresh();
}


sub setPageHeight
{
    my ($this) = @_;
	my $num_lines = scalar keys %{$this->{recs}};
	display($dbg+1,0,"LINE_CHARS=$this->{LINE_CHARS}");
    my $width = $this->{LINE_CHARS} * $this->{CHAR_WIDTH};
	my $line_height = $this->{LINE_HEIGHT};
    my $height = $num_lines * $line_height + $line_height * $HEADER_SIZE;
		# lines + header
	$this->SetVirtualSize($width + 20, $height + $line_height);
		# a little extra width and
		# and one more line for a blank line at the end
	$this->{scroll_y} = $this->GetScrollPos(wxVERTICAL);
	$this->{scroll_x} = $this->GetScrollPos(wxHORIZONTAL);
}



#-------------------------------------------------
# sorting
#-------------------------------------------------

sub onClickHeaderCol
{
	my ($this,$col_num) = @_;
	display($dbg,0,"onClickHeaderCol($col_num)");
	$this->{sort_desc} = $col_num == $this->{sort_col} ? !$this->{sort_desc} : 0;
	$this->{sort_col} = $col_num;
	$this->sortRecs();
    $this->{redraw_all} = 1;
    $this->Refresh();
}

sub sortRecs
{
	my ($this) = @_;
	my $recs = $this->{recs};
	my $parent = $this->{parent};
	my @keys = sort {$parent->cmpRecs($this->{sort_col},$this->{sort_desc},$recs,$a,$b)} keys %$recs;
	$this->{sorted_keys} = \@keys;
}



#-------------------------------------------------
# data handling
#-------------------------------------------------

sub notifyData
{
    my ($this, $new_recs) = @_;
    my $recs = $this->{recs};
    my $now = time();
    my $cols = $this->{columns};
	my $last_col = @$cols-1;

	my $need_sort = 0;
	my $need_refresh = 0;

    for my $key (keys %$recs)
	{
        $recs->{$key}->{found} = 0;
    }

    for my $key (keys %$new_recs)
	{
        my $new_rec = $new_recs->{$key};
        my $rec = $recs->{$key};

        if ($rec)
		{
            $rec->{found} = 1;
            for my $i (0..$last_col)
			{
                my $field = $$cols[$i]->{field_name};
                my $new_value = $new_rec->{$field};
				if ($rec->{$field} ne $new_value)
				{
                    $rec->{changed}->[$i] = 1;
                    $rec->{change_time}->[$i] = $now;
                    $rec->{$field} = $new_value;
					$need_refresh = 1;
                }
				elsif ($rec->{change_time}->[$i] &&
					   $now > $rec->{change_time}->[$i] + $CHANGE_TIMEOUT)
				{
					$need_refresh = 1;
				}
            }
        }
		else
		{
            my $new = { %$new_rec };
            $new->{found} = 1;
            $new->{key} = $key;
            $new->{changed} = [ (1) x @$cols ];
            $new->{change_time} = [ ($now) x @$cols ];
            $recs->{$key} = $new;
			$need_refresh = 1;
			$need_sort = 1;
        }
    }

	my $longest_last = 0;
    for my $key (keys %$recs)
	{
		my $rec = $recs->{$key};
		if (!$rec->{found})
		{
			delete $recs->{$key};
			$need_refresh = 1;
			$need_sort = 1;
		}
		else
		{
			my $last_value = $rec->{$$cols[$last_col]->{field_name}};
			my $display_value = $this->{parent}->getDisplayValue($rec,$last_col,$last_value);
			my $len = length($display_value);
			$longest_last = $len if $len > $longest_last;
		}
    }

	if ($need_refresh)
	{
		$this->{LONGEST_LAST} = $longest_last;
		$this->{LINE_CHARS} = $this->{ALL_BUT_LAST} + $longest_last;
		$this->sortRecs() if $need_sort;
		$this->setPageHeight();
		$this->Refresh();
	}
}


#-------------------------------------------------
# paint
#-------------------------------------------------

sub onPaint
{
    my ($this, $event) = @_;
    my $dc = Wx::PaintDC->new($this);
    $this->DoPrepareDC($dc);
    $dc->SetFont($fonts[$this->{zoom_level}]);
    $dc->SetBackgroundMode(wxSOLID);

	if ($this->{last_scroll_y} != $this->{scroll_y} ||
		$this->{last_scroll_x} != $this->{scroll_x} )
	{
		$this->{last_scroll_y} = $this->{scroll_y};
		$this->{last_scroll_x} = $this->{scroll_x};
		$this->{redraw_all} = 1;
	}

	my $cols = $this->{columns};
	my $last_col = @$cols-1;
	my $char_width = $this->{CHAR_WIDTH};
	my $line_height = $this->{LINE_HEIGHT};
	my $header_y = int(($this->{scroll_y}) * $line_height);

	display($dbg+1,0,"header_y($header_y) scroll_y($this->{scroll_y})");

	if ($this->{redraw_all})
	{
		my $sz = $this->{parent}->GetSize();  # GetClientSize();
		my $width = $sz->GetWidth();
		my $height = $sz->GetHeight();
		$dc->SetBrush(wxWHITE_BRUSH);
		$dc->SetPen(wxWHITE_PEN);
		$dc->DrawRectangle(0, 0, $width + 1000, $height - $this->{parent_top} + 1000);

		my $bg_color = Wx::Colour->new(220, 220, 220);
		$dc->SetBrush(Wx::Brush->new($bg_color, wxSOLID));
		$dc->SetPen(wxTRANSPARENT_PEN);
		$dc->DrawRectangle(0, $header_y, $width + 1000, $line_height * $HEADER_SIZE);

		my $x = 0;
		$dc->SetTextForeground($wx_color_blue);
		for my $i (0..$last_col)
		{
			my $col = $cols->[$i];
			my $field_width = $char_width * ($i == $last_col ?
				$this->{LONGEST_LAST} + 20 :
				$col->{width});

			my $label = $col->{name};
			$label .= $this->{sort_desc} ? "v" : "^"	# "\x{2191}" : "\x{2193}"
				if ($i == $this->{sort_col});

			my $button_color = $wx_color_light_grey;
			my $bg_width = length($label) * $char_width;
			$dc->SetBrush(Wx::Brush->new($button_color, wxSOLID));
			$dc->DrawRectangle($x + 2, $header_y, $bg_width, $line_height + 2);

			$dc->SetBackgroundMode(wxSOLID);
			$dc->SetTextBackground($button_color);
			$dc->DrawText($label, $x + 2, $header_y + 2);
			$x += $field_width;
		}
	}

	$dc->SetBrush(wxWHITE_BRUSH);
	$dc->SetPen(wxWHITE_PEN);
	$dc->SetBackgroundMode(wxTRANSPARENT);
	$dc->SetTextBackground(wxWHITE);

    my $row = 0;
    my $now = time();
	my $recs = $this->{recs};
	my $parent = $this->{parent};
	my $start_y = $this->{LINE_HEIGHT} * $HEADER_SIZE;

    for my $key (@{$this->{sorted_keys}})
	{
        my $x = 0;
        my $rec = $recs->{$key};
        my $y = $start_y + $row * $line_height;
        $row++;

		next if $y <= $header_y + $line_height;
			# don't draw over the already drawn header

        for my $i (0..$last_col)
		{
			my $col = $cols->[$i];

			my $drawit = 0;
            my $color = wxBLACK;
            if ($rec->{changed}->[$i])
			{
                $color = $wx_color_red;
                $rec->{changed}->[$i] = 0;
				$drawit = 1;
            }
			elsif ($rec->{change_time}->[$i])
			{
				if ($now > $rec->{change_time}->[$i] + $CHANGE_TIMEOUT)
				{
					$rec->{change_time}->[$i] = 0;
					$drawit = 1;
				}
				else
				{
					$color = $wx_color_red;
				}
			}

			if ($drawit || $this->{redraw_all})
			{
				my $field = $col->{field_name};
				my $value = $parent->getDisplayValue($rec, $i, $rec->{$field});
				my $field_width = $char_width * ($i == $last_col ?
					$this->{LONGEST_LAST} + 20 :
					$col->{width});

				$dc->DrawRectangle($x, $y, $field_width, $line_height)
					if !$this->{redraw_all};
				$dc->SetTextForeground($color);
				$dc->DrawText($value, $x, $y);
			}

            $x += $col->{width} * $char_width;
        }
    }

    $this->{redraw_all} = 0;
}




1;