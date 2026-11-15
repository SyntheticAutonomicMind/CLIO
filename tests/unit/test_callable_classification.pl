#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Tools::Registry;
use CLIO::Core::ToolLoopDetector;
use CLIO::Core::WorkflowOrchestrator;

# The model calls emitted callable names (read_file, todo_add), never the
# grouping tool. Anything outside dispatch that asks "which tool is this?"
# has to resolve through the registry or it silently gets the wrong answer.
# These are the call sites that were comparing against grouping names.

# ── Registry specs and dispatch agree ──────────────────────────────────────

my @specs = (@{ CLIO::Tools::Registry->standard_tool_specs() },
             @{ CLIO::Tools::Registry->conditional_tool_specs() });

my @name_mismatch;
for my $spec (@specs) {
    (my $file = "$spec->{module}.pm") =~ s{::}{/}g;
    my $loaded = eval { require $file; 1 };
    push @name_mismatch, "$spec->{module}: $@" and next unless $loaded;

    my $tool = eval { $spec->{module}->new(debug => 0) };
    push @name_mismatch, "$spec->{module}: $@" and next unless $tool;

    push @name_mismatch, "$spec->{name} != $tool->{name}"
        unless $tool->{name} eq $spec->{name};
}
is_deeply(\@name_mismatch, [],
    'every registered spec name matches the module it names');

# ── callable_map covers the emitted surface exactly ────────────────────────

my $registry = CLIO::Tools::Registry->new();
for my $spec (@specs) {
    (my $file = "$spec->{module}.pm") =~ s{::}{/}g;
    require $file;
    $registry->register_tool($spec->{module}->new(debug => 0));
}

my $emitted = $registry->get_emitted_names();
my $map     = CLIO::Tools::Registry->callable_map();

my @missing = sort grep { !exists $map->{$_} } keys %$emitted;
is_deeply(\@missing, [],
    'callable_map resolves every name the registry emits');

my @extra = sort grep { !$registry->is_emitted_name($_) } keys %$map;
is_deeply(\@extra, [], 'callable_map invents no names the registry does not emit');

# ── classify_callable resolves each shape ──────────────────────────────────

my $write = CLIO::Tools::Registry->classify_callable('write_file');
is_deeply($write, { tool => 'file_operations', operation => 'write_file' },
    'write_file resolves to file_operations/write_file');

my $todo = CLIO::Tools::Registry->classify_callable('todo_read');
is_deeply($todo, { tool => 'todo_operations', operation => 'read' },
    'todo_read resolves to todo_operations/read');

my $interact = CLIO::Tools::Registry->classify_callable('interact');
ok($interact && $interact->{tool} eq 'interact' && !defined $interact->{operation},
    'a consolidated callable resolves to itself with no operation');

is(CLIO::Tools::Registry->classify_callable('not_a_tool'), undef,
    'an unknown name resolves to nothing');

# History recorded before a tool split into per-operation callables carries
# the grouping name plus an operation. Classification must read it; dispatch
# still refuses it (proved in test_unknown_tool_recovery.pl).
my $legacy = CLIO::Tools::Registry->classify_callable('file_operations', 'read_file');
is_deeply($legacy, { tool => 'file_operations', operation => 'read_file' },
    'grouping name plus operation classifies for stored history');

is(CLIO::Tools::Registry->classify_callable('file_operations', 'no_such_op'), undef,
    'grouping name with an unknown operation classifies to nothing');

# ── Loop detector reads the emitted names as what they are ─────────────────

my $detector = CLIO::Core::ToolLoopDetector->new();

my %expected = (
    read_file      => 0,   # neutral: ignored by the loop window
    grep_search    => 0,   # tracked: search results can repeat
    status         => 0,   # tracked: read-only version control
    list_dir       => 0,   # tracked: discovery
    write_file     => 1,   # mutating: clears the window
    replace_string => 1,
    commit         => 1,
    todo_add       => 1,   # mutating: todo state changed
    apply_patch    => 1,
);

for my $name (sort keys %expected) {
    is($detector->_is_state_changing($name, {}), $expected{$name},
        "_is_state_changing resolves '$name'");
}

# read_file returns the same bytes for the same path by design, so it is
# neutral: neither loop evidence nor a strategy change. It must not clear an
# active search run either, or reads interleaved with searches would hide the
# loop.
my $seed = 'lib/CLIO/Core/X.pm:1: script';
$detector->record_call('grep_search', { query => 'a', path => 'lib' }, $seed);
$detector->record_call('grep_search', { query => 'b', path => 'lib' }, $seed);

my $read = $detector->record_call('read_file', { path => 'lib/CLIO/Core/X.pm' },
    'package X; 1;');
is($read->{tracked}, 0, 'read_file is not tracked');
is($read->{count}, 0, 'read_file does not accumulate count');

my $verdict = $detector->record_call('grep_search',
    { query => 'c', path => 'lib' }, $seed);
is($verdict->{count}, 3, 'neutral read_file did not clear the search run');
ok(defined $verdict->{guidance}, 'the search run still reaches guidance');

# ── Session checkpoint read the recorded call shapes ───────────────────────

# Call records carry the canonical tool name plus the raw JSON argument
# string. A hash-only check left the file list empty for every real session.
my $activity = CLIO::Core::WorkflowOrchestrator::_summarize_tool_activity([
    { name => 'file_operations', operation => 'read_file',
      arguments => '{"path":"lib/CLIO/Core/A.pm"}' },
    { name => 'file_operations', operation => 'write_file',
      arguments => '{"path":"lib/CLIO/Core/B.pm"}' },
    { name => 'apply_patch', operation => '', arguments => '{"patch":"..."}' },
    { name => 'todo_add', operation => 'add', arguments => '{"newTodos":[]}' },
]);

is($activity->{counts}{'file_operations.read_file'}, 1,
    'checkpoint labels reads by tool and operation');
is($activity->{counts}{'todo_operations.add'}, 1,
    'checkpoint labels emitted callables by their owner and operation');
is_deeply($activity->{files},
    ['lib/CLIO/Core/B.pm', 'lib/CLIO/Core/A.pm'],
    'checkpoint collects file paths from JSON argument strings, most recent first');

done_testing();
