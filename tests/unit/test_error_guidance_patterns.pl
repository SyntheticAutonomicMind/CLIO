#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use lib './lib';

use CLIO::Core::ToolErrorGuidance;
use Test::More;

# Test: Every error pattern from real-world agent failures is correctly
# categorized and yields actionable guidance. See scratch/CLIO_AGENT_FAILURES.md
# for the failure modes that motivated these tests.

my $g = CLIO::Core::ToolErrorGuidance->new();

# ---- Categorization tests ----

# Each case: [error_msg, expected_category, expected_missing_param]
my @categorization_cases = (
    # Original canonical form (already worked)
    [q{Missing required parameter: message},     'missing_required',  'message'],
    [q{Missing required parameters: targets, task_description}, 'missing_required', 'targets, task_description'],

    # Canonical form for FileOperations fields (now used by handlers after
    # the validator rework - minimal schema + handler-enforced per-op reqs)
    [q{Missing required parameter: path},        'missing_required',  'path'],
    [q{Missing required parameter: content},     'missing_required',  'content'],
    [q{Missing required parameter: old_string},  'missing_required',  'old_string'],
    [q{Missing required parameter: new_string},  'missing_required',  'new_string'],
    [q{Missing required parameter: line},        'missing_required',  'line'],
    [q{Missing required parameter: old_path},    'missing_required',  'old_path'],
    [q{Missing required parameter: new_path},    'missing_required',  'new_path'],
    [q{Missing required parameter: query},       'missing_required',  'query'],
    [q{Missing required parameter: pattern},     'missing_required',  'pattern'],
    [q{Missing required parameter: toolCallId},  'missing_required',  'toolCallId'],
    [q{Missing required parameter: replacements}, 'missing_required', 'replacements'],
    [q{Missing required parameter: paths},       'missing_required',  'paths'],

    # Bare "Missing 'X' parameter" form (was generic_error)
    [q{Missing 'path' parameter},                'missing_required',  'path'],
    [q{Missing 'content' parameter},             'missing_required',  'content'],
    [q{Missing 'toolCallId' parameter},          'missing_required',  'toolCallId'],
    [q{Missing 'key' parameter},                 'missing_required',  'key'],
    [q{Missing 'query' parameter},               'missing_required',  'query'],
    [q{Missing 'symbol_name' parameter},         'missing_required',  'symbol_name'],
    [q{Missing 'line' parameter'},               'missing_required',  'line'],
    [q{Missing 'old_string' parameter},          'missing_required',  'old_string'],
    [q{Missing 'new_string' parameter},          'missing_required',  'new_string'],
    [q{Missing 'old_path' parameter},            'missing_required',  'old_path'],
    [q{Missing 'new_path' parameter},            'missing_required',  'new_path'],
    [q{Missing 'replacements' parameter},        'missing_required',  'replacements'],
    [q{Missing 'pattern' parameter},             'missing_required',  'pattern'],
    [q{Missing 'fact' parameter},                'missing_required',  'fact'],
    [q{Missing 'error' parameter},               'missing_required',  'error'],
    [q{Missing 'solution' parameter},            'missing_required',  'solution'],
    [q{Missing 'pattern' parameter},             'missing_required',  'pattern'],
    [q{Missing 'replacement' parameter},         'missing_required',  'replacement'],
    [q{Missing 'search_text' parameter},         'missing_required',  'search_text'],

    # "Missing or empty" form
    [q{Missing or empty 'command' parameter},    'missing_required',  'command'],
    [q{Missing or empty 'files' parameter},      'missing_required',  'files'],

    # "'X' or 'Y' parameter" form (alternatives)
    [q{Missing 'path' or 'paths' parameter},     'missing_required',  'path'],

    # Operation-requires-parameter form
    [q{'write' operation requires 'todoList' parameter},   'missing_required', 'todoList'],
    [q{'update' operation requires 'todoUpdates' parameter}, 'missing_required', 'todoUpdates'],
    [q{'add' operation requires 'newTodos' parameter},     'missing_required', 'newTodos'],

    # Missing operation parameter (NEW category)
    [q{Missing 'operation' parameter},           'missing_operation', 'operation'],

    # Already-working categories
    [q{Unknown operation: foo. Did you mean: bar?}, 'invalid_operation', undef],
    [q{File not found: /tmp/foo.txt},            'file_not_found',    undef],
    [q{Permission denied},                       'permission_denied', undef],
    [q{Cannot find match position for chunk},   'edit_content_mismatch', undef],
);

for my $case (@categorization_cases) {
    my ($err, $expected_cat, $expected_missing) = @$case;
    my $cat = $g->_categorize_error($err, "any_tool");
    is($cat, $expected_cat, "categorize: '$err' -> $expected_cat");

    # Verify parameter extraction by exercising the guidance sub.
    if ($expected_missing) {
        my $guidance = $g->_get_category_guidance($cat, "any_tool", $err, {}, undef);
        # For multi-param cases, the joined string should appear in the guidance.
        my @expected = split /\s*,\s*/, $expected_missing;
        for my $p (@expected) {
            like($guidance, qr/\Q$p\E/,
                "guidance for '$err' names the missing param '$p'");
        }
    }
}

# ---- Guidance tests for the new missing_operation category ----

subtest 'missing_operation guidance' => sub {
    # Without a tool_def, the guidance should still direct the agent to add
    # an operation field and tell them where to find the valid options.
    my $g1 = $g->_get_category_guidance('missing_operation', 'terminal_operations',
        q{Missing 'operation' parameter}, {}, undef);
    like($g1, qr/specifying which operation/i, "says 'specify an operation'");
    like($g1, qr/operation.*REQUIRED/i, "says operation is required");
    like($g1, qr/terminal_operations/i, "names the tool");

    # With a tool_def, the guidance should list the valid operations.
    my $def = {
        parameters => {
            properties => {
                operation => {
                    type => 'string',
                    enum => ['exec', 'validate'],
                },
            },
        },
    };
    my $g2 = $g->_get_category_guidance('missing_operation', 'terminal_operations',
        q{Missing 'operation' parameter}, {}, $def);
    like($g2, qr/exec.*validate|validate.*exec/, "lists valid operations");
};

# ---- End-to-end test: simulate what the agent sees ----

subtest 'end-to-end: terminal_operations called without operation' => sub {
    my $def = {
        name => 'terminal_operations',
        parameters => {
            type => 'object',
            properties => {
                operation => {
                    type => 'string',
                    enum => ['exec', 'validate'],
                },
                command => { type => 'string' },
            },
            required => ['operation'],
        },
    };
    my $enhanced = $g->enhance_tool_error(
        error => q{Missing 'operation' parameter},
        tool_name => 'terminal_operations',
        tool_definition => $def,
        attempted_params => { command => 'ls -la' },
    );
    like($enhanced, qr/operation/i, "mentions operation");
    like($enhanced, qr/exec.*validate|validate.*exec/, "lists valid operations");
    like($enhanced, qr/operation.*REQUIRED/i, "calls operation required");
};

subtest 'end-to-end: todo_operations update sent with wrong param slot' => sub {
    # This is the exact failure from the user's bug report:
    # update called with todoList content instead of todoUpdates.
    my $def = {
        name => 'todo_operations',
        parameters => {
            type => 'object',
            properties => {
                operation => { type => 'string', enum => ['read','write','update','add'] },
                todoUpdates => { type => 'array' },
            },
        },
    };
    my $enhanced = $g->enhance_tool_error(
        error => q{'update' operation requires 'todoUpdates' parameter},
        tool_name => 'todo_operations',
        tool_definition => $def,
        attempted_params => { operation => 'update', todoList => [{id=>1}] },
    );
    like($enhanced, qr/todoUpdates/, "names the correct param: todoUpdates");
    like($enhanced, qr/update.*needs.*todoUpdates|update.*requires.*todoUpdates/i,
        "explains update needs todoUpdates");
};

subtest 'end-to-end: file_operations write_file without path' => sub {
    my $def = {
        name => 'file_operations',
        parameters => {
            type => 'object',
            properties => {
                operation => { type => 'string', enum => ['read_file','write_file'] },
                path => { type => 'string' },
                content => { type => 'string' },
            },
        },
    };
    my $enhanced = $g->enhance_tool_error(
        error => q{Missing 'path' parameter},
        tool_name => 'file_operations',
        tool_definition => $def,
        attempted_params => { operation => 'write_file', content => 'hi' },
    );
    like($enhanced, qr/\bpath\b/, "names the missing param: path");
};

done_testing();
