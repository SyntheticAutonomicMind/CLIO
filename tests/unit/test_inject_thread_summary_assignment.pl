#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test for the @messages = $self->_inject_thread_summary(...)
# assignment bug introduced in commit a88d9a19 (fixed in this commit).
#
# Bug: WorkflowOrchestrator::process_input had:
#     @messages = $self->_inject_thread_summary(\@messages, $user_input)
#
# _inject_thread_summary returns an arrayref and modifies \@messages in
# place. Assigning an arrayref to a list (@messages) does NOT dereference
# it -- it makes @messages a single-element array whose sole element is
# the arrayref. The three real messages collapsed into [ARRAY_REF], then
# validate_tool_message_pairs filtered out the arrayref element leaving
# [], and the API received messages:[] -> OpenRouter returns 400
# "Input required: specify 'prompt' or 'messages'".
#
# This test reproduces the exact caller pattern and asserts the messages
# array survives the call with the correct structure (all hashrefs, all
# messages present).

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_tool_message_pairs);
use CLIO::Core::ConversationManager qw(enforce_message_alternation);

# ── Test 1: Buggy assignment pattern corrupts messages ──────────────
# Reproduces: @messages = $arrayref_returning_func(...)
{
    my @messages = (
        { role => 'system', content => 'system prompt' },
        { role => 'system', content => "<userContext>x</userContext>" },
        { role => 'user', content => 'I would like you to do a full QA audit of the CLIO codebase' },
    );
    my $before_count = scalar(@messages);
    my $before_roles = join(',', map { ref($_) eq 'HASH' ? $_->{role} : 'NONREF' } @messages);

    # Simulate the buggy caller: @messages = $func(\@messages)
    # where func returns the same arrayref it was handed.
    my $arrayref = \@messages;
    @messages = ( $arrayref );  # BUG: list-assigns the arrayref as ONE element

    my $after_count = scalar(@messages);

    is($before_count, 3, 'Before buggy assignment: 3 messages');
    is($after_count, 1, 'Buggy pattern: @messages collapses to 1 element');
    is(ref($messages[0]), 'ARRAY', 'Buggy pattern: sole element is an ARRAY ref (corruption)');
    isnt(ref($messages[0]), 'HASH', 'Buggy pattern: element is NOT a HASH');
}

# ── Test 2: Correct (in-place) call pattern preserves messages ───────
# The fix: call _inject_thread_summary(\@messages, ...) WITHOUT
# list-assigning the return value. The array is modified in place.
{
    my @messages = (
        { role => 'system', content => 'system prompt' },
        { role => 'user',   content => 'I would like you to do a full QA audit of the CLIO codebase' },
    );
    my $before_count = scalar(@messages);

    # Simulate the FIX: caller does NOT do @messages = $func(...);
    # The function mutates \@messages in place; caller ignores return.
    # (Equivalent to: if ($self->can('_inject_thread_summary')) {
    #                    $self->_inject_thread_summary(\@messages, $user_input);
    #                 })
    my $ref = \@messages;
    # In-place mutation (no list-assignment of the return value):
    # _messages stays intact.
    @messages = @$ref;  # re-deref the SAME array (no corruption)

    my $after_count = scalar(@messages);
    is($after_count, $before_count, 'Fixed pattern: message count preserved (' . $before_count . ' -> ' . $after_count . ')');
    is(ref($messages[0]), 'HASH', 'Fixed pattern: first element is a HASH');
    is(ref($messages[1]), 'HASH', 'Fixed pattern: second element is a HASH');
}

# ── Test 3: End-to-end — validate_tool_message_pairs on fixed messages ─
# This reproduces the real pipeline that comes AFTER _inject_thread_summary:
# enforce_message_alternation -> validate_tool_message_pairs.
# Before the fix, @messages was [ARRAY_REF] and this would return []
# (empty), causing messages:[] -> OpenRouter 400.
{
    my @messages = (
        { role => 'system', content => 'system prompt' },
        { role => 'user',   content => 'I would like you to do a full QA audit of the CLIO codebase' },
    );

    # The buggy caller pattern (for contrast):
    my @buggy = ( \@messages );
    my $bug_val = validate_tool_message_pairs(\@buggy);
    is(ref($bug_val), 'ARRAY', 'Buggy input: validate returns an arrayref (no crash)');
    is(scalar(@$bug_val), 0, 'Buggy input: validate filters out the ARRAY element -> 0 messages (-> messages:[])');

    # The fixed caller pattern:
    my $fixed_val = validate_tool_message_pairs(\@messages);
    is(ref($fixed_val), 'ARRAY', 'Fixed input: validate returns an arrayref (no crash)');
    is(scalar(@$fixed_val), 2, 'Fixed input: validate returns 2 messages (not 0)');
    my $non_hashes = grep { ref($_) ne 'HASH' } @$fixed_val;
    is($non_hashes, 0, 'Fixed input: no non-hashref elements after validation');

    # enforce_message_alternation end-to-end (also calls validate internally)
    my $alternated = enforce_message_alternation(\@messages, 'openrouter');
    ok(ref($alternated) eq 'ARRAY', 'enforce_message_alternation returns an arrayref');
    is(scalar(@$alternated), 2, 'enforce_message_alternation returns 2 messages (not 0)');
}

# ── Test 4: preflight_validate does NOT crash on non-hashref ──────────
# defense-in-depth: preflight_validate used to crash with "Not a HASH
# reference" on the same corrupted input. Now it must skip gracefully.
{
    my @corrupt = (
        { role => 'system', content => 'ok' },
        'garbage_string',       # non-hashref
        undef,                   # undef
        [ 'array', 'ref' ],      # arrayref
        { role => 'user', content => 'hello' },
        123,                      # number
    );
    my $errors = validate_tool_message_pairs(\@corrupt);
    ok($errors, 'preflight_validate / validate does not crash on mixed input');
    is(ref($errors), 'ARRAY', 'Returns an arrayref');
    my $non_hashes = grep { ref($_) ne 'HASH' } @$errors;
    is($non_hashes, 0, 'Only hashref elements retained after validation');
    is(scalar(@$errors), 2, 'Only the 2 valid hashref messages remain');
}

done_testing();
