#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

# Test SecretRedactor level-based redaction functionality

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;

# Load the module
use_ok('CLIO::Security::SecretRedactor', qw(redact redact_any get_redactor));

my $redactor = get_redactor();
ok($redactor, 'Got redactor singleton');

# Test data for each category
# NOTE: We carefully construct test data to avoid cross-category matches:
# - PII patterns (email, phone) can match inside other data types
# - Use tokens without long digit sequences that match phone patterns
# - Use database strings without @ symbols that look like emails
my %test_data = (
    pii => {
        input => 'Contact: john.doe@example.com, SSN: 123-45-6789, Phone: (555) 123-4567',
        should_redact => 1,
    },
    crypto => {
        # Use MySQL format without @ to avoid email pattern matching
        input => 'password=supersecretpass123',
        should_redact => 1,
    },
    api_key => {
        # Use a token without long digit sequences that match phone patterns
        input => 'GitHub token: ghp_abcdefghijABCDEFGHIJabcdefghijABCDEF',
        should_redact => 1,
    },
    token => {
        # JWT with non-phone-like payload
        input => 'Auth: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhYmMifQ.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U',
        should_redact => 1,
    },
);

# Define expected behavior per level
my %level_behavior = (
    strict => {
        pii => 1, crypto => 1, api_key => 1, token => 1
    },
    standard => {
        pii => 1, crypto => 1, api_key => 1, token => 1
    },
    api_permissive => {
        pii => 1, crypto => 1, api_key => 0, token => 0  # API keys and tokens allowed
    },
    pii => {
        pii => 1, crypto => 0, api_key => 0, token => 0  # Only PII redacted
    },
    off => {
        pii => 0, crypto => 0, api_key => 0, token => 0  # Nothing redacted
    },
);

# Test each level
for my $level (sort keys %level_behavior) {
    my $expected = $level_behavior{$level};
    
    for my $category (sort keys %test_data) {
        my $input = $test_data{$category}{input};
        my $result = redact($input, level => $level);
        
        my $should_redact = $expected->{$category};
        my $has_redacted = ($result =~ /\[REDACTED\]/);
        
        if ($should_redact) {
            ok($has_redacted, "Level '$level' redacts '$category' data");
        } else {
            ok(!$has_redacted, "Level '$level' allows '$category' data through");
        }
    }
}

# Test pattern counts per level
my @levels = CLIO::Security::SecretRedactor->get_valid_levels();
is_deeply([sort @levels], [qw(api_permissive off pii standard strict)], 'Valid levels list correct');

# Test pattern_count varies by level
my $strict_count = $redactor->pattern_count('strict');
my $pii_count = $redactor->pattern_count('pii');
my $off_count = $redactor->pattern_count('off');

ok($strict_count > $pii_count, "strict has more patterns ($strict_count) than pii ($pii_count)");
is($off_count, 0, "off level has 0 patterns");

# Test total pattern count
my $total = $redactor->total_pattern_count();
ok($total > 0, "Total pattern count: $total");

# Test set_level
$redactor->set_level('api_permissive');
is($redactor->get_level(), 'api_permissive', 'set_level works');

# Test invalid level falls back
$redactor->set_level('invalid_level');
is($redactor->get_level(), 'api_permissive', 'Invalid level rejected, keeps previous');

# Test redact_any with levels - use tokens without phone-like sequences
my $data = {
    email => 'secret@example.com',
    token => 'ghp_abcdefghijABCDEFGHIJabcdefghijABCDEF',
};

my $strict_result = redact_any($data, level => 'strict');
like($strict_result->{email}, qr/\[REDACTED\]/, 'redact_any strict: email redacted');
like($strict_result->{token}, qr/\[REDACTED\]/, 'redact_any strict: token redacted');

my $pii_result = redact_any($data, level => 'pii');
like($pii_result->{email}, qr/\[REDACTED\]/, 'redact_any pii: email redacted');
unlike($pii_result->{token}, qr/\[REDACTED\]/, 'redact_any pii: token NOT redacted');

# Test specific patterns
subtest 'GitHub PAT patterns' => sub {
    # Use tokens that don't have 10-digit phone-like sequences inside
    my $classic_pat = 'ghp_abcdefghijABCDEFGHIJabcdefghijABCDEF';
    # Fine-grained format: github_pat_[22 chars]_[59 chars]
    # 22 chars: abcdefghijklmnopqrstuv
    # 59 chars: abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZabcdefg
    my $finegrained_pat = 'github_pat_abcdefghijklmnopqrstuv_abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZabcdefg';
    
    # Strict level should redact
    like(redact($classic_pat, level => 'strict'), qr/\[REDACTED\]/, 'Classic PAT redacted at strict');
    like(redact($finegrained_pat, level => 'strict'), qr/\[REDACTED\]/, 'Fine-grained PAT redacted at strict');
    
    # api_permissive should allow
    is(redact($classic_pat, level => 'api_permissive'), $classic_pat, 'Classic PAT allowed at api_permissive');
    is(redact($finegrained_pat, level => 'api_permissive'), $finegrained_pat, 'Fine-grained PAT allowed at api_permissive');
};

subtest 'PII patterns' => sub {
    my $ssn = '123-45-6789';
    my $email = 'user@domain.com';
    my $phone = '(555) 123-4567';
    my $cc = '4111-1111-1111-1111';
    
    # Even api_permissive should redact PII
    like(redact("SSN: $ssn", level => 'api_permissive'), qr/\[REDACTED\]/, 'SSN redacted at api_permissive');
    like(redact("Email: $email", level => 'api_permissive'), qr/\[REDACTED\]/, 'Email redacted at api_permissive');
    like(redact("Phone: $phone", level => 'api_permissive'), qr/\[REDACTED\]/, 'Phone redacted at api_permissive');
    like(redact("Card: $cc", level => 'api_permissive'), qr/\[REDACTED\]/, 'Credit card redacted at api_permissive');
    
    # Off should allow everything
    unlike(redact("SSN: $ssn", level => 'off'), qr/\[REDACTED\]/, 'SSN allowed at off');
};

subtest 'Phone number edge case in API keys' => sub {
    # A token with 10-digit sequence SHOULD be redacted at api_permissive because
    # the PII phone pattern matches the digits inside
    # This is expected behavior - PII protection takes precedence
    my $token_with_digits = 'ghp_1234567890abcdefghijklmnopqrstuvwxyz';
    my $result = redact($token_with_digits, level => 'api_permissive');
    like($result, qr/\[REDACTED\]/, 
        'Token containing phone-like digits is partially redacted (PII protection)');
    
    # At 'off' level, nothing should be redacted
    is(redact($token_with_digits, level => 'off'), $token_with_digits,
        'Token with digits allowed at off level');
};

subtest 'Database connection strings with embedded PII' => sub {
    # Connection strings with user@host will trigger email pattern
    # This is somewhat expected - email-like patterns in URLs
    my $pg_conn = 'postgres://user:password@db.example.com/mydb';
    
    # At strict level, should be redacted (by crypto pattern)
    like(redact($pg_conn, level => 'strict'), qr/\[REDACTED\]/, 
        'Postgres connection redacted at strict');
    
    # At pii level, the user@db.example.com triggers email pattern
    # This is a known limitation - PII patterns can match in URLs
    my $pii_result = redact($pg_conn, level => 'pii');
    like($pii_result, qr/\[REDACTED\]/, 
        'Postgres connection partially redacted at pii (email pattern matches user@host)');
};

subtest 'Multi-line PEM private key redaction' => sub {
    my $pem_key = q{
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDZ
abc123def456789ghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQR
more key data here xyz123
-----END PRIVATE KEY-----
};

    # At strict level, entire block should be redacted
    my $strict_result = redact($pem_key, level => 'strict');
    like($strict_result, qr/\[REDACTED\]/, 'PEM key block redacted at strict');
    unlike($strict_result, qr/BEGIN PRIVATE KEY/, 'BEGIN line removed');
    unlike($strict_result, qr/END PRIVATE KEY/, 'END line removed');
    unlike($strict_result, qr/MIIEvQ/, 'Key body removed');
    
    # At pii level, key should NOT be redacted (crypto is not in pii level)
    my $pii_result = redact($pem_key, level => 'pii');
    like($pii_result, qr/BEGIN PRIVATE KEY/, 'PEM key NOT redacted at pii level');
    
    # At api_permissive, crypto IS redacted (only API keys/tokens allowed)
    my $permissive_result = redact($pem_key, level => 'api_permissive');
    like($permissive_result, qr/\[REDACTED\]/, 'PEM key redacted at api_permissive');
};

done_testing();
