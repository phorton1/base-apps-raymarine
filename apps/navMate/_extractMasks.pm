#!/usr/bin/perl
#-------------------------------------------------------------------------
# _extractMasks.pm
#-------------------------------------------------------------------------
# First-pass automatic alpha-mask extraction from the sym_catalog
# clean*.png set.  Produces mask{NN}.png -- 8-bit greyscale + alpha
# PNG starter assets for the eventual recolorable-icon pipeline.
#
# Algorithm:
#   Per-pixel classification.  A pixel is "in the symbol" unless it's
#   BOTH bright AND nearly grey, in which case it's transparent.
#   Bright = lum > $SYMBOL_MAX_LUM, nearly grey = sat < $SYMBOL_MIN_HUE.
#   Kept pixels are written as luminance greyscale, alpha = 255.
#   The green sentinel (0,255,0) is NOT emitted by this script -- it's
#   reserved for hand-painting designed-white regions in Aseprite.
#
# Output is 24x24-ish (matches each source's native dimensions; sources
# range 14x17 to 23x22).  Resampling to a uniform target size is a
# separate downstream step.
#
# Behavior note:
#   Any pixel that's bright AND nearly grey becomes transparent --
#   whether it's the outside background or a bounded white interior.
#   Icons whose design includes opaque-white regions (dive flags,
#   framed icons, etc.) need hand-painting in Aseprite: restore alpha
#   on the designed-white pixels and fill them with the green sentinel
#   (0,255,0) to mark them as "this is designed white."
#
# Run from the repo root in bash; output redirected per the
# feedback_perl_output_capture rule:
#
#   /c/Perl/bin/perl.exe -I/base -I/c/base/apps/raymarine/apps/navMate \
#       apps/navMate/_extractMasks.pm > \
#       /c/base_data/temp/raymarine/extractMasks.log 2>&1

use strict;
use warnings;
use Wx qw(:everything);
use GD;
use n_utils qw($app_dir);

# Fixed 18-entry output palette, in allocation order.  These indices
# end up as the PLTE chunk of every emitted indexed-color mask PNG --
# so Aseprite (and anyone else) sees all 18 slots whether or not the
# particular icon uses each one.
#   idx 0       -- red sentinel, "transparent" in the app's render
#   idx 1..16   -- greyscale, 16 levels at lum = k*17 for k = 0..15
#   idx 17      -- green sentinel, "opaque designed-white" in the app's render
my @PALETTE = ([255, 0, 0]);
push @PALETTE, [$_, $_, $_] for map { $_ * 17 } 0 .. 15;
push @PALETTE, [0, 255, 0];

# Tunable thresholds (both 0..255).  A pixel stays in the symbol unless
# it's BOTH bright AND nearly grey -- only then is it eligible to be
# flood-eaten as background.
#   $SYMBOL_MAX_LUM -- max luminance to remain in the symbol.
#   $SYMBOL_MIN_HUE -- min hue/saturation to remain in the symbol.
my $SYMBOL_MAX_LUM = 180;
my $SYMBOL_MIN_HUE = 63;

my $N_SYMS  = 40;
my $src_dir = "$app_dir/sym_catalog";
my $dst_dir = "$app_dir/sym_catalog";

Wx::Image::AddHandler(Wx::PNGHandler->new);

my $made    = 0;
my $missing = 0;
my $failed  = 0;

for my $i (0 .. $N_SYMS - 1)
{
    my $src = sprintf('%s/clean%02d.png', $src_dir, $i);
    my $dst = sprintf('%s/mask%02d.png',  $dst_dir, $i);

    if (!-f $src)
    {
        print STDERR "MISSING source: $src\n";
        $missing++;
        next;
    }

    my $img = Wx::Image->new($src, wxBITMAP_TYPE_PNG);
    if (!$img->IsOk())
    {
        print STDERR "LOAD failed: $src\n";
        $failed++;
        next;
    }

    my $w = $img->GetWidth();
    my $h = $img->GetHeight();

    # Per-pixel classification and emit as indexed-color PNG via GD.
    # GD::Image->new defaults to palette mode (8-bit indexed).  Allocating
    # the 18 colors in fixed order makes the resulting PLTE chunk
    # deterministic: red=idx 0, greys=idx 1..16, green=idx 17.  Aseprite
    # opens the file and sees all 18 palette slots even if the icon's
    # pixels don't reference every one.
    #   bright AND grey  -> idx 0  (red sentinel = transparent)
    #   else             -> idx 1..16  (greyscale bucket = (lum >> 4))
    # Green sentinel (idx 17) = opaque designed-white is hand-paint only,
    # never emitted by this script.
    my $out = GD::Image->new($w, $h);
    my @palette_idx;
    for my $rgb (@PALETTE)
    {
        push @palette_idx, $out->colorAllocate(@$rgb);
    }
    my $kept = 0;
    for my $y (0 .. $h - 1)
    {
        for my $x (0 .. $w - 1)
        {
            my $r   = $img->GetRed($x, $y);
            my $g   = $img->GetGreen($x, $y);
            my $b   = $img->GetBlue($x, $y);
            my $max = $r; $max = $g if $g > $max; $max = $b if $b > $max;
            my $min = $r; $min = $g if $g < $min; $min = $b if $b < $min;
            my $sat = $max ? int(255 * ($max - $min) / $max) : 0;
            my $lum = int(0.299 * $r + 0.587 * $g + 0.114 * $b);
            if ($lum > $SYMBOL_MAX_LUM && $sat < $SYMBOL_MIN_HUE)
            {
                $out->setPixel($x, $y, $palette_idx[0]);
            }
            else
            {
                my $bucket = $lum >> 4;
                $bucket = 15 if $bucket > 15;
                $out->setPixel($x, $y, $palette_idx[1 + $bucket]);
                $kept++;
            }
        }
    }

    my $fh;
    if (!open($fh, '>:raw', $dst))
    {
        print STDERR "SAVE open failed: $dst: $!\n";
        $failed++;
        next;
    }
    print $fh $out->png;
    close $fh;

    printf("  clean%02d.png (%2dx%-2d) -> mask%02d.png  kept=%d/%d (%.0f%%)\n",
        $i, $w, $h, $i, $kept, $w * $h, 100 * $kept / ($w * $h));
    $made++;
}

printf("done: %d made, %d missing, %d failed   (SYMBOL_MAX_LUM=%d SYMBOL_MIN_HUE=%d)\n",
    $made, $missing, $failed, $SYMBOL_MAX_LUM, $SYMBOL_MIN_HUE);

1;
