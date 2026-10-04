#!/usr/bin/perl
# Integration tests for ReadLine line-editing commands and the
# insert fast-path scroll bug fix.
#
# Covers:
#   1. Insert fast-path scroll bug: when typing past the terminal's
#      bottom edge causes autoscroll, display_lines and
#      last_cursor_input_row must be computed from content width,
#      not from the clamped screen row.
#
#   2. Standard readline key bindings:
#      - Ctrl-L  (12): clear screen + redraw
#      - Ctrl-B  ( 2): move backward one character
#      - Ctrl-F  ( 6): move forward one character
#      - Ctrl-T  (20): transpose characters
#      - Ctrl-Y  (25): yank from kill ring
#      - Alt+Y   (\ey): yank-pop (cycle kill ring)
#      - Ctrl-K / Ctrl-U / Ctrl-W accumulate into a single kill-ring
#        entry when consecutive (bash behavior).

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    no warnings 'redefine', 'prototype';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (20, 5) };
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

# ---- VirtualTerminal with scroll and clear-screen support ----

package VirtualTerminal;

sub new {
    my ($class, %opts) = @_;
    return bless {
        cols   => $opts{cols} || 20,
        rows   => $opts{rows} || 5,
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
                $j++ while $j < length($bytes) && substr($bytes, $j, 1) =~ /[0-9;?]/;
                my $param = substr($bytes, $i + 2, $j - $i - 2);
                my $cmd = substr($bytes, $j, 1);
                $self->csi($param, $cmd);
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
            $self->scroll_check();
            $i++;
        } elsif ($ch eq "\b") {
            if ($self->{pending}) { $self->{row}--; $self->{col} = $self->{cols} - 1; $self->{pending} = 0 }
            $self->{col}--;
            $self->{col} = 0 if $self->{col} < 0;
            $i++;
        } else {
            if ($self->{pending}) {
                $self->{pending} = 0;
                $self->{row}++;
                $self->{col} = 0;
                $self->scroll_check();
            }
            $self->putch($ch);
            $i++;
        }
    }
}

sub csi {
    my ($self, $param, $cmd) = @_;
    if ($cmd eq 'C') {
        my $n = ($param eq '' ? 1 : $param) + 0;
        $n = 1 if $n == 0;
        if ($self->{pending}) { $self->{row}++; $self->{col} = 0; $self->{pending} = 0; $self->scroll_check(); }
        $self->{col} += $n;
        $self->{col} = $self->{cols} - 1 if $self->{col} >= $self->{cols};
    } elsif ($cmd eq 'D') {
        my $n = ($param eq '' ? 1 : $param) + 0;
        $n = 1 if $n == 0;
        if ($self->{pending}) { $self->{pending} = 0; }
        $self->{col} -= $n;
        $self->{col} = 0 if $self->{col} < 0;
    } elsif ($cmd eq 'A') {
        my $n = ($param eq '' ? 1 : $param) + 0;
        $n = 1 if $n == 0;
        if ($self->{pending}) { $self->{pending} = 0; }
        $self->{row} -= $n;
        $self->{row} = 0 if $self->{row} < 0;
    } elsif ($cmd eq 'B') {
        my $n = ($param eq '' ? 1 : $param) + 0;
        $n = 1 if $n == 0;
        if ($self->{pending}) {
            $self->{pending} = 0;
            $self->{row}++;
            $self->{col} = 0;
        }
        $self->{row} += $n;
        $self->scroll_check();
    } elsif ($cmd eq 'J') {
        my $p = ($param eq '' ? 0 : $param) + 0;
        if ($p == 0) {
            for my $r ($self->{row} .. $self->{rows} - 1) {
                my $start = ($r == $self->{row}) ? $self->{col} : 0;
                for my $c ($start .. $self->{cols} - 1) {
                    delete $self->{buffer}[$r][$c];
                }
            }
        } elsif ($p == 2) {
            $self->{buffer} = [];
            $self->{row} = 0;
            $self->{col} = 0;
            $self->{pending} = 0;
        }
    } elsif ($cmd eq 'H') {
        $self->{row} = 0;
        $self->{col} = 0;
        $self->{pending} = 0;
    }
}

sub putch {
    my ($self, $ch) = @_;
    $self->{buffer}[$self->{row}][$self->{col}] = $ch;
    $self->{col}++;
    if ($self->{col} >= $self->{cols}) {
        $self->{pending} = 1;
    }
}

sub scroll_check {
    my ($self) = @_;
    while ($self->{row} >= $self->{rows}) {
        shift @{$self->{buffer}};
        push @{$self->{buffer}}, [];
        $self->{row}--;
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
            $rl->{_term_size_cache} = [$args{cols} || 20, $args{rows} || 5];
            $rl->{_term_size_time} = time();
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

    my $vt = VirtualTerminal->new(cols => $args{cols} || 20, rows => $args{rows} || 5);
    $vt->feed($buf);

    return ($vt, $buf);
}

# Count cursor-up escape sequences of the form \e[NA\e[J (redraw_line
# clear-and-redraw pattern) and return the total N.
sub count_redraw_cursor_up {
    my ($bytes) = @_;
    my $total = 0;
    while ($bytes =~ /\e\[(\d*)A\e\[J/g) {
        my $n = $1; $n = 1 if $n eq '';
        $total += $n;
    }
    return $total;
}

sub count_clear_screen {
    my ($bytes) = @_;
    my $count = 0;
    while ($bytes =~ /\e\[2J/g) { $count++ }
    return $count;
}

use Test::More tests => 22;

# ============================================================
# Issue 1: Insert fast-path scroll bug
#
# Terminal: 20 cols x 5 rows. Prompt: "> " (2 cols).
# 2 + 20*4 + 1 = 84... Let's compute for 100 chars:
#   total_disp = 2 + 100 = 102
#   _compute_display_lines(102) = int(101/20) + 1 + 0 = 5 + 1 = 6
#   So 6 rows of content, but terminal only has 5 rows. Scroll occurs.
#
# With the bug: display_lines = max_row + 1 = 5 (clamped), last_cursor_input_row = 4
# With the fix: display_lines = 6, last_cursor_input_row = 5
#
# When Ctrl-K (kill to end) triggers redraw_line, rows_to_top differs:
#   Bug:  4  (rows_to_top = last_cursor_input_row = 4)
#   Fix:  5  (rows_to_top = last_cursor_input_row = 5)
#
# We detect this by counting \e[NA\e[J patterns (the redraw_line clear pattern)
# and summing N.
# ============================================================

# Test: scroll during insert, then Ctrl-K triggers redraw_line
# The cursor-up count distinguishes bug (4) from fix (5).
{
    @KEY_QUEUE = ();
    push_input(input_chars_for('a' x 100));  # 100 chars -> 6 rows, triggers scroll
    push_input(0x0b);  # Ctrl-K: kill to end (input becomes empty)
    push_input(0x0a);  # Enter

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);

    # With the fix, display_lines = 6, last_cursor_input_row = 5.
    # redraw_line moves up 5 rows: \e[5A\e[J
    # With the bug, it would move up only 4: \e[4A\e[J
    my $up_count = count_redraw_cursor_up($bytes);
    is($up_count, 5,
       "scroll-bug: redraw_line moves up 5 rows after scroll+Ctrl-K (got $up_count)");
}

# Test: scroll during insert, then fast-path backspace (no corruption)
{
    @KEY_QUEUE = ();
    push_input(input_chars_for('a' x 101));  # 101 chars, exceeds terminal
    push_input(0x7f);  # Backspace (fast-path: deletes last char 'a')
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    # No stale characters — all visible content should be 'a' or spaces.
    # The 'a' at position 101 was deleted; no garbage should appear.
    my $all_clean = 1;
    for my $r (0 .. 4) {
        my $row = $rows[$r];
        $row =~ s/^> //;  # strip prompt from first row
        if ($row =~ /[^a ]/) {
            $all_clean = 0;
        }
    }
    ok($all_clean,
       "scroll-bug: no stale characters after scroll+backspace");
}

# Test: scroll during insert, then Ctrl-L (clear screen)
{
    @KEY_QUEUE = ();
    push_input(input_chars_for('a' x 100));  # 100 chars, scrolls
    push_input(0x0c);  # Ctrl-L: clear screen + redraw
    push_input(0x0a);  # Enter

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);

    my $clear_count = count_clear_screen($bytes);
    is($clear_count, 1,
       "scroll-bug+Ctrl-L: emits exactly 1 clear-screen escape");
}

# ============================================================
# Issue 2: Standard readline line-editing commands
# ============================================================

# Test: Ctrl-F moves forward one character
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("hello"));
    push_input(0x01);  # Ctrl-A -> pos 0
    push_input(0x06);  # Ctrl-F -> pos 1
    push_input(0x06);  # Ctrl-F -> pos 2
    push_input(ord('X'));
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    # "heXllo" — X inserted at position 2
    is(substr($rows[0], 0, 8), '> heXllo',
       "Ctrl-F: X inserted at correct position");
}

# Test: Ctrl-B moves backward one character
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("hello"));
    push_input(0x01);        # Ctrl-A -> pos 0
    push_input(0x06, 0x06);  # Ctrl-F x2 -> pos 2
    push_input(0x02);        # Ctrl-B -> pos 1
    push_input(ord('X'));
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    # "hXello" — X inserted at position 1
    is(substr($rows[0], 0, 8), '> hXello',
       "Ctrl-B: moves backward correctly before insert");
}

# Test: Ctrl-T at end of line (swap last two chars)
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("abc"));
    push_input(0x14);  # Ctrl-T
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 5), '> acb',
       "Ctrl-T: transpose last two chars at end of line");
}

# Test: Ctrl-T mid-line (swap char before and after cursor)
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("abc"));
    push_input(0x01);  # Ctrl-A -> pos 0
    push_input(0x06);  # Ctrl-F -> pos 1
    # Cursor at 1, between 'a' and 'b'. Swap -> "bac", cursor at 2
    push_input(0x14);  # Ctrl-T
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 5), '> bac',
       "Ctrl-T: transpose mid-line (a|b -> bac)");
}

# Test: Ctrl-K saves to kill ring, Ctrl-Y yanks it back
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("hello world"));
    push_input(0x01);  # Ctrl-A -> pos 0
    push_input(0x0b);  # Ctrl-K -> kills "hello world"
    push_input(0x19);  # Ctrl-Y -> yanks "hello world"
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 13), '> hello world',
       "Ctrl-K/Ctrl-Y: text killed and yanked back");
}

# Test: Ctrl-U kills entire line (cursor at end), Ctrl-Y yanks it back
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("hello world"));
    # Cursor at end. Ctrl-U kills entire line.
    push_input(0x15);  # Ctrl-U
    push_input(0x19);  # Ctrl-Y
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 13), '> hello world',
       "Ctrl-U/Ctrl-Y: entire line killed and yanked back");
}

# Test: Consecutive kills accumulate (bash behavior)
# Ctrl-W kills "world", then Ctrl-W kills "hello " — both appended
# to the same kill-ring entry. Ctrl-Y yanks the combined text.
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("hello world"));
    push_input(0x17);  # Ctrl-W -> kills "world"
    push_input(0x17);  # Ctrl-W -> kills "hello " (accumulates)
    push_input(0x19);  # Ctrl-Y -> yanks "worldhello "
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 13), '> worldhello ',
       "kill-ring: consecutive Ctrl-W accumulates into single entry");
}

# Test: Non-consecutive kills start new entries
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("abc def"));
    push_input(0x17);       # Ctrl-W -> kills "def", ring=["def"]
    push_input(ord('X'));   # Type X (breaks accumulation)
    push_input(0x17);       # Ctrl-W -> kills "X", ring=["def","X"]
    push_input(0x19);       # Ctrl-Y -> yanks "X" (most recent)
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 7), '> abc X',
       "kill-ring: non-consecutive kills are separate entries");
}

# Test: Alt+Y cycles through kill ring entries
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("hello world"));
    push_input(0x01);  # Ctrl-A -> pos 0
    push_input(0x0b);  # Ctrl-K -> kills "hello world", ring=["hello world"]
    push_input(ord('X'));  # Type X (breaks accumulation)
    push_input(0x17);  # Ctrl-W -> kills "X", ring=["hello world","X"]
    push_input(0x19);  # Ctrl-Y -> yanks "X"
    push_input(0x1b, ord('y'));  # Alt-Y -> replaces "X" with "hello world"
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 13), '> hello world',
       "Alt-Y: yank-pop cycles to older kill-ring entry");
}

# Test: Ctrl-L clears screen with short input
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("hello world"));
    push_input(0x0c);  # Ctrl-L
    push_input(0x0a);  # Enter

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    my $clear_count = count_clear_screen($bytes);
    is($clear_count, 1,
       "Ctrl-L: emits exactly 1 clear-screen escape");

    ok(substr($rows[0], 0, 2) eq '> ',
       "Ctrl-L: prompt on row 0 after clear+redraw");

    is(substr($rows[0], 0, 13), '> hello world',
       "Ctrl-L: input content preserved after clear+redraw");
}

# Test: Ctrl-L on empty input
{
    @KEY_QUEUE = ();
    push_input(0x0c);  # Ctrl-L on empty input
    push_input(0x0a);  # Enter

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);

    my $clear_count = count_clear_screen($bytes);
    is($clear_count, 1,
       "Ctrl-L on empty input: emits clear-screen escape");
}

# Test: Ctrl-Y with empty kill ring (no-op)
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("hello"));
    push_input(0x19);  # Ctrl-Y (nothing to yank)
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 7), '> hello',
       "Ctrl-Y with empty kill ring: no-op, input unchanged");
}

# Test: Ctrl-T at position 0 (no-op)
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("abc"));
    push_input(0x01);  # Ctrl-A -> pos 0
    push_input(0x14);  # Ctrl-T (nothing to transpose)
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 5), '> abc',
       "Ctrl-T at pos 0: no-op");
}

# Test: Ctrl-B at beginning of line (no-op)
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("abc"));
    push_input(0x01);  # Ctrl-A -> pos 0
    push_input(0x02);  # Ctrl-B (already at beginning)
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 5), '> abc',
       "Ctrl-B at beginning: no-op");
}

# Test: Ctrl-F at end of line (no-op)
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("abc"));
    # Cursor already at end (pos 3)
    push_input(0x06);  # Ctrl-F (already at end)
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 5), '> abc',
       "Ctrl-F at end: no-op");
}

# Test: Ctrl-K in the middle kills only to end
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("hello world"));
    # Cursor at end (pos 11). Move back 6 to pos 5 (between 'o' and ' ')
    push_input(0x01);        # Ctrl-A -> pos 0
    push_input(0x06, 0x06);  # Ctrl-F x2 -> pos 2... wait, need pos 5
    # Actually, let's use Left arrow approach: Ctrl-A then Ctrl-F x5
    push_input(0x06, 0x06, 0x06);  # Ctrl-F x3 -> pos 5
    push_input(0x0b);  # Ctrl-K -> kills " world"
    push_input(0x19);  # Ctrl-Y -> yanks " world"
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    # After yank: "hello world" (Ctrl-K killed " world", Ctrl-Y yanked it back)
    is(substr($rows[0], 0, 13), '> hello world',
       "Ctrl-K mid-line: kills only to end, Ctrl-Y restores");
}

# Test: Alt+Y without prior yank (no-op)
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("hello"));
    push_input(0x1b, ord('y'));  # Alt-Y (no prior yank)
    push_input(0x0a);

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    my @rows = split /\n/, $vt->render, -1;

    is(substr($rows[0], 0, 7), '> hello',
       "Alt-Y without yank: no-op, input unchanged");
}
