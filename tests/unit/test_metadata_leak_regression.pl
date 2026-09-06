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

    # But the underlying work product must still be present:
    like($prose, qr/fix the metadata leak bug/, 'Active task text is present (unlabeled)');
    like($prose, qr/Active todos:/, 'Active todos section is present');
    like($prose, qr/\[in-progress\] Strip label scaffolding/, 'Todo content with status is present');
    like($prose, qr/Working directory:/, 'Environment section is present');
};

# ===========================================================================
# Test 2: Tool errors in unresolved state do NOT leak into the prose
# ===========================================================================

subtest 'metadata-leak regression: tool errors not recycled' => sub {
    # Simulate unresolved state with raw tool errors (the kind that
    # previously appeared in the "Unresolved:" section).
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

    # But work product is still present.
    like($prose, qr/fix bugs/, 'Task text still present');
    like($prose, qr/\[in-progress\] Fix leak/, 'Todo still present');
};

# ===========================================================================
# Test 3: LTM entries do NOT leak into the prose
# ===========================================================================

subtest 'metadata-leak regression: LTM not injected into prose' => sub {
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

    # No "Relevant memory:" label — section removed.
    unlike($prose, qr/Relevant memory:/, 'No Relevant memory label');

    # No LTM content leaked into the prose at all.
    unlike($prose, qr/Self-referential/, 'Self-referential LTM not leaked');
    unlike($prose, qr/Always run perl/, 'General LTM not leaked');
    unlike($prose, qr/Framework internals/, 'Framework LTM not leaked');
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

    # But environment info is still present (it's always populated by _build_environment_hash).
    like($prose, qr/Working directory:/, 'Environment still present on empty proj');
};

done_testing();
