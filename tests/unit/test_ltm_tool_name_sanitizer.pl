#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: CLIO::Memory::LongTerm::sanitize_narration must
# replace every tool name from CLIO::Tools. Without these rewrite rules,
# LTM entries (and active todo content) leak framework-internal tool
# names to the model, which then may mimic them in prose responses.
#
# Bug H4 (scratch/QA_REPORT_message-history-xml.md): only memory_operations
# was in the rewrite table. file_operations, terminal_operations,
# version_control, interact, todo_operations, web_operations, apply_patch,
# code_intelligence, skill_operations, remote_execution, subagent_operations,
# todo_list all leaked verbatim.

use strict;
use warnings;
use lib './lib';

use Test::More;
use CLIO::Memory::LongTerm;

my $ltm = CLIO::Memory::LongTerm->new();

# Each entry: { tool_phrase => expected_neutral_word }
my %rewrite_cases = (
    'Files are read with file_operations(read_file).'           => 'file operations',
    'Run terminal_operations(exec) for grep'                    => 'shell commands',
    'Use version_control(commit) for git operations'             => 'git operations',
    'Call interact(operation: "request_input")'                 => 'user input',
    'Check todo_operations(add) for new todos'                  => 'todo operations',
    'web_operations(fetch_url) is the http helper'              => 'web requests',
    'apply_patch(diff) is for editing files'                     => 'patch operations',
    'code_intelligence(list_usages) searches the codebase'       => 'code search',
    'remote_execution(ssh) runs on handhelds'                   => 'remote execution',
    'subagent_operations(spawn) starts an agent'                 => 'subagent operations',
    'skill_operations(load) loads a skill'                       => 'skill operations',
    'todo_list(add) tracks todos'                               => 'todo list',
);

for my $input (sort keys %rewrite_cases) {
    my $expected = $rewrite_cases{$input};
    my $out = $ltm->sanitize_narration($input);
    unlike($out, qr/\b(file_operations|terminal_operations|version_control|interact|todo_operations|web_operations|apply_patch|code_intelligence|remote_execution|subagent_operations|skill_operations|todo_list)\b/,
        "tool name in '$input' was sanitized to '$expected' (got: '$out')");
    like($out, qr/$expected/,
        "tool name rewritten to '$expected' in '$input' (got: '$out')");
}

# Write path: add_discovery applies sanitizer on write.
$ltm->add_discovery('Use file_operations(read_file) to inspect files.', 0.9, 1);
my $stored = $ltm->get_entries_for_projection()->[0]{content};
unlike($stored, qr/\bfile_operations\b/,
    'add_discovery sanitizes file_operations on write');
like($stored, qr/file operations/, 'add_discovery rewrites to neutral form');

# Read path: score_ltm applies sanitizer on read (defense in depth
# for legacy entries that pre-date this rewrite table). Verify the
# score_ltm output applies sanitize_narration (the sanitizer runs at
# score time).
my $ltm2 = CLIO::Memory::LongTerm->new();
$ltm2->{patterns}{discoveries} = [
    { fact => 'Run terminal_operations to grep', confidence => 0.9 },
];
my $scored = $ltm2->get_entries_for_projection();
my $sanitized = $ltm->sanitize_narration($scored->[0]{content});
is($sanitized, 'Run shell commands to grep',
    'sanitize_narration strips terminal_operations from legacy entries (defense in depth)');

done_testing();
