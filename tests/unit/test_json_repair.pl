#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use CLIO::Util::JSONRepair qw(repair_malformed_json);
use JSON::PP qw(decode_json);

print "Testing JSONRepair with malformed examples...\n\n";

my $tests_passed = 0;
my $tests_failed = 0;

# Test 1: Missing value for parameter (no whitespace)
my $test1 = '{"operation":"read_tool_result","offset":,"length":8192}';

print "Test 1: Missing value for offset parameter\n";
print "Input: $test1\n";
my $fixed1 = repair_malformed_json($test1, 0);
print "Fixed: $fixed1\n";

eval {
    my $parsed = decode_json($fixed1);
    print "  PASSED: Operation: $parsed->{operation}\n";
    $tests_passed++;
};
if ($@) {
    print "  FAILED: $@\n";
    $tests_failed++;
}

print "\n";

# Test 2: Missing value with whitespace before comma
my $test2 = '{"operation":"read_tool_result","offset": ,"length":8192}';

print "Test 2: Missing value with whitespace before comma\n";
print "Input: $test2\n";
my $fixed2 = repair_malformed_json($test2, 0);
print "Fixed: $fixed2\n";

eval {
    my $parsed = decode_json($fixed2);
    print "  PASSED: Operation: $parsed->{operation}, offset: " . (defined $parsed->{offset} ? $parsed->{offset} : 'null') . "\n";
    $tests_passed++;
};
if ($@) {
    print "  FAILED: $@\n";
    $tests_failed++;
}

print "\n";

# Test 3: Trailing comma before closing brace
my $test3 = '{"operation":"read_file","path":"test.txt"}';

print "Test 3: Trailing comma before closing brace\n";
print "Input: $test3\n";
my $fixed3 = repair_malformed_json($test3, 0);
print "Fixed: $fixed3\n";

eval {
    my $parsed = decode_json($fixed3);
    print "  PASSED: Operation: $parsed->{operation}\n";
    $tests_passed++;
};
if ($@) {
    print "  FAILED: $@\n";
    $tests_failed++;
}

print "\n";

# Test 4: Decimal without leading zero (JavaScript-style)
# This is the bug from gpt-5.2 - sending .1 instead of 0.1
my $test4 = '{"operation":"update","todoUpdates":[{"id":2,"status":"in-progress","progress":.1}]}';

print "Test 4: Decimal without leading zero (.1 instead of 0.1)\n";
print "Input: $test4\n";
my $fixed4 = repair_malformed_json($test4, 0);
print "Fixed: $fixed4\n";

eval {
    my $parsed = decode_json($fixed4);
    my $progress = $parsed->{todoUpdates}[0]{progress};
    if ($progress == 0.1) {
        print "  PASSED: progress: $progress\n";
        $tests_passed++;
    } else {
        die "Progress value incorrect: expected 0.1, got $progress";
    }
};
if ($@) {
    print "  FAILED: $@\n";
    $tests_failed++;
}

print "\n";

# Test 5: Multiple decimals without leading zeros
my $test5 = '{"operation":"update","todoUpdates":[{"id":1,"progress":.05},{"id":2,"progress":.99}]}';

print "Test 5: Multiple decimals without leading zeros (.05 and .99)\n";
print "Input: $test5\n";
my $fixed5 = repair_malformed_json($test5, 0);
print "Fixed: $fixed5\n";

eval {
    my $parsed = decode_json($fixed5);
    my $p1 = $parsed->{todoUpdates}[0]{progress};
    my $p2 = $parsed->{todoUpdates}[1]{progress};
    if ($p1 == 0.05 && $p2 == 0.99) {
        print "  PASSED: progress values: $p1, $p2\n";
        $tests_passed++;
    } else {
        die "Progress values incorrect: expected 0.05 and 0.99, got $p1 and $p2";
    }
};
if ($@) {
    print "  FAILED: $@\n";
    $tests_failed++;
}

print "\n";

# Test 6: Decimal without leading zero with whitespace after colon
my $test6 = '{"operation":"update","todoUpdates":[{"id":2,"status":"in-progress","progress": .25}]}';

print "Test 6: Decimal without leading zero with whitespace (: .25)\n";
print "Input: $test6\n";
my $fixed6 = repair_malformed_json($test6, 0);
print "Fixed: $fixed6\n";

eval {
    my $parsed = decode_json($fixed6);
    my $progress = $parsed->{todoUpdates}[0]{progress};
    if ($progress == 0.25) {
        print "  PASSED: progress: $progress\n";
        $tests_passed++;
    } else {
        die "Progress value incorrect: expected 0.25, got $progress";
    }
};
if ($@) {
    print "  FAILED: $@\n";
    $tests_failed++;
}

print "\n";

# Test 7: Negative decimal without leading zero
my $test7 = '{"value":-.5}';

print "Test 7: Negative decimal without leading zero (-.5)\n";
print "Input: $test7\n";
my $fixed7 = repair_malformed_json($test7, 0);
print "Fixed: $fixed7\n";

eval {
    my $parsed = decode_json($fixed7);
    my $value = $parsed->{value};
    if ($value == -0.5) {
        print "  PASSED: value: $value\n";
        $tests_passed++;
    } else {
        die "Value incorrect: expected -0.5, got $value";
    }
};
if ($@) {
    print "  FAILED: $@\n";
    $tests_failed++;
}

print "\n";

# Test 8: The exact error from gpt-5.2 logs
my $test8 = '{"operation":"update","todoUpdates":[{"id":2,"status":"in-progress","progress":.1}]}';

print "Test 8: Exact error from gpt-5.2 logs\n";
print "Input: $test8\n";
my $fixed8 = repair_malformed_json($test8, 0);
print "Fixed: $fixed8\n";

eval {
    my $parsed = decode_json($fixed8);
    my $id = $parsed->{todoUpdates}[0]{id};
    my $status = $parsed->{todoUpdates}[0]{status};
    my $progress = $parsed->{todoUpdates}[0]{progress};
    if ($id == 2 && $status eq 'in-progress' && $progress == 0.1) {
        print "  PASSED: id=$id, status=$status, progress=$progress\n";
        $tests_passed++;
    } else {
        die "Values incorrect";
    }
};
if ($@) {
    print "  FAILED: $@\n";
    $tests_failed++;
}

print "\n";

# Summary
print "=" x 50 . "\n";
if ($tests_failed == 0) {
    print "All $tests_passed tests passed!\n";
    exit 0;
} else {
    print "FAILED: $tests_failed tests failed, $tests_passed passed\n";
    exit 1;
}
