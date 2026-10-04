#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 fewtarius
#
# Compatibility test for the deprecated _looks_premature_stop shim.
#
# The old heuristic (character-count + punctuation) has been replaced by
# CLIO::Core::WorkflowCompletion, which inspects objective execution
# evidence (API finish_reason, structured tool results, verification
# state, todo state) as the primary signal, with textual analysis
# relegated to a secondary advisory layer.
#
# _looks_premature_stop remains as a thin compatibility shim that
# delegates to the new evaluator. This test verifies the shim delegates
# correctly and returns the right boolean (1 = should continue nudging,
# 0 = treat as complete) for each case.
#
# Full behavioral coverage is in test_workflow_completion.pl.

use strict;
use warnings;
use utf8;
use lib '/Users/andrew/repositories/syntheticautonomicmind/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;
use CLIO::Core::WorkflowOrchestrator;

# Build a minimal WorkflowOrchestrator instance.
my $orch = bless({
    tool_calls_count => 0,
}, 'CLIO::Core::WorkflowOrchestrator');

# Empty content + tool calls -> premature (empty_response layer)
{
    is($orch->_looks_premature_stop('', 1), 1,
        'Test 1.1: empty content + 1 tool call = premature');
    is($orch->_looks_premature_stop(undef, 1), 1,
        'Test 1.2: undef content + tool calls = premature');
    is($orch->_looks_premature_stop('', 5), 1,
        'Test 1.3: empty content + many tool calls = premature');
}

# Short content with explicit unfinished-intent phrases + tool calls -> premature
{
    is($orch->_looks_premature_stop('I still need to check something', 1), 1,
        'Test 2.1: "I still need to..." = premature');
    is($orch->_looks_premature_stop('Next I will examine the output', 2), 1,
        'Test 2.2: "Next I will..." = premature');
    is($orch->_looks_premature_stop("I'll now check the results", 1), 1,
        'Test 2.3: "I\'ll now..." = premature');
    is($orch->_looks_premature_stop('The next step is to verify', 1), 1,
        'Test 2.4: "The next step is..." = premature');
}

# Short content ending with incomplete punctuation + tool calls -> premature
# (trailing `:` or `,` is not a letter, so incomplete_structure fires)
{
    is($orch->_looks_premature_stop('Found the following:', 1), 1,
        'Test 3.1: short content ending with colon = premature');
    is($orch->_looks_premature_stop('Looking at line 5,', 1), 1,
        'Test 3.2: short content ending with comma = premature');
    is($orch->_looks_premature_stop('Let me check', 1), 1,
        'Test 3.3: short content with no terminal punct = premature (matches "Let me check" intent pattern)');
}

# Short content with terminal punctuation + tool calls -> NOT premature
{
    is($orch->_looks_premature_stop('Done.', 1), 0,
        'Test 4.1: short content with period = NOT premature');
    is($orch->_looks_premature_stop('OK!', 1), 0,
        'Test 4.2: short content with exclamation = NOT premature');
    is($orch->_looks_premature_stop('Found 3 results.', 1), 0,
        'Test 4.3: short content with terminal punctuation = NOT premature');
    is($orch->_looks_premature_stop('All good.', 5), 0,
        'Test 4.4: short terminal-punctuated response = NOT premature');
    is($orch->_looks_premature_stop('working on it...', 1), 0,
        'Test 4.5: content ending with ellipsis = treated as terminal');
}

# Long content containing unfinished intent -> premature (textual signal,
# not length-based)
{
    my $long_mid = 'I have started the analysis and gathered the initial data, but I still need to' x 5;
    is($orch->_looks_premature_stop($long_mid, 1), 1,
        'Test 5.1: long content with "I still need to" = premature (textual, not length)');
}

# Long content without unfinished intent -> NOT premature
{
    my $long_complete = 'I have completed the analysis. The findings are consistent with the prior runs. ' x 5;
    is($orch->_looks_premature_stop($long_complete, 1), 0,
        'Test 6.1: long complete response = NOT premature');
}

# No tool calls -> never premature (first-iteration response, or response
# after no tool activity, is always treated as final)
{
    is($orch->_looks_premature_stop('', 0), 0,
        'Test 7.1: empty content + 0 tool calls = NOT premature');
    is($orch->_looks_premature_stop('mid-sentence', 0), 0,
        'Test 7.2: mid-sentence content + 0 tool calls = NOT premature');
    is($orch->_looks_premature_stop('Let me check', 0), 0,
        'Test 7.3: short content + 0 tool calls = NOT premature');
    is($orch->_looks_premature_stop(undef, 0), 0,
        'Test 7.4: undef content + 0 tool calls = NOT premature');
}

# The new gate does NOT use character count as a principal criterion.
# A long response without terminal punctuation that doesn't match any
# unfinished-intent pattern is treated as complete.
{
    my $long_no_punct = 'I have reviewed the codebase and identified the root cause in the' x 3;
    is($orch->_looks_premature_stop($long_no_punct, 0), 0,
        'Test 8.1: long response without terminal punctuation, no tools = NOT premature (char count is not the criterion)');
}

done_testing();