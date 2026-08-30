#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use lib './lib';

use CLIO::Core::ToolErrorGuidance;
use Test::More;

# Test: Unknown tool errors (model using wrong tool names from other
# frameworks, e.g. "read" instead of "read_file") are categorized as
# 'unknown_tool' and receive actionable guidance.

my $g = CLIO::Core::ToolErrorGuidance->new();

my @cases = (
    ["Unknown tool: read",         'unknown_tool'],
    ["Unknown tool: write",        'unknown_tool'],
    ["Unknown tool: apply_patch",  'unknown_tool'],
    ["Unknown tool: list_directory", 'unknown_tool'],
    ["Unknown tool: mkdir",        'unknown_tool'],
    ["Unknown tool: terminal_ops", 'unknown_tool'],
);

plan tests => scalar(@cases) + 2;

for my $i (0 .. $#cases) {
    my ($error, $expected) = @{$cases[$i]};
    my $cat = $g->_categorize_error($error);
    is($cat, $expected, "categorize '$error' as $expected");
}

# Verify the guidance message mentions correct CLIO tool names
my $guidance = $g->enhance_tool_error(
    error => "Unknown tool: read",
    tool_name => 'read',
);
ok($guidance =~ /file_operations/, "guidance mentions file_operations");
ok($guidance =~ /operation/, "guidance mentions the operation parameter");

done_testing();
