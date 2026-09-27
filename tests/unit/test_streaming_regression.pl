#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test for the streaming-output duplication bug.
#
# Background: an earlier "live mode" experiment printed each raw chunk to the
# terminal immediately and then tried to erase-and-replace it with
# markdown-rendered output using ANSI cursor save/restore + row-count-based
# line clearing.  The row count of the raw text never matched the wrapped
# formatted text, so the erase cleared the wrong number of lines, leaving
# raw text under the formatted text -- producing the doubled "CLIO: CLIO:"
# prefix and doubled content seen in bug reports.
#
# This test pins the behaviour we now rely on: output is post-processed
# (markdown rendered + indented/wrapped) BEFORE it is ever sent to the
# terminal, one complete line at a time.  No raw-immediate print, no cursor
# dance, no duplication.

use strict;
use warnings;
use utf8;
use Test::More;
use lib '../../lib';

use CLIO::UI::StreamingController;

# Fence characters, built without literal backticks so the test source is
# unambiguous.
my $FB = chr(96) x 3;

# ---- Mock pager ----
my $pager = bless { line_count => 0, page => [] }, 'MockPager';
sub MockPager::enable           { }
sub MockPager::should_trigger   { 0 }
sub MockPager::track_line       { push @{$_[0]{page}}, $_[1]; $_[0]{line_count}++ }
sub MockPager::increment_lines  { $_[0]{line_count} += ($_[1] // 1) }
sub MockPager::reset_page       { }

# ---- Mock UI ----
# render_markdown converts **x** -> [B]x[/B] so a raw-marker leak is visible.
my $mock_ui = bless {
    enable_markdown             => 1,
    non_interactive             => 0,
    stop_streaming              => 0,
    _prepare_for_next_iteration => 0,
    _need_agent_prefix          => 0,
    pager                       => $pager,
    first_line_printed          => 0,
}, 'MockUI';

sub MockUI::render_markdown {
    my ($self, $text) = @_;
    # Strip **bold** markers (proves rendering ran: **... -> ...).
    $text =~ s/\*\*(.+?)\*\*/$1/g;
    return $text;
}
sub MockUI::colorize   { return $_[1] }
sub MockUI::agent_name { return 'CLIO' }
sub MockUI::pause      { return 'C' }
sub MockUI::_count_visual_lines {
    my ($self, $text) = @_;
    return 0 unless defined $text && length($text) > 0;
    my @l = split /\n/, $text, -1;
    pop @l if @l && $l[-1] eq '';
    return scalar @l;
}

my $spinner = bless {}, 'MockSpinner';
sub MockSpinner::stop  {}
sub MockSpinner::start {}

my $host = bless {}, 'MockHost';
sub MockHost::emit_status {}

# ---- Capture STDOUT to a temp file ----
my $tmpfile = "/tmp/clio_regress_out_$$.txt";
sub capture_stdout {
    my ($code) = @_;
    open(my $old, '>&', *STDOUT) or die $!;
    open(*STDOUT, '>', $tmpfile) or die $!;
    $code->();
    close(*STDOUT);
    open(*STDOUT, '>&', $old) or die $!;
    close($old);
    my $c = do { open(my $fh, '<', $tmpfile) or die $!; local $/; <$fh> };
    unlink $tmpfile;
    return $c;
}

sub fresh_sc {
    my $sc = CLIO::UI::StreamingController->new(ui => $mock_ui);
    $sc->reset();
    $pager->{line_count} = 0;
    $pager->{page} = [];
    return $sc;
}

sub strip_ansi { my $t = $_[0]; $t =~ s/\e\[[0-9;?]*[A-Za-z]//g; return $t }

# ---- Test 1: multi-line streamed response is clean ----
{
    my $sc = fresh_sc();
    my $cb = $sc->make_on_chunk_callback(spinner => $spinner, host_proto => $host);

    my $out = capture_stdout(sub {
        $cb->("Summary line one\n");
        $cb->("Second line of the response.\n");
        $cb->("**Bold** word here.\n");
        $cb->("And a third line.\n");
        $sc->flush();
    });

    my $vis = strip_ansi($out);

    # No live-mode cursor-dance escape sequences.
    unlike($out, qr/\e\[s/,   'no cursor save (\e[s)');
    unlike($out, qr/\e\[u/,   'no cursor restore (\e[u)');
    unlike($out, qr/\e\[K/,   'no clear-to-EOL (\e[K)');
    unlike($out, qr/\e\[2K/,  'no clear-entire-line (\e[2K)');
    unlike($out, qr/\e\[J/,   'no clear-to-end-of-screen (\e[J)');

    # "CLIO: " prefix appears exactly once and never doubled.
    my $prefix = () = ($vis =~ /CLIO: /g);
    is($prefix, 1, 'CLIO: prefix appears exactly once');
    unlike($vis, qr/CLIO: CLIO:/, 'no doubled CLIO: prefix adjacency');

    # Each content line appears exactly once (no doubled content).
    for my $n ("Summary line one", "Second line", "third line") {
        my $c = () = ($vis =~ /\Q$n\E/g);
        is($c, 1, "content '$n' not duplicated");
    }

    # Markdown was post-processed before display: raw ** gone, text remains.
    unlike($vis, qr/\*\*Bold\*\*/, 'raw ** markdown markers not leaked');
    like($vis, qr/Bold/, 'bold text rendered (markers stripped) before display');
}

# ---- Test 2: a single short line has no latency floor (size_limit=1) ----
{
    my $sc = fresh_sc();
    my $cb = $sc->make_on_chunk_callback(spinner => $spinner, host_proto => $host);

    my $out = capture_stdout(sub {
        $cb->("Just one line.\n");
        $sc->flush();
    });
    my $vis = strip_ansi($out);
    my $prefix = () = ($vis =~ /CLIO: /g);
    is($prefix, 1, 'single-line response: prefix once');
    like($vis, qr/Just one line/, 'single-line response: content rendered');
    unlike($out, qr/\e\[s/, 'single-line: no cursor save code');
}

# ---- Test 3: code-block lines defer flushing until the fence closes ----
{
    my $sc = fresh_sc();
    my $cb = $sc->make_on_chunk_callback(spinner => $spinner, host_proto => $host);

    my $out = capture_stdout(sub {
        $cb->("Here is a code block:\n");
        $cb->("$FB perl\n");
        $cb->("print \"hello\";\n");
        $cb->("$FB\n");
        $cb->("After the block.\n");
        $sc->flush();
    });
    my $vis = strip_ansi($out);
    like($vis, qr/Here is a code block/, 'pre-block line rendered');
    like($vis, qr/After the block/, 'post-block line rendered');
    unlike($out, qr/\e\[s/, 'code-block path: no cursor dance');
}

# ---- Test 4: flush() resets md_line_count and last_flush_time ----
# The public flush() must reset the same buffer-tracking state as the
# internal _flush_markdown_buffer(), otherwise callers that invoke flush()
# (e.g. the thinking callback's $flush_thinking) leave a stale md_line_count
# that can trigger a spurious extra flush on the next chunk.
{
    my $sc = fresh_sc();
    my $cb = $sc->make_on_chunk_callback(spinner => $spinner, host_proto => $host);

    # Push a partial line (no newline) so it lands in the line_buffer
    # and does NOT trigger the per-line flush path (which only fires
    # on complete lines). Then flush() must drain and reset state.
    $cb->("A line without a newline");

    # Manually set md_line_count to simulate a pending buffered state
    # that flush() should clean up (the per-line path already resets it
    # for complete lines, but flush() handles the residual tail).
    $sc->{md_line_count} = 3;
    ok($sc->{md_line_count} > 0, 'set md_line_count to a stale non-zero value');

    $sc->flush();

    is($sc->{md_line_count}, 0, 'flush() resets md_line_count to 0');
    ok(defined $sc->{last_flush_time}, 'flush() sets last_flush_time');
}

done_testing();
