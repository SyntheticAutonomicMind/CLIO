#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for multimodal (arrayref) content handling in YaRN and
# MessageValidator. CLIO supports image uploads which produce messages
# with arrayref content like:
#   [{ type => 'text', text => '...' }, { type => 'image_url', ... }]
#
# Previously, find_substantive_task, recover_substantive_task, and
# compress_messages accessed $msg->{content} directly with length(),
# substr(), regex — all of which break on arrayref content (producing
# warnings under strict + silently dropping the text).
# _estimate_tokens_with_ratio had the same issue.
#
# These tests verify text is correctly extracted from multimodal content.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Memory::YaRN;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

# ===========================================================================
# 1. find_substantive_task handles arrayref content
# ===========================================================================
subtest 'find_substantive_task handles arrayref (multimodal) content' => sub {
    # A substantive user message sent with an image attachment
    my @messages = (
        { role => 'user', content => [
            { type => 'text', text => 'Audit the role-based context compression in ContextBuilder.pm for arrayref safety' },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,abc' } },
        ]},
    );

    my $task = CLIO::Memory::YaRN::find_substantive_task('', \@messages);
    ok(defined $task && length($task) > 0, 'find_substantive_task found text from arrayref content');
    like($task, qr/Audit the role-based context/, 'extracted text is the substantive user request');
    ok(length($task) >= 50, 'task meets >= 50 char substantiveness threshold');
};

# ===========================================================================
# 2. find_substantive_task skips short arrayref text (acks)
# ===========================================================================
subtest 'find_substantive_task skips short arrayref acks' => sub {
    my @messages = (
        { role => 'user', content => [
            { type => 'text', text => 'yes' },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,abc' } },
        ]},
        { role => 'user', content => 'Actually, audit the Security layer for path traversal too' },
    );

    # The short ack should be skipped, substantive message from history used
    my $task = CLIO::Memory::YaRN::find_substantive_task('', \@messages);
    like($task, qr/audit the Security layer/, 'skipped short arrayref ack, found substantive history message');
};

# ===========================================================================
# 3. recover_substantive_task handles arrayref content in thread
# ===========================================================================
subtest 'recover_substantive_task handles arrayref content in thread' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    # Simulate a session with a multimodal user message in the thread
    $yarn->add_to_thread('test-session', {
        role => 'user',
        content => [
            { type => 'text', text => 'Review the YaRN compression refactor in YARN.pm for correctness across all extraction paths' },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,xyz' } },
        ],
    });

    my $task = CLIO::Memory::YaRN::recover_substantive_task($yarn, 'test-session');
    ok(defined $task && length($task) > 0, 'recover_substantive_task found text from arrayref content');
    like($task, qr/Review the YaRN compression refactor/, 'extracted text matches the substantive user message');
    ok(length($task) >= 50, 'recovered task meets >= 50 char threshold');
};

# ===========================================================================
# 4. recover_substantive_task with non-YaRN session object
# ===========================================================================
subtest 'recover_substantive_task handles arrayref via session object' => sub {
    my $yarn = CLIO::Memory::YaRN->new();
    $yarn->add_to_thread('sess-abc', {
        role => 'user',
        content => [
            { type => 'text', text => 'Fix the multiline string token estimation bug in _estimate_tokens_with_ratio' },
        ],
    });

    package FakeSession {
        sub new { my ($class, $y, $id) = @_; bless { _yarn => $y, _id => $id }, $class }
        sub yarn { return $_[0]{_yarn} }
        sub id  { return $_[0]{_id} }
    }

    my $session = FakeSession->new($yarn, 'sess-abc');
    my $task = CLIO::Memory::YaRN::recover_substantive_task($session);
    like($task, qr/Fix the multiline string token estimation bug/, 'recovered from session with arrayref content');
};

# ===========================================================================
# 5. compress_messages handles arrayref content (text extracted for summary)
# ===========================================================================
subtest 'compress_messages extracts text from arrayref content' => sub {
    my $yarn = CLIO::Memory::YaRN->new();

    my @messages = (
        {
            role => 'user',
            content => [
                { type => 'text', text => 'Investigate the _compute_limits scaling for 64K context windows' },
                { type => 'image_url', image_url => { url => 'data:image/png;base64,imgdata' } },
            ],
        },
        {
            role => 'assistant',
            content => 'Looking at _compute_limits now.',
            tool_calls => [
                { id => 'tc1', function => { name => 'file_operations', arguments => '{"path":"lib/CLIO/Memory/YAARN.pm"}' } }
            ],
        },
        {
            role => 'tool',
            content => '[def5678] fix(memory): audit _compute_limits scaling for 64K',
            tool_call_id => 'tc1',
        },
    );

    my $summary = $yarn->compress_messages(\@messages,
        original_task => 'Investigate the _compute_limits scaling for 64K context windows');

    ok($summary && $summary->{content}, 'compression succeeded with arrayref content');
    like($summary->{content}, qr/Investigate the _compute_limits scaling/, 'summary contains text extracted from arrayref content');
    like($summary->{content}, qr/Current task:/, 'summary has Current task section');
    # No warnings should have been produced (the strict suite would catch these,
    # but we verify the output is clean here)
    unlike($summary->{content}, qr/ARRAY\(0x/, 'no raw arrayref in summary output');
};

# ===========================================================================
# 6. _estimate_tokens_with_ratio handles arrayref content
# ===========================================================================
subtest '_estimate_tokens_with_ratio handles arrayref content' => sub {
    # String content: 10 chars / 4.0 ratio = ceil(2.5) = 3
    my $str_tokens = CLIO::Core::API::MessageValidator::_estimate_tokens_with_ratio('hello world!', 4.0);
    is($str_tokens, 3, 'string: 12 chars / 4.0 = 3 tokens');

    # Arrayref content with text part only: 12 chars / 4.0 = ceil(3.0) = 3
    my $array_tokens = CLIO::Core::API::MessageValidator::_estimate_tokens_with_ratio(
        [{ type => 'text', text => 'hello world!' }],
        4.0
    );
    is($array_tokens, 3, 'arrayref text-only: 12 chars / 4.0 = 3 tokens');

    # Arrayref with text + image: text tokens + 85 image tokens
    # 'hello' is 5 chars, ceil(5/4) = 2, plus 85 image = 87
    my $mixed_tokens = CLIO::Core::API::MessageValidator::_estimate_tokens_with_ratio(
        [{ type => 'text', text => 'hello' }, { type => 'image_url', image_url => { url => 'data:image/png;base64,xyz' } }],
        4.0
    );
    is($mixed_tokens, 87, 'arrayref text+image: 5 chars / 4.0 = 2 tokens + 85 image = 87');

    # Empty arrayref content
    my $empty_tokens = CLIO::Core::API::MessageValidator::_estimate_tokens_with_ratio(
        [{ type => 'text', text => '' }],
        4.0
    );
    is($empty_tokens, 0, 'empty text in arrayref returns 0');

    # Scalar (non-arrayref) content still works
    my $scalar_tokens = CLIO::Core::API::MessageValidator::_estimate_tokens_with_ratio('aaaa', 4.0);
    is($scalar_tokens, 1, 'scalar content: 4 chars / 4.0 = 1 token');
};

# ===========================================================================
# 7. validate_and_truncate handles arrayref content without crashing
# ===========================================================================
subtest 'validate_and_truncate does not warn on arrayref content' => sub {
    my @messages = (
        { role => 'system', content => 'You are a helpful assistant.' },
        { role => 'user', content => [
            { type => 'text', text => 'Review this code change ' . ('x' x 200) },
            { type => 'image_url', image_url => { url => 'data:image/png;base64,abc' } },
        ]},
        { role => 'assistant', content => 'Looking at it.' },
    );

    my $caps = {
        max_context_window_tokens => 128000,
        max_output_tokens         => 16000,
    };

    # Pre-load lazily-required modules so their one-time load warnings
    # (e.g. Types::Serialiser bareword from vendor deps) don't leak into
    # our warning capture. We only care about warnings from CLIO's own
    # code paths in the validate_and_truncate call.
    require CLIO::Providers;
    require CLIO::Memory::TokenEstimator;
    require CLIO::Memory::LongTerm;

    # Capture warnings only from the validate_and_truncate call.
    # Filter out vendor warnings (Types::Serialiser, Test::More, etc.)
    # so we only see CLIO-originated warnings like length() on arrayref.
    my @clio_warnings;
    local $SIG{__WARN__} = sub {
        my $msg = $_[0];
        # Only count warnings that mention CLIO source files
        push @clio_warnings, $msg if $msg =~ /CLIO/;
    };

    my $result = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 4.0,
    );

    ok(ref($result) eq 'ARRAY', 'validate_and_truncate returns arrayref for multimodal content');
    is(scalar(@clio_warnings), 0, 'no CLIO-originated warnings for arrayref content in validate_and_truncate');
};

done_testing();
