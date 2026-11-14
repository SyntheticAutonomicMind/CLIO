#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Tools::Registry;
use CLIO::Core::PromptBuilder;
use CLIO::Core::PromptManager;

# The system prompt is the model's only description of the tool surface. Every
# name it prints must be a callable the registry emits, and no part of it may
# teach the grouping-name form that dispatch now refuses.

my $registry = CLIO::Tools::Registry->new();
for my $spec (@{ CLIO::Tools::Registry->standard_tool_specs() }) {
    (my $file = "$spec->{module}.pm") =~ s{::}{/}g;
    require $file;
    $registry->register_tool($spec->{module}->new(debug => 0));
}

my $builder = CLIO::Core::PromptBuilder->new(
    tool_registry        => $registry,
    debug                => 0,
    auto_discover_skills => 0,
    auto_create_skills   => 0,
    enable_subagents     => 0,
);

my $section = $builder->generate_tools_section();

# ── The numbered tool list ──────────────────────────────────────────────────

my @listed = $section =~ /^\d+\. \*\*(\S+)\*\*/mg;
ok(@listed, 'tools section lists callables');

my @listed_bad = grep { !$registry->is_emitted_name($_) } @listed;
is_deeply(\@listed_bad, [], 'every listed name is an emitted callable');

is(scalar @listed, scalar keys %{ $registry->get_emitted_names() },
    'listed count equals the emitted callable count');

# ── The Tool-First table ────────────────────────────────────────────────────

my @calls = $section =~ /\[calls (\w+)\]/g;
ok(@calls, 'tool-first table is rendered from the registry');

my @calls_bad = grep { !$registry->is_emitted_name($_) } @calls;
is_deeply(\@calls_bad, [], 'every tool-first target is an emitted callable');

unlike($section, qr/calls file_operations/,
    'tool-first table does not teach the grouping name');

# ── Grouping names are never advertised ─────────────────────────────────────

unlike($section, qr/\*\*file_operations\*\*/, 'file_operations is not a listed tool');
unlike($section, qr/\*\*todo_operations\*\*/, 'todo_operations is not a listed tool');

# ── Static prose does not name grouping tools as things to call ─────────────

my $manager = CLIO::Core::PromptManager->new(debug => 0, skip_custom => 1);
my $static  = $manager->get_system_prompt();

unlike($static, qr/->\s*`file_operations`/,
    'tool-selection prose does not route file work to file_operations');
unlike($static, qr/Use `(?:todo|memory|web|agent|skill|code_intelligence|version_control)_operations` for/,
    'static prose does not instruct calling a grouping tool by that name');

# Every call form the prose teaches - `name(...)` in backticks - has to be a
# name the registry publishes, or the prompt is teaching a call that fails.
my %taught;
$taught{$1}++ while $static =~ /`([a-z][a-z0-9_]*)\(/g;
my @taught_bad = grep { !$registry->is_emitted_name($_) } sort keys %taught;
is_deeply(\@taught_bad, [],
    'every call form taught in static prose is an emitted callable');

# The operation-required rule may still be stated - it is true of the
# consolidated callables that remain.
like($section, qr/`terminal_operations` is the common one/,
    'operation-required callout still names a real consolidated callable');
like($section, qr/Per-operation tools such as `write_file`, `replace_string`/,
    'operation-required callout names real per-operation callables');

# ── Descriptions match their schemas ───────────────────────────────────────

# A callable that says an operation field is required must have a schema that
# requires one. Interact's description claimed it did long after its schema
# stopped asking, which taught the model to send a field that was ignored.
my @false_claims;
for my $def (@{ $registry->get_tool_definitions() }) {
    my $fn   = $def->{function};
    my $desc = $fn->{description} // '';
    next unless $desc =~ /requires? the 'operation' parameter/i;

    my $required = $fn->{parameters}{required} // [];
    push @false_claims, $fn->{name}
        unless grep { $_ eq 'operation' } @$required;
}
is_deeply(\@false_claims, [],
    'no description claims an operation field that its schema does not require');

done_testing();
