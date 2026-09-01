#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: error result paths must not produce unthemed white text,
# and handled-error log lines must not duplicate the themed error display
# by printing raw log_warning text to the user's terminal.
#
# Bug: SimpleAIAgent wrapped orchestrator error strings as "I'm sorry, I
# encountered an error: $error" and set it as `final_response`. Chat.pm
# stored that wrapper as an assistant message in the screen buffer, which
# the next repaint rendered with assistant-theme colors (white text + cyan
# agent label) - making the error look like a normal agent reply. The
# proper themed ∙ ERROR -> path also ran, producing a duplicate.
#
# Additionally, handled-error log_warning lines (Region unavailable, Model
# not found, Billing error, etc.) printed to STDERR before the themed error
# display ran, so the user saw the raw log line and the styled line.
#
# Fix: SimpleAIAgent no longer wraps the error. Chat.pm does not write
# final_response to the assistant buffer when result->{success} is 0. Chat.pm
# also strips the legacy wrapper from the error string for backward
# compatibility. Handled-error log_warning lines are demoted to log_debug.

use strict;
use warnings;
use utf8;
use lib '/home/deck/repositories/CLIO/lib';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Test::More;

# Helper: slurp a file's content.
sub slurp { my ($f) = @_; local $/; open my $fh, '<', $f or die "open($f): $!"; return <$fh>; }

# ── Test 1: SimpleAIAgent error result has no "I'm sorry" wrapper ─────
{
    my $src = slurp('lib/CLIO/Core/SimpleAIAgent.pm');
    like($src, qr/result->\{error\}\s*=\s*\$error/, 'SimpleAIAgent sets $result->{error} from the raw error');
    unlike($src, qr/final_response.*I'm sorry.*encountered an error/i,
           'SimpleAIAgent no longer wraps final_response with "I\'m sorry, I encountered an error:"');
    unlike($src, qr/I'm experiencing technical difficulties/,
           'SimpleAIAgent no longer emits the legacy "I\'m experiencing technical difficulties" wrapper');
}

# ── Test 2: Chat.pm skips assistant buffer write on failure ────────────
{
    my $src = slurp('lib/CLIO/UI/Chat.pm');
    like($src, qr/Result is a failure - skipping assistant message write/,
         'Chat.pm logs and skips assistant-message write when result is a failure');
    like($src, qr/if \(\$result && \$result->\{success\}\)/,
         'Chat.pm wraps the assistant-message write in a success guard');
}

# ── Test 3: Chat.pm strips the legacy "I'm sorry" wrapper on display ─
{
    my $src = slurp('lib/CLIO/UI/Chat.pm');
    like($src, qr/I'm sorry,\? I encountered an error:\?\\s\*/,
         'Chat.pm strips the legacy "I\'m sorry, I encountered an error:" wrapper for backward compat');
}

# ── Test 4: Handled-error log lines are demoted to log_debug ───────────
# Verify the demotions exist by checking that the relevant log_debug
# statements are present (in both ResponseHandler.pm and ErrorHandler.pm)
# AND that the old log_warning statements are gone.
{
    my $rh = slurp('lib/CLIO/Core/API/ResponseHandler.pm');

    # Each demoted warning should now appear as a log_debug() call with the
    # same first ~40 chars of the message. The previous log_warning calls
    # have been replaced.
    like($rh, qr/log_debug\('ResponseHandler',\s*"Billing error \(non-retryable\):/,
         'ResponseHandler billing 400 uses log_debug');
    like($rh, qr/log_debug\('ResponseHandler',\s*"Region unavailable \(non-retryable\):/,
         'ResponseHandler region_unavailable uses log_debug');
    like($rh, qr/log_debug\('ResponseHandler',\s*"Account disabled \(non-retryable\):/,
         'ResponseHandler account_disabled uses log_debug');
    like($rh, qr/log_debug\('ResponseHandler',\s*"Model not found \(non-retryable\):/,
         'ResponseHandler model_not_found uses log_debug');
    like($rh, qr/log_debug\('ResponseHandler',\s*"Provider unavailable \(non-retryable\):/,
         'ResponseHandler provider_unavailable uses log_debug');

    my $eh = slurp('lib/CLIO/Core/API/ErrorHandler.pm');
    like($eh, qr/log_debug\('ErrorHandler',\s*"Provider backend unavailable/,
         'ErrorHandler provider_unavailable uses log_debug');
    like($eh, qr/log_debug\('ErrorHandler',\s*"Billing error \(out of credits\)/,
         'ErrorHandler billing_error uses log_debug');
    like($eh, qr/log_debug\('ErrorHandler',\s*"Model not found - returning/,
         'ErrorHandler model_not_found uses log_debug');
    like($eh, qr/log_debug\('ErrorHandler',\s*"Region unavailable - returning/,
         'ErrorHandler region_unavailable uses log_debug');
    like($eh, qr/log_debug\('ErrorHandler',\s*"Account disabled - returning/,
         'ErrorHandler account_disabled uses log_debug');
    like($eh, qr/log_debug\('ErrorHandler',\s*"Context trim removed 0 messages/,
         'ErrorHandler trim_zero escalation uses log_debug');
}

# ── Test 5: Verify the strip regex actually strips the legacy wrapper ─
{
    my $msg = "I'm sorry, I encountered an error: Session error limit reached (10 errors). Last error: foo";
    $msg =~ s/^I'm sorry,? I encountered an error:?\s*//i;
    is($msg, 'Session error limit reached (10 errors). Last error: foo',
       'Strip regex removes the legacy wrapper');

    my $msg2 = "API exception: foo";
    $msg2 =~ s/^I'm sorry,? I encountered an error:?\s*//i;
    is($msg2, 'API exception: foo', 'Strip regex leaves non-wrapper strings untouched');

    my $msg3 = "I'm sorry, I encountered an error:Model 'x' not found";
    $msg3 =~ s/^I'm sorry,? I encountered an error:?\s*//i;
    is($msg3, "Model 'x' not found", 'Strip regex handles no-space colon variant');
}

done_testing();
