#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for the three follow-ups to the prose renderer:
#   1. LTM body sanitization (framework-narration stripping)
#   2. YaRN anchor-recovery fallback
#   3. Cross-turn tool-call deduplication

use strict;
use warnings;
use utf8;

use Test::More;
use CLIO::Memory::LongTerm ();
use CLIO::Memory::YaRN ();
use CLIO::Core::ContextBuilder ();
use CLIO::Core::MessageHistory qw(messages_to_prose);

# ===========================================================================
# 1. LTM body sanitization
# ===========================================================================

subtest 'LTM sanitizer: framework-narration drops' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();

    my @drop_cases = (
        'After context trimming, use these patterns plus memory_operations(recall_sessions) to recover context instead of reading handoff documents.',
        '_Showing 12 of 55 memories (highest-scored). Additional memories available:_',
        '_- 20 more solutions_',
        '_- 15 more discoveries_',
        'Framework narration: the model treats this as a directive.',
    );

    for my $case (@drop_cases) {
        my $out = $ltm->sanitize_narration($case);
        ok($out !~ /After context trimming/, "'After context trimming' dropped from: $case");
        ok($out !~ /memory_operations/, "'memory_operations' dropped from: $case");
        ok($out !~ /_Showing \d+ of \d+/, "'Showing X of Y' dropped from: $case");
        ok($out !~ /_-\s*\d+\s*more/, "'_- N more' dropped from: $case");
    }
};

subtest 'LTM sanitizer: framework-internal terms rewritten' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();

    my %rewrite_cases = (
        'Use memory_operations to retrieve specific memories.'
            => 'long-term memory',
        'prompt caching strategy' => 'caching',
        'validate_and_truncate was called' => 'context validation',
        'inject_context_files ran' => 'context file loading',
        'thread_summary shows decisions' => 'thread summary',
        'messageHistory XML serialization' => 'message history',
    );

    for my $input (sort keys %rewrite_cases) {
        my $expected_substr = $rewrite_cases{$input};
        my $out = $ltm->sanitize_narration($input);
        like($out, qr/\Q$expected_substr\E/,
            "rewrote '$input' to contain '$expected_substr' (got: $out)");
    }
};

subtest 'LTM sanitizer: plain text unchanged' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    my @plain = (
        'CLIO uses Perl 5.32+ with strict and warnings enabled.',
        'The chat loop handles user input and tool results.',
        'The projection renders role-based history alongside a system message.',
    );
    for my $text (@plain) {
        my $out = $ltm->sanitize_narration($text);
        is($out, $text, "plain text unchanged: $text");
    }
};

subtest 'LTM sanitizer: write paths go through sanitizer' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery(
        'Use memory_operations(search) to retrieve keyword matches from LTM',
        0.8,
    );
    my $stored = $ltm->{patterns}{discoveries}[-1]{fact};
    unlike($stored, qr/memory_operations/,
        'add_discovery sanitized the stored text');
    like($stored, qr/long-term memory/, 'sanitized form persisted');
};

subtest 'LTM sanitizer: score_ltm applies sanitizer on read' => sub {
    my @dirty_ltm = (
        # Use type=discovery so the full sanitizer runs (rewriting
        # memory_operations -> 'long-term memory'). For type=pattern
        # (code patterns) the sanitizer skips tool-name replacement
        # because the model needs the tool names to recall "use
        # this specific tool". See test_ltm_sanitizer_code_patterns.pl
        # for that behavior.
        { confidence => 0.9, type => 'discovery', content => 'memory_operations prompt caching pattern' },
        { confidence => 0.8, type => 'discovery', content => 'plain text about cache misses' },
    );
    my $scored = CLIO::Core::ContextBuilder::score_ltm(
        \@dirty_ltm,
        'cache',
        'cache',
        [],
    );
    for my $entry (@$scored) {
        unlike($entry->{content}, qr/memory_operations/,
            'score_ltm output has no framework narration');
    }
    my $has_plain = grep { $_->{content} =~ /plain text/ } @$scored;
    ok($has_plain, 'plain text memory still surfaces through scorer');
};

# ===========================================================================
# 2. YaRN anchor-recovery fallback
# ===========================================================================

package MockSessionForAnchor {
    sub new { my ($class, %args) = @_; bless { %args }, $class }
    sub id  { $_[0]->{id} }
    sub yarn { $_[0]->{yarn} }
}

package MockYaRNForAnchor {
    sub new { my ($class, %args) = @_; bless { %args }, $class }
    sub get_thread {
        my ($self, $tid) = @_;
        return $self->{threads}{$tid} // [];
    }
}

subtest 'YaRN::recover_substantive_task: returns oldest substantive user message' => sub {
    my $yarn = MockYaRNForAnchor->new(
        threads => {
            'sess-1' => [
                { role => 'user', content => 'too short' },
                { role => 'assistant', content => 'ack' },
                { role => 'user', content => 'This is a substantive user message that is at least fifty characters long for the test.' },
                { role => 'assistant', content => 'ok' },
            ],
        },
    );
    my $sess = MockSessionForAnchor->new(id => 'sess-1', yarn => $yarn);
    my $recovered = CLIO::Memory::YaRN::recover_substantive_task($sess);
    like($recovered, qr/substantive user message/, 'recovered the substantive user message');
    unlike($recovered, qr/too short/, 'did not return the short message');
};

subtest 'YaRN::recover_substantive_task: handles empty thread' => sub {
    my $yarn = MockYaRNForAnchor->new(threads => {});
    my $sess = MockSessionForAnchor->new(id => 'sess-x', yarn => $yarn);
    my $recovered = CLIO::Memory::YaRN::recover_substantive_task($sess);
    is($recovered, '', 'returns empty string for empty thread');
};

subtest 'YaRN::recover_substantive_task: handles missing session' => sub {
    my $recovered = CLIO::Memory::YaRN::recover_substantive_task(undef);
    is($recovered, '', 'returns empty string for undef session');
};

subtest 'ContextBuilder: anchor recovery when history is empty' => sub {
    my $yarn = MockYaRNForAnchor->new(
        threads => {
            'sess-rec' => [
                { role => 'user', content => 'Build a new feature X that does Y and Z for the customer use case' },
                { role => 'assistant', content => 'ok, starting' },
            ],
        },
    );
    my $sess = MockSessionForAnchor->new(id => 'sess-rec', yarn => $yarn);

    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history       => [],
        user_input    => 'how is it going?',
        active_task   => '',
        active_todos  => [],
        ltm           => [],
        unresolved    => [],
        budget_tokens => 8000,
        session       => $sess,
    );

    ok(defined $proj->{anchor}, 'anchor was recovered from YaRN thread');
    is(ref($proj->{anchor}), 'ARRAY', 'anchor is an arrayref');
    is(scalar(@{ $proj->{anchor} }), 1, 'synthetic anchor has one message');
    like($proj->{anchor}[0]{content}, qr/Build a new feature/,
        'synthetic anchor contains the recovered task text');
};

subtest 'ContextBuilder: no session means no anchor recovery' => sub {
    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history       => [],
        user_input    => 'how is it going?',
        active_task   => '',
        active_todos  => [],
        ltm           => [],
        unresolved    => [],
        budget_tokens => 8000,
    );
    is($proj->{anchor}, undef, 'no anchor when session is absent');
};

# ===========================================================================
# 3. Cross-turn tool-call deduplication
# ===========================================================================

subtest 'cross-turn dedup: identical tool + continuation prompt' => sub {
    my @fragment = (
        { role => 'user', content => 'First task is to verify the codebase is clean and tidy before any further work.' },
        { role => 'assistant', content => 'Reading the dir', tool_calls => [{
            id => 'tc1', type => 'function',
            function => { name => 'terminal_operations', arguments => '{"operation":"exec","command":"ls lib/"}' }
        }]},
        { role => 'tool', tool_call_id => 'tc1', content => "APIManager.pm\nMessageHistory.pm" },

        { role => 'user', content => 'continue' },
        { role => 'assistant', content => 'Reading again', tool_calls => [{
            id => 'tc2', type => 'function',
            function => { name => 'terminal_operations', arguments => '{"operation":"exec","command":"ls lib/"}' }
        }]},
        { role => 'tool', tool_call_id => 'tc2', content => "APIManager.pm\nMessageHistory.pm" },
    );

    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history       => \@fragment,
        user_input    => 'and now?',
        active_task   => 'verify the codebase',
        active_todos  => [],
        ltm           => [],
        unresolved    => [],
        budget_tokens => 8000,
    );

    # Cross-turn dedup collapses the second (continuation-prompt) turn
    # into the first (anchor) turn. Both are identical-tool-call turns.
    # The dedup's chain is [anchor_turn, recent_turn]; after dedup it's
    # [anchor_turn] with the anchor's tool message marked _repeats=2.
    # Then build_projection splits chain[1..] as recent turns, which
    # is now empty. So $proj->{turns} is empty; the dedup marker lives
    # on the anchor's tool message instead.
    is(scalar(@{$proj->{turns}}), 0,
        'cross-turn dedup collapses identical tool calls into the anchor (recent becomes empty)');

    # The anchor's tool message should have _repeats=2.
    my $anchor = $proj->{anchor};
    my $tool_msg;
    for my $m (@$anchor) {
        $tool_msg = $m if ($m->{role} // '') eq 'tool';
    }
    ok($tool_msg, 'anchor has a tool message');
    is($tool_msg->{_repeats} // 1, 2,
        'anchor tool message has _repeats=2 marking the dedup');
};

subtest 'cross-turn dedup: non-continuation user message preserves both' => sub {
    my @fragment = (
        { role => 'user', content => 'First task is to verify the codebase is clean and tidy before any further work.' },
        { role => 'assistant', content => 'Reading the dir', tool_calls => [{
            id => 'tc1', type => 'function',
            function => { name => 'terminal_operations', arguments => '{"operation":"exec","command":"ls lib/"}' }
        }]},
        { role => 'tool', tool_call_id => 'tc1', content => "APIManager.pm\nMessageHistory.pm" },

        { role => 'user', content => 'What other files are in there?' },
        { role => 'assistant', content => 'Reading again', tool_calls => [{
            id => 'tc2', type => 'function',
            function => { name => 'terminal_operations', arguments => '{"operation":"exec","command":"ls lib/"}' }
        }]},
        { role => 'tool', tool_call_id => 'tc2', content => "APIManager.pm\nMessageHistory.pm" },
    );

    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history       => \@fragment,
        user_input    => 'and now?',
        active_task   => 'verify the codebase',
        active_todos  => [],
        ltm           => [],
        unresolved    => [],
        budget_tokens => 8000,
    );

    # "What other files are in there?" is a real question (contains
    # "what"), so the second turn's user message is NOT a continuation
    # prompt. The dedup should NOT collapse the second turn into the
    # anchor. With RECENT_FULL_TURNS=1 the recent array has at most
    # 1 turn, so we expect 1 (the latest, non-anchor turn) - the test
    # verifies the dedup didn't EMPTY the recent array by collapsing.
    is(scalar(@{$proj->{turns}}), 1,
        'non-continuation user message preserves recent turn (no false dedup)');
};

subtest 'cross-turn dedup: different result keeps both' => sub {
    my @fragment = (
        { role => 'user', content => 'First task is to verify the codebase is clean and tidy before any further work.' },
        { role => 'assistant', content => 'Reading the dir', tool_calls => [{
            id => 'tc1', type => 'function',
            function => { name => 'terminal_operations', arguments => '{"operation":"exec","command":"ls lib/"}' }
        }]},
        { role => 'tool', tool_call_id => 'tc1', content => "APIManager.pm\nMessageHistory.pm" },

        { role => 'user', content => 'ok' },
        { role => 'assistant', content => 'Reading again', tool_calls => [{
            id => 'tc2', type => 'function',
            function => { name => 'terminal_operations', arguments => '{"operation":"exec","command":"ls lib/"}' }
        }]},
        { role => 'tool', tool_call_id => 'tc2', content => "APIManager.pm\nMessageHistory.pm\nContextBuilder.pm" },
    );

    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history       => \@fragment,
        user_input    => 'and now?',
        active_task   => 'verify the codebase',
        active_todos  => [],
        ltm           => [],
        unresolved    => [],
        budget_tokens => 8000,
    );

    # Different result content means the dedup signature differs and
    # the recent turn survives. With RECENT_FULL_TURNS=1 we expect
    # 1 turn in recent (the latest non-anchor turn).
    is(scalar(@{$proj->{turns}}), 1,
        'different result keeps recent turn (no false dedup)');
};

subtest 'cross-turn dedup: different tool name keeps both' => sub {
    my @fragment = (
        { role => 'user', content => 'First task is to verify the codebase is clean and tidy before any further work.' },
        { role => 'assistant', content => 'Reading the dir', tool_calls => [{
            id => 'tc1', type => 'function',
            function => { name => 'terminal_operations', arguments => '{"operation":"exec","command":"ls lib/"}' }
        }]},
        { role => 'tool', tool_call_id => 'tc1', content => "APIManager.pm\nMessageHistory.pm" },

        { role => 'user', content => 'ok' },
        { role => 'assistant', content => 'Reading a file', tool_calls => [{
            id => 'tc2', type => 'function',
            function => { name => 'file_operations', arguments => '{"operation":"read_file","path":"x.pm"}' }
        }]},
        { role => 'tool', tool_call_id => 'tc2', content => "package X" },
    );

    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history       => \@fragment,
        user_input    => 'and now?',
        active_task   => 'verify the codebase',
        active_todos  => [],
        ltm           => [],
        unresolved    => [],
        budget_tokens => 8000,
    );

    # Different tool name = different signature = no dedup. The recent
    # turn survives.
    is(scalar(@{$proj->{turns}}), 1,
        'different tool name keeps recent turn');
};

subtest 'cross-turn dedup: 3 identical continuation prompts collapse to 1' => sub {
    my @fragment = (
        { role => 'user', content => 'First task is to verify the codebase is clean and tidy before any further work.' },
        { role => 'assistant', content => 'Reading', tool_calls => [{
            id => 'tc1', type => 'function',
            function => { name => 'read_file', arguments => '{}' }
        }]},
        { role => 'tool', tool_call_id => 'tc1', content => 'result' },

        { role => 'user', content => 'continue' },
        { role => 'assistant', content => 'Reading', tool_calls => [{
            id => 'tc2', type => 'function',
            function => { name => 'read_file', arguments => '{}' }
        }]},
        { role => 'tool', tool_call_id => 'tc2', content => 'result' },

        { role => 'user', content => 'continue' },
        { role => 'assistant', content => 'Reading', tool_calls => [{
            id => 'tc3', type => 'function',
            function => { name => 'read_file', arguments => '{}' }
        }]},
        { role => 'tool', tool_call_id => 'tc3', content => 'result' },
    );

    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history       => \@fragment,
        user_input    => 'next',
        active_task   => 'verify codebase',
        active_todos  => [],
        ltm           => [],
        unresolved    => [],
        budget_tokens => 8000,
    );

    # 3 continuation retries collapse into the anchor (which is the
    # only turn). The anchor's tool message gets _repeats=3.
    is(scalar(@{$proj->{turns}}), 0,
        '3 continuation retries collapsed into anchor (recent becomes empty)');

    my $anchor = $proj->{anchor};
    my $tool_msg;
    for my $m (@$anchor) {
        $tool_msg = $m if ($m->{role} // '') eq 'tool';
    }
    ok($tool_msg, 'anchor has a tool message');
    is($tool_msg->{_repeats} // 1, 3,
        'anchor tool message has _repeats=3 (three retries collapsed)');
};

# ===========================================================================
# 4. tool_error / nudge prefix removal
# ===========================================================================

subtest 'unresolved state: no tool_error prefix' => sub {
    my @history = (
        { role => 'user', content => 'do the thing' },
        { role => 'assistant', content => 'doing it', tool_calls => [{
            id => 'tc1', type => 'function',
            function => { name => 'read_file', arguments => '{}' }
        }]},
        { role => 'tool', tool_call_id => 'tc1', content => "ERROR: file not found at /tmp/x" },
    );
    require CLIO::Core::ContextBuilder;
    # Build_projection takes unresolved as a parameter; the caller
    # (WorkflowOrchestrator) populates it via _collect_unresolved_state.
    # For the test we pre-collect using the same logic so the projection
    # actually carries the unresolved state.
    require CLIO::Core::WorkflowOrchestrator;
    my $wf = bless {}, 'CLIO::Core::WorkflowOrchestrator';
    my $unresolved = $wf->_collect_unresolved_state(\@history);
    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history => \@history, user_input => 'next', active_task => '',
        active_todos => [], ltm => [], unresolved => $unresolved,
        budget_tokens => 8000,
    );
    my $prose = messages_to_prose($proj);
    unlike($prose, qr/tool_error:/, 'prose has no tool_error: prefix');
    unlike($prose, qr/nudge:/, 'prose has no nudge: prefix');
    like($prose, qr/ERROR: file not found/, 'prose has the error text directly');
};

subtest 'unresolved state: [SYSTEM: ...] user nudges are not surfaced' => sub {
    my @history = (
        # Anchor: a real user task (not a [SYSTEM: nudge).
        { role => 'user', content => 'do the thing please' },
        { role => 'assistant', content => 'doing it' },
        # A later user message with a [SYSTEM: nudge should not be
        # surfaced as unresolved state.
        { role => 'user', content => '[SYSTEM: nudge message]' },
    );
    require CLIO::Core::ContextBuilder;
    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history => \@history, user_input => 'next', active_task => '',
        active_todos => [], ltm => [], unresolved => [],
        budget_tokens => 8000,
    );
    my $prose = messages_to_prose($proj);
    # The unresolved-state section should not contain nudge material
    # (or any framework narration), but the anchor IS allowed to
    # contain it if that's what the user originally said.
    unlike($prose, qr/nudge:/, 'prose does not surface nudges via nudge: prefix');
    # The '# Unresolved state' header is only emitted when there are
    # actual unresolved items. With no real errors, it should be absent.
    unlike($prose, qr/# Unresolved state/, 'no # Unresolved state section when no real errors');
};

# ===========================================================================
# 5. Category-recognition boost in score_ltm
# ===========================================================================

subtest 'category boost: meta-relevant memory surfaces during framework work' => sub {
    my @ltm = (
        # Use type=discovery so the full sanitizer runs (which rewrites
        # memory_operations -> 'long-term memory' as the test expects).
        # type=pattern would skip the tool replacement (see
        # test_ltm_sanitizer_code_patterns.pl for that behavior).
        { confidence => 0.92, type => 'discovery',
          content => 'Model-facing prompt paths must NOT tell the model about framework internals (memory_operations, prompt caching, validate_and_truncate, framework narration). The thread_summary content is a work product that speaks for itself.' },
    );
    my $scored = CLIO::Core::ContextBuilder::score_ltm(
        \@ltm,
        'how does the prose look on this fragment?',
        'rewrite optimize.md and implement prose rendering for ContextBuilder',
        [],
    );
    ok(scalar(@$scored) >= 1, 'meta-relevant memory surfaces when working on framework');
    my $first = $scored->[0];
    ok($first->{_is_meta}, 'surfaces as a meta-categorized memory');
    unlike($first->{content}, qr/memory_operations/, 'content is sanitized');
};

subtest 'category boost: meta memory does NOT surface during non-framework work' => sub {
    my @ltm = (
        { confidence => 0.92, type => 'discovery',
          content => 'Model-facing prompt paths must NOT tell the model about framework internals (memory_operations, prompt caching, framework narration).' },
    );
    my $scored = CLIO::Core::ContextBuilder::score_ltm(
        \@ltm,
        'what is the weather today?',
        'deploy the application to production',
        [],
    );
    is(scalar(@$scored), 0, 'meta memory does not surface during non-framework work');
};

subtest 'category boost: domain memory surfaces with normal scoring' => sub {
    my @ltm = (
        { confidence => 0.9, type => 'pattern',
          content => 'ContextBuilder.pm already exists with build_projection, score_ltm, and collapse_repeated_tool_calls. The projection logic is in lib/CLIO/Core/ContextBuilder.pm.' },
    );
    my $scored = CLIO::Core::ContextBuilder::score_ltm(
        \@ltm,
        'implement the prose rendering for ContextBuilder',
        'rewrite optimize.md and implement prose rendering for ContextBuilder',
        [],
    );
    ok(scalar(@$scored) >= 1, 'domain memory surfaces with normal scoring');
    my $first = $scored->[0];
    ok($first->{score} >= 5, 'domain memory passes normal threshold');
};

# ===========================================================================
# 6. Active todos: no (id=N) suffix
# ===========================================================================

subtest 'active todos: no internal id exposed' => sub {
    my @fragment = (
        { role => 'user', content => 'Test' },
        { role => 'assistant', content => 'ok' },
    );
    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history => \@fragment, user_input => 'next',
        active_task => '',
        active_todos => [
            { id => 42, status => 'in_progress', content => 'verify output' },
            { id => 43, status => 'pending', content => 'commit' },
        ],
        ltm => [], unresolved => [],
        budget_tokens => 8000,
    );
    my $prose = messages_to_prose($proj);
    unlike($prose, qr/\(id=42\)/, 'prose has no (id=42)');
    unlike($prose, qr/\(id=43\)/, 'prose has no (id=43)');
    like($prose, qr/- \[in_progress\] verify output/, 'todo content rendered with status only');
    like($prose, qr/- \[pending\] commit/, 'pending todo rendered');
};
done_testing();
