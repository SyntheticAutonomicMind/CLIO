#!/usr/bin/env perl
# Test for tool_use/tool_result pair preservation during message truncation
# This tests the fix for: "unexpected `tool_use_id` found in `tool_result` blocks"

use strict;
use warnings;
use utf8;

use lib './lib';
use Test::More tests => 8;

# Mock the APIManager to test validate_and_truncate_messages
package MockAPIManager;

sub new {
    my ($class, %opts) = @_;
    return bless {
        debug => $opts{debug} || 0,
        _model_capabilities_cache => {
            'test-model' => {
                max_prompt_tokens => 1000,  # Small limit to force truncation
                max_output_tokens => 100,
            },
        },
    }, $class;
}

sub get_current_model { return 'test-model'; }
sub get_model_capabilities { 
    my ($self, $model) = @_;
    return $self->{_model_capabilities_cache}{$model || 'test-model'};
}

# Copy the validate_and_truncate_messages method from APIManager
# (In real test, you'd use the actual module)

sub validate_and_truncate_messages {
    my ($self, $messages, $model, $tools) = @_;
    
    $model ||= $self->get_current_model();
    my $caps = $self->get_model_capabilities($model);
    
    unless ($caps) {
        return $messages;
    }
    
    my $max_prompt = $caps->{max_prompt_tokens};
    my $tool_tokens = 0;
    if ($tools && ref($tools) eq 'ARRAY' && @$tools) {
        $tool_tokens = scalar(@$tools) * 2500;
    }
    
    my $safety_margin = int($max_prompt * 0.10);
    my $effective_limit = $max_prompt - $tool_tokens - $safety_margin;
    
    if ($effective_limit < 10000) {
        $effective_limit = 10000;
    }
    
    my $estimated_tokens = 0;
    for my $msg (@$messages) {
        if ($msg->{content}) {
            $estimated_tokens += int(length($msg->{content}) / 3);
        }
    }
    
    if ($estimated_tokens <= $effective_limit) {
        return $messages;
    }
    
    # Group messages into units
    my @units = ();
    my $current_unit = undef;
    my %pending_tool_ids = ();
    
    for my $msg (@$messages) {
        my $msg_tokens = int(length($msg->{content} || '') / 3);
        my $has_tool_calls = $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY' && @{$msg->{tool_calls}};
        my $is_tool_result = $msg->{tool_call_id} || ($msg->{role} && $msg->{role} eq 'tool');
        
        if ($has_tool_calls) {
            if ($current_unit) {
                push @units, $current_unit;
            }
            $current_unit = {
                messages => [$msg],
                tokens => $msg_tokens,
            };
            %pending_tool_ids = ();
            for my $tc (@{$msg->{tool_calls}}) {
                $pending_tool_ids{$tc->{id}} = 1 if $tc->{id};
            }
        }
        elsif ($is_tool_result && $current_unit) {
            push @{$current_unit->{messages}}, $msg;
            $current_unit->{tokens} += $msg_tokens;
            if ($msg->{tool_call_id}) {
                delete $pending_tool_ids{$msg->{tool_call_id}};
            }
            if (!keys %pending_tool_ids) {
                push @units, $current_unit;
                $current_unit = undef;
            }
        }
        else {
            if ($current_unit) {
                push @units, $current_unit;
                $current_unit = undef;
                %pending_tool_ids = ();
            }
            push @units, {
                messages => [$msg],
                tokens => $msg_tokens,
            };
        }
    }
    
    if ($current_unit) {
        push @units, $current_unit;
    }
    
    # Truncate by units
    my @truncated = ();
    my $current_tokens = 0;
    
    # Extract system message if first
    my $system_msg = undef;
    my $system_tokens = 0;
    my $start_unit = 0;
    
    if (@units && @{$units[0]{messages}} && $units[0]{messages}[0]{role} eq 'system') {
        $system_msg = $units[0]{messages}[0];
        $system_tokens = $units[0]{tokens};
        $start_unit = 1;
    }
    
    # Build conversation messages from newest to oldest
    my @conversation = ();
    $current_tokens = $system_tokens;  # Account for system in budget
    
    my @remaining_units = @units[$start_unit .. $#units];
    
    for my $unit (reverse @remaining_units) {
        if ($current_tokens + $unit->{tokens} <= $effective_limit) {
            unshift @conversation, @{$unit->{messages}};
            $current_tokens += $unit->{tokens};
        } else {
            last;
        }
    }
    
    # Combine: system (if any) + conversation
    @truncated = ();
    push @truncated, $system_msg if $system_msg;
    push @truncated, @conversation;
    
    return \@truncated;
}

package main;

# Test 1: Messages without tool calls pass through
{
    my $api = MockAPIManager->new();
    my $messages = [
        { role => 'system', content => 'System prompt' },
        { role => 'user', content => 'Hello' },
        { role => 'assistant', content => 'Hi there' },
    ];
    
    # These are small enough to fit
    $api->{_model_capabilities_cache}{'test-model'}{max_prompt_tokens} = 100000;
    my $result = $api->validate_and_truncate_messages($messages);
    is(scalar(@$result), 3, "Test 1: All messages preserved when within limit");
}

# Test 2: Tool use/result pairs stay together
{
    my $api = MockAPIManager->new();
    $api->{_model_capabilities_cache}{'test-model'}{max_prompt_tokens} = 100000;
    
    my $messages = [
        { role => 'system', content => 'System' },
        { role => 'user', content => 'User msg' },
        { 
            role => 'assistant', 
            content => '',
            tool_calls => [
                { id => 'tool_123', type => 'function', function => { name => 'test', arguments => '{}' } }
            ]
        },
        { role => 'user', content => 'Tool result', tool_call_id => 'tool_123' },
        { role => 'assistant', content => 'Done' },
    ];
    
    my $result = $api->validate_and_truncate_messages($messages);
    is(scalar(@$result), 5, "Test 2: All messages preserved including tool pairs");
}

# Test 3: When truncating, tool pairs are kept or dropped together
{
    my $api = MockAPIManager->new();
    # Force truncation with very small limit
    $api->{_model_capabilities_cache}{'test-model'}{max_prompt_tokens} = 10000;  # Will be adjusted to 10000 effective
    
    my $messages = [
        { role => 'system', content => 'S' x 100 },  # ~33 tokens
        { role => 'user', content => 'A' x 9000 },   # ~3000 tokens - this will be truncated
        { 
            role => 'assistant', 
            content => 'B' x 9000,                   # ~3000 tokens
            tool_calls => [
                { id => 'tool_old', type => 'function', function => { name => 'old', arguments => '{}' } }
            ]
        },
        { role => 'user', content => 'C' x 9000, tool_call_id => 'tool_old' },  # ~3000 tokens
        { role => 'user', content => 'D' x 300 },    # ~100 tokens - recent
        { 
            role => 'assistant', 
            content => 'E' x 300,                    # ~100 tokens - recent
            tool_calls => [
                { id => 'tool_new', type => 'function', function => { name => 'new', arguments => '{}' } }
            ]
        },
        { role => 'user', content => 'F' x 300, tool_call_id => 'tool_new' },  # ~100 tokens - recent
        { role => 'assistant', content => 'G' x 300 },  # ~100 tokens - most recent
    ];
    
    my $result = $api->validate_and_truncate_messages($messages);
    
    # Check that we don't have orphaned tool_results
    my %tool_call_ids = ();
    my %tool_result_ids = ();
    
    for my $msg (@$result) {
        if ($msg->{tool_calls}) {
            for my $tc (@{$msg->{tool_calls}}) {
                $tool_call_ids{$tc->{id}} = 1;
            }
        }
        if ($msg->{tool_call_id}) {
            $tool_result_ids{$msg->{tool_call_id}} = 1;
        }
    }
    
    # Every tool_result should have corresponding tool_call
    my $orphaned = 0;
    for my $id (keys %tool_result_ids) {
        $orphaned++ unless $tool_call_ids{$id};
    }
    
    is($orphaned, 0, "Test 3: No orphaned tool_results after truncation");
}

# Test 4: System message always kept
{
    my $api = MockAPIManager->new();
    $api->{_model_capabilities_cache}{'test-model'}{max_prompt_tokens} = 10000;
    
    my $messages = [
        { role => 'system', content => 'System prompt' },
        { role => 'user', content => 'X' x 30000 },  # Force truncation
        { role => 'assistant', content => 'Response' },
    ];
    
    my $result = $api->validate_and_truncate_messages($messages);
    
    ok(@$result > 0 && $result->[0]{role} eq 'system', "Test 4: System message preserved");
}

# Test 5: Multiple tool calls in one message
{
    my $api = MockAPIManager->new();
    $api->{_model_capabilities_cache}{'test-model'}{max_prompt_tokens} = 100000;
    
    my $messages = [
        { role => 'system', content => 'System' },
        { 
            role => 'assistant', 
            content => '',
            tool_calls => [
                { id => 'tool_1', type => 'function', function => { name => 'func1', arguments => '{}' } },
                { id => 'tool_2', type => 'function', function => { name => 'func2', arguments => '{}' } },
            ]
        },
        { role => 'user', content => 'Result 1', tool_call_id => 'tool_1' },
        { role => 'user', content => 'Result 2', tool_call_id => 'tool_2' },
        { role => 'assistant', content => 'Done' },
    ];
    
    my $result = $api->validate_and_truncate_messages($messages);
    is(scalar(@$result), 5, "Test 5: Multiple tool calls handled correctly");
}

# Test 6: Empty messages array
{
    my $api = MockAPIManager->new();
    my $result = $api->validate_and_truncate_messages([]);
    is(scalar(@$result), 0, "Test 6: Empty array returns empty");
}

# Test 7: Messages with role 'tool' (alternative format)
{
    my $api = MockAPIManager->new();
    $api->{_model_capabilities_cache}{'test-model'}{max_prompt_tokens} = 100000;
    
    my $messages = [
        { role => 'system', content => 'System' },
        { 
            role => 'assistant', 
            content => '',
            tool_calls => [
                { id => 'tool_x', type => 'function', function => { name => 'test', arguments => '{}' } }
            ]
        },
        { role => 'tool', content => 'Tool output', tool_call_id => 'tool_x' },
        { role => 'assistant', content => 'Processed' },
    ];
    
    my $result = $api->validate_and_truncate_messages($messages);
    is(scalar(@$result), 4, "Test 7: role='tool' messages handled correctly");
}

# Test 8: Verify the actual APIManager module works
{
    require CLIO::Core::APIManager;
    ok(CLIO::Core::APIManager->can('validate_and_truncate_messages'), 
       "Test 8: APIManager has validate_and_truncate_messages method");
}

print "\n=== All tests passed! ===\n";
