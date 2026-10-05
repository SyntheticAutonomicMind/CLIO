#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: _looks_premature_stop catches empty/reasoning-only
# responses after tool activity.
#
# The model made tool calls in prior iterations but the final response
# has no content (the model emitted thinking/reasoning only, and
# APIManager stripped it from the visible content). The workflow should
# be nudged to continue, not treated as a final answer.
#
# The gate does NOT check text-based signals (intent patterns, punctuation,
# character count) — those were removed because they caused false positives
# and the agent itself decides when it is done.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../lib";
use Test::More;
require CLIO::Core::WorkflowCompletion;
require CLIO::Core::WorkflowOrchestrator;

my $eval = CLIO::Core::WorkflowCompletion->new(debug => 0);

# Simulate the debug-1.log scenario:
# Model made tool calls, then returned empty content (reasoning stripped).
{
    my @synthetic_calls = map { { name => 'unknown', operation => '', success => 1 } } 1..3;
    my $r = $eval->evaluate(
        content      => '',
        tool_calls   => \@synthetic_calls,
        api_response => { finish_reason => 'stop' },
        retry_count  => 0,
    );
    is($r->{decision}, 'continue',
       'debug-1.log scenario: empty content after tool calls = premature');
    ok(grep { $_ eq 'empty_response' } @{$r->{blockers}},
       'debug-1.log scenario: blocks on empty_response');
}

# Empty content with 0 simulated tool calls -> NOT premature
# (the shim passes count > 0 to synthesize calls; with count=0 it returns 0)
{
    my $r = $eval->evaluate(
        content      => '',
        tool_calls   => [],
        api_response => { finish_reason => 'stop' },
        retry_count  => 0,
    );
    is($r->{decision}, 'complete',
       'empty content + no tool activity = complete (not the gate\'s concern)');
}

# Legitimate final answers with content -> NOT premature
{
    is(_looks_premature_stop_direct("Done. All files have been updated.", 1), 0,
       'legitimate: ends with period -> not premature');
    is(_looks_premature_stop_direct("All done!", 1), 0,
       'legitimate: ends with exclamation -> not premature');
    is(_looks_premature_stop_direct("Shall I continue?", 1), 0,
       'legitimate: ends with question mark -> not premature');
    is(_looks_premature_stop_direct("Yes.", 1), 0,
       'short final answer: ends with period -> not premature');
}

# Responses with content (even mid-sentence) -> NOT premature
# The gate does not check punctuation or sentence structure.
{
    my @synthetic_calls = map { { name => 'unknown', operation => '', success => 1 } } 1..1;
    my $debug_log_content = "Now I can see the exact tokens. So the tokens are:";

    my $r = $eval->evaluate(
        content      => $debug_log_content,
        tool_calls   => \@synthetic_calls,
        api_response => { finish_reason => 'stop' },
        retry_count  => 0,
    );
    is($r->{decision}, 'complete',
       'mid-sentence content after tool calls = complete (no text parsing)');
}

# Long response (>500 chars) -> NOT premature
{
    my $long_mid = "This is a very long response that goes on and on about many " x 10;
    $long_mid = substr($long_mid, 0, 600);
    is(_looks_premature_stop_direct($long_mid, 1), 0,
       'long response (>500 chars): NOT premature (length is not checked)');
}

# finish_reason=length -> premature (truncation)
{
    my $r = $eval->evaluate(
        content      => "Here is the beginning of",
        api_response => { finish_reason => 'length' },
        tool_calls   => [],
        retry_count  => 0,
    );
    is($r->{decision}, 'continue', 'finish_reason=length = premature');
    ok(grep { $_ eq 'api_truncated' } @{$r->{blockers}}, 'blocks on api_truncated');
}

done_testing();

# Direct call to _looks_premature_stop via a minimal orchestrator object.
sub _looks_premature_stop_direct {
    my ($content, $tool_calls_count) = @_;
    my $orch = bless({}, 'CLIO::Core::WorkflowOrchestrator');
    return $orch->_looks_premature_stop($content, $tool_calls_count);
}
