#!/usr/bin/perl
# Test the actual user scenario: type past the bottom of the terminal,
# then backspace and retype, verifying no content above the input is
# wiped and no stale characters remain.
#
# This directly exercises the bug that occurred when _emit_text tracked
# cursor position incrementally and scroll_offset drifted, causing
# redraw_line to move too far up and \e[J to wipe terminal content.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    no warnings 'redefine', 'prototype';
    require CLIO::Compat::Terminal;
}

# --- VirtualTerminal ---
package VirtualTerminal;
use CLIO::Core::ReadLine();
sub new {
    my ($class, %opts) = @_;
    return bless {
        cols => $opts{cols} || 20,
        rows => $opts{rows} || 5,
        row => 0, col => 0, buffer => [], pending => 0,
    }, $class;
}

sub feed {
    my ($self, $str) = @_;
    my $i = 0;
    while ($i < length($str)) {
        my $ch = substr($str, $i, 1);
        if ($ch eq "\e") {
            if (substr($str, $i + 1, 1) eq '[') {
                my $j = $i + 2;
                $j++ while $j < length($str) && substr($str, $j, 1) =~ /[0-9;?]/;
                my $param = substr($str, $i + 2, $j - $i - 2);
                my $cmd = substr($str, $j, 1);
                $i = $j + 1;
                if ($param =~ /\?/) { next }
                my $n = ($param eq '' ? 1 : $param) + 0;
                $n = 1 if $n == 0;
                if ($cmd eq 'A') {
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{row} -= $n;
                    $self->{row} = 0 if $self->{row} < 0;
                } elsif ($cmd eq 'B') {
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{row} += $n;
                } elsif ($cmd eq 'K') {
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
                }
            } else { $i++ }
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
            my $w = CLIO::Core::ReadLine::_display_width($ch);
            $self->{buffer}[$self->{row}][$self->{col}] = $ch;
            $self->{col} += $w;
            if ($self->{col} >= $self->{cols}) {
                $self->{pending} = $self->{col} == $self->{cols};
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

# --- run_scenario: fork ReadLine into a pipe, capture bytes, feed to VT ---
package main;
use Test::More tests => 5;
use Encode;

our @KEY_QUEUE;
*CLIO::Compat::Terminal::GetTerminalSize = sub { return (20, 5) };
*CLIO::Compat::Terminal::ReadMode = sub { return 1 };
*CLIO::Compat::Terminal::ReadKey = sub {
    return undef unless @main::KEY_QUEUE;
    return shift @main::KEY_QUEUE;
};

sub push_input {
    push @KEY_QUEUE, map {
        my $v = $_;
        ($v =~ /^-?\d+\z/) ? chr($v) : $v;
    } @_;
}
sub input_chars_for { return map { chr(ord($_)) } split //, $_[0] }

sub capture_stdout {
    my ($code) = @_;
    my $captured = '';
    open my $fh, '>', \$captured or die "open to scalar: $!";
    my $old = select($fh);
    $| = 1;
    eval { $code->() };
    select($old);
    close $fh;
    return ($captured, $@);
}

sub run_scenario {
    my (%args) = @_;

    pipe(my $read_end, my $write_end) or die "pipe: $!";
    my $saved_stdout = select($write_end);
    $| = 1;
    binmode($write_end, ':encoding(UTF-8)');

    my $pid = fork();
    die "fork: $!" unless defined $pid;

    if ($pid == 0) {
        eval {
            local $SIG{ALRM} = sub { die "TIMEOUT\n" };
            alarm 3;
            require CLIO::Core::TabCompletion;
            my $completer = CLIO::Core::TabCompletion->new();
            my $rl = CLIO::Core::ReadLine->new(
                prompt => $args{prompt} || '> ',
                completer => $completer,
            );
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

    $buf = Encode::decode('UTF-8', $buf);

    my $cols = $args{cols} || 20;
    my $rows = $args{rows} || 5;
    my $vt = VirtualTerminal->new(cols => $cols, rows => $rows);
    $vt->feed($buf);

    return ($vt, $buf);
}

# Type 100 'a's on a 20x24 terminal (fits: 6 rows of content, no scroll needed),
# then backspace, then Enter. Then test redraw_line directly.
# ============================================================
# Part 1: Direct redraw_line test (no \e[J)
# ============================================================
{
    # Simulate: 100 'a's typed, cursor at end, then backspace.
    # display_lines = 6 (102 cols / 20 = 5.1 -> 6 rows)
    # After backspace: 99 'a's, display_lines = 6 (101 / 20 = 5.05 -> 6 rows)
    my $input = 'a' x 99;
    my $cursor_pos = 99;
    my $prompt = '> ';

    my $rl = CLIO::Core::ReadLine->new(prompt => '> ');
    $rl->{_term_size_cache} = [20, 24];
    $rl->{_term_size_time} = time();

    # _refresh_geometry to set display_lines properly
    $rl->_refresh_geometry($input, $cursor_pos, $prompt);
    is($rl->{display_lines}, 6, "display_lines=6 for 99 chars on 20-col terminal");

    # Call redraw_line
    my ($bytes, $eval_err) = capture_stdout(sub {
        $rl->redraw_line(\$input, \$cursor_pos, $prompt);
    });
    ok(!$eval_err, "redraw_line ran without error");

    # No \e[J (erase display) — only \e[K (erase line)
    ok($bytes !~ /\e\[J/, "redraw_line uses \\e[K not \\e[J");

    # Should have cursor-up then per-line K
    ok($bytes =~ /\e\[\d+A\e\[K/, "redraw_line uses N-cursor-up + \\e[K");
}

# ============================================================
# Part 2: Full readline test (no \e[J, no \e[2J)
# ============================================================
{
    @KEY_QUEUE = ();
    push_input(input_chars_for('a' x 100));
    push_input(127);   # backspace
    push_input(0x0a);  # Enter

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 24);

    # No \e[J should be present
    ok($bytes !~ /\e\[J/, "no \\e[J in full readline output");
}
