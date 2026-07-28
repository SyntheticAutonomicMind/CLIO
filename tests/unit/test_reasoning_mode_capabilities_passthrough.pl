#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only

# Regression: CLIO::Core::APIManager.get_model_capabilities dropped
# reasoning_mode from its normalized capabilities hash. That made
# _get_reasoning_mode() return undef for every model, which silently
# disabled every adapt_request_for_endpoint code path that gated on it:
#
#   - OpenAI / DeepSeek / NVIDIA / Copilot -> reasoning_effort never sent
#   - MiniMax adaptive models (M3)        -> thinking.type never sent
#   - Z.AI                                -> thinking.type never sent
#
# Symptom at the user level: MiniMax-M3 with thinking_mode=enabled and
# show_thinking=1 still produced brief "garbage" thinking at the start of
# every session because the API call went out without any thinking.type
# parameter, leaving M3's default (adaptive) in charge. Andrew had been
# chasing this for several sessions.
#
# Companion fix: MiniMax adaptive models that DO receive a thinking.type
# signal now honor an explicit user thinking_mode=enabled by emitting
# thinking.type=enabled (always-on) instead of the model's preferred
# adaptive mode. Adaptive mode reliably gives back one-line summaries at
# session start; enabled forces the model through every response.
#
# These tests verify:
#   1. get_model_capabilities returns reasoning_mode in its normalized hash.
#   2. _get_reasoning_mode() returns 'adaptive' for MiniMax-M3, 'enabled'
#      for MiniMax-M2.x, 'effort' for DeepSeek V4 / NVIDIA nemotron.
#   3. MiniMax adaptive + user thinking_mode=enabled -> thinking.type=enabled.
#   4. MiniMax adaptive + user thinking_mode=auto + show_thinking=1
#      -> thinking.type=adaptive (default preserved).
#   5. MiniMax adaptive + user thinking_mode=disabled -> thinking.type=disabled.
#   6. MiniMax enabled-capability (M2.x) is unaffected by the user override
#      (always emits type=enabled).
#   7. OpenAI-compat reasoning_effort is emitted for DeepSeek V4 when
#      thinking_mode=auto + show_thinking=1.
#
# All tests run without an API key or network access.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use Test::More;
use File::Temp;
use CLIO::Util::JSON qw(encode_json);
use CLIO::Core::APIManager;
use CLIO::Core::Config;
use CLIO::Providers;

# Hermetic config so the user's saved config.json does not pollute results.
my $tmpdir = File::Temp::tempdir(CLEANUP => 1);

sub _make {
    my (%args) = @_;
    my $config = CLIO::Core::Config->new(config_dir => $tmpdir);
    $config->set('api_base', $args{api_base} // 'https://api.example.com/v1');
    $config->set('api_keys', { ($args{provider} // 'openai') => 'sk-test' });
    $config->set('model',    $args{model});
    $config->set('provider', $args{provider});
    if (exists $args{show_thinking}) {
        $config->set('show_thinking', $args{show_thinking});
    }
    if (exists $args{thinking_mode}) {
        $config->set('thinking_mode', $args{thinking_mode});
    }
    if (exists $args{thinking_effort}) {
        $config->set('thinking_effort', $args{thinking_effort});
    }
    my $mgr = CLIO::Core::APIManager->new(
        provider => $args{provider},
        model    => $args{model},
        config   => $config,
    );
    my $ec = CLIO::Providers::build_endpoint_config($args{provider}, 'sk-test');
    $ec->{$_} = 1 for @{$args{minimax_marker} // []};
    return ($mgr, $ec);
}

sub _build {
    my (%args) = @_;
    my ($mgr, $ec) = _make(%args);
    return $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }],
        $args{model},
        $ec,
    );
}

# ─────────────────────────────────────────────────────────────────────────
# Section 1: get_model_capabilities passes reasoning_mode through.
# This is the root fix; everything downstream depends on it.
# ─────────────────────────────────────────────────────────────────────────

subtest 'get_model_capabilities returns reasoning_mode in normalized hash' => sub {
    my ($mgr) = _make(provider => 'minimax', model => 'minimax/MiniMax-M3');
    my $caps = $mgr->get_model_capabilities('minimax/MiniMax-M3');
    ok($caps, 'caps returned for MiniMax-M3');
    is($caps->{reasoning_mode}, 'adaptive',
        'MiniMax-M3 normalized caps include reasoning_mode=adaptive');
    is($caps->{supports_reasoning}, 1,
        'MiniMax-M3 normalized caps include supports_reasoning=1');
};

subtest '_get_reasoning_mode returns correct value for each provider' => sub {
    my @cases = (
        ['minimax/MiniMax-M3',                          'minimax', 'adaptive'],
        ['minimax/MiniMax-M2.7',                        'minimax', 'enabled'],
        ['deepseek/deepseek-v4-pro',                    'deepseek', 'effort'],
        ['nvidia/nemotron-3-ultra-550b-a55b',           'nvidia', 'effort'],
    );
    for my $case (@cases) {
        my ($model, $provider, $expected) = @$case;
        my ($mgr) = _make(provider => $provider, model => $model);
        my $rm = $mgr->_get_reasoning_mode($model);
        is($rm, $expected, "$model -> $expected");
    }
};

# ─────────────────────────────────────────────────────────────────────────
# Section 2: MiniMax thinking.type selection
# ─────────────────────────────────────────────────────────────────────────

subtest 'M3 + user thinking_mode=enabled -> thinking.type=enabled (override)' => sub {
    my $payload = _build(
        provider      => 'minimax',
        model         => 'minimax/MiniMax-M3',
        api_base      => 'https://api.minimax.io/v1',
        minimax_marker => ['minimax'],
        thinking_mode => 'enabled',
        show_thinking => 1,
    );
    is_deeply($payload->{thinking}, { type => 'enabled' },
        'MiniMax-M3: explicit thinking_mode=enabled forces thinking.type=enabled');
};

subtest 'M3 + thinking_mode=auto + show_thinking=1 -> thinking.type=adaptive (default preserved)' => sub {
    my $payload = _build(
        provider      => 'minimax',
        model         => 'minimax/MiniMax-M3',
        api_base      => 'https://api.minimax.io/v1',
        minimax_marker => ['minimax'],
        thinking_mode => 'auto',
        show_thinking => 1,
    );
    is_deeply($payload->{thinking}, { type => 'adaptive' },
        'MiniMax-M3: thinking_mode=auto + show_thinking=1 keeps adaptive default');
};

subtest 'M3 + thinking_mode=disabled -> thinking.type=disabled' => sub {
    my $payload = _build(
        provider      => 'minimax',
        model         => 'minimax/MiniMax-M3',
        api_base      => 'https://api.minimax.io/v1',
        minimax_marker => ['minimax'],
        thinking_mode => 'disabled',
        show_thinking => 1,
    );
    is_deeply($payload->{thinking}, { type => 'disabled' },
        'MiniMax-M3: thinking_mode=disabled sends type=disabled');
};

subtest 'M3 + thinking_mode=auto + show_thinking=0 -> no thinking.type' => sub {
    my $payload = _build(
        provider      => 'minimax',
        model         => 'minimax/MiniMax-M3',
        api_base      => 'https://api.minimax.io/v1',
        minimax_marker => ['minimax'],
        thinking_mode => 'auto',
        show_thinking => 0,
    );
    # MiniMax payload always sets a thinking field (the provider
    # requires it: absent field would mean "default" which is
    # unknown per docs). When thinking is off we explicitly emit
    # type=disabled.
    is_deeply($payload->{thinking}, { type => 'disabled' },
        'MiniMax-M3: auto + show=0 -> thinking.type=disabled');
};

subtest 'M2.7 + thinking_mode=auto + show_thinking=1 -> thinking.type=enabled' => sub {
    # M2.x has reasoning_mode=enabled (not adaptive), so behavior is
    # unaffected by the user-override branch.
    my $payload = _build(
        provider      => 'minimax',
        model         => 'minimax/MiniMax-M2.7',
        api_base      => 'https://api.minimax.io/v1',
        minimax_marker => ['minimax'],
        thinking_mode => 'auto',
        show_thinking => 1,
    );
    is_deeply($payload->{thinking}, { type => 'enabled' },
        'MiniMax-M2.7 (enabled model) keeps type=enabled');
};

subtest 'MiniMax payload always sets reasoning_split=true' => sub {
    my $payload = _build(
        provider      => 'minimax',
        model         => 'minimax/MiniMax-M3',
        api_base      => 'https://api.minimax.io/v1',
        minimax_marker => ['minimax'],
        thinking_mode => 'enabled',
    );
    # JSON true lands in the hash as the string "true" because of \$1
    # in the source; decode-compare instead.
    # JSON true in the source is a scalar ref to 1; two refs to the
    # same value compare unequal as refs, so deref and compare.
    is(${ $payload->{reasoning_split} }, 1,
        'MiniMax payloads always carry reasoning_split=true');
};

# ─────────────────────────────────────────────────────────────────────────
# Section 3: OpenAI-compat reasoning_effort activation
# ─────────────────────────────────────────────────────────────────────────

subtest 'DeepSeek v4-pro + auto + show_thinking=1 -> reasoning_effort=high' => sub {
    # This was dead code before the cap-passthrough fix.
    my $payload = _build(
        provider      => 'deepseek',
        model         => 'deepseek/deepseek-v4-pro',
        api_base      => 'https://api.deepseek.com/v1',
        thinking_mode => 'auto',
        show_thinking => 1,
        thinking_effort => 'high',
    );
    is($payload->{reasoning_effort}, 'high',
        'DeepSeek V4 / auto / show=1 -> reasoning_effort=high');
};

subtest 'DeepSeek v4-pro + thinking_mode=disabled -> no reasoning_effort' => sub {
    my $payload = _build(
        provider      => 'deepseek',
        model         => 'deepseek/deepseek-v4-pro',
        api_base      => 'https://api.deepseek.com/v1',
        thinking_mode => 'disabled',
        show_thinking => 1,
    );
    is($payload->{reasoning_effort}, undef,
        'DeepSeek V4 / disabled -> no reasoning_effort');
};

done_testing();
