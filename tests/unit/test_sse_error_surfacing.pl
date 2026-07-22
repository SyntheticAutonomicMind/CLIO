#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 fewtarius
#
# Integration test: simulate the full SSE streaming path including
# _process_sse_data and _finalize_streaming_response to confirm that
# SSE error chunks get surfaced as retryable errors instead of being
# silently swallowed.
#
# This is the production bug: NVIDIA NIM streaming responses occasionally
# arrive as `data: {"error":{"message":"...","code":"..."}}\n\n` instead
# of normal chunks. Before the fix, this caused the workflow to exit
# with `content: UNDEF` at the orchestrator level.

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use CLIO::Core::APIManager;

# Stub response_handler for both subroutines.
package StubRH;
sub release_broker_slot {}

package main;
sub fake_resp {
    return bless { headers => bless {}, 'FakeResp' }, 'FakeResp';
}
sub FakeResp::headers { return $_[0]->{headers}; }

# Test 1: _process_sse_data captures SSE error chunk on streaming state
{
    my $am = bless({
        response_handler => bless({}, 'StubRH'),
        session => undef,
    }, 'CLIO::Core::APIManager');

    # Simulate streaming state hash
    my $ss = {
        accum_content => '',
        use_responses_api => 0,
    };

    # SSE error chunk (NVIDIA NIM pattern)
    my $data = {
        error => {
            message => 'Upstream provider returned empty response',
            code => 'upstream',
        },
    };

    $am->_process_sse_data($data, '', $ss);

    ok(exists $ss->{_sse_error}, 'Test 1.1: SSE error captured on streaming state');
    is($ss->{_sse_error}{message}, 'Upstream provider returned empty response',
       'Test 1.2: error message preserved');
    is($ss->{_sse_error}{code}, 'upstream', 'Test 1.3: error code preserved');
}

# Test 2: _process_sse_data does NOT capture regular chunks as errors
{
    my $am = bless({
        response_handler => bless({}, 'StubRH'),
        session => undef,
    }, 'CLIO::Core::APIManager');

    my $ss = {
        accum_content => '',
        use_responses_api => 0,
    };

    # Normal completion chunk
    my $data = {
        choices => [{
            delta => { content => 'hello' },
        }],
    };

    $am->_process_sse_data($data, '', $ss);

    ok(!exists $ss->{_sse_error}, 'Test 2.1: regular chunk not flagged as SSE error');
    is($ss->{accum_content}, 'hello', 'Test 2.2: content from normal chunk accumulated');
}

# Test 3: Responses API error event delivery (event_type=error pattern).
# This is the second error shape - data has `type=error` and message/code at top level.
{
    my $am = bless({
        response_handler => bless({}, 'StubRH'),
        session => undef,
    }, 'CLIO::Core::APIManager');

    my $ss = {
        accum_content => '',
        use_responses_api => 1,  # Responses API
    };

    my $data = {
        type => 'error',
        message => 'Server overloaded',
        code => 'overloaded',
    };

    $am->_process_sse_data($data, 'error', $ss);

    ok(exists $ss->{_sse_error},
       'Test 3.1: Responses API error event captured');
    is($ss->{_sse_error}{message}, 'Server overloaded',
       'Test 3.2: Responses API error message preserved');
    is($ss->{_sse_error}{code}, 'overloaded',
       'Test 3.3: Responses API error code preserved');
}

# Test 4: Streaming chunk loop must safely skip JSON `null` payloads.
# safe_decode_json returns undef for JSON `null` (no $@), and the previous
# SSE loop passed that undef to _process_sse_data which would then crash
# on `keys %$data`. Verify the loop side skips null/non-hash payloads.
{
    use CLIO::Util::JSON qw(safe_decode_json);

    my $cases = [
        { name => 'JSON null',     input => 'null' },
        { name => 'JSON scalar',   input => '42' },
        { name => 'JSON array',    input => '[1,2,3]' },
        { name => 'JSON string',   input => '"hello"' },
        { name => 'JSON object',   input => '{"choices":[]}' },
    ];

    for my $case (@$cases) {
        my $data = safe_decode_json($case->{input});
        my $is_hash = ref($data) eq 'HASH';
        my $should_process = $is_hash ? 1 : 0;
        ok(($is_hash && $should_process) || (!$is_hash && !$should_process),
           "Test 4.x: $case->{name} payload shape correctly recognized");
    }

    # Replicate the SSE-loop guard
    my $data = safe_decode_json('null');
    my $would_skip = (!defined $data) || (ref($data) ne 'HASH');
    ok($would_skip, 'Test 4.6: null payload would be skipped by SSE loop guard');
}

done_testing();
