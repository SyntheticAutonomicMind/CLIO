#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 fewtarius
#
# Unit test for the premature-stop heuristic in WorkflowOrchestrator.
#
# The heuristic decides whether to nudge the model with a continuation
# message when it appears to have stopped mid-workflow. The two-prong
# defense is:
#
#   1. APIManager streaming-side: detects truncated streams (no
#      finish_reason) and surfaces them as retryable errors.
#   2. WorkflowOrchestrator response-side: catches responses that
#      complete cleanly but look incomplete (empty, short, mid-sentence).
#
# This test exercises (2) directly. The full premature-stop injection
# (message list mutation, iteration decrement) is integrated with
# process_input and is covered by the e2e/integration tests.
#
# Critical: this heuristic is the second line of defense for the
# MiniMax-style "agent just stops" bug, so it has to keep firing
# reliably on empty/short-mid-sentence responses.

use strict;
use warnings;
use utf8;
use lib '/Users/andrew/repositories/syntheticautonomicmind/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use CLIO::Core::WorkflowOrchestrator;

# Build a minimal WorkflowOrchestrator instance. The heuristic only uses
# the blessed object identity, so we don't need a full session/api_manager.
my $orch = bless({
    tool_calls_count => 0,
}, 'CLIO::Core::WorkflowOrchestrator');

# Empty content + tool calls -> premature
{
    is($orch->_looks_premature_stop('', 1), 1,
        'Test 1.1: empty content + 1 tool call = premature');
    is($orch->_looks_premature_stop(undef, 1), 1,
        'Test 1.2: undef content + tool calls = premature');
    is($orch->_looks_premature_stop('', 5), 1,
        'Test 1.3: empty content + many tool calls = premature');
}

# Short mid-sentence content + tool calls -> premature
{
    is($orch->_looks_premature_stop('Let me check', 1), 1,
        'Test 2.1: short content with no terminal punctuation = premature');
    is($orch->_looks_premature_stop('I will examine the', 1), 1,
        'Test 2.2: short content ending mid-word = premature');
    is($orch->_looks_premature_stop('Found the following:', 1), 1,
        'Test 2.3: short content ending with colon = premature');
    is($orch->_looks_premature_stop('Looking at line 5,', 1), 1,
        'Test 2.4: short content ending with comma = premature');
    is($orch->_looks_premature_stop('OK', 2), 1,
        'Test 2.5: 2-char content with no punctuation = premature');
    # Note: "..." matches the [.!?] terminal-punctuation regex, so the
    # heuristic treats it as a stop signal. This is a fine-grained
    # limitation: a model that says "working on it..." intending to
    # continue will be treated as a final answer. The streaming-side
    # truncation guard in APIManager is the real defense for those
    # cases - the model would need to actually send a finish_reason
    # chunk for this heuristic to be the only thing standing between
    # a continuation and a stop.
    is($orch->_looks_premature_stop('working on it...', 1), 0,
        'Test 2.6: content ending with ellipsis = treated as terminal (heuristic limitation)');
}

# Short content with terminal punctuation + tool calls -> NOT premature
# (this is the gap that allowed the MiniMax silent-stop bug through; the
#  streaming-side truncation guard in APIManager now catches it there)
{
    is($orch->_looks_premature_stop('Done.', 1), 0,
        'Test 3.1: short content with period = NOT premature');
    is($orch->_looks_premature_stop('OK!', 1), 0,
        'Test 3.2: short content with exclamation = NOT premature');
    is($orch->_looks_premature_stop('Found 3 results.', 1), 0,
        'Test 3.3: short content with terminal punctuation = NOT premature');
    is($orch->_looks_premature_stop('All good.', 5), 0,
        'Test 3.4: short terminal-punctuated response = NOT premature');
}

# Long content (>= 200 chars) + tool calls -> NOT premature, even mid-sentence
# A model that wrote 200+ chars was probably actually finishing its thought.
{
    my $long_mid = 'I have started the analysis and gathered the initial data, but I still need to' x 5;  # ~225 chars
    is($orch->_looks_premature_stop($long_mid, 1), 0,
        'Test 4.1: long content even mid-sentence = NOT premature');
    my $long_complete = 'I have completed the analysis. The findings are consistent with the prior runs. ' x 5;  # ~280 chars
    is($orch->_looks_premature_stop($long_complete, 1), 0,
        'Test 4.2: long complete response = NOT premature');
}

# No tool calls -> never premature (first-iteration response, or response
# after no tool activity, is always treated as final)
{
    is($orch->_looks_premature_stop('', 0), 0,
        'Test 5.1: empty content + 0 tool calls = NOT premature');
    is($orch->_looks_premature_stop('mid-sentence', 0), 0,
        'Test 5.2: mid-sentence content + 0 tool calls = NOT premature');
    is($orch->_looks_premature_stop('Let me check', 0), 0,
        'Test 5.3: short content + 0 tool calls = NOT premature');
    is($orch->_looks_premature_stop(undef, 0), 0,
        'Test 5.4: undef content + 0 tool calls = NOT premature');
}

# Trailing whitespace must not break detection
{
    is($orch->_looks_premature_stop("checking the file  \n", 1), 1,
        'Test 6.1: trailing whitespace stripped before punctuation check');
    is($orch->_looks_premature_stop("done.   \n", 1), 0,
        'Test 6.2: trailing whitespace stripped, terminal period detected');
}

# Realistic MiniMax-style responses
{
    is($orch->_looks_premature_stop('I will investigate', 1), 1,
        'Test 7.1: MiniMax-style "I will investigate" = premature');
    is($orch->_looks_premature_stop('Let me check the next', 2), 1,
        'Test 7.2: Mid-work continuation after multiple tool calls = premature');
    is($orch->_looks_premature_stop('The fix is complete. The tests pass.', 3), 0,
        'Test 7.3: Complete answer with summary = NOT premature');
}

done_testing();
