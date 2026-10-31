#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-or-later
# Tests for reasoning repetition loop detection and llama.cpp loop
# recovery wiring: detector thresholds, false-positive resistance, and
# the reasoning_control payload arming.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use lib "$RealBin/../lib";
use Test::More;

use CLIO::Core::ReasoningLoopDetector;
use CLIO::Providers qw(build_endpoint_config);

# =============================================================================
# Section 1: Detector basics
# =============================================================================
subtest 'detector ignores non-looping text' => sub {
    my $d = CLIO::Core::ReasoningLoopDetector->new();

    is($d->check(\""), 0, "empty buffer");
    is($d->check(\"Some normal reasoning that continues on and on with varied sentence structure."), 0,
        "normal varied text");
    is($d->check(undef), 0, "undef ref");

    my $short_repeat = "let me check the merge commit again. ";
    is($d->check($short_repeat x 5), 0, "short repeat under min_cycle_length is ignored");
};

subtest 'detector triggers on sentence-level loops' => sub {
    my $d = CLIO::Core::ReasoningLoopDetector->new();

    # A ~120 char sentence repeated 3x must trigger; 2x must not.
    my $sentence = "But wait, the merge commit was created by git merge master with the ort strategy which performed a 3-way merge. ";
    ok(length($sentence) >= 40, "sentence is above min_cycle_length");
    is($d->check($sentence x 2), 0, "2 repeats do not trigger");
    ok($d->check($sentence x 3), "3 repeats trigger");
    ok($d->check($sentence x 20), "20 repeats trigger (realistic loop)");
};

subtest 'detector triggers on paragraph-level loops' => sub {
    my $d = CLIO::Core::ReasoningLoopDetector->new();

    my $para = "Actually, I think the issue is that the merge commit was created by git merge master with the ort strategy, "
             . "which performed a 3-way merge. The merge resolved conflicts automatically, and some conflicts might "
             . "have been resolved manually. But the user said to always take ours, so the merge should have taken "
             . "our version for all conflicting files.\n\n";
    ok($d->check($para x 3), "3 paragraph repeats trigger");
    ok($d->check($para x 10), "10 paragraph repeats trigger");
};

subtest 'detector catches loops with a pre-loop prefix' => sub {
    my $d = CLIO::Core::ReasoningLoopDetector->new();
    my $prefix = "Let me analyze the git history of this repository to understand the merge structure.\n\n";
    my $loop = "Wait, but the ort strategy resolves conflicts by taking the version from the branch being merged into. " x 6;
    ok($d->check($prefix . $loop), "loop after legitimate prefix triggers");
};

subtest 'detector returns the cycle length' => sub {
    my $d = CLIO::Core::ReasoningLoopDetector->new();
    my $sentence = "The ort strategy resolves conflicts by taking the version from the branch being merged into, the unstable branch. ";
    my $cycle_len = $d->check($sentence x 5);
    ok($cycle_len == length($sentence), "cycle length equals repeated block length");
};

subtest 'custom thresholds' => sub {
    my $d = CLIO::Core::ReasoningLoopDetector->new(min_cycle_length => 100, min_cycles => 4);
    my $sentence = "But wait, the merge commit was created by git merge master with the ort strategy which performed a 3-way merge. ";
    is($d->check($sentence x 3), 0, "3 repeats do not trigger with min_cycles=4");
    ok($d->check($sentence x 4), "4 repeats trigger with min_cycles=4");
};

# =============================================================================
# Section 2: llama.cpp endpoint config wiring
# =============================================================================
subtest 'llama.cpp endpoint arms reasoning_control' => sub {
    my $cfg = build_endpoint_config('llama.cpp', undef);

    ok($cfg->{reasoning_control}, "llama.cpp arms reasoning_control");
    ok($cfg->{exposes_props}, "llama.cpp exposes_props (gates arming)");

    # Simulate the APIManager arming block: JSON boolean required -
    # the server warns (json.exception.type_error.302) and falls back
    # to false when reasoning_control arrives as a number.
    my $payload = {};
    if ($cfg->{exposes_props} && $cfg->{reasoning_control} && !$payload->{reasoning_control}) {
        $payload->{reasoning_control} = \1;
    }
    use CLIO::Util::JSON qw(encode_json);
    like(encode_json($payload), qr/"reasoning_control":true/,
        "armed value encodes as JSON boolean true (not number)");
};

subtest 'other providers do not arm reasoning_control' => sub {
    for my $provider ('openai', 'anthropic', 'deepseek') {
        my $cfg = build_endpoint_config($provider, 'test-key');
        ok(!$cfg->{reasoning_control}, "$provider does not arm reasoning_control");
        ok(!$cfg->{exposes_props}, "$provider does not expose_props");
    }
};

# =============================================================================
# Section 3: reasoning_control arming reaches the payload
# =============================================================================
subtest 'reasoning_control arming applies to llama.cpp payloads' => sub {
    require CLIO::Core::APIManager;
    require CLIO::Core::Config;

    my $endpoint = build_endpoint_config('llama.cpp', 'test-key');
    my $config = CLIO::Core::Config->new();
    $config->{config}{llamacpp_reasoning_control} = 1;
    my $api = bless { config => $config, session => undef }, 'CLIO::Core::APIManager';

    my $payload = $api->_build_payload(
        [ { role => 'user', content => 'test' } ], 'local-model', $endpoint);
    is($payload->{temperature}, 0.7, "regular sampling defaults still apply");
    ok(defined $payload->{reasoning_control} && ref($payload->{reasoning_control}) eq 'SCALAR'
        && ${$payload->{reasoning_control}} == 1,
        "reasoning_control armed as JSON true");
};

subtest 'LM Studio exposes props but has no control endpoint' => sub {
    my $cfg = build_endpoint_config('lmstudio', undef);
    ok($cfg->{exposes_props}, "lmstudio exposes_props");
    ok(!$cfg->{reasoning_control}, "lmstudio does NOT arm reasoning_control (no control endpoint)");
};

done_testing();
