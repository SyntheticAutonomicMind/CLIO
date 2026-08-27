#!/usr/bin/env perl
# Regression test: Pipeline Protocol Layout Normalisation
#
# Reproduces and verifies the fix for the mid-session agent restart bug
# observed in session f091a4e1 (2026-08-27, CachyLLama/llama.cpp).
#
# Root cause: the snapshot (last_api_payload) captured at end-of-turn
# had a BROKEN message layout:
#   1. thread_summary at position [104] (MIDDLE of conversation, with
#      16 messages after it) — a <system> block interrupting the flow
#   2. user_context at position [1] (leading, right after system_prompt) —
#      changes every minute (timestamp), shifting all downstream tokens
#      and permanently collapsing the LCP cache
#   3. user_input at position [5] (buried in the middle)
#
# These persisted across turns via the resume fast path, causing the model
# to gradually degrade: empty content, memory_operations TOOL ERROR loops,
# and eventual "restart" (re-issuing the session start protocol).
#
# The fix has two parts:
#   Fix 1: MessageValidator output assembly places the summary BETWEEN
#     old dialog and user_context/user_input, not after everything.
#   Fix 2: _capture_api_payload normalises the snapshot via
#     _normalize_payload_layout() which repositions thread_summary and
#     user_context to their canonical pipeline-protocol slots.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More;
use CLIO::Session::State;
use File::Temp qw(tempdir);

# Redirect sessions dir to a temp dir.
my $tmpdir = tempdir(CLEANUP => 1);
require CLIO::Util::PathResolver;
no warnings 'redefine';
*CLIO::Util::PathResolver::get_sessions_dir = sub { return "$tmpdir/sessions" };
*CLIO::Util::PathResolver::get_session_file = sub {
    my ($id) = @_;
    return "$tmpdir/sessions/$id.json";
};
use warnings;
mkdir "$tmpdir/sessions" or die "Cannot mkdir sessions: $!";

# Minimal stub session
package StubSession {
    sub new { my ($class, %args) = @_; return bless { state => $args{state} }, $class; }
    sub state { $_[0]->{state} }
}

# Minimal api_manager stub
package StubAPIManager {
    sub new { my ($class, %args) = @_; return bless { provider => $args{provider}, caps => $args{caps} }, $class; }
    sub get_current_provider    { $_[0]->{provider} }
    sub get_current_model       { 'llama.cpp/test' }
    sub get_model_capabilities  { $_[0]->{caps} }
}

package main;
require CLIO::Core::WorkflowOrchestrator;

# Build a real orchestrator with real tools (for signature matching in
# resume fast path tests).
my $orchestrator = CLIO::Core::WorkflowOrchestrator->new(
    debug => 0,
    api_manager => StubAPIManager->new(provider => 'llama.cpp', caps => { max_context_window_tokens => 131072 }),
);
my $real_tools = $orchestrator->_build_tools_for_api(undef);

# === Test helpers ===
sub find_tag_at_idx {
    my ($msgs, $tag_regex) = @_;
    for my $i (0 .. $#$msgs) {
        my $m = $msgs->[$i];
        next unless ref($m) eq 'HASH' && ($m->{role} // '') eq 'system';
        my $c = $m->{content} // '';
        return $i if $c =~ $tag_regex;
    }
    return -1;
}

sub find_last_role {
    my ($msgs, $role) = @_;
    for my $i (reverse 0 .. $#$msgs) {
        return $i if ($msgs->[$i]{role} // '') eq $role;
    }
    return -1;
}

# ============================================================================
# Test 1: Reproduces the f091a4e1 broken layout
# ============================================================================
subtest 'f091a4e1 broken layout normalised to canonical protocol layout' => sub {
    # Mirrors the EXACT broken structure from the real session payload:
    # [sys][userContext (leading)][dialog][thread_summary (middle)][dialog]
    my @broken = (
        { role => 'system', content => 'SYSTEM_PROMPT_CONTENT' },
        { role => 'system', content => "<userContext>\nDate: 2026-08-27 10:19\n</userContext>" },
        # dialog (old stuff before current turn)
        { role => 'user', content => 'Original task' },
        { role => 'assistant', content => 'a1' },
        { role => 'tool', content => 'r1', tool_call_id => 'tc1' },
        # current turn input + response
        { role => 'user', content => 'Current turn input' },
        { role => 'assistant', content => 'a2', tool_calls => [
            { id => 'tc2', type => 'function', function => { name => 'version_control', arguments => '{}' } },
        ] },
        { role => 'tool', content => 'r2', tool_call_id => 'tc2' },
        # BROKEN: thread_summary in the MIDDLE (after user_input, before more dialog)
        { role => 'system', content => "<thread_summary>\nCurrent task: Original task\n</thread_summary>" },
        # more conversation AFTER the summary (the degradation)
        { role => 'assistant', content => '' },
        { role => 'tool', content => '[]', tool_call_id => 'tc3' },
    );

    my @normalized = $orchestrator->_normalize_payload_layout(@broken);
    my $n = scalar @normalized;
    ok($n > 0, "Normalised payload has messages");

    # Position 0: system_prompt
    is($normalized[0]{role}, 'system', 'Position 0 is system_prompt');
    unlike($normalized[0]{content} // '', qr/<userContext>/, 'Position 0 is NOT user_context');

    # user_context must NOT be at position 1 (the bug)
    if ($n > 1) {
        unlike($normalized[1]{content} // '', qr/<userContext>/,
            'user_context is NOT at position [1] (was the LCP cache breaker)');
    }

    # thread_summary must be BEFORE user_context, not in the middle
    my $summary_idx = find_tag_at_idx(\@normalized, qr/<thread_summary>/);
    my $uc_idx = find_tag_at_idx(\@normalized, qr/<userContext>/);
    ok($summary_idx >= 0, "thread_summary exists in normalised output");
    ok($uc_idx >= 0, "user_context exists in normalised output");
    if ($summary_idx >= 0 && $uc_idx >= 0) {
        ok($summary_idx < $uc_idx,
            "thread_summary ($summary_idx) is BEFORE user_context ($uc_idx) — not in the middle");
        my $between = $uc_idx - $summary_idx;
        is($between, 1, "thread_summary immediately precedes user_context (no dialog in between)");
    }

    # user_input should be AFTER user_context
    my $last_user_idx = find_last_role(\@normalized, 'user');
    if ($uc_idx >= 0 && $last_user_idx >= 0) {
        ok($last_user_idx > $uc_idx,
            "user_input ($last_user_idx) is AFTER user_context ($uc_idx)");
    }

    # Only ONE of each
    my $summary_count = grep { ref($_) eq 'HASH' && ($_->{role} // '') eq 'system' && ($_->{content} // '') =~ /<thread_summary>/ } @normalized;
    is($summary_count, 1, "Exactly one thread_summary after normalisation");
    my $uc_count = grep { ref($_) eq 'HASH' && ($_->{role} // '') eq 'system' && ($_->{content} // '') =~ /<userContext>/ } @normalized;
    is($uc_count, 1, "Exactly one user_context after normalisation");
};

# ============================================================================
# Test 2: Already-correct layout is preserved (no-op on good input)
# ============================================================================
subtest 'Already-correct layout is preserved (no-op on good input)' => sub {
    my @correct = (
        { role => 'system', content => 'SYSTEM PROMPT' },
        { role => 'user', content => 'q1' },
        { role => 'assistant', content => 'a1' },
        { role => 'system', content => '<thread_summary>summary</thread_summary>' },
        { role => 'system', content => '<userContext>date: 2026-08-28</userContext>' },
        { role => 'user', content => 'q2' },
        { role => 'assistant', content => 'final' },
    );

    my @normalized = $orchestrator->_normalize_payload_layout(@correct);
    is(scalar(@normalized), 7, "Same count preserved");

    my $summary_idx = find_tag_at_idx(\@normalized, qr/<thread_summary>/);
    my $uc_idx = find_tag_at_idx(\@normalized, qr/<userContext>/);
    my $last_user_idx = find_last_role(\@normalized, 'user');

    is($normalized[0]{content}, 'SYSTEM PROMPT', 'system_prompt at [0]');
    is($summary_idx, 3, 'summary at [3] (after dialog)');
    is($uc_idx, 4, 'user_context at [4] (after summary)');
    is($last_user_idx, 5, 'user_input at [5] (after user_context)');
    is($normalized[6]{content}, 'final', 'assistant response at [6]');
};

# ============================================================================
# Test 3: _capture_api_payload normalises broken snapshot before saving
# ============================================================================
subtest '_capture_api_payload normalises broken snapshot before saving' => sub {
    my $real_state = CLIO::Session::State->new(session_id => 'layout-norm-int', debug => 0);
    my $sess = StubSession->new(state => $real_state);

    # Broken layout with old dialog before user_context:
    # [sys][old_dialog][userContext (leading→bug)][user_input][dialog][summary(middle)][dialog]
    my $broken = [
        { role => 'system', content => 'SYS' },
        { role => 'user', content => 'old_q1' },
        { role => 'assistant', content => 'old_a1' },
        { role => 'system', content => '<userContext>date: 2026-08-27</userContext>' },
        { role => 'user', content => 'q1' },
        { role => 'assistant', content => 'a1', tool_calls => [
            { id => 'tc2', type => 'function', function => { name => 'file_operations', arguments => '{}' } },
        ] },
        { role => 'system', content => '<thread_summary>summary</thread_summary>' },
        { role => 'assistant', content => 'a2' },
        { role => 'tool', content => 'r2', tool_call_id => 'tc2' },
    ];

    $orchestrator->_capture_api_payload($sess, $broken, $real_tools);
    my $stored = $real_state->last_api_payload;
    ok($stored && @$stored, 'payload was stored');

    # user_context must NOT be at position 1
    if (scalar(@$stored) > 1) {
        unlike($stored->[1]{content} // '', qr/<userContext>/,
            'user_context NOT at [1] in stored snapshot (was the LCP cache breaker)');
    }

    # Summary must be BEFORE user_context
    my $summary_idx = find_tag_at_idx($stored, qr/<thread_summary>/);
    my $uc_idx = find_tag_at_idx($stored, qr/<userContext>/);
    ok($summary_idx >= 0 && $uc_idx >= 0, 'Both summary and user_context exist');
    if ($summary_idx >= 0 && $uc_idx >= 0) {
        ok($summary_idx < $uc_idx,
            "Summary ($summary_idx) precedes user_context ($uc_idx) in stored snapshot");
        is($uc_idx - $summary_idx, 1, 'thread_summary immediately precedes user_context');
    }

    # No system messages after user_context (no interrupting summary)
    if ($uc_idx >= 0) {
        for my $i ($uc_idx + 1 .. $#$stored) {
            my $m = $stored->[$i];
            if (ref($m) eq 'HASH' && ($m->{role} // '') eq 'system') {
                my $c = $m->{content} // '';
                ok($c !~ /<thread_summary>/, "No thread_summary after user_context at $i in snapshot");
            }
        }
    }

    # Canonical layout verification
    is($stored->[0]{content}, 'SYS', 'system_prompt at [0]');
    is($stored->[1]{role}, 'user', 'old dialog starts at [1]');
    my $last_user_idx = find_last_role($stored, 'user');
    ok($last_user_idx > $uc_idx, 'user_input is after user_context');
};

# ============================================================================
# Test 4: Summary at END when no user_context present (first-turn)
# ============================================================================
subtest 'Summary at END when no user_context (first-turn scenario)' => sub {
    my @no_uc = (
        { role => 'system', content => 'SYS' },
        { role => 'user', content => 'q1' },
        { role => 'assistant', content => 'a1' },
        { role => 'system', content => '<thread_summary>summary</thread_summary>' },
        { role => 'assistant', content => 'a2' },
    );

    my @normalized = $orchestrator->_normalize_payload_layout(@no_uc);
    my $summary_idx = find_tag_at_idx(\@normalized, qr/<thread_summary>/);
    ok($summary_idx >= 0, 'summary exists');
    if ($summary_idx >= 0) {
        is($summary_idx, $#normalized,
            'summary is at the very END (no user_context to split on)');
    }
};

# ============================================================================
# Test 5: Duplicate user_context reduced to one (last retained)
# ============================================================================
subtest 'Duplicate user_context messages reduced to one (last)' => sub {
    my @dups = (
        { role => 'system', content => 'SYS' },
        { role => 'system', content => '<userContext>OLD</userContext>' },
        { role => 'user', content => 'q1' },
        { role => 'assistant', content => 'a1' },
        { role => 'system', content => '<userContext>NEW</userContext>' },
        { role => 'user', content => 'q2' },
    );

    my @normalized = $orchestrator->_normalize_payload_layout(@dups);

    my $uc_count = 0;
    my $uc_content = '';
    for my $m (@normalized) {
        if (ref($m) eq 'HASH' && ($m->{role} // '') eq 'system' && ($m->{content} // '') =~ /<userContext>/) {
            $uc_count++;
            $uc_content = $m->{content};
        }
    }
    is($uc_count, 1, 'Only one user_context after dedup');
    like($uc_content, qr/NEW/, 'Last user_context retained (NEW, not OLD)');
};

# ============================================================================
# Test 6: Resume roundtrip — broken snapshot normalised on capture, then
#          loaded cleanly by the resume fast path
# ============================================================================
subtest 'Resume roundtrip: broken snapshot normalised, then clean on resume' => sub {
    my $real_state = CLIO::Session::State->new(session_id => 'roundtrip-test', debug => 0);
    my $sess = StubSession->new(state => $real_state);

    # Capture a broken-layout payload with REAL tools (for signature match).
    # Use large enough messages to exceed MIN_CSSS_SLOT_TOKENS (8192 tokens)
    # so the resume fast path doesn't reject the payload as too small.
    my $pad = 'This is padding text to make the payload large enough. ' x 200;
    my $broken = [
        { role => 'system', content => 'SYS. ' . $pad },
        { role => 'system', content => '<userContext>date: 2026-08-27 10:19</userContext>' . $pad },
        { role => 'user', content => 'task: ' . $pad },
        { role => 'assistant', content => 'a1 thinking: ' . $pad, tool_calls => [
            { id => 'tc2', type => 'function', function => { name => 'file_operations', arguments => '{}' } },
        ] },
        { role => 'system', content => '<thread_summary>summary of old work</thread_summary>' },
        { role => 'assistant', content => 'a2: ' . $pad },
        { role => 'tool', content => 'r2: ' . $pad, tool_call_id => 'tc2' },
    ];

    $orchestrator->_capture_api_payload($sess, $broken, $real_tools);

    # Verify the stored snapshot is normalised
    my $stored = $real_state->last_api_payload;
    ok($stored && @$stored, 'payload stored');

    my $s_idx = find_tag_at_idx($stored, qr/<thread_summary>/);
    my $u_idx = find_tag_at_idx($stored, qr/<userContext>/);
    if ($s_idx >= 0 && $u_idx >= 0) {
        ok($s_idx < $u_idx,
            "Stored: summary ($s_idx) before user_context ($u_idx)");
    }

    # Resume from the normalised snapshot
    my ($resumed, $resumed_tools) = $orchestrator->_try_resume_from_payload(
        $sess,
        { max_context_window_tokens => 131072 }
    );
    ok($resumed && ref($resumed) eq 'ARRAY' && @$resumed, 'resume returned messages');
    return unless $resumed && ref($resumed) eq 'ARRAY' && @$resumed;

    # The resumed payload should NOT have user_context at [1]
    if (scalar(@$resumed) > 1) {
        unlike($resumed->[1]{content} // '', qr/<userContext>/,
            'Resumed: user_context NOT at [1]');
    }

    # Summary should be before user_context
    my $rs_idx = find_tag_at_idx($resumed, qr/<thread_summary>/);
    my $ru_idx = find_tag_at_idx($resumed, qr/<userContext>/);
    if ($rs_idx >= 0 && $ru_idx >= 0) {
        ok($rs_idx < $ru_idx,
            "Resumed: summary ($rs_idx) before user_context ($ru_idx)");
    }
};

done_testing();
