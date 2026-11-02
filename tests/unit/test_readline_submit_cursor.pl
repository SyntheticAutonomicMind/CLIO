#!/usr/bin/perl
# Regression test: submitting a multi-row input must leave the cursor
# AFTER the input, never inside it.
#
# Scenario: the input wraps past the terminal width. The user scrolls back
# to an earlier row to make an edit, then presses Enter to submit. ReadLine
# must move the cursor to the end of the input before emitting the submit
# newline, so the newline -- and everything printed after it (the busy
# indicator, the "YOU: ..." echo) -- lands below the whole input instead of
# in the middle of it.
#
# Uses the fork/pipe readline loop so the FULL interactive flow is tested
# (key parsing, escape-sequence handling, state management, reposition).

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

use Test::More tests => 18;
use CLIO::Core::ReadLine;

my $cols = 80;
my $prompt = '>' . (' ' x 36);  # 37 chars wide

# 213-char input => 4 display rows on an 80-col terminal
# (row 0: 43 chars, row 1: 80, row 2: 80, row 3: 10)
my $input = '';
for my $i (0 .. 212) {
    $input .= chr(ord('a') + ($i % 26));
}
my $INPUT_ROWS = 4;

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
    $vt->feed($buf);
    return ($vt, $buf);
}

# ---- Scenario 1: cursor scrolled back to row 0, then Enter ----
# The submit newline must land BELOW all 4 input rows (row 4), not on row 1.
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for($input));
    push_input(0x1b, ord('['), ord('H'));  # Home -> cursor to row 0
    push_input(0x0a);                     # Enter

    my ($vt, $bytes) = run_scenario();
    my ($vr, $vc, $vp) = $vt->cursor();

    is($vr, $INPUT_ROWS,
       "submit-after-home: cursor lands below the input (row $INPUT_ROWS), got $vr");
    is($vc, 0,
       "submit-after-home: cursor at column 0 after submit, got $vc");

    # The input itself must be untouched by the cursor move.
    my @rows = split /\n/, $vt->render, -1;
    is(substr($rows[0], 0, 37), $prompt,
       "submit-after-home: prompt intact on row 0");
    is(substr($rows[0], 37, 43), substr($input, 0, 43),
       "submit-after-home: row 0 input intact");
    is(substr($rows[3], 0, 10), substr($input, 203, 10),
       "submit-after-home: last input row intact");
}

# ---- Scenario 2: cursor scrolled back to row 0, edit made, then Enter ----
# Inserting a character mid-input triggers a full redraw; the submit
# newline must still land below the whole input.
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for($input));
    push_input(0x1b, ord('['), ord('H'));  # Home
    push_input(ord('Z'));                  # insert at row 0
    push_input(0x0a);                     # Enter

    my ($vt, $bytes) = run_scenario();
    my ($vr, $vc, $vp) = $vt->cursor();

    is($vr, $INPUT_ROWS,
       "submit-after-edit: cursor lands below the input (row $INPUT_ROWS), got $vr");
    is($vc, 0,
       "submit-after-edit: cursor at column 0 after submit, got $vc");

    my @rows = split /\n/, $vt->render, -1;
    is(substr($rows[0], 37, 43), 'Z' . substr($input, 0, 42),
       "submit-after-edit: edited row 0 intact");
}

# ---- Scenario 3: cursor in the middle of the input (row 2), then Enter ----
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for($input));
    # 95 Lefts from the end -> cp=118, which is on row 1 of the wrapped input.
    push_input((0x1b, ord('['), ord('D')) x 95);  # cp = 213 - 95 = 118
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario();
    my ($vr, $vc, $vp) = $vt->cursor();

    is($vr, $INPUT_ROWS,
       "submit-from-middle: cursor lands below the input (row $INPUT_ROWS), got $vr");
    is($vc, 0,
       "submit-from-middle: cursor at column 0 after submit, got $vc");
}

# ---- Scenario 4: cursor already at the end of the input, then Enter ----
# Baseline: behavior must be unchanged when the cursor never moved.
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for($input));
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario();
    my ($vr, $vc, $vp) = $vt->cursor();

    is($vr, $INPUT_ROWS,
       "submit-at-end: cursor lands below the input (row $INPUT_ROWS), got $vr");
    is($vc, 0,
       "submit-at-end: cursor at column 0 after submit, got $vc");
}

# ---- Scenario 5: single-row input, cursor scrolled back, then Enter ----
# The submit newline must still clear the row so later output does not
# land on top of the input text.
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for("hello world"));
    push_input(0x1b, ord('['), ord('H'));  # Home
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario();
    my ($vr, $vc, $vp) = $vt->cursor();

    is($vr, 1,
       "submit-single-row: cursor lands on row 1 after submit, got $vr");
    is($vc, 0,
       "submit-single-row: cursor at column 0 after submit, got $vc");

    my @rows = split /\n/, $vt->render, -1;
    is(substr($rows[0], 0, 48), $prompt . 'hello world',
       "submit-single-row: input text intact on row 0");
}

# ---- Scenario 6: the submit newline is the LAST thing emitted ----
# The cursor move must precede the newline, not follow it.
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for($input));
    push_input(0x1b, ord('['), ord('H'));
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario();

    like($bytes, qr/\r\n\z/,
         "submit-order: submit newline is the final byte sequence");
    is(scalar(() = $bytes =~ /\r\n/g), 1,
       "submit-order: only the submit newline is emitted");
}

# ---- Scenario 7: Ctrl-C abort marker lands after the whole input ----
# The abort marker has the same problem as the submit newline: printed at
# the cursor position it splits a multi-row input.
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for($input));
    push_input(0x1b, ord('['), ord('H'));  # Home
    push_input(0x03);                     # Ctrl-C

    my ($vt, $bytes) = run_scenario();
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[3], 0, 12), substr($input, 203, 10) . '^C',
       "submit-ctrl-c: abort marker lands after the input");
}
