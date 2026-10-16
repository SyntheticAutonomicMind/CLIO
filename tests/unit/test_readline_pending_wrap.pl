#!/usr/bin/perl
# Test: pending wrap cursor position after backspace + type
#
# Bug: When the user types text that fills a terminal row exactly
# (prompt + input = N * term_width), the terminal enters "pending wrap"
# state — the cursor is at col term_width (the last column) with a flag
# indicating the NEXT printable char will wrap to the next row.
#
# When backspace is pressed at this exact boundary, redraw_line would
# move up by old_cursor_input_row (which counts the pending row),
# overshooting past the top of the input area. The \r resolves the
# pending state, then \e[NA moves above the input, clearing chat content.
#
# Fix: Track last_cursor_pending. When set, subtract 1 from
# rows_to_top in redraw_line and _redraw_line_external.

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
sub push_input { push @KEY_QUEUE, @_; }
sub bs() { return chr(0x7f) }
sub ent() { return "\r" }

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
                    if ($self->{pending}) { $self->{pending} = 0 }
                    my $n = ($param eq '' ? 1 : $param) + 0;
                    $n = 1 if $n == 0;
                    $self->{col} -= $n;
                    $self->{col} = 0 if $self->{col} < 0;
                } elsif ($cmd eq 'A') {
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
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
                } elsif ($cmd eq 'K') {
                    for my $c ($self->{col} .. $self->{cols} - 1) {
                        delete $self->{buffer}[$self->{row}][$c];
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
            if ($self->{col} > 0) {
                $self->{col}--;
            }
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

sub row_chars {
    my ($self, $r) = @_;
    my $line = '';
    for my $c (0 .. $self->{cols} - 1) {
        $line .= $self->{buffer}[$r][$c] // ' ';
    }
    return $line;
}

package main;

sub run_readline {
    my ($keys, $prompt, $cols, $rows) = @_;

    pipe(my $r, my $w) or die "pipe: $!";
    my $saved_fd = select($w);
    $| = 1;

    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
        select($w);
        $| = 1;
        eval {
            local $SIG{ALRM} = sub { die "TIMEOUT\n" };
            alarm 15;
            require CLIO::Core::ReadLine;
            my $rl = CLIO::Core::ReadLine->new(prompt => $prompt);
            $rl->{_term_size_cache} = [$cols, $rows];
            $rl->{_term_size_time} = time();
            $rl->readline($prompt);
            alarm 0;
        };
        exit(0);
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

    close $w;
    select($saved_fd);
    $| = 1;

    my $buf = '';
    while (1) {
        my $chunk = '';
        my $n = sysread($r, $chunk, 8192);
        last unless defined $n && $n > 0;
        $buf .= $chunk;
    }
    close $r;

    my $vt = VirtualTerminal->new(cols => $cols, rows => $rows);
    $vt->feed($buf);

    return ($vt, $buf);
}

use Test::More tests => 8;

# Test 1: 18 chars (fills row 0 exactly), backspace, type Z
# After 18 chars: total_disp = 20 = term_width. Pending.
# Without fix: redraw_line moves up 1 row (above input area, into chat content).
# With fix: rows_to_top = 0, no cursor-up.
{
    @main::KEY_QUEUE = ();
    push_input(('a') x 18);
    push_input(bs());
    push_input('Z');
    push_input(ent());

    my ($vt, $raw) = run_readline(\@main::KEY_QUEUE, '> ', 20, 24);

    # Row 0 should have prompt + 17 a + Z = 20 chars
    my $row0 = $vt->row_chars(0);
    is(substr($row0, 0, 20), '> ' . ('a' x 17) . 'Z',
       "pending-wrap backspace T1: row 0 has prompt + 17a + Z");

    # Row 1 should be empty (no spurious content)
    my $row1 = $vt->row_chars(1);
    ok(substr($row1, 0, 1) eq ' ',
       "pending-wrap backspace T1: row 1 is empty (cursor didn't jump to row 1)");

    # No cursor-up should be emitted by redraw_line when pending
    # (rows_to_top = 0)
    my $up_count = 0;
    while ($raw =~ /\e\[0*([1-9]\d*)A/g) { $up_count += $1; }
    is($up_count, 0, "pending-wrap backspace T1: no excessive cursor-up (got $up_count)");
}

# Test 2: 38 chars (fills 2 rows exactly), backspace, type Z
# After 38 chars: total_disp = 40 = 2 * term_width. Pending.
# Without fix: redraw_line moves up 2 rows (overshooting by 1).
# With fix: rows_to_top = 1, moves up 1 row.
{
    @main::KEY_QUEUE = ();
    push_input(('a') x 38);
    push_input(bs());
    push_input('Z');
    push_input(ent());

    my ($vt, $raw) = run_readline(\@main::KEY_QUEUE, '> ', 20, 24);

    # Row 0 should be full (prompt + 18 a)
    my $row0 = $vt->row_chars(0);
    is(substr($row0, 0, 20), '> ' . ('a' x 18),
       "pending-wrap backspace T2: row 0 full with 18 a's");

    # Row 1 should have the remaining 19 a's + Z = 20 chars
    my $row1 = $vt->row_chars(1);
    is(substr($row1, 0, 20), ('a' x 19) . 'Z',
       "pending-wrap backspace T2: row 1 has 19a + Z");

    # The cursor-up from redraw_line should be exactly 1 (not 2).
    my $up_total = 0;
    while ($raw =~ /\e\[(\d*)A/g) {
        my $n = $1; $n = 1 if $n eq '';
        $up_total += $n;
    }
    is($up_total, 1, "pending-wrap backspace T2: correct cursor-up (got $up_total, expected 1)");
}

# Test 3: 19 chars (cursor at row 1 col 2, NOT pending), backspace, type Z
# Fast-path is used, no redraw_line. Should work correctly.
{
    @main::KEY_QUEUE = ();
    push_input(('a') x 19);
    push_input(bs());
    push_input('Z');
    push_input(ent());

    my ($vt, $raw) = run_readline(\@main::KEY_QUEUE, '> ', 20, 24);

    # Row 0: prompt + 18 a
    my $row0 = $vt->row_chars(0);
    is(substr($row0, 0, 20), '> ' . ('a' x 18),
       "non-pending backspace T3: row 0 full with 18 a's");

    # Row 1: 'Z'
    my $row1 = $vt->row_chars(1);
    is(substr($row1, 0, 1), 'Z',
       "non-pending backspace T3: row 1 has Z");
}
