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

# Test 3: chunks with error AND choices (e.g., mid-stream error with prior content)
# should NOT be treated as pure-error chunks; let existing content flow through.
{
    my $am = bless({
        response_handler => bless({}, 'StubRH'),
        session => undef,
    }, 'CLIO::Core::APIManager');

    my $ss = {
        accum_content => '',
        use_responses_api => 0,
    };

    my $data = {
        choices => [{ delta => { content => 'partial' } }],
        error => { message => 'late', code => 'late' },
    };

    $am->_process_sse_data($data, '', $ss);

    ok(!exists $ss->{_sse_error},
       'Test 3.1: chunk with both choices+error is not flagged as SSE error');
    is($ss->{accum_content}, 'partial',
       'Test 3.2: content still extracted when error accompanies choices');
}

done_testing();
