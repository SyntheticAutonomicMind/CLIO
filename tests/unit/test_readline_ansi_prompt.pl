#!/usr/bin/perl
# Integration test for ReadLine with ANSI-colored prompts.
#
# The prompt produced by Chat.pm::_build_prompt() wraps every segment in
# colorize() (SGR escape sequences). _emit_text() must strip those ANSI
# bytes from cursor tracking while still printing them to the terminal.
#
# Without the fix, _emit_text counts ANSI escape bytes as visible columns,
# inflating last_cursor_col by the ANSI byte count. This corrupts cursor
# positioning for any operation that uses last_cursor_* as a source-of-truth:
#
#   - Arrow-key navigation after paste: cursor drifts, characters land
#     at column 0 instead of the correct position.
#   - Backspace after paste across wrap: cursor tracking is off by the
#     ANSI byte count, causing row jumps.
#   - Shift+arrow + type: insertion appears at the wrong position.
#
# Strategy: same virtual-terminal approach as test_readline_wrap_integration.pl,
# but with an ANSI-colored prompt.

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
    *CLIO::Compat::Terminal::ReadKey = sub {
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

# --- VirtualTerminal: 2-D buffer that processes escape sequences ---

package VirtualTerminal;

sub new {
    my ($class, %opts) = @_;
    return bless {
        cols => $opts{cols} || 20,
        rows => $opts{rows} || 24,
        row => 0,
        col => 0,
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
                    my $n = ($param eq '' ? 1 : $param) + 0;
                    $n = 1 if $n == 0;
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{col} -= $n;
                    $self->{col} = 0 if $self->{col} < 0;
                } elsif ($cmd eq 'A') {
                    my $n = ($param eq '' ? 1 : $param) + 0;
                    $n = 1 if $n == 0;
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
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
                    $self->{row} = 0; $self->{col} = 0; $self->{pending} = 0;
                }
                $i = $j + 1;
            } else {
                $i++;
            }
        } elsif ($ch eq "\r") {
            $self->{col} = 0; $self->{pending} = 0;
            $i++;
        } elsif ($ch eq "\n") {
            $self->{row}++;
            $i++;
        } elsif ($ch eq "\b") {
            if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
            $self->{col}--;
            $self->{col} = 0 if $self->{col} < 0;
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
            my $rl = CLIO::Core::ReadLine->new(prompt => $args{prompt} || '> ');
            my $line = $rl->readline($args{prompt} || undef);
            alarm 0;
        };
        exit(0);
    }

    my $waited = 0;
    while ($waited < 3.5) {
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

    my $vt = VirtualTerminal->new(cols => $args{cols} || 20, rows => $args{rows} || 24);
    $vt->feed($buf);

    return ($vt, $buf);
}

use Test::More tests => 9;

# ANSI-colored prompt: visible width 2 ("> "), ANSI bytes = 17 across
# multiple colorize() calls. Each segment wrapped in SGR codes.
# [\e[36m>\e[0m ] -> > (cyan) + space. Visible: "> " (2 chars).
# This mimics what _build_prompt produces via colorize().
my $ansi_prompt = "\e[36m>\e[0m ";
my $ansi_bytes = length($ansi_prompt) - 2;  # 2 = visible width of "> "
ok($ansi_bytes > 0, "ANSI prompt has $ansi_bytes invisible bytes that must not count as cursor advance");

# Verify _emit_text correctly tracks visible width with ANSI prompt
{
    no warnings 'redefine';
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (80, 24) };
    require CLIO::Core::ReadLine;

    my $rl = CLIO::Core::ReadLine->new(prompt => '> ');
    $rl->{last_cursor_row} = 0;
    $rl->{last_cursor_col} = 1;
    $rl->{last_cursor_disp} = 0;
    $rl->{pending_wrap} = 0;
    $rl->{_prompt_disp_cache} = undef;
    $rl->{_term_width_cache} = undef;

    # Suppress terminal output
    open(my $dn, ">", "/dev/null");
    my $old = select($dn);
    $rl->_emit_text($ansi_prompt);
    select($old);
    close($dn);

    is($rl->{last_cursor_col}, 3, "_emit_text: cursor at col 3 after 2-visible-char ANSI prompt");
    is($rl->{last_cursor_disp}, 2, "_emit_text: disp=2 after ANSI prompt (ANSI bytes not counted)");
    is($rl->{pending_wrap}, 0, "_emit_text: no pending wrap after short ANSI prompt");
    ok($rl->_get_prompt_disp($ansi_prompt) == 2, "_get_prompt_disp: strips ANSI, returns 2");
}

# Scenario 1: paste that wraps, arrow-left twice, insert X, enter
# 20-col terminal, 2-visible-char prompt. Paste 25 chars -> wraps.
# Left x2 -> cp=23. Insert X between 'w' and 'x'.
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("abcdefghijklmnopqrstuvwxy"));  # 25 chars
    push_input(0x1b, ord('['), ord('D'));                       # left arrow (cp 24)
    push_input(0x1b, ord('['), ord('D'));                       # left arrow (cp 23)
    push_input(ord('X'));                                       # insert X at cp 23
    push_input(0x0a);                                           # enter

    my ($vt, $bytes) = run_scenario(prompt => $ansi_prompt, cols => 20);
    my @rows = split /\n/, $vt->render, -1;

    # Row 0: "> abcdefghijklmnopqr" (prompt 2 + 18 chars = 20)
    is(substr($rows[0], 0, 20), '> abcdefghijklmnopqr',
       "ansi-scenario1 row0: prompt + 18 chars, no ANSI bleed");
    # Row 1: chars 18-25 of "abcdefghijklmnopqrstuvwXxy" = s,t,u,v,w,X,x,y
    # Wait: insert at cp=23 (before x at index 23). Original chars: a(0)..w(22), x(23), y(24).
    # After insert X at 23: a(0)...w(22), X(23), x(24), y(25).
    # Row 1 (chars 18-25): s(18) t(19) u(20) v(21) w(22) X(23) x(24) y(25) = "stuvwXxy"
    is(substr($rows[1], 0, 8), 'stuvwXxy',
       "ansi-scenario1 row1: X inserted between w and x at correct position");
}

# Scenario 2: paste content that wraps to row 2, then backspace
# (delete at end across wrap boundary). Without the fix, the inflated
# last_cursor_col causes the wrong row calculation and cursor jumps.
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("abcdefghijklmnopqrstuvwxyz"));  # 26 chars
    push_input(0x7f);  # backspace - delete 'z'
    push_input(0x0a);  # enter

    my ($vt, $bytes) = run_scenario(prompt => $ansi_prompt, cols => 20);
    my @rows = split /\n/, $vt->render, -1;

    # After prompt(2) + 25 chars = 27. Row 0: 20 (prompt 2 + 18 chars a-r).
    # Row 1: 7 chars (s-y, since z was deleted).
    # Without fix: cursor tracking inflated by 9 ANSI bytes, causing the
    # backspace to compute wrong rows, corrupting the screen.
    is(substr($rows[0], 0, 20), '> abcdefghijklmnopqr',
       "ansi-scenario2 row0: paste-wrap + backspace preserves row 0");
    is(substr($rows[1], 0, 7), 'stuvwxy',
       "ansi-scenario2 row1: paste-wrap + backspace leaves 'stuvwxy' (z deleted)");
}
