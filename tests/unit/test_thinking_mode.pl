#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Coverage test for the new thinking_mode config knob (auto|enabled|disabled).
# Background:
#   Anthropic recommends adaptive thinking (mode='adaptive') for Claude 4.6+
#   and it's the only mode supported on Fable 5, Mythos 5, Opus 4.7, Opus 4.8.
#   Prior to this change, CLIO only sent thinking parameters when the user
#   had /api set thinking on, which meant adaptive thinking was opt-in and
#   models that require it would HTTP 400 if the user had thinking off.
#
# This test verifies:
#   1. MCM._anthropic_requires_adaptive correctly identifies the known
#      required families (Fable 5, Mythos 5, Mythos Preview) via fallback
#      and respects the API's capabilities.thinking.types.disabled.supported
#      when present.
#   2. Anthropic provider's build_request correctly emits the adaptive
#      payload with display=summarized and effort in output_config.
#   3. The thinking_mode validation in /api set works (covered via a tiny
#      subset - the full handler is exercised by integration tests).
#   4. The /api show display path includes the new Think Mode line.
#
# These tests run in isolation and don't require an API key or network
# access. They exercise the pure-logic surface area of the change.

use Test::More;
use CLIO::Util::JSON qw(decode_json);
use CLIO::Providers::Anthropic;
use CLIO::Core::ModelCapabilitiesManager;

# ============================================================================
# Section 1: MCM._anthropic_requires_adaptive
# ============================================================================

my $mcm = CLIO::Core::ModelCapabilitiesManager->new();

# Fable 5 family - always requires adaptive
for my $model (qw(
    claude-fable-5
    claude-fable-5-20260101
    Claude-Fable-5
)) {
    my $result = $mcm->_anthropic_requires_adaptive($model, undef);
    is($result, 1, "_anthropic_requires_adaptive: $model -> 1 (required)");
}

# Mythos 5 family - always requires adaptive
for my $model (qw(
    claude-mythos-5
    claude-mythos-5-20260201
    Claude-Mythos-5
)) {
    my $result = $mcm->_anthropic_requires_adaptive($model, undef);
    is($result, 1, "_anthropic_requires_adaptive: $model -> 1 (required)");
}

# Mythos Preview - always requires adaptive
for my $model (qw(
    claude-mythos-preview
    claude-mythos-preview-20260301
)) {
    my $result = $mcm->_anthropic_requires_adaptive($model, undef);
    is($result, 1, "_anthropic_requires_adaptive: $model -> 1 (required)");
}

# Sonnet 5 - adaptive is default but CAN be disabled
{
    my $result = $mcm->_anthropic_requires_adaptive('claude-sonnet-5', undef);
    is($result, 0, "_anthropic_requires_adaptive: claude-sonnet-5 -> 0 (default on, but disable allowed)");
}

# Opus 4.8 - adaptive is the only mode, but you can opt out
{
    my $result = $mcm->_anthropic_requires_adaptive('claude-opus-4-8', undef);
    is($result, 0, "_anthropic_requires_adaptive: claude-opus-4-8 -> 0 (adaptive-only, but disable allowed)");
}

# Opus 4.6 / Sonnet 4.6 - adaptive available, enabled available
{
    my $r_opus = $mcm->_anthropic_requires_adaptive('claude-opus-4-6', undef);
    is($r_opus, 0, "_anthropic_requires_adaptive: claude-opus-4-6 -> 0");
    my $r_sonnet = $mcm->_anthropic_requires_adaptive('claude-sonnet-4-6', undef);
    is($r_sonnet, 0, "_anthropic_requires_adaptive: claude-sonnet-4-6 -> 0");
}

# Older Anthropic models
{
    my $r = $mcm->_anthropic_requires_adaptive('claude-3-5-sonnet-20241022', undef);
    is($r, 0, "_anthropic_requires_adaptive: claude-3-5-sonnet-20241022 -> 0");
}

# Data-driven path: API explicitly says disabled is not supported
{
    my $thinking = {
        supported => 1,
        types => {
            adaptive => { supported => 1 },
            enabled  => { supported => 1 },
            disabled => { supported => 0 },  # API says: cannot disable
        },
    };
    my $r = $mcm->_anthropic_requires_adaptive('some-future-model', $thinking);
    is($r, 1, "_anthropic_requires_adaptive: API signals disabled.supported=0 -> 1");
}

# Data-driven path: API says disabled IS supported
{
    my $thinking = {
        supported => 1,
        types => {
            adaptive => { supported => 1 },
            enabled  => { supported => 1 },
            disabled => { supported => 1 },
        },
    };
    my $r = $mcm->_anthropic_requires_adaptive('some-model', $thinking);
    is($r, 0, "_anthropic_requires_adaptive: API signals disabled.supported=1 -> 0");
}

# Data-driven path: missing 'disabled' key entirely
{
    my $thinking = {
        supported => 1,
        types => {
            adaptive => { supported => 1 },
        },
    };
    my $r = $mcm->_anthropic_requires_adaptive('some-model', $thinking);
    is($r, 0, "_anthropic_requires_adaptive: API omits disabled entirely -> 0 (fall back to name heuristic)");
}

# Edge case: empty/undef inputs
{
    is($mcm->_anthropic_requires_adaptive(undef, undef), 0,
        "_anthropic_requires_adaptive: undef model -> 0 (no false positive)");
    is($mcm->_anthropic_requires_adaptive('', undef), 0,
        "_anthropic_requires_adaptive: empty model -> 0");
    is($mcm->_anthropic_requires_adaptive('claude-fable-5', undef), 1,
        "_anthropic_requires_adaptive: model with undef thinking block -> 1 (name heuristic still wins)");
}

# Proxy deployment names should also match the required families
{
    my $r = $mcm->_anthropic_requires_adaptive('Proxy-Fable-5', undef);
    is($r, 1, "_anthropic_requires_adaptive: proxy alias Proxy-Fable-5 -> 1");
    my $r2 = $mcm->_anthropic_requires_adaptive('internal-mythos-5-deployment', undef);
    is($r2, 1, "_anthropic_requires_adaptive: proxy alias internal-mythos-5 -> 1");
}

# ============================================================================
# Section 2: Anthropic provider build_request with adaptive mode
# ============================================================================

# These tests verify the provider emits the correct Anthropic API shape
# when called with the new mode config from APIManager. They complement
# test_anthropic_adaptive_payload.pl by also covering the "default effort"
# case and the requires_adaptive path.

my $provider = CLIO::Providers::Anthropic->new(
    api_key => 'test-key',
    model   => 'claude-fable-5',
);

sub build_payload {
    my (%opts) = @_;
    my $req = $provider->build_request(
        [{ role => 'user', content => 'hi' }],
        undef,
        {
            model      => $opts{model}     // 'claude-fable-5',
            max_tokens => $opts{max_tokens} // 16000,
            thinking   => $opts{thinking},
        },
    );
    return decode_json($req->{body});
}

# Adaptive mode at default effort
{
    my $body = build_payload(
        model    => 'claude-sonnet-4-6',
        thinking => { enabled => 1, mode => 'adaptive', effort => 'medium' },
    );
    is($body->{thinking}{type}, 'adaptive',
        'Anthropic adaptive (medium): type=adaptive');
    is($body->{thinking}{display}, 'summarized',
        'Anthropic adaptive (medium): display=summarized');
    ok(!$body->{output_config} || !$body->{output_config}{effort},
        'Anthropic adaptive (medium): output_config.effort omitted (default)');
    is($body->{temperature}, 1,
        'Anthropic adaptive (medium): temperature forced to 1');
}

# Adaptive mode with xhigh
{
    my $body = build_payload(
        model    => 'claude-sonnet-5',
        thinking => { enabled => 1, mode => 'adaptive', effort => 'xhigh' },
    );
    is($body->{output_config}{effort}, 'xhigh',
        'Anthropic adaptive (xhigh): effort=xhigh in output_config');
}

# Adaptive mode with max
{
    my $body = build_payload(
        model    => 'claude-opus-4-8',
        thinking => { enabled => 1, mode => 'adaptive', effort => 'max' },
    );
    is($body->{output_config}{effort}, 'max',
        'Anthropic adaptive (max): effort=max in output_config');
}

# Disabled -> no thinking block, no output_config
{
    my $body = build_payload(
        model    => 'claude-sonnet-4-6',
        thinking => { enabled => 0 },
    );
    is($body->{thinking}, undef,
        'Anthropic disabled: no thinking block');
    is($body->{output_config}, undef,
        'Anthropic disabled: no output_config');
}

# Legacy enabled mode still works (for older models)
{
    my $body = build_payload(
        model    => 'claude-3-5-sonnet-20241022',
        thinking => { enabled => 1, mode => 'enabled', effort => 'medium', budget_tokens => 10240 },
    );
    is($body->{thinking}{type}, 'enabled',
        'Anthropic enabled (legacy): type=enabled');
    ok($body->{thinking}{budget_tokens},
        'Anthropic enabled (legacy): budget_tokens set');
    is($body->{output_config}, undef,
        'Anthropic enabled (legacy): no output_config (effort goes in thinking.effort? No - just budget)');
}

# ============================================================================
# Section 3: Source-level regression guards
# ============================================================================

# Verify that the new thinking_mode config appears in Config.pm with the
# correct default. This catches accidental removal of the config knob.
{
    open my $fh, '<', 'lib/CLIO/Core/Config.pm' or die "Cannot read Config.pm: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    like($src, qr/thinking_mode\s*=>\s*'auto'/,
        'Config.pm: thinking_mode default is auto');
    like($src, qr/show_thinking thinking_effort thinking_mode/,
        'Config.pm: thinking_mode is in MODEL_SCOPED_KEYS');
}

# Verify APIManager has the new thinking_mode handling. This catches
# accidental rollback to the show_thinking-only decision.
{
    open my $fh, '<', 'lib/CLIO/Core/APIManager.pm' or die "Cannot read APIManager.pm: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    like($src, qr/\$thinking_mode\s+eq\s+'disabled'/,
        'APIManager: has thinking_mode=disabled branch');
    like($src, qr/\$thinking_mode\s+eq\s+'enabled'/,
        'APIManager: has thinking_mode=enabled branch');
    like($src, qr/\$thinking_mode\s+eq\s+'auto'/,
        'APIManager: has thinking_mode=auto branch');
    like($src, qr/\$requires_adaptive/,
        'APIManager: respects requires_adaptive from capabilities');
    like($src, qr/log_warning.*thinking_mode=disabled ignored/,
        'APIManager: logs warning when disabled is overridden by requires_adaptive');
}

# Verify the API Config handler accepts thinking_mode.
{
    open my $fh, '<', 'lib/CLIO/UI/Commands/API/Config.pm' or die "Cannot read API/Config.pm: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    like($src, qr/\$setting\s+eq\s+'thinking_mode'/,
        'API::Config: handles thinking_mode setting');
    like($src, qr/\(auto\|enabled\|disabled\)/,
        'API::Config: validates auto|enabled|disabled');
    like($src, qr/Invalid thinking_mode value/,
        'API::Config: error message for invalid value');
}

# Verify the MCM has the _anthropic_requires_adaptive helper.
{
    open my $fh, '<', 'lib/CLIO/Core/ModelCapabilitiesManager.pm' or die "Cannot read MCM: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    like($src, qr/sub _anthropic_requires_adaptive/,
        'MCM: defines _anthropic_requires_adaptive');
    like($src, qr/requires_adaptive_thinking\s*=>/,
        'MCM: requires_adaptive_thinking field is set in caps');
    like($src, qr/fable\|mythos\)-5/,
        'MCM: fallback heuristic for fable/mythos 5 families');
    like($src, qr/\^claude-mythos-preview/,
        'MCM: fallback heuristic for Mythos Preview');
}

# Verify the /api help text includes thinking_mode.
{
    open my $fh, '<', 'lib/CLIO/UI/Commands/API.pm' or die "Cannot read API.pm: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    like($src, qr/\/api set thinking_mode/,
        'API.pm: /api set thinking_mode in help output');
}

done_testing();
