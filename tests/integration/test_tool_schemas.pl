#!/usr/bin/env perl

# Test to verify tool schemas are complete and correct

use strict;
use warnings;
use lib 'lib';
use JSON::PP qw(encode_json);
use CLIO::Tools::Registry;
use CLIO::Tools::FileOperations;
use CLIO::Tools::MemoryOperations;
use CLIO::Tools::WebOperations;
use CLIO::Tools::CodeIntelligence;
use CLIO::Tools::UserCollaboration;
use CLIO::Tools::TerminalOperations;
use CLIO::Tools::TodoList;
use CLIO::Tools::VersionControl;

print "Testing all tool schemas...\n\n";

my $registry = CLIO::Tools::Registry->new(debug => 0);

# Register all tools
$registry->register_tool(CLIO::Tools::FileOperations->new());
$registry->register_tool(CLIO::Tools::MemoryOperations->new());
$registry->register_tool(CLIO::Tools::WebOperations->new());
$registry->register_tool(CLIO::Tools::CodeIntelligence->new());
$registry->register_tool(CLIO::Tools::UserCollaboration->new());
$registry->register_tool(CLIO::Tools::TerminalOperations->new());
$registry->register_tool(CLIO::Tools::TodoList->new());
$registry->register_tool(CLIO::Tools::VersionControl->new());

# Get all tool definitions
my $definitions = $registry->get_tool_definitions();

print "Total tools registered: " . scalar(@$definitions) . "\n\n";

my $all_pass = 1;

for my $def (@$definitions) {
    my $tool_name = $def->{function}{name};
    my $params = $def->{function}{parameters};
    
    print "=== $tool_name ===\n";
    
    # Check has operation parameter
    if (!exists $params->{properties}{operation}) {
        print "  ❌ FAIL: Missing 'operation' parameter\n";
        $all_pass = 0;
    } else {
        print "  ✓ Has 'operation' parameter\n";
    }
    
    # Check operation is required
    my $required = $params->{required} || [];
    if (!grep { $_ eq 'operation' } @$required) {
        print "  ❌ FAIL: 'operation' not marked as required\n";
        $all_pass = 0;
    } else {
        print "  ✓ 'operation' is required\n";
    }
    
    # Count all parameters
    my $param_count = scalar(keys %{$params->{properties}});
    print "  Parameters: $param_count\n";
    
    # List them
    print "    - " . join("\n    - ", sort keys %{$params->{properties}}) . "\n";
    
    print "\n";
}

if ($all_pass) {
    print "✅ All tool schemas are valid!\n";
    exit 0;
} else {
    print "❌ Some tool schemas have issues.\n";
    exit 1;
}
