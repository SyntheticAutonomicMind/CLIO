#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for the tool success loop detector (ToolLoopDetector):
# - Loose signatures collapse argument variations (grep flags/patterns)
# - Result-similarity gate: only near-identical results escalate
# - Guidance note at the warning threshold, nudge ladder on escalation
#   (break -> loop-break instruction while budget remains, hard break after)
# - State-changing calls clear the window (edit-then-verify never loops)
# - Interleaved target switches still escalate (best match over window)
# - Repeated empty results are a loop signal

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::ToolLoopDetector;

my $GREP_RESULT_A = join("\n",
    'lib/CLIO/Core/PluginManager.pm:654:    my $script = $tool_def->{script} || $tool_def->{command};',
    'lib/CLIO/Security/CommandAnalyzer.pm:439:                description => "Environment dump command \'$cmd\' (may expose API keys and tokens)",',
    'lib/CLIO/Security/CommandAnalyzer.pm:456:                description => \'Potentially destructive system command detected\',',
    'lib/CLIO/Session/State.pm:793:    # output blocks), pre_action_description (command/preview shown before execution),',
    'lib/CLIO/Tools/RemoteExecution.pm:249:    my $command = $params->{task_description} || $params->{command};',
);

my $GREP_RESULT_B = join("\n",
    'lib/CLIO/Core/PluginManager.pm:654:    my $script = $tool_def->{script} || $tool_def->{command};',
    'lib/CLIO/Core/RepositoryLoader.pm:87:  name, description, prompt, type, source_repo, skill_path, readonly',
    'lib/CLIO/Security/CommandAnalyzer.pm:456:                description => \'Potentially destructive system command detected\',',
    'lib/CLIO/Session/Manager.pm:179:    reset_script_session_grants();',
);

subtest 'loose signature collapses grep argument variations' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    my $sig1 = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'grep -rn "script" lib/CLIO/ | grep -i "script.*command" | head -10' });
    my $sig2 = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'grep -rn "script" lib/CLIO/ --include="*.pm" | head -10' });
    my $sig3 = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'grep "script" lib/CLIO/ | grep -v "script_session" | head -10' });

    is($sig1, $sig2, 'different flags and pipe tails collapse to one signature');
    is($sig1, $sig3, 'different patterns collapse to one signature');

    # Different target directory changes the signature
    my $sig4 = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'grep -rn "script" lib/CLIO/UI/ | head -10' });
    isnt($sig1, $sig4, 'different target path gets a different signature');

    # Different binary changes the signature
    my $sig5 = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'rg -n "script" lib/CLIO/ | head -10' });
    isnt($sig1, $sig5, 'different binary gets a different signature');

    # Quoted pipe inside a pattern must not fragment the signature
    my $sig6 = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'grep -i "script.*command\\|script.*util" lib/CLIO/ | head -5' });
    is($sig6, $sig1, 'quoted pipe inside pattern does not truncate the stage');
};

subtest 'guidance fires after threshold similar calls with similar results' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    my @commands = (
        'grep -rn "script" lib/CLIO/ | head -10',
        'grep -rn "script" lib/CLIO/ --include="*.pm" | head -10',
        'grep "script" lib/CLIO/ | grep -v "script_session" | head -10',
    );

    my $verdict;
    for my $i (0 .. $#commands) {
        # Results vary slightly: token overlap stays high.
        my $content = $GREP_RESULT_A;
        $content .= "\nlib/CLIO/Core/Extra$i.pm:1:    description => 'filler',";
        $verdict = $d->record_call('terminal_operations',
            { operation => 'exec', command => $commands[$i] }, $content);
    }

    ok(defined $verdict->{guidance}, 'guidance note returned at threshold');
    like($verdict->{guidance}, qr/LOOP WARNING/, 'guidance text has the LOOP WARNING header');
    like($verdict->{guidance}, qr/loop-break instruction/, 'guidance previews the escalation ladder');
    is($verdict->{break}, 0, 'no hard break at guidance threshold');
    is($verdict->{count}, 3, 'count reached the guidance threshold');
};

subtest 'hard break after guidance is ignored (budget exhausted)' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new(
        guidance_threshold => 3,
        break_threshold    => 4,
        nudge_budget       => 0,
    );

    my $verdict;
    for my $i (0 .. 3) {
        my $content = $GREP_RESULT_A . "\nlib/CLIO/Filler$i.pm:1:    description => 'x',";
        $verdict = $d->record_call('terminal_operations',
            { operation => 'exec', command => "grep -rn \"script\" lib/CLIO/ | head -10 #v$i" }, $content);
    }

    # Call 3 fires guidance; call 4 must break because guidance is active.
    is($verdict->{break}, 1, 'break after continued pattern post-guidance');
    is($verdict->{guidance}, undef, 'no guidance note on the break call');
    ok(!$verdict->{nudge}, 'nudge budget 0: break is not converted to a nudge');
};

subtest 'nudge ladder: break becomes instruction until budget exhausted' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new(
        guidance_threshold => 3,
        break_threshold    => 4,
        nudge_budget       => 2,
    );

    my $make_call = sub {
        my ($i) = @_;
        my $content = $GREP_RESULT_A . "\nlib/CLIO/Filler$i.pm:1:    description => 'x',";
        return $d->record_call('terminal_operations',
            { operation => 'exec', command => "grep -rn \"script\" lib/CLIO/ | head -10 #v$i" },
            $content);
    };

    # Calls 1-2 are below thresholds.
    my $v = $make_call->(0);
    is($v->{break}, 0, 'call 1: no escalation');
    $v = $make_call->(1);
    is($v->{break}, 0, 'call 2: no escalation');

    # Call 3: guidance note.
    $v = $make_call->(2);
    ok(defined $v->{guidance}, 'call 3: guidance note');
    is($v->{break}, 0, 'call 3: no break yet');

    # Call 4: first escalation -> nudge, not a silent break.
    $v = $make_call->(3);
    is($v->{break}, 1, 'call 4: escalation fires');
    is($v->{nudge}, 1, 'call 4: converted to nudge (budget 2)');
    ok(defined $v->{nudge_text}, 'call 4: nudge text present');
    like($v->{nudge_text}, qr/LOOP BREAK/, 'nudge text has the LOOP BREAK header');
    like($v->{nudge_text}, qr/terminal_operations/, 'nudge text names the looping tool');

    # Call 5: second escalation -> last nudge.
    $v = $make_call->(4);
    is($v->{nudge}, 1, 'call 5: second nudge (budget exhausted after this)');

    # Call 6: budget gone -> real break with no nudge.
    $v = $make_call->(5);
    is($v->{break}, 1, 'call 6: real break');
    ok(!$v->{nudge}, 'call 6: no nudge - budget exhausted');
    is($v->{nudge_text}, undef, 'call 6: no nudge text');
};

subtest 'nudge budget restores when the window resets' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new(
        guidance_threshold => 3,
        break_threshold    => 4,
        nudge_budget       => 2,
    );

    my $make_call = sub {
        my ($i) = @_;
        my $content = $GREP_RESULT_A . "\nlib/CLIO/Filler$i.pm:1:    description => 'x',";
        return $d->record_call('terminal_operations',
            { operation => 'exec', command => "grep -rn \"script\" lib/CLIO/ | head -10 #v$i" },
            $content);
    };

    # Burn one nudge from the run.
    $make_call->($_) for 0 .. 3;
    my $v = $make_call->(4);
    is($v->{nudge}, 1, 'first escalation is a nudge');
    $v = $make_call->(5);
    ok(!$v->{nudge}, 'second escalation is a real break');

    # A state-changing call resets the window AND the ladder: the next run
    # escalates to a nudge again instead of immediately breaking.
    $d->record_call('apply_patch', { patch => '*** Update File: lib/X.pm' }, 'patched');
    $make_call->($_) for 10 .. 13;
    $v = $make_call->(14);
    is($v->{nudge}, 1, 'fresh window restores nudge budget');

    # reset() (called at turn start / on interact) does the same.
    $d->reset();
    $make_call->($_) for 20 .. 23;
    $v = $make_call->(24);
    is($v->{nudge}, 1, 'reset() restores nudge budget');
};

subtest 'state-changing call clears the window (edit-then-verify)' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    # Two similar read-only calls, then a state-changing one, then more reads.
    $d->record_call('terminal_operations',
        { operation => 'exec', command => 'grep -rn "script" lib/CLIO/ | head -5' }, $GREP_RESULT_A);
    $d->record_call('terminal_operations',
        { operation => 'exec', command => 'grep "script" lib/CLIO/ --include="*.pm"' }, $GREP_RESULT_B);

    # apply_patch is state-changing: clears the window.
    my $verdict = $d->record_call('apply_patch',
        { patch => '*** Update File: lib/X.pm' }, 'patch applied');
    is($verdict->{tracked}, 0, 'state-changing call is not tracked');

    # Same grep again: window was cleared, so the run restarts.
    $verdict = $d->record_call('terminal_operations',
        { operation => 'exec', command => 'grep -rn "script" lib/CLIO/ | head -5' }, $GREP_RESULT_A);
    is($verdict->{count}, 1, 'window cleared: count restarts at 1');
    is($verdict->{break}, 0, 'no break after window reset');
};

subtest 'file write between test runs does not escalate' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    my $test_output = join("\n", map { "ok $_ - test_$_" } 1 .. 20);

    # edit, test, edit, test, edit, test. Both sides are state-changing:
    # the write clears the window, and running an arbitrary executable is
    # conservatively classified as state-changing too. No read-only run
    # ever accumulates across the rounds, so nothing escalates - that is
    # the point: the classic edit-test cycle must never false-positive.
    for my $round (1 .. 3) {
        my $w = $d->record_call('file_operations',
            { operation => 'write_file', path => 'lib/X.pm', content => 'x' }, 'written');
        is($w->{tracked}, 0, "write $round is state-changing");
        my $v = $d->record_call('terminal_operations',
            { operation => 'exec', command => "perl -I./lib tests/unit/test_x.pl" }, $test_output);
        is($v->{tracked}, 0, "test run $round is state-changing (not tracked)");
        is($v->{count}, 0, "test run $round resets the window");
        is($v->{break}, 0, "test run $round does not break");
    }
};

subtest 'differing results do not escalate (converging work)' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    my @results = (
        join("\n", map { "lib/File$_\.pm:1: unique_line_$_" } 1 .. 10),
        join("\n", map { "lib/Other$_\.pm:1: totally_different_$_" } 1 .. 10),
        join("\n", map { "lib/Third$_\.pm:1: another_set_$_" } 1 .. 10),
    );

    my $verdict;
    for my $i (0 .. $#results) {
        $verdict = $d->record_call('terminal_operations',
            { operation => 'exec', command => 'grep -rn "script" lib/CLIO/ | head -10' },
            $results[$i]);
    }

    is($verdict->{count}, 3, 'three calls counted');
    is($verdict->{guidance}, undef, 'no guidance: results are substantially different');
    is($verdict->{break}, 0, 'no break: results are substantially different');
};

subtest 'repeated empty results are a loop signal' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    my $verdict;
    for my $i (0 .. 2) {
        $verdict = $d->record_call('terminal_operations',
            { operation => 'exec', command => "grep -rn \"no_such_thing\" lib/CLIO/ | head -5 #var$i" }, '');
    }

    is($verdict->{count}, 3, 'empty-result calls counted');
    ok(defined $verdict->{guidance}, 'guidance fires for repeated empty results');
};

subtest 'interleaved target switches still escalate via window counting' => sub {
    # The observed failure mode: the model alternates targets but keeps
    # searching the same directory with the same binary. Window counting
    # catches this where a strict consecutive counter would not.
    my $d = CLIO::Core::ToolLoopDetector->new();

    my @calls = (
        ['grep -rn "script" lib/CLIO/ | head -10', $GREP_RESULT_A],
        ['grep "script" lib/CLIO/UI/Chat.pm | head -5', ''],
        ['grep -rn "script" lib/CLIO/ --include="*.pm" | head -10', $GREP_RESULT_B],
        ['grep "script" lib/CLIO/UI/SessionReplay.pm | head -5', ''],
        ['grep -rn "script" lib/CLIO/ | grep -v description | head -10', $GREP_RESULT_A],
    );

    my $verdict;
    for my $call (@calls) {
        $verdict = $d->record_call('terminal_operations',
            { operation => 'exec', command => $call->[0] }, $call->[1]);
    }

    # The lib/CLIO/ grep signature appeared 3 times in the window (calls
    # 1, 3, 5) with similar results, so guidance fires at call 5.
    ok(defined $verdict->{guidance}, 'guidance fires despite interleaved target switches');
    is($verdict->{count}, 3, 'same-signature calls counted across the window');
};

subtest 'two interleaved similar-result signatures complete the ladder' => sub {
    # The observed SAM session failure: the model alternated TWO different
    # grep queries over the same docs, both returning near-identical
    # results. Single-slot guidance bookkeeping was overwritten by the
    # alternating partner on every call, so guidance re-fired forever
    # (139 notes over ~270 calls) and the escalation ladder never fired.
    # With per-signature tracking the ladder completes: guidance X,
    # guidance Y, nudge X, nudge Y, hard break.
    my $d = CLIO::Core::ToolLoopDetector->new();

    my $x_query = 'Claude.*model|claude.*model|Anthropic.*model';
    my $y_query = 'Claude|claude|Anthropic';

    my $call = sub {
        my ($q, $content) = @_;
        return $d->record_call('file_operations',
            { operation => 'grep_search', query => $q, directory => 'docs' },
            $content);
    };

    # X1 Y1 X2 Y2: below every threshold.
    my $v = $call->($x_query, '');
    is($v->{count}, 1, 'X call 1 counted');
    $v = $call->($y_query, 'match line');
    is($v->{count}, 1, 'Y call 1 counted');
    $v = $call->($x_query, '');
    is($v->{count}, 2, 'X call 2 counted');
    $v = $call->($y_query, 'match line');
    is($v->{count}, 2, 'Y call 2 counted');
    ok(!$v->{break} && !defined $v->{guidance}, 'calls 1-2 stay quiet');

    # X3: guidance. Y3: guidance - a second, separate signature.
    $v = $call->($x_query, '');
    ok(defined $v->{guidance}, 'X call 3: guidance fires');
    $v = $call->($y_query, 'match line');
    ok(defined $v->{guidance}, 'Y call 3: guidance fires for the second signature');

    # X4: escalation, NOT another guidance note. This is the exact point
    # where the old single-slot code re-warned forever.
    $v = $call->($x_query, '');
    is($v->{break}, 1, 'X call 4: escalates despite interleaved partner');
    ok(!defined $v->{guidance}, 'X call 4: no re-warn');
    is($v->{nudge}, 1, 'X call 4: converted to nudge 1');

    $v = $call->($y_query, 'match line');
    is($v->{break}, 1, 'Y call 4: escalates');
    is($v->{nudge}, 1, 'Y call 4: nudge 2 (budget exhausted)');

    # X5: budget gone -> hard break. Ladder completes at 9 similar calls.
    $v = $call->($x_query, '');
    is($v->{break}, 1, 'X call 5: hard break');
    ok(!$v->{nudge}, 'X call 5: no nudge left');
};

subtest 'git read-only commands are tracked' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    my $status_output = "On branch main\nnothing to commit, working tree clean";
    my $verdict;
    for my $i (0 .. 2) {
        $verdict = $d->record_call('terminal_operations',
            { operation => 'exec', command => "git status --short #$i" }, $status_output);
    }

    is($verdict->{count}, 3, 'git status calls tracked as read-only');
    ok(defined $verdict->{guidance}, 'guidance fires for repeated identical git status');
};

subtest 'mutating commands clear the window' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    $d->record_call('terminal_operations',
        { operation => 'exec', command => 'grep -rn "script" lib/CLIO/ | head -5' }, $GREP_RESULT_A);
    $d->record_call('terminal_operations',
        { operation => 'exec', command => 'grep "script" lib/CLIO/ --include="*.pm"' }, $GREP_RESULT_B);

    # A build/test run is state-changing: clears the window.
    my $verdict = $d->record_call('terminal_operations',
        { operation => 'exec', command => 'perl -I./lib tests/unit/test_x.pl' }, 'ok 1');
    is($verdict->{tracked}, 0, 'perl test run treated as state-changing');

    # git commit is also state-changing.
    $d->record_call('terminal_operations',
        { operation => 'exec', command => 'grep -rn "script" lib/CLIO/ | head -5' }, $GREP_RESULT_A);
    $d->record_call('terminal_operations',
        { operation => 'exec', command => 'grep "script" lib/CLIO/' }, $GREP_RESULT_B);
    $verdict = $d->record_call('terminal_operations',
        { operation => 'exec', command => 'git commit -m "test"' }, 'committed');
    is($verdict->{tracked}, 0, 'git commit treated as state-changing');
};

subtest 'file_operations read-only ops tracked, writes clear' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    # read_file same path repeatedly with identical content -> loop.
    my $verdict;
    for my $i (0 .. 2) {
        $verdict = $d->record_call('file_operations',
            { operation => 'read_file', path => 'lib/CLIO/Core/X.pm' }, 'package X; 1;');
    }
    is($verdict->{count}, 3, 'read_file runs counted');
    ok(defined $verdict->{guidance}, 'guidance fires for repeated identical reads');

    # A write clears the window.
    $verdict = $d->record_call('file_operations',
        { operation => 'write_file', path => 'lib/CLIO/Core/X.pm', content => 'x' }, 'written');
    is($verdict->{tracked}, 0, 'write_file is state-changing');

    # grep_search (file_operations) is read-only and tracked.
    $verdict = $d->record_call('file_operations',
        { operation => 'grep_search', query => 'script', scope => 'lib' }, 'some results');
    is($verdict->{tracked}, 1, 'grep_search is read-only and tracked');
};

subtest 'different signature resets run' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    $d->record_call('terminal_operations',
        { operation => 'exec', command => 'grep -rn "script" lib/CLIO/ | head -5' }, $GREP_RESULT_A);
    $d->record_call('terminal_operations',
        { operation => 'exec', command => 'grep -rn "script" lib/CLIO/ | head -5' }, $GREP_RESULT_A);

    # Different binary: window keeps entries but the run for the new sig is 1.
    my $verdict = $d->record_call('terminal_operations',
        { operation => 'exec', command => 'rg -n "script" lib/CLIO/' }, $GREP_RESULT_A);
    is($verdict->{count}, 1, 'new signature starts at count 1');
};

subtest 'validate operation and empty command are handled' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    # validate operation is read-only but its calls are cheap and varied;
    # they should be tracked without breaking anything.
    my $verdict = $d->record_call('terminal_operations',
        { operation => 'validate', command => 'ls -la' }, 'ok');
    is($verdict->{tracked}, 1, 'validate is tracked as read-only');

    # Empty command: signature forms, no crash.
    $verdict = $d->record_call('terminal_operations',
        { operation => 'exec', command => '' }, '');
    is($verdict->{tracked}, 0, 'empty command treated as state-changing (not tracked)');
};

# The wire surface publishes one callable per operation (file_search,
# grep_search, list_usages), so the dispatcher hands the detector the
# emitted name - never the grouping name. Every case above drives
# terminal_operations (a real single callable) or the grouping form, so a
# regression that only breaks emitted callables would slip through. The
# field log that motivated this test showed the same file_search call
# issued 13 times without escalation.
subtest 'emitted callables are tracked like grouping names' => sub {
    my $field_result = '{"path":"lib/CLIO/Code/Scanner.pm","type":"file","size":7167}';

    my @cases = (
        [ 'file_search',    { pattern => '**/Scanner.pm', directory => 'lib/CLIO/Code' } ],
        [ 'grep_search',    { query => 'sub is_code_language', directory => 'lib/CLIO/Code' } ],
        [ 'list_usages',    { symbol_name => 'is_code_language' } ],
        [ 'read_file',      { path => 'lib/CLIO/Code/Scanner.pm' } ],
        [ 'file_exists',    { path => 'lib/CLIO/Code/Scanner.pm' } ],
    );

    for my $case (@cases) {
        my ($tool, $args) = @$case;
        my $d = CLIO::Core::ToolLoopDetector->new();

        my $first = $d->record_call($tool, $args, $field_result);
        is($first->{tracked}, 1, "$tool is tracked as read-only");
        is($first->{break}, 0, "$tool: no break on first call");

        my $broke_at;
        for my $i (2 .. 13) {
            my $v = $d->record_call($tool, $args, $field_result);
            $broke_at = $i if !$broke_at && $v->{break};
        }

        ok(defined $broke_at,
            "$tool: repeated identical call escalates (broke at iteration " .
            (defined $broke_at ? $broke_at : 'never') . ")");
        cmp_ok($broke_at // 99, '<=', 6,
            "$tool: escalation arrives early, not after a dozen attempts");
    }
};

# The read-only classification is resolved through the registry, so the
# emitted callable and the grouping form must classify identically and
# escalate at the same point. Signatures differ by design (they encode
# the dispatched name); classification is the shared contract.
subtest 'grouping and emitted forms agree' => sub {
    my $result = '{"path":"lib/CLIO/Code/Scanner.pm","type":"file","size":7167}';

    my @forms = (
        [ 'file_search',     { pattern => '**/Scanner.pm', directory => 'lib/CLIO/Code' } ],
        [ 'file_operations', { operation => 'file_search',
                               pattern => '**/Scanner.pm', directory => 'lib/CLIO/Code' } ],
    );

    my %broke_at;
    for my $form (@forms) {
        my ($tool, $args) = @$form;
        my $d = CLIO::Core::ToolLoopDetector->new();

        for my $i (1 .. 13) {
            my $v = $d->record_call($tool, $args, $result);
            is($v->{tracked}, 1, "$tool form: call $i tracked as read-only") if $i == 1;
            if ($v->{break} && !$broke_at{$tool}) {
                $broke_at{$tool} = $i;
            }
        }
    }

    is($broke_at{file_search}, $broke_at{file_operations},
        'both forms escalate at the same iteration');
};

done_testing();
