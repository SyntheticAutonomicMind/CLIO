#!/usr/bin/env perl

# Integration test: Verify that tool schemas include all necessary parameters
# and that the AI can see what parameters each operation needs

use strict;
use warnings;
use lib 'lib';
use JSON::PP qw(encode_json decode_json);
use CLIO::Tools::Registry;
use CLIO::Tools::MemoryOperations;
use CLIO::Tools::WebOperations;
use CLIO::Tools::CodeIntelligence;

print "Testing operation-specific parameter visibility...\n\n";

my $registry = CLIO::Tools::Registry->new(debug => 0);
$registry->register_tool(CLIO::Tools::MemoryOperations->new());
$registry->register_tool(CLIO::Tools::WebOperations->new());
$registry->register_tool(CLIO::Tools::CodeIntelligence->new());

my $definitions = $registry->get_tool_definitions();

# Test 1: memory_operations should have 'key' and 'content' parameters
print "Test 1: memory_operations has 'key' and 'content' parameters\n";
my ($memory_def) = grep { $_->{function}{name} eq 'memory_operations' } @$definitions;
if ($memory_def && 
    exists $memory_def->{function}{parameters}{properties}{key} &&
    exists $memory_def->{function}{parameters}{properties}{content}) {
    print "  [OK] memory_operations has key and content\n";
} else {
    print "  [FAIL] memory_operations missing key or content\n";
    exit 1;
}

# Test 2: web_operations should have 'url' and 'query' parameters  
print "\nTest 2: web_operations has 'url' and 'query' parameters\n";
my ($web_def) = grep { $_->{function}{name} eq 'web_operations' } @$definitions;
if ($web_def &&
    exists $web_def->{function}{parameters}{properties}{url} &&
    exists $web_def->{function}{parameters}{properties}{query}) {
    print "  [OK] web_operations has url and query\n";
} else {
    print "  [FAIL] web_operations missing url or query\n";
    exit 1;
}

# Test 3: code_intelligence should have 'symbol_name' parameter
print "\nTest 3: code_intelligence has 'symbol_name' parameter\n";
my ($code_def) = grep { $_->{function}{name} eq 'code_intelligence' } @$definitions;
if ($code_def &&
    exists $code_def->{function}{parameters}{properties}{symbol_name}) {
    print "  [OK] code_intelligence has symbol_name\n";
} else {
    print "  [FAIL] code_intelligence missing symbol_name\n";
    exit 1;
}

# Test 4: All tools should have 'operation' as required
print "\nTest 4: All tools have 'operation' as required parameter\n";
my $all_have_operation = 1;
for my $def (@$definitions) {
    my $name = $def->{function}{name};
    my $required = $def->{function}{parameters}{required} || [];
    if (!grep { $_ eq 'operation' } @$required) {
        print "  [FAIL] $name doesn't have operation as required\n";
        $all_have_operation = 0;
    }
}
if ($all_have_operation) {
    print "  [OK] All tools have operation as required\n";
}

print "\n[OK] All tests passed! Schemas are complete and correct.\n";
exit 0;
