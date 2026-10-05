#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Compatibility test for the deprecated _looks_premature_stop shim.
#
# _looks_premature_stop remains as a thin compatibility shim that
# delegates to CLIO::Core::WorkflowCompletion->evaluate(). The gate
# only checks two conditions:
#   1. API finish_reason=length (truncation)
#   2. Empty response after tool activity (reasoning-only turn)
#
# Textual signals (unfinished intent patterns, incomplete structure,
# character count thresholds) are NOT checked — the agent decides when
# it is done; the gate only catches objective premature stops.
#
# The shim converts the gate's structured result to a boolean:
#   1 = should nudge the model to continue
#   0 = treat as a legitimate final answer

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

use Test::More;
use CLIO::Core::WorkflowOrchestrator;

# Build a minimal WorkflowOrchestrator instance.
my $orch = bless({}, 'CLIO::Core::WorkflowOrchestrator');

# Empty content + tool calls -> premature (empty_response layer)
{
    is($orch->_looks_premature_stop('', 1), 1,
        'Test 1.1: empty content + 1 tool call = premature');
    is($orch->_looks_premature_stop(undef, 1), 1,
        'Test 1.2: undef content + tool calls = premature');
    is($orch->_looks_premature_stop('', 5), 1,
        'Test 1.3: empty content + many tool calls = premature');
}

# Non-empty content with tool calls -> NOT premature
# (the gate does not parse text for intent, structure, or length)
{
    is($orch->_looks_premature_stop('I still need to check something', 1), 0,
        'Test 2.1: "I still need to..." with content = NOT premature');
    is($orch->_looks_premature_stop('Let me check', 1), 0,
        'Test 2.2: "Let me check" with content = NOT premature');
    is($orch->_looks_premature_stop('Found the following:', 1), 0,
        'Test 2.3: short content ending with colon = NOT premature');
    is($orch->_looks_premature_stop('Looking at line 5,', 1), 0,
        'Test 2.4: short content ending with comma = NOT premature');
}

# Short content with terminal punctuation + tool calls -> NOT premature
{
    is($orch->_looks_premature_stop('Done.', 1), 0,
        'Test 3.1: short content with period = NOT premature');
    is($orch->_looks_premature_stop('OK!', 1), 0,
        'Test 3.2: short content with exclamation = NOT premature');
    is($orch->_looks_premature_stop('Found 3 results.', 1), 0,
        'Test 3.3: short content with terminal punctuation = NOT premature');
}

# Long content (with or without punctuation) -> NOT premature
{
    my $long_complete = 'I have completed the analysis. The findings are consistent with the prior runs. ' x 5;
    is($orch->_looks_premature_stop($long_complete, 1), 0,
        'Test 4.1: long complete response = NOT premature');

    my $long_no_punct = 'I have reviewed the codebase and identified the root cause in the' x 3;
    is($orch->_looks_premature_stop($long_no_punct, 1), 0,
        'Test 4.2: long response without terminal punctuation = NOT premature');
}

# No tool calls -> never premature
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

done_testing();
