# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::ANSI;

use strict;
use warnings;
use utf8;

use CLIO::UI::Terminal qw(box_char);


=head1 NAME

CLIO::UI::ANSI - ANSI escape code management with extended @-code system

=head1 DESCRIPTION

Provides ANSI escape codes and an extended @-code system for terminal
formatting. Supports basic 16-color, 256-color, TrueColor (24-bit RGB),
cursor control, and capability-aware box-drawing characters.

Compatible with PhotonBBS @-code conventions.

=head1 SYNOPSIS

    use CLIO::UI::ANSI;
    
    my $ansi = CLIO::UI::ANSI->new();
    
    # Standard @-codes
    print $ansi->parse("@BOLD@Hello @RED@World@RESET@\n");
    
    # TrueColor hex (24-bit RGB)
    print $ansi->parse("@[FF5500]@Orange text@RESET@\n");
    print $ansi->parse("@[BG:003366]@Blue background@RESET@\n");
    
    # 256-color palette
    print $ansi->parse("@256:208@Orange text@RESET@\n");
    
    # Cursor control
    print $ansi->parse("@CURSOR_HIDE@");  # Hide cursor during animation
    print $ansi->parse("@CURSOR_SHOW@");  # Restore cursor

=cut

# Standard ANSI escape codes
use constant {
    # Cursor movement
    CURSOR_UP       => "\e[1A",
    CURSOR_DOWN     => "\e[1B",
    CURSOR_RIGHT    => "\e[1C",
    CURSOR_LEFT     => "\e[1D",
    CURSOR_HOME     => "\e[H",
    CURSOR_SAVE     => "\e[s",
    CURSOR_RESTORE  => "\e[u",
    CURSOR_HIDE     => "\e[?25l",
    CURSOR_SHOW     => "\e[?25h",
    
    # Line operations
    CLEAR_LINE      => "\e[2K",
    CLEAR_TO_EOL    => "\e[K",
    CLEAR_TO_BOL    => "\e[1K",
    CLEAR_SCREEN    => "\e[2J",
    CARRIAGE_RETURN => "\r",
    
    # Text attributes
    RESET           => "\e[0m",
    BOLD            => "\e[1m",
    DIM             => "\e[2m",
    ITALIC          => "\e[3m",
    UNDERLINE       => "\e[4m",
    BLINK           => "\e[5m",
    REVERSE         => "\e[7m",
    HIDDEN          => "\e[8m",
    STRIKETHROUGH   => "\e[9m",
    
    # Foreground colors (normal)
    BLACK           => "\e[30m",
    RED             => "\e[31m",
    GREEN           => "\e[32m",
    YELLOW          => "\e[33m",
    BLUE            => "\e[34m",
    MAGENTA         => "\e[35m",
    CYAN            => "\e[36m",
    WHITE           => "\e[37m",
    DEFAULT_FG      => "\e[39m",
    
    # Foreground colors (bright)
    BRIGHT_BLACK    => "\e[90m",
    BRIGHT_RED      => "\e[91m",
    BRIGHT_GREEN    => "\e[92m",
    BRIGHT_YELLOW   => "\e[93m",
    BRIGHT_BLUE     => "\e[94m",
    BRIGHT_MAGENTA  => "\e[95m",
    BRIGHT_CYAN     => "\e[96m",
    BRIGHT_WHITE    => "\e[97m",
    
    # Background colors (normal)
    BG_BLACK        => "\e[40m",
    BG_RED          => "\e[41m",
    BG_GREEN        => "\e[42m",
    BG_YELLOW       => "\e[43m",
    BG_BLUE         => "\e[44m",
    BG_MAGENTA      => "\e[45m",
    BG_CYAN         => "\e[46m",
    BG_WHITE        => "\e[47m",
    DEFAULT_BG      => "\e[49m",
    
    # Background colors (bright)
    BG_BRIGHT_BLACK     => "\e[100m",
    BG_BRIGHT_RED       => "\e[101m",
    BG_BRIGHT_GREEN     => "\e[102m",
    BG_BRIGHT_YELLOW    => "\e[103m",
    BG_BRIGHT_BLUE      => "\e[104m",
    BG_BRIGHT_MAGENTA   => "\e[105m",
    BG_BRIGHT_CYAN      => "\e[106m",
    BG_BRIGHT_WHITE     => "\e[107m",
};

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        enabled => $opts{enabled} // 1,  # ANSI codes enabled by default
        debug => $opts{debug} || 0,
    };
    
    return bless $self, $class;
}

=head2 codes

Get hash reference of all ANSI codes.
Returns a cached hash reference for performance (built once per instance).

=cut

sub codes {
    my ($self) = @_;
    
    return {} unless $self->{enabled};
    
    # Return cached codes hash if already built
    return $self->{_codes_cache} if $self->{_codes_cache};
    
    $self->{_codes_cache} = {
        # Cursor movement
        CURSOR_UP       => CURSOR_UP,
        CURSOR_DOWN     => CURSOR_DOWN,
        CURSOR_RIGHT    => CURSOR_RIGHT,
        CURSOR_LEFT     => CURSOR_LEFT,
        CURSOR_HOME     => CURSOR_HOME,
        CURSOR_SAVE     => CURSOR_SAVE,
        CURSOR_RESTORE  => CURSOR_RESTORE,
        CURSOR_HIDE     => CURSOR_HIDE,
        CURSOR_SHOW     => CURSOR_SHOW,
        CUP             => CURSOR_UP,      # Short alias
        CDN             => CURSOR_DOWN,
        CRT             => CURSOR_RIGHT,
        CLT             => CURSOR_LEFT,
        
        # Line operations
        CLEAR_LINE      => CLEAR_LINE,
        CLEAR_TO_EOL    => CLEAR_TO_EOL,
        CLEAR_TO_BOL    => CLEAR_TO_BOL,
        CLEAR_SCREEN    => CLEAR_SCREEN,
        CR              => CARRIAGE_RETURN,
        CLL             => CLEAR_LINE,     # Short alias
        CLS             => CLEAR_SCREEN,
        
        # Text attributes
        RESET           => RESET,
        BOLD            => BOLD,
        DIM             => DIM,
        ITALIC          => ITALIC,
        UNDERLINE       => UNDERLINE,
        BLINK           => BLINK,
        REVERSE         => REVERSE,
        REV             => REVERSE,        # PhotonBBS alias
        HIDDEN          => HIDDEN,
        STRIKETHROUGH   => STRIKETHROUGH,
        STRIKE          => STRIKETHROUGH,  # PhotonBBS alias
        
        # Foreground colors
        BLACK           => BLACK,
        RED             => RED,
        GREEN           => GREEN,
        YELLOW          => YELLOW,
        BLUE            => BLUE,
        MAGENTA         => MAGENTA,
        CYAN            => CYAN,
        WHITE           => WHITE,
        DEFAULT_FG      => DEFAULT_FG,
        
        # Bright foreground
        BRIGHT_BLACK    => BRIGHT_BLACK,
        BRIGHT_RED      => BRIGHT_RED,
        BRIGHT_GREEN    => BRIGHT_GREEN,
        BRIGHT_YELLOW   => BRIGHT_YELLOW,
        BRIGHT_BLUE     => BRIGHT_BLUE,
        BRIGHT_MAGENTA  => BRIGHT_MAGENTA,
        BRIGHT_CYAN     => BRIGHT_CYAN,
        BRIGHT_WHITE    => BRIGHT_WHITE,
        
        # Background colors
        BG_BLACK        => BG_BLACK,
        BG_RED          => BG_RED,
        BG_GREEN        => BG_GREEN,
        BG_YELLOW       => BG_YELLOW,
        BG_BLUE         => BG_BLUE,
        BG_MAGENTA      => BG_MAGENTA,
        BG_CYAN         => BG_CYAN,
        BG_WHITE        => BG_WHITE,
        DEFAULT_BG      => DEFAULT_BG,
        
        # Bright backgrounds
        BG_BRIGHT_BLACK   => BG_BRIGHT_BLACK,
        BG_BRIGHT_RED     => BG_BRIGHT_RED,
        BG_BRIGHT_GREEN   => BG_BRIGHT_GREEN,
        BG_BRIGHT_YELLOW  => BG_BRIGHT_YELLOW,
        BG_BRIGHT_BLUE    => BG_BRIGHT_BLUE,
        BG_BRIGHT_MAGENTA => BG_BRIGHT_MAGENTA,
        BG_BRIGHT_CYAN    => BG_BRIGHT_CYAN,
        BG_BRIGHT_WHITE   => BG_BRIGHT_WHITE,
    };
    
    return $self->{_codes_cache};
}

=head2 parse

Parse @-codes in text and replace with ANSI escape sequences.

Supports:
- Standard @-codes: @BOLD@, @RED@, @RESET@ etc.
- TrueColor hex: @[RRGGBB] or @[RRGGBB]@ foreground, @[BG:RRGGBB] or @[BG:RRGGBB]@ background
- 256-color: @256:NNN@ foreground, @BG256:NNN@ background

    my $formatted = $ansi->parse($text);

=cut

sub parse {
    my ($self, $text) = @_;
    
    return '' unless defined $text;
    
    # If ANSI is disabled (--no-color), strip extended codes, resolve box-drawing to chars
    unless ($self->{enabled}) {
        $text =~ s/\@\[[^\]]*\]\@?//g;         # Strip @[hex]@ and @[hex] codes
        $text =~ s/\@(?:BG)?256:\d+\@//g;      # Strip @256:N@ codes
        # Box-drawing codes still resolve to characters (they're not color)
        $text =~ s/\@(D?BOX(?:HORIZ|VERT|TOPLEFT|TOPRIGHT|BOTLEFT|BOTRIGHT|TDOWN|TUP|TLEFT|TRIGHT|CROSS))\@/_boxcode_to_char($1)/ge;
        $text =~ s/\@[A-Z_]+\@//g;             # Strip standard @-codes
        return $text;
    }
    
    my $codes = $self->codes();
    
    # 1. TrueColor hex: @[RRGGBB]@ or @[RRGGBB] foreground, @[BG:RRGGBB]@ or @[BG:RRGGBB] background
    #    Both with and without trailing @ are supported (PhotonBBS compat)
    $text =~ s/\@\[([0-9A-Fa-f]{6})\]\@?/_hex_to_ansi($1, 0)/ge;
    $text =~ s/\@\[BG:([0-9A-Fa-f]{6})\]\@?/_hex_to_ansi($1, 1)/ge;
    
    # 2. 256-color: @256:NNN@ foreground, @BG256:NNN@ background
    $text =~ s/\@256:(\d{1,3})\@/_256_to_ansi($1, 0)/ge;
    $text =~ s/\@BG256:(\d{1,3})\@/_256_to_ansi($1, 1)/ge;
    
    # 3. Box-drawing @-codes: @BOXHORIZ@, @BOXVERT@, @DBOXHORIZ@, etc.
    $text =~ s/\@(D?BOX(?:HORIZ|VERT|TOPLEFT|TOPRIGHT|BOTLEFT|BOTRIGHT|TDOWN|TUP|TLEFT|TRIGHT|CROSS))\@/_boxcode_to_char($1)/ge;
    
    # 4. Standard @CODE@ with ANSI escape sequence
    $text =~ s/\@([A-Z_]+)\@/exists $codes->{$1} ? $codes->{$1} : ''/ge;
    
    return $text;
}

=head2 strip

Remove all @-codes from text (including hex and 256-color codes)

=cut

sub strip {
    my ($self, $text) = @_;
    
    return '' unless defined $text;
    
    $text =~ s/\@\[[^\]]*\]\@?//g;         # @[hex]@ and @[hex] codes
    $text =~ s/\@(?:BG)?256:\d+\@//g;      # @256:N@ / @BG256:N@ codes
    $text =~ s/\@[A-Z_]+\@//g;             # Standard @CODE@ patterns
    
    return $text;
}

=head2 strip_ansi

Remove ANSI escape sequences from text

=cut

sub strip_ansi {
    my ($self, $text) = @_;
    
    return '' unless defined $text;
    
    # Remove ANSI CSI sequences (colors, cursor movement, etc.)
    $text =~ s/\e\[[0-9;]*[A-Za-z]//g;
    
    # Remove private-mode sequences (cursor hide/show: \e[?25l, \e[?25h)
    $text =~ s/\e\[\?\d+[lh]//g;
    
    # Remove OSC 8 hyperlinks: \e]8;;URL\e\\text\e]8;;\e\\ -> text
    $text =~ s/\e\]8;;[^\e]*\e\\//g;
    
    return $text;
}

=head2 enable / disable

Enable or disable ANSI code output

=cut

sub enable {
    my ($self) = @_;
    $self->{enabled} = 1;
    delete $self->{_codes_cache};  # Invalidate cache
}

sub disable {
    my ($self) = @_;
    $self->{enabled} = 0;
    delete $self->{_codes_cache};  # Invalidate cache
}

=head2 is_enabled

Check if ANSI codes are enabled

=cut

sub is_enabled {
    my ($self) = @_;
    return $self->{enabled};
}

# ─────────────────────────────────────────────────────────────
# Internal: extended color conversion
# ─────────────────────────────────────────────────────────────

sub _hex_to_ansi {
    my ($hex, $is_bg) = @_;
    my $r = hex(substr($hex, 0, 2));
    my $g = hex(substr($hex, 2, 2));
    my $b = hex(substr($hex, 4, 2));
    my $prefix = $is_bg ? 48 : 38;
    return "\e[${prefix};2;${r};${g};${b}m";
}

sub _256_to_ansi {
    my ($n, $is_bg) = @_;
    $n = 0   if $n < 0;
    $n = 255 if $n > 255;
    my $prefix = $is_bg ? 48 : 38;
    return "\e[${prefix};5;${n}m";
}

sub _boxcode_to_char {
    my ($code) = @_;
    my %box_map = (
        'BOXHORIZ'    => 'horizontal',   'BOXVERT'     => 'vertical',
        'BOXTOPLEFT'  => 'topleft',      'BOXTOPRIGHT'  => 'topright',
        'BOXBOTLEFT'  => 'bottomleft',   'BOXBOTRIGHT'  => 'bottomright',
        'BOXTDOWN'    => 'tdown',        'BOXTUP'       => 'tup',
        'BOXTLEFT'    => 'tleft',        'BOXTRIGHT'    => 'tright',
        'BOXCROSS'    => 'cross',
        'DBOXHORIZ'   => 'dhorizontal',  'DBOXVERT'     => 'dvertical',
        'DBOXTOPLEFT' => 'dtopleft',     'DBOXTOPRIGHT' => 'dtopright',
        'DBOXBOTLEFT' => 'dbottomleft',  'DBOXBOTRIGHT' => 'dbottomright',
    );
    return box_char($box_map{$code} || 'horizontal');
}

1;

__END__

=head1 @-CODE REFERENCE

=head2 Cursor Movement

  @CURSOR_UP@, @CUP@       - Move cursor up one line
  @CURSOR_DOWN@, @CDN@     - Move cursor down one line
  @CURSOR_RIGHT@, @CRT@    - Move cursor right one column
  @CURSOR_LEFT@, @CLT@     - Move cursor left one column
  @CURSOR_HOME@            - Move cursor to top-left (1,1)
  @CURSOR_SAVE@            - Save cursor position
  @CURSOR_RESTORE@         - Restore cursor position
  @CURSOR_HIDE@            - Hide cursor (for animations)
  @CURSOR_SHOW@            - Show cursor (restore after hide)

=head2 Line Operations

  @CLEAR_LINE@, @CLL@      - Clear entire line
  @CLEAR_TO_EOL@           - Clear to end of line
  @CLEAR_TO_BOL@           - Clear to beginning of line
  @CLEAR_SCREEN@, @CLS@   - Clear entire screen
  @CR@                     - Carriage return

=head2 Text Attributes

  @RESET@        - Reset all attributes
  @BOLD@         - Bold/bright text
  @DIM@          - Dim text
  @ITALIC@       - Italic text
  @UNDERLINE@    - Underlined text
  @BLINK@        - Blinking text
  @REVERSE@, @REV@     - Reverse video
  @HIDDEN@       - Hidden text
  @STRIKETHROUGH@, @STRIKE@ - Strikethrough text

=head2 Foreground Colors

  @BLACK@ @RED@ @GREEN@ @YELLOW@ @BLUE@ @MAGENTA@ @CYAN@ @WHITE@
  @BRIGHT_BLACK@ @BRIGHT_RED@ @BRIGHT_GREEN@ @BRIGHT_YELLOW@
  @BRIGHT_BLUE@ @BRIGHT_MAGENTA@ @BRIGHT_CYAN@ @BRIGHT_WHITE@
  @DEFAULT_FG@

=head2 Background Colors

  @BG_BLACK@ @BG_RED@ @BG_GREEN@ @BG_YELLOW@
  @BG_BLUE@ @BG_MAGENTA@ @BG_CYAN@ @BG_WHITE@
  @BG_BRIGHT_BLACK@ @BG_BRIGHT_RED@ @BG_BRIGHT_GREEN@ @BG_BRIGHT_YELLOW@
  @BG_BRIGHT_BLUE@ @BG_BRIGHT_MAGENTA@ @BG_BRIGHT_CYAN@ @BG_BRIGHT_WHITE@
  @DEFAULT_BG@

=head2 Extended Colors

  @[RRGGBB]@       - TrueColor foreground (e.g., @[FF5500]@ = orange)
  @[BG:RRGGBB]@    - TrueColor background (e.g., @[BG:003366]@ = dark blue)
  @256:NNN@        - 256-color foreground (0-255)
  @BG256:NNN@      - 256-color background (0-255)

=head2 Box-Drawing Characters (capability-aware)

  @BOXHORIZ@    - Horizontal line (─ or -)
  @BOXVERT@     - Vertical line (│ or |)
  @BOXTOPLEFT@  - Top-left corner (┌ or +)
  @BOXTOPRIGHT@ - Top-right corner (┐ or +)
  @BOXBOTLEFT@  - Bottom-left corner (└ or +)
  @BOXBOTRIGHT@ - Bottom-right corner (┘ or +)
  @BOXTDOWN@    - T-down junction (┬ or +)
  @BOXTUP@      - T-up junction (┴ or +)
  @BOXTLEFT@    - T-left junction (┤ or +)
  @BOXTRIGHT@   - T-right junction (├ or +)
  @BOXCROSS@    - Cross junction (┼ or +)
  @DBOXHORIZ@   - Double horizontal (═ or =)
  @DBOXVERT@    - Double vertical (║ or |)
  @DBOXTOPLEFT@ - Double top-left (╔ or +)
  @DBOXTOPRIGHT@ - Double top-right (╗ or +)
  @DBOXBOTLEFT@ - Double bottom-left (╚ or +)
  @DBOXBOTRIGHT@ - Double bottom-right (╝ or +)

Box-drawing codes respect terminal capability detection from
L<CLIO::UI::Terminal>. On Unicode terminals they render as line-drawing
characters; on ASCII-only terminals they degrade to +, -, |.

=head1 SEE ALSO

L<CLIO::UI::Terminal>, L<CLIO::UI::Theme>

=cut
