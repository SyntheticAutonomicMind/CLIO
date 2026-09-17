#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: SecretRedactor whitelist functionality.
# The old redact_text() method used a blind s///g replacement that never
# consulted the whitelist hash, making add_whitelist() dead code. After
# the fix, whitelisted values are preserved while everything else is
# still redacted.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $repo_root = abs_path(dirname(dirname(dirname($0))));
$repo_root = abs_path('.') unless -d "$repo_root/lib";
unshift @INC, "$repo_root/lib";

require CLIO::Security::SecretRedactor;
CLIO::Security::SecretRedactor->import(qw(redact redact_any get_redactor));

my $pass = 0;
my $fail = 0;

sub ok {
    my ($cond, $label) = @_;
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

my $redactor = get_redactor();
ok($redactor, "Got redactor singleton");

# Save and restore the global whitelist state so this test doesn't
# interfere with other tests that use the singleton.
my %saved_whitelist = %{$redactor->{whitelist}};
$redactor->{whitelist} = {};

# Use exactly 36 chars after the underscore to match the regex
# qr/gh[pous]_[a-zA-Z0-9]{36}/ exactly.  The whitelist key must match
# the exact text that the regex captures.
my $secret  = 'ghp_' . ('a' x 36);
my $secret2 = 'gho_' . ('c' x 36);

# ── Test 1: Without whitelist, known secret is redacted ──
my $text_unsafe = "Token: $secret";
my $redacted = $redactor->redact_text($text_unsafe, level => 'strict');
ok($redacted =~ /\[REDACTED\]/, "Without whitelist: secret is redacted");
ok($redacted !~ /\Q$secret\E/, "Without whitelist: original secret text not present in output");

# ── Test 2: With whitelist, known secret is preserved ──
$redactor->{whitelist} = { lc($secret) => 1 };
$text_unsafe = "Token: $secret";
$redacted = $redactor->redact_text($text_unsafe, level => 'strict');
ok($redacted !~ /\[REDACTED\]/, "With whitelist: secret is NOT redacted");
ok($redacted =~ /\Q$secret\E/, "With whitelist: original secret text preserved in output");

# ── Test 3: Other secrets in same text are still redacted ──
my $text_both = "First: $secret, Second: $secret2";
$redacted = $redactor->redact_text($text_both, level => 'strict');
ok($redacted =~ /\Q$secret\E/, "With whitelist: whitelisted secret preserved alongside other secrets");
ok($redacted =~ /\[REDACTED\]/, "With whitelist: non-whitelisted secret still redacted");
ok($redacted !~ /\Q$secret2\E/, "With whitelist: non-whitelisted secret text not in output");

# ── Test 4: Case-insensitive whitelist matching ──
$redactor->{whitelist} = { lc($secret) => 1 };
$text_unsafe = "Token: " . uc($secret);
$redacted = $redactor->redact_text($text_unsafe, level => 'strict');
# The pattern qr/gh[pous]_[a-zA-Z0-9]{36}/ matches case-insensitively
# because [A-Za-z] is in the char class. lc() on the match should still
# match the whitelist key.
ok($redacted !~ /\[REDACTED\]/, "Whitelist case-insensitive: uppercase secret preserved");

# ── Test 5: add_whitelist public API works ──
$redactor->add_whitelist($secret);
ok(exists $redactor->{whitelist}->{lc($secret)}, "add_whitelist stores value (lowercase key)");

# ── Test 6: redact_any also respects whitelist ──
$redactor->{whitelist} = { lc($secret) => 1 };
my $data = { token => $secret, other => $secret2 };
my $safe = redact_any($data, level => 'strict');
ok($safe->{token} eq $secret, "redact_any: whitelisted value preserved");
ok($safe->{other} =~ /\[REDACTED\]/, "redact_any: non-whitelisted value still redacted");

# ── Test 7: Whitelist does not bypass redaction of different patterns ──
$redactor->{whitelist} = { lc($secret) => 1 };
my $mixed = "API key secret: $secret2, Token: $secret";
$redacted = $redactor->redact_text($mixed, level => 'strict');
ok($redacted =~ /\Q$secret\E/, "Whitelisted secret preserved in mixed text");
ok($redacted !~ /\Q$secret2\E/, "Non-whitelisted secret still redacted in mixed text");

# ── Test 8: Empty/whitespace-only whitelist entries don't break redaction ──
$redactor->{whitelist} = { "" => 1, " " => 1 };
$redacted = $redactor->redact_text("Token: $secret", level => 'strict');
ok($redacted =~ /\[REDACTED\]/, "Empty whitelist entries don't prevent redaction");

# Restore original whitelist state
$redactor->{whitelist} = \%saved_whitelist;

print "\n----------------------------------------\n";
print "PASS: $pass  FAIL: $fail\n";
if ($fail > 0) {
    print "SOME TESTS FAILED!\n";
    exit 1;
}
print "ALL TESTS PASSED\n";
exit 0;
