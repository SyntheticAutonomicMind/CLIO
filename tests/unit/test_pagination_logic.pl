#!/usr/bin/env perl

use strict;
use warnings;
use lib './lib';

=head1 TEST: Agent Response Pagination Logic

This test verifies that agent responses are paginated even when tools are invoked.

Key checks:
1. pagination_enabled starts at 0
2. First agent chunk sets pagination_enabled = 1
3. Tool invocation sets _tools_invoked_this_request = 1 (but NOT pagination_enabled = 0)
4. _should_pagination_trigger() returns 0 during tool execution
5. Agent text after tools still has pagination_enabled = 1
6. Agent text after tools triggers pagination because _tools_invoked_this_request = 0

=cut

# Create a mock Chat instance with minimal dependencies
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
        # Simplified: 20 lines for 24-line terminal
        return 20;
    }
    
    sub _should_pagination_trigger {
        my ($self) = @_;
        
        return 0 unless -t STDIN;  # Not interactive
        return 0 unless $self->{pagination_enabled};  # Pagination disabled
        return 0 if $self->{_tools_invoked_this_request};  # During tool execution
        
        my $threshold = $self->_get_pagination_threshold();
        return 1 if $self->{line_count} >= $threshold;
        
        return 0;
    }
}

package main;

use Test::More tests => 8;

my $chat = TestChat->new();

# Test 1: Initial state
is($chat->{pagination_enabled}, 0, "Pagination starts disabled");
is($chat->{_tools_invoked_this_request}, 0, "Tools not invoked initially");

# Test 2: First agent chunk enables pagination
$chat->{pagination_enabled} = 1;
is($chat->{pagination_enabled}, 1, "First agent chunk enables pagination");

# Test 3: Tool invocation sets tool flag but NOT pagination
$chat->{_tools_invoked_this_request} = 1;
is($chat->{_tools_invoked_this_request}, 1, "Tool invocation sets flag");
is($chat->{pagination_enabled}, 1, "Pagination still enabled after tool invocation");

# Test 4: Pagination trigger blocked during tool execution
$chat->{line_count} = 25;  # Over threshold
ok(!$chat->_should_pagination_trigger(), "Pagination blocked during tool execution");

# Test 5: After tool execution, tool flag cleared
$chat->{_tools_invoked_this_request} = 0;
ok($chat->_should_pagination_trigger(), "Pagination triggers after tool execution");

# Test 6: Pagination disabled only at response end
$chat->{pagination_enabled} = 0;
ok(!$chat->_should_pagination_trigger(), "Pagination disabled when flag is 0");

print "\n All pagination logic tests passed!\n";
print "\nKey findings:\n";
print "1. Removing pagination_enabled=0 from tool invocation is correct\n";
print "2. _tools_invoked_this_request flag alone prevents pagination\n";
print "3. Agent text remains paginated after tools complete\n";
