# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Terminal;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(
    detect_capabilities
    configure_io_encoding
    supports_unicode
    supports_cp437
    supports_truecolor
    supports_256color
    supports_ansi
    color_depth
    terminal_type
    box_char
    ui_char
);

# binmode set by configure_io_encoding() after detection, not here

=head1 NAME

CLIO::UI::Terminal - Terminal capability detection and character abstraction

=head1 DESCRIPTION

Detects terminal capabilities (Unicode, color depth, terminal type) and
provides capability-aware character sets for box drawing and other UI
elements. Designed for first-class support on graphical terminals,
Linux console (fbcon), serial terminals, and macOS.

Detection is performed once and cached for the session.

=head1 SYNOPSIS

    use CLIO::UI::Terminal qw(detect_capabilities supports_unicode box_char);
    
    detect_capabilities();
    
    if (supports_unicode()) {
        print box_char('topleft') . box_char('horizontal') x 20 . "\n";
    }

=cut

# Cached detection results
my %caps = (
    detected   => 0,
    unicode    => undef,
    cp437      => undef,
    truecolor  => undef,
    color_256  => undef,
    ansi       => undef,
    term_type  => undef,  # 'graphical', 'console', 'serial', 'dumb'
);

=head2 detect_capabilities()

Probe the terminal and cache results. Safe to call multiple times.

=cut

sub detect_capabilities {
    if (!$caps{detected}) {
        $caps{term_type}  = _detect_term_type();
        $caps{unicode}    = _detect_unicode();
        $caps{cp437}      = _detect_cp437();
        $caps{ansi}       = _detect_ansi();
        $caps{truecolor}  = _detect_truecolor();
        $caps{color_256}  = _detect_256color();
        $caps{detected}   = 1;

        # Log capabilities for debugging (uses require to avoid circular deps)
        eval {
            require CLIO::Core::Logger;
            my $lang = $ENV{LANG} // $ENV{LC_ALL} // $ENV{LC_CTYPE} // '(unset)';
            my $term = $ENV{TERM} // '(unset)';
            CLIO::Core::Logger::log_debug('Terminal',
                sprintf('Capabilities: type=%s unicode=%d cp437=%d ansi=%d truecolor=%d 256=%d LANG=%s TERM=%s',
                    $caps{term_type}, $caps{unicode}, $caps{cp437},
                    $caps{ansi}, $caps{truecolor}, $caps{color_256},
                    $lang, $term));
        };
    }
    return \%caps;
}

=head2 configure_io_encoding()

Set STDOUT/STDERR encoding based on detected terminal capabilities.
Unicode terminals get C<:encoding(UTF-8)>, CP437/raw terminals get
C<:raw> so that byte values 128-255 pass through unchanged.

Call this once after detect_capabilities(), typically at startup.

=cut

sub configure_io_encoding {
    _ensure();
    if ($caps{unicode}) {
        binmode(STDOUT, ':encoding(UTF-8)');
        binmode(STDERR, ':encoding(UTF-8)');
    } else {
        binmode(STDOUT, ':raw');
        binmode(STDERR, ':raw');
    }
}

=head2 Accessors

    supports_unicode()   - 1 if Unicode box-drawing / symbols are safe
    supports_truecolor() - 1 if 24-bit RGB color is available
    supports_256color()  - 1 if xterm 256-color palette is available
    supports_ansi()      - 1 if basic ANSI SGR codes work
    color_depth()        - 'truecolor', '256', '16', 'mono'
    terminal_type()      - 'graphical', 'console', 'serial', 'dumb'

=cut

sub supports_unicode   { _ensure(); return $caps{unicode}   }
sub supports_cp437     { _ensure(); return $caps{cp437}     }
sub supports_truecolor { _ensure(); return $caps{truecolor}  }
sub supports_256color  { _ensure(); return $caps{color_256}  }
sub supports_ansi      { _ensure(); return $caps{ansi}       }

sub color_depth {
    _ensure();
    return 'truecolor' if $caps{truecolor};
    return '256'       if $caps{color_256};
    return '16'        if $caps{ansi};
    return 'mono';
}

sub terminal_type { _ensure(); return $caps{term_type} }

sub _ensure { detect_capabilities() unless $caps{detected} }

# Override for testing
sub set_unicode_support {
    my ($val) = @_;
    _ensure();
    $caps{unicode} = $val ? 1 : 0;
}

# Override for testing
sub set_cp437_support {
    my ($val) = @_;
    _ensure();
    $caps{cp437} = $val ? 1 : 0;
}

# Re-detect (for testing after overrides)
sub _detect_capabilities {
    %caps = ();
    detect_capabilities();
}

# ─────────────────────────────────────────────────────────────
# Detection routines
# ─────────────────────────────────────────────────────────────

sub _detect_term_type {
    my $term = $ENV{TERM} // '';
    
    # Dumb / no TERM
    return 'dumb' if $term eq '' || $term eq 'dumb';
    
    # Linux framebuffer console
    return 'console' if $term eq 'linux' || $term eq 'con' || $term eq 'con132x43';
    
    # Serial / very basic
    return 'serial' if $term =~ /^(vt[12]\d\d|ansi|screen\.linux)$/;
    
    # Multiplexers inherit the outer terminal's graphical ability
    # tmux/screen running inside a graphical terminal are graphical
    if ($term =~ /^(tmux|screen)/) {
        # Check if the outer terminal is graphical
        my $outer = $ENV{TERM_PROGRAM} // '';
        return 'graphical' if $outer ne '';
        # If COLORTERM is set, likely graphical
        return 'graphical' if ($ENV{COLORTERM} // '') ne '';
        # Otherwise conservative - still supports Unicode usually
        return 'graphical';
    }
    
    # Known graphical terminals
    return 'graphical' if $term =~ /^(xterm|rxvt|alacritty|kitty|foot|wezterm|contour)/;
    return 'graphical' if ($ENV{TERM_PROGRAM} // '') ne '';
    return 'graphical' if $term =~ /256color/;
    
    # Fallback - if it's not console/serial/dumb, assume graphical
    return 'graphical';
}

sub _detect_unicode {
    # NO_COLOR doesn't affect Unicode, only colors
    # Check environment signals first (fast path)
    
    # Console terminal (TERM=linux) - the Linux console has limited Unicode
    # support. The default console font (like lat1-16, default8x16) only
    # covers Latin-1. Box-drawing works, but braille/exotic symbols don't.
    # We allow Unicode box-drawing but the spinner should use ASCII.
    my $term_type = $caps{term_type} // _detect_term_type();
    
    # Dumb terminal - no Unicode
    return 0 if $term_type eq 'dumb';
    
    # Serial/VT100 - no Unicode
    return 0 if $term_type eq 'serial';
    
    # Check locale for UTF-8
    my $lang = $ENV{LANG} // $ENV{LC_ALL} // $ENV{LC_CTYPE} // '';
    return 1 if $lang =~ /utf-?8/i;
    
    # If LANG is explicitly set but not UTF-8, respect it - the terminal
    # or user is telling us the encoding isn't Unicode (e.g. CP437, Latin-1).
    # Don't let platform heuristics override an explicit locale.
    return 0 if $lang ne '';
    
    # macOS defaults to UTF-8 even without explicit locale
    return 1 if $^O eq 'darwin';
    
    # TERM_PROGRAM set means a modern graphical terminal (almost always UTF-8)
    return 1 if ($ENV{TERM_PROGRAM} // '') ne '';
    
    # Console with UTF-8 locale = limited Unicode (box-drawing OK)
    # Console without UTF-8 = no Unicode
    if ($term_type eq 'console') {
        return 0;  # Already checked locale above
    }
    
    # Conservative default
    return 0;
}

sub _detect_cp437 {
    # CP437 is the IBM PC character set - supported by most ANSI-capable
    # terminals. Unicode terminals render CP437 chars natively (they map
    # to the same glyphs). Serial/dumb terminals do not support CP437.
    my $term_type = $caps{term_type} // _detect_term_type();
    
    return 0 if $term_type eq 'dumb';
    
    # Unicode implies CP437 glyph support (Unicode is a superset)
    return 1 if $caps{unicode} // _detect_unicode();
    
    # Console terminals (TERM=linux) support CP437 via the VGA font
    return 1 if $term_type eq 'console';
    
    # Serial/VT100 terminals generally don't support CP437
    return 0 if $term_type eq 'serial';
    
    # If ANSI is supported, CP437 extended chars usually work
    return 1 if $caps{ansi} // _detect_ansi();
    
    return 0;
}

sub _detect_ansi {
    # NO_COLOR disables ANSI
    return 0 if defined $ENV{NO_COLOR};
    
    my $term = $ENV{TERM} // '';
    return 0 if $term eq 'dumb' || $term eq '';
    
    # Everything else supports basic ANSI SGR
    return 1;
}

sub _detect_truecolor {
    return 0 unless $caps{ansi} // _detect_ansi();
    
    # COLORTERM is the standard signal for truecolor
    my $ct = $ENV{COLORTERM} // '';
    return 1 if $ct =~ /^(truecolor|24bit)$/i;
    
    # Known truecolor terminals by TERM_PROGRAM
    my $tp = $ENV{TERM_PROGRAM} // '';
    return 1 if $tp =~ /^(iTerm|WezTerm|Alacritty|kitty|Hyper|vscode)$/i;
    
    # TERM hints
    my $term = $ENV{TERM} // '';
    return 1 if $term =~ /-(truecolor|direct)$/;
    
    # tmux passes through truecolor if outer supports it
    return 1 if $term =~ /^tmux/ && $ct ne '';
    
    return 0;
}

sub _detect_256color {
    return 0 unless $caps{ansi} // _detect_ansi();
    return 1 if $caps{truecolor} // _detect_truecolor();  # truecolor implies 256
    
    my $term = $ENV{TERM} // '';
    return 1 if $term =~ /256color/;
    
    # Most modern graphical terminals support 256 colors
    my $tp = $ENV{TERM_PROGRAM} // '';
    return 1 if $tp ne '';
    
    # macOS Terminal.app supports 256
    return 1 if $^O eq 'darwin' && ($caps{term_type} // '') eq 'graphical';
    
    # Console supports 16 colors, not 256
    return 0 if ($caps{term_type} // '') eq 'console';
    
    return 0;
}

# ─────────────────────────────────────────────────────────────
# Box-drawing character abstraction
# ─────────────────────────────────────────────────────────────

=head2 box_char($type)

Returns the appropriate box-drawing character for the current terminal.

Unicode terminals get proper box-drawing characters.
Non-Unicode terminals get ASCII fallbacks.

Types: horizontal, vertical, topleft, topright, bottomleft, bottomright,
       tdown, tup, tright, tleft, cross,
       dhorizontal, dvertical, dtopleft, dtopright, dbottomleft, dbottomright,
       hhorizontal

=cut

my %BOX_UNICODE = (
    horizontal   => "\x{2500}",  # ─
    vertical     => "\x{2502}",  # │
    topleft      => "\x{250C}",  # ┌
    topright     => "\x{2510}",  # ┐
    bottomleft   => "\x{2514}",  # └
    bottomright  => "\x{2518}",  # ┘
    tdown        => "\x{252C}",  # ┬
    tup          => "\x{2534}",  # ┴
    tright       => "\x{251C}",  # ├
    tleft        => "\x{2524}",  # ┤
    cross        => "\x{253C}",  # ┼

    dhorizontal  => "\x{2550}",  # ═
    dvertical    => "\x{2551}",  # ║
    dtopleft     => "\x{2554}",  # ╔
    dtopright    => "\x{2557}",  # ╗
    dbottomleft  => "\x{255A}",  # ╚
    dbottomright => "\x{255D}",  # ╝

    hhorizontal  => "\x{2501}",  # ━ (heavy horizontal)
);

my %BOX_CP437 = (
    horizontal   => chr(196),  # ─
    vertical     => chr(179),  # │
    topleft      => chr(218),  # ┌
    topright     => chr(191),  # ┐
    bottomleft   => chr(192),  # └
    bottomright  => chr(217),  # ┘
    tdown        => chr(194),  # ┬
    tup          => chr(193),  # ┴
    tright       => chr(195),  # ├
    tleft        => chr(180),  # ┤
    cross        => chr(197),  # ┼

    dhorizontal  => chr(205),  # ═
    dvertical    => chr(186),  # ║
    dtopleft     => chr(201),  # ╔
    dtopright    => chr(187),  # ╗
    dbottomleft  => chr(200),  # ╚
    dbottomright => chr(188),  # ╝

    hhorizontal  => chr(196),  # ━ (no heavy variant in CP437, use horizontal)
);

my %BOX_ASCII = (
    horizontal   => '-',
    vertical     => '|',
    topleft      => '+',
    topright     => '+',
    bottomleft   => '+',
    bottomright  => '+',
    tdown        => '+',
    tup          => '+',
    tright       => '+',
    tleft        => '+',
    cross        => '+',

    dhorizontal  => '=',
    dvertical    => '|',
    dtopleft     => '+',
    dtopright    => '+',
    dbottomleft  => '+',
    dbottomright => '+',

    hhorizontal  => '-',
);

sub box_char {
    my ($type) = @_;
    _ensure();
    
    if ($caps{unicode}) {
        return $BOX_UNICODE{$type} // '?';
    } elsif ($caps{cp437}) {
        return $BOX_CP437{$type} // $BOX_ASCII{$type} // '?';
    } else {
        return $BOX_ASCII{$type} // '?';
    }
}

# ─────────────────────────────────────────────────────────────
# UI symbol abstraction (bullets, separators, indicators)
# ─────────────────────────────────────────────────────────────

=head2 ui_char($name)

Returns a capability-appropriate UI symbol for the current terminal.

Three tiers: Unicode -> CP437 -> ASCII.
Themes can override these via the style file.

Names: bullet, separator, footer_sep, ellipsis, arrow_right, arrow_left,
       check, cross_mark, dot, dash, pipe,
       bullet_round, infinity, lock, filled_block, light_shade, diamond, circle,
       info, lightbulb, envelope

=cut

my %UI_UNICODE = (
    bullet       => "\x{2219}",  # ∙ (bullet operator)
    separator    => "\x{2192}",  # → (rightwards arrow)
    footer_sep   => "\x{2500}",  # ─ (horizontal line)
    ellipsis     => "\x{2026}",  # … (horizontal ellipsis)
    arrow_right  => "\x{2192}",  # → (rightward arrow)
    arrow_left   => "\x{2190}",  # ← (leftward arrow)
    check        => "\x{2713}",  # ✓ (check mark)
    cross_mark   => "\x{2717}",  # ✗ (ballot x)
    dot          => "\x{00B7}",  # · (middle dot)
    dash         => "\x{2014}",  # — (em dash)
    pipe         => "\x{2502}",  # │ (vertical line)

    bullet_round => "\x{2022}",  # • (bullet)
    infinity     => "\x{221E}",  # ∞ (infinity)
    lock         => "\x{1F512}", #  (lock)
    filled_block => "\x{2588}",  # █ (full block)
    light_shade  => "\x{2591}",  # ░ (light shade)
    diamond      => "\x{25C6}",  # ◆ (black diamond)
    circle       => "\x{25CB}",  # ○ (white circle)

    info         => "\x{2139}",  # [INFO] (information source)
    lightbulb    => "\x{1F4A1}", # [IDEA] (electric light bulb)
    envelope     => "\x{1F4E8}", #  (incoming envelope)

    times        => "\x{00D7}",  # × (multiplication sign)
    divide       => "\x{00F7}",  # ÷ (division sign)
    plus_minus   => "\x{00B1}",  # ± (plus-minus sign)
    approx       => "\x{2248}",  # ≈ (approximately equal)
    not_equal    => "\x{2260}",  # ≠ (not equal)
    less_equal   => "\x{2264}",  # ≤ (less than or equal)
    greater_equal => "\x{2265}", # ≥ (greater than or equal)
    sqrt_sym     => "\x{221A}",  # √ (square root)
    sum_sym      => "\x{2211}",  # ∑ (summation)
    integral     => "\x{222B}",  # ∫ (integral)
    partial      => "\x{2202}",  # ∂ (partial derivative)
    nabla        => "\x{2207}",  # ∇ (nabla/del)
);

my %UI_CP437 = (
    bullet       => chr(249),    # bullet
    separator    => chr(26),     # rightwards arrow
    footer_sep   => chr(196),    # horizontal line
    ellipsis     => "...",
    arrow_right  => chr(175),    # double angle right
    arrow_left   => chr(174),    # double angle left
    check        => chr(251),    # check mark
    cross_mark   => "x",
    dot          => chr(250),    # middle dot
    dash         => "-",
    pipe         => chr(179),    # vertical line

    bullet_round => chr(7),      # bullet
    infinity     => chr(236),    # infinity
    lock         => "*",
    filled_block => chr(219),    # full block
    light_shade  => chr(176),    # light shade
    diamond      => chr(4),      # diamond
    circle       => chr(9),      # circle

    info         => "i",
    lightbulb    => "*",
    envelope     => "\@",

    times        => chr(158),    # multiply (CP437 approx)
    divide       => chr(246),    # ÷ (division sign)
    plus_minus   => chr(241),    # ± (plus-minus)
    approx       => "~=",
    not_equal    => "!=",
    less_equal   => "<=",
    greater_equal => ">=",
    sqrt_sym     => "sqrt",
    sum_sym      => "SUM",
    integral     => "INT",
    partial      => "d",
    nabla        => "V",
);


my %UI_ASCII = (
    bullet       => '*',
    separator    => '>',
    footer_sep   => '_',
    ellipsis     => '...',
    arrow_right  => '->',
    arrow_left   => '<-',
    check        => '+',
    cross_mark   => 'x',
    dot          => '.',
    dash         => '-',
    pipe         => '|',

    bullet_round => '*',
    infinity     => 'inf',
    lock         => '*',
    filled_block => '#',
    light_shade  => '.',
    diamond      => '*',
    circle       => 'o',

    info         => 'i',
    lightbulb    => '*',
    envelope     => '@',

    times        => 'x',
    divide       => '/',
    plus_minus   => '+/-',
    approx       => '~=',
    not_equal    => '!=',
    less_equal   => '<=',
    greater_equal => '>=',
    sqrt_sym     => 'sqrt',
    sum_sym      => 'SUM',
    integral     => 'INT',
    partial      => 'd',
    nabla        => 'V',
);

sub ui_char {
    my ($name) = @_;
    _ensure();
    
    if ($caps{unicode}) {
        return $UI_UNICODE{$name} // '?';
    } elsif ($caps{cp437}) {
        return $UI_CP437{$name} // '?';
    } else {
        return $UI_ASCII{$name} // '?';
    }
}

1;

__END__

=head1 ENVIRONMENT VARIABLES

Terminal detection uses:

    TERM          - Terminal type (xterm-256color, linux, dumb, etc.)
    TERM_PROGRAM  - Terminal application (iTerm2.app, vscode, etc.)
    COLORTERM     - Color capability (truecolor, 24bit)
    LANG/LC_ALL   - Locale (checked for UTF-8)
    NO_COLOR      - Standard: disable all color output

=head1 SEE ALSO

L<CLIO::UI::ANSI>, L<CLIO::UI::Theme>

=cut
