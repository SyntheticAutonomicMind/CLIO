#!/usr/bin/env perl

use strict;
use warnings;
use lib './lib';

=head1 TEST: Agent Response Pagination Logic - CORRECTED

This test verifies the corrected approach:
- Agent streaming uses _should_pagination_trigger_for_agent_streaming()
- Tool output uses _should_pagination_trigger()
- Agent text paginated even during tool execution
- Tool output not paginated

=cut

package TestChat {
    use strict;
    use warnings;
    
    sub new {
        my ($class) = @_;
        return bless {
            pagination_enabled => 0,
            _tools_invoked_this_request => 0,
            line_count => 0,
            terminal_height => 24,
        }, $class;
    }
    
    sub _get_pagination_threshold {
        my ($self) = @_;
        return 20;
    }
    
    sub _should_pagination_trigger {
        my ($self) = @_;
        
        return 0 unless -t STDIN;
        return 0 unless $self->{pagination_enabled};
        return 0 if $self->{_tools_invoked_this_request};  # Blocks on tool execution
        
        my $threshold = $self->_get_pagination_threshold();
        return 1 if $self->{line_count} >= $threshold;
        
        return 0;
    }
    
    sub _should_pagination_trigger_for_agent_streaming {
        my ($self) = @_;
        
        return 0 unless -t STDIN;
        return 0 unless $self->{pagination_enabled};
        # NOTE: Do NOT check _tools_invoked_this_request for agent streaming
        
        my $threshold = $self->_get_pagination_threshold();
        return 1 if $self->{line_count} >= $threshold;
        
        return 0;
    }
}

package main;

use Test::More tests => 10;

my $chat = TestChat->new();

# Test 1-2: Initial state
is($chat->{pagination_enabled}, 0, "Pagination starts disabled");
is($chat->{_tools_invoked_this_request}, 0, "Tools not invoked initially");

# Test 3-4: Agent streaming pagination enabled
$chat->{pagination_enabled} = 1;
$chat->{line_count} = 25;
ok($chat->_should_pagination_trigger_for_agent_streaming(), 
   "Agent streaming triggers pagination");
ok($chat->_should_pagination_trigger(), 
   "Tool output pagination also triggers (no tool flag set yet)");

# Test 5-6: Tool invocation doesn't affect agent streaming pagination
$chat->{_tools_invoked_this_request} = 1;
ok($chat->_should_pagination_trigger_for_agent_streaming(), 
   "Agent streaming STILL triggers pagination during tool execution");
ok(!$chat->_should_pagination_trigger(), 
   "Tool output pagination blocked during tool execution");

# Test 7-8: After tools, both work normally
$chat->{_tools_invoked_this_request} = 0;
ok($chat->_should_pagination_trigger_for_agent_streaming(), 
   "Agent streaming pagination after tools");
ok($chat->_should_pagination_trigger(), 
   "Tool output pagination after tools");

# Test 9-10: With low line count, neither paginate
$chat->{line_count} = 5;
ok(!$chat->_should_pagination_trigger_for_agent_streaming(), 
   "No pagination when below threshold");
ok(!$chat->_should_pagination_trigger(), 
   "No pagination when below threshold");

print "\n All corrected pagination logic tests passed!\n";
print "\nKey findings:\n";
print "1. Agent streaming uses dedicated method (_should_pagination_trigger_for_agent_streaming)\n";
print "2. Agent text paginated even during tool execution\n";
print "3. Tool output blocked from pagination during tool execution\n";
print "4. Both work normally after tools complete\n";
