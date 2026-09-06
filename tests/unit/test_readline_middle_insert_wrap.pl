#!/usr/bin/perl
# Reproduction test for the readline wrap-boundary insert bug.
#
# Bug: When inserting text in the middle of a single-line input that
# pushes content past the terminal's line-wrap boundary, the current
# line is not re-painted. The stale content persists until the next
# insert or delete triggers a full redraw.
#
# Root cause: The insert path calls _redraw_from_cursor (partial redraw
# that only re-emits characters after the cursor) instead of redraw_line
# (full redraw) when the insert crosses a wrap boundary.

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

sub push_input {
    push @KEY_QUEUE, map {
        my $v = $_;
        ($v =~ /^-?\d+\z/) ? chr($v) : $v;
    } @_;
}

sub input_chars_for { return map { chr(ord($_)) } split //, $_[0] }

# ---- VirtualTerminal: 2-D buffer processing ANSI escape sequences ---

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
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{col} += $n;
                    $self->{col} = $self->{cols} - 1 if $self->{col} >= $self->{cols};
                } elsif ($cmd eq 'D') {
                    # Cursor left: the terminal does NOT autowrap on
                    # cursor movement.  If we had a pending wrap (cursor
                    # at col 0 of a new row because the last char filled
                    # col term_width), pressing left simply moves within
                    # the current row — no row change.  But we must clear
                    # pending so subsequent chars don't double-wrap.
                    $self->{pending} = 0;
                    my $n = ($param eq '' ? 1 : $param) + 0;
                    $self->{col} -= $n;
                    if ($self->{col} < 1) {
                        $self->{col} = 1;
                    }
                } elsif ($cmd eq 'A') {
                    # Cursor up: clear pending (we're not wrapping yet).
                    $self->{pending} = 0;
                    my $n = ($param eq '' ? 1 : $param) + 0;
                    $self->{row} -= $n;
                    $self->{row} = 0 if $self->{row} < 0;
                } elsif ($cmd eq 'B') {
                    my $n = ($param eq '' ? 1 : $param) + 0;
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
            $self->{col} = 0;
            $self->{pending} = 0;
            $i++;
        } elsif ($ch eq "\n") {
            if ($self->{pending}) { $self->{pending} = 0 }
            $self->{row}++;
            $self->{col} = 0;
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
        eval {
            local $SIG{ALRM} = sub { die "TIMEOUT\n" };
            alarm 3;

            require CLIO::Core::ReadLine;
            my $rl = CLIO::Core::ReadLine->new(use_vt => 1);
            # Override terminal size
            $rl->{_term_width_cache} = 20;
            $rl->{_term_width_time} = time();

            my $line = $rl->readline('> ');
            print "\nLINE:" . $line . "\n";
            exit 0;
        };
        if ($@) {
            print STDERR "CHILD ERROR: $@";
            exit 1;
        }
        exit 0;
    }

    close($write_end);
    my $buf = '';
    {
        local $/ = \1;
        while (defined(my $chunk = <$read_end>)) {
            $buf .= $chunk;
        }
    }
    close($read_end);
    waitpid($pid, 0);

    my $vt = VirtualTerminal->new(cols => 20, rows => 24);
    $vt->feed($buf);

    my $line = '';
    if ($buf =~ /LINE:(.*)/) {
        $line = $1;
    }

    return ($vt, $buf, $line);
}

# ---- Test scenarios ----

use Test::More tests => 4;

# Scenario A: Insert at the wrap boundary of an already-wrapped input.
# 20 chars on a 20-col terminal (18 input chars per row with "> " prompt).
# Cursor at cp=18 (boundary between row 0 and row 1), insert 'X'.
# After insert: input = "abcdefghijklmnopqrXst"
#   row 0: "> abcdefghijklmnopqr" (18 input chars)
#   row 1: "Xst" + spaces
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for("abcdefghijklmnopqrst"));
    push_input(0x1b, ord('['), ord('D'));  # left -> cp=19
    push_input(0x1b, ord('['), ord('D'));  # left -> cp=18
    push_input(ord('X'));
    push_input(0x0a);

    my ($vt, $bytes, $line) = run_scenario();
    my @rows = split /\n/, $vt->render, -1;

    diag "A line: '$line'";
    is(substr($rows[0], 0, 20), '> abcdefghijklmnopqr',
       "boundary insert A row0: prompt + 18 original chars");
    is(substr($rows[1], 0, 3), 'Xst',
       "boundary insert A row1: 'Xst' (X at start of row 1)");
}

# Scenario B: Single-line input that grows past the boundary via mid-input
# insert.  This is the user's exact scenario.
# 18 chars exactly fills row 0. Move cursor to cp=16, insert 'X'.
# After insert: input = "abcdefghijklmnopXqr" (19 chars, now wrapped)
{
    @main::KEY_QUEUE = ();
    push_input(input_chars_for("abcdefghijklmnopqr"));
    push_input(0x1b, ord('['), ord('D'));  # left -> cp=17
    push_input(0x1b, ord('['), ord('D'));  # left -> cp=16
    push_input(ord('X'));
    push_input(0x0a);

    my ($vt, $bytes, $line) = run_scenario();
    my @rows = split /\n/, $vt->render, -1;

    diag "B line: '$line'";
    # Input after insert: "abcdefghijklmnopXqr" (19 chars)
    # chars 0-17 go on row 0: "abcdefghijklmnopXq"
    # char 18 goes on row 1: "r"
    is(substr($rows[0], 0, 20), '> abcdefghijklmnopXq',
       "single->wrapped B row0: prompt + 18 chars incl X");
    is(substr($rows[1], 0, 4), 'r   ',
       "single->wrapped B row1: 'r' + spaces");
}
