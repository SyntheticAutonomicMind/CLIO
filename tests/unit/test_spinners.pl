#!/usr/bin/perl
# Test: Named spinner animations + capability-aware fallback
# Covers:
#   - dots, rotator, braille spinner definitions
#   - UTF-8 locale fallback (braille -> dots)
#   - Unknown spinner name -> dots fallback
#   - Legacy spinner_frames parser (backward compat)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use lib '../../lib';
use CLIO::UI::Spinners qw(
    spinner_frames spinner_metadata list_spinners detect_locale_utf8 parse_legacy_frames
);

my ($pass, $fail) = (0, 0);

sub ok {
    my ($got, $expected, $label) = @_;
    if (defined $got && $got eq $expected) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (got=" . (defined $got ? "'$got'" : 'undef') . ", expected='$expected')\n";
        $fail++;
    }
}

sub ok_arr {
    my ($got, $expected, $label) = @_;
    my $g = join(',', @$got);
    my $e = join(',', @$expected);
    if ($g eq $e) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (got=[$g], expected=[$e])\n";
        $fail++;
    }
}

# --- list_spinners ---
{
    my @names = list_spinners();
    ok_arr(\@names, ['braille', 'dots', 'rotator'], 'list_spinners returns sorted names');
}

# --- dots spinner (always works) ---
{
    my $frames = spinner_frames('dots');
    ok_arr($frames, ['.', '..', '...', '..', '.', ' '], 'dots: 6-frame cascade');
}

# --- rotator spinner ---
{
    my $frames = spinner_frames('rotator');
    ok_arr($frames, ['|', '/', '-', '\\'], 'rotator: 4-frame vi-style');
}

# --- braille spinner ---
{
    my $frames = spinner_frames('braille', force_utf8 => 1);
    my @expected = ("\x{2801}", "\x{2802}", "\x{2804}", "\x{2808}",
                    "\x{2810}", "\x{2820}", "\x{2840}", "\x{2880}");
    ok_arr($frames, \@expected, 'braille: 8-frame unicode pattern');
}

# --- UTF-8 fallback: braille -> dots when no UTF-8 locale ---
{
    local $ENV{LC_ALL} = 'C';
    local $ENV{LC_CTYPE} = 'C';
    local $ENV{LANG} = 'C';
    my $frames = spinner_frames('braille');
    ok_arr($frames, ['.', '..', '...', '..', '.', ' '], 'braille: falls back to dots on C locale');
}

# --- UTF-8 locale preserves braille ---
{
    local $ENV{LC_ALL} = 'en_US.UTF-8';
    local $ENV{LC_CTYPE} = undef;
    local $ENV{LANG} = undef;
    my $frames = spinner_frames('braille');
    my @expected = ("\x{2801}", "\x{2802}", "\x{2804}", "\x{2808}",
                    "\x{2810}", "\x{2820}", "\x{2840}", "\x{2880}");
    ok_arr($frames, \@expected, 'braille: preserved on UTF-8 locale');
}

# --- Unknown spinner name -> dots fallback ---
{
    my $frames = spinner_frames('does_not_exist');
    ok_arr($frames, ['.', '..', '...', '..', '.', ' '], 'unknown spinner -> dots fallback');
}

# --- Undef name -> dots fallback ---
{
    my $frames = spinner_frames(undef);
    ok_arr($frames, ['.', '..', '...', '..', '.', ' '], 'undef name -> dots fallback');
}

# --- spinner_metadata ---
{
    my $meta = spinner_metadata('dots');
    ok(defined $meta ? 1 : 0, 1, 'spinner_metadata returns hash for known spinner');
    ok($meta->{requires_utf8} ? 1 : 0, 0, 'dots does not require UTF-8');

    $meta = spinner_metadata('braille');
    ok($meta->{requires_utf8} ? 1 : 0, 1, 'braille requires UTF-8');

    $meta = spinner_metadata('does_not_exist');
    ok(defined $meta ? 1 : 0, 0, 'spinner_metadata returns undef for unknown');
}

# --- Legacy frames parser (backward compat for spinner_frames=...) ---
{
    my $frames = parse_legacy_frames('.,..,...,..,., ');
    ok_arr($frames, ['.', '..', '...', '..', '.', ' '], 'legacy: parse dots string');

    $frames = parse_legacy_frames('-,|,/,-\\,');
    ok_arr($frames, ['-', '|', '/', '-\\'], 'legacy: parse rotator string');

    $frames = parse_legacy_frames(undef);
    ok_arr($frames, ['.', '..', '...', '..', '.', ' '], 'legacy: undef -> default dots');
}

# --- detect_locale_utf8 ---
{
    local $ENV{LC_ALL} = 'en_US.UTF-8';
    local $ENV{LC_CTYPE} = undef;
    local $ENV{LANG} = undef;
    ok(detect_locale_utf8(), 1, 'UTF-8 detected via LC_ALL');

    local $ENV{LC_ALL} = undef;
    local $ENV{LC_CTYPE} = 'en_US.UTF-8';
    ok(detect_locale_utf8(), 1, 'UTF-8 detected via LC_CTYPE');

    local $ENV{LC_CTYPE} = undef;
    local $ENV{LANG} = 'en_US.UTF-8';
    ok(detect_locale_utf8(), 1, 'UTF-8 detected via LANG');

    local $ENV{LANG} = 'C';
    ok(detect_locale_utf8(), 0, 'C locale is not UTF-8');

    local %ENV = ();
    ok(detect_locale_utf8(), 0, 'unset env is not UTF-8');
}

# --- Theme integration ---
{
    use CLIO::UI::Theme;
    my $theme = CLIO::UI::Theme->new();

    # Set spinner_style=braille in the current style.
    my $style_name = $theme->get_current_style();
    my $style = { %{ $theme->{styles}->{$style_name} } };  # shallow copy
    $style->{spinner_style} = 'braille';
    $theme->{styles}->{$style_name} = $style;

    # If locale is UTF-8, braille frames; otherwise dots.
    local $ENV{LC_ALL} = $ENV{LC_ALL};
    local $ENV{LC_CTYPE} = $ENV{LC_CTYPE};
    local $ENV{LANG} = 'en_US.UTF-8';
    my $frames = $theme->get_spinner_frames();
    my @expected_braille = ("\x{2801}", "\x{2802}", "\x{2804}", "\x{2808}",
                            "\x{2810}", "\x{2820}", "\x{2840}", "\x{2880}");
    ok_arr($frames, \@expected_braille, 'theme.get_spinner_frames: spinner_style=braille + UTF-8');

    $ENV{LANG} = 'C';
    $frames = $theme->get_spinner_frames();
    ok_arr($frames, ['.', '..', '...', '..', '.', ' '], 'theme.get_spinner_frames: braille falls back to dots on C locale');

    # Legacy spinner_frames override wins over spinner_style.
    $style->{spinner_frames} = '*,**,***,**,*, ';
    $theme->{styles}->{$style_name} = $style;
    $frames = $theme->get_spinner_frames();
    ok_arr($frames, ['*', '**', '***', '**', '*', ' '], 'theme: spinner_frames override beats spinner_style');
}

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);