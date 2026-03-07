#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use lib './lib';

# Need to load WorkflowOrchestrator to get access to the function
# It's a package-level function, so we need to call it with full name
require CLIO::Core::WorkflowOrchestrator;

my $pass = 0;
my $fail = 0;

sub ok {
    my ($cond, $desc) = @_;
    if ($cond) {
        print "ok - $desc\n";
        $pass++;
    } else {
        print "NOT ok - $desc\n";
        $fail++;
    }
}

# Test 1: Extract collaboration topic
{
    my @messages = (
        { role => 'user', content => 'Help me design a board layout' },
        { role => 'assistant', content => 'Sure, let me work on that.' },
        { role => 'assistant', content => '', tool_calls => [
            { id => 'tc_1', function => { name => 'user_collaboration', arguments => '{"operation":"request_input","message":"Here is a 24-column board layout. What do you think?"}' } }
        ]},
        { role => 'tool', tool_call_id => 'tc_1', content => 'Can we abbreviate the space names?' },
        { role => 'assistant', content => '', tool_calls => [
            { id => 'tc_2', function => { name => 'user_collaboration', arguments => '{"operation":"request_input","message":"Good idea! GO|MA|CC|BA format?"}' } }
        ]},
        { role => 'tool', tool_call_id => 'tc_2', content => 'We may not fit a separator in 24 chars.' },
    );

    my $topic = CLIO::Core::WorkflowOrchestrator::_extract_conversation_topic(\@messages);
    ok(defined $topic, 'Topic extracted from collaboration messages');
    ok($topic =~ /ACTIVE DISCUSSION/i, 'Identified as active discussion');
    ok($topic =~ /abbreviate/i, 'Contains user response about abbreviation');
    ok($topic =~ /separator/i || $topic =~ /24 chars/i, 'Contains latest user response');
}

# Test 2: Extract from regular user messages (no collaboration)
{
    my @messages = (
        { role => 'user', content => 'Fix the login bug in auth.py' },
        { role => 'assistant', content => 'Looking at the code now...' },
        { role => 'assistant', content => '', tool_calls => [
            { id => 'tc_3', function => { name => 'file_operations', arguments => '{"operation":"read_file","path":"auth.py"}' } }
        ]},
        { role => 'tool', tool_call_id => 'tc_3', content => 'def login():\n    pass' },
        { role => 'user', content => 'Also check the session handling' },
    );

    my $topic = CLIO::Core::WorkflowOrchestrator::_extract_conversation_topic(\@messages);
    ok(defined $topic, 'Topic extracted from regular messages');
    ok($topic =~ /session handling/i, 'Contains latest user message');
}

# Test 3: Empty messages
{
    my $topic = CLIO::Core::WorkflowOrchestrator::_extract_conversation_topic([]);
    ok(!defined $topic, 'No topic from empty messages');
}

# Test 4: Only system messages
{
    my @messages = (
        { role => 'system', content => 'You are a helpful assistant.' },
    );
    my $topic = CLIO::Core::WorkflowOrchestrator::_extract_conversation_topic(\@messages);
    ok(!defined $topic, 'No topic from system-only messages');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
