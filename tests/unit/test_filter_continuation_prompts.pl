#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: continuation-only user prompts ('continue', 'go on',
# 'ok', etc.) that survive trim should be filtered out unless they're
# the LAST user message (the actual current input).

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::ConversationManager qw(filter_continuation_prompts);

# ---------------------------------------------------------------------------
# Scenario 1: mid-history 'continue' prompts get filtered.
# ---------------------------------------------------------------------------
{
    my @messages = (
        { role => 'user', content => 'Original task' },
        { role => 'assistant', content => 'Working on it.' },
        { role => 'user', content => 'continue' },
        { role => 'assistant', content => 'Done.' },
        { role => 'user', content => 'continue' },
        { role => 'assistant', content => 'Done.' },
        { role => 'user', content => 'go on' },
        { role => 'assistant', content => 'Done.' },
        { role => 'user', content => 'Final question here' },
    );

    my $result = filter_continuation_prompts(\@messages);

    my @contents = map { $_->{content} // '' } @$result;
    is(scalar(@$result), 6,
        'Scenario 1: filtered out 3 continuation prompts (kept 6/9 messages)');

    ok(!(grep { $_ eq 'continue' } @contents),
        'Scenario 1: no "continue" survived in mid-history');
    ok(!(grep { $_ eq 'go on' } @contents),
        'Scenario 1: no "go on" survived in mid-history');
    ok((grep { $_ eq 'Original task' } @contents),
        'Scenario 1: original task preserved');
    ok((grep { $_ eq 'Final question here' } @contents),
        'Scenario 1: final user input preserved');
}

# ---------------------------------------------------------------------------
# Scenario 2: last user message IS a continuation prompt - keep it.
# This handles the case where the user types 'continue' as their
# actual current input.
# ---------------------------------------------------------------------------
{
    my @messages = (
        { role => 'user', content => 'Original task' },
        { role => 'assistant', content => 'Working.' },
        { role => 'user', content => 'continue' },
    );

    my $result = filter_continuation_prompts(\@messages);
    is(scalar(@$result), 3,
        'Scenario 2: last user is "continue" - preserved (it is the actual current input)');
}

# ---------------------------------------------------------------------------
# Scenario 3: no continuation prompts - no-op (same arrayref returned).
# ---------------------------------------------------------------------------
{
    my @messages = (
        { role => 'user', content => 'Task 1' },
        { role => 'assistant', content => 'Done.' },
        { role => 'user', content => 'Real question with substance' },
    );

    my $result = filter_continuation_prompts(\@messages);
    is(scalar(@$result), 3, 'Scenario 3: no-op when no continuations');
    is($result, \@messages, 'Scenario 3: same arrayref returned (no allocation)');
}

# ---------------------------------------------------------------------------
# Scenario 4: continuation-like phrases that are NOT continuations.
# ---------------------------------------------------------------------------
{
    my @messages = (
        { role => 'user', content => 'continue working on the test file' },
        { role => 'assistant', content => 'OK' },
        { role => 'user', content => 'Final question' },
    );

    my $result = filter_continuation_prompts(\@messages);
    is(scalar(@$result), 3,
        'Scenario 4: longer "continue ..." not filtered (not a continuation-only prompt)');
}

done_testing();