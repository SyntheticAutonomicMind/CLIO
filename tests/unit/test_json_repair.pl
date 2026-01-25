#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use lib 'lib';

use CLIO::Util::JSONRepair qw(repair_malformed_json);

# Test cases
my @tests = (
    {
        name => 'Missing value without space',
        input => '{"operation":"read","offset":,"length":8192}',
        expected => '{"operation":"read","offset":null,"length":8192}',
    },
    {
        name => 'Missing value with space (THE BUG)',
        input => '{"operation":"read_tool_result","toolCallId":"toolu_01UDkM4vCXkok5eWFLfcgEyd","offset": ,"length":8192}',
        expected => '{"operation":"read_tool_result","toolCallId":"toolu_01UDkM4vCXkok5eWFLfcgEyd","offset":null,"length":8192}',
    },
    {
        name => 'Multiple missing values',
        input => '{"operation":"read","offset":,"path":"file.txt","content":,"line":100}',
        expected => '{"operation":"read","offset":null,"path":"file.txt","content":null,"line":100}',
    },
    {
        name => 'Trailing comma before }',
        input => '{"operation":"read","path":"file.txt"}',
        expected => '{"operation":"read","path":"file.txt"}',
    },
    {
        name => 'Trailing comma before ]',
        input => '[1,2,3,]',
        expected => '[1,2,3]',
    },
    {
        name => 'Mixed issues',
        input => '{"operation":"read","offset": ,"content":,"items":[1,2,3,]}',
        expected => '{"operation":"read","offset":null,"content":null,"items":[1,2,3]}',
    },
    {
        name => 'No changes needed',
        input => '{"operation":"read","path":"file.txt","line":100}',
        expected => '{"operation":"read","path":"file.txt","line":100}',
    },
);

# Run tests
my $passed = 0;
my $failed = 0;

foreach my $test (@tests) {
    my $result = repair_malformed_json($test->{input}, 0);
    
    if ($result eq $test->{expected}) {
        print "[PASS] $test->{name}\n";
        $passed++;
    } else {
        print "[FAIL] $test->{name}\n";
        print "  Input:    $test->{input}\n";
        print "  Expected: $test->{expected}\n";
        print "  Got:      $result\n";
        $failed++;
    }
}

print "\n$passed passed, $failed failed\n";
exit $failed ? 1 : 0;
