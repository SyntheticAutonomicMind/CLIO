#!/usr/bin/perl
# Regression test for the readline multi-line scroll bug.
#
# Bug: When the user types a large amount of text that crosses the
# terminal's line-wrap boundary (consuming multiple terminal rows),
# then moves the cursor back to a previous line and types more text,
# the entire input section scrolls upward by one row per keystroke.
#
# Root cause: redraw_line computed rows_to_top as (display_lines - 1),
# assuming the cursor was always at the bottom of the input. After
# cursor navigation (arrow keys), the cursor sits on a middle row;
# moving up (display_lines - 1) rows from a middle position overshoots
# past the top of the input area, scrolling terminal content above it.
#
# Fix: Use last_cursor_input_row (the cursor's actual row within the
# input, tracked by reposition_cursor/redraw_line) to compute rows_to_top.
#
# This test verifies two things:
# 1. VT rendering: the prompt and input content are rendered correctly
#    in the right rows (no scroll artifacts).
# 2. Byte-level: redraw_line does not emit excessive cursor-up sequences.
#    With the bug, redraw_line emits \e[2A (move up 2 rows) for a 3-row
#    input even when the cursor is already on row 0. With the fix, it
#    emits 0 cursor-up sequences.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    no warnings 'redefine', 'prototype';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (20, 24) };
    *CLIO::Compat::Terminal::ReadMode        = sub { return 1 };
    *CLIO::Compat::Terminal::ReadKey         = sub {
        return undef unless @main::KEY_QUEUE;
        return shift @main::KEY_QUEUE;
    };
}

our @KEY_QUEUE;

# push_input: converts numeric args to chars, passes strings as-is.
# IMPORTANT: single-char strings that look numeric (like "0") will be
# chr()'d by the numeric check, so avoid digit-only strings in input.
sub push_input {
    push @KEY_QUEUE, map {
        my $v = $_;
        ($v =~ /^-?\d+\z/) ? chr($v) : $v;
    } @_;
}

sub input_chars_for { return map { chr(ord($_)) } split //, $_[0] }

# ---- VirtualTerminal: 2-D buffer processing ANSI escape sequences ----

package VirtualTerminal;

sub new {
    my ($class, %opts) = @_;
    return bless {
        cols   => $opts{cols} || 20,
        rows   => $opts{rows} || 24,
        row    => 0,
        col    => 0,
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
                if ($cmd eq 'C') {
                    my $n = ($param eq '' ? 1 : $param) + 0;
                    $n = 1 if $n == 0;
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{col} += $n;
                    $self->{col} = $self->{cols} - 1 if $self->{col} >= $self->{cols};
                } elsif ($cmd eq 'D') {
                    $self->{pending} = 0;
                    my $n = ($param eq '' ? 1 : $param) + 0;
                    $n = 1 if $n == 0;
                    $self->{col} -= $n;
                    $self->{col} = 0 if $self->{col} < 0;
                } elsif ($cmd eq 'A') {
                    $self->{pending} = 0;
                    my $n = ($param eq '' ? 1 : $param) + 0;
                    $n = 1 if $n == 0;
                    $self->{row} -= $n;
                    $self->{row} = 0 if $self->{row} < 0;
                } elsif ($cmd eq 'B') {
                    my $n = ($param eq '' ? 1 : $param) + 0;
                    $n = 1 if $n == 0;
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{row} += $n;
                } elsif ($cmd eq 'J') {
                    for my $r ($self->{row} .. $self->{rows} - 1) {
                        my $start = ($r == $self->{row}) ? $self->{col} : 0;
                        for my $c ($start .. $self->{cols} - 1) {
                            delete $self->{buffer}[$r][$c];
                        }
                    }
                } elsif ($cmd eq 'H') {
                    $self->{row} = 0;
                    $self->{col} = 0;
                    $self->{pending} = 0;
                }
                $i = $j + 1;
            } else {
                $i++;
            }
        } elsif ($ch eq "\r") {
            $self->{col} = 0;
            $self->{pending} = 0;
            $i++;
        } elsif ($ch eq "\n") {
            if ($self->{pending}) { $self->{pending} = 0 }
            $self->{row}++;
            $self->{col} = 0;
            $i++;
        } elsif ($ch eq "\b") {
            if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
            $self->{col}--;
            $self->{col} = 0 if ($self->{col} < 0);
            $i++;
        } else {
            if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
            $self->{buffer}[$self->{row}][$self->{col}] = $ch;
            $self->{col}++;
            if ($self->{col} >= $self->{cols}) {
                $self->{pending} = 1;
            }
            $i++;
        }
    }
}

sub render {
    my ($self) = @_;
    my @lines;
    for my $r (0 .. $self->{rows} - 1) {
        my $line = '';
        for my $c (0 .. $self->{cols} - 1) {
            $line .= $self->{buffer}[$r][$c] // ' ';
        }
        push @lines, $line;
    }
    return join("\n", @lines);
}

package main;

sub run_scenario {
    my (%args) = @_;

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
            my $rl = CLIO::Core::ReadLine->new(prompt => '> ');
            $rl->{_term_width_cache} = 20;
            $rl->{_term_width_time} = time();
            $rl->{_term_height_cache} = 24;
            $rl->{_term_height_time} = time();
            $rl->readline('> ');
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
        my $n = sysread($read_end, $chunk, 4096);
        last unless defined $n && $n > 0;
        $buf .= $chunk;
    }
    close $read_end;

    my $vt = VirtualTerminal->new(cols => 20, rows => 24);
    $vt->feed($buf);

    return ($vt, $buf);
}

# Count cursor-up escape sequences emitted by redraw_line during
# character insertion. redraw_line emits \e[NA\e[J (move up N,
# clear to end). We count the N values from these sequences.
#
# With the bug: rows_to_top = display_lines - 1 (e.g. 2 for a 3-row
# input), so each redraw_line during mid-input insert emits \e[2A.
# With the fix: rows_to_top = last_cursor_input_row (e.g. 0 when
# cursor is on the top row), so redraw_line emits \e[0A (i.e. nothing).
sub count_redraw_cursor_up {
    my ($bytes) = @_;
    my $total = 0;
    # redraw_line pattern: \r \e[NA \e[J (CR, up N, clear)
    # or: \e[NA \e[J (up N, clear after CR)
    while ($bytes =~ /\e\[(\d*)A\e\[J/g) {
        my $n = $1; $n = 1 if $n eq '';
        $total += $n;
    }
    return $total;
}

use Test::More tests => 6;

# Test 1: Multi-line input (3 rows), cursor moved to middle of row 0,
# insert 3 chars. Terminal: 20 cols. Prompt: "> " (2 cols).
# 42 chars = 3 rows. Move cursor to cp=10 (row 0) via Home + 10 Rights,
# insert XYZ.
#
# With the bug: redraw_line emits \e[2A per insertion (rows_to_top=2).
# With the fix: redraw_line emits nothing (rows_to_top=0).
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKL"));  # 42 chars
    push_input(0x1b, ord('['), ord('H'));  # Home -> cp=0
    push_input((0x1b, ord('['), ord('C')) x 10);  # 10 right arrows -> cp=10
    push_input(ord('X'), ord('Y'), ord('Z'));
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario();
    my @rows = split /\n/, $vt->render, -1;

    # The prompt must still be on row 0 — it should NOT have scrolled up.
    ok($rows[0] =~ /^> /,
       "scroll bug test 1: prompt still on row 0 after mid-input insert");

    # With the fix, redraw_line should not move up (cursor is on row 0).
    # With the bug, it would move up 2 rows per insertion = 6 total.
    my $up_rows = count_redraw_cursor_up($bytes);
    ok($up_rows == 0,
       "scroll bug test 1: no cursor-up from redraw_line (got $up_rows, expected 0)");

    # Row 0 should have the correct content
    is(substr($rows[0], 0, 20), '> abcdefghijXYZklmno',
       "scroll bug test 1: row 0 has prompt + 18 chars incl XYZ");
}

# Test 2: Same scenario but with 5 insertions to verify the scroll
# doesn't compound per-character.
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKL"));  # 42 chars
    push_input(0x1b, ord('['), ord('H'));  # Home -> cp=0
    push_input((0x1b, ord('['), ord('C')) x 10);  # 10 right arrows -> cp=10
    push_input(ord('A'), ord('B'), ord('C'), ord('D'), ord('E'));
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario();
    my @rows = split /\n/, $vt->render, -1;

    ok($rows[0] =~ /^> /,
       "scroll bug test 2: prompt still on row 0 after 5 mid-input inserts");

    my $up_rows = count_redraw_cursor_up($bytes);
    ok($up_rows == 0,
       "scroll bug test 2: no cursor-up from redraw_line (got $up_rows, expected 0)");

    is(substr($rows[0], 0, 20), '> abcdefghijABCDEklm',
       "scroll bug test 2: row 0 has prompt + 18 chars incl ABCDE");
}

