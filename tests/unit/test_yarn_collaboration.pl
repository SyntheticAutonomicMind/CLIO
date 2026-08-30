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
    $desc //= '(no description)';
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
            { id => 'tc_1', function => { name => 'interact', arguments => '{"operation":"request_input","message":"Here is my proposed layout:\\nGO|MA|CC|BA\\nWhat do you think?"}' } }
        ]},
        { role => 'tool', tool_call_id => 'tc_1', content => 'Can we abbreviate every space? Like GO|MA|CC|BA?' },
        { role => 'assistant', content => '', tool_calls => [
            { id => 'tc_2', function => { name => 'interact', arguments => '{"operation":"request_input","message":"Good idea! Each space abbreviated to 2 chars. Fits in 24 columns."}' } }
        ]},
        { role => 'tool', tool_call_id => 'tc_2', content => 'We may not be able to use a separator and stay inside our 24 chars though.' },
    );

    my $result = $yarn->compress_messages(\@messages, original_task => 'Design board game');
    ok($result, 'compress_messages returns result');
    ok($result->{content}, 'Result has content');
    
    # Check that collaboration exchanges are NOT rendered as a
    # "Discussion" section — that pattern caused models to treat the
    # summary as a conversation to respond to rather than context
    # to consume.
    my $content = $result->{content};
    ok($content !~ /Discussion/i, 'No Discussion section (removed to avoid model treating summary as conversation)');
    ok($content !~ /Agent asked/i, 'No "Agent asked" lines in summary');
    ok($content !~ /User replied/i, 'No "User replied" lines in summary');
    ok($content =~ /Decisions/i || $content =~ /Current task/i || $content =~ /Files/i, 'Summary contains work-product sections');
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
    ok($content !~ /Active discussion/i && $content !~ /Discussion:/i, 'No discussion section for non-collaboration messages');
    ok(!($content =~ /file_operations/i), 'No tool counts rendered (removed)');
}

# Test 3: Multiple exchanges - only last 5 kept
{
    my @messages;
    for my $i (1..8) {
        push @messages, { role => 'assistant', content => '', tool_calls => [
            { id => "tc_multi_$i", function => { name => 'interact', arguments => qq({"operation":"request_input","message":"Question $i about design"}) } }
        ]};
        push @messages, { role => 'tool', tool_call_id => "tc_multi_$i", content => "Response $i from user" };
    }

    my $result = $yarn->compress_messages(\@messages, original_task => 'Design session');
    my $content = $result->{content};
    # Should have exchanges but limited to 5
    ok($content =~ /Discussion/i, 'Multi-exchange has discussion section');
    # First 3 should be dropped (8-5=3)
    ok($content !~ /Question 1 about/, 'Oldest exchanges trimmed');
    ok($content !~ /Question 2 about/, 'Second oldest trimmed');
    ok($content !~ /Question 3 about/, 'Third oldest trimmed');
    ok($content =~ /Question 4 about/ || $content =~ /Response 4/, 'Fourth exchange kept');
    ok($content =~ /Question 8 about/ || $content =~ /Response 8/, 'Latest exchange kept');
}

print "\n$pass passed, $fail failed\n";
exit($fail ? 1 : 0);
