#!/usr/bin/env perl

# Direct tool execution test - forces AI to use tools

use strict;
use warnings;
use feature 'say';
use FindBin qw($RealBin);
use File::Temp qw(tempdir);
use File::Spec;

my $clio = "$RealBin/clio";
my $test_dir = tempdir(CLEANUP => 1);
my $test_file = File::Spec->catfile($test_dir, "direct_test.txt");

say "Testing DIRECT tool usage (explicit tool requests)";
say "=" x 80;

sub test_tool {
    my ($name, $prompt) = @_;
    
    say "\n[TEST] $name";
    say "Prompt: $prompt";
    
    my $output = `$clio --new --debug --input "$prompt" --exit 2>&1`;
    my $tool_called = ($output =~ /\[TOOL_CALL\]/ or $output =~ /calling.*tool/i or $output =~ /executing.*operation/i);
    
    if ($tool_called) {
        say "✅ PASS - Tool was called";
        return 1;
    } else {
        say "❌ FAIL - Tool NOT called";
        say "Output: " . substr($output, 0, 200) . "...";
        return 0;
    }
}

my $passed = 0;
my $total = 0;

# Test each tool with explicit "use the XYZ tool" requests
$total++; $passed += test_tool(
    "file_operations:create",
    "Use the file_operations tool with create_file operation to create $test_file with content 'test'"
);

$total++; $passed += test_tool(
    "version_control:status",
    "Use the version_control tool with status operation to show git status"
);

$total++; $passed += test_tool(
    "terminal_operations:exec",
    "Use the terminal_operations tool with exec operation to run 'echo hello'"
);

$total++; $passed += test_tool(
    "code_intelligence:list_usages",
    "Use the code_intelligence tool with list_usages operation to find usages of 'CLIO' in lib/"
);

$total++; $passed += test_tool(
    "todo_operations:write",
    "Use the todo_operations tool with write operation to create a todo: Test CLIO"
);

say "\n" . "=" x 80;
say "RESULTS: $passed/$total tests passed (" . sprintf("%.1f%%", ($passed/$total)*100) . ")";
say "=" x 80;

exit($passed == $total ? 0 : 1);
