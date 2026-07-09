#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Test the show_thinking steering paragraph in PromptBuilder.
#
# When show_thinking is enabled, PromptBuilder appends a "Reasoning
# Visibility" section that asks the model to briefly articulate reasoning
# in the thinking block before each tool call (and explicitly tells it not
# to leak reasoning into the visible response). When disabled, the section
# is omitted entirely so the system prompt stays clean.

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;

use CLIO::Core::PromptBuilder;
use CLIO::Tools::Registry;

# Helper: build a minimal PromptBuilder with a real (empty) ToolRegistry
# so build_system_prompt can complete. skip_custom=1 keeps user.md out
# of tests, skip_ltm=1 keeps LTM out, and we use the show_thinking value
# the caller asks for.
sub _builder_with_steering {
    my (%opts) = @_;
    my $registry = CLIO::Tools::Registry->new(debug => 0);
    return CLIO::Core::PromptBuilder->new(
        skip_custom   => 1,
        skip_ltm      => 1,
        tool_registry => $registry,
        show_thinking => $opts{show_thinking} ? 1 : 0,
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
# Test 2: constructor stores the flag.
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
# Test 3: build_system_prompt includes the steering paragraph when enabled.
# ---------------------------------------------------------------------------
subtest 'build_system_prompt - steering included when show_thinking=1' => sub {
    my $builder = _builder_with_steering(show_thinking => 1);
    my $prompt  = $builder->build_system_prompt(undef);
    ok(defined $prompt, 'Prompt generated');
    like($prompt, qr/## Reasoning Visibility/,
        'Steering section included when show_thinking=1');
    like($prompt, qr/before.*each tool call/is,
        'Steering text asks for reasoning before tool calls');
};

# ---------------------------------------------------------------------------
# Test 4: build_system_prompt omits the steering paragraph when disabled.
# ---------------------------------------------------------------------------
subtest 'build_system_prompt - steering omitted when show_thinking=0' => sub {
    my $builder = _builder_with_steering(show_thinking => 0);
    my $prompt  = $builder->build_system_prompt(undef);
    ok(defined $prompt, 'Prompt generated');
    unlike($prompt, qr/## Reasoning Visibility/,
        'Steering section omitted when show_thinking=0');
    unlike($prompt, qr/before each tool call/i,
        'Steering text not present when show_thinking=0');
};

done_testing();