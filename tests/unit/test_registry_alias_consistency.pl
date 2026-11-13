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

# The emitted surface is the contract. Every name sent to the model must
# resolve to a tool, and every resolvable name must be one that was emitted.

my $r = CLIO::Tools::Registry->new();
for my $class (qw(FileOperations TerminalOperations MemoryOperations Interact
                  VersionControl WebOperations TodoList CodeIntelligence ApplyPatch)) {
    my $module = "CLIO::Tools::$class";
    $r->register_tool($module->new(debug => 0));
}

my $emitted = $r->get_emitted_names();
ok(scalar(keys %$emitted) > 0, 'registry emits a non-empty tool surface');

my @unresolvable;
for my $name (sort keys %$emitted) {
    my $tool = $r->get_tool($name);
    push @unresolvable, $name unless $tool && $r->has_tool($name);
}
is_deeply(\@unresolvable, [], 'every emitted name resolves to a tool');

# Generic operation names must not be emitted bare. They are namespaced.
for my $bare (qw(read write add update delete list search store retrieve get save forget)) {
    ok(!$emitted->{$bare}, "generic name '$bare' is not emitted bare");
}

# The namespaced versions exist.
ok($emitted->{todo_read}, 'todo_read is emitted');
ok($emitted->{todo_write}, 'todo_write is emitted');
ok($emitted->{memory_delete}, 'memory_delete is emitted');
ok($emitted->{memory_search}, 'memory_search is emitted');

# Every emitted name that is an operation alias must map to a registered tool.
for my $name (sort keys %$emitted) {
    my $info = $r->get_alias_info($name);
    next unless $info;
    ok(exists $r->{tools}{ $info->{tool} },
        "'$name' maps to registered tool '$info->{tool}'");
}

# Consolidated tools keep their canonical name and resolve directly.
for my $name (qw(terminal_operations interact apply_patch)) {
    ok($emitted->{$name}, "$name is emitted");
    ok($r->get_tool($name), "$name resolves");
}

ok(!$r->is_emitted_name('file_operations'), 'canonical file_operations is not emitted');
ok(!$r->is_emitted_name('nonexistent_tool'), 'unknown name is not emitted');

done_testing();
