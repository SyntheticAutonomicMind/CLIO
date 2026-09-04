#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: per-iteration dynamic userContext refresh must
# re-read live state (active_todos, relevant_memory), not use the
# frozen projection built at the start of the turn.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::ContextBuilder;
use CLIO::Core::MessageHistory qw(messages_to_prose_dynamic);

my $initial_todos = [
    { id => 1, status => 'not-started', content => 'Initial task A' },
];
my $initial_ltm = [
    { content => 'Old memory about something unrelated', confidence => 0.9 },
];

my $proj = CLIO::Core::ContextBuilder::build_projection(
    history             => [],
    user_input          => 'work on the refactor',
    active_task         => 'refactor',
    active_todos        => $initial_todos,
    ltm                 => $initial_ltm,
    unresolved          => [],
    context_files_block => '',
);

my $initial_render = messages_to_prose_dynamic($proj);
like($initial_render, qr/Initial task A/, 'initial render contains initial todo');
unlike($initial_render, qr/New task B/, 'initial render does NOT contain new todo (not yet added)');

my $live_todos = [
    { id => 2, status => 'in-progress', content => 'New task B' },
    { id => 1, status => 'completed', content => 'Initial task A' },
];
my $live_ltm = [
    { content => 'Old memory about something unrelated', confidence => 0.9 },
    { content => 'New memory about refactoring the message history serialization', confidence => 0.95 },
];

$proj->{active_todos} = $live_todos;
$proj->{relevant_memory} = CLIO::Core::ContextBuilder::score_ltm(
    $live_ltm, $proj->{user_input}, $proj->{active_task}, $proj->{unresolved} || [],
);
$proj->{ltm_total_count} = scalar(@$live_ltm);

my $refreshed_render = messages_to_prose_dynamic($proj);
like($refreshed_render, qr/New task B/, 'refreshed render contains the NEW todo (live state)');
like($refreshed_render, qr/2 available/, 'refreshed render reflects updated LTM total count (live)');

done_testing();