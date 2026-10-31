#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-or-later
# Integration tests for the llama.cpp streaming reasoning loop recovery:
# delta processing drives the ReasoningLoopDetector and fires the
# /v1/chat/completions/control reasoning_end call exactly once.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use lib "$RealBin/../lib";
use Test::More;

use CLIO::Core::APIManager;
use CLIO::Compat::HTTP;
use CLIO::Util::JSON qw(decode_json);
use HTTP::Request;

my $api = bless {
    config  => undef,
    session => undef,
}, 'CLIO::Core::APIManager';

sub make_ss {
    my (%over) = @_;
    return {
        reasoning_active  => 1,
        accum_reasoning   => '',
        cmpl_id           => 'cmpl-1234567890',
        loop_check_len    => 0,
        loop_detector     => CLIO::Core::ReasoningLoopDetector->new(),
        loop_action_taken => 0,
        control_url       => 'http://localhost:8080/v1/chat/completions/control',
        control_auth_header => 'Authorization',
        control_auth_value  => 'Bearer no-key-required',
        on_thinking       => undef,
        model             => 'local-model',
        opts              => {},
        %over,
    };
}

my $LOOP_SENTENCE = 'Wait, but the ort strategy resolves conflicts by taking the version from the branch being merged into. ';

sub feed_reasoning {
    my ($ss, $text) = @_;
    return $api->_process_chat_completions_delta(
        { choices => [ { delta => { reasoning_content => $text } } ] }, $ss);
}

# =============================================================================
# Section 1: success path - control call fires with correct payload
# =============================================================================
subtest 'loop triggers exactly one control call with reasoning_end' => sub {
    my @captured;
    my $thinking_seen = '';
    my $ss = make_ss(on_thinking => sub { $thinking_seen .= $_[0] });
    # First chunk: not enough characters to trigger a detector pass
    my ($c1, $t1) = feed_reasoning($ss, 'Some normal reasoning text. ');
    is($c1, undef, "reasoning deltas do not surface as content");
    is(scalar @captured, 0, "no control call before 128 new reasoning chars");

    # Second chunk: pushes well past the threshold with a repeating loop
    my ($c2, $t2);
    {
        no warnings 'redefine';
        local *CLIO::Compat::HTTP::request = sub {
            my ($self, $req) = @_;
            push @captured, $req;
            return MockResponse->new(1);
        };
        ($c2, $t2) = feed_reasoning($ss, $LOOP_SENTENCE x 8);
    }
    is($t2, undef, "no tool calls in reasoning deltas");
    is(scalar @captured, 1, "control call fired");

    my $req = $captured[0];
    isa_ok($req, 'HTTP::Request');
    is($req->method, 'POST', "control request is POST");
    is($req->uri->as_string, 'http://localhost:8080/v1/chat/completions/control',
        "control request targets /v1/chat/completions/control");
    is($req->header('Content-Type'), 'application/json', "JSON content type");
    is($req->header('Authorization'), 'Bearer no-key-required', "auth header forwarded");

    my $body = decode_json($req->content);
    is($body->{id}, 'cmpl-1234567890', "control body carries the streaming completion id");
    is($body->{action}, 'reasoning_end', "control body requests reasoning_end");

    like($thinking_seen, qr/forcing end of thinking/,
        "intervention surfaced in the thinking panel");

    # Further looping must not fire again
    feed_reasoning($ss, $LOOP_SENTENCE x 10);
    is(scalar @captured, 1, "control call fires at most once per completion");
};

# =============================================================================
# Section 2: failure path - graceful, disables control URL, no user notice
# =============================================================================
subtest 'failed control call disables recovery without breaking the stream' => sub {
    my $thinking_seen = '';
    my $ss = make_ss(on_thinking => sub { $thinking_seen .= $_[0] });

    {
        no warnings 'redefine';
        local *CLIO::Compat::HTTP::request = sub {
            my ($self, $req) = @_;
            return MockResponse->new(0);
        };
        feed_reasoning($ss, $LOOP_SENTENCE x 8);
    }

    ok(defined $ss->{loop_action_taken} && $ss->{loop_action_taken},
        "loop_action_taken set even when the control call failed");
    ok(!defined $ss->{control_url}, "control URL cleared after failure");
    unlike($thinking_seen, qr/forcing end of thinking/,
        "no user-facing notice on failed control call");
};

# =============================================================================
# Section 3: conditions that must NOT trigger the control call
# =============================================================================
subtest 'no trigger without control url, id, or when not in reasoning' => sub {
    my @captured;
    {
        no warnings 'redefine';
        local *CLIO::Compat::HTTP::request = sub {
            my ($self, $req) = @_;
            push @captured, $req;
            return MockResponse->new(1);
        };

        # Not in reasoning (reasoning_active => 0)
        my $ss = make_ss(reasoning_active => 0);
        feed_reasoning($ss, $LOOP_SENTENCE x 8);
        is(scalar @captured, 0, "no call when reasoning_active is false");

        # No control URL (e.g. endpoint without /chat/completions suffix)
        $ss = make_ss(control_url => undef);
        feed_reasoning($ss, $LOOP_SENTENCE x 8);
        is(scalar @captured, 0, "no call without control URL");

        # No completion id seen yet
        $ss = make_ss(cmpl_id => undef);
        feed_reasoning($ss, $LOOP_SENTENCE x 8);
        is(scalar @captured, 0, "no call before completion id is known");
    }
};

done_testing();

# Mock HTTP response for patched CLIO::Compat::HTTP::request
package MockResponse;
sub new { my ($class, $ok) = @_; return bless { ok => $ok }, $class; }
sub is_success { my $self = shift; return $self->{ok}; }
sub status_line { return '500 Internal Server Error'; }

1;
