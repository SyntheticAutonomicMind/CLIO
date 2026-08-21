#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Test all 12 combinations of thinking_mode (3) x show_thinking (2)
# x reasoning_mode supported (2) for effort-mode providers.

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More;

use CLIO::Core::APIManager;
use CLIO::Providers qw(build_endpoint_config);

package FakeConfig {
    sub new { my ($cls, %o) = @_; bless { %o }, $cls }
    sub get { my ($self, $k) = @_; return $self->{$k} }
}

package main;

my $am = bless { debug => 0, config => undef, api_base => 'https://x' }, 'CLIO::Core::APIManager';

no warnings 'redefine';
*CLIO::Core::APIManager::_get_reasoning_mode = sub {
    my ($self, $model) = @_;
    return 'effort' if $model && $model eq 'gpt-5-reasoning';
    return undef;
};
*CLIO::Core::APIManager::_model_supports_reasoning = sub { 1 };

sub _run {
    my ($mode, $show, $model, $provider) = @_;
    $provider //= 'openai';
    my $ec = build_endpoint_config($provider, 'test-key');
    $am->{config} = FakeConfig->new(
        thinking_mode   => $mode,
        show_thinking   => $show,
        thinking_effort => 'high',
    );
    my $payload = { model => $model, messages => [] };
    $am->adapt_request_for_endpoint($payload, $ec);
    return $payload;
}

# === 12 combos with reasoning-capable model ===
{   my $p = _run('enabled', 1, 'gpt-5-reasoning');
    is($p->{reasoning_effort}, 'high', 'enabled/show=1/supports: reasoning_effort sent');
}
{   my $p = _run('enabled', 0, 'gpt-5-reasoning');
    is($p->{reasoning_effort}, 'high', 'enabled/show=0/supports: sent (show irrelevant)');
}
{   my $p = _run('auto', 1, 'gpt-5-reasoning');
    is($p->{reasoning_effort}, 'high', 'auto/show=1/supports: reasoning_effort sent');
}
{   my $p = _run('auto', 0, 'gpt-5-reasoning');
    ok(!exists $p->{reasoning_effort}, 'auto/show=0/supports: NOT sent');
}
{   my $p = _run('disabled', 1, 'gpt-5-reasoning');
    ok(!exists $p->{reasoning_effort}, 'disabled/show=1/supports: NOT sent');
}
{   my $p = _run('disabled', 0, 'gpt-5-reasoning');
    ok(!exists $p->{reasoning_effort}, 'disabled/show=0/supports: NOT sent');
}

# === 6 combos with non-reasoning model ===
{   my $p = _run('enabled', 1, 'gpt-5');
    ok(!exists $p->{reasoning_effort}, 'enabled/show=1/!supports: NOT sent');
}
{   my $p = _run('enabled', 0, 'gpt-5');
    ok(!exists $p->{reasoning_effort}, 'enabled/show=0/!supports: NOT sent');
}
{   my $p = _run('auto', 1, 'gpt-5');
    ok(!exists $p->{reasoning_effort}, 'auto/show=1/!supports: NOT sent');
}
{   my $p = _run('disabled', 1, 'gpt-5');
    ok(!exists $p->{reasoning_effort}, 'disabled/show=1/!supports: NOT sent');
}
{   my $p = _run('disabled', 0, 'gpt-5');
    ok(!exists $p->{reasoning_effort}, 'disabled/show=0/!supports: NOT sent');
}

# === Effort value fallback for OpenRouter (nested mode) ===
{   my $p = _run('enabled', 1, 'openrouter/claude-3.7-sonnet', 'openrouter');
    is($p->{reasoning}{effort}, 'high', 'OpenRouter: valid effort passes through');
    ok(!exists $p->{reasoning}{max_tokens}, 'OpenRouter: no max_tokens');
}

done_testing();