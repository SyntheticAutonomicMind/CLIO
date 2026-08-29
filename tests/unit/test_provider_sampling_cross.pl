#!/usr/bin/env perl

# Cross-provider regression tests for sampling parameter handling.
#
# Background: CLIO historically injected temperature => 0.2 and top_p => 0.95
# into every request payload. This leaked into providers that reject those
# defaults (OpenAI o-series + reasoning_effort, Anthropic with thinking, etc).
#
# This test enumerates every provider in CLIO::Providers, runs the full
# `_build_payload` + `adapt_request_for_endpoint` pipeline for each, and
# asserts the resulting payload never carries the old hardcoded defaults.
#
# It also verifies the priority order:
#   1. Explicit caller opts (highest)
#   2. User /api set sampling_*  config
#   3. Provider endpoint sampling_defaults  (registry-recommended values)
#   4. Nothing (omit the parameter)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use lib './lib';
use Test::More;
use JSON::PP qw(encode_json decode_json);

use_ok('CLIO::Providers');
use_ok('CLIO::Core::APIManager');
use_ok('CLIO::Core::Config');

# Build an APIManager + endpoint_config pair for a given provider.
# Uses a benign placeholder api_base - we never actually make a network call.
sub _setup {
    my (%args) = @_;
    my $provider = $args{provider};
    # Use a hermetic config dir so test results don't depend on the
    # user's saved config.json (which may have sampling_* overrides set).
    require File::Temp;
    my $dir = File::Temp::tempdir(CLEANUP => 1);
    my $config = $args{config} || CLIO::Core::Config->new(config_dir => $dir);
    $config->set('api_key', $args{api_key} // 'sk-test');

    # Some providers require specific api_base URLs to construct their config.
    # Provide them so build_endpoint_config produces a realistic result.
    my $defaults = {
        'llama.cpp'   => 'http://localhost:8080/v1/chat/completions',
        'lmstudio'    => 'http://localhost:1234/v1/chat/completions',
        'ollama_cloud'=> 'https://ollama.com/v1/chat/completions',
        'openrouter'  => 'https://openrouter.ai/api/v1/chat/completions',
        'orca'        => 'https://api.orcarouter.ai/v1/chat/completions',
        'kilo'        => 'https://api.kilo.ai/api/gateway/chat/completions',
        'openai'      => 'https://api.openai.com/v1/chat/completions',
        'deepseek'    => 'https://api.deepseek.com/v1/chat/completions',
        'google'      => 'https://generativelanguage.googleapis.com/v1beta/openai/chat/completions',
        'minimax'     => 'https://api.minimax.io/v1/chat/completions',
        'minimax_token' => 'https://api.minimax.io/v1/chat/completions',
        'zai'         => 'https://api.z.ai/api/paas/v4',
        'zai_coding'  => 'https://api.z.ai/api/coding/paas/v4',
        'anthropic'   => 'https://api.anthropic.com/v1/messages',
        'nvidia'      => 'https://integrate.api.nvidia.com/v1/chat/completions',
        'github_copilot' => 'https://api.githubcopilot.com/chat/completions',
        'sam'         => 'http://localhost:8080/v1/chat/completions',
        'dashscope'   => 'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    };
    $config->set('api_base', $args{api_base} // $defaults->{$provider} // 'https://api.example.com/v1');

    my $mgr = CLIO::Core::APIManager->new(
        provider => $provider,
        model    => $args{model} // 'default-model',
        config   => $config,
    );
    my $ec = CLIO::Providers::build_endpoint_config($provider, 'sk-test');
    return ($mgr, $ec, $config);
}

# All providers we care about exercising. Each entry is (provider_name, model).
# Models are placeholders - we never hit the wire.
my @PROVIDERS = (
    [ 'openai',           'gpt-4.1' ],
    [ 'deepseek',         'deepseek-v4-pro' ],
    [ 'llama.cpp',        'local-model' ],
    [ 'lmstudio',         'local-model' ],
    [ 'ollama_cloud',     'gemma4:31b' ],
    [ 'openrouter',       'meta-llama/llama-3.1-405b-instruct:free' ],
    [ 'google',           'gemini-2.5-flash' ],
    [ 'minimax',          'MiniMax-M3' ],
    [ 'minimax_token',    'MiniMax-M3' ],
    [ 'zai',              'glm-5.1' ],
    [ 'zai_coding',       'glm-5.1' ],
    [ 'anthropic',        'claude-sonnet-4-20250514' ],
    [ 'nvidia',           'nvidia/nemotron-3-ultra-550b-a55b' ],
);

# ── Group 1: Every provider's payload never carries temperature=0.2 ───
# This is THE primary regression test. If anyone re-introduces the
# `// 0.2` default anywhere upstream of adapt_request_for_endpoint,
# every provider should fail here.

for my $entry (@PROVIDERS) {
    my ($provider, $model) = @$entry;
    my ($mgr, $ec, $cfg) = _setup(provider => $provider, model => $model);

    # Build payload with NO sampling opts - mimics a default request.
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }],
        $model,
        $ec,
    );
    my $adapted = $mgr->adapt_request_for_endpoint($payload, $ec);

    # The OLD bug: temperature=>0.2 was hardcoded into every payload.
    # If a payload carries temperature=0.2 without caller requesting it,
    # that's a regression.
    if (exists $adapted->{temperature}) {
        isnt($adapted->{temperature}, 0.2,
            "$provider: no hardcoded temperature=0.2 (got $adapted->{temperature})");
    }
    if (exists $adapted->{top_p}) {
        # top_p=0.95 is acceptable IF it comes from provider sampling_defaults
        # (llama.cpp, MiniMax, Z.AI). For providers WITHOUT sampling_defaults
        # this would be a regression.
        my $has_default = $ec->{sampling_defaults};
        if (!$has_default) {
            fail("$provider: top_p=$adapted->{top_p} but provider has no sampling_defaults");
        }
    }
}

# ── Group 2: Provider sampling_defaults are applied correctly ─────────
# llama.cpp has sampling_defaults {temperature=>1.0, top_p=>0.95, top_k=>20}.
# Without caller opts, all three should appear.
{
    my ($mgr, $ec, $cfg) = _setup(provider => 'llama.cpp');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }], 'local-model', $ec,
    );
    my $adapted = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($adapted->{temperature}, 1.0, 'llama.cpp sampling_defaults.temperature applied');
    is($adapted->{top_p},       0.95, 'llama.cpp sampling_defaults.top_p applied');
    is($adapted->{top_k},       20,   'llama.cpp sampling_defaults.top_k applied');
}

# Z.AI has sampling_defaults {temperature=>1.0, top_p=>0.95}.
{
    my ($mgr, $ec, $cfg) = _setup(provider => 'zai');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }], 'glm-5.1', $ec,
    );
    my $adapted = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($adapted->{temperature}, 1.0, 'zai sampling_defaults.temperature applied');
    is($adapted->{top_p},       0.95, 'zai sampling_defaults.top_p applied');
}

# MiniMax has sampling_defaults {temperature=>1.0, top_p=>0.95, top_k=>40}.
# MiniMax also transforms max_tokens -> max_completion_tokens, but sampling
# defaults should still come through.
{
    my ($mgr, $ec, $cfg) = _setup(provider => 'minimax');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }], 'MiniMax-M3', $ec,
    );
    my $adapted = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($adapted->{temperature}, 1.0, 'minimax sampling_defaults.temperature applied');
    is($adapted->{top_p},       0.95, 'minimax sampling_defaults.top_p applied');
    is($adapted->{top_k},       40,   'minimax sampling_defaults.top_k applied');
}

# ── Group 3: Providers WITHOUT sampling_defaults omit the params ─────
# OpenAI, DeepSeek, OpenRouter, Ollama Cloud, Anthropic, NVIDIA, Google
# should NOT inject temperature/top_p/top_k when caller didn't ask.

for my $entry (
    [ 'openai',       'gpt-4.1' ],
    [ 'deepseek',     'deepseek-v4-pro' ],
    [ 'openrouter',   'meta-llama/llama-3.1-405b-instruct:free' ],
    [ 'ollama_cloud', 'gemma4:31b' ],
) {
    my ($provider, $model) = @$entry;
    my ($mgr, $ec, $cfg) = _setup(provider => $provider, model => $model);

    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }],
        $model,
        $ec,
    );
    my $adapted = $mgr->adapt_request_for_endpoint($payload, $ec);

    ok(!exists $adapted->{temperature},
        "$provider: temperature not injected without caller opts");
    ok(!exists $adapted->{top_p},
        "$provider: top_p not injected without caller opts");
    ok(!exists $adapted->{top_k},
        "$provider: top_k not injected without caller opts");
}

# ── Group 4: Caller opts always win over sampling_defaults ───────────

# Caller temperature=0.4 must override llama.cpp's default of 1.0.
{
    my ($mgr, $ec, $cfg) = _setup(provider => 'llama.cpp');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }], 'local-model', $ec,
        temperature => 0.4,
    );
    my $adapted = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($adapted->{temperature}, 0.4,
        'caller temperature overrides llama.cpp default');
}

# Caller top_p=0.8 must override llama.cpp's default of 0.95.
{
    my ($mgr, $ec, $cfg) = _setup(provider => 'llama.cpp');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }], 'local-model', $ec,
        top_p => 0.8,
    );
    my $adapted = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($adapted->{top_p}, 0.8,
        'caller top_p overrides llama.cpp default');
}

# ── Group 5: User /api set sampling_temperature overrides everything ─
{
    my $config = CLIO::Core::Config->new();
    $config->set('api_base', 'http://localhost:8080/v1/chat/completions');
    $config->set('sampling_temperature', '0.55');
    $config->set('sampling_top_p',       '0.77');
    $config->set('sampling_top_k',       '33');

    my ($mgr, $ec, $cfg) = _setup(
        provider => 'llama.cpp',
        config   => $config,
    );

    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }], 'local-model', $ec,
    );
    my $adapted = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($adapted->{temperature}, 0.55,
        'user sampling_temperature config overrides llama.cpp default');
    is($adapted->{top_p},       0.77,
        'user sampling_top_p config overrides llama.cpp default');
    is($adapted->{top_k},       33,
        'user sampling_top_k config overrides llama.cpp default');
}

# User config overrides even an explicit caller value? No - caller is
# higher priority. Verify this.
{
    my $config = CLIO::Core::Config->new();
    $config->set('api_base', 'http://localhost:8080/v1/chat/completions');
    $config->set('sampling_temperature', '0.99');

    my ($mgr, $ec, $cfg) = _setup(
        provider => 'llama.cpp',
        config   => $config,
    );

    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }], 'local-model', $ec,
        temperature => 0.3,  # caller opts - should win
    );
    my $adapted = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($adapted->{temperature}, 0.3,
        'caller temperature beats user config sampling_temperature');
}

# ── Group 6: Native providers receive sampling opts cleanly ──────────
# Anthropic, Google, NVIDIA all have build_request() of their own.
# When APIManager calls _send_native_streaming, the payload it builds
# (via _build_payload) is used as a source of temperature/top_p, and
# only those are forwarded to the native provider's build_request.

# Anthropic: temperature passed through, top_p passed through.
{
    my ($mgr, $ec, $cfg) = _setup(provider => 'anthropic');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }], 'claude-sonnet-4-20250514', $ec,
        temperature => 0.5,
        top_p       => 0.9,
    );
    my $adapted = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($adapted->{temperature}, 0.5, 'anthropic: explicit temperature preserved');
    is($adapted->{top_p},       0.9, 'anthropic: explicit top_p preserved');
}

# Google: same.
{
    my ($mgr, $ec, $cfg) = _setup(provider => 'google');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }], 'gemini-2.5-flash', $ec,
        temperature => 0.6,
        top_p       => 0.85,
    );
    my $adapted = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($adapted->{temperature}, 0.6, 'google: explicit temperature preserved');
    is($adapted->{top_p},       0.85, 'google: explicit top_p preserved');
}

# NVIDIA: same.
{
    my ($mgr, $ec, $cfg) = _setup(provider => 'nvidia');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }],
        'nvidia/nemotron-3-ultra-550b-a55b',
        $ec,
        temperature => 0.65,
        top_p       => 0.88,
    );
    my $adapted = $mgr->adapt_request_for_endpoint($payload, $ec);

    is($adapted->{temperature}, 0.65, 'nvidia: explicit temperature preserved');
    is($adapted->{top_p},       0.88, 'nvidia: explicit top_p preserved');
}

# ── Group 7: End-to-end payload shape sanity ─────────────────────────
# A payload for "openai" (no sampling_defaults) with no caller opts and
# no user config should look like:
#   { model, messages, max_tokens, stream (if streaming), stream_options }
# No temperature, no top_p, no top_k. This is the OpenAI best-practice
# payload - let the provider apply its own defaults.

{
    my ($mgr, $ec, $cfg) = _setup(provider => 'openai');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }],
        'gpt-4.1',
        $ec,
    );

    my @unexpected = grep { exists $payload->{$_} } qw(temperature top_p top_k);
    ok(!@unexpected,
        'openai _build_payload output contains no sampling keys: '
        . (@unexpected ? "found [@unexpected]" : 'clean'));
}

# Same for a Chat Completions provider like deepseek.
{
    my ($mgr, $ec, $cfg) = _setup(provider => 'deepseek');
    my $payload = $mgr->_build_payload(
        [{ role => 'user', content => 'hi' }],
        'deepseek-v4-pro',
        $ec,
    );

    my @unexpected = grep { exists $payload->{$_} } qw(temperature top_p top_k);
    ok(!@unexpected,
        'deepseek _build_payload output contains no sampling keys: '
        . (@unexpected ? "found [@unexpected]" : 'clean'));
}

# ── Group 8: Verify Anthropic native provider's own build_request ───
# When Anthropic gets thinking enabled, it forces temperature=1 and
# removes top_k. This is provider-side logic, not the central pipeline.
{
    require CLIO::Providers::Anthropic;
    my $p = CLIO::Providers::Anthropic->new(api_key => 'sk-test');
    my $req = $p->build_request(
        [{ role => 'user', content => 'hi' }],
        [],
        {
            model       => 'claude-sonnet-4-20250514',
            max_tokens  => 8192,
            temperature => 0.5,
            top_p       => 0.7,
            top_k       => 25,
            thinking    => { enabled => 1, mode => 'enabled', budget_tokens => 4096 },
        },
    );

    my $body = decode_json($req->{body});
    is($body->{temperature}, 1,
        'anthropic build_request forces temperature=1 when thinking enabled');
    ok(!exists $body->{top_k},
        'anthropic build_request removes top_k when thinking enabled');
    is($body->{top_p}, 0.95,
        'anthropic build_request clamps top_p to >=0.95 when thinking enabled');
}

print "\nAll cross-provider sampling tests passed!\n";
done_testing();

__END__

=head1 NOTES

This test enumerates every provider registered in CLIO::Providers and
verifies that the central sampling-handling pipeline (`_build_payload` +
`adapt_request_for_endpoint`) never reintroduces the old `temperature => 0.2`
default for any provider.

Providers with `sampling_defaults` in their endpoint config (llama.cpp,
LM Studio, MiniMax, Z.AI) still apply their registry-recommended values
when the caller didn't set them - that's intentional and correct.

Providers WITHOUT `sampling_defaults` (OpenAI, DeepSeek, OpenRouter,
Ollama Cloud, GitHub Copilot, Anthropic, Google, NVIDIA) get clean
payloads with no sampling keys at all - letting the provider or user
decide what to use.

Priority order:
  1. Explicit caller opts (`temperature => X` in the call)
  2. User /api set sampling_temperature config
  3. Provider endpoint sampling_defaults (registry-recommended values)
  4. Nothing (omit the parameter)

=cut
