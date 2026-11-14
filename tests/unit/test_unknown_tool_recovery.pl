#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Util::JSON qw(decode_json);
use CLIO::Tools::Registry;
use CLIO::Tools::FileOperations;
use CLIO::Tools::TerminalOperations;
use CLIO::Tools::TodoList;
use CLIO::Core::ToolErrorGuidance;
use CLIO::Core::ToolCallExtractor;
use CLIO::Core::ToolExecutor;

# A model that names a tool it was never given must be told the truth twice:
# the call is refused (no silent redirect), and the error names the callables
# that would have worked. The textual "[tool operation]" format is normalized
# where the text is parsed, so the dispatcher never needs a compatibility
# hatch.

my $registry = CLIO::Tools::Registry->new();
for my $class (qw(FileOperations TerminalOperations TodoList)) {
    my $module = "CLIO::Tools::$class";
    $registry->register_tool($module->new(debug => 0));
}

ok(!$registry->is_emitted_name('file_operations'),
    'grouping name file_operations is not emitted');
ok($registry->is_emitted_name('read_file'),
    'per-operation callable read_file is emitted');

my $rejection = "Unknown tool: file_operations (this name is not part of the "
    . "current tool set). Use one of the callable names from the tool "
    . "definitions, exactly as written there.";

# ── Guidance ────────────────────────────────────────────────────────────────

my $guidance = CLIO::Core::ToolErrorGuidance->new(tool_registry => $registry);

is($guidance->categorize_error($rejection, 'file_operations'), 'unknown_tool',
    'rejection is categorized as unknown_tool, not as a tool failure');

my $text = $guidance->enhance_tool_error(
    error      => $rejection,
    tool_name  => 'file_operations',
    attempted_params => { operation => 'read_file', path => 'README.md' },
);

like($text, qr/\bread_file\b/, 'recovery names read_file as the callable to use');
like($text, qr/\{"name": "read_file", "parameters": \{"path":"README\.md"\}\}/,
    'recovery prints the corrected call with the operation field dropped');
unlike($text, qr/call\s+file_operations\s+with\s+operation/i,
    'recovery does not teach wrapping an operation in the grouping name');
unlike($text, qr/\{"operation"/,
    'recovery prints no example that passes an operation field');
like($text, qr/'operation' field is not part of that call/,
    'recovery states the operation-field rule');

# Without an attempted operation there is nothing to resolve to one callable,
# so the guidance lists the tool's published names instead.
my $list_text = $guidance->enhance_tool_error(
    error     => $rejection,
    tool_name => 'file_operations',
);
like($list_text, qr/Call one of these names directly: .*\bread_file\b/,
    'recovery lists published callables when the operation is unknown');
like($list_text, qr/\bwrite_file\b/, 'listed callables include write_file');

# A name that matches no registered tool falls back to name-overlap hints.
my $typo_text = $guidance->enhance_tool_error(
    error     => "Unknown tool: read_fil (this name is not part of the current tool set).",
    tool_name => 'read_fil',
);
like($typo_text, qr/\bread_file\b/, 'typo recovery suggests read_file');
unlike($typo_text, qr/That callable takes:/,
    'typo recovery with several candidates prints no single call shape');

# A call that names only the grouping tool still gets a usable call shape
# instead of an empty parameter object.
my $shape_text = $guidance->enhance_tool_error(
    error            => $rejection,
    tool_name        => 'file_operations',
    attempted_params => { operation => 'write_file' },
);
like($shape_text, qr/"name": "write_file"/,
    'recovery names the callable the operation belongs to');
like($shape_text, qr/"path":"<path>"/,
    'recovery fills the corrected call from the callable schema');
like($shape_text, qr/"content":"<content>"/,
    'recovery includes every required parameter');

# ── Dispatcher ──────────────────────────────────────────────────────────────

my $executor = CLIO::Core::ToolExecutor->new(
    tool_registry => $registry,
    debug         => 0,
);

my $raw = $executor->execute_tool({
    type     => 'function',
    function => {
        name      => 'file_operations',
        arguments => '{"operation":"read_file","path":"README.md"}',
    },
}, 'call-grouping-name');

my $result = decode_json($raw);
is($result->{success}, 0,
    'grouping name with an explicit operation is refused, not redirected');
like($result->{error}, qr/not part of the current tool set/,
    'refusal says the name is not callable');
ok(!exists $result->{output} || $result->{output} !~ /^\s*[\{\[]/,
    'refusal does not return a file read result');

# ── Text-format normalization ───────────────────────────────────────────────

my $extractor = CLIO::Core::ToolCallExtractor->new(
    registry => $registry,
    debug    => 0,
);

my $clio = $extractor->extract(
    "[file_operations read_file]\n{\"path\": \"README.md\"}"
);
is(scalar @{ $clio->{tool_calls} }, 1, 'text format still extracts one call');
is($clio->{tool_calls}[0]{function}{name}, 'read_file',
    'text format resolves the grouping/operation pair to the emitted callable');

my $clio_args = decode_json($clio->{tool_calls}[0]{function}{arguments});
ok(exists $clio_args->{path}, 'resolved call keeps the real parameter');
ok(!exists $clio_args->{operation},
    'textual operation key is dropped for a per-operation callable');

my $consolidated = $extractor->extract(
    "[terminal_operations exec]\n{\"command\": \"ls\"}"
);
is($consolidated->{tool_calls}[0]{function}{name}, 'terminal_operations',
    'consolidated callable keeps its published name');
my $consolidated_args = decode_json($consolidated->{tool_calls}[0]{function}{arguments});
is($consolidated_args->{operation}, 'exec',
    'consolidated callable keeps the operation it needs');

done_testing();
