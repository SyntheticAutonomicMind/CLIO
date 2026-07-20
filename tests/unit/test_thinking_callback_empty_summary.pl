#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Test Chat::_make_thinking_callback empty-summary behavior.
#
# Anthropic's adaptive thinking summarizer can return an empty string for
# trivial reasoning (e.g. "which tool do I call next?" decisions) even
# though the round-trip still produces a valid signature we bill for. The
# old behavior printed the THINKING header on the start signal and then
# the top hrule, producing a visually empty box when the summarizer
# collapsed to nothing. The fix defers header/hrule printing until the
# first real content chunk arrives, and skips the box entirely if 'end'
# fires with no content.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use CLIO::UI::Chat;

# ---------------------------------------------------------------------------
# Lightweight mocks. We avoid instantiating a full Chat (which pulls in a
# lot of UI machinery) by creating a stub class with only the surface area
# _make_thinking_callback touches:
#   $self->{config}              - has get('show_thinking')
#   $self->{theme_mgr}           - undef or a get_tool_display_format method
#   $self->colorize($text, $tag) - returns (possibly colorized) string
#   $self->{streaming}           - hash with first_chunk_received flag
# Then we install _make_thinking_callback by copying the actual sub from
# CLIO::UI::Chat into our mock package via symbol-table aliasing.
# ---------------------------------------------------------------------------

package MockConfig;
sub new {
    my ($class, %opts) = @_;
    return bless { show_thinking => $opts{show_thinking} ? 1 : 0 }, $class;
}
sub get { my ($self, $key) = @_; return $self->{$key}; }

package MockSpinner;
sub new { return bless {}, shift; }
sub stop { }

package MockChat;
sub new {
    my ($class, %opts) = @_;
    my $self = {
        config      => $opts{config},
        theme_mgr   => undef,
        streaming   => { first_chunk_received => 0 },
    };
    bless $self, $class;
    # Alias CLIO::UI::Chat::_make_thinking_callback into this package so
    # the mock can call it directly. We rebind the coderef so that any
    # internal `use CLIO::UI::Theme`/etc. references inside the sub
    # resolve against CLIO::UI::Chat::, which already has those modules
    # loaded.
    no strict 'refs';
    no warnings 'redefine';
    *{__PACKAGE__ . "::_make_thinking_callback"} =
        \&CLIO::UI::Chat::_make_thinking_callback;
    # The thinking callback now delegates to a real StreamingController
    # for Markdown rendering and word-wrap. Build a real one with the
    # mock so flush()/render_markdown() succeed.
    require CLIO::UI::StreamingController;
    $self->{streaming}                = CLIO::UI::StreamingController->new(ui => $self);
    $self->{first_chunk_received}     = 0;
    $self->{stop_streaming}          = 0;
    $self->{_last_was_system_message} = 0;
    $self->{_prepare_for_next_iteration} = 0;
    $self->{_need_agent_prefix}       = 0;
    $self->{enable_markdown}         = 1;
    $self->{terminal_width}          = 100;
    $self->{_count_visual_lines} = sub {
        my ($self, $text) = @_;
        return 0 unless defined $text && length($text) > 0;
        my @lines = split /\n/, $text, -1;
        pop @lines if @lines && $lines[-1] eq '';
        return scalar(@lines);
    };
    $self->{pager} = bless { line_count => 0, pages => [],
        current_page => [], page_index => 0, pagination_enabled => 0 },
        'MockPager';
    {
        no strict 'refs';
        for my $m (qw(enable disable reset_page track_line
                increment_lines line_count enabled should_trigger)) {
            my $body = $m eq 'enable'         ? sub { $_[0]->{pagination_enabled} = 1 }
                     : $m eq 'disable'        ? sub { $_[0]->{pagination_enabled} = 0 }
                     : $m eq 'reset_page'     ? sub { $_[0]->{line_count} = 0; $_[0]->{current_page} = [] }
                     : $m eq 'track_line'     ? sub { push @{$_[0]->{current_page}}, $_[1]; $_[0]->{line_count}++ }
                     : $m eq 'increment_lines'? sub { $_[0]->{line_count} += ($_[1] // 1) }
                     : $m eq 'line_count'     ? sub { $_[0]->{line_count} = $_[1] if defined $_[1]; $_[0]->{line_count} }
                     : $m eq 'enabled'        ? sub { $_[0]->{pagination_enabled} }
                     :                         sub { 0 };
            no warnings 'redefine';
            *{"MockPager::$m"} = $body;
        }
    }
    return $self;
}
# colorize: identity (no ANSI codes) so test output is greppable.
sub colorize { my ($self, $text, $tag) = @_; return $text; }
sub render_markdown { my ($self, $text) = @_; return $text; }
sub agent_name { 'CLIO' }

package main;

# ---------------------------------------------------------------------------
# Helper: capture STDOUT during the callback invocation. Returns the
# captured string. We're testing the visible output, so capturing is the
# cleanest way to assert what got printed.
# ---------------------------------------------------------------------------
sub _capture_stdout {
    my ($cb) = @_;
    my $captured = '';
    open my $fh, '>:encoding(UTF-8)', \$captured or die "open in-memory fh: $!";
    my $old = select $fh;
    local $| = 1;
    $cb->();
    select $old;
    close $fh;
    return $captured;
}

# ---------------------------------------------------------------------------
# Test 1: when show_thinking is off, the callback is a no-op.
# ---------------------------------------------------------------------------
subtest 'show_thinking=0 - callback is a no-op' => sub {
    my $config  = MockConfig->new(show_thinking => 0);
    my $chat    = MockChat->new(config => $config);
    my $spinner = MockSpinner->new;

    my $cb  = $chat->_make_thinking_callback($spinner);
    my $out = _capture_stdout(sub {
        $cb->('any content', 'start');
        $cb->('thinking text', undef);
        $cb->('', 'end');
    });
     is($out, '', 'No output when show_thinking is off');
};

# ---------------------------------------------------------------------------
# Test 2: empty summary (start -> end with no content) produces no box.
# This is the regression: the old code printed header + top hrule on the
# start signal, so even with no content the user saw an empty THINKING box.
# ---------------------------------------------------------------------------
subtest 'show_thinking=1 - empty summary produces no THINKING box' => sub {
    my $config  = MockConfig->new(show_thinking => 1);
    my $chat    = MockChat->new(config => $config);
    my $spinner = MockSpinner->new;

    my $cb  = $chat->_make_thinking_callback($spinner);
    my $out = _capture_stdout(sub {
        $cb->('', 'start');
        $cb->('', 'end');
    });
     is($out, '', 'No output when summary is empty (start + end, no content)');
};

# ---------------------------------------------------------------------------
# Test 3: non-empty summary produces THINKING header + content + footer.
# ---------------------------------------------------------------------------
subtest 'show_thinking=1 - non-empty summary renders THINKING box' => sub {
    my $config  = MockConfig->new(show_thinking => 1);
    my $chat    = MockChat->new(config => $config);
    my $spinner = MockSpinner->new;

    my $cb  = $chat->_make_thinking_callback($spinner);
    my $out = _capture_stdout(sub {
        $cb->('', 'start');
        $cb->("Considering which tool to call next.\n", undef);
        $cb->('', 'end');
    });
     like($out, qr/THINKING/, 'Box contains THINKING label');
     like($out, qr/Considering which tool to call next/, 'Box contains content');
};

# ---------------------------------------------------------------------------
# Test 4: header is NOT printed on 'start' alone; it appears only after the
# first content chunk arrives. Verifies the deferral behavior.
# ---------------------------------------------------------------------------
subtest 'show_thinking=1 - header deferred until first content chunk' => sub {
    my $config  = MockConfig->new(show_thinking => 1);
    my $chat    = MockChat->new(config => $config);
    my $spinner = MockSpinner->new;

    my $cb = $chat->_make_thinking_callback($spinner);

    # Step 1: send 'start' alone - nothing should be printed yet.
    my $out_start_only = _capture_stdout(sub {
        $cb->('', 'start');
    });
     is($out_start_only, '',
        'No output on start signal alone (header deferred)');

    # Step 2: now send content - header + content should appear together.
    my $out_after_content = _capture_stdout(sub {
        $cb->("Reasoning about the next step.\n", undef);
        # The header now defers rendering until 'end' too: only after
        # the streaming chunk has been accumulated into the
        # StreamingController do we print the THINKING box. Send an
        # 'end' so the flush_thinking path renders the deferred box.
        $cb->('', 'end');
    });
     like($out_after_content, qr/THINKING/,
        'Header appears once first content arrives');
     like($out_after_content, qr/Reasoning about the next step/,
        'First content chunk is rendered');
};

done_testing();