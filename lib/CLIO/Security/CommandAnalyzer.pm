# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Security::CommandAnalyzer;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use CLIO::Core::Logger qw(log_debug log_info log_warning);

our @EXPORT_OK = qw(analyze_command);

=head1 NAME

CLIO::Security::CommandAnalyzer - Intent-based command security analysis

=head1 DESCRIPTION

Analyzes shell commands to classify their security intent rather than
maintaining a blocklist of specific commands. This approach recognizes
that blocking individual commands (curl, wget, etc.) is fundamentally
incomplete - an agent can always write a script that does the same thing
and execute that instead.

Instead, this module identifies B<categories of risky behavior>:

=over 4

=item * B<network_outbound> - Commands that send data to external hosts

=item * B<credential_access> - Commands that read known credential files

=item * B<system_destructive> - Commands that can destroy the system

=item * B<privilege_escalation> - Commands that escalate privileges

=back

When a risky behavior is detected, the caller decides what to do:
prompt the user, block the command, or allow it based on security level.

This module does NOT block commands. It classifies them. The enforcement
decision belongs to the caller (TerminalOperations, WorkflowOrchestrator).

=head1 SYNOPSIS

    use CLIO::Security::CommandAnalyzer qw(analyze_command);

    my $analysis = analyze_command($command_string);

    if ($analysis->{risk_level} eq 'high') {
        # Prompt user for confirmation
        for my $flag (@{$analysis->{flags}}) {
            print "Warning: $flag->{category} - $flag->{description}\n";
        }
    }

=cut

# ---------------------------------------------------------------------------
# Network outbound detection
# ---------------------------------------------------------------------------
# Commands and patterns that indicate outbound network activity.
# We check the FULL command (including pipe targets, subshells, etc.)
# because data exfiltration typically happens via pipes or redirects.

my @NETWORK_COMMANDS = qw(
    curl wget nc ncat netcat socat nmap telnet
    ssh scp sftp rsync
    ftp lftp tftp
    sendmail mail mutt
);

# Interpreter patterns that might do network I/O
# These are checked with their import/module patterns
my @NETWORK_INTERPRETER_PATTERNS = (
    # Python network modules
    qr/python[23]?\s+.*(?:urllib|requests|http\.client|socket|paramiko|ftplib|smtplib)/i,
    qr/python[23]?\s+-c\s+.*(?:urllib|requests|http\.client|socket|urlopen|urlretrieve)/i,

    # Perl network modules
    qr/perl\s+.*(?:LWP|HTTP::Tiny|IO::Socket|Net::FTP|Net::SMTP|Net::SSH)/i,
    qr/perl\s+-[eE]\s+.*(?:LWP|HTTP::Tiny|IO::Socket|Net::|socket)/i,

    # Ruby network
    qr/ruby\s+.*(?:net\/http|open-uri|socket|net\/ftp|net\/smtp)/i,
    qr/ruby\s+-e\s+.*(?:Net::HTTP|open-uri|TCPSocket|Net::FTP)/i,

    # Node.js network
    qr/node\s+.*(?:http|https|net|dgram|fetch|axios|request)/i,
    qr/node\s+-e\s+.*(?:require\(['"](?:http|https|net|dgram)|fetch\()/i,

    # PHP network
    qr/php\s+.*(?:curl_exec|file_get_contents\s*\(\s*['"]https?|fsockopen|ftp_connect)/i,

    # Go network (less common but possible)
    qr/go\s+run\s+.*(?:net\/http|net\.Dial)/i,
);

# DNS exfiltration (encoding data in DNS queries)
my @DNS_EXFIL_PATTERNS = (
    qr/dig\s+.*\.\S+\.\S+/,          # dig with subdomain patterns
    qr/nslookup\s+.*\.\S+\.\S+/,      # nslookup with subdomain patterns
    qr/host\s+.*\.\S+\.\S+/,          # host command with subdomains
);

# ---------------------------------------------------------------------------
# Credential access detection
# ---------------------------------------------------------------------------
# Paths where credentials are commonly stored.
# We check if commands READ from these paths.

my @CREDENTIAL_PATHS = (
    # SSH
    qr{~/\.ssh/(?:id_\w+|authorized_keys|config|known_hosts)},
    qr{\$HOME/\.ssh/},
    qr{/home/[^/]+/\.ssh/},
    qr{/root/\.ssh/},

    # AWS
    qr{~/\.aws/(?:credentials|config)},
    qr{\$HOME/\.aws/},
    qr{/home/[^/]+/\.aws/},

    # GCP
    qr{~/\.config/gcloud/},
    qr{application_default_credentials\.json},

    # Azure
    qr{~/\.azure/},

    # Kubernetes
    qr{~/\.kube/config},
    qr{/etc/kubernetes/},

    # Docker
    qr{~/\.docker/config\.json},

    # GPG
    qr{~/\.gnupg/},
    qr{\$HOME/\.gnupg/},

    # Git credentials
    qr{~/\.git-credentials},
    qr{~/\.netrc},

    # npm/yarn tokens
    qr{~/\.npmrc},
    qr{~/\.yarnrc},

    # System credentials
    qr{/etc/shadow},
    qr{/etc/master\.passwd},

    # Environment with secrets (printenv, env can expose API keys)
    # These are checked separately as they expose ALL env vars
);

# Commands that dump environment variables (may contain API keys, tokens)
my @ENV_DUMP_COMMANDS = qw(
    printenv env
);

# ---------------------------------------------------------------------------
# System destructive detection
# ---------------------------------------------------------------------------

my @DESTRUCTIVE_PATTERNS = (
    qr/\brm\s+(-[a-zA-Z]*r[a-zA-Z]*f|--recursive\s+--force|-[a-zA-Z]*f[a-zA-Z]*r)\b/,  # rm -rf variants
    qr/\brm\s+(-[a-zA-Z]*r[a-zA-Z]*)\s+\//,  # rm -r / (recursive on root or system paths)
    qr/\bsudo\s+rm\b/,                         # sudo rm anything
    qr/\bdd\s+.*\bif=/,                        # dd (raw disk write)
    qr/\bmkfs\b/,                               # mkfs (format filesystem)
    qr/\bfdisk\b/,                              # fdisk (partition table)
    qr/\bparted\b/,                             # parted
    qr/\bshutdown\b/,                           # shutdown
    qr/\breboot\b/,                             # reboot
    qr/\bhalt\b/,                               # halt
    qr/\binit\s+[06]\b/,                        # init 0/6
    qr/\bsystemctl\s+(?:poweroff|reboot|halt)\b/,
    qr/:\(\)\s*\{\s*:\|:\s*&\s*\}\s*;?\s*:/,   # fork bomb :(){ :|:& };:
    qr/>\s*\/dev\/[sh]d[a-z]/,                  # write to raw block device
    qr/\bchmod\s+(-[a-zA-Z]*R|-[a-zA-Z]*r)\s+[0-7]*\s+\//,  # recursive chmod on /
    qr/\bchown\s+(-[a-zA-Z]*R|-[a-zA-Z]*r)\s+\S+\s+\//,     # recursive chown on /
);

# ---------------------------------------------------------------------------
# Privilege escalation detection
# ---------------------------------------------------------------------------

my @PRIVILEGE_PATTERNS = (
    qr/\bsudo\b/,                               # sudo anything
    qr/\bsu\s+(-\s+)?root\b/,                   # su root
    qr/\bsu\s+-\s*$/,                            # su - (become root)
    qr/\bdoas\b/,                                # doas (OpenBSD sudo)
    qr/\bpkexec\b/,                              # polkit exec
    qr/\bchmod\s+[u+]*s\b/,                      # setuid
);

# ---------------------------------------------------------------------------
# Main analysis function
# ---------------------------------------------------------------------------

=head2 analyze_command($command, %opts)

Analyze a shell command for security-relevant behavior.

Arguments:
- $command: The full shell command string
- %opts:
  - sandbox: If true, applies stricter analysis
  - security_level: 'relaxed', 'standard', or 'strict'

Returns hashref:
  {
    command     => $original_command,
    risk_level  => 'none' | 'low' | 'medium' | 'high' | 'critical',
    flags       => [
      {
        category    => 'network_outbound' | 'credential_access' | 'system_destructive' | 'privilege_escalation',
        severity    => 'low' | 'medium' | 'high' | 'critical',
        description => 'Human-readable explanation',
        details     => 'Specific match details',
      },
      ...
    ],
    requires_confirmation => 0 | 1,
    blocked     => 0 | 1,  # Advisory flag for critical/destructive commands (user still gets prompted)
    summary     => 'Brief text summary of findings',
  }

Note: The C<blocked> flag indicates the command is classified as critical risk.
The consuming tool (TerminalOperations) prompts the user with elevated warnings
but the user always has final say. Critical commands cannot be session-granted.

=cut

sub analyze_command {
    my ($command, %opts) = @_;

    my $sandbox = $opts{sandbox} || 0;
    my $security_level = $opts{security_level} || 'standard';

    my @flags;

    # --- Network outbound ---
    _check_network_outbound($command, \@flags);

    # --- Credential access ---
    _check_credential_access($command, \@flags);

    # --- System destructive ---
    _check_destructive($command, \@flags);

    # --- Privilege escalation ---
    _check_privilege_escalation($command, \@flags);

    # --- Compute overall risk ---
    my $risk_level = _compute_risk_level(\@flags);

    # --- Determine enforcement ---
    my $requires_confirmation = 0;
    my $blocked = 0;

    if ($security_level eq 'strict') {
        # Strict: confirm medium+, block critical
        $requires_confirmation = 1 if $risk_level =~ /^(medium|high|critical)$/;
        $blocked = 1 if $risk_level eq 'critical';
    } elsif ($security_level eq 'standard') {
        # Standard: confirm high+, block critical
        $requires_confirmation = 1 if $risk_level =~ /^(high|critical)$/;
        $blocked = 1 if $risk_level eq 'critical';
    } else {
        # Relaxed: only block critical (system destructive)
        $blocked = 1 if $risk_level eq 'critical';
    }

    # Sandbox mode escalates everything
    if ($sandbox) {
        $requires_confirmation = 1 if $risk_level =~ /^(low|medium|high)$/;
        $blocked = 1 if $risk_level eq 'critical';
    }

    # Build summary
    my $summary = '';
    if (@flags) {
        my @categories = _unique_categories(\@flags);
        $summary = "Detected: " . join(', ', @categories);
    }

    my $result = {
        command               => $command,
        risk_level            => $risk_level,
        flags                 => \@flags,
        requires_confirmation => $requires_confirmation,
        blocked               => $blocked,
        summary               => $summary,
    };

    if (@flags) {
        log_debug('CommandAnalyzer', "Command risk=$risk_level flags=" . scalar(@flags) . " summary='$summary'");
    }

    return $result;
}

# ---------------------------------------------------------------------------
# Detection helpers
# ---------------------------------------------------------------------------

sub _check_network_outbound {
    my ($command, $flags) = @_;

    # Check for known network commands anywhere in the command
    # (not just at the start - they can appear after pipes, &&, etc.)
    for my $cmd (@NETWORK_COMMANDS) {
        # Word boundary match - the command name must be a distinct word
        if ($command =~ /\b\Q$cmd\E\b/i) {
            # Determine severity based on command type
            my $severity = 'medium';
            my $desc;

            if ($cmd =~ /^(curl|wget|nc|ncat|netcat|socat)$/) {
                $severity = 'high';
                $desc = "Outbound data transfer command '$cmd' detected";
            } elsif ($cmd =~ /^(ssh|scp|sftp|rsync)$/) {
                $severity = 'medium';
                $desc = "Remote access command '$cmd' detected";
            } elsif ($cmd =~ /^(sendmail|mail|mutt)$/) {
                $severity = 'high';
                $desc = "Email sending command '$cmd' detected";
            } else {
                $desc = "Network command '$cmd' detected";
            }

            push @$flags, {
                category    => 'network_outbound',
                severity    => $severity,
                description => $desc,
                details     => "Matched command: $cmd",
            };

            last;  # One network flag per command is enough
        }
    }

    # Check interpreter patterns (python with urllib, etc.)
    for my $pattern (@NETWORK_INTERPRETER_PATTERNS) {
        if ($command =~ $pattern) {
            push @$flags, {
                category    => 'network_outbound',
                severity    => 'high',
                description => 'Script interpreter with network library detected',
                details     => "Matched pattern in command",
            };
            last;
        }
    }

    # Check DNS exfiltration patterns
    for my $pattern (@DNS_EXFIL_PATTERNS) {
        if ($command =~ $pattern) {
            push @$flags, {
                category    => 'network_outbound',
                severity    => 'medium',
                description => 'DNS query with subdomain pattern (potential data exfiltration)',
                details     => "Matched DNS exfiltration pattern",
            };
            last;
        }
    }
}

sub _check_credential_access {
    my ($command, $flags) = @_;

    # Check for reads of known credential paths
    for my $pattern (@CREDENTIAL_PATHS) {
        if ($command =~ $pattern) {
            my $matched = $&;
            push @$flags, {
                category    => 'credential_access',
                severity    => 'high',
                description => 'Access to credential file detected',
                details     => "Path pattern: $matched",
            };
            last;  # One credential flag is enough
        }
    }

    # Check for environment variable dumps
    for my $cmd (@ENV_DUMP_COMMANDS) {
        # Only flag standalone env/printenv (not as part of another word like "environment")
        if ($command =~ /(?:^|\s|;|&&|\|\|)\Q$cmd\E(?:\s|$|;|&&|\|\||\|)/) {
            push @$flags, {
                category    => 'credential_access',
                severity    => 'medium',
                description => "Environment dump command '$cmd' (may expose API keys and tokens)",
                details     => "Matched command: $cmd",
            };
            last;
        }
    }
}

sub _check_destructive {
    my ($command, $flags) = @_;

    for my $pattern (@DESTRUCTIVE_PATTERNS) {
        if ($command =~ $pattern) {
            my $matched = $&;
            push @$flags, {
                category    => 'system_destructive',
                severity    => 'critical',
                description => 'Potentially destructive system command detected',
                details     => "Matched: $matched",
            };
            last;
        }
    }
}

sub _check_privilege_escalation {
    my ($command, $flags) = @_;

    for my $pattern (@PRIVILEGE_PATTERNS) {
        if ($command =~ $pattern) {
            my $matched = $&;

            # sudo is very common in legitimate dev work
            # Only flag it as medium, not high
            my $severity = ($matched =~ /sudo/) ? 'medium' : 'high';

            push @$flags, {
                category    => 'privilege_escalation',
                severity    => $severity,
                description => 'Privilege escalation command detected',
                details     => "Matched: $matched",
            };
            last;
        }
    }
}

# ---------------------------------------------------------------------------
# Risk computation
# ---------------------------------------------------------------------------

my %SEVERITY_SCORE = (
    low      => 1,
    medium   => 2,
    high     => 3,
    critical => 4,
);

sub _compute_risk_level {
    my ($flags) = @_;

    return 'none' unless @$flags;

    my $max_score = 0;
    my $total_score = 0;

    for my $flag (@$flags) {
        my $score = $SEVERITY_SCORE{$flag->{severity}} || 0;
        $max_score = $score if $score > $max_score;
        $total_score += $score;
    }

    # Critical is always critical (system destructive)
    return 'critical' if $max_score >= 4;

    # Multiple high flags = critical
    return 'critical' if $total_score >= 6;

    # High flag or multiple medium flags
    return 'high' if $max_score >= 3;
    return 'high' if $total_score >= 4;

    # Medium flag
    return 'medium' if $max_score >= 2;

    # Low flags only
    return 'low';
}

sub _unique_categories {
    my ($flags) = @_;
    my %seen;
    my @result;
    for my $flag (@$flags) {
        unless ($seen{$flag->{category}}++) {
            push @result, $flag->{category};
        }
    }
    return @result;
}

1;

__END__

=head1 DESIGN PHILOSOPHY

Traditional command filtering (blocklists) is fundamentally broken for AI agents:

=over 4

=item * Block C<curl>? Agent uses C<wget>. Block C<wget>? Agent uses
C<python -c "import urllib...">. Block interpreters? Agent can't work.

=item * Analysis caps and shortcut heuristics become bypass vectors.
When a security boundary can be exceeded by crafting input, it's not
a boundary - it's a suggestion.

=item * Command-level blocking is a game of whack-a-mole that reduces
agent capability while providing false security.

=back

Instead, this module classifies B<intent> (network outbound, credential
access, etc.) and lets the enforcement layer decide what to do. The user
always has the final say - all commands prompt the user for approval,
with critical-risk commands showing elevated warnings.

=head1 SECURITY MODEL

    +-----------------+     +------------------+     +-----------------+
    | AI generates    | --> | CommandAnalyzer   | --> | User prompt     |
    | shell command   |     | classifies intent |     | (if risky)      |
    +-----------------+     +------------------+     +-----------------+
                                    |
                            +-------+--------+
                            |                |
                       risk=none          risk>none
                       (auto-allow)       (confirm/block)

=head1 LIMITATIONS

This module cannot catch every possible exfiltration vector. An agent
can always write an obfuscated script and execute it. The goal is to
catch the B<common, obvious cases> and provide visibility, not to
build an impenetrable sandbox. True sandboxing requires OS-level
isolation (containers, seccomp) which is out of scope.

=cut
