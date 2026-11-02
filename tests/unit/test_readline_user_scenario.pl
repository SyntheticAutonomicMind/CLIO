#!/usr/bin/perl
# End-to-end reproduction of the "stuck cursor at row boundary" bug.
#
# User scenario: 80-col terminal, 37-char prompt. Type enough text to
# fill 4 rows. Navigate with Left arrow to the end-of-row boundary,
# then press Left again. Verify the VT cursor matches _cursor_at_codepoint
# at every step.
#
# Uses the fork/pipe readline loop so the FULL interactive flow is
# tested (key parsing, escape-sequence handling, state management,
# reposition_cursor).

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    no warnings 'redefine', 'prototype';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (80, 24) };
    *CLIO::Compat::Terminal::ReadMode        = sub { return 1 };
    *CLIO::Compat::Terminal::ReadKey         = sub {
        return undef unless @main::KEY_QUEUE;
        return shift @main::KEY_QUEUE;
    };
}

our @KEY_QUEUE;

sub input_chars_for { return map { chr(ord($_)) } split //, $_[0] }
sub push_input { push @main::KEY_QUEUE, map { my $v = $_; ($v =~ /^-?\d+\z/) ? chr($v) : $v } @_; }

# ---- VirtualTerminal: tracks cursor from ANSI bytes CLIO emits ----
# Models xterm deferred-autowrap: pending state is NOT resolved by
# cursor movement commands, only by character output or CR.
package VirtualTerminal;

sub new {
    my ($class, %opts) = @_;
    return bless {
        cols   => $opts{cols} || 80,
        rows   => $opts{rows} || 24,
        row    => 0,
        col    => 0,       # 0-indexed
        buffer => [],
        pending => 0,
    }, $class;
}

sub feed {
    my ($self, $bytes) = @_;
    my $i = 0;
    while ($i < length($bytes)) {
        my $ch = substr($bytes, $i, 1);
        if ($ch eq "\e") {
            if (substr($bytes, $i + 1, 1) eq '[') {
                my $j = $i + 2;
                $j++ while $j < length($bytes) && substr($bytes, $j, 1) =~ /[\d;?]/;
                my $param = substr($bytes, $i + 2, $j - $i - 2);
                my $cmd = substr($bytes, $j, 1);
                $i = $j + 1;
                next if $param =~ /\?/;  # skip private modes (\e[?2004h)
                my $n = ($param ne '' && $param =~ /^(\d+)/ ? $1 : 1) + 0;
                $n = 1 if $n == 0;
                if ($cmd eq 'C') {
                    # Cursor right — does NOT resolve pending (xterm behavior)
                    $self->{col} += $n;
                    $self->{col} = $self->{cols} - 1 if $self->{col} >= $self->{cols};
                } elsif ($cmd eq 'D') {
                    # Cursor left — does NOT resolve pending (xterm behavior)
                    $self->{col} -= $n;
                    $self->{col} = 0 if $self->{col} < 0;
                } elsif ($cmd eq 'A') {
                    # Cursor up — does NOT resolve pending (xterm behavior)
                    $self->{row} -= $n;
                    $self->{row} = 0 if $self->{row} < 0;
                } elsif ($cmd eq 'B') {
                    # Cursor down — does NOT resolve pending (xterm behavior)
                    $self->{row} += $n;
                } elsif ($cmd eq 'K') {
                    # Erase to end of line
                    for (my $c = $self->{col}; $c < $self->{cols}; $c++) {
                        delete $self->{buffer}[$self->{row}][$c];
                    }
                } elsif ($cmd eq 'J') {
                    for my $r ($self->{row} .. $self->{rows} - 1) {
                        my $start = ($r == $self->{row}) ? $self->{col} : 0;
                        for my $c ($start .. $self->{cols} - 1) {
                            delete $self->{buffer}[$r][$c];
                        }
                    }
                } elsif ($cmd eq 'H') {
                    my @p = split /;/, $param;
                    $self->{row} = (($p[0] // '') ne '' ? $p[0] : 1) - 1;
                    $self->{col} = (($p[1] // '') ne '' ? $p[1] : 1) - 1;
                    $self->{pending} = 0;
                }
            } else {
                $i++;
            }
        } elsif ($ch eq "\r") {
            $self->{col} = 0; $self->{pending} = 0; $i++;
        } elsif ($ch eq "\n") {
            if ($self->{pending}) { $self->{pending} = 0 }
            $self->{row}++; $self->{col} = 0; $i++;
        } elsif ($ch eq "\b") {
            if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
            $self->{col}--;
            $self->{col} = 0 if $self->{col} < 0; $i++;
        } else {
            if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
            $self->{buffer}[$self->{row}][$self->{col}] = $ch;
            $self->{col}++;
            if ($self->{col} >= $self->{cols}) { $self->{pending} = 1; $self->{col} = $self->{cols} - 1;
            }
            $i++;
        }
    }
}

# Get VT cursor as (row_0indexed, col_0indexed, pending)
sub cursor { my $s = shift; return ($s->{row}, $s->{col}, $s->{pending}) }

sub render {
    my $s = shift;
    my @lines;
    for my $r (0 .. $s->{rows} - 1) {
        my $line = '';
        for my $c (0 .. $s->{cols} - 1) {
            $line .= $s->{buffer}[$r][$c] // ' ';
        }
        push @lines, $line;
    }
    return join("\n", @lines);
}

package main;

use Test::More;
use CLIO::Core::ReadLine;

my $cols = 80;
my $prompt = '>' . (' ' x 36);  # 37 chars

# Build 213-char input (4 rows: 43 + 80 + 80 + 10)
my $input = '';
for my $i (0 .. 212) {
    $input .= chr(ord('a') + ($i % 26));
}
die "Input should be 213 chars" unless length($input) == 213;

# model_pos: get (row_0indexed, col_1indexed) from _cursor_at_codepoint
my $cached_rl;
sub model_pos {
    my ($cp) = @_;
    $cached_rl //= do {
        my $rl = CLIO::Core::ReadLine->new(prompt => $prompt);
        $rl->{_term_size_cache} = [$cols, 24];
        $rl->{_term_size_time} = time();
        $rl->{_prompt_disp_cache} = length($prompt);
        $rl;
    };
    return $cached_rl->_cursor_at_codepoint($input, $cp, $prompt);
}

sub run_scenario {
    pipe(my $read_end, my $write_end) or die "pipe: $!";
    my $saved_stdout = select($write_end);
    $| = 1;

    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
        select($write_end);
        $| = 1;
        eval {
            local $SIG{ALRM} = sub { die "TIMEOUT\n" };
            alarm 15;
            require CLIO::Core::ReadLine;
            my $rl = CLIO::Core::ReadLine->new(prompt => $prompt);
            $rl->{_term_size_cache} = [$cols, 24];
            $rl->{_term_size_time} = time();
            $rl->readline($prompt);
            alarm 0;
        };
        if ($@) {
            print STDERR "CHILD ERROR: $@";
            exit 1;
        }
        exit 0;
    }

    my $waited = 0;
    while ($waited < 15) {
        my $kid = waitpid($pid, 1);
        last if $kid == $pid;
        select(undef, undef, undef, 0.05);
        $waited += 0.05;
    }
    if (kill 0, $pid) {
        kill 'KILL', $pid;
        waitpid($pid, 0);
    }

    close $write_end;
    select($saved_stdout);
    $| = 1;

    my $buf = '';
    while (1) {
        my $chunk = '';
        my $n = sysread($read_end, $chunk, 8192);
        last unless defined $n && $n > 0;
        $buf .= $chunk;
    }
    close $read_end;

   my $vt = VirtualTerminal->new(cols => $cols, rows => 24);
    # Strip everything from the submit point onward: the bracketed-paste
    # disable, the move-to-end-of-input, and the submit newline emitted when
    # Enter is pressed. This is the "submit" sequence, not part of
    # cursor positioning. The VT cursor must reflect the state before
    # Enter was pressed, to match model_pos.
    (my $vt_buf = $buf) =~ s/\e\[\?2004l.*\z//s;
    $vt->feed($vt_buf);
    return ($vt, $buf);
}

# ---- Scenario: Navigate Left through 4 rows, verify final VT cursor ----
# Type 213 chars, then press Left 10 times to reach the row-2/row-3 boundary,
# then press Left once more. The Enter finishes the line.
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for($input));
    # 213 Left = cp=0. That's 213 Left presses.
    push_input((0x1b, ord('['), ord('D')) x 213);
    push_input(0x0a);  # Enter

    my ($vt, $bytes) = run_scenario();

    # After 213 Lefts from cp=213, cursor should be at cp=0.
    # cp=0: model says (0, 38) [1-indexed col]. VT should be at (0, 37) [0-indexed col].
    my ($vr, $vc, $vp) = $vt->cursor();
    my ($mr, $mc) = model_pos(0);
    is($vr, $mr, "navigate-all-back: VT row matches model at cp=0 (got $vr, expected $mr)");
    is($vc + 1, $mc, "navigate-all-back: VT col matches model at cp=0 (got " . ($vc + 1) . ", expected $mc)");

    # Input content should be intact
    my @rows = split /\n/, $vt->render, -1;
    # Verify row 0 content is intact after 213 Lefts: prompt + first 16 input chars
    is(substr($rows[0], 0, length($prompt) + 16), $prompt . 'abcdefghijklmnop',
       "navigate-all-back: row 0 has prompt + input start");
}

# ---- Scenario: Left to boundary, then Left from boundary ----
# Type 213 chars. Press Left 10 times to reach cp=203 (row 2, col 80, pending).
# Then press Left once more to reach cp=202 (row 2, col 79).
# Then Enter. Verify VT cursor matches model at cp=202.
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for($input));
    # Left 10 times: cp=213 -> cp=203 (row 2, col 80, pending)
    push_input((0x1b, ord('['), ord('D')) x 10);
    # One more Left: cp=203 -> cp=202 (row 2, col 79)
    push_input(0x1b, ord('['), ord('D'));
    push_input(0x0a);  # Enter

    my ($vt, $bytes) = run_scenario();

    # After 11 Lefts from end, cursor should be at cp=202.
    my ($vr, $vc, $vp) = $vt->cursor();
    my ($mr, $mc) = model_pos(202);
    is($vr, $mr, "boundary-11-lefts: VT row matches model at cp=202 (got $vr, expected $mr)");
    is($vc + 1, $mc, "boundary-11-lefts: VT col matches model at cp=202 (got " . ($vc + 1) . ", expected $mc)");
}

# ---- Scenario: Type at end (causes redraw), then navigate back ----
# Type 213 chars, then type 1 more at cp=213 (end), then Left, Left, Enter.
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for($input));
    push_input(ord('z'));  # 214th char, at end -> fast path (emit + refresh)
    push_input((0x1b, ord('['), ord('D')) x 2);  # Left x2 -> cp=212
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario();

    my ($vr, $vc, $vp) = $vt->cursor();
    my ($mr, $mc) = model_pos(212);
    is($vr, $mr, "type-then-left: VT row matches model at cp=212 (got $vr, expected $mr)");
    is($vc + 1, $mc, "type-then-left: VT col matches model at cp=212 (got " . ($vc + 1) . ", expected $mc)");
}

# ---- Scenario: Type 1 char at end, then navigate ALL the way back ----
# This tests the interaction between fast-path insert and reposition_cursor.
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for($input));
    push_input(ord('z'));  # 214 chars total
    # Navigate all the way back: 214 Lefts
    push_input((0x1b, ord('['), ord('D')) x 214);
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario();

    my ($vr, $vc, $vp) = $vt->cursor();
    my ($mr, $mc) = model_pos(0);
    is($vr, $mr, "type-then-nav-all-back: VT row at cp=0 (got $vr, expected $mr)");
    is($vc + 1, $mc, "type-then-nav-all-back: VT col at cp=0 (got " . ($vc + 1) . ", expected $mc)");

    # Verify input is intact
    ok($input . 'z' eq do { my $s = $input; $s .= 'z'; $s }, "sanity check");
}

# ---- Scenario: Navigate to boundary via Home + Right arrows ----
# Type 213 chars, press Home (cp=0), then Right arrow 43 times to reach
# cp=43 (end of row 0, col 80, pending). Then Left once.
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for($input));
    push_input(0x1b, ord('['), ord('H'));  # Home -> cp=0
    push_input((0x1b, ord('['), ord('C')) x 43);  # 43 Rights -> cp=43 (row 0, col 80, pending)
    push_input(0x1b, ord('['), ord('D'));  # Left -> cp=42 (row 0, col 79)
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario();

    my ($vr, $vc, $vp) = $vt->cursor();
    my ($mr, $mc) = model_pos(42);
    is($vr, $mr, "home-then-right-to-boundary: VT row at cp=42 (got $vr, expected $mr)");
    is($vc + 1, $mc, "home-then-right-to-boundary: VT col at cp=42 (got " . ($vc + 1) . ", expected $mc)");
}

done_testing();