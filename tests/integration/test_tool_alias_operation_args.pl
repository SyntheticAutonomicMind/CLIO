#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression tests for the arguments the orchestrator hands to the tool
# round when the model emits a per-operation callable.
#
# The failure these cover: alias resolution rewrites `grep_search` to
# `file_operations` and injects operation => 'grep_search' into
# _parsed_args, but the round loop re-parsed function->{arguments}, which
# never carried that operation. With $tool_operation empty:
#   * _capture_file_before returned undef, so edits made through
#     replace_string/write_file/insert_at_line displayed no diff at all;
#   * ToolLoopDetector saw a grouping name with no operation, classified
#     every read-only call as state-changing, reset its window on each
#     call, and the success loop never escalated (60+ identical searches
#     in a field report).
#
# Both symptoms are asserted here against the real workflow orchestrator
# driven by a mock provider.

use strict;
use warnings;
use utf8;
use lib 'lib';

use Test::More;
use File::Temp qw(tempdir);
use JSON::PP;
use CLIO::Util::PathResolver;

our @CAPTURE_LOG;
our @DIFF_LOG;
our @DETECTOR_LOG;

package MockConfig;
sub new { bless {}, shift }
sub get { my ($self, $k) = @_; return $k eq 'max_iterations' ? 0 : undef }
sub set { 1 }

package MockSession;
sub new {
    my ($class, %opts) = @_;
    return bless {
        session_id => 'mock-' . time,
        messages   => [],
        state      => { max_tokens => 128000, max_output_tokens => 16000 },
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
        return { success => 1, content => 'Finished.', finish_reason => 'stop' };
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
                arguments => JSON::PP::encode_json($call->{args}),
            },
        }],
    };
}
sub get_current_model { 'mock-model' }
sub get_model_capabilities { { max_context_window_tokens => 128000, max_output_tokens => 16000 } }
sub model_supports_vision { 0 }
sub provider_for_model { 'mock' }
sub get_current_provider { 'mock' }
sub config { $_[0]->{config} }

package main;

use CLIO::Core::WorkflowOrchestrator;
use CLIO::Core::ToolErrorGuidance;
use CLIO::Core::ToolExecutor;
use CLIO::Core::ToolLoopDetector;
use CLIO::Tools::Registry;
use CLIO::Tools::FileOperations;
use CLIO::UI::ToolOutputFormatter;
use CLIO::Logging::ProcessStats;

sub build_orchestrator {
    my ($api, $session, $dir) = @_;

    my $registry = CLIO::Tools::Registry->new(debug => 0);
    $registry->register_tool(CLIO::Tools::FileOperations->new(session_dir => $dir));

    my $orch = CLIO::Core::WorkflowOrchestrator->new(
        api_manager     => $api,
        session         => $session,
        config          => MockConfig->new(),
        debug           => 0,
        non_interactive => 1,
        max_iterations  => 20,
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

    return $orch;
}

# Keep the mock turn context: the real one builds system prompts (and the
# prompt builder needs provider state the mock does not have).
{
    no warnings 'redefine';
    *CLIO::Core::WorkflowOrchestrator::_build_turn_context = sub {
        my ($self, $user_input) = @_;
        return ([
            { role => 'system', content => 'system' },
            { role => 'user',   content => $user_input },
        ], $self->{tools});
    };

    my $orig_capture = \&CLIO::Core::WorkflowOrchestrator::_capture_file_before;
    *CLIO::Core::WorkflowOrchestrator::_capture_file_before = sub {
        my ($self, $tool_name, $operation, $args) = @_;
        my $before = $orig_capture->($self, $tool_name, $operation, $args);
        push @CAPTURE_LOG, {
            tool      => $tool_name,
            operation => $operation,
            captured  => $before ? [ sort keys %$before ] : [],
        };
        return $before;
    };

    my $orig_diff = \&CLIO::Core::WorkflowOrchestrator::_display_file_diff;
    *CLIO::Core::WorkflowOrchestrator::_display_file_diff = sub {
        my ($self, $before_map, $tool_name, $operation, $args, $opts) = @_;
        push @DIFF_LOG, {
            tool      => $tool_name,
            operation => $operation,
            files     => $before_map ? [ sort keys %$before_map ] : [],
        };
        return $orig_diff->(@_);
    };

    my $orig_record = \&CLIO::Core::ToolLoopDetector::record_call;
    *CLIO::Core::ToolLoopDetector::record_call = sub {
        my ($self, $name, $args, $content) = @_;
        my $verdict = $orig_record->($self, $name, $args, $content);
        push @DETECTOR_LOG, {
            tool      => $name,
            operation => $args && ref($args) eq 'HASH' ? $args->{operation} : undef,
            sig       => $verdict->{sig} // '',
            tracked   => $verdict->{tracked} // 0,
            count     => $verdict->{count} // 0,
            break     => $verdict->{break} // 0,
            nudge     => $verdict->{nudge} // 0,
        };
        return $verdict;
    };
}

# Expand __DIR__ placeholders inside the mock's arguments once the temp
# directory exists, so call definitions can be written literally.
sub _expand_dir {
    my ($value, $dir) = @_;
    my $ref = ref $value;
    return { map { $_ => _expand_dir($value->{$_}, $dir) } keys %$value } if $ref eq 'HASH';
    return [ map { _expand_dir($_, $dir) } @$value ] if $ref eq 'ARRAY';
    if (!ref $value && defined $value) {
        $value =~ s/__DIR__/$dir/g;
    }
    return $value;
}

sub run_loop {
    my (%opts) = @_;
    @CAPTURE_LOG = ();
    @DIFF_LOG    = ();
    @DETECTOR_LOG = ();

    my $dir = tempdir(CLEANUP => 1);
    CLIO::Util::PathResolver::init(base_dir => $dir);

    my @calls = map {
        { %$_, args => _expand_dir($_->{args}, $dir) }
    } @{ $opts{calls} || [] };

    my $api     = MockAPIManager->new(loop => \@calls, max_calls => $opts{max_calls});
    my $session = MockSession->new();
    my $orch    = build_orchestrator($api, $session, $dir);
    my $result  = $orch->process_input('do the thing', $session);

    return {
        dir    => $dir,
        api    => $api,
        result => $result,
    };
}

# ---------------------------------------------------------------------------
# 1. A replace_string call emitted by the model reaches the round loop with
#    its operation intact, so the before-image is captured and a diff shown.
# ---------------------------------------------------------------------------
subtest 'alias edit call carries its operation and displays a diff' => sub {
    my $note = "alpha\nbeta\ngamma\n";

    my $run = run_loop(
        max_calls => 2,
        calls     => [
            { name => 'write_file', args => { path => '__DIR__/note.txt', content => $note } },
            { name => 'replace_string', args => {
                path => '__DIR__/note.txt', old_string => 'beta', new_string => 'BETA',
            } },
        ],
    );

    my @ops = map { $_->{operation} } @CAPTURE_LOG;
    is_deeply(
        [ grep { defined } @ops ],
        [ 'write_file', 'replace_string' ],
        'round loop passes the resolved operation for each alias call'
    ) or diag("captured operations: " . join(',', map { $_ // 'undef' } @ops));

    my ($edit_capture) = grep { ($_->{operation} // '') eq 'replace_string' } @CAPTURE_LOG;
    ok($edit_capture, 'replace_string reached _capture_file_before');
    is(scalar @{ $edit_capture->{captured} }, 1,
        'before-image captured for replace_string')
        or diag("captured: " . join(',', @{ $edit_capture->{captured} }));

    my ($edit_diff) = grep { ($_->{operation} // '') eq 'replace_string' } @DIFF_LOG;
    ok($edit_diff, 'diff display invoked for replace_string')
        or diag('no diff displayed - $tool_operation was lost');
    is(scalar @{ $edit_diff->{files} }, 1, 'diff display got the edited file')
        if $edit_diff;

    # The write_file call created a new file: nothing to diff, but the
    # capture must still have been attempted with the operation set.
    my ($write_capture) = grep { ($_->{operation} // '') eq 'write_file' } @CAPTURE_LOG;
    ok($write_capture, 'write_file reached _capture_file_before with its operation');
};

# ---------------------------------------------------------------------------
# 2. Repeated read-only alias calls are tracked, not treated as
#    state-changing, so the success-loop detector escalates and ends the turn
#    instead of letting the model search forever.
# ---------------------------------------------------------------------------
subtest 'repeated read-only alias calls escalate instead of looping' => sub {
    my $run = run_loop(
        max_calls => 60,
        calls     => [
            { name => 'file_search', args => { pattern => 'outline - unsupported', directory => '.' } },
            { name => 'file_exists', args => { path => 'README.md' } },
            { name => 'file_search', args => { pattern => '*advanced*', directory => '.' } },
        ],
    );

    ok(scalar @DETECTOR_LOG > 0, 'detector recorded calls');

    my @untracked = grep { !$_->{tracked} } @DETECTOR_LOG;
    is(scalar @untracked, 0, 'every read-only alias call is tracked')
        or diag('untracked: ' . join(', ', map { $_->{tool} . '/' . ($_->{operation} // 'undef') } @untracked));

    my @missing_op = grep { !defined $_->{operation} } @DETECTOR_LOG;
    is(scalar @missing_op, 0, 'every recorded call carries its operation')
        or diag('missing operation: ' . join(', ', map { $_->{tool} } @missing_op));

    my @escaped = grep { $_->{break} || $_->{nudge} } @DETECTOR_LOG;
    ok(scalar @escaped > 0, 'loop escalation fired for repeated stable searches');

    cmp_ok($run->{api}->{calls}, '<', 20,
        "turn ended early instead of burning 60 calls (made $run->{api}->{calls})");
};

done_testing();
