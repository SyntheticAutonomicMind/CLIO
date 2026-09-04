#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression tests for H2 (per-iteration dynamic userContext refresh)
# and H3 (on-demand LTM search affordance).
#
# H2: When the model calls todo_operations during a turn, the next
# API iteration must see the updated todo state. Without per-iteration
# refresh, the model sees stale "Active todos" until the next turn.
#
# H3: When LTM exists but no memories met the relevance threshold,
# the model should see a hint that it can search LTM on demand.
# Without this hint, the model assumes LTM is empty and won't search.

use strict;
use warnings;
use lib './lib';

use Test::More;
use CLIO::Memory::LongTerm ();
use CLIO::Core::ContextBuilder ();
use CLIO::Core::MessageHistory qw(messages_to_prose_dynamic);

# ===========================================================================
# H3: on-demand LTM search affordance
# ===========================================================================

subtest 'H3: empty relevant_memory surfaces on-demand search affordance' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery('Model-facing prompt paths must NEVER tell the model about framework internals.', 0.9);
    $ltm->add_discovery('Cache stability requires structural separation of stable vs dynamic content.', 0.7);
    my $entries = $ltm->get_entries_for_projection();

    # Off-topic user input - no LTM entries score high enough
    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history    => [],
        user_input => 'what is the weather like today?',
        ltm        => $entries,
    );

    my $prose = messages_to_prose_dynamic($proj);
    like($prose, qr/# Relevant memory/, 'Relevant memory section is present');
    like($prose, qr/no memories met the relevance threshold/,
        'surfaces that threshold filtering happened');
    like($prose, qr/memory_operations\(operation: "search"/,
        'surfaces on-demand memory_operations(search) affordance (NOT sanitized)');
    like($prose, qr/2 available/,
        'reports the total count of available LTM entries');
};

subtest 'H3: relevant_memory + extras shows count of available more' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    # 5 LTM entries; some relevant, some not
    $ltm->add_discovery('Model-facing prompt paths must NEVER tell the model about framework internals.', 0.9);
    $ltm->add_discovery('Cache stability requires structural separation of stable vs dynamic content.', 0.7);
    $ltm->add_discovery('Always run perl -c before commit', 0.6);
    $ltm->add_discovery('PREFER system-prompt caching for static content', 0.6);
    $ltm->add_discovery('Use file_operations(read_file) for file content', 0.5);
    my $entries = $ltm->get_entries_for_projection();

    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history    => [],
        user_input => 'framework context',
        active_task => 'fix framework',
        ltm        => $entries,
    );

    my $prose = messages_to_prose_dynamic($proj);
    like($prose, qr/# Relevant memory/, 'Relevant memory section present');
    like($prose, qr/more memories available.+memory_operations\(operation: "search"/s,
        'shows count of extras available + memory_operations(search) affordance');
};

subtest 'H3: no LTM -> no relevant memory section' => sub {
    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history    => [],
        user_input => 'hello',
        ltm        => [],
    );

    my $prose = messages_to_prose_dynamic($proj);
    unlike($prose, qr/# Relevant memory/, 'No relevant memory section when LTM is empty');
};

subtest 'H3: hint uses literal tool name (not sanitized)' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery('Framework internals protection', 0.9);
    my $entries = $ltm->get_entries_for_projection();

    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history    => [],
        user_input => 'off topic',
        ltm        => $entries,
    );

    my $prose = messages_to_prose_dynamic($proj);
    # The hint uses the literal tool name. The sanitizer would rewrite
    # memory_operations -> long-term memory, which the model can't
    # act on. The hint MUST be hard-coded, not run through the
    # sanitizer.
    like($prose, qr/memory_operations\(operation: "search"/,
        'hint uses literal memory_operations tool name (not sanitized to long-term memory)');
    unlike($prose, qr/long-term memory\(operation: "search"/,
        'hint is NOT passed through sanitize_narration');
};

# ===========================================================================
# H2: per-iteration refresh (verified at the prose-renderer level -
# WorkflowOrchestrator integration is checked via the orchestrator
# test suite)
# ===========================================================================

subtest 'H2: messages_to_prose_dynamic reflects current datetime' => sub {
    my $proj1 = CLIO::Core::ContextBuilder::build_projection(
        history => [], user_input => 'test',
    );
    my $render1 = messages_to_prose_dynamic($proj1);
    sleep(1);
    my $proj2 = CLIO::Core::ContextBuilder::build_projection(
        history => [], user_input => 'test',
    );
    my $render2 = messages_to_prose_dynamic($proj2);
    isnt($render1, $render2,
        'datetime_iso is refreshed on each build_projection call');
    like($render1, qr/Date: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, 'first render has ISO date');
    like($render2, qr/Date: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/, 'second render has ISO date');
};

done_testing();