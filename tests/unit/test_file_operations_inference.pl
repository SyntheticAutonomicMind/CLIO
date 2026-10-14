#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use lib './lib';
use Test::More tests => 14;

use CLIO::Tools::FileOperations;

my $tool = CLIO::Tools::FileOperations->new(debug => 0);

# Test 1-2: default_operation is set and is read_file
ok(defined $tool->{default_operation}, 'default_operation is set');
is($tool->{default_operation}, 'read_file', 'default_operation is read_file');

# Tests 3-12: Context-aware inference for unambiguous parameter combinations
my @cases = (
    [{ toolCallId => 'call_123' },                          'read_tool_result'],
    [{ old_path => '/a', new_path => '/b' },                'rename_file'],
    [{ replacements => [] },                                'multi_replace_string'],
    [{ line => 5, content => 'test' },                      'insert_at_line'],
    [{ old_string => 'old', new_string => 'new' },          'replace_string'],
    [{ content => 'hello' },                                'write_file'],
    [{ query => 'pat', pattern => '*.pm' },                'grep_search'],
    [{ query => 'terms', scope => '.' },                    'semantic_search'],
    [{ pattern => '*.pm' },                                'file_search'],
    [{ path => '/tmp/test', start_line => 1 },              'read_file'],
);

for my $i (0 .. $#cases) {
    my ($params, $expected) = @{$cases[$i]};
    my $inferred = $tool->_infer_operation_from_params($params);
    is($inferred, $expected,
        "inference: " . join(',', map { "$_=$params->{$_}" } sort keys %$params) . " -> $expected")
        or diag("  got: $inferred // undef");
}

# Test: write_file inference should NOT fire when old_string is present
my $r1 = $tool->_infer_operation_from_params({ content => 'h', old_string => 'o', new_string => 'n' });
is($r1, 'replace_string', 'content+old_string+new_string -> replace_string, not write_file');

# Test: path-only is ambiguous -> undef (default_operation handles it later)
my $r2 = $tool->_infer_operation_from_params({ path => '/tmp/test' });
ok(!defined($r2), 'path-only is ambiguous -> undef (falls through to default_operation)');

