#!/usr/bin/perl
#-------------------------------------------------------------------------
# winTreeColors.pm
#-------------------------------------------------------------------------
# Continuation of the winTreeBase package (declared in winTreeBase.pm),
# split out to keep individual Perl files under ~1100 lines.
#
# Contents:
#   - One shared wxImageList that hosts row-icon swatches (color + sym)
#     for the three tree windows (winDatabase, winE80, winFSH).
#   - A static cache that maps swatch values (AABBGGRR hex strings or
#     sym 0..39 integers) to image-list indices, lazily minting a
#     bitmap on first sight of a previously unseen value.
#   - The package-function API the windows call to attach the shared
#     list to their wxTreeCtrl and to resolve a swatch spec to an index.
#
# Design rationale and per-window contract live in the color-swatch-plan
# memory.  Briefly: each window implements _swatchSpec($node) returning
# { kind=>'color',value=>$abgr_hex } | { kind=>'sym',value=>$sym_idx }
# | undef.  Row-create paths call _swatchImageIndex on the spec and
# pass the result to SetItemImage.

package winTreeBase;	# continued ...
use strict;
use warnings;
use Wx qw(:everything);
use Pub::Utils qw(display $resource_dir $temp_dir);
use n_utils qw(@E80_ROUTE_COLOR_ABGR);

my $SWATCH_W = 15;
my $SWATCH_H = 15;
my $COLOR_INNER = 9;	# centered solid-color rect inside the white cell

# Per-process shared state.  All three tree windows attach the same
# image list (non-owning) and look up indices in the same caches.
my $shared_img_list;
my %color_cache;		# 'AABBGGRR' upper-hex                  -> image-list index
my %sym_cache;			# 0..39 sym index                       -> image-list index
my %colored_sym_cache;	# 'sym{NN}/{AABBGGRR}'                  -> image-list index
my $blank_idx;			# index of a transparent placeholder at slot 0


#---------------------------------
# shared image list lifecycle
#---------------------------------

sub _initSwatchImageList
{
	# Create the shared list and seed it with a transparent placeholder
	# at index 0.  The placeholder is the fallback for nodes that have
	# no swatch -- on platforms where wxTreeCtrl reserves item-image
	# horizontal space once an image list is attached, assigning the
	# blank explicitly keeps the no-swatch rows visually clean.
	return if $shared_img_list;

	$shared_img_list = Wx::ImageList->new($SWATCH_W, $SWATCH_H);

	my $blank = Wx::Bitmap->new($SWATCH_W, $SWATCH_H);
	my $dc    = Wx::MemoryDC->new();
	$dc->SelectObject($blank);
	$dc->SetBackground(Wx::Brush->new(Wx::Colour->new(255, 255, 255), wxTRANSPARENT));
	$dc->Clear();
	$dc->SelectObject(wxNullBitmap);
	# Mask the white so the placeholder reads as transparent against
	# any row background.
	my $mask = Wx::Mask->new($blank, Wx::Colour->new(255, 255, 255));
	$blank->SetMask($mask);

	$blank_idx = $shared_img_list->Add($blank);
}


sub _attachSwatchImageList
{
	# Called once per tree window during new(), after $this->{tree} exists.
	# wxPerl's SetImageList takes only the list arg (the non-owning bool
	# from C++ isn't exposed); the file-scoped $shared_img_list strong
	# reference is what actually keeps it alive across tree destructors.
	my ($tree) = @_;
	_initSwatchImageList();
	$tree->SetImageList($shared_img_list);
}


#---------------------------------
# spec -> index resolution
#---------------------------------

sub _swatchImageIndex
{
	# Returns the image-list index for a swatch spec, minting and
	# caching a new bitmap if this exact value hasn't been seen yet.
	# Returns -1 for an undef or unknown spec -- callers (via _setSwatch)
	# skip SetItemImage in that case, which lets rows without a swatch
	# render with text flush against the checkbox where the platform's
	# wxTreeCtrl allows it.  If empirically wx ends up reserving the
	# item-image slot regardless, swap this to return $blank_idx
	# instead so no-swatch rows show a transparent placeholder.
	my ($spec) = @_;
	_initSwatchImageList();
	return -1 if !$spec || ref($spec) ne 'HASH';

	my $kind = $spec->{kind} // '';
	if ($kind eq 'color')
	{
		my $hex = $spec->{value};
		return -1 if !defined $hex || $hex eq '';
		my $key = uc($hex);
		return $color_cache{$key} if exists $color_cache{$key};
		my $bmp = _swatchBitmapForColor($key);
		my $idx = $shared_img_list->Add($bmp);
		$color_cache{$key} = $idx;
		return $idx;
	}
	elsif ($kind eq 'sym')
	{
		my $sym = $spec->{value};
		return -1 if !defined $sym;
		$sym += 0;
		return -1 if $sym < 0 || $sym > 39;
		return $sym_cache{$sym} if exists $sym_cache{$sym};
		my $bmp = _swatchBitmapForSym($sym);
		return -1 if !$bmp || !$bmp->IsOk();
		my $idx = $shared_img_list->Add($bmp);
		$sym_cache{$sym} = $idx;
		return $idx;
	}
	elsif ($kind eq 'colored_sym')
	{
		my $sym = $spec->{sym};
		return -1 if !defined $sym;
		$sym += 0;
		return -1 if $sym < 0 || $sym > 39;
		my $color = $spec->{color};
		return -1 if !defined $color || $color eq '';
		my $key = sprintf('sym%02d/%s', $sym, uc($color));
		return $colored_sym_cache{$key} if exists $colored_sym_cache{$key};
		my $bmp = _swatchBitmapForColoredSym($sym, uc($color));
		return -1 if !$bmp || !$bmp->IsOk();
		my $idx = $shared_img_list->Add($bmp);
		$colored_sym_cache{$key} = $idx;
		return $idx;
	}
	return -1;
}


#---------------------------------
# bitmap construction
#---------------------------------

sub _parseUserColor
{
	# AABBGGRR hex string -> (rr, gg, bb) for rendering.  Returns
	# (0x88, 0x88, 0x88) for malformed/missing input.
	#
	# Dual coercion: both FFFFFFFF (palette "Black/White on Map", the
	# protocol-BLACK whose AABBGGRR is literally white) and FF000000
	# (literal black, only reachable via the DB's custom-color picker)
	# render as RGB (0, 0, 0) in the app.  They differ ONLY on the
	# leaflet map (one is white-on-map, one is black-on-map) and at
	# spoke-push time (only FFFFFFFF round-trips cleanly to E80/FSH;
	# FF000000 triggers the existing non-round-trippable-color
	# warning).  All other AABBGGRR values render as their literal RGB.
	my ($hex) = @_;
	return (0x88, 0x88, 0x88) if !defined $hex || length($hex) < 8;
	my $up = uc($hex);
	return (0, 0, 0) if $up eq 'FFFFFFFF' || $up eq 'FF000000';
	return (
		hex(substr($hex, 6, 2)),
		hex(substr($hex, 4, 2)),
		hex(substr($hex, 2, 2)));
}


sub _swatchBitmapForColor
{
	# Build a $SWATCH_W x $SWATCH_H cell: white background with a
	# centered $COLOR_INNER x $COLOR_INNER solid-color square.  The
	# white margin keeps the color swatch visually quieter than the
	# checkbox glyph next to it; the inner color square is the actual
	# row indicator.
	my ($hex) = @_;
	my ($rr, $gg, $bb) = _parseUserColor($hex);

	my $bmp = Wx::Bitmap->new($SWATCH_W, $SWATCH_H);
	my $dc  = Wx::MemoryDC->new();
	$dc->SelectObject($bmp);
	$dc->SetBackground(Wx::Brush->new(Wx::Colour->new(255, 255, 255), wxSOLID));
	$dc->Clear();
	my $off = int(($SWATCH_W - $COLOR_INNER) / 2);
	$dc->SetPen(Wx::Pen->new(Wx::Colour->new($rr, $gg, $bb), 1, wxSOLID));
	$dc->SetBrush(Wx::Brush->new(Wx::Colour->new($rr, $gg, $bb), wxSOLID));
	$dc->DrawRectangle($off, $off, $COLOR_INNER, $COLOR_INNER);
	$dc->SelectObject(wxNullBitmap);
	return $bmp;
}


#---------------------------------
# row-create convenience
#---------------------------------
# Called after every AppendItem from the tree-build paths in winE80,
# winFSH, and winDatabase.  Reads the node's swatch spec via the
# polymorphic _swatchSpec method (which each window overrides) and
# assigns the corresponding image-list entry.  Unconditionally safe
# to call for any node type -- _swatchImageIndex returns the blank
# placeholder for undef specs.

my $_row_height_reported = 0;

sub _setSwatch
{
	my ($this, $item) = @_;
	return if !$item || !$item->IsOk();
	my $tree = $this->{tree};
	return if !$tree;

	# One-shot probe of the actual row height so we can size the
	# image-list cell to match.  Fires from whichever tree window
	# adds the first leaf item.
	if (!$_row_height_reported)
	{
		$_row_height_reported = 1;
		my $ih  = eval { $tree->GetItemHeight() };
		my $ihs = (defined $ih && !$@) ? $ih : 'n/a';
		display(0, 0, sprintf(
			"winTreeColors: tree GetItemHeight=%s GetCharHeight=%d swatch=%dx%d",
			$ihs, $tree->GetCharHeight(), $SWATCH_W, $SWATCH_H));
	}

	my $d = $tree->GetItemData($item);
	return if !$d;
	my $node = $d->GetData();
	return if ref $node ne 'HASH';
	my $idx = _swatchImageIndex($this->_swatchSpec($node));
	$tree->SetItemImage($item, $idx) if $idx >= 0;
}


#---------------------------------
# default _swatchSpec (E80- and FSH-shaped trees)
#---------------------------------
# winE80 and winFSH share the same node-type schema and the same data
# shape (waypoints carry sym; routes and tracks carry a palette index
# in $node->{data}{color}).  This default serves both -- neither
# overrides it.  winDatabase has a different node schema and data
# shape; it provides its own override.

sub _swatchSpec
{
	my ($this, $node) = @_;
	my $type = $node->{type} // '';
	if ($type eq 'waypoint')
	{
		my $sym = ($node->{data}{sym} // 0) + 0;
		return { kind => 'sym', value => $sym };
	}
	elsif ($type eq 'route' || $type eq 'track')
	{
		my $cidx = ($node->{data}{color} // 0) + 0;
		my $abgr = $E80_ROUTE_COLOR_ABGR[$cidx] // 'FF888888';
		return { kind => 'color', value => $abgr };
	}
	return undef;
}


sub _ensureCache15x15
{
	# Build $temp_dir/sym_cache/15x15_NN.png from symNN.png if missing or
	# older.  Resolve the green sentinel to white first (so edge area-
	# averaging doesn't produce green-tinged pixels), Rescale 16x16 ->
	# 13x13 with wxIMAGE_QUALITY_HIGH, then place in a 15x15 white
	# canvas with 1-px border.
	my ($src_path, $cache_path) = @_;
	my $src_mtime   = (stat($src_path))[9];
	my $cache_mtime = -f $cache_path ? (stat($cache_path))[9] : 0;
	return if defined $src_mtime && $cache_mtime >= $src_mtime;

	my $dir = $cache_path;
	$dir =~ s|/[^/]+$||;
	mkdir $dir if !-d $dir;

	my $src = Wx::Image->new($src_path, wxBITMAP_TYPE_PNG);
	return if !$src || !$src->IsOk();

	for my $y (0 .. 15)
	{
		for my $x (0 .. 15)
		{
			if ($src->GetRed($x, $y) == 0 &&
				$src->GetGreen($x, $y) == 255 &&
				$src->GetBlue($x, $y) == 0)
			{
				$src->SetRGB($x, $y, 255, 255, 255);
			}
		}
	}

	$src->Rescale(13, 13, wxIMAGE_QUALITY_HIGH);

	my $out = Wx::Image->new(15, 15);
	for my $y (0 .. 14)
	{
		for my $x (0 .. 14)
		{
			$out->SetRGB($x, $y, 255, 255, 255);
		}
	}
	for my $y (0 .. 12)
	{
		for my $x (0 .. 12)
		{
			$out->SetRGB($x + 1, $y + 1,
				$src->GetRed($x, $y), $src->GetGreen($x, $y), $src->GetBlue($x, $y));
		}
	}
	$out->SaveFile($cache_path, wxBITMAP_TYPE_PNG);
}


sub _swatchBitmapForSym
{
	# Load the pre-built $SWATCH_W x $SWATCH_H sym bitmap from
	# sym_catalog/cache/15x15_NN.png.  Built lazily by _ensureCache15x15
	# from sym_catalog/symNN.png: 16x16 source downsampled to 13x13 and
	# placed in a 15x15 white canvas with 1-px border.
	my ($sym) = @_;
	my $src   = sprintf('%s/sym_catalog/sym%02d.png',          $resource_dir, $sym);
	my $cache = sprintf('%s/sym_cache/15x15_%02d.png', $temp_dir, $sym);
	_ensureCache15x15($src, $cache);
	return undef if !-f $cache;
	my $bmp = Wx::Bitmap->new($cache, wxBITMAP_TYPE_PNG);
	return undef if !$bmp || !$bmp->IsOk();
	return $bmp;
}


sub _ensureCache15x15Grey
{
	# Build sym_catalog/cache/15x15_grey_NN.png from symNN.png if missing
	# or older.  Same pipeline as _ensureCache15x15 but the final 15x15
	# emits greyscale where the grey value is V from HSV (max channel),
	# not Rec 601 luminance.  The hand-drawn sym palette is dominant-
	# channel pure colors (reds and blues), so V reads source intensity
	# directly; luminance would crush pure red and crush blue harder
	# because Rec 601 is green-weighted for natural photos.  The recolor
	# step in _swatchBitmapForColoredSym then tints the greys per the
	# user's chosen color and leaves white alone.
	my ($src_path, $cache_path) = @_;
	my $src_mtime   = (stat($src_path))[9];
	my $cache_mtime = -f $cache_path ? (stat($cache_path))[9] : 0;
	return if defined $src_mtime && $cache_mtime >= $src_mtime;

	my $dir = $cache_path;
	$dir =~ s|/[^/]+$||;
	mkdir $dir if !-d $dir;

	my $src = Wx::Image->new($src_path, wxBITMAP_TYPE_PNG);
	return if !$src || !$src->IsOk();

	for my $y (0 .. 15)
	{
		for my $x (0 .. 15)
		{
			if ($src->GetRed($x, $y) == 0 &&
				$src->GetGreen($x, $y) == 255 &&
				$src->GetBlue($x, $y) == 0)
			{
				$src->SetRGB($x, $y, 255, 255, 255);
			}
		}
	}

	$src->Rescale(13, 13, wxIMAGE_QUALITY_HIGH);

	# Cache encoding: each pixel stores chroma+lift for HSV-style hue
	# replacement (see _swatchBitmapForColoredSym):
	#   R = chroma = max(r,g,b) - min(r,g,b)
	#   G = lift   = min(r,g,b)
	#   B = 0
	# A pure-white pixel (sentinel was resolved to white) thus encodes
	# as (0,255,0) and tints to (255,255,255) regardless of user color.
	# The 1-px border is set to the same white-encoding directly.
	my $out = Wx::Image->new(15, 15);
	for my $y (0 .. 14)
	{
		for my $x (0 .. 14)
		{
			$out->SetRGB($x, $y, 0, 255, 0);
		}
	}
	for my $y (0 .. 12)
	{
		for my $x (0 .. 12)
		{
			my $r = $src->GetRed($x, $y);
			my $g = $src->GetGreen($x, $y);
			my $b = $src->GetBlue($x, $y);
			my $max = $r > $g ? ($r > $b ? $r : $b) : ($g > $b ? $g : $b);
			my $min = $r < $g ? ($r < $b ? $r : $b) : ($g < $b ? $g : $b);
			$out->SetRGB($x + 1, $y + 1, $max - $min, $min, 0);
		}
	}
	$out->SaveFile($cache_path, wxBITMAP_TYPE_PNG);
}


sub _swatchBitmapForColoredSym
{
	# Load sym_catalog/cache/15x15_grey_NN.png and recolor in memory per
	# the user's chosen ABGR.  Cached mask is chroma+lift encoded:
	#   src.R = chroma = max(r,g,b) - min(r,g,b)
	#   src.G = lift   = min(r,g,b)
	# Tint:  out = userColor * chroma/255 + lift
	# This preserves the source palette's "lift toward white" so a pixel
	# like native (230,175,175) -- chroma=55, lift=175 -- still reads as
	# a bright highlight when tinted to any hue.  Cannot overflow:
	# userColor*chroma/255 + lift <= chroma + lift = max(r,g,b) <= 255.
	# Built lazily by _ensureCache15x15Grey from sym_catalog/symNN.png.
	my ($sym, $color_hex) = @_;
	my $src_path   = sprintf('%s/sym_catalog/sym%02d.png',               $resource_dir, $sym);
	my $cache_path = sprintf('%s/sym_cache/15x15_grey_%02d.png', $temp_dir, $sym);
	_ensureCache15x15Grey($src_path, $cache_path);
	return undef if !-f $cache_path;
	my $src = Wx::Image->new($cache_path, wxBITMAP_TYPE_PNG);
	return undef if !$src || !$src->IsOk();

	my ($rr, $gg, $bb) = _parseUserColor($color_hex);

	my $out = Wx::Image->new($SWATCH_W, $SWATCH_H);
	for my $oy (0 .. $SWATCH_H - 1)
	{
		for my $ox (0 .. $SWATCH_W - 1)
		{
			my $chroma = $src->GetRed($ox, $oy);
			my $lift   = $src->GetGreen($ox, $oy);
			$out->SetRGB($ox, $oy,
				int($rr * $chroma / 255) + $lift,
				int($gg * $chroma / 255) + $lift,
				int($bb * $chroma / 255) + $lift);
		}
	}
	return Wx::Bitmap->new($out);
}


1;
