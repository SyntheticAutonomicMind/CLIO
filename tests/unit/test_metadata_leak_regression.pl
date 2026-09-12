#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression tests for the metadata-leak bug:
# messages_to_prose_dynamic must NOT inject label scaffolding that
# tells the model "this is framework-managed metadata." Specifically:
#   - No "Active task:" label (emit task text as plain work product)
#   - No "Unresolved:" section (no recycling of tool errors)
#   - No "Relevant memory:" section (no self-referential LTM)
#   - LTM entries that ARE injected (via relevance scoring) must
#     appear under a "## Long-Term Memory" knowledge-base header
#     with type grouping, confidence indicators, and framing text
#     ("not current instructions"), NOT as flat "Relevant context"
#     bullets that read like task items to execute
#
# Work product that IS preserved:
#   - Working directory / Language / Date (environment info)
#   - Active task text (unlabeled)
#   - Active todos (as a checklist with status)
#   - Compressed tail (YaRN summary)
#   - Context files block

use strict;
use warnings;
use lib './lib';

use Test::More;
use CLIO::Core::ContextBuilder ();
use CLIO::Core::MessageHistory qw(messages_to_prose_dynamic);

# ===========================================================================
# Test 1: No label scaffolding leaks into the dynamic userContext
# ===========================================================================

subtest 'metadata-leak regression: no label scaffolding' => sub {
    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history       => [],
        user_input    => 'fix the metadata leak bug',
        active_task   => 'fix the metadata leak bug',
        active_todos  => [
            { id => 1, status => 'in-progress', content => 'Strip label scaffolding' },
        ],
        ltm           => [],
        unresolved    => [],
    );

    my $prose = messages_to_prose_dynamic($proj);

    # The three labels that must NOT appear:
    unlike($prose, qr/^Active task:/m, 'No "Active task:" label');
    unlike($prose, qr/^Unresolved:/m, 'No "Unresolved:" label');
    unlike($prose, qr/^Relevant memory:/m, 'No "Relevant memory:" label');

    # Active task text is NOT rendered in the prose — it is prepended
    # to the user_input by WorkflowOrchestrator via
    # PromptBuilder::get_user_context(). Rendering it here would cause
    # the model to refocus on the original request every turn.
    unlike($prose, qr/fix the metadata leak bug/,
        'Active task text is NOT in prose (rendered separately)');

    # But the underlying work product must still be present:
    like($prose, qr/Active todos:/, 'Active todos section is present');
    like($prose, qr/\[in-progress\] Strip label scaffolding/, 'Todo content with status is present');
    # Environment is NOT rendered here — handled by PromptBuilder::get_user_context().
    unlike($prose, qr/Working directory:/, 'Environment NOT rendered (handled by PromptBuilder)');
};

# ===========================================================================
# Test 2: Tool errors in unresolved state do NOT leak into the prose
# ===========================================================================

subtest 'metadata-leak regression: tool errors not recycled' => sub {
    # Simulate unresolved state with raw tool errors. The prose
    # renderer must not surface them in the userContext.
    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history      => [],
        user_input   => 'continue working',
        active_task  => 'fix bugs',
        active_todos => [
            { id => 1, status => 'in-progress', content => 'Fix leak' },
        ],
        ltm          => [],
        unresolved   => [
            '[TOOL ERROR: shell commands] Missing required parameter: operation',
            'terminal_operations failed: status code 500',
            'file_operations error: file not found at /tmp/x',
        ],
    );

    my $prose = messages_to_prose_dynamic($proj);

    # No "Unresolved:" label at all — the entire section is removed.
    unlike($prose, qr/Unresolved:/, 'No Unresolved label');

    # No raw tool error strings leaked into the prose.
    unlike($prose, qr/TOOL ERROR/, 'No raw TOOL ERROR strings');
    unlike($prose, qr/terminal_operations failed/, 'No tool error text leaked');
    unlike($prose, qr/file_operations error/, 'No tool error text leaked');
    unlike($prose, qr/Missing required parameter/, 'No parameter error text leaked');

    # Active task text is NOT in the prose — rendered separately via
    # get_user_context(). Only the todos should be present as work product.
    like($prose, qr/\[in-progress\] Fix leak/, 'Todo still present');
};

# ===========================================================================
# Test 3: LTM entries are properly scoped — relevant entries are
# injected as structured KB (no metadata labels), irrelevant entries
# are filtered out by scoring.
# ===========================================================================

subtest 'metadata-leak regression: LTM scoped to relevant entries only' => sub {
    my @ltm_entries = (
        { confidence => 0.9, content => 'Self-referential: this is a bug about context dumps', type => 'discovery' },
        { confidence => 0.8, content => 'Always run perl -c before commit', type => 'discovery' },
        { confidence => 0.7, content => 'Framework internals protection pattern', type => 'discovery' },
    );

    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history     => [],
        user_input  => 'framework context',
        active_task => 'fix framework',
        ltm         => \@ltm_entries,
    );

    my $prose = messages_to_prose_dynamic($proj);

    # LTM IS injected (as a structured KB) when entries are relevant.
    # But NO old-style metadata labels leak:
    unlike($prose, qr/Relevant memory:/, 'No old "Relevant memory:" label');
    unlike($prose, qr/Relevant context from previous sessions:/, 'No flat-bullet label');

    # Structured KB format:
    like($prose, qr/## Long-Term Memory/, 'Structured KB header present');
    like($prose, qr/Reference these patterns to inform your approach/, 'Framing text present');
    like($prose, qr/not current instructions/, 'Not-current-instructions framing present');

    # Irrelevant entries are NOT injected (filtered by scoring):
    unlike($prose, qr/Self-referential/, 'Irrelevant entry (no keyword overlap) not injected');
    unlike($prose, qr/Always run perl/, 'Irrelevant entry (no keyword overlap) not injected');

    # Relevant entry IS injected (keyword overlap with "framework"):
    like($prose, qr/Framework internals/, 'Relevant entry (keyword "framework" overlap) injected');
    like($prose, qr/Confidence:/, 'Injected entry has confidence indicator');
    like($prose, qr/\[UNVERIFIED\]/, 'Injected entry has tier badge');
};

# ===========================================================================
# Test 4: Compressed tail (YaRN summary) is still preserved as work product
# ===========================================================================

subtest 'metadata-leak regression: compressed tail preserved' => sub {
    # Construct a projection with a compressed_tail directly (bypassing
    # build_projection, which computes compressed_tail internally from
    # dropped turns and requires a session).
    my $proj = {
        active_task       => 'investigate context dump',
        active_todos      => [],
        environment       => {
            working_directory => '/tmp/test',
            language          => 'English',
            datetime_iso      => '2026-01-01T00:00:00',
        },
        compressed_tail   => '<thread_summary>'
            . "\nCurrent task: investigate the context dump bug\n"
            . "\nCommits:\n- fix(context): remove metadata labels\n"
            . "\n</thread_summary>",
        context_files_block => '',
    };

    my $prose = messages_to_prose_dynamic($proj);

    # The YaRN thread_summary is still present (work product, not narration).
    like($prose, qr/<thread_summary>/, 'YaRN thread_summary preserved');
    like($prose, qr/Current task: investigate the context dump bug/, 'YaRN task line preserved');
    like($prose, qr/fix\(context\): remove metadata labels/, 'YaRN commits line preserved');

    # But no "this is a compressed summary" framing narration.
    unlike($prose, qr/this is a compressed summary/, 'No summary framing narration');
    unlike($prose, qr/you were trimmed/, 'No trim narration');
};

# ===========================================================================
# Test 5: Context files block is still preserved
# ===========================================================================

subtest 'metadata-leak regression: context files preserved' => sub {
    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history             => [],
        user_input          => 'read the code',
        active_task         => 'read the code',
        context_files_block => 'lib/CLIO/Core/MessageHistory.pm: sub messages_to_prose_dynamic {',
    );

    my $prose = messages_to_prose_dynamic($proj);

    like($prose, qr/messages_to_prose_dynamic/, 'Context files content present');
};

# ===========================================================================
# Test 6: Empty projection produces empty (or near-empty) output
# ===========================================================================

subtest 'metadata-leak regression: empty projection produces no labels' => sub {
    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history    => [],
        user_input => 'hello',
    );

    my $prose = messages_to_prose_dynamic($proj);

    # Even with empty projection, no label scaffolding should appear.
    unlike($prose, qr/^Active task:/m, 'No Active task label on empty proj');
    unlike($prose, qr/^Unresolved:/m, 'No Unresolved label on empty proj');
    unlike($prose, qr/^Relevant memory:/m, 'No Relevant memory label on empty proj');

        # Environment is handled separately by PromptBuilder::get_user_context(),
    # not by this renderer. An empty projection produces empty prose.
    is(length($prose), 0, 'Empty projection produces empty prose (env handled elsewhere)');
};

done_testing();
