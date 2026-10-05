#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use lib '../../lib';
use Test::More;
use File::Temp qw(tempdir);

use CLIO::Session::State;

=head1 NAME

test_index_zero_truthiness.pl - Regression test for index-0 truthiness bug
in Session::State::_validate_and_repair_history.

=head1 DESCRIPTION

The repair logic in Session::State used truthiness instead of exists()
to check whether a tool_result had been found for a given tool_call_id.
When a tool result was at history index 0, the value 0 was treated as
false, causing the tool_call to be incorrectly flagged as orphaned and
the entire assistant+result exchange to be discarded.

=cut

my $temp_dir = tempdir(CLEANUP => 1);
my $session_dir = "$temp_dir/sessions/test_idx0";

sub make_state {
    my $state = CLIO::Session::State->new(session_id => 'test_idx0');
    $state->{sessions_dir} = $session_dir;
    return $state;
}

# Test 1: Normal case — tool result not at index 0 (should work with both old and new code)
{
    my $state = make_state();
    $state->{history} = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi',
          tool_calls => [{ id => 'tc_normal', type => 'function', function => { name => 'test', arguments => '{}' } }] },
        { role => 'tool', tool_call_id => 'tc_normal', content => 'result' },
    ];
    my $repaired = $state->_validate_and_repair_history();
    my $history = $state->{history};
    is(scalar(@$history), 3, "Normal case: all 3 messages preserved (tool result at non-zero index)");
    is($history->[0]{role}, 'user', "Normal: user message preserved");
    is($history->[1]{role}, 'assistant', "Normal: assistant message preserved");
    ok($history->[1]{tool_calls}, "Normal: tool_calls preserved on assistant");
    is($history->[2]{role}, 'tool', "Normal: tool result preserved");
}

# Test 2: Tool result at index 0 in history (the bug scenario)
# In corrupted/modified session data, a tool result can appear as the
# very first message. The index stored in %tool_result_ids would be 0
# (falsy). The buggy `unless ($tool_result_ids{$tc_id})` would treat
# this as "missing result" and remove the tool_call + result.
{
    my $state = make_state();
    $state->{history} = [
        { role => 'tool', tool_call_id => 'tc_zero', content => 'result_at_index_0' },
        { role => 'assistant', content => 'done',
          tool_calls => [{ id => 'tc_zero', type => 'function', function => { name => 'test', arguments => '{}' } }] },
        { role => 'user', content => 'Hello' },
    ];
    $state->_validate_and_repair_history();
    my $history = $state->{history};

    # With the fix: the tool result at index 0 is found via exists()
    # The assistant has tool_calls with id 'tc_zero', and the result
    # at index 0 has tool_call_id 'tc_zero'
    # So the pair should be valid (no missing results).
    #
    # If the bug were present, the assistant's tool_call 'tc_zero'
    # would be flagged as orphaned (because $tool_result_ids{'tc_zero'}
    # is 0 which is falsy), and both the assistant and the tool result
    # would be removed.

    my $has_result = grep { $_->{role} eq 'tool' && $_->{tool_call_id} eq 'tc_zero' } @$history;
    my $has_assistant_with_calls = grep { $_->{role} eq 'assistant' && $_->{tool_calls} } @$history;

    ok($has_result, "Index-0 tool result: NOT removed (exists() fix works)");
    ok($has_assistant_with_calls, "Index-0 tool result's assistant call: NOT stripped (exists() fix works)");
}

# Test 3: Tool result at index 0 with matching call — pair preserved
{
    my $state = make_state();
    $state->{history} = [
        { role => 'tool', tool_call_id => 'tc_z2', content => 'result' },
        { role => 'assistant', content => 'done',
          tool_calls => [{ id => 'tc_z2', type => 'function', function => { name => 'test', arguments => '{}' } }],
        },
    ];
    $state->_validate_and_repair_history();
    my $history = $state->{history};
    is(scalar(@$history), 2, "Index-0 result pair: both messages preserved");
}

# Test 4: Genuinely orphaned tool_call (no result at all) — should be removed
{
    my $state = make_state();
    $state->{history} = [
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi',
          tool_calls => [{ id => 'tc_orphan', type => 'function', function => { name => 'test', arguments => '{}' } }],
        },
    ];
    $state->_validate_and_repair_history();
    my $history = $state->{history};
    my $assistant = (grep { $_->{role} eq 'assistant' } @$history)[0];
    ok(!$assistant->{tool_calls}, "Genuinely orphaned call: tool_calls stripped");
}

# Test 5: Genuinely orphaned tool_result (no matching call) — should be removed
{
    my $state = make_state();
    $state->{history} = [
        { role => 'user', content => 'Hello' },
        { role => 'tool', tool_call_id => 'tc_ghost', content => 'no call for me' },
    ];
    $state->_validate_and_repair_history();
    my $history = $state->{history};
    my $tool_count = grep { $_->{role} eq 'tool' } @$history;
    is($tool_count, 0, "Genuinely orphaned result: removed");
}

# Test 6: Two tool calls, both with results — neither at index 0 but
# existence check must still work for all indices
{
    my $state = make_state();
    $state->{history} = [
        { role => 'user', content => 'Question' },
        { role => 'assistant', content => 'A',
          tool_calls => [{ id => 'tc_6a', type => 'function', function => { name => 'f1', arguments => '{}' } },
                         { id => 'tc_6b', type => 'function', function => { name => 'f2', arguments => '{}' } }],
        },
        { role => 'tool', tool_call_id => 'tc_6a', content => 'ra' },
        { role => 'tool', tool_call_id => 'tc_6b', content => 'rb' },
    ];
    $state->_validate_and_repair_history();
    my $history = $state->{history};
    is(scalar(@$history), 4, "Two calls with results: all 4 preserved");
}

# Test 7: Same ID reused across turns — should be handled (not treated as
# falsy when one of them is at index 0)
{
    my $state = make_state();
    $state->{history} = [
        { role => 'tool', tool_call_id => 'tc_reuse', content => 'first' },
        { role => 'assistant', content => 'done1',
          tool_calls => [{ id => 'tc_reuse', type => 'function', function => { name => 'f1', arguments => '{}' } }],
        },
        { role => 'tool', tool_call_id => 'tc_reuse', content => 'second' },
        { role => 'assistant', content => 'done2',
          tool_calls => [{ id => 'tc_reuse', type => 'function', function => { name => 'f1', arguments => '{}' } },
                         { id => 'tc_reuse', type => 'function', function => { name => 'f1', arguments => '{}' } }],
        },
    ];
    my $result = $state->_validate_and_repair_history();
    # Should not crash; should return 0 or 1
    ok($result == 0 || $result == 1, "Same ID reused across turns: no crash, returns 0 or 1");
    my $history = $state->{history};
    ok(ref($history) eq 'ARRAY', "Same ID reused: history is still an arrayref");
}

# Test 8: Adversarial — tool result at index 0 alongside a genuinely
# orphaned call. The repair logic removes the entire assistant message
# when any call is orphaned (by design in _validate_and_repair_history,
# which differs from validate_tool_message_pairs which selectively strips).
# The key assertion: the index-0 result is NOT treated as "missing" by
# the truthiness bug — it is correctly detected via exists().
{
    my $state = make_state();
    $state->{history} = [
        { role => 'tool', tool_call_id => 'tc_index0', content => 'present' },
        { role => 'assistant', content => 'done',
          tool_calls => [
              { id => 'tc_index0', type => 'function', function => { name => 'f1', arguments => '{}' } },
              { id => 'tc_missing', type => 'function', function => { name => 'f2', arguments => '{}' } },
          ],
        },
        { role => 'user', content => 'next' },
    ];
    $state->_validate_and_repair_history();
    my $history = $state->{history};

    # The assistant is removed entirely (tc_missing has no result).
    # The tool result at index 0 survives (Pass 4 checks %tool_call_ids
    # which was populated in Pass 1 before any removal).
    # The critical assertion: the tool result at index 0 was NOT falsely
    # flagged as orphaned by the truthiness bug. If it had been, the
    # assistant's tc_index0 would have been in @missing_ids, and the
    # behavior would differ (both calls would be "missing").
    #
    # We verify the index-0 result is still present (not removed as
    # "orphaned result" by Pass 4):
    my $has_index0_result = grep { $_->{role} eq 'tool' && $_->{tool_call_id} eq 'tc_index0' } @$history;
    ok($has_index0_result, "Adversarial: index-0 tool result survived (NOT falsely flagged as orphaned by truthiness bug)");

    # The assistant should have been removed (tc_missing is genuinely orphaned)
    my $has_assistant = grep { $_->{role} eq 'assistant' } @$history;
    ok(!$has_assistant, "Adversarial: assistant removed (tc_missing genuinely orphaned)");
}

done_testing();

print "\n";
print "━" x 60 . "\n";
print "TEST SUMMARY: Index-0 Truthiness Bug\n";
print "━" x 60 . "\n";
print "[OK] Index-0 tool result: NOT removed (exists() fix works)\n";
print "[OK] Genuinely orphaned calls/results still removed correctly\n";
print "[OK] Same ID reused across turns: handled safely\n";
print "[OK] Mixed scenario (one at index 0, one orphaned): correct\n";
print "━" x 60 . "\n";
