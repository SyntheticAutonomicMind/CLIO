#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: _role_based_tail_walk must not produce duplicate
# messages when tool_call pair-keeping pre-pushes an assistant index.
#
# Before the fix: when the tail walk reached a `tool` message, it
# pre-pushed the matching assistant tool_call index into @kept_indices.
# When the loop then reached that same assistant index as $i, it
# unshifted it again without checking for duplicates. The trimmed
# messages array contained the assistant tool_calls message TWICE.
#
# After the fix: the loop checks `grep { $_ == $i } @kept_indices`
# before unshift-ing, so the assistant is added exactly once.
#
# We exercise the trim path via validate_and_truncate with a tight
# budget that forces the tail walk to drop oldest turns while keeping
# the most recent pair.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Core::API::MessageValidator;

# Build a tight-budget scenario: 6 messages, the second-to-last
# assistant has tool_calls. Budget forces the walk to keep just the
# last 3 messages but include the tool_call/tool_result pair.
my $messages = [
    { role => 'user', content => 'task ' . 'x' x 100 },                            # 0
    { role => 'assistant', content => 'first response', tool_calls => [
        { id => 'abc', function => { name => 'foo', arguments => '{}' } }
    ] },                                                                          # 1
    { role => 'tool', tool_call_id => 'abc', content => 'tool result ' . 'x' x 200 }, # 2
    { role => 'user', content => 'next ' . 'y' x 100 },                            # 3
    { role => 'assistant', content => 'second response', tool_calls => [
        { id => 'def', function => { name => 'bar', arguments => '{}' } }
    ] },                                                                          # 4
    { role => 'tool', tool_call_id => 'def', content => 'another result ' . 'x' x 200 }, # 5
];

# Compute total content length to size the budget.
my $total_len = 0;
$total_len += length($_->{content} // '') for @$messages;

# Budget small enough that we have to keep only the most recent turn.
my $trimmed = CLIO::Core::API::MessageValidator::validate_and_truncate(
    messages           => $messages,
    model_capabilities => { max_context_window_tokens => 500, max_output_tokens => 50 },
    tools              => [],
);

# Check for duplicate indices in the trimmed output. Two messages with
# the same role + content + tool_call_ids is the failure mode.
my %seen;
my @dups;
for my $i (0 .. $#$trimmed) {
    my $m = $trimmed->[$i];
    next unless ref($m) eq 'HASH';
    my $tc_ids = '';
    if ($m->{tool_calls}) {
        $tc_ids = join(',', map { $_->{id} // '' } @{$m->{tool_calls}});
    }
    my $key = "$m->{role}|$tc_ids|" . substr($m->{content} // '', 0, 50);
    if ($seen{$key}++) {
        push @dups, "[$i] $key";
    }
}

ok(!@dups, "No duplicate role+tool_call_id+content triples in trimmed output")
    or diag("Duplicates found:\n" . join("\n", @dups));

# Tool pairing: no orphan tool_call or tool_result.
my %call_ids;
my %result_ids;
for my $m (@$trimmed) {
    if ($m->{role} eq 'assistant' && $m->{tool_calls}) {
        for my $tc (@{$m->{tool_calls}}) {
            $call_ids{$tc->{id}} = 1 if $tc->{id};
        }
    }
    if ($m->{role} eq 'tool' && $m->{tool_call_id}) {
        $result_ids{$m->{tool_call_id}} = 1;
    }
}
my @orphans;
for my $id (keys %call_ids) {
    push @orphans, "call $id" unless $result_ids{$id};
}
for my $id (keys %result_ids) {
    push @orphans, "result $id" unless $call_ids{$id};
}
ok(!@orphans, "No orphaned tool_call/tool_result pairs in trimmed output")
    or diag("Orphans: @orphans");

# Also: count assistant+tool_calls messages. Should match count of
# unique tool_call ids.
my $asst_with_calls = grep { $_->{role} eq 'assistant' && $_->{tool_calls} } @$trimmed;
my $unique_call_ids = scalar keys %call_ids;
is($asst_with_calls, $unique_call_ids,
    "Assistant+tool_calls messages count matches unique tool_call ids (no duplicates)");

done_testing();