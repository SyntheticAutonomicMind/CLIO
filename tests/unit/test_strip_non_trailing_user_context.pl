#!/usr/bin/env perl
# Tests for WorkflowOrchestrator::_strip_non_trailing_user_context
#
# Regression test for the 2026-08-18 bug: snapshot captured
# <dynamicContext> at position [1] instead of [-2]. The resume fast
# path carried this non-standard layout forward, the next turn's
# rebuild produced the correct layout at [-2], and the LCP match
# failed because the prompts diverged after the system prompt.
#
# Fix: normalize snapshots by stripping all user_context system
# messages except the last one (which should be at the trailing
# position per the pipeline protocol).

use strict;
use warnings;
use utf8;

use CLIO::Core::WorkflowOrchestrator;

sub make_msg {
    my ($role, $content) = @_;
    return { role => $role, content => $content };
}

sub has_user_context_tag {
    my ($msg) = @_;
    my $content = $msg->{content} // '';
    return $content =~ /<(?:userContext|dynamicContext|sessionGoals)>/;
}

# Build a minimal WorkflowOrchestrator-like object that exposes the
# normalization helper. The method is intentionally package-callable
# so we can test it without spinning up the full orchestrator.
my $orc = bless {}, 'CLIO::Core::WorkflowOrchestrator';

# Test 1: snapshot with user_context at [1] (the bug) gets normalized
{
    my @messages = (
        make_msg('system', '# CLIO System Prompt...'),
        make_msg('system', '<dynamicContext> LTM </dynamicContext>'),
        make_msg('user',   'please study the cache changes'),
        make_msg('assistant', 'I will study them.'),
        make_msg('tool',   '{"result": "..."}'),
        make_msg('system', '<userContext> date: 2026-08-18 </userContext>'),
        make_msg('user',   'continue debugging'),
    );

    my @normalized = $orc->_strip_non_trailing_user_context(@messages);

    my $stale_count = 0;
    for my $i (0 .. $#normalized) {
        next if $i == $#normalized - 1;
        if (has_user_context_tag($normalized[$i])) {
            $stale_count++;
        }
    }

    if ($stale_count == 0) {
        print "ok 1 - stale non-trailing user_context removed\n";
    } else {
        print "not ok 1 - stale non-trailing user_context NOT removed (found $stale_count)\n";
    }

    my $trailing_ok = 0;
    if ($#normalized >= 1
        && ($normalized[-2]{role} // '') eq 'system'
        && has_user_context_tag($normalized[-2])) {
        $trailing_ok = 1;
    }
    if ($trailing_ok) {
        print "ok 2 - trailing user_context preserved at [-2]\n";
    } else {
        print "not ok 2 - trailing user_context NOT at [-2]\n";
    }

    if (($normalized[-1]{role} // '') eq 'user') {
        print "ok 3 - user_input preserved at [-1]\n";
    } else {
        print "not ok 3 - user_input NOT at [-1]\n";
    }
}

# Test 2: canonical layout (user_context at [-2] only) is unchanged
{
    my @messages = (
        make_msg('system', '# CLIO System Prompt...'),
        make_msg('user',   'please study the cache changes'),
        make_msg('assistant', 'I will study them.'),
        make_msg('tool',   '{"result": "..."}'),
        make_msg('system', '<userContext> date: 2026-08-18 </userContext>'),
        make_msg('user',   'continue debugging'),
    );

    my @normalized = $orc->_strip_non_trailing_user_context(@messages);

    if (scalar(@normalized) == scalar(@messages)) {
        print "ok 4 - canonical layout unchanged\n";
    } else {
        print "not ok 4 - canonical layout was modified (was " . scalar(@messages) . ", now " . scalar(@normalized) . ")\n";
    }
}

# Test 3: multiple stale user_context messages all get removed
{
    my @messages = (
        make_msg('system', '<dynamicContext> LTM </dynamicContext>'),
        make_msg('system', '# CLIO System Prompt...'),
        make_msg('system', '<sessionGoals> goal1 </sessionGoals>'),
        make_msg('user',   'msg'),
        make_msg('system', '<dynamicContext> date </dynamicContext>'),
        make_msg('user',   'input'),
    );

    my @normalized = $orc->_strip_non_trailing_user_context(@messages);

    my $uc_count = 0;
    for my $msg (@normalized) {
        $uc_count++ if has_user_context_tag($msg);
    }

    if ($uc_count == 1) {
        print "ok 5 - only one (trailing) user_context remains after stripping\n";
    } else {
        print "not ok 5 - found $uc_count user_context messages (expected 1)\n";
    }
}

# Test 4: empty array passes through
{
    my @normalized = $orc->_strip_non_trailing_user_context();
    if (scalar(@normalized) == 0) {
        print "ok 6 - empty array passes through\n";
    } else {
        print "not ok 6 - empty array produced " . scalar(@normalized) . " elements\n";
    }
}

# Test 5: no user_context at all passes through unchanged
{
    my @messages = (
        make_msg('system', '# CLIO System Prompt...'),
        make_msg('user',   'msg'),
        make_msg('assistant', 'reply'),
        make_msg('tool',   '{"r":1}'),
        make_msg('user',   'next msg'),
    );

    my @normalized = $orc->_strip_non_trailing_user_context(@messages);

    if (scalar(@normalized) == scalar(@messages)) {
        print "ok 7 - array without user_context passes through unchanged\n";
    } else {
        print "not ok 7 - array without user_context was modified\n";
    }
}

print "1..7\n";