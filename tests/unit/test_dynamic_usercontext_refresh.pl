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

subtest 'H3: relevant LTM entries are projected into the userContext tail' => sub {
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
    # Relevant LTM entries ARE projected into the dynamic userContext, in the
    # tail, as a knowledge base ("## Long-Term Memory" + type-grouped
    # subsections). The knowledge-base framing is what keeps the model
    # consulting entries as reference instead of executing them as
    # instructions; the old flat-bullet "Relevant memory:" label is gone.
    like($prose, qr/^## Long-Term Memory/m,
        'LTM projected into dynamic userContext under a knowledge-base header');
    like($prose, qr/Model-facing prompt paths/,
        'Relevant LTM content is projected');
    # Scoring is relevance-gated, not a blind dump: of the five entries above,
    # only the ones matching the input/active task survive.
    unlike($prose, qr/file_operations\(read_file\)/,
        'Unrelated LTM entry is not projected (relevance filtering)');
    unlike($prose, qr/Relevant memory:/,
        'Legacy flat-bullet "Relevant memory:" label is not used');

    # LTM is the tail section: nothing may be rendered after it, or cache
    # ordering and the "reference material sits last" contract both break.
    my @headers = $prose =~ /^#{1,3} .*$/mg;
    ok(@headers, 'prose contains section headers');
    like($headers[-1], qr/Long-Term Memory|Key Discoveries|Discoveries/,
        'LTM section is the last section in the dynamic userContext');

    # Design: no "N more available" count, no framework instructions,
    # no raw decimal confidence scores.
    unlike($prose, qr/more memories available/, 'No "more available" count');
    unlike($prose, qr/memory_operations\(operation: "search"/, 'No search affordance (no framework instructions)');
    unlike($prose, qr/\(0\.\d+\)/, 'No raw decimal confidence scores in prose');
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
# H2: per-iteration refresh — the dynamic UC (todos, compressed_tail)
# is re-rendered every iteration from the current projection. Environment
# (CWD, Date, Lang) is handled separately by PromptBuilder::get_user_context()
# (cached per-minute, prepended to user input) — not tested here.
# ===========================================================================

subtest 'H2: dynamic UC refresh is deterministic for identical inputs' => sub {
    my $proj1 = CLIO::Core::ContextBuilder::build_projection(
        history    => [],
        user_input => 'test',
        active_todos => [
            { id => 1, status => 'in_progress', content => 'write tests' },
        ],
    );
    my $render1 = messages_to_prose_dynamic($proj1);
    my $render2 = messages_to_prose_dynamic($proj1);
    is($render1, $render2, 'dynamic UC render is deterministic for identical inputs');
    like($render1, qr/Active todos:/, 'dynamic UC contains active todos');
};

done_testing();