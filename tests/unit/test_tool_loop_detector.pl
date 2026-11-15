#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for the tool success loop detector (ToolLoopDetector):
# - Loose signatures collapse the search term, wrappers, and flags while
#   keeping the target, for terminal and native tool calls alike
# - Result-similarity gate: only near-identical results produce guidance
# - Guidance is advisory: a notice at the threshold, reminders on a
#   cadence, and nothing that authorizes ending the turn
# - Three-way classification: tracked, neutral (ignored), mutating (reset)

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

subtest 'terminal signatures collapse the search term and keep the target' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    my $sig1 = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'grep -rn "script" lib/CLIO/ | grep -i "script.*command" | head -10' });
    my $sig2 = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'grep -rn "script" lib/CLIO/ --include="*.pm" | head -10' });
    my $sig3 = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'grep "script" lib/CLIO/ | grep -v "script_session" | head -10' });

    is($sig1, $sig2, 'different flags and pipe tails collapse to one signature');
    is($sig1, $sig3, 'different patterns collapse to one signature');

    my $sig4 = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'grep -rn "script" lib/CLIO/UI/ | head -10' });
    isnt($sig1, $sig4, 'different target path gets a different signature');

    my $sig5 = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'rg -n "script" lib/CLIO/ | head -10' });
    isnt($sig1, $sig5, 'different binary gets a different signature');

    my $sig6 = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'grep -i "script.*command\\|script.*util" lib/CLIO/ | head -5' });
    is($sig6, $sig1, 'quoted pipe inside pattern does not truncate the stage');

    my $relative_lib = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'grep -rn script lib' });
    my $relative_tests = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'grep -rn script tests' });
    isnt($relative_lib, $relative_tests,
        'relative directory targets are kept and do not collide');

    my $git_log = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'git log --oneline' });
    my $git_status = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'git status --short' });
    isnt($git_log, $git_status, 'git subcommands keep distinct signatures');
};

subtest 'command wrappers and cd prefixes are stripped' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();
    my $base = $d->call_signature('terminal_operations',
        { operation => 'exec', command => 'grep -rn foo lib/CLIO' });

    is($d->call_signature('terminal_operations',
        { operation => 'exec', command => 'cd /repo && grep -rn bar lib/CLIO' }), $base,
        'cd prefix does not change the signature');
    is($d->call_signature('terminal_operations',
        { operation => 'exec', command => 'cd /repo; grep -rn bar lib/CLIO' }), $base,
        'cd prefix with semicolon does not change the signature');
    is($d->call_signature('terminal_operations',
        { operation => 'exec', command => 'sudo grep -rn bar lib/CLIO' }), $base,
        'sudo prefix does not change the signature');
    is($d->call_signature('terminal_operations',
        { operation => 'exec', command => 'sudo -u root grep -rn bar lib/CLIO' }), $base,
        'sudo flag values are not mistaken for the command');
    is($d->call_signature('terminal_operations',
        { operation => 'exec', command => 'FOO=1 grep -rn bar lib/CLIO' }), $base,
        'environment assignments do not change the signature');
    is($d->call_signature('terminal_operations',
        { operation => 'exec', command => 'timeout 30 grep -rn bar lib/CLIO' }), $base,
        'timeout duration is stripped with the wrapper');
};

subtest 'native search signatures collapse the query and keep the scope' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    my $grep_a = $d->call_signature('file_operations',
        { operation => 'grep_search', query => 'alpha', path => 'lib/CLIO' });
    my $grep_b = $d->call_signature('file_operations',
        { operation => 'grep_search', query => 'beta', path => 'lib/CLIO' });
    is($grep_a, $grep_b, 'grep_search with a different query keeps one signature');

    my $grep_other = $d->call_signature('file_operations',
        { operation => 'grep_search', query => 'alpha', path => 'tests' });
    isnt($grep_a, $grep_other, 'grep_search with a different path gets a new signature');

    my $find_a = $d->call_signature('file_operations',
        { operation => 'file_search', pattern => '*alpha*', directory => 'lib' });
    my $find_b = $d->call_signature('file_operations',
        { operation => 'file_search', pattern => '*beta*', directory => 'lib' });
    is($find_a, $find_b, 'file_search with a different pattern keeps one signature');

    my $sem_a = $d->call_signature('file_operations',
        { operation => 'semantic_search', query => 'alpha', scope => 'lib' });
    my $sem_b = $d->call_signature('file_operations',
        { operation => 'semantic_search', query => 'beta', scope => 'lib' });
    is($sem_a, $sem_b, 'semantic_search with a different query keeps one signature');

    my $web_a = $d->call_signature('web_operations',
        { operation => 'search_web', query => 'alpha' });
    my $web_b = $d->call_signature('web_operations',
        { operation => 'search_web', query => 'beta' });
    is($web_a, $web_b, 'search_web with a different query keeps one signature');

    my $fetch_a = $d->call_signature('web_operations',
        { operation => 'fetch_url', url => 'https://example.com/a' });
    my $fetch_b = $d->call_signature('web_operations',
        { operation => 'fetch_url', url => 'https://example.com/b' });
    isnt($fetch_a, $fetch_b, 'fetch_url keeps the URL in the signature');
};

subtest 'emitted and canonical callable names share one signature' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    my $emitted = $d->call_signature('grep_search',
        { query => 'alpha', path => 'lib' });
    my $canonical = $d->call_signature('file_operations',
        { operation => 'grep_search', query => 'alpha', path => 'lib' });
    is($emitted, $canonical, 'grep_search and file_operations/grep_search agree');

    my $v1 = $d->record_call('grep_search', { query => 'a', path => 'lib' }, $GREP_RESULT_A);
    my $v2 = $d->record_call('file_operations',
        { operation => 'grep_search', query => 'b', path => 'lib' }, $GREP_RESULT_A);
    my $v3 = $d->record_call('grep_search', { query => 'c', path => 'lib' }, $GREP_RESULT_A);

    is($v2->{sig}, $v1->{sig}, 'both call forms record the same signature');
    is($v3->{count}, 3, 'both call forms accumulate in one run');
    ok(defined $v3->{guidance}, 'guidance fires across mixed call forms');
};

subtest 'guidance fires at the threshold with measured overlap' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    my $verdict;
    for my $i (0 .. 2) {
        my $content = $GREP_RESULT_A . "\nlib/CLIO/Core/Extra$i.pm:1:    description => 'filler',";
        $verdict = $d->record_call('terminal_operations',
            { operation => 'exec', command => "grep -rn \"script$i\" lib/CLIO/" }, $content);
    }

    is($verdict->{level}, 1, 'level 1 notice at the threshold');
    ok(defined $verdict->{guidance}, 'guidance note returned');
    like($verdict->{guidance}, qr/LOOP NOTICE/, 'guidance has the LOOP NOTICE header');
    like($verdict->{guidance}, qr/% identical/, 'guidance reports the measured overlap');
    like($verdict->{guidance}, qr/does not end the turn/, 'guidance states it is advisory');
    is($verdict->{count}, 3, 'count reached the guidance threshold');
};

subtest 'reminders repeat on the configured cadence' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new(reminder_interval => 2);

    my @levels;
    for my $i (0 .. 7) {
        my $content = $GREP_RESULT_A . "\nlib/CLIO/Core/Filler$i.pm:1: x";
        my $v = $d->record_call('terminal_operations',
            { operation => 'exec', command => "grep -rn q$i lib/CLIO" }, $content);
        push @levels, $v->{level};
    }

    is_deeply(\@levels, [0, 0, 1, 0, 2, 0, 2, 0],
        'notice at 3, reminders at 5 and 7, quiet in between');
};

subtest 'new information never produces guidance' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    my $saw_guidance = 0;
    for my $i (0 .. 4) {
        # Every result is disjoint: each call returns new information.
        my $content = "uniqueword${i}a uniqueword${i}b uniqueword${i}c uniqueword${i}d";
        my $v = $d->record_call('file_operations',
            { operation => 'grep_search', query => "q$i", path => 'lib' }, $content);
        $saw_guidance = 1 if defined $v->{guidance};
    }
    ok(!$saw_guidance, 'substantially different results never fire');
};

subtest 'repeated empty results are a loop signal' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    my $verdict;
    for my $i (0 .. 2) {
        $verdict = $d->record_call('file_operations',
            { operation => 'grep_search', query => "nothing$i", path => 'lib' }, '');
    }
    ok(defined $verdict->{guidance}, 'three empty results produce guidance');
};

subtest 'no verdict authorizes ending the turn' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    my @keys_seen;
    for my $i (0 .. 9) {
        my $v = $d->record_call('terminal_operations',
            { operation => 'exec', command => "grep -rn q$i lib/CLIO" }, $GREP_RESULT_A);
        push @keys_seen, sort keys %$v;
        for my $forbidden (qw(break nudge nudge_text)) {
            ok(!exists $v->{$forbidden}, "call $i has no '$forbidden' field")
                if $i == 9;
        }
    }
    ok(!grep({ $_ eq 'break' } @keys_seen), 'no call ever returned a break field');
};

subtest 'neutral reads neither enter nor clear the window' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    $d->record_call('file_operations',
        { operation => 'grep_search', query => 'a', path => 'lib' }, $GREP_RESULT_A);
    $d->record_call('file_operations',
        { operation => 'grep_search', query => 'b', path => 'lib' }, $GREP_RESULT_A);

    my $read = $d->record_call('file_operations',
        { operation => 'read_file', path => 'lib/CLIO/Core/X.pm' }, 'package X; 1;');
    is($read->{tracked}, 0, 'read_file is not tracked');

    my $exists = $d->record_call('file_operations',
        { operation => 'file_exists', path => 'lib/CLIO/Core/X.pm' }, '1');
    is($exists->{tracked}, 0, 'file_exists is not tracked');

    my $todo = $d->record_call('todo_read', {}, 'no todos');
    is($todo->{tracked}, 0, 'todo_read is not tracked');

    my $verdict = $d->record_call('file_operations',
        { operation => 'grep_search', query => 'c', path => 'lib' }, $GREP_RESULT_A);
    is($verdict->{count}, 3, 'neutral reads did not clear the active run');
    ok(defined $verdict->{guidance}, 'the run still reaches guidance');
};

subtest 'mutating calls clear the window' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    for my $i (0 .. 2) {
        $d->record_call('terminal_operations',
            { operation => 'exec', command => "grep -rn q$i lib/CLIO" }, $GREP_RESULT_A);
    }

    my $write = $d->record_call('file_operations',
        { operation => 'write_file', path => 'lib/CLIO/Core/X.pm', content => 'x' }, 'written');
    is($write->{tracked}, 0, 'write_file is not tracked');

    my $verdict = $d->record_call('terminal_operations',
        { operation => 'exec', command => 'grep -rn after lib/CLIO' }, $GREP_RESULT_A);
    is($verdict->{count}, 1, 'the run restarts after a mutation');
    ok(!defined $verdict->{guidance}, 'no guidance on the restart call');
};

subtest 'classification: tracked, neutral, mutating' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new();

    my %expected = (
        'read_file'            => 'neutral',
        'file_exists'          => 'neutral',
        'grep_search'          => 'tracked',
        'file_search'          => 'tracked',
        'list_dir'             => 'tracked',
        'get_errors'           => 'tracked',
        'write_file'           => 'mutating',
        'replace_string'       => 'mutating',
        'apply_patch'          => 'mutating',
        'status'               => 'tracked',
        'commit'               => 'mutating',
        'todo_read'            => 'neutral',
        'todo_add'             => 'mutating',
        'skill_list'           => 'neutral',
        'skill_create'         => 'mutating',
        'interact'             => 'neutral',
    );

    for my $name (sort keys %expected) {
        my ($tool, $op) = $d->_resolve_call($name, {});
        is($d->_classify($tool, $op, {}), $expected{$name},
            "_classify resolves '$name' as $expected{$name}");
    }

    my @terminal = (
        [ 'grep -rn foo lib',               'tracked' ],
        [ 'sudo grep -rn foo lib',          'tracked' ],
        [ 'cd /repo && grep -rn foo lib',   'tracked' ],
        [ 'git log --oneline',              'tracked' ],
        [ 'git commit -m x',                'mutating' ],
        [ 'make test',                      'mutating' ],
        [ 'perl -Ilib t.pl',                'mutating' ],
    );
    for my $case (@terminal) {
        my ($command, $want) = @$case;
        is($d->_classify('terminal_operations', 'exec', { command => $command }), $want,
            "terminal '$command' is $want");
    }

    is($d->_classify('terminal_operations', 'validate', {}), 'neutral',
        'terminal validate is neutral');
};

subtest 'guidance names the emitted callable' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new(similarity_threshold => 0.1);

    my $note;
    for my $i (1 .. 4) {
        my $v = $d->record_call(
            'file_operations',
            { operation => 'file_search', pattern => 'x', directory => '.' },
            'same result every time',
            'file_search',
        );
        $note = $v->{guidance} if $v->{guidance};
    }

    ok(defined $note, 'guidance note was produced');
    like($note // '', qr/'file_search'/, 'note names the emitted callable');
    unlike($note // '', qr/'file_operations'/,
        'note does not name the rewritten grouping tool');
};

subtest 'thresholds are configurable for tests' => sub {
    my $d = CLIO::Core::ToolLoopDetector->new(
        guidance_threshold   => 1,
        similarity_threshold => 0.1,
    );

    my $first = $d->record_call('file_operations',
        { operation => 'grep_search', query => 'a', path => 'lib' }, 'same');
    is($first->{count}, 1, 'count is 1 on the first call');
    is($first->{guidance}, undef, 'nothing to compare against on the first call');

    my $second = $d->record_call('file_operations',
        { operation => 'grep_search', query => 'b', path => 'lib' }, 'same');
    is($second->{level}, 1, 'threshold 1 fires on the first repeatable call');
};

done_testing();
