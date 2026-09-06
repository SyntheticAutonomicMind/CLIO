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

subtest 'H3: empty relevant_memory → no Relevant memory section' => sub {
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
    # Design: no "Relevant memory" section when nothing passes threshold,
    # and no framework instructions ("call memory_operations...").
    unlike($prose, qr/Relevant memory:/, 'No Relevant memory section when nothing passes threshold');
    unlike($prose, qr/no memories met the relevance threshold/, 'No threshold-hint narration');
    unlike($prose, qr/memory_operations\(operation: "search"/, 'No on-demand search affordance (no framework instructions)');
    unlike($prose, qr/\(0\.90\)|\(0\.70\)/, 'No confidence scores in prose');
};

subtest 'H3: relevant_memory NOT in dynamic userContext (metadata-leak fix)' => sub {
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
    # Post-metadata-leak fix: the Relevant memory section is removed
    # entirely. LTM entries are not injected into the dynamic
    # userContext — the model can search LTM on demand via
    # memory_operations(search).
    unlike($prose, qr/Relevant memory:/, 'No Relevant memory label in prose');
    unlike($prose, qr/Model-facing prompt paths/, 'No LTM content leaked into dynamic userContext');
    unlike($prose, qr/Cache stability requires/, 'No LTM content leaked into dynamic userContext');
    unlike($prose, qr/Always run perl/, 'No LTM content leaked into dynamic userContext');
    # Design: no "N more available" count, no framework instructions,
    # no confidence scores.
    unlike($prose, qr/more memories available/, 'No "more available" count');
    unlike($prose, qr/memory_operations\(operation: "search"/, 'No search affordance (no framework instructions)');
    unlike($prose, qr/\(0\.\d+\)/, 'No confidence scores in prose');
};

subtest 'H3: no LTM -> no relevant memory section' => sub {
    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history    => [],
        user_input => 'hello',
        ltm        => [],
    );

    my $prose = messages_to_prose_dynamic($proj);
    unlike($prose, qr/Relevant memory:/, 'No relevant memory section when LTM is empty');
};

subtest 'H3: no framework instructions in dynamic userContext' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery('Framework internals protection', 0.9);
    my $entries = $ltm->get_entries_for_projection();

    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history    => [],
        user_input => 'off topic',
        ltm        => $entries,
    );

    my $prose = messages_to_prose_dynamic($proj);
    # Design: no framework narration, no tool-call instructions.
    unlike($prose, qr/memory_operations\(operation: "search"/,
        'No on-demand search affordance (framework instructions removed)');
    unlike($prose, qr/long-term memory\(operation: "search"/,
        'No sanitized variant either');
    unlike($prose, qr/more memories available/,
        'No "more available" count');
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