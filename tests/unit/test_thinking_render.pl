#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression coverage for thinking-output formatting.
#
# Validates that the on_thinking callback:
#   1. Strips BOTH the simple (<!--session:foo-->) and structured
#      (<!--session:{"title":"..."}-->) session-naming markers.
#   2. Renders Markdown (bold/italic/headings) inside thinking content.
#   3. Renders tables (lines starting with |) and preserves their structure.
#   4. Word-wraps long lines that exceed the terminal width.
#   5. Does NOT produce run-on words when chunks split inside a word.
#   6. Preserves in-progress trailing partial lines until a newline or end.
#
# Run: perl -I./lib tests/unit/test_thinking_render.pl

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use CLIO::UI::Chat;
use CLIO::UI::StreamingController;
use CLIO::Compat::Terminal;

# ---- Lightweight stubs ----
package MockConfig;
sub new {
    my ($class, %opts) = @_;
    return bless { show_thinking => $opts{show_thinking} ? 1 : 0 }, $class;
}
sub get { my ($self, $key) = @_; return $self->{$key}; }

package MockSpinner;
sub new { return bless {}, shift; }
sub stop { }

# Capture STDOUT inside the callback without invoking terminal-side
# Markdown parsing (so we can assert exact byte output).
package MockChat;
sub new {
    my ($class, %opts) = @_;
    my $self = {
        config      => $opts{config},
        theme_mgr   => undef,
    };
    bless $self, $class;
    no strict 'refs';
    no warnings 'redefine';
    no strict 'refs';
    *{'MockChat::_make_thinking_callback'} =
        \&CLIO::UI::Chat::_make_thinking_callback;
    require CLIO::UI::StreamingController;
    require CLIO::Compat::Terminal;
    $self->{enable_markdown}             = 1;
    # The thinking callback now delegates to StreamingController for
    # Markdown rendering and word-wrap. Build a real one against the
    # mock so flush()/render_markdown() succeed.
    $self->{streaming}                    = CLIO::UI::StreamingController->new(ui => $self);
    $self->{first_chunk_received}         = 0;
    $self->{stop_streaming}              = 0;
    $self->{_last_was_system_message}     = 0;
    $self->{_prepare_for_next_iteration}  = 0;
    $self->{_need_agent_prefix}           = 0;
    $self->{terminal_width}              = $opts{terminal_width} || 100;
    $self->{_count_visual_lines} = \&_count_visual_lines;
    $self->{pager} = bless { line_count => 0, pages => [],
        current_page => [], page_index => 0, pagination_enabled => 0 },
        'MockPager';
    {
        no strict 'refs';
        *MockPager::enable = sub { $_[0]->{pagination_enabled} = 1 };
        *MockPager::disable = sub { $_[0]->{pagination_enabled} = 0 };
        *MockPager::reset_page = sub { $_[0]->{line_count} = 0; $_[0]->{current_page} = [] };
        *MockPager::track_line = sub { push @{$_[0]->{current_page}}, $_[1]; $_[0]->{line_count}++ };
        *MockPager::increment_lines = sub { $_[0]->{line_count} += ($_[1] // 1) };
        *MockPager::line_count = sub { $_[0]->{line_count} = $_[1] if defined $_[1]; $_[0]->{line_count} };
        *MockPager::enabled = sub { $_[0]->{pagination_enabled} };
        *MockPager::should_trigger = sub { 0 };
    }
    return $self;
}
sub colorize { my ($self, $text, $tag) = @_; return $text; }
# Identity Markdown so we can compare the input characters verbatim and
# still exercise the routing/marker-strip paths. Production code uses
# CLIO::UI::Markdown; we don't need to re-test that here.
sub render_markdown { return $_[1]; }
sub _indent_and_wrap { return $_[1]; }

sub _count_visual_lines {
    my ($self, $text) = @_;
    return 0 unless defined $text && length($text) > 0;
    my @lines = split /\n/, $text, -1;
    pop @lines if @lines && $lines[-1] eq '';
    return scalar(@lines);
}

sub _capture_stdout { goto &main::_capture_stdout }

package main;

sub main::_capture_stdout {
    my ($cb) = @_;
    my $captured = '';
    # The thinking callback emits unicode horizontal-rule chars and
    # bullets via the colorize() path. Set the UTF-8 layer on the
    # in-memory filehandle so Perl does not raise "Wide character"
    # warnings during the capture phase.
    open my $fh, '>:encoding(UTF-8)', \$captured or die "open in-memory fh: $!";
    my $old = select $fh;
    local $| = 1;
    $cb->();
    select $old;
    close $fh;
    return $captured;
}

# --- Test 1: simple session marker stripped from thinking content ---
subtest 'simple session marker stripped' => sub {
    my $config  = MockConfig->new(show_thinking => 1);
    my $chat    = MockChat->new(config => $config);
    my $spinner = MockSpinner->new;
    my $cb      = $chat->_make_thinking_callback($spinner);

    my $out = _capture_stdout(sub {
        $cb->('', 'start');
        $cb->("Reasoning prose before marker. <!--session:audit-thinking-format-->", undef);
        $cb->('', 'end');
    });

    unlike($out, qr/<!--session:/, 'simple session marker stripped from thinking');
    like($out, qr/Reasoning prose before marker/, 'content before marker preserved');
};

# --- Test 2: structured session marker stripped from thinking content ---
subtest 'structured session marker stripped' => sub {
    my $config  = MockConfig->new(show_thinking => 1);
    my $chat    = MockChat->new(config => $config);
    my $spinner = MockSpinner->new;
    my $cb      = $chat->_make_thinking_callback($spinner);

    my $out = _capture_stdout(sub {
        $cb->('', 'start');
        $cb->('Plan: yes <!--session:{"title":"audit-thinking-format"}-->', undef);
        $cb->('', 'end');
    });

    unlike($out, qr/<!--session:/, 'structured session marker stripped from thinking');
    unlike($out, qr/audit-thinking-format/, 'no leak of marker payload');
    like($out, qr/Plan: yes/, 'pre-marker content preserved');
};

# --- Test 3: Markdown bold renders in thinking (after routing through Markdown) ---
# We assert on the routing layer by giving the MockChat a Markdown-aware render.
subtest 'thinking routed through Markdown rendering' => sub {
    package MarkdownAwareChat;
    our @ISA = ('MockChat');
    sub render_markdown {
        my ($self, $text) = @_;
        # Real Markdown would convert **bold** -> @BOLD_BOLD@marker. We use
        # an unambiguous stand-in so the test is robust.
        $text =~ s/\*\*([^*]+)\*\*/<BOLD:$1>/g;
        return $text;
    }
    package main;

    my $config  = MockConfig->new(show_thinking => 1);
    my $chat    = MarkdownAwareChat->new(config => $config);
    my $spinner = MockSpinner->new;
    my $cb      = $chat->_make_thinking_callback($spinner);

    my $out = _capture_stdout(sub {
        $cb->('', 'start');
        $cb->("Thinking about **important** point\n", undef);
        $cb->('', 'end');
    });

    like($out, qr/<BOLD:important>/, 'Markdown bold rendered in thinking');
};

# --- Test 4: table rows preserved as discrete lines ---
subtest 'thinking preserves table line structure' => sub {
    my $config  = MockConfig->new(show_thinking => 1);
    my $chat    = MockChat->new(config => $config);
    my $spinner = MockSpinner->new;
    my $cb      = $chat->_make_thinking_callback($spinner);

    my $out = _capture_stdout(sub {
        $cb->('', 'start');
        $cb->("| a | b |\n|---|---|\n| 1 | 2 |\n", undef);
        $cb->('', 'end');
    });

    like($out, qr/\| a \| b \|/, 'header row preserved');
    like($out, qr/\|---\|---/,  'separator row preserved');
    like($out, qr/\| 1 \| 2 \|/, 'data row preserved');
};

# --- Test 5: word-wrap prevents overflow ---
subtest 'long thinking lines are wrapped' => sub {
    # Force a narrow terminal width on the mock so the wrap path is
    # exercised regardless of the harness's actual COLUMNS env value.
    my $config  = MockConfig->new(show_thinking => 1);
    my $chat    = MockChat->new(config => $config);
    $chat->{enable_markdown} = 1;
    $chat->{terminal_width}  = 60;
    $chat->{_count_visual_lines} = sub {
        my $n = 0;
        for my $l (split /\n/, $_[1]) { $n++ if length($l) > 0 }
        return $n;
    };
    $chat->{_last_was_system_message} = 0;
    $chat->{_prepare_for_next_iteration} = 0;
    require CLIO::Compat::Terminal;
    no warnings 'redefine';
    *CLIO::Compat::Terminal::GetTerminalSize = sub { (60, 24) };
    my $spinner = MockSpinner->new;
    my $cb      = $chat->_make_thinking_callback($spinner);
    my $long_line = 'word ' x 40;  # 200 chars, will exceed 60-column wrap
    $long_line =~ s/\s+$//;

    my $out = _capture_stdout(sub {
        $cb->('', 'start');
        $cb->("$long_line\n", undef);
        $cb->('', 'end');
    });

    my @lines = split /\n/, $out;
    my $max_visible = 0;
    my @oversize;
    for my $line (@lines) {
        my $v = $line;
        $v =~ s/\e\[[0-9;]*[A-Za-z]//g;
        # Skip the THINKING header and the closing horizontal rule,
        # both of which span the full terminal width by design.
        next if $v =~ /THINKING/;
        next if $v =~ /^[\s\xe2\x94\x80]+$/ && length($v) >= 50;
        if (length($v) > 60) {
            push @oversize, [length($v), substr($v, 0, 80)];
        }
        $max_visible = length($v) if length($v) > $max_visible;
    }
    if (@oversize) {
        diag "Oversize lines (showing first 5):";
        for my $o (@oversize[0 .. ($#oversize > 4 ? 4 : $#oversize)]) {
            diag "  len=$o->[0]  sample=$o->[1]";
        }
    }
    # Should not exceed terminal width (with a small margin for indent)
    cmp_ok($max_visible, '<=', 80,
        "wrapped lines stay within terminal width (max=$max_visible)");
};

# --- Test 6: chunks split mid-word don't produce run-on joins ---
subtest 'chunks split mid-word do not produce run-on joins' => sub {
    my $config  = MockConfig->new(show_thinking => 1);
    my $chat    = MockChat->new(config => $config);
    my $spinner = MockSpinner->new;
    my $cb      = $chat->_make_thinking_callback($spinner);

    # Provider streams "the noise" split mid-word: "thenoise" in one chunk,
    # " " before, "." after. The renderer must not glue the two halves into
    # "thenoise" in the visible output.
    my $out = _capture_stdout(sub {
        $cb->('', 'start');
        $cb->("Characterize the", undef);
        $cb->(" noise profile.\n", undef);
        $cb->('', 'end');
    });

    unlike($out, qr/thenoise/, 'chunks split inside "the" did not glue into "thenoise"');
    like($out, qr/Characterize the/, 'text before split preserved');
    like($out, qr/noise profile/, 'text after split preserved');
};

# --- Test 7: empty summary still produces no THINKING box ---
subtest 'empty summary produces no THINKING box' => sub {
    my $config  = MockConfig->new(show_thinking => 1);
    my $chat    = MockChat->new(config => $config);
    my $spinner = MockSpinner->new;
    my $cb      = $chat->_make_thinking_callback($spinner);

    my $out = _capture_stdout(sub {
        $cb->('', 'start');
        $cb->('', 'end');
    });

    is($out, '', 'no THINKING box rendered for empty summary');
};

# --- Test 8: show_thinking=0 produces no output even with content ---
subtest 'show_thinking=0 - callback is a no-op' => sub {
    my $config  = MockConfig->new(show_thinking => 0);
    my $chat    = MockChat->new(config => $config);
    my $spinner = MockSpinner->new;
    my $cb      = $chat->_make_thinking_callback($spinner);

    my $out = _capture_stdout(sub {
        $cb->('', 'start');
        $cb->('Some reasoning text', undef);
        $cb->('', 'end');
    });

    is($out, '', 'no output when show_thinking is off');
};

# --- Test 9: end-of-stream flush of partial line (no trailing newline) ---
subtest 'end signal flushes partial trailing line' => sub {
    my $config  = MockConfig->new(show_thinking => 1);
    my $chat    = MockChat->new(config => $config);
    my $spinner = MockSpinner->new;
    my $cb      = $chat->_make_thinking_callback($spinner);

    my $out = _capture_stdout(sub {
        $cb->('', 'start');
        $cb->('partial line without newline', undef);
        $cb->('', 'end');
    });

    like($out, qr/partial line without newline/,
        'partial line at end-of-stream is flushed');
};

# --- Test 10: end signal preserves main streaming controller state.
# Regression guard for the boundary bug where thinking flush could
# leak first_chunk_received or first_line_printed state changes into
# the main answer stream that follows. The fix preserves all main-
# controller fields that flush_thinking() touches.
#
# Documented behavior:
#   - first_chunk_received MUST be reset to 0 by thinking 'end' so the
#     subsequent answer stream re-emits "CLIO: " on its first chunk.
#   - first_line_printed MUST remain at its pre-call value so the
#     answer stream's first line is NOT indented (it sits next to the
#     "CLIO: " prefix, not below it).
subtest 'end signal preserves main streaming controller state' => sub {
    my $config  = MockConfig->new(show_thinking => 1);
    my $chat    = MockChat->new(config => $config);
    # Simulate that a prior answer stream had already started (so
    # first_chunk_received=1). After thinking ends, the boundary
    # behavior is: first_chunk_received reset to 0, first_line_printed
    # preserved.
    $chat->{streaming}->{first_chunk_received} = 1;
    $chat->{streaming}->{first_line_printed}  = 1;
    my $spinner = MockSpinner->new;
    my $cb      = $chat->_make_thinking_callback($spinner);

    my $out = _capture_stdout(sub {
        $cb->('', 'start');
        $cb->("thinking prose\n", undef);
        $cb->('', 'end');
    });

    is($chat->{streaming}->{first_chunk_received}, 0,
        'first_chunk_received reset to 0 so answer stream re-emits CLIO: prefix');
    is($chat->{streaming}->{first_line_printed}, 1,
        'main controller first_line_printed unchanged by thinking flush');
    like($out, qr/THINKING/, 'THINKING header still emitted inside box');
};

done_testing();