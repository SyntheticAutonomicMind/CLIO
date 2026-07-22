# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::Diagnostics;

use strict;
use warnings;
use utf8;
use Exporter 'import';
use POSIX qw(strftime);
use CLIO::Util::JSON qw(encode_json safe_encode_json);
use CLIO::Memory::TokenEstimator qw(estimate_tokens get_effective_ratio);
use CLIO::Core::Logger qw(log_warning log_info log_debug);
use CLIO::Util::RateLimit qw(format_reset_message);

our @EXPORT_OK = qw(
    dump_diagnostic
    display_rate_limit_info
    deduplicate_paragraphs
    get_tool_specific_guidance
);

=head1 NAME

CLIO::Core::Diagnostics - Diagnostic dumping, rate limit display, and utility functions

=head1 DESCRIPTION

Pure functions for diagnostic output and text processing. Extracted from
WorkflowOrchestrator to reduce module size and improve testability.

None of these functions access object state - they operate solely on their arguments.

=head1 SYNOPSIS

    use CLIO::Core::Diagnostics qw(dump_diagnostic deduplicate_paragraphs);

    dump_diagnostic(
        trigger     => 'trim',
        messages    => \@messages,
        api_manager => $api_manager,
        iteration   => 3,
    );

    my $clean = deduplicate_paragraphs($response_text);

=cut

#============================================================================
# Diagnostic Dumping
#============================================================================

=head2 dump_diagnostic

Unified diagnostic dump for debugging API and context management issues.

Supports multiple trigger modes:

  trigger => 'trim'            Context trim diagnostic (CLIO_TRIM_DIAG env var)
  trigger => 'persistent_400'  Persistent 400 errors (always-on)

Options:
  phase       => 'before'|'after'  (for trim diagnostics)
  messages    => \@messages
  api_manager => $api_manager
  iteration   => $iteration
  retry_count => $retry_count
  extra       => { ... }          Additional key-value pairs
  api_response => { ... }         API response hash (for 400 diagnostics)
  error       => 'error string'   Error message
  append      => 1                Append to file instead of creating new

Returns: Output file path, or undef on failure.

=cut

sub dump_diagnostic {
    my (%args) = @_;

    my $trigger      = $args{trigger} || 'unknown';
    my $phase        = $args{phase} || '';
    my $messages     = $args{messages} || [];
    my $api_manager  = $args{api_manager};
    my $iteration    = $args{iteration} // 0;
    my $retry_count  = $args{retry_count} // 0;
    my $extra        = $args{extra} || {};
    my $api_response = $args{api_response};
    my $error_msg    = $args{error} || '';
    my $append       = $args{append} || 0;

    # Determine output file
    my $file;
    if ($append) {
        $file = "/tmp/clio_diag_${trigger}.log";
    } else {
        my $ts = POSIX::strftime('%Y%m%d_%H%M%S', localtime);
        my $label = $phase ? "${trigger}_${phase}" : $trigger;
        $file = "/tmp/clio_diag_${label}_${ts}_$$.log";
    }

    my $open_mode = $append ? '>>:encoding(UTF-8)' : '>:encoding(UTF-8)';
    open my $fh, $open_mode, $file or do {
        log_warning('Diagnostics', "Cannot write diagnostic to $file: $!");
        return;
    };

    # Header
    my $title = uc($trigger);
    $title .= " - " . uc($phase) if $phase;
    print $fh "\n" if $append;
    print $fh "=" x 80, "\n";
    print $fh "CLIO DIAGNOSTIC: $title\n";
    print $fh "Timestamp: ", scalar(localtime), "\n";
    print $fh "PID: $$\n";
    print $fh "Iteration: $iteration, Retry: $retry_count\n";
    print $fh "Error: $error_msg\n" if $error_msg;
    print $fh "=" x 80, "\n\n";

    # API response details (if provided)
    if ($api_response && ref($api_response) eq 'HASH') {
        print $fh "-" x 40, "\n";
        print $fh "API RESPONSE\n";
        print $fh "-" x 40, "\n";
        for my $key (sort keys %$api_response) {
            next if $key eq 'content';  # Skip large content
            my $val = $api_response->{$key};
            if (ref($val)) {
                $val = safe_encode_json($val, ref($val));
                $val = substr($val, 0, 500) . "..." if length($val) > 500;
            }
            $val //= 'undef';
            print $fh "  $key: $val\n";
        }
        print $fh "\n";
    }

    # Model capabilities
    print $fh "-" x 40, "\n";
    print $fh "MODEL & CAPABILITIES\n";
    print $fh "-" x 40, "\n";
    if ($api_manager) {
        my $model = $api_manager->get_current_model() || 'unknown';
        my $provider = $api_manager->{provider_name} || 'unknown';
        print $fh "  Model: $model\n";
        print $fh "  Provider: $provider\n";
        my $caps = $api_manager->get_model_capabilities($model);
        if ($caps) {
            for my $key (sort keys %$caps) {
                my $val = $caps->{$key};
                if (ref($val) eq 'ARRAY') {
                    $val = '[' . join(', ', @$val) . ']';
                } elsif (ref($val)) {
                    $val = safe_encode_json($val, ref($val));
                }
                print $fh "  $key: $val\n";
            }
        } else {
            print $fh "  (no capabilities available)\n";
        }
        print $fh "  learned_token_ratio: " . ($api_manager->{learned_token_ratio} // 'undef') . "\n";
    } else {
        print $fh "  (no api_manager)\n";
    }
    print $fh "\n";

    # Token estimator state
    print $fh "-" x 40, "\n";
    print $fh "TOKEN ESTIMATOR\n";
    print $fh "-" x 40, "\n";
    my $effective_ratio = CLIO::Memory::TokenEstimator::get_effective_ratio();
    print $fh "  effective_ratio: $effective_ratio\n\n";

    # Extra parameters
    if (keys %$extra) {
        print $fh "-" x 40, "\n";
        print $fh "EXTRA CONTEXT\n";
        print $fh "-" x 40, "\n";
        for my $key (sort keys %$extra) {
            print $fh "  $key: " . ($extra->{$key} // 'undef') . "\n";
        }
        print $fh "\n";
    }

    # Messages detail
    print $fh "-" x 40, "\n";
    print $fh "MESSAGES (" . scalar(@$messages) . " total)\n";
    print $fh "-" x 40, "\n";

    my $grand_total_tokens = 0;
    my %role_counts;
    my %role_tokens;

    for (my $i = 0; $i < @$messages; $i++) {
        my $msg = $messages->[$i];
        my $role = $msg->{role} || 'unknown';
        my $content = $msg->{content} || '';
        my $content_len = length($content);
        my $msg_tokens = estimate_tokens($content) + 4;
        $msg_tokens += 8 if $role eq 'tool';

        my $tc_count = 0;
        my $tc_tokens = 0;
        if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            $tc_count = scalar(@{$msg->{tool_calls}});
            for my $tc (@{$msg->{tool_calls}}) {
                my $json = safe_encode_json($tc, '');
                $tc_tokens += estimate_tokens($json);
            }
            $msg_tokens += $tc_tokens;
        }

        $grand_total_tokens += $msg_tokens;
        $role_counts{$role}++;
        $role_tokens{$role} = ($role_tokens{$role} || 0) + $msg_tokens;

        my $tc_info = $tc_count ? " tool_calls=$tc_count(${tc_tokens}tok)" : "";
        my $tool_id = $msg->{tool_call_id} ? " tool_call_id=$msg->{tool_call_id}" : "";
        my $importance = defined $msg->{_importance} ? " importance=$msg->{_importance}" : "";
        print $fh sprintf("[%4d] role=%-10s tokens=%-6d chars=%-7d%s%s%s\n",
            $i, $role, $msg_tokens, $content_len, $tc_info, $tool_id, $importance);

        my $preview = substr($content, 0, 200);
        $preview =~ s/\n/\\n/g;
        print $fh "       content: $preview" . ($content_len > 200 ? "..." : "") . "\n";
    }

    print $fh "\n";
    print $fh "-" x 40, "\n";
    print $fh "SUMMARY\n";
    print $fh "-" x 40, "\n";
    print $fh "Total messages: " . scalar(@$messages) . "\n";
    print $fh "Total estimated tokens: $grand_total_tokens\n";
    for my $role (sort keys %role_counts) {
        print $fh sprintf("  %-12s %4d messages, %7d tokens\n",
            "$role:", $role_counts{$role}, $role_tokens{$role});
    }
    print $fh "\n";

    # Tool pair validation (critical for diagnosing 400 errors)
    {
        my %tc_ids;   # tool_call_id => message index
        my %tr_ids;   # tool_call_id => message index (from results)
        for (my $i = 0; $i < @$messages; $i++) {
            my $msg = $messages->[$i];
            if ($msg->{role} && $msg->{role} eq 'assistant' &&
                $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                for my $tc (@{$msg->{tool_calls}}) {
                    $tc_ids{$tc->{id}} = $i if $tc->{id};
                }
            }
            if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
                $tr_ids{$msg->{tool_call_id}} = $i;
            }
        }
        my @orphaned_calls   = grep { !exists $tr_ids{$_} } keys %tc_ids;
        my @orphaned_results = grep { !exists $tc_ids{$_} } keys %tr_ids;

        if (@orphaned_calls || @orphaned_results) {
            print $fh "-" x 40, "\n";
            print $fh "TOOL PAIR VALIDATION (ERRORS)\n";
            print $fh "-" x 40, "\n";
            for my $id (@orphaned_calls) {
                print $fh "  ORPHANED tool_call: $id (assistant at msg $tc_ids{$id})\n";
            }
            for my $id (@orphaned_results) {
                print $fh "  ORPHANED tool_result: $id (tool at msg $tr_ids{$id})\n";
            }
            print $fh "Total tool_calls: " . scalar(keys %tc_ids) . ", tool_results: " . scalar(keys %tr_ids) . "\n";
            print $fh "\n";
        } else {
            print $fh "-" x 40, "\n";
            print $fh "TOOL PAIR VALIDATION: OK (" . scalar(keys %tc_ids) . " pairs matched)\n";
            print $fh "-" x 40, "\n\n";
        }
    }

    # Recent API 400 log (included for 400-related diagnostics)
    if ($trigger =~ /400/ && -f '/tmp/clio_api_400.log') {
        print $fh "-" x 40, "\n";
        print $fh "RECENT API 400 LOG\n";
        print $fh "-" x 40, "\n";
        if (open my $log_fh, '<', '/tmp/clio_api_400.log') {
            my @lines = <$log_fh>;
            close $log_fh;
            my $start = @lines > 20 ? @lines - 20 : 0;
            for my $i ($start..$#lines) {
                print $fh $lines[$i];
            }
        }
        print $fh "\n";
    }

    print $fh "=" x 80, "\n";
    close $fh;

    log_info('Diagnostics', "Diagnostic ($trigger" . ($phase ? "/$phase" : "") . ") written to $file");
    return $file;
}

#============================================================================
# Rate Limit Display
#============================================================================

=head2 display_rate_limit_info

Display rate limit information to the user via system message.

Arguments:
- $rl_code: Rate limit error code
- $retry_after: Seconds until rate limit resets

Returns: Human-readable message string.

=cut

sub display_rate_limit_info {
    my ($rl_code, $retry_after) = @_;

    my $message;
    if ($rl_code =~ /user_weekly_rate_limited/i) {
        my $reset_msg = format_reset_message($retry_after, undef);
        $message = "Weekly rate limit reached. Please review your usage$reset_msg.";
    } elsif ($rl_code =~ /user_monthly_rate_limited/i) {
        my $reset_msg = format_reset_message($retry_after, undef);
        $message = "Monthly rate limit reached. Please review your usage$reset_msg.";
    } elsif ($rl_code =~ /userbymodelbyminuteuncachedinputtokens|userbymodelbyminuteinputtokens|^anthropic[-_]ratelimit|ratelimitreached/i) {
        # Anthropic ITPM (input tokens per minute) hits. The bucket name in
        # older errors / Bedrock proxies exposes the limit directly
        # ("UserByModelByMinuteUncachedInputTokens" = per-model per-user per
        # minute, uncached input tokens). Newer responses use a generic
        # "RateLimitReached" code with a descriptive message instead.
        #
        # These caps continuously refill (token bucket), so the provider's
        # Retry-After hint is what determines when the bucket recovers.
        # Without it, default to a short wait - CLIO proactively paces
        # subsequent requests once ITPM throttling is triggered.
        my $reset_msg = format_reset_message($retry_after, undef);
        my $suffix = $reset_msg || " and try again shortly";
        $message = "Anthropic input-token rate limit hit (ITPM)$suffix. "
                 . "Large or repeated requests with prompt caching disabled are the usual cause.";
    } elsif ($rl_code =~ /userbymodelbyminuteuncachedoutputtokens|userbymodelbyminuteoutputtokens/i) {
        my $reset_msg = format_reset_message($retry_after, undef);
        my $suffix = $reset_msg || " and try again shortly";
        $message = "Anthropic output-token rate limit hit (OTPM)$suffix. "
                 . "Long responses or many parallel completions are the usual cause.";
    } elsif ($rl_code =~ /userbymodelbyminuterequests/i) {
        my $reset_msg = format_reset_message($retry_after, undef);
        my $suffix = $reset_msg || " and try again shortly";
        $message = "Anthropic request rate limit hit (RPM)$suffix. Reduce concurrent requests or add delay between turns.";
    } else {
        $message = "Rate limit reached. Please wait before making more requests.";
    }

    log_info('Diagnostics', "Rate limit info: $message");
    return $message;
}

#============================================================================
# Response Text Cleanup
#============================================================================

=head2 deduplicate_paragraphs

Detect and remove duplicated paragraphs within a single response.

Models sometimes echo the last paragraph(s) a second time, producing
output like "A\n\nB\n\nB" or "A\n\nB\n\nC\n\nB\n\nC".
Detects a repeated suffix: if the last N paragraphs equal the N
paragraphs just before them, strips the duplicate tail.

Arguments:
- $text: Raw response text

Returns: Cleaned text with duplicate suffix removed (or original if no dup found).

=cut

sub deduplicate_paragraphs {
    my ($text) = @_;
    return $text unless defined $text && length($text) > 40;

    # Split on blank-line boundaries (two+ newlines)
    my @parts = split /\n\s*\n/, $text;
    return $text if @parts < 2;

    # Try suffix lengths from half down to 1
    my $max_suffix = int(@parts / 2);
    for my $suffix_len (reverse 1 .. $max_suffix) {
        my $start_a = @parts - 2 * $suffix_len;  # first copy starts here
        my $start_b = @parts - $suffix_len;       # second copy starts here

        my $match = 1;
        for my $j (0 .. $suffix_len - 1) {
            my $a = $parts[$start_a + $j];
            my $b = $parts[$start_b + $j];
            # Normalize whitespace for comparison
            (my $na = $a) =~ s/\s+/ /g;
            (my $nb = $b) =~ s/\s+/ /g;
            $na =~ s/^\s+|\s+$//g;
            $nb =~ s/^\s+|\s+$//g;
            if ($na ne $nb) {
                $match = 0;
                last;
            }
        }

        if ($match) {
            # Remove the duplicated suffix
            my @deduped = @parts[0 .. $start_b - 1];
            my $result = join("\n\n", @deduped);
            log_debug('Diagnostics',
                "Removed $suffix_len duplicated paragraph(s) from response");
            return $result;
        }
    }

    return $text;
}

#============================================================================
# Tool-Specific Error Guidance
#============================================================================

=head2 get_tool_specific_guidance

Returns guidance messages for specific tools when they fail with malformed JSON.

Arguments:
- $tool_name: Name of the tool that failed (e.g., 'file_operations', 'todo_operations')

Returns: Guidance string with alternative approaches and required field reminders.
         Empty string for unknown tool names.

=cut

sub get_tool_specific_guidance {
    my ($tool_name) = @_;

    return '' unless defined $tool_name;

    # Special guidance for read_tool_result failures
    if ($tool_name eq 'file_operations') {
        return <<'GUIDANCE';

ALTERNATIVE APPROACHES FOR FILE OPERATIONS:
If read_tool_result is failing repeatedly, try these instead:
1. Use terminal_operations with head/tail/sed to view specific portions:
   terminal_operations(operation: "exec", command: "head -n 50 /path/to/file")
2. Use file_operations with read_file and line ranges:
   file_operations(operation: "read_file", path: "/path/to/file", start_line: 1, end_line: 100)
3. Use grep_search to find specific patterns instead of reading entire file:
   file_operations(operation: "grep_search", query: "pattern")

GUIDANCE
    }

    if ($tool_name eq 'todo_operations') {
        return <<'GUIDANCE';

TODO OPERATIONS - REQUIRED FIELDS:
Every todoList item MUST include these 3 fields: title, description, status
Every newTodos item MUST include these 2 fields: title, description
The "description" field is the most commonly omitted required field - ALWAYS include it.

GUIDANCE
    }

    return '';
}

1;
