#!/usr/bin/env perl
# Test CLIO::Core::PromptBuilder - system prompt construction
#
# Tests the individual section generators that make up the system prompt.
# Cannot test build_system_prompt fully without a full tool registry,
# so we test the independent section generators.

use strict;
use warnings;
use lib './lib';
use Test::More;

use CLIO::Core::PromptBuilder;

# Test 1: Constructor
subtest 'constructor - defaults' => sub {
    my $builder = CLIO::Core::PromptBuilder->new();
    ok(defined $builder, 'Builder created');
    is($builder->{debug}, 0, 'Debug defaults to 0');
    is($builder->{skip_custom}, 0, 'skip_custom defaults to 0');
    is($builder->{skip_ltm}, 0, 'skip_ltm defaults to 0');
    is($builder->{non_interactive}, 0, 'non_interactive defaults to 0');
};

subtest 'constructor - custom values' => sub {
    my $builder = CLIO::Core::PromptBuilder->new(
        debug           => 1,
        skip_custom     => 1,
        skip_ltm        => 1,
        non_interactive => 1,
    );
    is($builder->{debug}, 1, 'Debug set to 1');
    is($builder->{skip_custom}, 1, 'skip_custom set');
    is($builder->{skip_ltm}, 1, 'skip_ltm set');
    is($builder->{non_interactive}, 1, 'non_interactive set');
};

# Test 2: generate_datetime_section
subtest 'generate_datetime_section - content' => sub {
    my $builder = CLIO::Core::PromptBuilder->new();
    my $section = $builder->generate_datetime_section();

    ok(defined $section, 'Section generated');
    like($section, qr/Current Date/, 'Contains date header');
    like($section, qr/\d{4}-\d{2}-\d{2}/, 'Contains ISO date');
    like($section, qr/Working Directory/, 'Contains working directory');
    like($section, qr/CRITICAL PATH RULES/, 'Contains path rules');
    like($section, qr/SYSTEM TELEMETRY/, 'Contains telemetry notice');
};

# Test 3: generate_non_interactive_section (static function)
subtest 'generate_non_interactive_section - content' => sub {
    my $section = CLIO::Core::PromptBuilder::generate_non_interactive_section();

    ok(defined $section, 'Section generated');
    like($section, qr/Non-Interactive Mode/, 'Contains mode header');
    like($section, qr/DO NOT use user_collaboration/, 'Contains collaboration restriction');
    like($section, qr/DO NOT ask questions/, 'Contains question restriction');
    like($section, qr/DO complete the task/, 'Contains completion instruction');
};

# Test 4: generate_ltm_section - no session
subtest 'generate_ltm_section - no session' => sub {
    my $builder = CLIO::Core::PromptBuilder->new();
    my $section = $builder->generate_ltm_section(undef);
    is($section, '', 'Empty string for undef session');
};

# Test 5: generate_ltm_section - session without LTM
subtest 'generate_ltm_section - no LTM method' => sub {
    my $builder = CLIO::Core::PromptBuilder->new();
    my $session = bless {}, 'FakeSession';
    my $section = $builder->generate_ltm_section($session);
    is($section, '', 'Empty string when session has no LTM');
};

# Test 6: tools section cache
subtest 'generate_tools_section - cache hit' => sub {
    my $builder = CLIO::Core::PromptBuilder->new();
    # Pre-populate cache
    $builder->{_tools_section_cache} = "Cached tools section";
    my $section = $builder->generate_tools_section();
    is($section, "Cached tools section", 'Returns cached value');
};

done_testing();
