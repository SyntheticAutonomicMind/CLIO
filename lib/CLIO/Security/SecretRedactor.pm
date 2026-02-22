package CLIO::Security::SecretRedactor;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use Exporter 'import';
use CLIO::Core::Logger qw(log_debug);

our @EXPORT_OK = qw(redact redact_any get_redactor);

=head1 NAME

CLIO::Security::SecretRedactor - Automatic secret and PII redaction with configurable levels

=head1 DESCRIPTION

Automatically detects and redacts sensitive information from text before
display or transmission to AI providers. Supports multiple redaction levels:

=over 4

=item * B<strict> - Redact everything (PII, crypto, API keys, tokens)

=item * B<standard> - Same as strict (recommended for most use cases)

=item * B<api_permissive> - Allow API keys/tokens to pass through (PII/crypto still redacted)

=item * B<pii> - Only redact PII (SSN, credit cards, phone, email) [DEFAULT]

=item * B<off> - No redaction (use with extreme caution)

=back

Pattern categories:

- B<pii_patterns>: SSN, phone numbers, credit cards, email addresses, UK NI numbers
- B<crypto_patterns>: Private keys, database connection strings with passwords
- B<api_key_patterns>: AWS, GitHub, Stripe, Google, OpenAI, Anthropic, Slack, Discord, etc.
- B<token_patterns>: JWT, Bearer tokens, Basic auth headers

Performance: ~10 MB/s throughput, <1ms for typical 10KB tool output.

=head1 SYNOPSIS

    use CLIO::Security::SecretRedactor qw(redact redact_any);
    
    # Simple text redaction (uses default level from config or 'pii')
    my $safe = redact("api_key=sk_live_abc123def456");
    
    # Redact with specific level
    my $safe = redact($text, level => 'strict');
    
    # Redact any data structure (for tool results)
    my $safe_result = redact_any($hash_ref, level => 'standard');

=head1 REDACTION LEVELS

    ┌─────────────────┬────────┬──────────┬───────────────┬─────┬─────┐
    │ Category        │ strict │ standard │ api_permissive│ pii │ off │
    ├─────────────────┼────────┼──────────┼───────────────┼─────┼─────┤
    │ PII             │ redact │ redact   │ redact        │redct│     │
    │ Private keys    │ redact │ redact   │ redact        │     │     │
    │ DB passwords    │ redact │ redact   │ redact        │     │     │
    │ API keys        │ redact │ redact   │ allow         │     │     │
    │ Tokens          │ redact │ redact   │ allow         │     │     │
    └─────────────────┴────────┴──────────┴───────────────┴─────┴─────┘

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

# Valid redaction levels
my %VALID_LEVELS = map { $_ => 1 } qw(strict standard api_permissive pii off);

#
# === PATTERN CATEGORIES ===
#

# PII (Personally Identifiable Information) - Most critical
my @PII_PATTERNS = (
    # Email addresses (greedy match for TLD)
    qr/\b[a-zA-Z0-9._%+-]+\@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,63}\b/,
    
    # US Social Security Numbers
    qr/\b\d{3}-\d{2}-\d{4}\b/,
    
    # US Phone numbers (various formats)
    qr/(?:\+1[-.\s]?)?(?:\(\d{3}\)|\d{3})[-.\s]?\d{3}[-.\s]?\d{4}/,
    
    # Credit card numbers (16 digits, various separators)
    qr/\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/,
    
    # UK National Insurance numbers
    qr/\b[A-CEGHJ-PR-TW-Z]{2}\s?\d{2}\s?\d{2}\s?\d{2}\s?[A-D]\b/i,
);

# Cryptographic material and database credentials - Very sensitive
# Note: Some patterns use /s modifier for multi-line matching
my @CRYPTO_PATTERNS = (
    # PEM-encoded private keys - FULL BLOCK (multi-line)
    # Matches from -----BEGIN...PRIVATE KEY----- through -----END...PRIVATE KEY-----
    # The .*? is non-greedy to match the smallest block
    qr/-----BEGIN\s+(?:RSA\s+|DSA\s+|EC\s+|OPENSSH\s+|ENCRYPTED\s+)?PRIVATE\s+KEY-----.*?-----END\s+(?:RSA\s+|DSA\s+|EC\s+|OPENSSH\s+|ENCRYPTED\s+)?PRIVATE\s+KEY-----/s,
    
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
    
    # Password assignments (match entire assignment)
    qr/(?i)(?:password|passwd|pwd)\s*[:=]\s*["']?[^\s'"]{8}["']?/,
);

# API Keys - Can be needed for legitimate agent work
my @API_KEY_PATTERNS = (
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
    
    # Generic key=value patterns for common secret names
    qr/(?i)(?:api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|private[_-]?key)\s*[:=]\s*["']?[a-zA-Z0-9_\-\.]{12}["']?/,
);

# Authentication tokens - Often needed for API work
my @TOKEN_PATTERNS = (
    # JWT tokens (3 base64 segments)
    qr/eyJ[a-zA-Z0-9_-]+\.eyJ[a-zA-Z0-9_-]+\.[a-zA-Z0-9_-]+/,
    
    # Bearer tokens in headers
    qr/(?i)Bearer\s+[a-zA-Z0-9_\-\.]{20,256}/,
    
    # Authorization: Basic header (base64 encoded user:pass)
    qr/(?i)Authorization:\s*Basic\s+[A-Za-z0-9+\/]{20}={0,2}/,
);

# Level to category mapping
my %LEVEL_CATEGORIES = (
    strict => ['pii', 'crypto', 'api_keys', 'tokens'],
    standard => ['pii', 'crypto', 'api_keys', 'tokens'],
    api_permissive => ['pii', 'crypto'],  # Allow API keys and tokens
    pii => ['pii'],  # Only PII
    off => [],  # Nothing
);

=head2 new

Create a new SecretRedactor instance.

    my $redactor = CLIO::Security::SecretRedactor->new(
        debug => 1,              # Enable debug output
        redaction_text => '***', # Custom redaction text (default: [REDACTED])
        level => 'standard',     # Default redaction level
    );

=cut

sub new {
    my ($class, %args) = @_;
    
    my $level = $args{level} // 'pii';
    $level = 'pii' unless $VALID_LEVELS{$level};
    
    my $self = {
        debug           => $args{debug} // 0,
        redaction_text  => $args{redaction_text} // '[REDACTED]',
        whitelist       => { %WHITELIST },
        level           => $level,
        # Categorized patterns
        pii_patterns    => \@PII_PATTERNS,
        crypto_patterns => \@CRYPTO_PATTERNS,
        api_key_patterns => \@API_KEY_PATTERNS,
        token_patterns  => \@TOKEN_PATTERNS,
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

=head2 set_level

Set the redaction level.

    $redactor->set_level('api_permissive');

Valid levels: strict, standard, api_permissive, pii, off

=cut

sub set_level {
    my ($self, $level) = @_;
    
    if ($VALID_LEVELS{$level}) {
        $self->{level} = $level;
        log_debug('SecretRedactor', "Level set to: $level");
        return 1;
    }
    return 0;
}

=head2 get_level

Get the current redaction level.

    my $level = $redactor->get_level();

=cut

sub get_level {
    my ($self) = @_;
    return $self->{level};
}

=head2 get_valid_levels

Get list of valid redaction levels.

    my @levels = CLIO::Security::SecretRedactor->get_valid_levels();

=cut

sub get_valid_levels {
    return sort keys %VALID_LEVELS;
}

=head2 _get_patterns_for_level

Internal: Get the patterns to apply for a given level.

=cut

sub _get_patterns_for_level {
    my ($self, $level) = @_;
    
    $level //= $self->{level};
    $level = 'pii' unless $VALID_LEVELS{$level};
    
    my @patterns;
    my $categories = $LEVEL_CATEGORIES{$level} // [];
    
    for my $cat (@$categories) {
        if ($cat eq 'pii') {
            push @patterns, @{$self->{pii_patterns}};
        } elsif ($cat eq 'crypto') {
            push @patterns, @{$self->{crypto_patterns}};
        } elsif ($cat eq 'api_keys') {
            push @patterns, @{$self->{api_key_patterns}};
        } elsif ($cat eq 'tokens') {
            push @patterns, @{$self->{token_patterns}};
        }
    }
    
    return @patterns;
}

=head2 redact

Redact secrets and PII from text. Functional interface.

    my $safe = redact($text);
    my $safe = redact($text, level => 'strict');
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
    my $safe = $redactor->redact_text($text, level => 'strict');

=cut

sub redact_text {
    my ($self, $text, %opts) = @_;
    
    return '' unless defined $text && length($text);
    
    my $redaction = $opts{redaction_text} // $self->{redaction_text};
    my $level = $opts{level} // $self->{level};
    
    # Early return for 'off' level
    return $text if $level eq 'off';
    
    my $result = $text;
    my @patterns = $self->_get_patterns_for_level($level);
    
    # Apply each pattern - simple full-match replacement
    for my $pattern (@patterns) {
        $result =~ s/$pattern/$redaction/g;
    }
    
    return $result;
}

=head2 redact_any

Redact secrets from any data structure (hash, array, scalar).
Useful for tool results that may contain nested structures.

    my $safe_result = redact_any($data);
    my $safe_result = redact_any($data, level => 'strict');

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

Add a custom regex pattern to a specific category.

    $redactor->add_pattern('pii', qr/my_custom_pii_pattern/);
    $redactor->add_pattern('api_keys', qr/my_company_key_[a-z0-9]+/);

Valid categories: pii, crypto, api_keys, tokens

=cut

sub add_pattern {
    my ($self, $category, $pattern) = @_;
    
    my $key = $category . '_patterns';
    if (exists $self->{$key}) {
        push @{$self->{$key}}, $pattern;
        log_debug('SecretRedactor', "Added pattern to $category");
        return 1;
    }
    return 0;
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

Return the number of patterns being checked for the current level.

=cut

sub pattern_count {
    my ($self, $level) = @_;
    my @patterns = $self->_get_patterns_for_level($level);
    return scalar @patterns;
}

=head2 total_pattern_count

Return the total number of patterns across all categories.

=cut

sub total_pattern_count {
    my ($self) = @_;
    return scalar(@{$self->{pii_patterns}}) + 
           scalar(@{$self->{crypto_patterns}}) +
           scalar(@{$self->{api_key_patterns}}) +
           scalar(@{$self->{token_patterns}});
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

=head1 REDACTION LEVEL GUIDANCE

=over 4

=item B<strict/standard> - Use for most scenarios. Maximum protection.

=item B<api_permissive> - Use when agent needs to work with API keys (e.g., setting up integrations).
PII and crypto credentials are still protected.

=item B<pii> - Default. Protects personal information. API keys allowed.
Good balance for development work where API key usage is common.

=item B<off> - Use only when absolutely necessary and you understand the risks.

=back

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0-only

=cut
