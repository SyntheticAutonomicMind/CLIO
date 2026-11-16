#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_workflow_tool_round.pl - The tool round carries the emitted callable through to execution

=head1 DESCRIPTION

Phase 3 of C<CLIO::Core::WorkflowOrchestrator::_prepare_tool_round> rewrites an
emitted callable to the tool that owns it: C<file_search> becomes
C<file_operations> with C<operation =E<gt> 'file_search'> injected. Everything
downstream that names the call for display - the tool header, the session
replay, the loop guidance - must use the name the model emitted, and the
dispatcher must use the canonical name.

That only works if both survive on the same hash reference. This test asserts
the handoff rather than the rendering: the hashes in C<ordered_tools> are the
hashes that carry C<_emitted_name>, so a caller that reads either field gets the
right one. The previous coverage rendered through C<SessionReplay>, which meant
reverting the live header path left every test green.

=cut

use strict;
use warnings;
use utf8;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../lib";
use File::Temp qw(tempdir);
use CLIO::Core::Config;
use CLIO::Core::WorkflowOrchestrator;

sub build_orchestrator {
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/config.json" or die $!;
    print $fh q({"provider":"github_copilot","api_key":"sk-test-key"});
    close $fh;
    return CLIO::Core::WorkflowOrchestrator->new(
        config  => CLIO::Core::Config->new(config_dir => $dir),
        debug   => 0,
        session => undef,
    );
}

sub round {
    my ($orch, @calls) = @_;
    my $api_response = { content => '', tool_calls => \@calls };
    my @messages = ({ role => 'user', content => 'do the thing' });
    return $orch->_prepare_tool_round($api_response, \@messages, undef);
}

# The header source expression, kept next to the test so a change to one
# without the other is visible.
sub header_label {
    my ($tool_call) = @_;
    my $name = uc($tool_call->{_emitted_name} // $tool_call->{function}{name} // 'unknown');
    $name =~ s/_/ /g;
    return $name;
}

my $orch = build_orchestrator();
isa_ok($orch, 'CLIO::Core::WorkflowOrchestrator');

subtest 'an aliased call keeps the emitted name and records the dispatch tool' => sub {
    my $call = {
        id       => 'call_1',
        type     => 'function',
        function => { name => 'file_search', arguments => '{"pattern":"Scanner.pm"}' },
    };
    my $round = round($orch, $call);
    ok($round, 'tool round prepared');

    my @tools = @{ $round->{ordered_tools} };
    is(scalar @tools, 1, 'one tool ordered');

    my $ordered = $tools[0];
    is($ordered->{function}{name}, 'file_search',
        'the wire name keeps the callable the model emitted');
    is($ordered->{_dispatch_name}, 'file_operations',
        'the owning tool is recorded separately for dispatch');
    is($ordered->{_emitted_name}, 'file_search',
        'the emitted callable is recorded on the same hash');
    is(header_label($ordered), 'FILE SEARCH',
        'the header reads FILE SEARCH, not FILE OPERATIONS');
    is($ordered->{_parsed_args}{operation}, 'file_search',
        'the operation is injected for the dispatcher');
    is($ordered->{_parsed_args}{pattern}, 'Scanner.pm',
        'the caller arguments survive alias resolution');
};

subtest 'a call that was not rewritten is labelled as itself' => sub {
    my $call = {
        id       => 'call_2',
        type     => 'function',
        function => { name => 'terminal_operations',
                      arguments => '{"operation":"exec","command":"ls"}' },
    };
    my $round = round($orch, $call);
    my $ordered = $round->{ordered_tools}[0];
    is($ordered->{function}{name}, 'terminal_operations', 'name unchanged');
    is($ordered->{_emitted_name}, 'terminal_operations',
        'emitted name recorded even when no rewrite happened');
    is(header_label($ordered), 'TERMINAL OPERATIONS', 'header matches the call');
};

subtest 'a grouping name reaches dispatch and is rejected there' => sub {
    # The model must not reach an operation by naming the tool that owns it.
    # Phase 3 orders the call - the header then names what the model actually
    # emitted, which is honest - and ToolExecutor's surface check refuses it,
    # so the operation never runs.
    my $call = {
        id       => 'call_3',
        type     => 'function',
        function => { name => 'file_operations',
                      arguments => '{"operation":"file_search","pattern":"x"}' },
    };
    my $round = round($orch, $call);
    my @tools = @{ $round->{ordered_tools} || [] };
    is(scalar @tools, 1, 'the call is ordered');

    # A header naming the grouping name is correct here: the model did emit it.
    is(header_label($tools[0]), 'FILE OPERATIONS',
        'the header names the callable the model emitted');

    require CLIO::Util::JSON;
    my $raw = $orch->{tool_executor}->execute_tool($tools[0], 'call_3');
    my $result = CLIO::Util::JSON::decode_json($raw);
    ok(!$result->{success}, 'dispatch rejects the grouping name');
    like($result->{error}, qr/Unknown tool: file_operations/,
        'the error names the invented callable');
    like($result->{error}, qr/not part of the current tool set/,
        'the error says the name was never offered');
};

subtest 'multiple calls keep their own labels' => sub {
    my $round = round(
        $orch,
        { id => 'c1', type => 'function',
          function => { name => 'read_file', arguments => '{"path":"a.txt"}' } },
        { id => 'c2', type => 'function',
          function => { name => 'replace_string',
                        arguments => '{"path":"a.txt","old_string":"a","new_string":"b"}' } },
    );
    my %labels = map { header_label($_) => 1 } @{ $round->{ordered_tools} };
    ok($labels{'READ FILE'}, 'read_file labelled READ FILE');
    ok($labels{'REPLACE STRING'}, 'replace_string labelled REPLACE STRING');
    ok(!$labels{'FILE OPERATIONS'},
        'no call collapsed onto the grouping name');
};

subtest 'a mangled argument key is reported on the tool result' => sub {
    # What a stray quote in the arguments produces: the rest of the payload
    # becomes part of a key name, and the result still parses as valid JSON.
    my $q = chr(39);
    # Reproduces the shape from a real session: the stray quote swallows the
    # rest of the payload up to the next double quote, and the result is
    # still valid JSON.
    my $args = '{"todoUpdates":[{"id":4,"status":"blocked","blockedReason'
        . $q . ': ' . $q . 'because' . $q . '}] if False else [{":""}]}';

    my $call = {
        id       => 'call_mangled',
        type     => 'function',
        function => { name => 'todo_update', arguments => $args },
    };

    my $round = round($orch, $call);
    ok($round, 'the call is still dispatched: the tool decides what to do');
    my @tools = @{ $round->{ordered_tools} };
    is(scalar @tools, 1, 'one call ordered');
    ok(defined $tools[0]{_mangled_key}, 'the impossible key is recorded on the call');

    my $shown = $tools[0]{_mangled_key};
    like($shown, qr/blockedReason/, 'the recorded key identifies the field that was mangled');
};

subtest 'a well-formed call is unaffected by the mangled-key guard' => sub {
    my $round = round(
        $orch,
        { id => 'c1', type => 'function',
          function => { name => 'file_search',
                        arguments => '{"pattern":"*.pm","directory":"lib"}' } },
    );
    ok($round, 'the round is prepared');
    is(scalar @{ $round->{ordered_tools} }, 1, 'the call is ordered');
    ok(!defined $round->{ordered_tools}[0]{_mangled_key},
        'no mangled key recorded for a clean call');
};

subtest 'non-object arguments are rejected with a usable message' => sub {
    my @messages = ({ role => 'user', content => 'do the thing' });
    my $round = $orch->_prepare_tool_round(
        { content => '',
          tool_calls => [ {
              id => 'call_scalar', type => 'function',
              function => { name => 'read_file', arguments => '"lib/foo.pm"' },
          } ] },
        \@messages, undef);

    ok(!$round, 'nothing is dispatched for non-object arguments');

    my ($tool_msg) = grep { ($_->{role} // '') eq 'tool' } @messages;
    ok($tool_msg, 'the rejection is explained to the model');
    like($tool_msg->{content}, qr/decoded to a string/,
        'the message names the shape that arrived');
    like($tool_msg->{content}, qr/must be a JSON object/,
        'the message states what is required');
    like($tool_msg->{content}, qr/Nothing was executed/, 'the message says nothing ran');
};

done_testing();
