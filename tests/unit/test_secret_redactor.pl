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
ok($redactor->pattern_count() > 20, 'Has 20+ patterns loaded');

#
# === API KEYS ===
#

subtest 'AWS Keys' => sub {
    # AWS Access Key ID
    my $text = "aws_access_key_id = AKIAIOSFODNN7EXAMPLE";
    my $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'AWS access key ID redacted');
    unlike($result, qr/AKIAIOSFODNN7EXAMPLE/, 'No AWS key in output');
    
    # AWS Secret
    $text = "aws_secret_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY";
    $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'AWS secret key redacted');
};

subtest 'GitHub Tokens' => sub {
    my $text = "GITHUB_TOKEN=ghp_1234567890abcdefghijklmnopqrstuvwxyz";
    my $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'GitHub personal token redacted');
    
    $text = "gho_1234567890abcdefghijklmnopqrstuvwxyz";
    $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'GitHub OAuth token redacted');
};

subtest 'Stripe Keys' => sub {
    # Use obviously fake keys - pattern expects sk_(live|test)_[24 chars]
    my $text = "stripe_key: sk_test_FAKE1234567890123456";
    my $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'Stripe live key redacted');
    
    $text = "pk_test_FAKE1234567890123456";
    $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'Stripe test key redacted');
};

subtest 'Google API Keys' => sub {
    my $text = "apiKey: AIzaSyDaGmWKa4JsXZ-HjGw7ISLn_3namBGewQe";
    my $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'Google API key redacted');
};

subtest 'OpenAI Keys' => sub {
    my $text = "OPENAI_API_KEY=sk-proj-1234567890abcdefghijklmnopqrstuvwxyz1234567890abcdefghijklmnop";
    my $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'OpenAI project key redacted');
};

#
# === AUTHENTICATION TOKENS ===
#

subtest 'JWT Tokens' => sub {
    my $jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c";
    my $text = "token: $jwt";
    my $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'JWT token redacted');
    unlike($result, qr/eyJ/, 'No JWT in output');
};

subtest 'Bearer Tokens' => sub {
    my $text = "Authorization: Bearer 1234567890abcdefghijklmnopqrstuvwxyz";
    my $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'Bearer token redacted');
};

#
# === DATABASE CONNECTIONS ===
#

subtest 'Database URLs' => sub {
    my $text = "DATABASE_URL=postgres://user:supersecretpassword\@localhost:5432/mydb";
    my $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'Postgres URL with password redacted');
    unlike($result, qr/supersecretpassword/, 'No password in output');
    
    $text = "mongodb://admin:password123\@cluster.mongodb.net/db";
    $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'MongoDB URL redacted');
    
    $text = "redis://:myredispassword\@localhost:6379";
    $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'Redis URL redacted');
};

#
# === CRYPTOGRAPHIC MATERIAL ===
#

subtest 'Private Keys' => sub {
    my $text = <<'EOF';
-----BEGIN RSA PRIVATE KEY-----
MIIEowIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyf8E
-----END RSA PRIVATE KEY-----
EOF
    my $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'RSA private key marker redacted');
    
    $text = "-----BEGIN PRIVATE KEY-----";
    $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'Generic private key marker redacted');
};

#
# === PII ===
#

subtest 'Email Addresses' => sub {
    my $text = "Contact: john.doe\@example.com for more info";
    my $result = redact($text);
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
    $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'International phone redacted');
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
# === GENERIC PATTERNS ===
#

subtest 'Generic Secrets' => sub {
    my $text = "api_key: mysupersecretapikey123";
    my $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'Generic api_key redacted');
    
    $text = "password=verysecretpassword";
    $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'Password redacted');
    
    $text = "auth_token: abc123def456ghi789";
    $result = redact($text);
    like($result, qr/\[REDACTED\]/, 'Auth token redacted');
};

#
# === WHITELIST ===
#

subtest 'Whitelist' => sub {
    # Test that safe values are not redacted
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
            api_key => "sk_test_FAKE1234567890123456",
            name => "Test Config",
        },
        users => [
            { email => "user\@example.com", role => "admin" },
            { email => "test\@test.com", role => "user" },
        ],
    };
    
    my $safe = redact_any($data);
    
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
    
    # Multiple secrets in same string
    $text = "api_key=mysupersecretkey123 and email=user\@test.com";
    my $result = redact($text);
    my @matches = $result =~ /\[REDACTED\]/g;
    ok(scalar(@matches) >= 2, 'Multiple secrets redacted (got ' . scalar(@matches) . ')');
};

done_testing();
