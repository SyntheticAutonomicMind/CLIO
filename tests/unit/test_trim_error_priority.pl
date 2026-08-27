#!/usr/bin/env perl
# Regression test for Bug C: error-first trim priority.
#
# When trim budget is exhausted by non-error content, error tool_result units
# (TOOL ERROR responses with schema dumps) should be the FIRST candidates
# for dropping. Without this, the prompt fills with stale error messages
# that the model no longer needs, pushing out valuable context.
#
# Fix: mark tool_results starting with "TOOL ERROR", "ERROR:", or "STOP:"
# as has_tool_error during unit grouping. The budget walk defers error
# units to a second pass that only includes them if budget allows, after
# non-error units have been placed.

use strict;
use warnings;
use utf8;
use lib '../../lib';
use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

# Build a messages array with mixed error and non-error content - enough
# that the trim is forced to make trade-offs. With 15 good units (~24K
# tokens each) + 15 error units (~40K each), trim_threshold=8000 forces
# drop, and we expect error units to be dropped first.
my @messages;
push @messages, { role => 'system', content => 'CLIO System Prompt ' . ('X' x 1000) };
push @messages, { role => 'user', content => 'Do something useful' };

for my $i (1..15) {
    my $tc_id = "tc_good_$i";
    push @messages, {
        role => 'assistant',
        content => "Step $i",
        tool_calls => [{ id => $tc_id, type => 'function', function => { name => 'terminal_operations', arguments => "{\"operation\":\"exec\",\"command\":\"ls $i\"}" } }],
    };
    push @messages, {
        role => 'tool',
        tool_call_id => $tc_id,
        content => "File contents for $i " . ('a' x 2000),
    };
}

for my $i (1..15) {
    my $tc_id = "tc_err_$i";
    push @messages, {
        role => 'assistant',
        content => "Bad step $i",
        tool_calls => [{ id => $tc_id, type => 'function', function => { name => 'terminal_operations', arguments => "{\"command\":\"ls $i\"}" } }],
    };
    push @messages, {
        role => 'tool',
        tool_call_id => $tc_id,
        content => "TOOL ERROR: terminal_operations\n" . ('b' x 4000),
    };
}

push @messages, { role => 'user', content => 'continue' };

# With a tight budget, error units should be dropped first.
my $result = validate_and_truncate(
    messages => \@messages,
    model_capabilities => { max_prompt_tokens => 30000 },
    tools => [],
    token_ratio => 2.5,
    trim_threshold => 8000,
    disable_post_trim_floor => 1,
);

# Count error vs non-error tool results in the trimmed output
my ($err_count, $good_count) = (0, 0);
for my $m (@$result) {
    next unless ($m->{role} // '') eq 'tool';
    my $c = $m->{content} // '';
    if ($c =~ /^TOOL ERROR:/) {
        $err_count++;
    } else {
        $good_count++;
    }
}

ok($good_count > 0, "At least some non-error tool results preserved (got $good_count)");
ok($err_count < 15, "At least some error tool results dropped (got $err_count, was 15 in input)");

# Verify the order: when both are present, the latest unit is at the END
# (interleaved ordering preserved)
my $last_role = '';
my $prev_role = '';
my $interleaving_ok = 1;
my @roles = map { $_->{role} // '?' } @$result;
# We expect: [system][user][assistant,tool pairs interleaved][user]
# So we should NOT see two consecutive tool messages without an assistant in between
for my $i (1..$#roles) {
    if ($roles[$i] eq 'tool' && $roles[$i-1] eq 'tool') {
        $interleaving_ok = 0;
        last;
    }
}
ok($interleaving_ok, "Tool results are interleaved with assistant messages (no consecutive tool messages)");

done_testing();
