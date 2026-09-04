#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: the resume fast path must not duplicate history.
#
# When a session is resumed, _try_resume_from_payload returns the cached
# payload verbatim (when ctx >= saved_ctx). The cached payload's
# structure in the role-based format is:
#   [system, anchor_msgs, recent_msgs, dynamic_userContext, user_input,
#    assistant+tool_calls, tool_results, ..., final_assistant]
#
# Before this fix, _build_turn_context tried to pop [user, system]
# from the tail (assuming the old XML pipeline shape). The new format
# ends with `assistant`, not `user`, so no pops fired. The cached
# payload was kept intact AND the projection's anchor + recent were
# APPENDED on top - the model saw every prior message twice.
#
# After the fix, _build_turn_context only reuses the system_prompt
# from the cache. Everything else is rebuilt fresh from session
# history via the normal projection pipeline.
#
# This test exercises the resume path end-to-end and asserts no
# duplicate role+content pairs in the resulting messages array.

use strict;
use warnings;
use utf8;
no warnings 'redefine';
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Session::State;

# Build a synthetic session state with a multi-turn history.
my $state = CLIO::Session::State->new(
    session_id => 'test-resume-no-dup',
    max_tokens => 128000,
);

my @history;
push @history, { role => 'user', content => 'Original task: investigate the bug in module X with sufficient content here for anchor ' . 'x' x 40 };
push @history, { role => 'assistant', content => 'Investigating.', tool_calls => [{ id => 'a1', function => { name => 'grep', arguments => '{}' } }] };
push @history, { role => 'tool', tool_call_id => 'a1', content => 'grep result' };
push @history, { role => 'assistant', content => 'Found the bug.' };
push @history, { role => 'user', content => 'Continue with module Y ' . 'y' x 40 };
push @history, { role => 'assistant', content => 'On it.', tool_calls => [{ id => 'b1', function => { name => 'read', arguments => '{}' } }] };
push @history, { role => 'tool', tool_call_id => 'b1', content => 'file contents' };
push @history, { role => 'assistant', content => 'Done with module Y.' };
push @history, { role => 'user', content => 'final ask ' . 'z' x 40 };
push @history, { role => 'assistant', content => 'Final answer', tool_calls => [{ id => 'c1', function => { name => 'ls', arguments => '{}' } }] };
push @history, { role => 'tool', tool_call_id => 'c1', content => 'file list' };
push @history, { role => 'assistant', content => 'Here is the result.' };

for my $msg (@history) {
    my %opts;
    $opts{tool_calls} = $msg->{tool_calls} if $msg->{tool_calls};
    $opts{tool_call_id} = $msg->{tool_call_id} if $msg->{tool_call_id};
    $state->add_message($msg->{role}, $msg->{content}, \%opts);
}

# Build the cached payload as _capture_api_payload would have saved it.
my @cached_payload;
push @cached_payload, { role => 'system', content => '[cached system prompt that includes tools and profile]' };
push @cached_payload, @history;
push @cached_payload, { role => 'system', content => '[cached dynamic_userContext with environment block]' };

$state->{last_api_payload} = [@cached_payload];
$state->{last_api_metadata} = {
    saved_at => time(),
    provider => 'minimax',
    model    => 'MiniMax-M3',
    context_window => 200000,
    tools_signature => 'fake-signature',
};

# Inline fake classes (no `my` needed in methods).
package FakeSession;
sub FakeSession::new { my $pkg = shift; my %a = @_; bless { %a }, $pkg }
sub FakeSession::state { $_[0]->{state} }
sub FakeSession::id    { $_[0]->{session_id} || 'test-session' }
sub FakeSession::ltm   { undef }
sub FakeSession::get_conversation_history { [ @{$_[0]->{state}->{history} || []} ] }
sub FakeSession::yarn  { undef }

package FakeAPI;
sub FakeAPI::new { my $pkg = shift; my %a = @_; bless { %a }, $pkg }
sub FakeAPI::get_current_provider { 'minimax' }
sub FakeAPI::get_current_model    { 'MiniMax-M3' }
sub FakeAPI::get_model_capabilities { { max_context_window_tokens => 200000, max_output_tokens => 128000 } }

package main;

my $session = FakeSession->new(state => $state, session_id => 'test-resume-no-dup');
my $api = FakeAPI->new();
my $tools = [{ type => 'function', function => { name => 'fake_tool', description => 'fake', parameters => {} } }];

require CLIO::Core::WorkflowOrchestrator;
my $wo = bless {
    api_manager => $api,
    debug => 0,
    _active_task_text => sub { return 'test task'; },
    _read_active_todos_for_projection => sub { return []; },
    _read_ltm_entries_for_projection => sub { return []; },
    _collect_unresolved_state => sub { return []; },
    _render_context_files_for_user_context => sub { return ''; },
    _tools_cache => undef,
}, 'CLIO::Core::WorkflowOrchestrator';

# Stub _build_tools_for_api and _tools_signature at the package level.
{
    no warnings 'redefine';
    *CLIO::Core::WorkflowOrchestrator::_build_tools_for_api = sub {
        my $self = shift;
        return ($tools);
    };
    *CLIO::Core::WorkflowOrchestrator::_tools_signature = sub {
        my ($self, $t) = @_;
        return 'fake-signature';
    };
}

my ($messages, $tools_back) = $wo->_build_turn_context('continue the work', $session,);

# The fix: messages array should contain each unique role+content at most once.
my %seen;
my @dups;
for my $i (0 .. $#$messages) {
    my $m = $messages->[$i];
    next unless ref($m) eq 'HASH';
    next if $m->{role} eq 'system';
    next if $m->{role} eq 'tool';
    my $key = "$m->{role}|" . substr($m->{content} // '', 0, 200);
    if ($seen{$key}++) {
        push @dups, "[$i] $key";
    }
}

ok(!@dups, "No duplicate user/assistant messages in resumed messages array")
    or diag("Duplicates found:\n" . join("\n", @dups));

# The anchor should be present exactly once.
my $anchor_count = 0;
for my $m (@$messages) {
    if ($m->{role} eq 'user' && ($m->{content} // '') =~ /Original task: investigate/) {
        $anchor_count++;
    }
}
is($anchor_count, 1, "Anchor user message appears exactly once");

# The final turn's user input should be present exactly once.
my $current_count = 0;
for my $m (@$messages) {
    if ($m->{role} eq 'user' && ($m->{content} // '') eq 'continue the work') {
        $current_count++;
    }
}
is($current_count, 1, "Current turn's user_input appears exactly once");

# The previous turn's user_input IS in session history and therefore
# appears in the resumed messages array via the projection's recent
# turns. What we want to verify is that it appears EXACTLY ONCE, not
# twice (once from cached payload + once from projection rebuild).
my $prev_count = 0;
for my $m (@$messages) {
    if ($m->{role} eq 'user' && ($m->{content} // '') =~ /final ask/) {
        $prev_count++;
    }
}
is($prev_count, 1, "Previous turn's user_input appears exactly once (not duplicated from cache + projection)");

done_testing();