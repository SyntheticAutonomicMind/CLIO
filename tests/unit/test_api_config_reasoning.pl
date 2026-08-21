#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Tests for /api config thinking/thinking_effort/thinking_mode validation
# and provider-aware schema dispatch.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More;

use CLIO::Core::Config;
use CLIO::Providers qw(build_endpoint_config list_providers);

# Verify that every provider in the registry has a reasoning_schema
subtest 'all 15 providers have reasoning_schema' => sub {
    my @all = CLIO::Providers::list_providers();
    my $count = 0;
    for my $p (@all) {
        my $ec = build_endpoint_config($p, '');
        ok($ec->{reasoning_schema} && $ec->{reasoning_schema}{mode},
            "Provider '$p' has reasoning_schema.mode");
        $count++;
    }
    is($count, scalar(@all), "Checked $count providers");
};

# Verify schema modes are correct per provider
subtest 'schema modes match provider expectations' => sub {
    my @cases = (
        ['llama.cpp',   'disabled'],
        ['lmstudio',    'disabled'],
        ['ollama_cloud', 'disabled'],
        ['sam',         'disabled'],
        ['anthropic',   'native'],
        ['google',      'native'],
        ['openai',      'effort'],
        ['deepseek',    'effort'],
        ['nvidia',      'effort'],
        ['github_copilot','effort'],
        ['openrouter',  'nested'],
        ['minimax',     'think_object'],
        ['minimax_token', 'think_object'],
        ['zai',         'mixed'],
        ['zai_coding',  'mixed'],
    );
    for my $case (@cases) {
        my ($provider, $expected) = @$case;
        my $ec = build_endpoint_config($provider, '');
        my $actual = $ec->{reasoning_schema}{mode};
        is($actual, $expected, "Provider '$provider' schema mode = $expected");
    }
};

# Verify side-effect flags are correctly set
subtest 'side-effect flags propagate correctly' => sub {
    # DeepSeek: delete_stream_options
    my $ds = build_endpoint_config('deepseek', '')->{reasoning_schema};
    ok($ds->{delete_stream_options}, 'DeepSeek: delete_stream_options=true');

    # Z.AI: delete_stream_options + coding_plan_peak
    my $zai = build_endpoint_config('zai', '')->{reasoning_schema};
    ok($zai->{delete_stream_options}, 'Z.AI: delete_stream_options=true');
    ok($zai->{coding_plan_peak}, 'Z.AI: coding_plan_peak=true');

    # MiniMax: max_tokens_rename + reasoning_split + message_transform
    my $mm = build_endpoint_config('minimax', '')->{reasoning_schema};
    is($mm->{max_tokens_rename}, 'max_completion_tokens', 'MiniMax: max_tokens_rename=max_completion_tokens');
    ok($mm->{reasoning_split}, 'MiniMax: reasoning_split=true');
    is($mm->{message_transform}, 'minimax', 'MiniMax: message_transform=minimax');

    # llama.cpp: disabled mode (no side-effects needed)
    my $lc = build_endpoint_config('llama.cpp', '')->{reasoning_schema};
    is($lc->{mode}, 'disabled', 'llama.cpp: mode=disabled');
};

done_testing();