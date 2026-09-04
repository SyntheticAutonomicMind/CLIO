#!/usr/bin/perl
# Test: ReadLine word movement across line boundaries.
#
# Reproduces the off-by-one bug in reposition_cursor when moving
# by word (Ctrl+Left/Right, Alt+Left/Right) on multi-line input.
#
# Strategy: call move_word_* methods directly, capture printed escape
# codes into a buffer, and verify against a virtual terminal.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    no warnings 'redefine', 'prototype';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (20, 24) };
    *CLIO::Compat::Terminal::ReadMode = sub { return 1 };
}

# --- VirtualTerminal (0-indexed cols) ---
package VirtualTerminal;
sub new {
    my ($class, %opts) = @_;
    return bless {
        cols => $opts{cols} || 20,
        rows => $opts{rows} || 24,
        row => 0, col => 0,
        buffer => [], pending => 0,
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
                my @parts = split /;/, $param;
                my $n = (@parts && $parts[0] ne '' ? $parts[0] : 1) + 0;
                if ($cmd eq 'C') {
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{col} += $n;
                    $self->{col} = $self->{cols} - 1 if $self->{col} >= $self->{cols};
                } elsif ($cmd eq 'D') {
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{col} -= $n;
                    $self->{col} = 0 if $self->{col} < 0;
                } elsif ($cmd eq 'A') {
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{row} -= $n;
                    $self->{row} = 0 if $self->{row} < 0;
                } elsif ($cmd eq 'B') {
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{row} += $n;
                } elsif ($cmd eq 'J') {
                    for my $r ($self->{row} .. $self->{rows} - 1) {
                        my $start = ($r == $self->{row}) ? $self->{col} : 0;
                        for my $c ($start .. $self->{cols} - 1) {
                            delete $self->{buffer}[$r][$c];
                        }
                    }
                }
                $i = $j + 1;
            } else {
                $i += 2;
            }
        } elsif ($ch eq "\r") {
            $self->{col} = 0; $self->{pending} = 0; $i++;
        } elsif ($ch eq "\n") {
            $self->{row}++; $i++;
        } elsif ($ch eq "\b") {
            if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
            $self->{col}--;
            $self->{col} = 0 if $self->{col} < 0; $i++;
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

sub cursor { my $s = shift; return ($s->{row}, $s->{col}) }
sub char_at { my ($s, $r, $c) = @_; return $s->{buffer}[$r][$c] // ' ' }

package main;

use Test::More tests => 7;

# Helper: create a ReadLine with 20-col terminal, print prompt + input,
# return (rl, vt) ready for cursor tracking.
use CLIO::Core::ReadLine;

sub setup_rl {
    my ($input, $cursor_pos) = @_;
    my $rl = CLIO::Core::ReadLine->new(prompt => '> ');
    my $vt = VirtualTerminal->new(cols => 20, rows => 24);

    # Open a pipe to catch CLIO's print statements
    pipe(my $r, my $w) or die "pipe: $!";
    my $old = select($w); $| = 1;

    # Type out the input character by character (simulating user typing)
    $rl->_emit_text('> ');
    $vt->feed('> ');
    for my $i (0 .. length($input) - 1) {
        my $ch = substr($input, $i, 1);
        $rl->_emit_text($ch);
        $vt->feed($ch);
    }

    # Now simulate cursor movement to cursor_pos
    if ($cursor_pos < length($input)) {
        # Move cursor left from end to cursor_pos
        my $old_pos = length($input);
        # Use reposition_cursor to set cursor at cursor_pos
        $rl->reposition_cursor(\$old_pos, \$cursor_pos, \$input, '> ');
        # Capture what reposition_cursor printed
        select($old);
        close $w;
        my $buf = '';
        { local $/; $buf = <$r>; }
        close $r;
        $vt->feed($buf);
    } else {
        select($old);
        close $w;
        my $buf = '';
        { local $/; $buf = <$r>; }
        close $r;
    }

    return ($rl, $vt);
}

# Helper: call a method, capture printed bytes, feed to VT
sub do_move {
    my ($rl, $vt, $method, $input_ref, $cursor_pos_ref, $prompt) = @_;
    pipe(my $r, my $w) or die "pipe: $!";
    my $old = select($w); $| = 1;
    $rl->$method($input_ref, $cursor_pos_ref, $prompt);
    select($old);
    close $w;
    my $buf = '';
    { local $/; $buf = <$r>; }
    close $r;
    if ($ENV{DEBUG_VT}) {
        print STDERR "do_move($method): bytes=" . join(' ', map { sprintf('0x%02X', ord($_)) } split //, $buf) . "\n";
        print STDERR "do_move($method): before VT cursor=($vt->{row},$vt->{col}) pending=$vt->{pending}\n";
    }
    $vt->feed($buf);
    if ($ENV{DEBUG_VT}) {
        print STDERR "do_move($method): after VT cursor=($vt->{row},$vt->{col}) pending=$vt->{pending}\n";
    }
}

# --- Test 1: Word movement across line boundary ---
# Input: "hello world foo bar" (19 chars on 20-col terminal, prompt "> ")
# Wraps: row 0 = 18 chars (cols 3-20), row 1 = 1 char (col 2)
# Cursor at end (pos 19, row 1, col 3).
# Ctrl+Left: skip "bar" -> pos 16, row 0, col 20 (pending)
# Ctrl+Right: skip "bar" -> pos 19, row 1, col 3
# Ctrl+Left: skip "bar" -> pos 16, row 0, col 20 (pending)
# Expected: VT cursor at (0, 19) (0-indexed, = col 20 1-indexed)

{
    my $input = 'hello world foo bar';
    my $cursor_pos = length($input);
    my $prompt = '> ';

    my ($rl, $vt) = setup_rl($input, $cursor_pos);

    # Ctrl+Left: move word left
    do_move($rl, $vt, 'move_word_backward', \$input, \$cursor_pos, $prompt);
    is($cursor_pos, 16, "ctrl+left from pos 19 -> cp 16 (start of 'bar')");

    # Ctrl+Right: move word right
    do_move($rl, $vt, 'move_word_forward', \$input, \$cursor_pos, $prompt);
    is($cursor_pos, 19, "ctrl+right from pos 16 -> cp 19 (end of 'bar')");

    # Ctrl+Left again
    do_move($rl, $vt, 'move_word_backward', \$input, \$cursor_pos, $prompt);
    is($cursor_pos, 16, "ctrl+left from pos 19 -> cp 16 (round-trip preserves pos)");

    # Check VT cursor position (0-indexed)
    my ($row, $col) = $vt->cursor();
    # cp=16 maps to (0, 19) 1-indexed = (0, 18) 0-indexed
    # (The 'b' of "bar" is at col 19 1-indexed, cursor before 'b' is at col 19 1-indexed)
    is($row, 0, "vt cursor row 0 after round-trip");
    is($col, 18, "vt cursor col 18 (0-indexed = col 19 1-indexed) after round-trip");
}

# --- Test 2: Alt+Left/Right word movement ---
{
    my $input = 'hello world foo bar';
    my $cursor_pos = length($input);
    my $prompt = '> ';

    my ($rl, $vt) = setup_rl($input, $cursor_pos);

    # Alt+Left (ESC b) = move_word_backward
    do_move($rl, $vt, 'move_word_backward', \$input, \$cursor_pos, $prompt);
    is($cursor_pos, 16, "alt+left from pos 19 -> cp 16");

    # Alt+Right (ESC f) = move_word_forward
    do_move($rl, $vt, 'move_word_forward', \$input, \$cursor_pos, $prompt);
    is($cursor_pos, 19, "alt+right from pos 16 -> cp 19");
}

done_testing();