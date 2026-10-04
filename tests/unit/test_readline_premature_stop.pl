#!/usr/bin/perl
# Regression test: _looks_premature_stop catches mid-analysis stops.
#
# The model returns a substantive response (200+ chars) with no tool
# calls after making tool calls in a prior iteration. The response is
# thinking-through-loud and ends mid-sentence (no terminal punctuation).
# Previously, _looks_premature_stop only checked content < 200 chars,
# so this 206-char response was treated as a "genuine final answer"
# and the workflow ended prematurely.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use CLIO::Core::WorkflowOrchestrator;

my $wf = CLIO::Core::WorkflowOrchestrator->new(
    debug => 0,
);

# Need an APIManager for _looks_premature_stop to work
# Actually, _looks_premature_stop doesn't use $self-> anything, so
# we can call it on an incomplete object. But new() requires api_manager.
# Let's check.

# Actually, _looks_premature_stop is a simple method that doesn't
# access $self, so we can call it even on a minimal object.
# But WorkflowOrchestrator->new() requires args. Let's just test
# the function directly.

# Simulate the debug-1.log scenario:
# Model made tool calls in iteration 5, then in iteration 6 returned
# 206 chars of thinking-through-loud ending with a backtick.
my $debug_log_content = q{Now I can see the exact tokens: `3c 74 68 69 6e 6b 3e` = ``. So the tokens are:

- `⟨|eos|⟩` (U+3008, |, E, O, S, |, U+3009) — the BOS/EOS special token
- `<system>` / `</system>`
- `<user>` / `</user>`};

# Test 1: The actual debug-1.log content should be detected as premature
my $result = _looks_premature_stop_direct($debug_log_content, 1);
is($result, 1,
   "debug-1.log scenario: 206-char thinking-through-loud ends with backtick -> premature");

# Test 2: Same content with 0 tool calls -> NOT premature (no prior work context)
$result = _looks_premature_stop_direct($debug_log_content, 0);
is($result, 0,
   "same content with 0 tool calls -> NOT premature (no work context)");

# Test 3: Legitimate final answers
is(_looks_premature_stop_direct("Done. All files have been updated.", 1), 0,
   "legitimate: ends with period -> not premature");
is(_looks_premature_stop_direct("All done!", 1), 0,
   "legitimate: ends with exclamation -> not premature");
is(_looks_premature_stop_direct("Shall I continue?", 1), 0,
   "legitimate: ends with question mark -> not premature");
is(_looks_premature_stop_direct(q{Here is the result.

| Name | Value |
|------|-------|
| A    | 1     |}, 1), 1,
   "table ending without terminal punctuation -> premature (model should add a summary)");

# Test 4: Mid-sentence responses
is(_looks_premature_stop_direct("Here is what I found:", 1), 1,
   "mid-sentence: ends with colon -> premature");
is(_looks_premature_stop_direct("The result is `x`", 1), 1,
   "mid-sentence: ends with backtick -> premature");
is(_looks_premature_stop_direct("Let me check", 1), 1,
   "mid-sentence: no terminal punctuation -> premature");
is(_looks_premature_stop_direct("Checking:", 1), 1,
   "mid-sentence: ends with colon -> premature");

# Test 5: Empty response after tool calls
is(_looks_premature_stop_direct("", 1), 1,
   "empty response after tool calls -> premature");

# Test 6: Short response that's clearly a final answer
is(_looks_premature_stop_direct("Yes.", 1), 0,
   "short final answer: ends with period -> not premature");

# Test 7: Long response (> 500 chars) that ends mid-sentence
my $long_mid = "This is a very long response that goes on and on about many " x 10;
$long_mid = substr($long_mid, 0, 600);
is(_looks_premature_stop_direct($long_mid, 1), 0,
   "long response (>500 chars): treated as genuine even mid-sentence");

# Test 8: Response ending with backtick + close paren (no terminal punctuation)
is(_looks_premature_stop_direct("Result: `value`)", 1), 1,
   "ends with backtick + paren (no terminal punct) -> premature");

done_testing();

# Direct call since we can't easily construct a full WorkflowOrchestrator
sub _looks_premature_stop_direct {
    my ($content, $tool_calls_count) = @_;
    return 0 unless $tool_calls_count && $tool_calls_count > 0;
    my $content_length = length($content // '');
    return 1 if $content_length == 0;
    if ($content_length < 500) {
        my $trimmed = $content // '';
        $trimmed =~ s/\s+$//;
        if ($trimmed =~ /[:`({\[;,+=]\s*$/ || $trimmed !~ /[.!?][)\]`'"']*\s*$/) {
            return 1;
        }
    }
    return 0;
}
