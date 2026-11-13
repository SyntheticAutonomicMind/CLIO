#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

# Integration test: every emitted tool definition is a schema a model can obey.
#
# The correctness question is not "does every definition declare operation" -
# per-operation definitions must not declare it - but "could a model that reads
# this definition and obeys it still fail". The checks below are the ways that
# answer has been no in practice.

use strict;
use warnings;
use utf8;
use lib 'lib';
use Test::More;
use CLIO::Tools::Registry;

my @MODULES = qw(
    CLIO::Tools::FileOperations
    CLIO::Tools::MemoryOperations
    CLIO::Tools::WebOperations
    CLIO::Tools::CodeIntelligence
    CLIO::Tools::Interact
    CLIO::Tools::TerminalOperations
    CLIO::Tools::TodoList
    CLIO::Tools::VersionControl
    CLIO::Tools::ApplyPatch
);

my $registry = CLIO::Tools::Registry->new(debug => 0);

for my $module (@MODULES) {
    eval "require $module; 1" or BAIL_OUT("cannot load $module: $@");
    $registry->register_tool($module->new());
}

my $definitions = $registry->get_tool_definitions();

ok(@$definitions > 0, 'registry emits tool definitions');

my (@missing_description, @bad_required, @optional_operation, @no_properties);
my ($consolidated, $per_operation) = (0, 0);

for my $definition (@$definitions) {
    my $function = $definition->{function};
    my $name = $function->{name};
    my $parameters = $function->{parameters} || {};
    my $properties = $parameters->{properties} || {};
    my $required = $parameters->{required} || [];

    push @missing_description, $name
        unless defined $function->{description} && length $function->{description};

    push @no_properties, $name
        unless ref($parameters) eq 'HASH' && ref($properties) eq 'HASH';

    # JSON Schema forbids a required name absent from properties, and some
    # providers drop the entire tool when it happens.
    for my $param (@$required) {
        push @bad_required, "$name: $param"
            unless exists $properties->{$param};
    }

    if (exists $properties->{operation}) {
        $consolidated++;
        # operation selects the action; leaving it optional makes the tool
        # callable with no action at all.
        push @optional_operation, $name
            unless grep { $_ eq 'operation' } @$required;
    } else {
        $per_operation++;
    }
}

is_deeply(\@missing_description, [], 'every definition has a description');
is_deeply(\@no_properties, [], 'every definition has a parameters object');
is_deeply(\@bad_required, [], 'required names all exist in properties');
is_deeply(\@optional_operation, [],
    'a definition that declares operation requires it');

ok($per_operation > 0, "registry emits per-operation definitions ($per_operation)");

diag("          $consolidated consolidated, $per_operation per-operation");

# A definition whose required list is empty must genuinely need nothing. Every
# tool here that takes arguments has at least one operation that needs them.
my %must_require_something = (
    write_file     => 1,
    replace_string => 1,
    insert_at_line => 1,
    commit         => 1,
    store          => 1,
);

my %by_name = map { $_->{function}{name} => $_->{function} } @$definitions;

for my $name (sort keys %must_require_something) {
    my $function = $by_name{$name};
    ok($function, "$name is emitted") or next;
    ok(scalar @{ $function->{parameters}{required} || [] },
        "$name declares at least one required parameter");
}

done_testing();
