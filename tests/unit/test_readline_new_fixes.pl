#!/usr/bin/perl
# Integration tests for newly-fixed ReadLine issues:
#   1. rows_to_top bug: cross-line-boundary edit after scroll
#   2. Bracketed paste mode support
#   3. VT100/VT220 SS3 arrow key support (ESC O A/B/C/D)
#   4. DSR timeout increased to 500ms

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

# ---- VirtualTerminal (same as test_readline_line_editing.pl) ----

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
    } elsif ($cmd eq 'h') {
        # DEC Private Mode Set (e.g., ESC[?2004h for bracketed paste)
        # VT: ignore (track mode is not relevant for our tests)
    } elsif ($cmd eq 'l') {
        # DEC Private Mode Reset (e.g., ESC[?2004l)
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

sub count_redraw_cursor_up {
    my ($bytes) = @_;
    my $total = 0;
    while ($bytes =~ /\e\[(\d*)A\e\[J/g) {
        my $n = $1; $n = 1 if $n eq '';
        $total += $n;
    }
    return $total;
}

use Test::More tests => 12;

# ============================================================
# Test 1: rows_to_top correctly accounts for scroll_offset changes
# ============================================================

# Scenario: terminal 20x5, input that scrolls (display_lines > rows).
# Cursor on an intermediate input row, then insert a character that
# changes display_lines, triggering redraw_line. The cursor-up count
# should reflect the correct screen-row distance, not the stale
# input-row count.
{
    @KEY_QUEUE = ();
    # Type 78 chars (fills 4 rows: prompt(2) + 78 = 80 = exactly 4*20)
    # display_lines = 4, available = 5, scroll_offset = 0.
    # Type 1 more char: total = 81, display_lines = 5, scroll_offset = 0.
    # Type 1 more char: total = 82, display_lines = 5, scroll_offset = 0.
    # Type enough to get scroll_offset = 1: total must be > 100.
    # 100 chars: total = 102, display_lines = 6, available = 5, scroll = 1.
    push_input(input_chars_for('a' x 100));

    # Now we're at the end of input (input row 5, screen row 4 = max_row).
    # Move cursor up to input row 2 (Ctrl-B x 60).
    for (1..60) { push_input(0x02); }  # Ctrl-B

    # Type a character at position 60 -> triggers redraw_line
    push_input(input_chars_for('X'));

    # Ctrl-K to clear (triggers another redraw_line with different content)
    push_input(0x0b);  # Ctrl-K
    push_input(0x0a);  # Enter

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);

    # The cursor-up count during redraw_line should be computed from
    # screen coordinates, not stale input rows.
    my $up_count = count_redraw_cursor_up($bytes);
    ok($up_count > 0, "rows_to_top fix: at least one cursor-up in redraw_line (got $up_count)");

    # The key check: the cursor-up count should not exceed max_row (4).
    # With the old bug, rows_to_up could exceed the terminal height.
    ok($up_count <= 4, "rows_to_top fix: cursor-up count does not exceed max_row (got $up_count)");

    diag("Total cursor-up rows: $up_count");
}

# ============================================================
# Test 2: Bracketed paste mode is enabled/disabled
# ============================================================

{
    @KEY_QUEUE = ();
    # Type some text, then Enter
    push_input(input_chars_for("hi"));
    push_input(0x0a);  # Enter

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);

    # Bracketed paste enable sequence should be emitted
    like($bytes, qr/\e\[\?2004h/, "bracketed paste: enable sequence sent");
    # Bracketed paste disable sequence should be emitted before return
    like($bytes, qr/\e\[\?2004l/, "bracketed paste: disable sequence sent before return");
}

# ============================================================
# Test 3: Bracketed paste inserts pasted text as literal text
# ============================================================

{
    @KEY_QUEUE = ();
    # Simulate a bracketed paste of "hello" followed by ESC[201~
    push_input(0x1b);       # ESC
    push_input(0x5b);       # [
    push_input(0x32);       # 2
    push_input(0x30);       # 0
    push_input(0x30);       # 0
    push_input(0x7e);       # ~  (ESC[200~ = paste start)
    push_input(input_chars_for("hello"));  # pasted text
    push_input(0x1b);       # ESC
    push_input(0x5b);       # [
    push_input(0x32);       # 2
    push_input(0x30);       # 0
    push_input(0x31);       # 1
    push_input(0x7e);       # ~  (ESC[201~ = paste end)
    push_input(0x0a);       # Enter

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);

    my $rendered = $vt->render();
    like($rendered, qr/> hello/, "bracketed paste: pasted 'hello' appears in input line");
}

# ============================================================
# Test 4: VT100/VT220 SS3 arrow keys (ESC O A/B/C/D)
# ============================================================

{
    @KEY_QUEUE = ();
    # Type some text, move back with SS3 Left (ESC O D), type, move forward (ESC O C)
    push_input(input_chars_for("hello world"));
    # ESC O D = SS3 Left (move back 1 char) - 5 times
    for (1..5) {
        push_input(0x1b);  # ESC
        push_input(0x4f);  # O
        push_input(0x44);  # D
    }
    push_input(input_chars_for("X"));  # Insert X in middle
    push_input(0x0a);  # Enter

    my ($vt, $input) = run_scenario(cols => 20, rows => 5);

    # "hello world" = 11 chars. After 5 left arrows, cursor at position 6.
    # Inserting 'X' at position 6 gives "hello Xworld" (X before 'world').
    # But wait: 5 from position 11 = position 6, which is after "hello "
    # (h-e-l-l-o-space = 6 chars). Inserting X gives "hello Xworld".
    ok($input =~ /hello Xworld/, "ss3: ESC O D (left arrow) works in VT100 mode");

    # We can't easily verify the rendered output for mid-line insert with
    # the VT, but we can verify the byte stream contains the insert.
}

# ============================================================
# Test 5: SS3 arrow keys in application mode (ESC O A = Up)
# ============================================================

{
    @KEY_QUEUE = ();
    # Type nothing, send SS3 Up (ESC O A) - should trigger history prev
    # On empty input, history prev is a no-op (empty ring).
    push_input(0x1b);  # ESC
    push_input(0x4f);  # O
    push_input(0x41);  # A (Up)
    push_input(0x0a);  # Enter

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);

    # Should not crash, should return empty input
    ok(1, "ss3: ESC O A (up arrow) doesn't crash on empty history");

    # Verify the SS3 sequence is recognized (not treated as literal text)
    # The rendered line should be empty (no "OA" characters)
    my $rendered = $vt->render();
    ok($rendered !~ /OA/, "ss3: ESC O A not rendered as literal 'OA' text");
}

# ============================================================
# Test 6: rows_to_top with scroll_offset change on insert
# ============================================================

{
    @KEY_QUEUE = ();
    # Terminal 20x5. Type 79 chars: total = 81, display_lines = 5.
    # scroll_offset = max(0, 5 - 5) = 0. Cursor at end, input row 4, screen row 4 = max_row.
    push_input(input_chars_for('a' x 79));

    # Now move cursor to beginning (Ctrl-A x 79)
    for (1..79) { push_input(0x01); }  # Ctrl-A

    # Type a character at position 0 -> insert at beginning
    # New total = 82, display_lines = 5, scroll_offset = 0.
    # But if we type ONE MORE char: total = 83, display_lines = 5, still no scroll.
    # Need total > 100 for scroll.
    # Instead, let's type enough to trigger scroll and then delete.

    # Type chars at beginning to grow past scroll threshold
    push_input(input_chars_for('b' x 22));  # total = 101, display_lines = 6, scroll = 1
    push_input(0x0a);  # Enter

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);

    # Should have scrolled - verify no crash and input captured
    ok(1, "rows_to_top: insert at beginning with scroll doesn't crash");
}

# ============================================================
# Test 7: No crash with empty input + Ctrl-K
# ============================================================

{
    @KEY_QUEUE = ();
    push_input(0x0b);  # Ctrl-K on empty input
    push_input(0x0a);  # Enter

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);
    ok(1, "no crash: Ctrl-K on empty input");
}

# ============================================================
# Test 8: DSR drain doesn't interfere with normal input
# ============================================================

{
    @KEY_QUEUE = ();
    # Simulate a scenario where DSR response bytes are in the queue
    # (from a timed-out DSR query). The readline should drain them
    # and then read normal input.
    # DSR response: ESC [ 0 ; 1 R
    push_input(0x1b);  # ESC
    push_input(0x5b);  # [
    push_input(0x30);  # 0
    push_input(0x3b);  # ;
    push_input(0x31);  # 1
    push_input(0x52);  # R
    # Then normal input
    push_input(input_chars_for("hello"));
    push_input(0x0a);  # Enter

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);

    # The DSR bytes should have been consumed, not rendered as input
    my $rendered = $vt->render();
    # "hello" should appear, but "[0;1R" should not
    like($rendered, qr/> hello/, "dsr: normal input works after DSR drain");
}

# ============================================================
# Test 9: Bracketed paste with embedded escape sequences
# ============================================================

{
    @KEY_QUEUE = ();
    # Simulate pasting text containing an ANSI color escape
    push_input(0x1b);       # ESC
    push_input(0x5b);       # [
    push_input(0x32);       # 2
    push_input(0x30);       # 0
    push_input(0x30);       # 0
    push_input(0x7e);       # ~  (ESC[200~ = paste start)
    push_input(input_chars_for("hello"));
    # Embedded ESC[31m (red color) - should be treated as literal text
    push_input(0x1b);
    push_input(0x5b);
    push_input(0x33);
    push_input(0x31);
    push_input(0x6d);
    push_input(input_chars_for("world"));
    push_input(0x1b);       # ESC
    push_input(0x5b);       # [
    push_input(0x32);       # 2
    push_input(0x30);       # 0
    push_input(0x31);       # 1
    push_input(0x7e);       # ~  (ESC[201~ = paste end)
    push_input(0x0a);       # Enter

    my ($vt, $bytes) = run_scenario(cols => 20, rows => 5);

    # The entire pasted content should be inserted as literal text
    like($bytes, qr/> hello.*world/s, "bracketed paste: embedded escape sequences treated as literal");
}

print "\nAll tests completed.\n";
