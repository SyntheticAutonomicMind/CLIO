#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use lib './lib';

# Regression: every natural-language alias added on 2026-08-26 must route
# to the right tool+operation. The aliases were added because the audit
# found that agents commonly try these names instead of the canonical ones
# (e.g. "run" instead of "exec", "forget" instead of "delete"). If any
# alias stops resolving, the agent will hit the unknown-operation error
# path again.

use CLIO::Tools::Registry;
use Test::More;

my $registry = CLIO::Tools::Registry->new();

# Each case: [alias_name, expected_tool, expected_operation]
my @cases = (
    # terminal_operations natural-language verbs
    ['run',  'terminal_operations', 'exec'],
    ['bash', 'terminal_operations', 'exec'],
    ['cmd',  'terminal_operations', 'exec'],

    # memory_operations natural-language verbs
    ['get',    'memory_operations', 'retrieve'],
    ['save',   'memory_operations', 'store'],
    ['forget', 'memory_operations', 'delete'],

    # web_operations natural-language verbs
    ['curl',   'web_operations', 'fetch_url'],
    ['wget',   'web_operations', 'fetch_url'],
    ['http',   'web_operations', 'fetch_url'],
    ['google', 'web_operations', 'search_web'],

    # interact natural-language verbs
    ['ask_user', 'interact', 'request_input'],
    ['confirm',  'interact', 'request_input'],
    ['question', 'interact', 'request_input'],

    # Existing aliases - regression guard
    ['exec',    'terminal_operations', 'exec'],
    ['shell',   'terminal_operations', 'exec'],
    ['store',   'memory_operations',   'store'],
    ['retrieve','memory_operations',   'retrieve'],
    ['delete',  'memory_operations',   'delete'],
    ['search',  'memory_operations',   'search'],
    ['ask',     'interact',            'request_input'],
    ['collab',  'interact',            'request_input'],
    ['git',     'version_control',     'status'],
    ['status',  'version_control',     'status'],
    ['todo',    'todo_operations',     'write'],
    ['todos',   'todo_operations',     'read'],
    ['spawn',   'agent_operations',    'spawn'],
);

for my $case (@cases) {
    my ($alias, $expected_tool, $expected_op) = @$case;
    my $info = $registry->get_alias_info($alias);
    ok($info, "alias '$alias' is registered");
    if ($info) {
        is($info->{tool},      $expected_tool, "alias '$alias' -> tool '$expected_tool'");
        is($info->{operation}, $expected_op,    "alias '$alias' -> operation '$expected_op'");
    }
}

done_testing();
