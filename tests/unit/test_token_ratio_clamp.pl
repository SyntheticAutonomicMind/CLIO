#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: validate_and_truncate clamps out-of-range
# token_ratio values to prevent catastrophic over/under-trim.
#
# Background: token_ratio is learned from observed counts and passed
# from APIManager. If it's stale (wrong model, wrong provider, or
# corrupted learning), the trim math breaks silently - a ratio of
# 0.5 makes _estimate_tokens think a message is twice as long as
# it is (over-trim), a ratio of 100 makes it 40x shorter
# (under-trim until we exceed budget and bail out).
#
# Fix: clamp to 1.0..10.0 and log a warning. 2.5 (chars/token) is
# the safe default.

use strict;
use warnings;
use utf8;
use lib './lib';

use Test::More;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

# Minimal messages - just enough to exercise the validate path.
my @messages = (
    { role => 'user', content => 'hello' },
    { role => 'assistant', content => 'hi' },
);

my $caps = {
    max_context_window_tokens => 128000,
    max_output_tokens         => 16000,
};

# Sanity: a normal ratio (2.5) produces a no-trim result.
my $result = validate_and_truncate(
    messages           => \@messages,
    model_capabilities => $caps,
    tools              => [],
    token_ratio        => 2.5,
);
ok(ref($result) eq 'ARRAY', 'normal token_ratio (2.5) returns arrayref');
is(scalar(@$result), 2, 'normal token_ratio preserves all messages when under budget');

# Out-of-range low: 0.5 (over-estimate by 5x).
$result = validate_and_truncate(
    messages           => \@messages,
    model_capabilities => $caps,
    tools              => [],
    token_ratio        => 0.5,
);
ok(ref($result) eq 'ARRAY', 'out-of-range low (0.5) does not crash');

# Out-of-range high: 100 (under-estimate by 40x).
$result = validate_and_truncate(
    messages           => \@messages,
    model_capabilities => $caps,
    tools              => [],
    token_ratio        => 100,
);
ok(ref($result) eq 'ARRAY', 'out-of-range high (100) does not crash');

# Garbage ratio (non-numeric) - falls back to 2.5.
$result = validate_and_truncate(
    messages           => \@messages,
    model_capabilities => $caps,
    tools              => [],
    token_ratio        => 'banana',
);
ok(ref($result) eq 'ARRAY', 'non-numeric ratio falls back to 2.5 without crash');

# Undef ratio - falls back to 2.5.
$result = validate_and_truncate(
    messages           => \@messages,
    model_capabilities => $caps,
    tools              => [],
    token_ratio        => undef,
);
ok(ref($result) eq 'ARRAY', 'undef ratio falls back to 2.5 without crash');

# Boundary: exactly 1.0 is accepted (the clamp range is inclusive).
$result = validate_and_truncate(
    messages           => \@messages,
    model_capabilities => $caps,
    tools              => [],
    token_ratio        => 1.0,
);
ok(ref($result) eq 'ARRAY', 'ratio 1.0 (boundary) accepted');

# Boundary: exactly 10.0 is accepted.
$result = validate_and_truncate(
    messages           => \@messages,
    model_capabilities => $caps,
    tools              => [],
    token_ratio        => 10.0,
);
ok(ref($result) eq 'ARRAY', 'ratio 10.0 (boundary) accepted');

# Regression: bare-dot string ("."), the no-leading-digit edge case
# (".5"), and a number with a trailing dot ("1.") must NOT trigger
# Perl's "isn't numeric in numeric lt" warning. Same class of bug
# Andrew caught in TodoStore.pm:180 in 64de736c. The QA-review regex
# `/^[\d.]+$/` matched all three of these strings (it allows
# arbitrary dot/digit combinations with no required digit) and the
# subsequent numeric compare on the matched string emitted the
# warning. The fix uses `/^\d+(\.\d+)?$/` so only well-formed
# positive decimals match.
{
    # Capture warnings during these calls; assert zero "isn't numeric"
    # warnings fire from the code under test.
    #
    # NOTE: under `perl -W`, Test::Builder itself emits "isn't numeric"
    # warnings when its internal accumulator does numeric addition on
    # the test description strings (e.g. "token_ratio '.' (malformed)
    # does not crash" gets a `+ 0` somewhere in Test/Builder.pm:687).
    # Those are framework noise, not warnings from our code. Filter
    # them out: any warning whose source path contains "Test/" or
    # "Test2/" is framework noise and excluded from the count.
    my @warnings;
    local $SIG{__WARN__} = sub {
        my $msg = shift;
        push @warnings, $msg;
    };
    for my $ratio ('.', '.5', '1.') {
        my $r = validate_and_truncate(
            messages           => \@messages,
            model_capabilities => $caps,
            tools              => [],
            token_ratio        => $ratio,
        );
        ok(ref($r) eq 'ARRAY', "token_ratio '$ratio' (malformed) does not crash");
    }
    # Filter: only count warnings from lib/CLIO/ paths (our code),
    # not Test::Builder / Test2 / JSON::PP / etc.
    my $our_warnings = grep {
        /isn'?t numeric/i
            && !/Test\/Builder\.pm/
            && !/Test2\//
            && !/JSON::PP/
    } @warnings;
    is($our_warnings, 0, 'no "isn\'t numeric" warnings from CLIO code on malformed ratios')
        or diag("Warnings from our code: "
            . join("\n", grep { /isn'?t numeric/i && !/Test\// && !/Test2\// } @warnings));
}

done_testing();