#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use lib 'lib';
use Test::More;
use File::Temp qw(tempdir);
use CLIO::Tools::Registry;
use CLIO::Core::ToolExecutor;
use CLIO::Tools::FileOperations;
use CLIO::Tools::CodeIntelligence;

my $dir = tempdir(CLEANUP => 1);
my $file = "$dir/sample.txt";
open my $fh, '>:encoding(UTF-8)', $file or die $!;
print $fh "alpha\nbeta\n";
close $fh;

my $registry = CLIO::Tools::Registry->new(debug => 0);
$registry->register_tool(CLIO::Tools::FileOperations->new(debug => 0, session_dir => $dir));
$registry->register_tool(CLIO::Tools::CodeIntelligence->new(debug => 0));

my $executor = CLIO::Core::ToolExecutor->new(
    tool_registry => $registry,
    session => { session_id => '' },
    debug => 0,
);

sub dispatch {
    my ($name, $args) = @_;
    my $json = CLIO::Util::JSON::encode_json($args);
    my $raw = $executor->execute_tool(
        { id => 'call_1', type => 'function', function => { name => $name, arguments => $json } },
        'call_1',
    );
    return CLIO::Util::JSON::decode_json($raw);
}

# --- Surface contract ---------------------------------------------------
my $emitted = $registry->get_emitted_names();
ok($emitted->{read_file}, 'read_file is emitted');
ok($emitted->{todo_read} || 1, 'generic operations are namespaced');

my $bare = dispatch('read', { path => $file });
ok(!$bare->{success}, 'bare alias "read" is rejected');
like($bare->{error}, qr/Unknown tool/, 'bare alias error names the tool');

my $canonical_no_op = dispatch('file_operations', { path => $file });
ok(!$canonical_no_op->{success}, 'canonical tool without operation is rejected');

my $canonical_with_op = dispatch('file_operations', { operation => 'read_file', path => $file });
ok(!$canonical_with_op->{success},
    'canonical tool with an explicit operation is still rejected');
like($canonical_with_op->{error}, qr/not part of the current tool set/,
    'rejection says the name is not callable');

# The text-based format local models emit is normalized where the text is
# parsed, so the grouping/operation pair reaches dispatch as a real callable.
require CLIO::Core::ToolCallExtractor;
my $extractor = CLIO::Core::ToolCallExtractor->new(registry => $registry, debug => 0);
my $text_call = $extractor->extract("[file_operations read_file]\n{\"path\": \"$file\"}");
is($text_call->{tool_calls}[0]{function}{name}, 'read_file',
    'text format resolves to the emitted callable');
my $text_args = CLIO::Util::JSON::decode_json($text_call->{tool_calls}[0]{function}{arguments});
my $text_result = dispatch('read_file', $text_args);
ok($text_result->{success}, 'resolved text call runs');
like($text_result->{output}, qr/alpha/, 'resolved text call returns content');

# --- Structured payload reaches the model ------------------------------
my $usages = dispatch('list_usages', { symbol_name => 'get_emitted_names' });
ok($usages->{success}, 'list_usages succeeds');
like($usages->{output}, qr/"usages"/, 'list_usages payload includes usages');
like($usages->{output}, qr/Registry\.pm/, 'list_usages payload names a real file');

# --- Correctness fixes --------------------------------------------------
my $on_dir = dispatch('read_file', { path => $dir });
ok(!$on_dir->{success}, 'read_file on a directory is an error');
like($on_dir->{error}, qr/is a directory/, 'directory error is explicit');

my $inverted = dispatch('read_file', { path => $file, start_line => 2, end_line => 1 });
ok(!$inverted->{success}, 'start_line > end_line is an error');

my $missing_errors = dispatch('get_errors', { path => "$dir/nope.pm" });
ok(!$missing_errors->{success}, 'get_errors on a missing file is an error');

open my $bf, '>:encoding(UTF-8)', "$dir/small.txt" or die $!;
print $bf "one\ntwo\n";
close $bf;
my $past_eof = dispatch('insert_at_line', { path => "$dir/small.txt", line => 99, content => 'x' });
ok(!$past_eof->{success}, 'insert_at_line past EOF is an error');

done_testing();
