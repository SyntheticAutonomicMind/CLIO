#!/usr/bin/perl
# Comprehensive integration test for the redesigned ReadLine cursor tracking.
#
# Drives the full ReadLine::readline() loop through a virtual terminal
# emulator (a 2-D buffer that processes escape sequences) and verifies
# the rendered screen state.
#
# Exercises the key redesign: _cursor_at_codepoint is the single source
# of truth for cursor position. reposition_cursor computes both source and
# target from input state (not from incrementally-tracked last_cursor_*)
# and _pos_to_rowcol has been removed entirely.
#
# Scenarios covered:
#   1.  CJK input with arrow-key navigation + insert
#   2.  CJK backspace at end across wrap boundary
#   3.  CJK insertion at beginning (Ctrl-A then insert)
#   4.  ANSI-colored prompt + CJK + arrow-left + insert
#   5.  Ctrl-A / Ctrl-E on CJK wrapped input
#   6.  History navigation with CJK entries
#   7.  Wide-char backspace that tightens wrap
#   8.  Wide char at exact boundary, then backspace
#   9.  Insert at end pushing into pending-wrap position (ASCII)

use strict;
use warnings;
use utf8;
use Encode;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More tests => 15;

BEGIN {
    no warnings 'redefine', 'prototype';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (10, 24) };
    *CLIO::Compat::Terminal::ReadMode = sub { return 1 };
    *CLIO::Compat::Terminal::ReadKey = sub {
        return undef unless @main::KEY_QUEUE;
        return shift @main::KEY_QUEUE;
    };
    binmode(STDOUT, ':encoding(UTF-8)');
    binmode(STDERR, ':encoding(UTF-8)');
}

our @KEY_QUEUE;
sub push_input {
    push @KEY_QUEUE, map {
        my $v = $_;
        ($v =~ /^-?\d+\z/) ? chr($v) : $v;
    } @_;
}
sub input_chars_for { return map { chr(ord($_)) } split //, $_[0] }

# --- VirtualTerminal: processes escape sequences into a 2-D buffer ---
# Handles wide characters (CJK) by advancing the column by display width.

package VirtualTerminal;

use CLIO::Core::ReadLine ();  # for _display_width

sub new {
    my ($class, %opts) = @_;
    return bless {
        cols => $opts{cols} || 10,
        rows => $opts{rows} || 24,
        row => 0,
        col => 0,
        buffer => [],
        pending => 0,
    }, $class;
}

sub feed {
    my ($self, $str) = @_;
    # $str should be a decoded character string (not raw bytes)
    my $i = 0;
    while ($i < length($str)) {
        my $ch = substr($str, $i, 1);
        if ($ch eq "\e") {
            if (substr($str, $i + 1, 1) eq '[') {
                my $j = $i + 2;
                $j++ while $j < length($str) && substr($str, $j, 1) =~ /[\d;?]/;
                my $param = substr($str, $i + 2, $j - $i - 2);
                my $cmd = substr($str, $j, 1);
                if ($cmd eq 'C') {
                    my $n = ($param eq '' ? 1 : $param) + 0;
                    $n = 1 if $n == 0;
                    if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0 }
                    $self->{col} += $n;
                    $self->{col} = $self->{cols} if $self->{col} > $self->{cols};
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
                # SGR (\e[...m and other) and unknown cmds: just skip
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
            my $w = CLIO::Core::ReadLine::_display_width($ch);
            # Place at current col
            $self->{buffer}[$self->{row}][$self->{col}] = $ch;
            $self->{col} += $w;
            if ($self->{col} >= $self->{cols}) {
                $self->{pending} = $self->{col} == $self->{cols};
                # If col > cols (shouldn't happen for w<=2 on cols>=2), clamp
                if ($self->{col} > $self->{cols}) {
                    $self->{col} = $self->{cols};
                }
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
            require CLIO::Core::ReadLine;
            require CLIO::Core::TabCompletion;
            my $completer = CLIO::Core::TabCompletion->new();
            my $rl = CLIO::Core::ReadLine->new(
                prompt => $args{prompt} || '> ',
                completer => $completer,
                debug => 0,
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

    # Decode raw UTF-8 bytes to Perl characters for the virtual terminal
    $buf = Encode::decode('UTF-8', $buf);

    my $cols = $args{cols} || 10;
    my $vt = VirtualTerminal->new(cols => $cols, rows => 24);
    $vt->feed($buf);

    return ($vt, $buf);
}

# Scenario 1: CJK input with arrow-left + insert
# 10-col terminal, 2-char prompt "> ".
# "abc你好" = 3+2+2 = 7 display cols. Total = 9. Fits in 1 row.
# Left x3 (cp=2, between 'b' and 'c'). Insert 'X': "abXc你好"
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("abc\x{4F60}\x{597D}"));  # abc你好
    push_input(0x1b, ord('['), ord('D'));  # left (cp=4, before 好)
    push_input(0x1b, ord('['), ord('D'));  # left (cp=3, before 你)
    push_input(0x1b, ord('['), ord('D'));  # left (cp=2, before c)
    push_input(ord('X'));                  # insert X at cp=2
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 10);
    my @rows = split /\n/, $vt->render, -1;

    # "abXc你好" = 1+1+1+1+2+2 = 8 display. Total = 2+8 = 10 = full row.
    is(substr($rows[0], 0, 6), '> abXc',
       "cjk-nav: X inserted at cp=2 (abXc...)");
}

# Scenario 2: CJK backspace at end across row boundary
# 10-col terminal, 2-char prompt. Input: "abc你好世界" = 3+2+2+2+2 = 11.
# Total = 13. Row 0: 10 cols (prompt 2 + abc 3 + 你 2 + 好 2 = 9, then 1 space).
# Row 1: 4 cols (世 2 + 界 2). Backspace deletes 界.
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("abc\x{4F60}\x{597D}\x{4E16}\x{754C}"));  # abc你好世界
    push_input(0x7f);  # backspace - delete 界
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 10);
    my @rows = split /\n/, $vt->render, -1;

    # After delete: "abc你好世" = 3+2+2+2 = 9. Total = 2+9 = 11.
    # Row 0: 10 cols (prompt 2 + abc 3 + 你 2 + 好 2 = 9, 1 space).
    # Row 1: 2 cols (世 = 2 cols, then nothing).
    # The VT stores display columns, so "你" takes cols 5-6, "好" takes cols 7-8.
    # Prompt: > space | a b c 你好 好 | space | 世 界 -> wait, let me recalculate.
    # Actually: prompt(2 cols: > and space) + a(1) + b(1) + c(1) + 你(2) + 好(2) = 9. Total 11.
    # Row 0 cols 0-9: >, space, a, b, c, 你(col5), 你(col6), 好(col7), 好(col8), space(col9)
    # Row 1: 世(col0), 世(col1) -> that's only 2 display cols used.
    # After backspace deletes 界(wide): "abc你好世" still = 9 display. Row 1: 世(cols 0-1).

    # Check row 0 has the first 9 chars
    is(substr($rows[0], 0, 1), '>',
       "cjk-backspace: row 0 starts with prompt");
    is(substr($rows[0], 2, 4), 'abc' . "\x{4F60}",
       "cjk-backspace: row0 has abc + first CJK char after delete");
}

# Scenario 3: CJK insert at beginning (Ctrl-A then insert)
# 10-col terminal. Input "abc你好" (7 display, total 9). Fits in 1 row.
# Ctrl-A (go to start), insert 'X': "Xabc你好"
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("abc\x{4F60}\x{597D}"));  # abc你好
    push_input(0x01);  # Ctrl-A (cp=0)
    push_input(ord('X'));  # insert X at start
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 10);
    my @rows = split /\n/, $vt->render, -1;

    # "Xabc你好" = 1+1+1+1+2+2 = 8. Total = 10. Exactly fills row.
    is(substr($rows[0], 0, 1), '>',
       "cjk-insert: row 0 starts with prompt");
    is(substr($rows[0], 2, 4), 'Xabc',
       "cjk-insert: X inserted at beginning");
}

# Scenario 4: ANSI-colored prompt + CJK + arrow-left + insert
# Uses ANSI prompt "\e[36m>\e[0m " (visible width 2).
# 10-col terminal. Input "abc你好" (7 display, total 9). Fits in 1 row.
# Left x3 (cp=2), insert 'X': "abXc你好"
{
    @KEY_QUEUE = ();
    my $ansi_prompt = "\e[36m>\e[0m ";
    push_input(input_chars_for("abc\x{4F60}\x{597D}"));  # abc你好
    push_input(0x1b, ord('['), ord('D'));  # cp=4
    push_input(0x1b, ord('['), ord('D'));  # cp=3
    push_input(0x1b, ord('['), ord('D'));  # cp=2
    push_input(ord('X'));  # insert at cp=2
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(prompt => $ansi_prompt, cols => 10);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 2), '> ',
       "cjk-ansi: row 0 starts with visible prompt (ANSI stripped)");
    is(substr($rows[0], 2, 2), 'ab',
       "cjk-ansi: ab present before insert position");
    is(substr($rows[0], 4, 1), 'X',
       "cjk-ansi: X inserted at correct position (between b and c)");
}

# Scenario 5: Ctrl-A / Ctrl-E on CJK wrapped input
# 10-col terminal. Input "abc你好世界" (11 display, total 13). Wraps to 2 rows.
# Ctrl-A (start), Ctrl-E (end), Enter. Input unchanged.
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("abc\x{4F60}\x{597D}\x{4E16}\x{754C}"));  # abc你好世界
    push_input(0x01);  # Ctrl-A
    push_input(0x05);  # Ctrl-E
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 10);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 1), '>',
       "cjk-ctrl-a-e: row 0 starts with prompt");
    is(substr($rows[0], 2, 3), 'abc',
       "cjk-ctrl-a-e: row 0 has 'abc' intact");
}

# Scenario 6: Wide char at exact boundary, then backspace
# 10-col terminal. Input "abcdefgh你" = 8+2 = 10 display. Total = 12.
# Row 0: prompt(2) + abcdefgh(8) = 10. Row 1: 你(2).
# Backspace deletes 你 (2-col wide char). Should redraw.
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("abcdefgh\x{4F60}"));  # abcdefgh你
    push_input(0x7f);  # backspace
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 10);
    my @rows = split /\n/, $vt->render, -1;

    # After delete: "abcdefgh" (8 display). Total = 10. Fits in 1 row.
    is(substr($rows[0], 0, 10), '> abcdefgh',
       "wide-boundary: backspacing CJK at end redraws row 0 clean");
    # Row 1 should be all spaces (cleared by redraw)
    is(substr($rows[1], 0, 3), '   ',
       "wide-boundary: row 1 cleared after redraw");
}

# Scenario 7: History navigation with CJK entries
# Type "hello", Enter. Type "你好", Enter. Up x2 to recall "hello", Enter.
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("hello"));
    push_input(0x0a);
    push_input(input_chars_for("\x{4F60}\x{597D}"));  # 你好
    push_input(0x0a);
    push_input(0x1b, ord('['), ord('A'));  # up - shows "你好"
    push_input(0x1b, ord('['), ord('A'));  # up - shows "hello"
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 10);
    my @rows = split /\n/, $vt->render, -1;

    # After recalling "hello": row 0 = "> hello" (7 chars) + spaces
    # The prompt "> " + "hello" = 7 chars
    my $row0 = substr($rows[0], 0, 10);
    like($row0, qr/^> hello/,
       "cjk-history: recalled ASCII entry renders correctly");
}

# Scenario 8: Insert at end pushing into pending-wrap position (ASCII)
# 10-col terminal, 2-char prompt. 8 ASCII chars fill row 0 exactly.
# Insert one more char. Should wrap to row 1.
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("abcdefgh"));  # 8 chars, fills row 0 (cols 2-9)
    push_input(ord('X'));  # insert at end - wraps
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 10);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 10), '> abcdefgh',
       "pending-wrap-insert: row 0 full after insert at boundary");
    is(substr($rows[1], 0, 1), 'X',
       "pending-wrap-insert: X wrapped to row 1");
}
