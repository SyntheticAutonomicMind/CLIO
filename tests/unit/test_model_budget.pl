#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Regression tests for lib/CLIO/Core/ModelBudget.pm and the
# context-window-class aware budget scaling wired through
# InstructionsReader (XS-class skips AGENTS.md).
#
# Verifies:
#   1. model_class() boundary classification (XS/S/M/L/XL)
#   2. budget_for() returns the documented table for each class
#   3. effective_budget() is a convenience that picks the right class
#   4. apply_budget_to_payload() truncates / skips / preserves correctly
#   5. InstructionsReader skips AGENTS.md for XS class and includes it
#      for M class (and above)
#   6. PromptManager.set_model_class invalidates the cached instructions

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use CLIO::Core::ModelBudget qw(
    model_class budget_for effective_budget apply_budget_to_payload known_classes
);
use CLIO::Core::InstructionsReader;
use CLIO::Core::PromptManager;

subtest 'model_class() boundary classification' => sub {
    is(model_class(0),       'XS', '0 -> XS');
    is(model_class(8192),    'XS', '8K -> XS');
    is(model_class(32768),   'XS', '32K (boundary) -> XS');
    is(model_class(32769),   'S',  '32K+1 -> S');
    is(model_class(65536),   'S',  '64K (boundary) -> S');
    is(model_class(65537),   'M',  '64K+1 -> M');
    is(model_class(131072),  'M',  '128K (boundary) -> M');
    is(model_class(131073),  'L',  '128K+1 -> L');
    is(model_class(262144),  'L',  '256K (boundary) -> L');
    is(model_class(262145),  'XL', '256K+1 -> XL');
    is(model_class(1000000), 'XL', '1M -> XL');
};

subtest 'budget_for() returns documented table per class' => sub {
    my $xs = budget_for('XS');
    ok($xs, 'XS budget defined');
    is($xs->{agents_md}, 0, 'XS skips AGENTS.md');
    is($xs->{ltm}, 0, 'XS skips LTM');
    is($xs->{system_prompt}, -1, 'XS keeps system_prompt full');
    is($xs->{tools_schema}, 6000, 'XS tools_schema capped at 6000');
    is($xs->{csss_slot}, 2000, 'XS CSSS slot at 2000');

    my $s = budget_for('S');
    ok($s, 'S budget defined');
    is($s->{agents_md}, 5000, 'S truncates AGENTS.md to 5000');
    is($s->{ltm}, 2000, 'S truncates LTM to 2000');

    my $xl = budget_for('XL');
    ok($xl, 'XL budget defined');
    is($xl->{agents_md}, -1, 'XL keeps AGENTS.md full');
    is($xl->{ltm}, -1, 'XL keeps LTM full');

    # Unknown class returns undef
    is(budget_for('XX'), undef, 'unknown class returns undef');
};

subtest 'effective_budget() picks right class' => sub {
    is(effective_budget(8192,  'agents_md'),   0,     'XS: AGENTS.md skipped');
    is(effective_budget(65536, 'agents_md'),   5000,  'S: AGENTS.md 5000');
    is(effective_budget(131072, 'agents_md'),  15000, 'M: AGENTS.md 15000');
    is(effective_budget(1000000, 'agents_md'), -1,    'XL: AGENTS.md full');
};

subtest 'apply_budget_to_payload() truncates / skips / preserves' => sub {
    # Unlimited budget (e.g. XL-class system_prompt): return unchanged
    my $content = "Hello world";
    is(apply_budget_to_payload(-1, 'system_prompt', $content),
        $content, 'unlimited budget returns content unchanged');

    # Zero budget (e.g. XS-class LTM): return undef (skip section)
    is(apply_budget_to_payload(0, 'ltm', $content),
        undef, 'zero budget returns undef (skip)');

    # Small budget on long content: truncate
    my $long = ("x" x 4000);  # ~1000 tokens at 4 chars/token
    my $truncated = apply_budget_to_payload(100, 'dialog', $long);
    ok(defined $truncated, 'truncated result defined');
    ok(length($truncated) < length($long), 'truncated result is shorter than original');

    # Small budget on short content: return as-is
    my $short = "x" x 100;  # ~25 tokens
    is(apply_budget_to_payload(100, 'dialog', $short),
        $short, 'short content under budget unchanged');

    # undef content: return undef regardless of budget
    is(apply_budget_to_payload(1000, 'dialog', undef),
        undef, 'undef content returns undef');
};

subtest 'InstructionsReader skips AGENTS.md for XS class' => sub {
    my $reader = CLIO::Core::InstructionsReader->new();
    my $xs = $reader->read_instructions(undef, model_class => 'XS');
    ok(defined $xs, 'XS load returns something');
    like($xs, qr/agentsMdPointer/, 'XS load contains agentsMdPointer');
    unlike($xs || '', qr/Quick Setup/, 'XS load does NOT contain AGENTS.md Quick Setup section');

    my $m = $reader->read_instructions(undef, model_class => 'M');
    ok(defined $m, 'M load returns something');
    unlike($m || '', qr/agentsMdPointer/, 'M load does NOT contain agentsMdPointer');
    like($m || '', qr/Quick Setup/, 'M load contains AGENTS.md Quick Setup section');
};

subtest 'PromptManager.set_model_class invalidates cache' => sub {
    my $pm = CLIO::Core::PromptManager->new(debug => 0);
    # First load (no class set) - loads full
    my $full = $pm->_load_custom_instructions();
    ok(defined $full, 'full load returns content');
    is($pm->{custom_instructions_cache}, $full, 'cache set');

    # Set XS class - cache should be invalidated
    $pm->set_model_class('XS');
    is($pm->{model_class}, 'XS', 'model_class set');
    ok(!defined $pm->{custom_instructions_cache},
        'cache invalidated after set_model_class');

    # Next load with XS - returns the agentsMdPointer version
    my $xs_load = $pm->_load_custom_instructions();
    ok(defined $xs_load, 'XS load returns content');
    like($xs_load, qr/agentsMdPointer/, 'XS load contains agentsMdPointer');

    # Set M class - cache invalidated again
    $pm->set_model_class('M');
    ok(!defined $pm->{custom_instructions_cache},
        'cache invalidated after switching M');
    my $m_load = $pm->_load_custom_instructions();
    unlike($m_load || '', qr/agentsMdPointer/,
        'M load after class switch does NOT contain agentsMdPointer');
};

subtest 'known_classes returns 5 classes' => sub {
    my $classes = known_classes();
    is_deeply($classes, [qw(XS S M L XL)],
        'known classes are XS S M L XL in order');
};

done_testing();