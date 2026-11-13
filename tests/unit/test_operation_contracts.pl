#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Util::JSON qw(encode_json);
use CLIO::Tools::Registry;

=head1 NAME

test_operation_contracts.pl - Enforce the per-operation tool schema invariants

=head1 DESCRIPTION

Models obey the machine-readable contract and ignore prose. A tool whose
consolidated schema declares C<required =E<gt> ["operation"]> while its handler
demands C<content> is a tool that fails on first use, then fails again while
"correcting" itself, because the error guidance repeated the same wrong claim.

Every tool that opts into per-operation definitions must satisfy these
invariants. Each one has already been violated in production at least once:

=over 4

=item * Every emitted definition name resolves to a tool.

A name the registry cannot resolve is a dead end - the model calls it and gets
"unknown tool". C<multi_replace_string> shipped that way.

=item * No two definitions share a name.

Operations are unique only within a tool: both memory_operations and
skill_operations have C<list>.

=item * Every contract property exists in the tool's own schema.

Contract properties are copied from the consolidated schema. A typo produces a
silently empty C<properties> map, which reads to the model as "no parameters".

=item * Required is a subset of properties.

JSON Schema rejects a required name absent from properties, and some providers
drop the whole tool when that happens.

=item * A tool with per-operation definitions emits no consolidated definition.

Two contradictory descriptions of the same commands - the model picks the
cheaper one to satisfy, which is the one that lies.

=back

=cut

my @TOOLS = (
    ['CLIO::Tools::FileOperations',     'file_operations',     { session_dir => '.' }],
    ['CLIO::Tools::VersionControl',     'version_control',     {}],
    ['CLIO::Tools::MemoryOperations',   'memory_operations',   {}],
    ['CLIO::Tools::TodoList',           'todo_operations',     {}],
    ['CLIO::Tools::WebOperations',      'web_operations',      {}],
    ['CLIO::Tools::CodeIntelligence',   'code_intelligence',   {}],
    ['CLIO::Tools::SkillOperations',    'skill_operations',    {}],
    ['CLIO::Tools::RemoteExecution',    'remote_execution',    {}],
    ['CLIO::Tools::SubAgentOperations', 'agent_operations',    {}],
);

my $registry = CLIO::Tools::Registry->new();
my %tool_objects;

for my $entry (@TOOLS) {
    my ($module, $name, $args) = @$entry;
    my $loaded = eval "require $module; 1";
    ok($loaded, "$module loads") or diag($@);
    next unless $loaded;

    my $tool = $module->new(%$args);
    $tool_objects{$name} = $tool;
    $registry->register_tool($tool);
}

my $definitions = $registry->get_tool_definitions();
ok(@$definitions > 0, 'registry emits definitions');

my %seen_name;
my @duplicates;
my @unresolvable;
my @consolidated_leaks;

for my $definition (@$definitions) {
    my $name = $definition->{function}{name};
    push @duplicates, $name if $seen_name{$name}++;
    push @unresolvable, $name unless $registry->has_tool($name);

    # A contract-bearing tool contributes only per-operation definitions; its
    # canonical name must not appear as a second, contradictory surface.
    push @consolidated_leaks, $name if $tool_objects{$name}
        && $tool_objects{$name}->can('operation_contract')
        && keys %{ $tool_objects{$name}->operation_contract() || {} };
}

is_deeply(\@duplicates, [], 'no duplicate definition names');
is_deeply(\@unresolvable, [], 'every emitted name resolves through the registry');
is_deeply(\@consolidated_leaks, [],
    'contract-bearing tools do not also emit the consolidated schema');

my @contract_problems;

for my $name (sort keys %tool_objects) {
    my $tool = $tool_objects{$name};
    next unless $tool->can('operation_contract');

    my $contract = $tool->operation_contract() || {};
    my $schema = $tool->get_tool_definition() || {};
    my $schema_props = $schema->{parameters}{properties} || {};

    # The same parameter name must mean the same thing everywhere. A tool whose
    # operations disagree forces the schema to carry the union, which is why
    # one definition per operation exists.
    for my $op (sort keys %$contract) {
        my $spec = $contract->{$op} || {};
        my $required = $spec->{required} || [];
        my %required = map { $_ => 1 } @$required;

        for my $param (@{ $spec->{properties} || [] }) {
            push @contract_problems, "$name/$op: unknown property '$param'"
                unless exists $schema_props->{$param};
        }

        for my $param (@$required) {
            push @contract_problems, "$name/$op: required '$param' not in properties"
                unless exists $schema_props->{$param};

            push @contract_problems, "$name/$op: required '$param' not listed as a property"
                unless grep { $_ eq $param } @{ $spec->{properties} || [] };
        }
    }
}

is_deeply(\@contract_problems, [], 'contracts match the tool schemas');

# A model that reads the schema and obeys it must be able to satisfy the
# canonical failure: replace_string needs old_string, write_file needs content.
my %must_be_required = (
    write_file           => ['path', 'content'],
    replace_string       => ['path', 'old_string', 'new_string'],
    insert_at_line       => ['path', 'line', 'content'],
    multi_replace_string => ['replacements'],
    commit               => ['message'],
    spawn                => ['task'],
);

my %definition_by_name = map { $_->{function}{name} => $_->{function} } @$definitions;

for my $callable (sort keys %must_be_required) {
    my $definition = $definition_by_name{$callable};
    ok($definition, "$callable is emitted") or next;

    my %required = map { $_ => 1 } @{ $definition->{parameters}{required} || [] };
    for my $param (@{ $must_be_required{$callable} }) {
        ok($required{$param}, "$callable declares '$param' required");
    }
}

# Dispatch must be unchanged: the callable name resolves to (tool, operation).
my @dispatch_problems;

for my $callable (sort keys %must_be_required) {
    my $alias = $registry->get_alias_info($callable);
    push @dispatch_problems, $callable unless $alias && $alias->{operation} eq $callable;
}

is_deeply(\@dispatch_problems, [], 'per-operation callables dispatch by name');

# Payload cost. The split is worth a few KB, but a runaway description would
# quietly eat the context it is meant to save.
my $bytes = length(encode_json({ tools => $definitions }));
my $definition_count = scalar @$definitions;

diag(sprintf "          %d definitions, %d bytes (~%.1fk tokens)",
    $definition_count, $bytes, $bytes / 3.6 / 1000);

ok($bytes < 120_000, "tool payload stays under 120 KB (was $bytes)");

done_testing();
