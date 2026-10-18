#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
#
# Test: Collaboration Q/A extraction and Discussion section.
# Updated for the new YaRN format ("Discussion:" header, 10-exchange
# default at 128K context). Note: "Tool operations:" section was removed
# in commit cd0de94d for cache stability — tool counts are non-deterministic.

use strict;
use warnings;
use utf8;
use lib './lib';

use CLIO::Memory::YaRN;

# Use Test::More to avoid the list-context regex gotcha where
# ok($content =~ /pat/, $desc) silently passes when the regex fails
# (because a failed =~ returns () in list context, making ok() treat
# the description string as the condition — which is truthy).
use Test::More;

my $yarn = CLIO::Memory::YaRN->new();

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

    my $content = $result->{content};
    like($content, qr/Discussion:/, 'Contains Discussion section');
    like($content, qr/abbreviate/i, 'Contains user response about abbreviation');
    like($content, qr/24 ch/i, 'Contains details about 24 chars');
    like($content, qr/24 col/i, 'Contains details about 24 columns');
    like($content, qr/separator/i, 'Contains user response about separator');
}

# Test 2: Non-collaboration messages don't create fake Discussion
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
    unlike($content, qr/Discussion:/, 'No Discussion section for non-collaboration messages');
    unlike($content, qr/Tool operations:/, 'Tool operations section NOT present (removed)');
    unlike($content, qr/file_operations: \d+/, 'file_operations count NOT present');
}

# Test 3: Multiple exchanges - only last N kept.
# Use context_window=65536 to get a collaboration limit of 5 (matching
# the old test's expectation). At 128K the limit is 10, so all 8 would
# be kept — we test the scaling by using a smaller window.
{
    my @messages;
    for my $i (1..8) {
        push @messages, { role => 'assistant', content => '', tool_calls => [
            { id => "tc_multi_$i", function => { name => 'interact', arguments => qq({"operation":"request_input","message":"Question $i about design"}) } }
        ]};
        push @messages, { role => 'tool', tool_call_id => "tc_multi_$i", content => "Response $i from user" };
    }

    my $result = $yarn->compress_messages(\@messages,
        original_task  => 'Design session',
        context_window => 65536,  # collaboration limit = 5
    );
    my $content = $result->{content};
    like($content, qr/Discussion:/, 'Multi-exchange has Discussion section');
    unlike($content, qr/Question 1 about/, 'Oldest exchanges trimmed');
    unlike($content, qr/Question 2 about/, 'Second oldest trimmed');
    unlike($content, qr/Question 3 about/, 'Third oldest trimmed');
    like($content, qr/Question 4 about/, 'Fourth exchange kept');
    like($content, qr/Question 8 about/, 'Latest exchange kept');
}

done_testing();
exit(0);
