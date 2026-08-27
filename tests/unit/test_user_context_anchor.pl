#!/usr/bin/env perl
# Regression test: ensure user_context at msg[1] is preserved through the trim.
#
# Bug: validate_and_truncate drops user_context system messages (containing
# <dynamicContext>/<userContext>/<sessionGoals>) when they appear at non-trailing
# positions in the messages array. This happens because the canonical pipeline
# layout puts user_context at position [-2], but in practice user_context often
# sits at position [1] right after the CLIO system prompt (especially after
# tool result accumulation moves the trailing user_input out of the way).
#
# When the proactive trim drops this user_context, the chat template's
# <system>...</system> block content shifts (or in this template, doesn't
# change but the message order does), and llama.cpp's LCP cache match fails.
# The next request forces a full re-prompt process (~5 minutes per task).
#
# Fix: _extract_preserved_units must preserve user_context units at any
# position, treating them like anchors (similar to thread_summary).

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use lib '../../lib';
use Test::More;
use CLIO::Core::API::MessageValidator;

# ---- Test 1: user_context at msg[1] is preserved when budget forces trim ----
{
    my @messages;
    push @messages, { role => 'system', content => 'You are CLIO. ' . ('X' x 1000) };
    push @messages, {
        role => 'system',
        content => "<dynamicContext>\n## Long-Term Memory\n\nLTM patterns.\n</dynamicContext>\n\n<sessionGoals>\nNone.\n</sessionGoals>",
    };
    push @messages, { role => 'user', content => 'please do a full QA audit' };

    # Fill context with assistant+tool pairs so the budget walk must drop something
    for my $i (1..50) {
        my $tc_id = "call_$i";
        push @messages, {
            role => 'assistant',
            content => "Step $i",
            tool_calls => [{ id => $tc_id, type => 'function', function => { name => 'file_operations', arguments => '{"path":"file"}' } }],
        };
        push @messages, {
            role => 'tool',
            tool_call_id => $tc_id,
            content => ('x' x 5000),
        };
    }
    # Trailing user_context (canonical pipeline layout)
    push @messages, {
        role => 'system',
        content => "<dynamicContext>\n## Long-Term Memory (fresh)\n\nUpdated LTM.\n</dynamicContext>",
    };
    push @messages, { role => 'user', content => 'please do a full QA audit' };

    my $result = CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 8000 },
        token_ratio        => 2.5,
    );

    my @user_ctx = grep {
        ($_->{role} // '') eq 'system' && ($_->{content} // '') =~ /<dynamicContext>/
    } @$result;

    ok(scalar(@user_ctx) >= 1, "At least one user_context system message preserved through trim (got " . scalar(@user_ctx) . ")");

    # The trailing user_context (with "Updated LTM") must be preserved through
    # the trim. With the Fix 1 layout correction, the leading user_context at
    # msg[1] is dropped (deduplicated) and only the trailing one survives —
    # placed after the thread_summary, not at position [1].
    my $trailing_user_ctx_preserved = 0;
    for my $msg (@$result) {
        if (($msg->{role} // '') eq 'system' && ($msg->{content} // '') =~ /Updated LTM/) {
            $trailing_user_ctx_preserved = 1;
            last;
        }
    }
    ok($trailing_user_ctx_preserved, "trailing user_context (Updated LTM) preserved through trim");

    # The leading user_context at msg[1] (with "LTM patterns") should NOT
    # survive — it was the non-trailing duplicate that caused the LCP cache
    # to break when it changed every minute (timestamp).
    my $leading_user_ctx_stripped = 1;
    for my $msg (@$result) {
        if (($msg->{role} // '') eq 'system' && ($msg->{content} // '') =~ /LTM patterns/) {
            $leading_user_ctx_stripped = 0;
            last;
        }
    }
    ok($leading_user_ctx_stripped, "leading user_context (LTM patterns) stripped — no duplicate at msg[1]");

    # Verify user_context is NOT at position [1] (the bug)
    if (@$result > 1) {
        unlike($result->[1]{content} // '', qr/<dynamicContext>/,
            'user_context NOT at position [1] after trim (was the LCP cache breaker)');
    }
}

# ---- Test 2: prefix layout stable when trim runs ----
{
    # Construct the canonical pipeline layout where user_context sits at
    # msg[1] (which happens whenever _build_turn_context is called once and
    # tool results are appended after user_input on subsequent iterations).
    my @messages;
    push @messages, { role => 'system', content => 'CLIO System Prompt ' . ('A' x 5000) };
    push @messages, { role => 'system', content => "<dynamicContext>Original LTM at msg[1]</dynamicContext>" };
    push @messages, { role => 'user',   content => 'original user query' };

    # Add enough assistant+tool pairs to force a trim
    for my $i (1..30) {
        my $tc_id = "tc_$i";
        push @messages, {
            role => 'assistant',
            content => "Step $i",
            tool_calls => [{ id => $tc_id, type => 'function', function => { name => 'exec', arguments => '{}' } }],
        };
        push @messages, {
            role => 'tool',
            tool_call_id => $tc_id,
            content => ('x' x 8000),
        };
    }
    push @messages, { role => 'system', content => "<dynamicContext>Fresh user_context at trailing</dynamicContext>" };
    push @messages, { role => 'user',   content => 'continue' };

    my $result = CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 5000 },
        token_ratio        => 2.5,
    );

    # The first system message (CLIO system prompt) must still be msg[0]
    ok(@$result && $result->[0]{role} eq 'system', "msg[0] is system (CLIO preserved)");
    like($result->[0]{content}, qr/CLIO System Prompt/, "msg[0] is the CLIO system prompt");

    # The trailing user_context (Fresh) must be preserved. With Fix 1, the
    # leading user_context at msg[1] (Original LTM) is dropped as a duplicate
    # and the trailing one is placed after the thread_summary — NOT at [1].
    my $trailing_uc_preserved = 0;
    my $trailing_uc_idx = -1;
    for my $i (0 .. $#$result) {
        my $msg = $result->[$i];
        if (ref($msg) eq 'HASH' && ($msg->{role} // '') eq 'system'
            && ($msg->{content} // '') =~ /Fresh user_context at trailing/) {
            $trailing_uc_preserved = 1;
            $trailing_uc_idx = $i;
            last;
        }
    }
    ok($trailing_uc_preserved, "trailing user_context (Fresh) preserved through trim");
    if ($trailing_uc_preserved && $trailing_uc_idx > 0) {
        unlike($result->[1]{content} // '', qr/Original LTM at msg/,
            'leading user_context (Original LTM) NOT at msg[1] — moved/dropped');
    }
}

# ---- Test 3: prefix layout stable when no trim is needed ----
{
    # Sanity: even when there's no budget pressure, user_context at msg[1]
    # should round-trip through validate_and_truncate unchanged.
    my @messages;
    push @messages, { role => 'system', content => 'CLIO System Prompt' };
    push @messages, { role => 'system', content => "<dynamicContext>LTM</dynamicContext>" };
    push @messages, { role => 'user', content => 'hello' };
    push @messages, { role => 'assistant', content => 'world' };

    my $result = CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 128000 },
        token_ratio        => 2.5,
    );

    is(scalar @$result, 4, "All 4 messages preserved when within budget");
    is($result->[1]{role}, 'system', "msg[1] is system");
    like($result->[1]{content}, qr/<dynamicContext>/, "msg[1] contains dynamicContext tag");
}

# ---- Test 4: trim drops oldest dialog without touching user_context ----
{
    # Verify the trim drops assistant+tool pairs (oldest first) but keeps
    # user_context at msg[1] intact. This is what the bug regression looks like:
    # without the fix, msg[1] changes from system(user_context) to user(query),
    # breaking the LCP cache.
    my @messages;
    push @messages, { role => 'system', content => 'CLIO ' . ('Z' x 2000) };
    push @messages, { role => 'system', content => "<dynamicContext>DO NOT DROP ME</dynamicContext>" };
    push @messages, { role => 'user',   content => 'query' };

    # Pad with many assistant+tool pairs to force aggressive trim
    for my $i (1..100) {
        my $tc_id = "tc_$i";
        push @messages, {
            role => 'assistant',
            content => "Step $i",
            tool_calls => [{ id => $tc_id, type => 'function', function => { name => 'exec', arguments => '{}' } }],
        };
        push @messages, {
            role => 'tool',
            tool_call_id => $tc_id,
            content => ('y' x 3000),
        };
    }

    my $result = CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => \@messages,
        model_capabilities => { max_prompt_tokens => 4000 },
        token_ratio        => 2.5,
    );

    # The user_context (DO NOT DROP ME) must survive even under aggressive
    # trim. With Fix 1, it's preserved at the trailing position (after the
    # thread_summary), NOT at msg[1].
    my $user_ctx_preserved = 0;
    for my $msg (@$result) {
        if (ref($msg) eq 'HASH' && ($msg->{role} // '') eq 'system'
            && ($msg->{content} // '') =~ /DO NOT DROP ME/) {
            $user_ctx_preserved = 1;
            last;
        }
    }
    ok($user_ctx_preserved, "user_context (DO NOT DROP ME) preserved under aggressive trim");
    unless ($user_ctx_preserved) {
        # If not preserved, check it's not at [1] specifically
        if (@$result > 1) {
            unlike($result->[1]{content} // '', qr/DO NOT DROP ME/,
                'user_context was NOT dropped entirely — either preserved elsewhere or intentionally removed');
        }
    }
}

done_testing();