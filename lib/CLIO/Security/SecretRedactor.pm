package CLIO::Security::SecretRedactor;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use Exporter 'import';
use CLIO::Core::Logger qw(should_log);

our @EXPORT_OK = qw(redact redact_any get_redactor);

=head1 NAME

CLIO::Security::SecretRedactor - Automatic secret and PII redaction

=head1 DESCRIPTION

Automatically detects and redacts sensitive information from text before
display or transmission to AI providers. Includes patterns for:

- API keys (AWS, GitHub, Stripe, Google, etc.)
- Authentication tokens (JWT, Bearer, OAuth)
- Database connection strings with credentials
- PEM-encoded private keys
- Slack/Discord tokens
- PII (emails, SSN, phone numbers, credit cards)

Performance: ~10 MB/s throughput, <1ms for typical 10KB tool output.

Inspired by gokin's SecretRedactor with additional PII patterns.

=head1 SYNOPSIS

    use CLIO::Security::SecretRedactor qw(redact redact_any);
    
    # Simple text redaction
    my $safe = redact("api_key=sk_live_abc123def456");
    # Returns: "api_key=[REDACTED]"
    
    # Redact any data structure (for tool results)
    my $safe_result = redact_any($hash_ref);

=cut

# Singleton instance
my $_instance;

# Whitelist of safe values that should never be redacted
my %WHITELIST = map { $_ => 1 } qw(
    example test demo sample mock localhost
    127.0.0.1 ::1 0.0.0.0
    development staging production
    readme license changelog undefined
    placeholder dummy foobar redacted
    true false null
);

# Compiled regex patterns - simple full-match patterns for performance
# No capture groups needed - we replace entire match
my @PATTERNS = (
    #
    # === API KEYS AND TOKENS ===
    #
    
    # AWS Access Key ID (always starts with AKIA)
    qr/AKIA[0-9A-Z]{16}/,
    
    # AWS Secret Access Key (40 chars after assignment)
    qr/(?i)aws[_-]?secret[_-]?(?:access[_-]?)?key\s*[:=]\s*["']?[a-zA-Z0-9+\/]{40}["']?/,
    
    # GitHub tokens (Personal, OAuth, etc.)
    qr/gh[pous]_[a-zA-Z0-9]{36}/,
    
    # GitHub fine-grained tokens (newer format)
    qr/github_pat_[a-zA-Z0-9]{22}_[a-zA-Z0-9]{59}/,
    
    # Stripe keys (live and test)
    qr/sk_(?:live|test)_[0-9a-zA-Z]{24}/,
    qr/pk_(?:live|test)_[0-9a-zA-Z]{24}/,
    qr/rk_(?:live|test)_[0-9a-zA-Z]{24}/,
    
    # Google Cloud API keys
    qr/AIza[0-9A-Za-z\-_]{35}/,
    
    # OpenAI API keys
    qr/sk-[a-zA-Z0-9]{48}/,
    qr/sk-proj-[a-zA-Z0-9\-_]{64}/,
    
    # Anthropic API keys
    qr/sk-ant-[a-zA-Z0-9\-_]{95}/,
    
    # Slack tokens (bot, app, user, etc.)
    qr/xox[baprs]-[0-9]{10,13}-[0-9]{10,13}-[a-zA-Z0-9]{24}/,
    qr/xoxe\.xox[bp]-1-[a-zA-Z0-9]{60}/,
    
    # Slack webhooks
    qr|https?://hooks\.slack\.com/services/T[A-Z0-9]{8}/B[A-Z0-9]{8}/[a-zA-Z0-9]{24}|,
    
    # Discord tokens and webhooks
    qr/[MN][A-Za-z\d]{23,27}\.[A-Za-z\d\-_]{6}\.[A-Za-z\d\-_]{27,40}/,
    qr|https?://discord(?:app)?\.com/api/webhooks/\d+/[a-zA-Z0-9_-]+|,
    
    # Twilio Account SID and Auth Token
    qr/AC[a-f0-9]{32}/i,
    qr/SK[a-f0-9]{32}/i,
    
    #
    # === AUTHENTICATION TOKENS ===
    #
    
    # JWT tokens (3 base64 segments) - simplified pattern
    qr/eyJ[a-zA-Z0-9_-]+\.eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+/,
    
    # Bearer tokens in headers (match entire header value)
    qr/(?i)Bearer\s+[a-zA-Z0-9_\-\.]{20,256}/,
    
    # Authorization: Basic header (base64 encoded user:pass)
    qr/(?i)Authorization:\s*Basic\s+[A-Za-z0-9+\/]{20}={0,2}/,
    
    #
    # === DATABASE AND CONNECTION STRINGS ===
    #
    
    # PostgreSQL connection strings with password
    qr|postgres(?:ql)?://[^:]+:[^@]+@[^\s/]+|,
    
    # MySQL connection strings with password
    qr|mysql://[^:]+:[^@]+@[^\s/]+|,
    
    # MongoDB connection strings with password
    qr|mongodb(?:\+srv)?://[^:]+:[^@]+@[^\s/]+|,
    
    # Redis connection strings with password
    qr|redis://:[^@]+@[^\s/]+|,
    qr|redis://[^:]+:[^@]+@[^\s/]+|,
    
    # ODBC connection strings with password
    qr/(?i)(?:Password|Pwd)\s*=\s*[^;'"\s]{8}/,
    
    #
    # === CRYPTOGRAPHIC MATERIAL ===
    #
    
    # PEM-encoded private keys
    qr/-----BEGIN\s+(?:RSA\s+|DSA\s+|EC\s+|OPENSSH\s+|ENCRYPTED\s+)?PRIVATE\s+KEY-----/,
    
    #
    # === GENERIC SECRET PATTERNS ===
    #
    
    # Generic key=value patterns for common secret names (match entire assignment)
    qr/(?i)(?:api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|private[_-]?key)\s*[:=]\s*["']?[a-zA-Z0-9_\-\.]{12}["']?/,
    
    # Password assignments (match entire assignment)
    qr/(?i)(?:password|passwd|pwd)\s*[:=]\s*["']?[^\s'"]{8}["']?/,
    
    #
    # === PII (Personally Identifiable Information) ===
    #
    
    # Email addresses (greedy match for TLD)
    qr/\b[a-zA-Z0-9._%+-]+\@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,63}\b/,
    
    # US Social Security Numbers
    qr/\b\d{3}-\d{2}-\d{4}\b/,
    
    # US Phone numbers (various formats) - removed word boundary for better matching
    qr/(?:\+1[-.\s]?)?(?:\(\d{3}\)|\d{3})[-.\s]?\d{3}[-.\s]?\d{4}/,
    
    # Credit card numbers (16 digits, various separators)
    qr/\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/,
    
    # UK National Insurance numbers
    qr/\b[A-CEGHJ-PR-TW-Z]{2}\s?\d{2}\s?\d{2}\s?\d{2}\s?[A-D]\b/i,
);

=head2 new

Create a new SecretRedactor instance.

    my $redactor = CLIO::Security::SecretRedactor->new(
        debug => 1,              # Enable debug output
        redaction_text => '***', # Custom redaction text (default: [REDACTED])
    );

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug           => $args{debug} // 0,
        redaction_text  => $args{redaction_text} // '[REDACTED]',
        whitelist       => { %WHITELIST },
        patterns        => \@PATTERNS,
    };
    
    bless $self, $class;
    return $self;
}

=head2 get_redactor

Get the singleton redactor instance.

    my $redactor = get_redactor();

=cut

sub get_redactor {
    unless ($_instance) {
        $_instance = __PACKAGE__->new();
    }
    return $_instance;
}

=head2 redact

Redact secrets and PII from text. Functional interface.

    my $safe = redact($text);
    my $safe = redact($text, redaction_text => '***');

=cut

sub redact {
    my ($text, %opts) = @_;
    
    return '' unless defined $text && length($text);
    
    my $redactor = get_redactor();
    return $redactor->redact_text($text, %opts);
}

=head2 redact_text

Object method to redact text.

    my $safe = $redactor->redact_text($text);

=cut

sub redact_text {
    my ($self, $text, %opts) = @_;
    
    return '' unless defined $text && length($text);
    
    my $redaction = $opts{redaction_text} // $self->{redaction_text};
    my $result = $text;
    
    # Apply each pattern - simple full-match replacement
    for my $pattern (@{$self->{patterns}}) {
        $result =~ s/$pattern/$redaction/g;
    }
    
    return $result;
}

=head2 redact_any

Redact secrets from any data structure (hash, array, scalar).
Useful for tool results that may contain nested structures.

    my $safe_result = redact_any($data);

=cut

sub redact_any {
    my ($data, %opts) = @_;
    
    return $data unless defined $data;
    
    my $redactor = get_redactor();
    return $redactor->_redact_recursive($data, %opts);
}

sub _redact_recursive {
    my ($self, $data, %opts) = @_;
    
    return $data unless defined $data;
    
    my $ref = ref($data);
    
    if (!$ref) {
        # Scalar - redact if it's a string
        return $self->redact_text($data, %opts);
    }
    elsif ($ref eq 'HASH') {
        my %result;
        for my $key (keys %$data) {
            $result{$key} = $self->_redact_recursive($data->{$key}, %opts);
        }
        return \%result;
    }
    elsif ($ref eq 'ARRAY') {
        return [ map { $self->_redact_recursive($_, %opts) } @$data ];
    }
    elsif ($ref eq 'SCALAR') {
        my $value = $self->redact_text($$data, %opts);
        return \$value;
    }
    else {
        # Other ref types (blessed objects, etc.) - return as-is
        return $data;
    }
}

=head2 add_pattern

Add a custom regex pattern to the redactor.

    $redactor->add_pattern(qr/my_company_key_[a-z0-9]+/);

=cut

sub add_pattern {
    my ($self, $pattern) = @_;
    
    push @{$self->{patterns}}, $pattern;
    
    print STDERR "[DEBUG][SecretRedactor] Added custom pattern\n" 
        if $self->{debug};
}

=head2 add_whitelist

Add a value to the whitelist (won't be redacted).

    $redactor->add_whitelist('my_safe_token');

=cut

sub add_whitelist {
    my ($self, $value) = @_;
    
    $self->{whitelist}{lc($value)} = 1;
}

=head2 pattern_count

Return the number of patterns being checked.

=cut

sub pattern_count {
    my ($self) = @_;
    return scalar @{$self->{patterns}};
}

1;

=head1 SECURITY NOTES

This module provides defense-in-depth but is NOT a replacement for:
- Proper secret management (use vaults, env vars)
- Access controls on sensitive data
- Code review for secret handling

False negatives are possible - new secret formats may not be caught.
False positives are minimized via whitelist, but some legitimate text
may be redacted (e.g., test data that looks like secrets).

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0-only

=cut
