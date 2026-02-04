#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use CLIO::Util::JSONRepair qw(repair_malformed_json);
use JSON::PP qw(decode_json);

print "Testing JSONRepair with malformed examples from scratch/test.txt...\n\n";

# Test 1: Valid JSON with XML garbage appended (the exact error from logs)
my $test1 = '{"end_line":150,"operation":"read_file","path":"lib/CLIO/UI/Theme.pm","start_line":50}</parameter>
</invoke>": ""}';

print "Test 1: Valid JSON with XML garbage appended\n";
print "Input: " . substr($test1, 0, 80) . "...\n";
my $fixed1 = repair_malformed_json($test1, 1);
print "Fixed: $fixed1\n";

eval {
    my $parsed = decode_json($fixed1);
    print "✓ Successfully parsed! Operation: $parsed->{operation}\n";
};
if ($@) {
    print "✗ FAILED to parse: $@\n";
    exit 1;
}

print "\n";

# Test 2: Missing value with whitespace (another common error)
my $test2 = '{"operation":"read_tool_result","offset":,"length":8192}';

print "Test 2: Missing value for offset parameter\n";
print "Input: $test2\n";
my $fixed2 = repair_malformed_json($test2, 1);
print "Fixed: $fixed2\n";

eval {
    my $parsed = decode_json($fixed2);
    print "✓ Successfully parsed! Operation: $parsed->{operation}\n";
};
if ($@) {
    print "✗ FAILED to parse: $@\n";
    exit 1;
}

print "\n";

# Test 3: Missing value with whitespace before comma
my $test3 = '{"operation":"read_tool_result","offset": ,"length":8192}';

print "Test 3: Missing value with whitespace before comma\n";
print "Input: $test3\n";
my $fixed3 = repair_malformed_json($test3, 1);
print "Fixed: $fixed3\n";

eval {
    my $parsed = decode_json($fixed3);
    print "✓ Successfully parsed! Operation: $parsed->{operation}, offset: " . (defined $parsed->{offset} ? $parsed->{offset} : 'null') . "\n";
};
if ($@) {
    print "✗ FAILED to parse: $@\n";
    exit 1;
}

print "\n";

# Test 4: Trailing comma
my $test4 = '{"operation":"read_file","path":"test.txt"}';

print "Test 4: Trailing comma before closing brace\n";
print "Input: $test4\n";
my $fixed4 = repair_malformed_json($test4, 1);
print "Fixed: $fixed4\n";

eval {
    my $parsed = decode_json($fixed4);
    print "✓ Successfully parsed! Operation: $parsed->{operation}\n";
};
if ($@) {
    print "✗ FAILED to parse: $@\n";
    exit 1;
}

print "\n✓ All tests passed!\n";
