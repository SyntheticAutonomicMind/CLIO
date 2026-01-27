package CLIO::UI::ANSI;

use strict;
use warnings;

=head1 NAME

CLIO::UI::ANSI - ANSI escape code management with @-code system

=head1 DESCRIPTION

Provides ANSI escape codes and an @-code system for terminal formatting,
similar to PhotonBBS/PhotonMUD. This enables consistent theming and styling
across CLIO.

=head1 SYNOPSIS

    use CLIO::UI::ANSI;
    
    my $ansi = CLIO::UI::ANSI->new();
    
    # Use @ codes for formatting
    print $ansi->parse("@BOLD@Hello @RED@World@RESET@\n");
    
    # Or use direct codes
    print $ansi->codes->{BOLD}, "Hello", $ansi->codes->{RESET}, "\n";

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

Get hash reference of all ANSI codes

=cut

sub codes {
    my ($self) = @_;
    
    return {} unless $self->{enabled};
    
    return {
        # Cursor movement
        CURSOR_UP       => CURSOR_UP,
        CURSOR_DOWN     => CURSOR_DOWN,
        CURSOR_RIGHT    => CURSOR_RIGHT,
        CURSOR_LEFT     => CURSOR_LEFT,
        CURSOR_HOME     => CURSOR_HOME,
        CURSOR_SAVE     => CURSOR_SAVE,
        CURSOR_RESTORE  => CURSOR_RESTORE,
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
        HIDDEN          => HIDDEN,
        STRIKETHROUGH   => STRIKETHROUGH,
        
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
}

=head2 parse

Parse @-codes in text and replace with ANSI escape sequences

    # Example: @BOLD@Hello @RED@World@RESET@
    my $formatted = $ansi->parse($text);

=cut

sub parse {
    my ($self, $text) = @_;
    
    return $text unless $self->{enabled};
    return '' unless defined $text;
    
    my $codes = $self->codes();
    
    # Replace @CODE@ with actual ANSI escape sequence
    # For valid codes: replace with ANSI escape sequence
    # For invalid codes: strip the @-code markers (they were intended as formatting)
    # This handles AI mistakes like @BRIGHT@ (invalid) while preserving valid codes
    $text =~ s/\@([A-Z_]+)\@/exists $codes->{$1} ? $codes->{$1} : ''/ge;
    
    return $text;
}

=head2 strip

Remove all @-codes from text

=cut

sub strip {
    my ($self, $text) = @_;
    
    return '' unless defined $text;
    
    # Remove @CODE@ patterns
    $text =~ s/@[A-Z_]+@//g;
    
    return $text;
}

=head2 strip_ansi

Remove ANSI escape sequences from text

=cut

sub strip_ansi {
    my ($self, $text) = @_;
    
    return '' unless defined $text;
    
    # Remove ANSI escape sequences
    $text =~ s/\e\[[0-9;]*[A-Za-z]//g;
    
    return $text;
}

=head2 enable / disable

Enable or disable ANSI code output

=cut

sub enable {
    my ($self) = @_;
    $self->{enabled} = 1;
}

sub disable {
    my ($self) = @_;
    $self->{enabled} = 0;
}

=head2 is_enabled

Check if ANSI codes are enabled

=cut

sub is_enabled {
    my ($self) = @_;
    return $self->{enabled};
}

1;

__END__

=head1 @-CODE REFERENCE

=head2 Cursor Movement

  @CURSOR_UP@, @CUP@       - Move cursor up one line
  @CURSOR_DOWN@, @CDN@     - Move cursor down one line
  @CURSOR_RIGHT@, @CRT@    - Move cursor right one column
  @CURSOR_LEFT@, @CLT@     - Move cursor left one column
  @CURSOR_HOME@            - Move cursor to home position
  @CURSOR_SAVE@            - Save cursor position
  @CURSOR_RESTORE@         - Restore cursor position

=head2 Line Operations

  @CLEAR_LINE@, @CLL@      - Clear entire line
  @CLEAR_TO_EOL@           - Clear from cursor to end of line
  @CLEAR_TO_BOL@           - Clear from cursor to beginning of line
  @CLEAR_SCREEN@, @CLS@    - Clear entire screen
  @CR@                     - Carriage return

=head2 Text Attributes

  @RESET@                  - Reset all attributes
  @BOLD@                   - Bold text
  @DIM@                    - Dim/faint text
  @ITALIC@                 - Italic text
  @UNDERLINE@              - Underlined text
  @BLINK@                  - Blinking text
  @REVERSE@                - Reverse video
  @HIDDEN@                 - Hidden text
  @STRIKETHROUGH@          - Strikethrough text

=head2 Colors

  @BLACK@, @RED@, @GREEN@, @YELLOW@, @BLUE@, @MAGENTA@, @CYAN@, @WHITE@
  
  @BRIGHT_BLACK@, @BRIGHT_RED@, @BRIGHT_GREEN@, @BRIGHT_YELLOW@,
  @BRIGHT_BLUE@, @BRIGHT_MAGENTA@, @BRIGHT_CYAN@, @BRIGHT_WHITE@
  
  @BG_BLACK@, @BG_RED@, @BG_GREEN@, @BG_YELLOW@, @BG_BLUE@,
  @BG_MAGENTA@, @BG_CYAN@, @BG_WHITE@

=head1 USAGE EXAMPLES

  # Simple colored output
  print $ansi->parse("@BOLD@@GREEN@Success!@RESET@\n");
  
  # Cursor manipulation
  print $ansi->parse("@CURSOR_UP@@CLL@Updated line@CR@\n");
  
  # Complex formatting
  my $text = "@BOLD@@CYAN@CLIO@RESET@ - @DIM@Command Line Intelligence Orchestrator@RESET@";
  print $ansi->parse($text), "\n";

=head1 FUTURE ENHANCEMENTS

- Theme system (/config theme <name>)
- Custom @-code definitions
- Color palettes
- Terminal capability detection

=head1 AUTHOR

Fewtarius

=cut

1;
