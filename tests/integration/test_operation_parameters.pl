#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Integration test: each operation carries its own parameters and its own
# required list.
#
# The previous version of this test asserted that the consolidated
# memory_operations definition contained key and content. That was true and
# useless: the schema still declared required => ["operation"], so a model
# could satisfy every declared requirement while omitting content. These
# assertions check the machine-readable contract, which is the one models obey.

use strict;
use warnings;
use utf8;
use lib 'lib';
use Test::More;
use CLIO::Tools::Registry;

my @MODULES = qw(
    CLIO::Tools::MemoryOperations
    CLIO::Tools::WebOperations
    CLIO::Tools::CodeIntelligence
    CLIO::Tools::SkillOperations
    CLIO::Tools::TodoList
);

my $registry = CLIO::Tools::Registry->new(debug => 0);

for my $module (@MODULES) {
    eval "require $module; 1" or BAIL_OUT("cannot load $module: $@");
    $registry->register_tool($module->new());
}

my %by_name = map { $_->{function}{name} => $_->{function} }
             @{ $registry->get_tool_definitions() };

# Callable name => [parameters that must be present, parameters that must be required]
my %expectations = (
    memory_store     => { present => [qw(key content)], required => [qw(key content)] },
    memory_retrieve  => { present => [qw(key)], required => [qw(key)] },
    memory_search    => { present => [qw(query)], required => [qw(query)] },
    fetch_url => { present => [qw(url timeout)], required => [qw(url)] },
    search_web => { present => [qw(query max_results timeout)], required => [qw(query)] },
    list_usages => { present => [qw(symbol_name file_paths)], required => [qw(symbol_name)] },
    skill_load => { present => [qw(name)], required => [qw(name)] },
    todo_write     => { present => [qw(todoList)], required => [qw(todoList)] },
    todo_update    => { present => [qw(todoUpdates)], required => [qw(todoUpdates)] },
    todo_add       => { present => [qw(newTodos)], required => [qw(newTodos)] },
);

for my $callable (sort keys %expectations) {
    my $function = $by_name{$callable};
    ok($function, "$callable is emitted") or next;

    my $properties = $function->{parameters}{properties} || {};
    my %required = map { $_ => 1 } @{ $function->{parameters}{required} || [] };
    my $expect = $expectations{$callable};

    for my $param (@{ $expect->{present} }) {
        ok(exists $properties->{$param}, "$callable exposes '$param'");
    }

    for my $param (@{ $expect->{required} }) {
        ok($required{$param}, "$callable declares '$param' required");
    }
}

# A per-operation definition must not carry the operation selector: it has
# nowhere to put it, and accepting one would let write's todoList requirements
# leak onto update.
for my $callable (sort keys %expectations) {
    next unless $by_name{$callable};
    ok(!exists $by_name{$callable}{parameters}{properties}{operation},
        "$callable does not declare an operation parameter");
}

# The consolidated definitions are replaced, not supplemented.
for my $name (qw(memory_operations web_operations code_intelligence todo_operations)) {
    ok(!exists $by_name{$name}, "$name consolidated definition is not emitted");
}

done_testing();
