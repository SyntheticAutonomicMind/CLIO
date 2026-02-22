#!/usr/bin/env perl

# Unit tests for CLIO::Security::SecretRedactor

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/../../lib";
use Test::More;

use_ok('CLIO::Security::SecretRedactor', qw(redact redact_any get_redactor));

# Test basic functionality
my $redactor = get_redactor();
isa_ok($redactor, 'CLIO::Security::SecretRedactor');
ok($redactor->total_pattern_count() > 20, 'Has 20+ total patterns loaded (count=' . $redactor->total_pattern_count() . ')');

#
# === API KEYS (require strict/standard level) ===
#

subtest 'AWS Keys' => sub {
    # AWS Access Key ID
    my $text = "aws_access_key_id = AKIAIOSFODNN7EXAMPLE";
    my $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'AWS access key ID redacted (strict)');
    unlike($result, qr/AKIAIOSFODNN7EXAMPLE/, 'No AWS key in output');
    
    # AWS Secret
    $text = "aws_secret_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
    $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'AWS secret key redacted (strict)');
};

subtest 'GitHub Tokens' => sub {
    my $text = "GITHUB_TOKEN=ghp_ABCDEFabcdefghijklmnopqrstuvwxyz1234";
    my $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'GitHub personal token redacted');
    
    $text = "gho_ABCDEFabcdefghijklmnopqrstuvwxyz1234";
    $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'GitHub OAuth token redacted');
};

subtest 'Stripe Keys' => sub {
    # Use generated test keys - exactly 24 alphanumeric chars after prefix
    # Note: These are NOT real keys - format matches our redaction regex
    my $stripe_suffix = 'X' x 24;  # Generate safe test pattern
    my $text = "stripe_key: sk_test_${stripe_suffix}";
    my $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'Stripe secret key redacted');
    
    $text = "pk_test_${stripe_suffix}";
    $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'Stripe publishable key redacted');
};

subtest 'Google API Keys' => sub {
    my $text = "apiKey: AIzaSyDaGmWKa4JsXZ-HjGw7ISLn_3namBGewQe";
    my $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'Google API key redacted');
};

subtest 'OpenAI Keys' => sub {
    my $text = "OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz1234567890abcdefghijklmn";
    my $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'OpenAI key redacted');
};

#
# === AUTHENTICATION TOKENS (require strict/standard level) ===
#

subtest 'JWT Tokens' => sub {
    my $jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
    my $text = "token: $jwt";
    my $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'JWT token redacted');
    unlike($result, qr/eyJ/, 'No JWT in output');
};

subtest 'Bearer Tokens' => sub {
    my $text = "Authorization: Bearer abcdefghijklmnopqrstuvwxyz12345678";
    my $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'Bearer token redacted');
};

#
# === DATABASE CONNECTIONS (require strict/standard level) ===
#

subtest 'Database URLs' => sub {
    my $text = "DATABASE_URL=postgres://user:supersecretpassword\@localhost:5432/mydb";
    my $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'Postgres URL with password redacted');
    unlike($result, qr/supersecretpassword/, 'No password in output');
    
    $text = "mongodb://admin:password123\@cluster.mongodb.net/db";
    $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'MongoDB URL redacted');
    
    $text = "redis://:myredispassword\@localhost:6379";
    $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'Redis URL redacted');
};

#
# === CRYPTOGRAPHIC MATERIAL (require strict/standard level) ===
#

subtest 'Private Keys' => sub {
    my $text = <<'EOF';
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyf8E
-----END RSA PRIVATE KEY-----
EOF
    my $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'RSA private key marker redacted');
    
    $text = "-----BEGIN PRIVATE KEY-----\nSomeKeyData\n-----END PRIVATE KEY-----";
    $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'Generic private key marker redacted');
};

#
# === PII (works with default 'pii' level) ===
#

subtest 'Email Addresses' => sub {
    my $text = "Contact: john.doe\@example.com for more info";
    my $result = redact($text);  # Default level (pii)
    like($result, qr/\[REDACTED\]/, 'Email address redacted');
    unlike($result, qr/john\.doe/, 'No email in output');
};

subtest 'SSN' => sub {
    my $text = "SSN: 123-45-6789";
    my $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'SSN redacted');
    unlike($result, qr/123-45-6789/, 'No SSN in output');
};

subtest 'Phone Numbers' => sub {
    my $text = "Call me at (555) 123-4567";
    my $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'Phone number redacted');
    
    $text = "Mobile: +1-555-123-4567";
    my $result2 = redact($text);
    like($result2, qr/\[REDACTED\]/, 'International phone redacted');
};

subtest 'Credit Cards' => sub {
    my $text = "Card: 4111-1111-1111-1111";
    my $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'Credit card redacted');
    
    $text = "cc: 4111111111111111";
    $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'Credit card (no separators) redacted');
};

#
# === GENERIC PATTERNS (require strict/standard level) ===
#

subtest 'Generic Secrets' => sub {
    my $text = "api_key: mysupersecretapikey123";
    my $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'Generic api_key redacted');
    
    $text = "password=verysecretpassword";
    $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'Password redacted');
    
    $text = "auth_token: abc123def456ghi789";
    $result = redact($text, level => 'strict');
    like($result, qr/\[REDACTED\]/, 'Auth token redacted');
};

#
# === WHITELIST ===
#

subtest 'Whitelist' => sub {
    my $text = "environment: localhost";
    my $result = redact($text);
    like($result, qr/localhost/, 'Localhost not redacted');
    
    $text = "value: test";
    $result = redact($text);
    like($result, qr/test/, 'Test value not redacted');
};

#
# === DATA STRUCTURES ===
#

subtest 'Nested Structures' => sub {
    my $data = {
        config => {
            api_key => "sk_test_" . ('X' x 24),
            name => "Test Config",
        },
        users => [
            { email => "user\@example.com", role => "admin" },
            { email => "test\@test.com", role => "user" },
        ],
    };
    
    # Use strict level so api_key pattern matches
    my $safe = redact_any($data, level => 'strict');
    
    like($safe->{config}{api_key}, qr/\[REDACTED\]/, 'Nested api_key redacted');
    like($safe->{users}[0]{email}, qr/\[REDACTED\]/, 'Array email redacted');
    is($safe->{config}{name}, "Test Config", 'Non-secret preserved');
};

#
# === PERFORMANCE ===
#

subtest 'Performance' => sub {
    my $large_text = "Normal text without secrets. " x 1000;  # ~30KB
    
    my $start = time();
    for (1..10) {
        my $result = redact($large_text);
    }
    my $elapsed = time() - $start;
    
    ok($elapsed < 1, "30KB x 10 iterations in < 1 second (got: ${elapsed}s)");
};

#
# === EDGE CASES ===
#

subtest 'Edge Cases' => sub {
    is(redact(undef), '', 'undef returns empty string');
    is(redact(''), '', 'empty string returns empty');
    
    my $text = "Normal text without any secrets whatsoever";
    is(redact($text), $text, 'Text without secrets unchanged');
    
    # Multiple PII in same string (works at default pii level)
    $text = "SSN: 123-45-6789 and email=user\@test.com";
    my $result = redact($text);
    my @matches = $result =~ /\[REDACTED\]/g;
    ok(scalar(@matches) >= 2, 'Multiple secrets redacted (got ' . scalar(@matches) . ')');
};

#
# === LEVEL BEHAVIOR ===
#

subtest 'Level Behavior' => sub {
    # Use a clearly recognizable API key format and email
    my $api_key = "AKIAIOSFODNN7EXAMPLE";
    my $text = "key=$api_key and email=user\@example.com";
    
    # pii level: only email redacted
    my $pii_result = redact($text, level => 'pii');
    like($pii_result, qr/AKIAIOSFODNN7EXAMPLE/, 'pii level: API key NOT redacted');
    like($pii_result, qr/\[REDACTED\]/, 'pii level: email IS redacted');
    
    # strict level: both redacted
    my $strict_result = redact($text, level => 'strict');
    unlike($strict_result, qr/AKIAIOSFODNN7EXAMPLE/, 'strict level: API key IS redacted');
    
    # off level: nothing redacted
    my $off_result = redact($text, level => 'off');
    like($off_result, qr/AKIAIOSFODNN7EXAMPLE/, 'off level: API key NOT redacted');
    like($off_result, qr/user\@example/, 'off level: email NOT redacted');
};

done_testing();
