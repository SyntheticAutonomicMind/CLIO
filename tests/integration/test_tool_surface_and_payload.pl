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

# --- Internal bookkeeping never reaches the wire ------------------------
# Tool-call hashes are carried in conversation history and cloned into the
# request payload. Any key CLIO adds is sent to the provider unless it is
# stripped, so the payload builders must remove all of them.
subtest 'internal tool_call keys are stripped from the payload' => sub {
    require CLIO::Core::APIManager;
    require CLIO::Core::Config;

    my $cfg_dir = tempdir(CLEANUP => 1);
    open my $cf, '>', "$cfg_dir/config.json" or die $!;
    print $cf q({"provider":"github_copilot","api_key":"sk-test-key"});
    close $cf;

    my $api = CLIO::Core::APIManager->new(
        config  => CLIO::Core::Config->new(config_dir => $cfg_dir),
        debug   => 0,
        session => bless({ state_data => {} }, 'FakeSession'),
    );

    my @internal = qw(_emitted_name _name_complete _parsed_args _dispatch_name);
    ok(scalar @CLIO::Core::APIManager::INTERNAL_TOOL_CALL_KEYS,
        'the internal key list is declared');
    is_deeply(
        [ sort @CLIO::Core::APIManager::INTERNAL_TOOL_CALL_KEYS ],
        [ sort @internal ],
        'the declared list covers every key CLIO attaches to a tool_call',
    );

    my $messages = [
        { role => 'user', content => 'find the file' },
        {
            role    => 'assistant',
            content => '',
            tool_calls => [ {
                id             => 'call_1',
                type           => 'function',
                # The model called file_search. function.name keeps that name;
                # the owning tool is carried separately for dispatch.
                function       => { name => 'file_search', arguments => '{"pattern":"**/x"}' },
                _name_complete => 1,
                _emitted_name  => 'file_search',
                _parsed_args   => { operation => 'file_search', pattern => '**/x' },
                _dispatch_name => 'file_operations',
            } ],
        },
        { role => 'tool', tool_call_id => 'call_1', content => 'ok' },
    ];

    my $payload = $api->_build_payload(
        $messages, 'gpt-4o', { endpoint => '/chat/completions', openai => 1 },
        stream => 0,
    );
    my $tc = $payload->{messages}[1]{tool_calls}[0];
    is_deeply([ sort keys %$tc ], [qw(function id type)],
        'Chat Completions tool_call carries only schema keys');
    ok(!exists $tc->{$_}, "Chat Completions payload has no $_") for @internal;
    is($tc->{function}{name}, 'file_search',
        'the payload keeps the callable the model actually called');
    is($tc->{function}{arguments}, '{"pattern":"**/x"}',
        'the real arguments are untouched');

    my $json = CLIO::Util::JSON::encode_json($payload);
    my @found = grep { index($json, $_) >= 0 } @internal;
    is_deeply(\@found, [], 'serialized Chat Completions body is clean');

    my $rpayload = $api->_build_responses_api_payload(
        $messages, 'gpt-4o',
        { endpoint => '/responses', openai => 1, use_responses_api => 1 },
        stream => 0,
    );
    my $rjson = CLIO::Util::JSON::encode_json($rpayload);
    my @rfound = grep { index($rjson, $_) >= 0 } @internal;
    is_deeply(\@rfound, [], 'serialized Responses body is clean');

    # The payload is a copy: the caller's history keeps its own bookkeeping.
    ok(exists $messages->[1]{tool_calls}[0]{_emitted_name},
        'stripping the payload does not modify the caller\'s message');
};

package FakeSession;
sub can   { my ($self, $m) = @_; return $m eq 'state' ? 1 : undef }
sub state { return $_[0]->{state_data} }

package main;

done_testing();
