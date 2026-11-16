#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# End-to-end regression for the session that ended on a todo error loop.
#
# The model sent three todo_update calls, each a different attempt at the same
# fix. Two of them invented field names; the first had a stray quote in its
# JSON that turned the rest of the payload into a key name. The turn used to
# end with "Tool error loop broken: 3 consecutive identical errors", which was
# wrong on two counts: the calls were not identical, and ending the turn threw
# away a model that was actively working the problem.
#
# This replays that sequence through the real orchestrator, the real TodoList
# tool, and the real TodoStore, and asserts that the model instead receives:
#   - the mangled-arguments diagnosis when its JSON was broken,
#   - the unrecognized-field rejection when it invented a name,
#   - a repeated-failure note when the pattern became clear,
#   - and that the turn keeps running.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use File::Temp qw(tempdir);
use JSON::PP ();

our @TOOL_RESULTS;

package MockConfig;
sub new { bless {}, shift }
sub get { my ($self, $k) = @_; return $k eq 'max_iterations' ? 20 : undef }
sub set { 1 }

package MockSession;
sub new {
    my ($class, %opts) = @_;
    return bless {
        session_id => 'mock-todo-loop',
        messages   => [],
        state      => { max_tokens => 200000, max_output_tokens => 16000 },
        %opts,
    }, $class;
}
sub id { $_[0]->{session_id} }
sub state { $_[0]->{state} }
sub add_message {
    my ($s, $role, $content, $meta) = @_;
    push @{ $s->{messages} }, { role => $role, content => $content, %{ $meta || {} } };
}
sub save { }
sub session_name { }

package MockAPIManager;
sub new {
    my ($class, %opts) = @_;
    return bless {
        calls     => 0,
        max_calls => $opts{max_calls} || 10,
        loop      => $opts{loop} || [],
        config    => MockConfig->new(),
        api_base  => 'https://mock.example.com/v1',
        _model    => 'mock-model',
    }, $class;
}
sub send_request_streaming {
    my ($self) = @_;
    $self->{calls}++;
    if (!@{ $self->{loop} } || $self->{calls} > $self->{max_calls}) {
        return { success => 1, content => 'Done.', finish_reason => 'stop' };
    }
    my $call = $self->{loop}[ ($self->{calls} - 1) % @{ $self->{loop} } ];
    return {
        success       => 1,
        content       => '',
        finish_reason => 'tool_calls',
        tool_calls    => [{
            id       => 'call_' . $self->{calls},
            type     => 'function',
            function => {
                name      => $call->{name},
                arguments => $call->{arguments},
            },
        }],
    };
}
sub get_current_model { 'mock-model' }
sub get_model_capabilities { { max_context_window_tokens => 200000, max_output_tokens => 16000 } }
sub model_supports_vision { 0 }
sub provider_for_model { 'mock' }
sub get_current_provider { 'mock' }
sub config { $_[0]->{config} }

package main;

use CLIO::Core::WorkflowOrchestrator;
use CLIO::Core::ToolErrorGuidance;
use CLIO::Core::ToolExecutor;
use CLIO::Tools::Registry;
use CLIO::Tools::TodoList;
use CLIO::Session::TodoStore;
use CLIO::UI::ToolOutputFormatter;
use CLIO::Util::PathResolver;
use CLIO::Logging::ProcessStats;

my $q = chr(39);

# The three payloads from the session, in order.
my $mangled_args = '{"todoUpdates":[{"id":1,"status":"blocked","blockedReason'
    . $q . ': ' . $q . 'needs a decision' . $q . '}] if False else [{":""}]}';
my $invented_args = JSON::PP::encode_json({
    todoUpdates => [ { id => 1, status => 'blocked', blockedReasonReason => 'x' } ],
});
my $invented_args_2 = JSON::PP::encode_json({
    todoUpdates => [ { id => 1, status => 'blocked', descriptionX => 'y' } ],
});

my @calls = (
    { name => 'todo_update', arguments => $mangled_args },
    { name => 'todo_update', arguments => $invented_args },
    { name => 'todo_update', arguments => $invented_args_2 },
);

my $dir = tempdir(CLEANUP => 1);
CLIO::Util::PathResolver::init(base_dir => $dir);

my $registry = CLIO::Tools::Registry->new(debug => 0);
$registry->register_tool(CLIO::Tools::TodoList->new(debug => 0));

my $api     = MockAPIManager->new(loop => \@calls, max_calls => 6);
my $session = MockSession->new();

my $orch = CLIO::Core::WorkflowOrchestrator->new(
    api_manager     => $api,
    session         => $session,
    config          => MockConfig->new(),
    debug           => 0,
    non_interactive => 1,
    max_iterations  => 8,
);
$orch->{tool_registry}  = $registry;
$orch->{tools}          = $registry->get_tool_definitions();
$orch->{tool_executor}  = CLIO::Core::ToolExecutor->new(
    session       => $session,
    tool_registry => $registry,
    config        => MockConfig->new(),
    debug         => 0,
);
$orch->{formatter}      = CLIO::UI::ToolOutputFormatter->new();
$orch->{error_guidance} = CLIO::Core::ToolErrorGuidance->new();

# The real turn context needs provider state the mock does not have.
{
    no warnings 'redefine';
    *CLIO::Core::WorkflowOrchestrator::_build_turn_context = sub {
        my ($self, $user_input) = @_;
        return ([
            { role => 'system', content => 'system' },
            { role => 'user',   content => $user_input },
        ], $self->{tools});
    };
}

# Seed a todo so the updates have something to target.
my $store = CLIO::Session::TodoStore->new(
    session_id   => 'mock-todo-loop',
    sessions_dir => CLIO::Util::PathResolver::get_sessions_dir(),
    debug        => 0,
);
$store->write([
    { title => 'First task', description => 'do the thing', status => 'not-started' },
]);

my $result = $orch->process_input('finish the work', $session);

subtest 'the turn is not ended by repeated tool errors' => sub {
    ok(!(ref $result eq 'HASH' && ($result->{error_type} // '') eq 'tool_error_loop'),
        'no tool_error_loop error was raised');
    ok(!(ref $result eq 'HASH' && !$result->{success} && $result->{error}
        && $result->{error} =~ /loop broken/i),
        'no loop-break message reached the caller');
};

subtest 'the model is told its JSON was mangled' => sub {
    my @tool_messages = grep { ($_->{role} // '') eq 'tool' }
        @{ $session->{messages} };
    ok(scalar @tool_messages >= 3, 'every call produced a tool result');

    my ($mangled) = grep { ($_->{content} // '') =~ /MALFORMED ARGUMENTS/ } @tool_messages;
    ok($mangled, 'the mangled call was diagnosed');
    like($mangled->{content}, qr/blockedReason/, 'the diagnosis names the broken key');
    like($mangled->{content}, qr/stray quote|quote or bracket/i,
        'the diagnosis names the cause');
};

subtest 'invented field names are rejected with the allowed list' => sub {
    my @tool_messages = grep { ($_->{role} // '') eq 'tool' }
        @{ $session->{messages} };

    my ($invented) = grep { ($_->{content} // '') =~ /blockedReasonReason/ } @tool_messages;
    ok($invented, 'the invented field was rejected');
    like($invented->{content}, qr/unrecognized field/i, 'the rejection says the field is unrecognized');
    like($invented->{content}, qr/Allowed fields:/, 'the rejection lists what is accepted');
};

subtest 'nothing invented was written to the todo list' => sub {
    my ($todo) = grep { ($_->{id} // 0) == 1 } @{ $store->read() };
    is($todo->{status}, 'not-started', 'the todo was not modified');
    ok(!exists $todo->{blockedReasonReason}, 'no invented field was persisted');
    ok(!exists $todo->{descriptionX}, 'no invented field was persisted');
};

subtest 'the repeated failure earns a guidance note' => sub {
    my @tool_messages = grep { ($_->{role} // '') eq 'tool' }
        @{ $session->{messages} };

    my ($note) = grep { ($_->{content} // '') =~ /REPEATED FAILURE|ERROR LOOP NOTICE/ }
        @tool_messages;
    ok($note, 'a loop note reached the model');
    like($note->{content}, qr/shape of the call|Change the input/,
        'the note says what has to change');
};

done_testing();
