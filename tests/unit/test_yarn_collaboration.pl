#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use lib './lib';

use CLIO::Memory::YaRN;

my $yarn = CLIO::Memory::YaRN->new();
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

# Test 1: Basic collaboration exchange extraction
{
    my @messages = (
        { role => 'user', content => 'Help me design a board game layout' },
        { role => 'assistant', content => '', tool_calls => [
            { id => 'tc_1', function => { name => 'user_collaboration', arguments => '{"operation":"request_input","message":"Here is my proposed layout:\\nGO|MA|CC|BA\\nWhat do you think?"}' } }
        ]},
        { role => 'tool', tool_call_id => 'tc_1', content => 'Can we abbreviate every space? Like GO|MA|CC|BA?' },
        { role => 'assistant', content => '', tool_calls => [
            { id => 'tc_2', function => { name => 'user_collaboration', arguments => '{"operation":"request_input","message":"Good idea! Each space abbreviated to 2 chars. Fits in 24 columns."}' } }
        ]},
        { role => 'tool', tool_call_id => 'tc_2', content => 'We may not be able to use a separator and stay inside our 24 chars though.' },
    );

    my $result = $yarn->compress_messages(\@messages, original_task => 'Design board game');
    ok($result, 'compress_messages returns result');
    ok($result->{content}, 'Result has content');
    
    # Check that collaboration exchanges are captured
    my $content = $result->{content};
    ok($content =~ /Active discussion/i, 'Contains active discussion section');
    ok($content =~ /abbreviate/i, 'Contains user response about abbreviation');
    ok($content =~ /24 ch/i || $content =~ /24 col/i, 'Contains details about 24 chars/columns');
    ok($content =~ /separator/i, 'Contains user response about separator');
}

# Test 2: Non-collaboration messages don't create fake exchanges
{
    my @messages = (
        { role => 'user', content => 'Read the file config.json' },
        { role => 'assistant', content => '', tool_calls => [
            { id => 'tc_3', function => { name => 'file_operations', arguments => '{"operation":"read_file","path":"config.json"}' } }
        ]},
        { role => 'tool', tool_call_id => 'tc_3', content => '{"key": "value"}' },
    );

    my $result = $yarn->compress_messages(\@messages, original_task => 'Read config');
    ok($result, 'Non-collab compress returns result');
    my $content = $result->{content};
    ok($content !~ /Active discussion/i, 'No active discussion for non-collaboration messages');
    ok($content =~ /file_operations/i, 'Tool usage tracked');
}

# Test 3: Multiple exchanges - only last 5 kept
{
    my @messages;
    for my $i (1..8) {
        push @messages, { role => 'assistant', content => '', tool_calls => [
            { id => "tc_multi_$i", function => { name => 'user_collaboration', arguments => qq({"operation":"request_input","message":"Question $i about design"}) } }
        ]};
        push @messages, { role => 'tool', tool_call_id => "tc_multi_$i", content => "Response $i from user" };
    }

    my $result = $yarn->compress_messages(\@messages, original_task => 'Design session');
    my $content = $result->{content};
    # Should have exchanges but limited to 5
    ok($content =~ /Active discussion/i, 'Multi-exchange has active discussion');
    # First 3 should be dropped (8-5=3)
    ok($content !~ /Question 1 about/, 'Oldest exchanges trimmed');
    ok($content !~ /Question 2 about/, 'Second oldest trimmed');
    ok($content !~ /Question 3 about/, 'Third oldest trimmed');
    ok($content =~ /Question 4 about/ || $content =~ /Response 4/, 'Fourth exchange kept');
    ok($content =~ /Question 8 about/ || $content =~ /Response 8/, 'Latest exchange kept');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
