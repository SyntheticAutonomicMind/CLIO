package CLIO::Core::MessageFingerprinter;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);

use CLIO::Core::Logger qw(log_debug);

use Exporter 'import';
our @EXPORT_OK = qw(
    message_fingerprint
    fingerprint_messages
    messages_match
    trace_context_transition
);

=head1 NAME

CLIO::Core::MessageFingerprinter - Message identity and context-transition tracing

=head1 DESCRIPTION

Provides message fingerprinting and context-transition tracing for the
context-integrity audit. A fingerprint is a compact, content-derived
identifier that detects accidental mutation, duplication, or reordering
of messages during trimming and provider serialization.

A fingerprint includes enough information to detect:
- role changes (role)
- content mutation (content hash)
- tool call additions/removals/reordering (tool_call ids)
- tool result pairing changes (tool_call_id)
- reasoning field presence changes (reasoning flag)

No sensitive message content is logged by default — only hashes and
structural fields. When debug tracing is enabled (CLIO_TRIM_DIAG or
debug mode), a context-transition trace is emitted around every trim
phase.

=cut

our $VERSION = '1.0.0';

=head2 message_fingerprint

Compute a compact fingerprint for a single message hash.

Fields included:
- role
- id (when available)
- content hash (SHA-256 truncated to 16 hex chars)
- tool_call ids (sorted, comma-joined)
- tool_call_id (for tool messages)
- reasoning presence flag

Returns a string like:
  user|content=abc123...|id=def456|tcids=|trid=|reasoning=0

=cut

sub message_fingerprint {
    my ($msg) = @_;
    return '' unless ref($msg) eq 'HASH';

    my $role = $msg->{role} // '';
    my $id   = $msg->{id} // '';

    # Content hash
    my $content = _content_for_fingerprint($msg->{content});
    my $chash = substr(sha256_hex(encode_utf8($content // '')), 0, 16);

    # Tool call IDs (sorted for order-independence within a message)
    my $tcids = '';
    if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
        my @ids = sort map { $_->{id} // '' } @{$msg->{tool_calls}};
        $tcids = join(',', grep { length } @ids);
    }

    # Tool call_id (for tool result messages)
    my $trid = $msg->{tool_call_id} // '';

    # Reasoning presence
    my $has_reasoning = 0;
    $has_reasoning = 1 if defined $msg->{reasoning_content} && length $msg->{reasoning_content};
    $has_reasoning = 1 if ref($msg->{reasoning_details}) eq 'ARRAY' && @{$msg->{reasoning_details}};
    $has_reasoning = 1 if ref($msg->{reasoning_blocks}) eq 'ARRAY' && @{$msg->{reasoning_blocks}};
    $has_reasoning = 1 if ref($msg->{responses_reasoning_items}) eq 'ARRAY' && @{$msg->{responses_reasoning_items}};

    return "$role|content=$chash|id=$id|tcids=$tcids|trid=$trid|reasoning=$has_reasoning";
}

sub _content_for_fingerprint {
    my ($content) = @_;
    return '' unless defined $content;
    if (ref($content) eq 'ARRAY') {
        my $text = '';
        for my $part (@$content) {
            next unless ref($part) eq 'HASH';
            $text .= $part->{text} // '' if ($part->{type} // '') eq 'text';
        }
        return $text;
    }
    return '' if ref($content);
    return $content;
}

=head2 fingerprint_messages

Compute fingerprints for an entire message array. Returns an arrayref
of fingerprint strings in the same order as the input.

=cut

sub fingerprint_messages {
    my ($messages) = @_;
    return [] unless $messages && ref($messages) eq 'ARRAY';
    return [map { message_fingerprint($_) } @$messages];
}

=head2 messages_match

Compare two message arrays by fingerprint. Returns the indices where
fingerprints differ, indicating mutation, reordering, or divergence.

=cut

sub messages_match {
    my ($before, $after) = @_;
    return [1] unless $before && $after && ref($before) eq 'ARRAY' && ref($after) eq 'ARRAY';
    return [2] if scalar(@$before) != scalar(@$after);

    my @diffs;
    for my $i (0 .. $#$before) {
        push @diffs, $i if message_fingerprint($before->[$i]) ne message_fingerprint($after->[$i]);
    }
    return \@diffs;
}

=head2 trace_context_transition

Emit a compact context-transition report. Called around every trim
phase (before-trim, after-trim, dropped, retained, new_summary).

The trace includes:
- phase: name of the trim phase
- message count
- role sequence (compact: u/a/t/s for user/assistant/tool/system)
- summary count (number of <thread_summary> system messages)
- first/last user index
- token estimate
- estimated budget
- current_task_hash (if provided)
- dynamic_context_hash (if provided)
- fingerprints of each message (debug level, not logged by default)

Does not log sensitive content — only hashes and structural fields.

=cut

sub trace_context_transition {
    my (%args) = @_;

    my $phase         = $args{phase}         // 'unknown';
    my $messages      = $args{messages}      || [];
    my $effective_limit = $args{effective_limit} // 0;
    my $current_task  = $args{current_task}  // '';
    my $dynamic_context = $args{dynamic_context} // '';
    my $extra         = $args{extra}         || {};

    return unless $messages && @$messages;

    # Role sequence (compact)
    my @roles = map {
        ref($_) eq 'HASH' ? substr(($_->{role} // ''), 0, 1) : '?'
    } @$messages;
    my $role_seq = join('', @roles);

    # Summary count
    my $summary_count = 0;
    for my $msg (@$messages) {
        if (ref($msg) eq 'HASH'
            && ($msg->{role} // '') eq 'system'
            && ($msg->{content} // '') =~ /<thread_summary>/) {
            $summary_count++;
        }
    }

    # First/last user index
    my ($first_user_idx, $last_user_idx);
    for my $i (0 .. $#{$messages}) {
        if (ref($messages->[$i]) eq 'HASH'
            && ($messages->[$i]{role} // '') eq 'user') {
            $first_user_idx //= $i;
            $last_user_idx = $i;
        }
    }

    # Token estimate
    require CLIO::Memory::TokenEstimator;
    my $token_estimate = CLIO::Memory::TokenEstimator::estimate_messages_tokens($messages);

    # Hashes
    my $task_hash = substr(sha256_hex(encode_utf8($current_task // '')), 0, 16);
    my $dc_hash   = substr(sha256_hex(encode_utf8($dynamic_context // '')), 0, 16);

    # Compact fingerprint summary (for debug - not full content)
    my $fingerprint_summary = join(',',
        map {
            my $role = ref($_) eq 'HASH' ? substr(($_->{role} // ''), 0, 1) : '?';
            $role . ':' . substr(message_fingerprint($_), 0, 16)
        } @$messages
    );

    log_debug('ContextTrace',
        sprintf('[CONTEXT] phase=%s messages=%d roles=%s summaries=%d ' .
                'first_user=%s last_user=%s tokens=%d budget=%d ' .
                'task_hash=%s dc_hash=%s fingerprints=%s extra=%s',
            $phase,
            scalar(@$messages),
            $role_seq,
            $summary_count,
            ($first_user_idx // 'none'),
            ($last_user_idx   // 'none'),
            $token_estimate,
            $effective_limit,
            $task_hash,
            $dc_hash,
            $fingerprint_summary,
            _stringify_extra($extra),
        )
    );
}

sub _stringify_extra {
    my ($extra) = @_;
    return '' unless $extra && ref($extra) eq 'HASH';
    my @parts;
    for my $k (sort keys %$extra) {
        my $v = $extra->{$k};
        $v = _abbreviate_scalar($v);
        push @parts, "$k=$v";
    }
    return join(' ', @parts);
}

sub _abbreviate_scalar {
    my ($v) = @_;
    return 'undef' unless defined $v;
    my $s = (ref($v) eq 'SCALAR') ? $$v : (ref($v) ? ref($v) : $v);
    $s = '' . $s;
    return $s if length($s) <= 60;
    return substr($s, 0, 57) . '...';
}

1;

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut

1;
