#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Test the show_thinking steering paragraph in PromptBuilder.
#
# When needs_thinking_steering is set, PromptBuilder appends a "Reasoning
# Visibility" section that asks the model to briefly articulate reasoning
# in the thinking block before each tool call (and explicitly tells it not
# to leak reasoning into the visible response). The caller
# (WorkflowOrchestrator) gates needs_thinking_steering on show_thinking=1
# AND the model's reasoning_mode resolving to 'adaptive' (currently
# Anthropic adaptive-mode models only, per _ensure_reasoning_mode). When
# disabled, the section is omitted entirely so the system prompt stays
# clean for providers whose thinking is their own native output.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;

use CLIO::Core::PromptBuilder;
use CLIO::Tools::Registry;

# Helper: build a minimal PromptBuilder with a real (empty) ToolRegistry
# so build_system_prompt can complete. skip_custom=1 keeps user.md out
# of tests, skip_ltm=1 keeps LTM out, and we use the show_thinking and
# needs_thinking_steering values the caller asks for.
sub _builder_with_steering {
    my (%opts) = @_;
    my $registry = CLIO::Tools::Registry->new(debug => 0);
    return CLIO::Core::PromptBuilder->new(
        skip_custom   => 1,
        skip_ltm      => 1,
        tool_registry => $registry,
        show_thinking => $opts{show_thinking} ? 1 : 0,
        needs_thinking_steering => $opts{needs_thinking_steering} ? 1 : 0,
    );
}

# ---------------------------------------------------------------------------
# Test 1: static generate_thinking_steering_section works.
# ---------------------------------------------------------------------------
subtest 'generate_thinking_steering_section - returns reasoning paragraph' => sub {
    my $section = CLIO::Core::PromptBuilder::generate_thinking_steering_section();
    ok(defined $section, 'Section returned');
    like($section, qr/Reasoning Visibility/,
        'Section names itself "Reasoning Visibility"');
    like($section, qr/thinking block/i,
        'Section mentions thinking block');
    like($section, qr/Do not.*include.*reasoning.*visible/i,
        'Section explicitly tells the model NOT to leak reasoning to visible text');
};

# ---------------------------------------------------------------------------
# Test 2: constructor stores the show_thinking flag (unchanged behavior).
# ---------------------------------------------------------------------------
subtest 'constructor - show_thinking flag stored' => sub {
    my $with_steering = CLIO::Core::PromptBuilder->new(show_thinking => 1);
    is($with_steering->{show_thinking}, 1,
        'show_thinking=1 stored on builder');

    my $without_steering = CLIO::Core::PromptBuilder->new(show_thinking => 0);
    is($without_steering->{show_thinking}, 0,
        'show_thinking=0 stored on builder');

    my $default = CLIO::Core::PromptBuilder->new();
    is($default->{show_thinking}, 0,
        'show_thinking defaults to 0 when not provided');
};

# ---------------------------------------------------------------------------
# Test 3: constructor stores the new needs_thinking_steering flag.
# ---------------------------------------------------------------------------
subtest 'constructor - needs_thinking_steering flag stored' => sub {
    my $on = CLIO::Core::PromptBuilder->new(needs_thinking_steering => 1);
    is($on->{needs_thinking_steering}, 1,
        'needs_thinking_steering=1 stored on builder');

    my $off = CLIO::Core::PromptBuilder->new(needs_thinking_steering => 0);
    is($off->{needs_thinking_steering}, 0,
        'needs_thinking_steering=0 stored on builder');

    my $default = CLIO::Core::PromptBuilder->new();
    is($default->{needs_thinking_steering}, 0,
        'needs_thinking_steering defaults to 0 when not provided');
};

# ---------------------------------------------------------------------------
# Test 4: build_system_prompt injects the steering paragraph when the
# caller passes needs_thinking_steering=1.
# ---------------------------------------------------------------------------
subtest 'build_system_prompt - steering included when needs_thinking_steering=1' => sub {
    my $builder = _builder_with_steering(
        show_thinking             => 1,
        needs_thinking_steering   => 1,
    );
    my $prompt  = $builder->build_system_prompt(undef);
    ok(defined $prompt, 'Prompt generated');
    like($prompt, qr/## Reasoning Visibility/,
        'Steering section included when needs_thinking_steering=1');
    like($prompt, qr/before.*each tool call/is,
        'Steering text asks for reasoning before tool calls');
};

# ---------------------------------------------------------------------------
# Test 5 (regression for the M3 bug): show_thinking=1 ALONE no longer
# injects steering. The pre-fix gate was `if ($self->{show_thinking})`,
# which fired for every provider when the user enabled thinking display.
# That over-firing is exactly what produced the M3 thinking block of
# `**Locating X****Reporting Y****Preparing Z**`. The new gate requires
# needs_thinking_steering=1, which the caller only sets when reasoning_mode
# is 'adaptive' (Anthropic family).
# ---------------------------------------------------------------------------
subtest 'build_system_prompt - show_thinking=1 alone does NOT inject steering (M3 regression)' => sub {
    my $builder = _builder_with_steering(show_thinking => 1);
    my $prompt  = $builder->build_system_prompt(undef);
    ok(defined $prompt, 'Prompt generated');
    unlike($prompt, qr/## Reasoning Visibility/,
        'Steering section omitted when needs_thinking_steering=0 even with show_thinking=1');
    unlike($prompt, qr/before each tool call/i,
        'Steering text not present when needs_thinking_steering=0');
};

# ---------------------------------------------------------------------------
# Test 6: both flags off -> no steering.
# ---------------------------------------------------------------------------
subtest 'build_system_prompt - steering omitted when both flags off' => sub {
    my $builder = _builder_with_steering(
        show_thinking             => 0,
        needs_thinking_steering   => 0,
    );
    my $prompt  = $builder->build_system_prompt(undef);
    ok(defined $prompt, 'Prompt generated');
    unlike($prompt, qr/## Reasoning Visibility/,
        'Steering omitted when both flags off');
    unlike($prompt, qr/before each tool call/i,
        'Steering text not present');
};

# ---------------------------------------------------------------------------
# Test 7: show_thinking=0 but needs_thinking_steering=1 still fires
# (PromptBuilder doesn't enforce the AND gate - the caller does, and we
# want the constructor option to be testable independently).
# ---------------------------------------------------------------------------
subtest 'build_system_prompt - needs_thinking_steering=1 fires regardless of show_thinking' => sub {
    my $builder = _builder_with_steering(
        show_thinking             => 0,
        needs_thinking_steering   => 1,
    );
    my $prompt  = $builder->build_system_prompt(undef);
    ok(defined $prompt, 'Prompt generated');
    like($prompt, qr/## Reasoning Visibility/,
        'Steering fires when needs_thinking_steering=1 (caller controls the AND gate)');
};

done_testing();