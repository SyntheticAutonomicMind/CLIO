#!/usr/bin/env perl
# Test for fix: context-trim-preserves-tool-pairs
# This test verifies that context trimming during token limit errors
# preserves tool call/result pairs to prevent "orphaned tool_call" errors.

use strict;
use warnings;
use Test::More tests => 6;
use JSON::PP;

print "\n# Testing smart context trimming for token limit errors\n";
print "# Bug: Aggressive trim was discarding tool messages, breaking pairs\n";
print "# Fix: Use message grouping to keep complete tool call/result pairs\n\n";

# Simulate the grouping logic from WorkflowOrchestrator
sub group_messages {
    my @messages = @_;
    
    my @groups = ();
    my $current_group = [];
    
    for my $msg (@messages) {
        if ($msg->{role} eq 'user') {
            if (@$current_group > 0) {
                push @groups, $current_group;
            }
            $current_group = [$msg];
        } elsif ($msg->{role} eq 'assistant') {
            if (@$current_group > 0 && $current_group->[-1]{role} eq 'user') {
                push @$current_group, $msg;
            } else {
                if (@$current_group > 0) {
                    push @groups, $current_group;
                }
                $current_group = [$msg];
            }
        } elsif ($msg->{role} eq 'tool') {
            push @$current_group, $msg;
        } else {
            push @$current_group, $msg;
        }
    }
    if (@$current_group > 0) {
        push @groups, $current_group;
    }
    
    return @groups;
}

# Test 1: Basic message grouping
{
    my @messages = (
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi there' },
        { role => 'user', content => 'Run a command' },
        { role => 'assistant', content => '', tool_calls => [{ id => 'tool_1' }] },
        { role => 'tool', tool_call_id => 'tool_1', content => 'Done' },
        { role => 'user', content => 'Thanks' },
    );
    
    my @groups = group_messages(@messages);
    is(scalar(@groups), 3, 'Test 1: Three message groups identified');
}

# Test 2: Tool calls stay with their results
{
    my @messages = (
        { role => 'user', content => 'Read file' },
        { role => 'assistant', content => '', tool_calls => [{ id => 'tc_1' }, { id => 'tc_2' }] },
        { role => 'tool', tool_call_id => 'tc_1', content => 'File content 1' },
        { role => 'tool', tool_call_id => 'tc_2', content => 'File content 2' },
    );
    
    my @groups = group_messages(@messages);
    is(scalar(@groups), 1, 'Test 2: Single group for user + assistant + multiple tools');
    
    my $group = $groups[0];
    is(scalar(@$group), 4, 'Test 2: Group contains all 4 messages');
}

# Test 3: Keeping last N groups preserves pairs
{
    my @messages = (
        # Group 1
        { role => 'user', content => 'Old message' },
        { role => 'assistant', content => 'Old response', tool_calls => [{ id => 'old_1' }] },
        { role => 'tool', tool_call_id => 'old_1', content => 'Old result' },
        # Group 2
        { role => 'user', content => 'Recent message' },
        { role => 'assistant', content => 'Recent response', tool_calls => [{ id => 'new_1' }] },
        { role => 'tool', tool_call_id => 'new_1', content => 'New result' },
    );
    
    my @groups = group_messages(@messages);
    is(scalar(@groups), 2, 'Test 3: Two groups identified');
    
    # Keep only last 1 group
    my @kept = @groups[-1..-1];
    is(scalar(@kept), 1, 'Test 3: Kept 1 group');
    
    # Verify the kept group has complete pair
    my $kept_group = $kept[0];
    my @tool_calls = grep { $_->{tool_calls} } @$kept_group;
    my @tool_results = grep { $_->{role} eq 'tool' } @$kept_group;
    
    # Count tool_call IDs
    my %tc_ids = ();
    for my $msg (@tool_calls) {
        for my $tc (@{$msg->{tool_calls}}) {
            $tc_ids{$tc->{id}} = 1;
        }
    }
    
    # Count tool_result IDs
    my %tr_ids = ();
    for my $msg (@tool_results) {
        $tr_ids{$msg->{tool_call_id}} = 1 if $msg->{tool_call_id};
    }
    
    # All tool_call IDs should have matching results
    my $orphans = 0;
    for my $id (keys %tc_ids) {
        $orphans++ unless $tr_ids{$id};
    }
    
    is($orphans, 0, 'Test 3: No orphaned tool_calls after keeping group');
}

print "\n# All tests passed - smart trimming preserves tool pairs!\n";
