#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Regression: Anthropic's adaptive thinking API takes the effort parameter
# in `output_config.effort`, NOT in `thinking.effort`. The earlier CLIO code
# put effort inside the thinking block:
#
#   thinking: { type: "adaptive", effort: "xhigh" }   # WRONG
#
# The API silently ignored that field, so /api set thinking_effort xhigh
# produced no observable behavior change - the model still ran at default
# effort (high). The correct shape is:
#
#   thinking: { type: "adaptive", display: "summarized" }
#   output_config: { effort: "xhigh" }
#
# Also added: `display: "summarized"` to the thinking block. On the newest
# models (Fable 5, Mythos 5, Sonnet 5, Opus 4.8, Opus 4.7) the default is
# "omitted" which returns thinking blocks with empty text. "summarized"
# gives CLIO the thinking text without extra cost (Anthropic charges for
# the original tokens, not the summary).
#
# Anthropic also accepts a 'max' effort tier (highest, no constraints)
# on top of the existing low|medium|high|xhigh. CLIO now forwards it
# verbatim.
#
# These tests verify the build_request payload shape directly so any
# future refactor that puts effort in the wrong place fails loud.

use Test::More;
use CLIO::Util::JSON qw(decode_json);
use CLIO::Providers::Anthropic;

my $provider = CLIO::Providers::Anthropic->new(
    api_key => 'test-key',
    model   => 'claude-sonnet-4-6',
);

sub build_payload_for {
    my (%opts) = @_;
    my $req = $provider->build_request(
        [{ role => 'user', content => 'hi' }],
        undef,
        {
            model      => $opts{model}     // 'claude-sonnet-4-6',
            max_tokens => $opts{max_tokens} // 16000,
            thinking   => $opts{thinking},
        },
    );
    return decode_json($req->{body});
}

# Test 1: Adaptive mode puts effort in output_config, NOT in thinking
{
    my $body = build_payload_for(
        thinking => { enabled => 1, mode => 'adaptive', effort => 'xhigh' },
    );
    is($body->{thinking}{type}, 'adaptive',
        'adaptive: thinking.type=adaptive');
    is($body->{thinking}{display}, 'summarized',
        'adaptive: thinking.display=summarized (so thinking text is visible to CLIO)');
    is($body->{thinking}{effort}, undef,
        'adaptive: effort is NOT in thinking block (regression guard for the original bug)');
    is($body->{output_config}{effort}, 'xhigh',
        'adaptive: effort goes in output_config.effort (correct Anthropic API shape)');
}

# Test 2: Adaptive mode with default medium omits output_config.effort entirely
{
    my $body = build_payload_for(
        thinking => { enabled => 1, mode => 'adaptive', effort => 'medium' },
    );
    is($body->{thinking}{type}, 'adaptive',
        'adaptive (medium): thinking.type=adaptive');
    is($body->{thinking}{display}, 'summarized',
        'adaptive (medium): thinking.display=summarized always set');
    ok(!$body->{output_config} || !$body->{output_config}{effort},
        'adaptive (medium): output_config.effort omitted for default medium');
}

# Test 3: max effort is accepted (highest tier, available on all adaptive-capable models)
{
    my $body = build_payload_for(
        model    => 'claude-opus-4-8',
        thinking => { enabled => 1, mode => 'adaptive', effort => 'max' },
    );
    is($body->{output_config}{effort}, 'max',
        'adaptive (max): effort=max forwarded to output_config.effort');
}

# Test 4: low and high effort also go to output_config, not thinking
{
    for my $effort (qw(low high)) {
        my $body = build_payload_for(
            thinking => { enabled => 1, mode => 'adaptive', effort => $effort },
        );
        is($body->{output_config}{effort}, $effort,
            "adaptive ($effort): effort=$effort forwarded to output_config.effort");
        is($body->{thinking}{effort}, undef,
            "adaptive ($effort): effort NOT in thinking block");
    }
}

# Test 5: 'enabled' (legacy) mode unchanged - thinking.type=enabled, budget_tokens present
{
    my $body = build_payload_for(
        model    => 'claude-3-5-sonnet-20241022',
        thinking => { enabled => 1, mode => 'enabled', effort => 'medium' },
    );
    is($body->{thinking}{type}, 'enabled',
        'enabled (legacy): thinking.type=enabled');
    ok($body->{thinking}{budget_tokens},
        'enabled (legacy): thinking.budget_tokens is set');
    is($body->{output_config}, undef,
        'enabled (legacy): output_config NOT set (only used for adaptive)');
}

# Test 6: Thinking disabled - no thinking block, no output_config
{
    my $body = build_payload_for(
        thinking => { enabled => 0 },
    );
    is($body->{thinking}, undef,
        'thinking disabled: thinking block absent');
    is($body->{output_config}, undef,
        'thinking disabled: output_config absent');
}

# Test 7: Adaptive mode forces temperature=1 and drops top_k (existing invariant)
{
    my $body = build_payload_for(
        thinking   => { enabled => 1, mode => 'adaptive', effort => 'high' },
        max_tokens => 16000,
    );
    is($body->{temperature}, 1,
        'adaptive: temperature forced to 1');
    is($body->{top_k}, undef,
        'adaptive: top_k dropped (incompatible with thinking)');
}

# Test 8: Source-level regression guard - effort is NOT assigned to thinking.effort
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Providers/Anthropic.pm' or die; <$fh> };

    # Locate the build_request block
    my $start = index($src, 'sub build_request');
    my $end   = index($src, 'sub get_headers', $start);
    my $block = substr($src, $start, $end - $start);

    # The original bug: $payload->{thinking}{effort} = $thinking->{effort};
    # This must NOT appear anywhere in build_request. Effort goes in
    # output_config instead.
    unlike($block, qr/\$\w+->\{thinking\}\{effort\}/,
        'build_request: does not assign to thinking->{effort} (effort must go in output_config)');

    like($block, qr/\$\w+->\{output_config\}\{effort\}/,
        'build_request: assigns effort to output_config->{effort} (correct Anthropic API shape)');

    like($block, qr/display\s*=>\s*['"]summarized['"]/,
        'build_request: sets thinking.display=summarized so thinking text is visible');
}

# Test 9: Proxy alias + no explicit mode falls through to adaptive via
# _supports_adaptive_thinking. Without this fix, model=Proxy-Sonnet-5
# with thinking enabled but no mode in the thinking_opt would have
# defaulted to {type: enabled, budget_tokens: ...} and HTTP 400'd
# with "thinking.type.enabled is not supported for this model".
{
    my $body = build_payload_for(
        model    => 'Proxy-Sonnet-5',
        thinking => { enabled => 1, effort => 'high' },  # no mode
    );
    is($body->{thinking}{type}, 'adaptive',
        'proxy alias Proxy-Sonnet-5 with no explicit mode -> adaptive (was: enabled, HTTP 400)');
    is($body->{thinking}{display}, 'summarized',
        'proxy alias Proxy-Sonnet-5 -> adaptive with display=summarized');
    ok(!exists $body->{thinking}{budget_tokens},
        'proxy alias Proxy-Sonnet-5 -> no budget_tokens (adaptive mode)');
    is($body->{output_config}{effort}, 'high',
        'proxy alias Proxy-Sonnet-5 -> effort goes to output_config.effort');
}

# Test 10: 5-series (claude-sonnet-5) without explicit mode also picks adaptive
{
    my $body = build_payload_for(
        model    => 'claude-sonnet-5',
        thinking => { enabled => 1, effort => 'high' },
    );
    is($body->{thinking}{type}, 'adaptive',
        'claude-sonnet-5 with no explicit mode -> adaptive');
    is($body->{output_config}{effort}, 'high',
        'claude-sonnet-5 effort -> output_config.effort');
}

# Test 11: 4.5 model (pre-adaptive) without explicit mode still gets
# {type: enabled, budget_tokens: ...} - regression guard for the
# reverse case (we must NOT over-match and adaptive-ify 4.5).
{
    my $body = build_payload_for(
        model    => 'claude-sonnet-4-5-20250929',
        thinking => { enabled => 1, effort => 'medium' },
    );
    is($body->{thinking}{type}, 'enabled',
        '4.5 dated model with no explicit mode -> enabled (legacy)');
    ok($body->{thinking}{budget_tokens},
        '4.5 dated model -> budget_tokens set (enabled mode)');
    is($body->{output_config}, undef,
        '4.5 dated model -> no output_config (enabled mode uses thinking block only)');
}

# Test 12: Source-level regression guard - Anthropic.pm's
# _supports_adaptive_thinking delegates to MCM. Without the
# shared helper, the regex could drift between the two files.
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Providers/Anthropic.pm' or die; <$fh> };

    like($src, qr/_anthropic_model_reasoning_mode/,
        'Anthropic.pm calls MCM._anthropic_model_reasoning_mode (single source of truth)');
}

done_testing();
