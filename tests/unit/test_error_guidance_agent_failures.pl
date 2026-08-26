#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use lib './lib';

# Regression: every error pattern from the agent failure modes report must
# be categorized correctly. This is the single most important assertion
# for the bug reported on 2026-08-26 where the agent gave up after several
# "generic" tool errors. If any of these fall through to generic_error,
# the agent will see a useless "check the error message" guidance.

use CLIO::Core::ToolErrorGuidance;
use Test::More;

my $g = CLIO::Core::ToolErrorGuidance->new();

# Each case: [error_msg, expected_category]
my @cases = (
    # Bare "Missing 'X' parameter" - the most common agent error
    [q{Missing 'path' parameter},                'missing_required'],
    [q{Missing 'content' parameter},             'missing_required'],
    [q{Missing 'toolCallId' parameter},          'missing_required'],
    [q{Missing 'key' parameter},                 'missing_required'],
    [q{Missing 'query' parameter},               'missing_required'],
    [q{Missing 'symbol_name' parameter},         'missing_required'],
    [q{Missing 'line' parameter},                'missing_required'],
    [q{Missing 'old_string' parameter},          'missing_required'],
    [q{Missing 'new_string' parameter},          'missing_required'],
    [q{Missing 'old_path' parameter},            'missing_required'],
    [q{Missing 'new_path' parameter},            'missing_required'],
    [q{Missing 'replacements' parameter},        'missing_required'],
    [q{Missing 'pattern' parameter},             'missing_required'],
    [q{Missing 'fact' parameter},                'missing_required'],
    [q{Missing 'error' parameter},               'missing_required'],
    [q{Missing 'solution' parameter},            'missing_required'],
    [q{Missing 'replacement' parameter},         'missing_required'],
    [q{Missing 'search_text' parameter},         'missing_required'],

    # "Missing or empty 'X' parameter"
    [q{Missing or empty 'command' parameter},    'missing_required'],
    [q{Missing or empty 'files' parameter},      'missing_required'],

    # "'X' or 'Y' parameter" alternation form
    [q{Missing 'path' or 'paths' parameter},     'missing_required'],

    # Operation-requires-parameter form (the todoList vs todoUpdates mistake)
    [q{'write' operation requires 'todoList' parameter},   'missing_required'],
    [q{'update' operation requires 'todoUpdates' parameter}, 'missing_required'],
    [q{'add' operation requires 'newTodos' parameter},     'missing_required'],

    # Canonical form (already worked before the fix)
    [q{Missing required parameter: message},     'missing_required'],
    [q{Missing required parameters: targets, task_description}, 'missing_required'],

    # Missing operation parameter - the most common first-attempt mistake
    [q{Missing 'operation' parameter},           'missing_operation'],

    # TodoStore validation errors
    [q{Update validation failed:},               'todo_validation_failed'],
    [q{Multiple todos marked as in-progress (only 1 allowed): #5, #6}, 'todo_validation_failed'],

    # Already-working categories (regression guard)
    [q{Unknown operation: foo. Did you mean: bar?}, 'invalid_operation'],
    [q{File not found: /tmp/foo.txt},            'file_not_found'],
    [q{Permission denied},                       'permission_denied'],
    [q{Cannot find match position for chunk},    'edit_content_mismatch'],
);

for my $case (@cases) {
    my ($err, $expected) = @$case;
    my $cat = $g->_categorize_error($err, "any_tool");
    is($cat, $expected, "categorize: '$err'");
}

done_testing();
