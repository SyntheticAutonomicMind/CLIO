#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Tools::Registry;
use CLIO::Tools::FileOperations;
use CLIO::Tools::TerminalOperations;
use CLIO::Tools::MemoryOperations;
use CLIO::Tools::Interact;
use CLIO::Tools::VersionControl;
use CLIO::Tools::WebOperations;
use CLIO::Tools::TodoList;
use CLIO::Tools::CodeIntelligence;
use CLIO::Tools::ApplyPatch;

# The registry used to expose a static table of natural-language aliases
# (run, bash, get, save, delete, ...) that were never emitted to the model.
# A model could call one and reach a different tool than the word implied.
# Only emitted callables are resolvable now. These aliases must not resolve.

my $registry = CLIO::Tools::Registry->new();
for my $class (qw(FileOperations TerminalOperations MemoryOperations Interact
                  VersionControl WebOperations TodoList CodeIntelligence ApplyPatch)) {
    my $module = "CLIO::Tools::$class";
    $registry->register_tool($module->new(debug => 0));
}

my @retired = qw(
    run bash cmd exec shell
    get save forget store retrieve
    curl wget http google
    ask ask_user confirm question collab
    git todo todos spawn patch
    read write add update delete list search
    append_file create_file
);

my $resolved = 0;
for my $name (@retired) {
    my $info = $registry->get_alias_info($name);
    ok(!$info, "retired alias '$name' no longer resolves") or $resolved++;
}

# Emitted names must still resolve to the right tool.
my @expected = (
    ['read_file',      'file_operations'],
    ['write_file',     'file_operations'],
    ['delete_file',    'file_operations'],
    ['grep_search',    'file_operations'],
    ['memory_delete',  'memory_operations'],
    ['memory_store',   'memory_operations'],
    ['memory_search',  'memory_operations'],
    ['todo_read',      'todo_operations'],
    ['todo_write',     'todo_operations'],
    ['list_usages',    'code_intelligence'],
    ['search_history', 'code_intelligence'],
    ['commit',         'version_control'],
    ['fetch_url',      'web_operations'],
);

for my $case (@expected) {
    my ($name, $tool) = @$case;
    my $info = $registry->get_alias_info($name);
    ok($info, "emitted name '$name' resolves");
    is($info->{tool}, $tool, "  '$name' -> $tool") if $info;
}

is($resolved, 0, 'no retired alias resolves');
done_testing();
