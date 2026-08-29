package CLIO::Core::API::MessageValidator;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use CLIO::Core::Defaults qw(DEFAULT_POST_TRIM_FLOOR
    MAX_CSSS_SLOT_TOKENS MAX_PRESERVED_HIGH_VALUE ACK_THRESHOLD_CHARS);
use CLIO::Core::Logger qw(should_log log_debug log_info log_warning);
use CLIO::Memory::TokenEstimator qw(estimate_tokens compute_prompt_budget);
use CLIO::Util::JSON qw(encode_json decode_json safe_encode_json);
use POSIX qw(strftime);


=head1 NAME

CLIO::Core::API::MessageValidator - Message validation and truncation for API requests

=head1 DESCRIPTION

Extracted from APIManager.pm to handle message validation, tool-call pairing,
and conversation truncation. These operations ensure that message arrays sent
to AI providers conform to their requirements (no orphaned tool calls/results,
within token limits, etc.)

=head1 SYNOPSIS

    use CLIO::Core::API::MessageValidator;
    
    my $validated = CLIO::Core::API::MessageValidator::validate_tool_message_pairs($messages);
    my $errors = CLIO::Core::API::MessageValidator::preflight_validate($messages);
    my $truncated = CLIO::Core::API::MessageValidator::validate_and_truncate(
        messages           => $messages,
        model_capabilities => $caps,
        tools              => $tools,
        token_ratio        => $ratio,
        config             => $config,
        api_base           => $api_base,
        debug              => $debug,
    );

=cut

use Exporter 'import';
our @EXPORT_OK = qw(
    validate_and_truncate
    validate_tool_message_pairs
    preflight_validate
);

=head2 validate_and_truncate

Validate messages and truncate to fit within token limits. Groups messages
into units (assistant+tool_calls+tool_results) to prevent orphaned pairs.
Uses YaRN compression for dropped messages when available.

Arguments (hash):
    messages           => ArrayRef of message objects (required)
    model_capabilities => HashRef from get_model_capabilities (optional)
    tools              => ArrayRef of tool definitions (optional)
    token_ratio        => Learned chars/token ratio (default: 2.5)
    config             => Config object (optional, for provider fallbacks)
    api_base           => API base URL (optional, for local model detection)
    debug              => Debug flag (optional)

Returns: ArrayRef of validated/truncated messages

=cut

sub validate_and_truncate {
    my (%args) = @_;
    
    my $messages = $args{messages} || [];
    my $caps = $args{model_capabilities};
    my $tools = $args{tools};
    my $token_ratio = $args{token_ratio} || 2.5;
    my $config = $args{config};
    my $api_base = $args{api_base} || '';
    my $debug = $args{debug};
    my $model = $args{model} || 'unknown';
    my $trim_threshold = $args{trim_threshold};  # Optional: override trim threshold in tokens
    
    # Determine max prompt tokens
    require CLIO::Providers;
    my $max_prompt;
    if ($caps && $caps->{max_prompt_tokens}) {
        $max_prompt = $caps->{max_prompt_tokens};
    } else {
        # Fall back to the provider registry: local inference servers
        # use DEFAULT_LOCAL_CONTEXT_WINDOW (smaller) because the model's
        # max context is bounded by host RAM; everything else uses
        # DEFAULT_CONTEXT_WINDOW. CLIO::Providers::default_context_window
        # centralizes this so we don't hardcode provider names here.
        my $provider = ($config && $config->can('get')) ? ($config->get('provider') || '') : '';

        # When the provider config is missing/empty (e.g. early init
        # before Config loads), fall back to the URL heuristic: any
        # HTTP host with an explicit port that isn't a known cloud
        # API base is treated as local inference.
        my $resolved_provider = $provider;
        if (!$resolved_provider && $api_base && $api_base =~ m{^https?://[^/]+:[0-9]+/}i
            && CLIO::Providers::provider_from_url($api_base) eq '') {
            # Unrecognized LAN URL with explicit port - sentinel value;
            # any local_inference provider would work, but we use
            # the local registry value to pick the smaller window.
            $resolved_provider = 'sam';
        }

        $max_prompt = CLIO::Providers::default_context_window($resolved_provider);

        log_debug('MessageValidator', "Using fallback token limit for $model: $max_prompt");
    }

    # Compute prompt budget from model capabilities. Uses the model's
    # actual max_output_tokens (no hard cap) plus an estimation buffer.
    # This replaces the previous 15% margin + 8K buffer, which over-
    # reserved for models with small actual output caps.
    # When tools are present, the budget calculation automatically caps
    # the output reserve at DEFAULT_TOOL_OUTPUT_RESERVE (8K) since tool
    # responses are short - reclaims up to ~24K of prompt room.
    require CLIO::Memory::TokenEstimator;
    my $prompt_budget = CLIO::Memory::TokenEstimator::compute_prompt_budget($caps, tools => $tools);

    # Calculate tool token budget
    my $tool_tokens = _calculate_tool_tokens($tools);

    # Effective limit: prompt budget minus tools. Tool definitions are
    # sent on every request and counted toward the prompt, so they
    # reduce the available budget for messages.
    my $effective_limit = $prompt_budget - $tool_tokens;
    $effective_limit = 1000 if $effective_limit < 1000;

    # Allow caller to override the trim threshold (e.g., to trim earlier at a
    # lower percentage of context window). If provided, use it as the limit.
    if (defined $trim_threshold && $trim_threshold > 0) {
        $effective_limit = $trim_threshold;
        log_debug('MessageValidator', "Using caller-provided trim threshold: $trim_threshold tokens");
    }

    log_debug('MessageValidator', "Token budget: max=$max_prompt, tools=$tool_tokens, budget=$prompt_budget, effective=$effective_limit");
    
    # Estimate token usage
    my $estimated_tokens = _estimate_tokens($messages);
    
    if ($estimated_tokens <= $effective_limit) {
        log_debug('MessageValidator', "Token validation: $estimated_tokens / $effective_limit tokens (OK)");
        return validate_tool_message_pairs($messages);
    }
    
    # Exceeds limit - need to truncate
    log_debug('MessageValidator', "Messages exceed token limit: $estimated_tokens > $effective_limit, truncating");

    # DIAGNOSTIC: Dump MessageValidator internal thresholds to /tmp (CLIO_TRIM_DIAG=1 to enable)
    if ($ENV{CLIO_TRIM_DIAG}) {
    eval {
        my $ts = POSIX::strftime('%Y%m%d_%H%M%S', localtime);
        my $diag_file = "/tmp/clio_trim_validator_${ts}_$$.log";
        if (open my $dfh, '>:encoding(UTF-8)', $diag_file) {
            print $dfh "MessageValidator TRUNCATION TRIGGERED\n";
            print $dfh "=" x 60, "\n";
            print $dfh "Timestamp: ", scalar(localtime), "\n";
            print $dfh "Model: $model\n";
            print $dfh "max_prompt (from caps): $max_prompt\n";
            print $dfh "max_output_tokens (from caps): " . ($caps->{max_output_tokens} // 'undef') . "\n";
            print $dfh "tool_tokens: $tool_tokens\n";
            print $dfh "prompt_budget (ctx - output - buffer): $prompt_budget\n";
            print $dfh "effective_limit (budget - tools): $effective_limit\n";
            print $dfh "estimated_tokens: $estimated_tokens\n";
            print $dfh "overage: " . ($estimated_tokens - $effective_limit) . "\n";
            print $dfh "message_count: " . scalar(@$messages) . "\n";
            close $dfh;
            log_info('MessageValidator', "Validator thresholds dumped to $diag_file");
        }
    };
    }
    
    # Group messages into units
    my ($units_ref, $tool_id_map) = _group_into_units($messages);
    my @units = @$units_ref;
    
    log_debug('MessageValidator', "Grouped " . scalar(@$messages) . " messages into " . scalar(@units) . " units");
    
    # Extract system message, most recent user message, AND the most
    # recent SUBSTANTIVE user message. The substantive user is the
    # original task anchor the model needs to keep its place after trim;
    # if the most recent user is just "continue" (7 tokens) the
    # substantive user holds the real task description and must be
    # surfaced via user_context or injected as a real user message.
    my ($system_msg, $last_user_unit, $start_unit, $system_tokens, $last_user_tokens,
        $summary_unit, $summary_tokens, $preserved_user_contexts,
        $preserved_general_system,
        $substantive_user_unit, $substantive_user_tokens, $substantive_user_content) =
        _extract_preserved_units(\@units);
    
    # Build conversation from newest to oldest. Unit-based walk: each unit
    # (assistant+tool_calls+tool_results grouped together) is kept or dropped
    # as a whole. This preserves the natural interleaved ordering of
    # tool_calls with their tool_results, so no reinterleave step is needed
    # later — the LCP cache stays stable because byte positions only change
    # when messages are actually dropped, not when they're reordered.
    my @conversation;
    # Don't pre-allocate token budget for last_user_unit - it will be included
    # naturally by the budget walk below (it's a recent message). Only reserve
    # space for the always-present system prompt and any existing summary.
    my $current_tokens = $system_tokens + $summary_tokens;
    my %included_tool_ids;
    # Extract previous summary content for merging into new compression
    my $previous_summary_content = '';
    if ($summary_unit && $summary_unit->{messages} && @{$summary_unit->{messages}}) {
        $previous_summary_content = $summary_unit->{messages}[0]{content} || '';
    }
    my @dropped_units;
    my @error_units;  # BUG C: error units deferred to second pass

    my @remaining = @units[$start_unit .. $#units];

    # Trim priority classification (see docs/SPECS/TRIM_PRIORITY.md).
    # Each unit is classified into a tier so the budget walk knows the
    # drop order. Tier 4 (errors + acks + empty) is dropped FIRST, then
    # Tier 3 (regular dialog), with the most recent N Tier 2 (high-value)
    # units preserved regardless of budget pressure.
    #
    # The reverse-walk below only emits Tier 3 (regular dialog) and routes
    # Tier 4 (errors) into @error_units for the second-pass walk. The
    # existing error-handling is preserved (drop ordering, summary capture).
    my $max_high_value = CLIO::Core::Defaults::MAX_PRESERVED_HIGH_VALUE();

    # Post-trim target: keep context at the caller's trim_threshold (which
    # defaults to the drift-aware threshold from the proactive trim in
    # WorkflowOrchestrator.process_input) or, if not provided, the
    # effective_limit (= prompt_budget - tool_tokens). Ring-buffer /
    # sliding window: keep newest messages, drop oldest non-critical.
    # CSSS handles summary cache stability; DEFAULT_POST_TRIM_FLOOR
    # acts as absolute safety floor.
    my $post_trim_keep_limit = $effective_limit;
    # BUG C: Allow callers to disable the post-trim floor when they want
    # to force aggressive trim for testing or tight-budget scenarios.
    if ($args{disable_post_trim_floor}) {
        # Caller overrides DEFAULT_post_TRIM_FLOOR. Use the raw threshold.
    } else {
        $post_trim_keep_limit = CLIO::Core::Defaults::DEFAULT_POST_TRIM_FLOOR()
            if $post_trim_keep_limit < CLIO::Core::Defaults::DEFAULT_POST_TRIM_FLOOR();
    }
    log_debug('MessageValidator', "Post-trim keep target: $post_trim_keep_limit tokens (prompt budget for $model)");

    # Trim priority multi-pass walk (see docs/SPECS/TRIM_PRIORITY.md).
    # Tier 4 (errors, empty assistant, acks) is dropped FIRST, before any
    # Tier 3 unit, when the budget is tight. The existing reverse-walk
    # already routes errors via @error_units. Here we extend the same
    # drop-first pattern to ack/empty units, walking them OLDEST-FIRST
    # within the tier so the newest noise is most likely to survive.
    #
    # Approach: rebuild the conversation walking ONLY Tier 4 units first,
    # then re-add the surviving Tier 3+ units. This guarantees Tier 4
    # is dropped before Tier 3 even when budget is loose enough that
    # Pass 1 (existing reverse-walk) would otherwise include Tier 4.
    my @ack_empty_units;
    for my $u (@remaining) {
        next unless $u;
        next if $u->{is_trailing_summary} || $u->{is_orphan_tool_result};
        next if $u->{has_tool_error};
        if ($u->{has_empty_assistant} || $u->{is_acknowledgement}) {
            push @ack_empty_units, $u;
        }
    }
    if (@ack_empty_units) {
        my $kept = 0;
        my $dropped = 0;
        # Walk oldest-first within Tier 4 so the newest noise is most
        # likely to survive. Collect which units to remove from
        # @conversation (they were included by the reverse-walk but
        # should be dropped).
        my @to_remove;
        for my $unit (@ack_empty_units) {
            if ($current_tokens + $unit->{tokens} <= $post_trim_keep_limit) {
                # Check if the unit is already in @conversation.
                # The earlier reverse-walk may have included it.
                my $already_included = grep { $_ == $unit } @conversation;
                if (!$already_included) {
                    unshift @conversation, @{$unit->{messages}};
                    $current_tokens += $unit->{tokens};
                    for my $id (keys %{$unit->{tool_call_ids} || {}}) {
                        $included_tool_ids{$id} = 1;
                    }
                    $kept++;
                }
            } else {
                push @to_remove, $unit;
                push @dropped_units, $unit;
                $dropped++;
            }
        }
        # Remove any ack/empty units from @conversation that the budget
        # no longer allows. This is the key Tier 4 enforcement step.
        if (@to_remove) {
            my %to_remove_set = map { $_ => 1 } @to_remove;
            my @filtered;
            for my $msg (@conversation) {
                # Check if this message belongs to a unit to remove.
                my $belongs_to_removed = 0;
                for my $u (@to_remove) {
                    if (grep { $_ == $msg } @{$u->{messages}}) {
                        $belongs_to_removed = 1;
                        last;
                    }
                }
                if (!$belongs_to_removed) {
                    push @filtered, $msg;
                } else {
                    $current_tokens -= CLIO::Memory::TokenEstimator::estimate_tokens($msg->{content} || '') + 4;
                }
            }
            @conversation = @filtered;
        }
        log_debug('MessageValidator', sprintf(
            "Tier 4 ack/empty pass: kept %d, dropped %d",
            $kept, $dropped)) if @ack_empty_units;
    }

    # Walk the conversation, building the in-budget list NEWEST-FIRST
    # (reverse chronological order), then reverse at the end. This is
    # the original behavior. The Tier 4 ack/empty removal pass happens
    # AFTER this walk to drop any noise that survived Pass 1.
    for my $unit (reverse @remaining) {
        if ($unit->{is_orphan_tool_result}) {
            log_debug('MessageValidator', "Skipping orphan tool_result unit (tool_id: $unit->{orphan_tool_id})");
            next;
        }
        # Skip the trailing thread_summary unit — it's extracted by the
        # second pass in _extract_preserved_units and placed at the END
        # of the output separately (CSSS). Including it in the budget
        # walk would either double-count it or drop it, losing the CSSS
        # slot lock that keeps sim_best stable across trims.
        if ($unit->{is_trailing_summary}) {
            log_debug('MessageValidator', "Skipping trailing thread_summary in budget walk (CSSS slot preserved)");
            next;
        }

        # BUG C: Error-first trim priority.
        # Units containing TOOL ERROR tool_results are the LOWEST priority
        # for retention. They convey "this approach failed" but no longer
        # serve a useful purpose once the model has moved on, and they can
        # be 100+ tokens each (schema dumps). Drop them first when budget
        # is tight, before any non-error units.
        if ($unit->{has_tool_error}) {
            # Error unit: defer to second pass. Push onto a separate list
            # so we can decide later whether budget allows it.
            push @error_units, $unit;
            next;
        }

        # Skip Tier 4 (ack/empty) units here - already handled by the
        # dedicated Tier 4 pass above.
        if ($unit->{has_empty_assistant} || $unit->{is_acknowledgement}) {
            push @dropped_units, $unit;
            next;
        }

        # Unit-based trim: keep or drop the ENTIRE unit (including any
        # tool_calls and tool_results it contains). This preserves the
        # natural interleaved ordering — no deinterleave/reinterleave
        # cycle, so the LCP cache prefix doesn't shift on trims that
        # only drop complete units.
        if ($current_tokens + $unit->{tokens} <= $post_trim_keep_limit) {
            unshift @conversation, @{$unit->{messages}};
            $current_tokens += $unit->{tokens};
            for my $id (keys %{$unit->{tool_call_ids} || {}}) {
                $included_tool_ids{$id} = 1;
            }
        } else {
            push @dropped_units, $unit;
        }
    }

    # Tier 4 (ack/empty) removal pass - drop any ack/empty units that
    # are in @conversation because they fit within the budget. These
    # units are pure noise (empty/whitespace assistant turns, "OK",
    # "Got it", etc.) and should be dropped FIRST, even when budget is
    # loose enough to keep them. This guarantees Tier 4 priority is
    # enforced regardless of budget tightness.
    my @conv_to_remove;
    for my $u (@units) {
        next unless $u;
        next if $u->{is_trailing_summary} || $u->{is_orphan_tool_result};
        next if $u->{has_tool_error};
        if ($u->{has_empty_assistant} || $u->{is_acknowledgement}) {
            push @conv_to_remove, $u;
        }
    }
    if (@conv_to_remove) {
        my @filtered;
        my $removed = 0;
        for my $msg (@conversation) {
            my $belongs = 0;
            for my $u (@conv_to_remove) {
                if (grep { $_ == $msg } @{$u->{messages}}) {
                    $belongs = 1;
                    last;
                }
            }
            if (!$belongs) {
                push @filtered, $msg;
            } else {
                $current_tokens -= estimate_tokens($msg->{content} || '') + 4;
                $removed++;
            }
        }
        @conversation = @filtered;
        log_debug('MessageValidator', "Tier 4 cleanup: removed $removed ack/empty messages from kept conversation");
    }

    # Second pass (BUG C): walk error units in reverse (newest first) and
    # include them only if remaining budget allows. Newest errors are most
    # relevant (the model's recent failures); oldest error noise is dropped.
    # If the unit budget was already exceeded by non-error units, the
    # entire error stream goes to dropped_units and gets compressed into
    # the thread_summary, which is desirable — a long error loop's content
    # is summarized, not preserved verbatim.
    if (@error_units) {
        # Newest first
        for my $unit (reverse @error_units) {
            if ($current_tokens + $unit->{tokens} <= $post_trim_keep_limit) {
                unshift @conversation, @{$unit->{messages}};
                $current_tokens += $unit->{tokens};
                for my $id (keys %{$unit->{tool_call_ids} || {}}) {
                    $included_tool_ids{$id} = 1;
                }
                log_debug('MessageValidator',
                    "Preserved error unit at end of budget (tokens=$unit->{tokens}, current=$current_tokens)");
            } else {
                push @dropped_units, $unit;
                log_debug('MessageValidator',
                    "Dropped error unit (would exceed budget: tokens=$unit->{tokens}, current=$current_tokens)");
            }
        }
    }

    # Calculate total tokens in dropped units for proactive CSSS slot growth
    my $dropped_tokens = 0;
    $dropped_tokens += $_->{tokens} for @dropped_units;
    # Create merged summary only if there are dropped messages to compress.
    # If nothing was dropped, preserve the existing summary as-is.
    my $summary_to_use;
    # CSSS (Cache-Stable Summary Slot): bounding summary size.
    #
    # Earlier versions tried to lock the summary at a constant byte size
    # for cache stability, padding undersized summaries with thousands
    # of x's to fill the slot. The padding was visible to the model as
    # a massive artifact inside <thread_summary> and burned context
    # budget. See git history of YaRN.pm:_fit_summary_to_target.
    #
    # Current policy: target_tokens is a CEILING, not an exact target.
    # The summary grows organically with dropped content. We only
    # enforce a maximum (MAX_CSSS_SLOT_TOKENS) to prevent unbounded
    # growth when aggressive trims drive large amounts of content into
    # the summary. The summary slot itself can be smaller than MAX
    # when there's less dropped content - this is the desired behavior.
    #
    # Cache impact: when the summary grows, the cache invalidates on
    # the summary position itself. That's a one-time cost per growth
    # event (much cheaper than paying thousands of padding tokens on
    # every turn).
    my $summary_slot_target = 0;
    if ($summary_unit && $summary_unit->{tokens}) {
        my $current_slot = $summary_unit->{tokens};
        # Lock the slot to the EXISTING summary size - no floor. The
        # summary slot grows with content but never shrinks (we
        # don't try to compact it back down).
        $summary_slot_target = $current_slot;
        log_debug('MessageValidator', "CSSS: slot target $summary_slot_target (current summary size)");

        # Proactive growth: if dropped content is > 1.5x slot, grow the
        # slot ceiling before compression. This prevents the summary
        # from being hard-truncated and silently dropping the "Current
        # task" or other critical context.
        if ($dropped_tokens > $summary_slot_target * 1.5) {
            my $max_slot = CLIO::Core::Defaults::MAX_CSSS_SLOT_TOKENS();
            my $new_slot = int($summary_slot_target * 1.5);
            $new_slot = $max_slot if $new_slot > $max_slot;
            if ($new_slot > $summary_slot_target) {
                log_info('MessageValidator', "CSSS: proactive growth $summary_slot_target -> $new_slot (dropped: $dropped_tokens tokens, 1.5x threshold)");
                $summary_slot_target = $new_slot;
            }
        }
    } elsif (@dropped_units) {
        # First trim: no existing summary. Just let the summary grow
        # organically with dropped content. _fit_summary_to_target
        # only enforces the ceiling, not a floor. This means small
        # sessions get tiny summaries (good) and big sessions get
        # summaries up to MAX_CSSS_SLOT_TOKENS.
        $summary_slot_target = CLIO::Core::Defaults::MAX_CSSS_SLOT_TOKENS();
        log_debug('MessageValidator', "CSSS: first trim, target = MAX ceiling $summary_slot_target (organic growth)");
    }

    if (@dropped_units) {
        my $compressed = _compress_dropped(\@dropped_units, $last_user_unit, $debug, $previous_summary_content, $summary_slot_target);
        $summary_to_use = $compressed;
        if ($compressed && $compressed->{_metadata}) {
            my $actual = $compressed->{_metadata}{compressed_tokens} || 0;
            log_debug('MessageValidator', "CSSS: regenerated summary to $actual tokens (slot target: $summary_slot_target)");
        }
    } elsif ($summary_unit && $summary_unit->{messages} && @{$summary_unit->{messages}}) {
        # No new drops - keep the existing summary intact
        $summary_to_use = $summary_unit->{messages}[0];
        log_debug('MessageValidator', "No dropped messages - preserving existing thread_summary");
    }
    
    # Post-truncation validation: drop orphaned tool_results whose tool_call
    # was in a dropped unit. With unit-based trim (no deinterleave), each
    # unit keeps tool_calls and their tool_results together — so this should
    # rarely fire. But it's defense-in-depth for units that straddle the
    # budget boundary (e.g. a large assistant+tool pair where the budget
    # walk kept the assistant but the tool_result's unit was built separately
    # by _group_into_units).
    my @validated;
    for my $msg (@conversation) {
        my $is_tool_result = $msg->{tool_call_id} || ($msg->{role} && $msg->{role} eq 'tool');
        if ($is_tool_result && $msg->{tool_call_id} && !$included_tool_ids{$msg->{tool_call_id}}) {
            log_debug('MessageValidator', "Dropping orphaned tool_result after truncation (tool_call in dropped unit)");
            next;
        }
        push @validated, $msg;
    }
    
    # Final cleanup: strip any pre-existing orphans (from stale snapshots,
    # etc.) so the wire payload always has matching tool_call/tool_result
    # pairs. This is a no-op on clean input.
    @validated = @{ validate_tool_message_pairs(\@validated) };
    
    # Combine: system + compressed summary + validated conversation
    # Ensure at least one user message exists in the conversation.
    # In long autonomous tool loops (50+ iterations), the original user message
    # can be far enough back that the budget walk drops it. Without a user
    # message, the model sees only assistant+tool pairs and may hallucinate
    # that it's in a new session with no active task.
    my $has_user_msg = grep { $_->{role} && $_->{role} eq 'user' } @validated;
    if (!$has_user_msg && $last_user_unit && @{$last_user_unit->{messages}}) {
        my $user_content = $last_user_unit->{messages}[0]{content} || '';
        if (length($user_content) > 0) {
            # Inject the most recent user message at the start of the conversation
            # so the model knows there's an active task
            unshift @validated, { role => 'user', content => $user_content };
            log_info('MessageValidator', "Injected preserved user message (budget walk dropped it)");
        }
    }
    if (!$has_user_msg && !($last_user_unit && @{$last_user_unit->{messages}})) {
        # No user unit found at all - extract task from thread_summary as fallback
        my $task_content = '';
        if ($summary_to_use && $summary_to_use->{content}) {
            if ($summary_to_use->{content} =~ /Current task:\s*(.+?)(?:\n\n|\z)/s) {
                $task_content = $1;
            }
        }
        if (length($task_content) > 0) {
            unshift @validated, { role => 'user', content => $task_content };
            log_info('MessageValidator', "Injected synthetic user message from thread_summary task");
        }
    }

    # If the most recent user message in the conversation is too short to
    # be a real task (e.g. "continue", "go", "yes" - < 50 chars) but a
    # SUBSTANTIVE user message exists somewhere (in the dropped set or
    # already-preserved tail), inject the substantive content as a fresh
    # user message BEFORE the short one. This anchors the model on the
    # original task even when the user has been issuing "continue"
    # directives between major phases.
    #
    # Without this, the model sees only the short directive and concludes
    # there is no active task. With it, the model sees both the original
    # task description (its anchor) and the recent directive (its
    # immediate instruction) in the correct chronological order.
    #
    # Only inject if the substantive user is NOT already in @validated
    # (skip if it's the same as the most recent user - that path is
    # already covered by the !has_user_msg branch above).
    if ($substantive_user_content
        && length($substantive_user_content) >= 50
        && $last_user_unit
        && $last_user_unit != $substantive_user_unit) {
        my $already_has_substantive = 0;
        for my $msg (@validated) {
            next unless $msg->{role} && $msg->{role} eq 'user';
            my $existing = $msg->{content} // '';
            if ($existing eq $substantive_user_content) {
                $already_has_substantive = 1;
                last;
            }
        }
        if (!$already_has_substantive) {
            # Find the position of the most recent user message and
            # insert the substantive one BEFORE it. Most recent is the
            # last role=user entry in @validated.
            my $insert_idx = scalar(@validated);
            for (my $i = $#validated; $i >= 0; $i--) {
                if ($validated[$i]{role} && $validated[$i]{role} eq 'user') {
                    $insert_idx = $i;
                    last;
                }
            }
            splice @validated, $insert_idx, 0,
                { role => 'user', content => $substantive_user_content };
            log_info('MessageValidator',
                "Injected original user task before 'continue' prompt "
                . "(" . length($substantive_user_content) . " chars) - "
                . "prevents the model from concluding 'no active task' after trim");
        }
    }
    my @truncated;
    push @truncated, $system_msg if $system_msg;
    # Preserve general static system messages (context_files, recovery notices)
    # at their original leading position. Without this, trimming drops them,
    # changing the prompt_stable_prefix_tokens hint and permanently collapsing
    # the LCP cache (server.log: stable prefix dropped 29032 -> 24168 on first
    # trim when context_files were silently skipped).
    if (@$preserved_general_system) {
        log_debug('MessageValidator', "Preserving " . scalar(@$preserved_general_system) .
            " general system message(s) at leading position for cache stability");
        for my $gs_unit (@$preserved_general_system) {
            push @truncated, $_ for @{$gs_unit->{messages}};
        }
    }
    # CRITICAL FIX: Place the CSSS thread_summary BETWEEN the old dialog
    # and the current turn's user_context/user_input, NOT after everything.
    #
    # Previously, the summary was pushed after ALL of @validated (which
    # includes user_context + user_input + assistant response + tool_results
    # from the current turn). This caused <thread_summary> to appear as a
    # mid-conversation system block — after user_input, before the model's
    # response — which the llama.cpp chat template wraps in <system>...</system>
    # tags, resetting the model's context framing and causing gradual
    # degradation (empty content, error loops, mid-session agent restart,
    # observed in session f091a4e1 2026-08-27).
    #
    # Per the pipeline protocol, the canonical order is:
    #   [sys][context_files][dialog][summary][user_context][user_input][...]
    # The summary sits at the END of the old dialog, before the current
    # turn's dynamic sections. This keeps the summary out of the active
    # conversation flow and stabilises the LCP cache prefix.
    #
    # Split @validated at the last user_context system message to separate
    # "old dialog" (before the current turn's user_context) from "current
    # turn" (user_context, user_input, assistant, tool_results). If no
    # user_context is present in @validated, the entire @validated is the
    # dialog and the summary goes at the very end (first-turn case).
    my $uc_split_idx = -1;
    for my $i (reverse 0 .. $#validated) {
        my $m = $validated[$i];
        next unless ref($m) eq 'HASH';
        my $content = $m->{content} // '';
        next unless ($m->{role} // '') eq 'system';
        next if $content =~ /<thread_summary>/;
        if ($content =~ /<(?:userContext|dynamicContext|sessionGoals)[\s>]/) {
            $uc_split_idx = $i;
            last;
        }
    }

    my @dialog_part = $uc_split_idx >= 0 ? @validated[0 .. $uc_split_idx - 1] : @validated;
    my @trailing_turn = $uc_split_idx >= 0 ? @validated[$uc_split_idx .. $#validated] : ();

    # Emit old dialog, then the CSSS summary, then the current turn.
    # This places the summary between old dialog and user_context/user_input
    # per the pipeline protocol, preventing the summary from appearing as a
    # mid-conversation system block that resets the model's context framing.
    push @truncated, @dialog_part;
    push @truncated, $summary_to_use if $summary_to_use;

    # Emit leading user_context anchors (extracted by the first pass when
    # user_context was at a leading position) AFTER the summary, not before
    # the dialog. Placing them at position 1 (leading) caused them to change
    # every minute (timestamp), shifting all downstream token positions and
    # permanently collapsing the LCP cache. After the summary is the correct
    # canonical position. Skip if @validated already contains a trailing
    # user_context (avoids duplicates — keep the most recent one).
    if ($uc_split_idx < 0 && @$preserved_user_contexts) {
        for my $uc_unit (@$preserved_user_contexts) {
            push @truncated, $_ for @{$uc_unit->{messages}};
        }
    }

    # Emit the current turn's messages (user_context, user_input,
    # assistant response, tool_results) after the summary.
    push @truncated, @trailing_turn;

    if (should_log('DEBUG')) {
        my $final_tokens = _estimate_tokens(\@truncated);
        log_debug('MessageValidator', "Truncated: " . scalar(@$messages) . " -> " . scalar(@truncated) .
            " messages, $final_tokens tokens");
        # Diagnostic: report cache impact of the trim. With CSSS, this should
        # be at most the summary slot size (everything else is byte-stable).
        my $summary_tokens_now = 0;
        if ($summary_to_use && $summary_to_use->{content}) {
            $summary_tokens_now = estimate_tokens($summary_to_use->{content});
        }
        if ($summary_slot_target > 0 && $summary_tokens_now > 0) {
            my $delta = abs($summary_tokens_now - $summary_slot_target);
            log_debug('MessageValidator', sprintf(
                "CSSS: cache impact ~%d/%d tokens invalidated (summary slot)",
                $delta, $final_tokens));
        }
    }

    return \@truncated;
}

=head2 validate_tool_message_pairs

Bidirectional validation of tool_calls and tool_results.
Removes orphaned tool_calls (strips from assistant messages) and
orphaned tool_results (removes entirely).

Arguments:
    $messages - ArrayRef of message objects

Returns: Validated ArrayRef

=cut

sub validate_tool_message_pairs {
    my ($messages) = @_;
    
    return [] unless $messages && @$messages;
    
    # Build bidirectional maps: tool_call_id -> assistant index, tool_call_id -> result index
    my %tc_id_to_assistant_idx;   # tool_call_id -> message index of assistant
    my %tr_id_to_result_idx;      # tool_call_id -> message index of tool result
    
    for (my $i = 0; $i < @$messages; $i++) {
        my $msg = $messages->[$i];
        if ($msg->{role} && $msg->{role} eq 'assistant' && 
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                $tc_id_to_assistant_idx{$tc->{id}} = $i if $tc->{id};
            }
        }
        if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
            $tr_id_to_result_idx{$msg->{tool_call_id}} = $i;
        }
    }
    
    # Identify orphaned tool_call IDs (no matching result) and orphaned result IDs (no matching call)
    my %orphaned_tc_ids;
    for my $tc_id (keys %tc_id_to_assistant_idx) {
        unless (exists $tr_id_to_result_idx{$tc_id}) {
            $orphaned_tc_ids{$tc_id} = 1;
            log_debug('MessageValidator', "Orphaned tool_call: $tc_id at message $tc_id_to_assistant_idx{$tc_id}");
        }
    }
    
    my %orphaned_result_indices;
    for my $tr_id (keys %tr_id_to_result_idx) {
        unless (exists $tc_id_to_assistant_idx{$tr_id}) {
            $orphaned_result_indices{$tr_id_to_result_idx{$tr_id}} = 1;
            log_debug('MessageValidator', "Orphaned tool_result: $tr_id at message $tr_id_to_result_idx{$tr_id}");
        }
    }
    
    # If no orphans, return original
    if (!keys %orphaned_tc_ids && !keys %orphaned_result_indices) {
        log_debug('MessageValidator', "Tool message validation: all pairs valid");
        return $messages;
    }
    
    # Rebuild: remove orphaned results entirely, selectively strip orphaned tool_calls
    my @validated;
    my $fixes = 0;
    for (my $i = 0; $i < @$messages; $i++) {
        my $msg = $messages->[$i];
        
        # Drop orphaned tool results
        if ($orphaned_result_indices{$i}) {
            log_debug('MessageValidator', "Removing orphaned tool_result at index $i");
            $fixes++;
            next;
        }
        
        # For assistant messages with tool_calls, strip only the orphaned ones
        if ($msg->{role} && $msg->{role} eq 'assistant' &&
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            
            my @kept_calls;
            my @dropped_calls;
            for my $tc (@{$msg->{tool_calls}}) {
                if ($tc->{id} && $orphaned_tc_ids{$tc->{id}}) {
                    push @dropped_calls, $tc->{id};
                } else {
                    push @kept_calls, $tc;
                }
            }
            
            if (@dropped_calls) {
                $fixes += scalar(@dropped_calls);
                log_debug('MessageValidator', "Stripped " . scalar(@dropped_calls) .
                    " orphaned tool_calls from assistant at index $i" .
                    " (kept " . scalar(@kept_calls) . ")");
                
                if (@kept_calls) {
                    # Keep assistant with remaining matched tool_calls
                    push @validated, {
                        %$msg,
                        tool_calls => \@kept_calls,
                    };
                } else {
                    # All tool_calls orphaned - keep as plain assistant
                    push @validated, { role => $msg->{role}, content => $msg->{content} || '' };
                }
                next;
            }
        }
        
        push @validated, $msg;
    }
    
    log_info('MessageValidator', "Fixed $fixes orphaned tool messages") if $fixes > 0;
    
    return \@validated;
}

=head2 preflight_validate

Lightweight pre-flight validation. Returns ArrayRef of error strings.

=cut

sub preflight_validate {
    my ($messages) = @_;
    
    return [] unless $messages && @$messages;
    
    my @errors;
    my %tool_call_ids;
    my %tool_result_ids;
    my %seen_ids;
    
    for (my $i = 0; $i < @$messages; $i++) {
        my $msg = $messages->[$i];
        my $role = $msg->{role} || '';
        
        if ($role eq 'assistant' && $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                my $id = $tc->{id};
                if ($id) {
                    push @errors, "Duplicate tool_call_id: $id" if $seen_ids{$id};
                    $seen_ids{$id} = $i;
                    $tool_call_ids{$id} = $i;
                }
            }
        }
        
        if ($role eq 'tool' && $msg->{tool_call_id}) {
            $tool_result_ids{$msg->{tool_call_id}} = $i;
        }
    }
    
    for my $id (keys %tool_call_ids) {
        push @errors, "Orphaned tool_call: $id" unless exists $tool_result_ids{$id};
    }
    for my $id (keys %tool_result_ids) {
        push @errors, "Orphaned tool_result: $id" unless exists $tool_call_ids{$id};
    }
    
    return \@errors;
}

# ================================================================
# Private helper functions
# ================================================================

sub _calculate_tool_tokens {
    my ($tools) = @_;
    return 0 unless $tools && ref($tools) eq 'ARRAY' && @$tools;
    
    require CLIO::Memory::TokenEstimator;
    my $ratio = CLIO::Memory::TokenEstimator::get_effective_ratio();
    
    my $total = 0;
    for my $tool (@$tools) {
        my $tool_json = safe_encode_json($tool);
        if ($tool_json) {
            $total += int(length($tool_json) / $ratio);
        } else {
            $total += 600;
        }
    }
    
    log_debug('MessageValidator', "Tool token budget: $total tokens for " . scalar(@$tools) . " tools (ratio: $ratio)");
    return $total;
}

sub _estimate_tokens {
    my ($messages) = @_;

    my $total = 0;
    for my $msg (@$messages) {
        # Per-message overhead: role field, message separators, formatting tokens
        # Every message has role + boundary tokens (~4)
        # Tool messages have additional name + tool_call_id fields (~8)
        $total += 4;                                                      # base overhead
        $total += 8 if $msg->{role} && $msg->{role} eq 'tool';           # tool-specific fields

        $total += estimate_tokens($msg->{content} || '');
        if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                my $json = safe_encode_json($tc);
                $total += estimate_tokens($json || '');
            }
        }
    }
    return $total;
}

sub _group_into_units {
    my ($messages) = @_;

    my @units;
    my $current_unit;
    my %pending_tool_ids;
    my %tool_call_id_to_unit_idx;

    for my $msg (@$messages) {
        my $msg_tokens = estimate_tokens($msg->{content} || '') + 4;
        $msg_tokens += 8 if $msg->{role} && $msg->{role} eq 'tool';
        my $has_tool_calls = $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY' && @{$msg->{tool_calls}};
        my $is_tool_result = $msg->{tool_call_id} || ($msg->{role} && $msg->{role} eq 'tool');

        # BUG C: Mark tool_results that contain TOOL ERROR responses so the
        # budget walk can prefer them for dropping. These are the LOWEST
        # priority content in the prompt — they convey "this approach
        # failed" but no longer serve a useful purpose once the model has
        # moved on. Keeping them costs token budget that should go to the
        # actual task work. Only mark the FIRST tool_result that immediately
        # follows the assistant's tool_call (i.e. a normal error response,
        # not a follow-up retry error which might be in a different unit).
        my $is_tool_error = 0;
        if ($is_tool_result && ($msg->{content} // '') =~ /^\s*TOOL ERROR[: ]|^\s*ERROR[: ]|^STOP:/) {
            $is_tool_error = 1;
        }
        
        if ($has_tool_calls) {
            push @units, $current_unit if $current_unit;

            # Include tool_call JSON tokens in the unit's token count
            my $tc_tokens = 0;
            for my $tc (@{$msg->{tool_calls}}) {
                my $json = safe_encode_json($tc, '');
                $tc_tokens += estimate_tokens($json);
            }
            $current_unit = { messages => [$msg], tokens => $msg_tokens + $tc_tokens, tool_call_ids => {} };
            %pending_tool_ids = ();

            for my $tc (@{$msg->{tool_calls}}) {
                if ($tc->{id}) {
                    $pending_tool_ids{$tc->{id}} = 1;
                    $current_unit->{tool_call_ids}{$tc->{id}} = 1;
                    $tool_call_id_to_unit_idx{$tc->{id}} = scalar(@units);
                }
            }
        }
        elsif ($is_tool_result) {
            my $tool_id = $msg->{tool_call_id};

            if ($current_unit) {
                # Track error tool_results separately so the budget walk can
                # prefer to drop them. We attach the marker to the unit so
                # when the whole unit is dropped the marker stays consistent.
                $current_unit->{has_tool_error} = 1 if $is_tool_error;
                push @{$current_unit->{messages}}, $msg;
                $current_unit->{tokens} += $msg_tokens;
                delete $pending_tool_ids{$tool_id} if $tool_id;

                if (!keys %pending_tool_ids) {
                    push @units, $current_unit;
                    $current_unit = undef;
                }
            }
            elsif ($tool_id && exists $tool_call_id_to_unit_idx{$tool_id}) {
                my $parent_idx = $tool_call_id_to_unit_idx{$tool_id};
                if ($parent_idx < scalar(@units)) {
                    push @{$units[$parent_idx]{messages}}, $msg;
                    $units[$parent_idx]{tokens} += $msg_tokens;
                    log_debug('MessageValidator', "Merged orphan tool_result to unit $parent_idx");
                } else {
                    push @units, { messages => [$msg], tokens => $msg_tokens, 
                                   tool_call_ids => {}, is_orphan_tool_result => 1,
                                   orphan_tool_id => $tool_id };
                }
            }
            else {
                log_debug('MessageValidator', "Orphan tool_result: $tool_id (from truncation)");
                push @units, { messages => [$msg], tokens => $msg_tokens,
                               tool_call_ids => {}, is_orphan_tool_result => 1,
                               orphan_tool_id => $tool_id };
            }
        }
        else {
            if ($current_unit) {
                push @units, $current_unit;
                $current_unit = undef;
                %pending_tool_ids = ();
            }
            my $new_unit = { messages => [$msg], tokens => $msg_tokens, tool_call_ids => {} };
            # Trim priority Tier 4 detection: flag non-tool messages that
            # contribute nothing to the dialog. These are the FIRST units
            # dropped when the budget is tight, ahead of any Tier 3 unit.
            # See docs/SPECS/TRIM_PRIORITY.md for tier definitions.
            if ($msg->{role} && $msg->{role} eq 'assistant') {
                my $content = $msg->{content} // '';
                my $has_reasoning = defined $msg->{reasoning_content}
                    && length($msg->{reasoning_content} // '');
                # Match whitespace-only content (single-line or multi-line) as empty
                # assistant, and short single-line content (< ACK_THRESHOLD)
                # as acknowledgement. The newline check is conservative -
                # true acks rarely span multiple lines.
                if (!$has_tool_calls && !$has_reasoning
                    && $content !~ /[^\s]/) {
                    # All whitespace (including multi-line) counts as empty.
                    $new_unit->{has_empty_assistant} = 1;
                } elsif (!$has_tool_calls && !$has_reasoning
                    && length($content) < CLIO::Core::Defaults::ACK_THRESHOLD_CHARS()
                    && $content !~ /\n/) {
                    $new_unit->{is_acknowledgement} = 1;
                }
            }
            push @units, $new_unit;
        }
    }

    push @units, $current_unit if $current_unit;

    return (\@units, \%tool_call_id_to_unit_idx);
}

sub _extract_preserved_units {
    my ($units) = @_;

    my $system_msg;
    my $start_unit = 0;
    my $system_tokens = 0;
    my $summary_unit;         # Previous thread_summary (preserved across trims)
    my $summary_tokens = 0;
    my @preserved_user_contexts;  # user_context anchors (<dynamicContext>/<userContext>/<sessionGoals>)
                                  # at non-trailing positions - preserved to keep chat template prefix
                                  # stable across trims. Without this, dropping user_context at msg[1]
                                  # causes the chat template's <system>...</system> block to disappear,
   # which changes the prefix tokens and breaks llama.cpp's LCP cache (the CachyLLama
   # full re-prompt bug observed 2026-08-18).
    my @preserved_general_system;  # Other static system messages (context_files,
                                  # recovery notices) at non-trailing positions.
                                  # Previously these were silently dropped, which
                                  # changed the stable prefix token count on the
                                  # first trim (e.g. 29032 -> 24168 when context_files
                                  # were removed), causing sim_best to collapse.
                                  # Now they are preserved at their leading position
                                  # so the stable prefix stays constant across trims.

    # Extract system message
    if (@$units && @{$units->[0]{messages}} && $units->[0]{messages}[0]{role} eq 'system') {
        $system_msg = $units->[0]{messages}[0];
        $system_tokens = $units->[0]{tokens};
        $start_unit = 1;
    }

    # Walk units between system_msg and the conversation start, preserving:
    #   - thread_summary system messages (CSSS slot)
    #   - user_context system messages (<dynamicContext>/<userContext>/<sessionGoals>)
    #     These render as <system>...</system> blocks in the chat template. If
    #     dropped, the chat template output diverges in the prefix region and
    #     llama.cpp's LCP cache match fails (forcing a full re-prompt).
    for my $i ($start_unit .. $#$units) {
        my $unit = $units->[$i];
        next unless $unit && $unit->{messages} && @{$unit->{messages}};

        my $first_msg = $unit->{messages}[0];
        my $content = $first_msg->{content} || '';
        if ($content =~ /<thread_summary>/) {
            $summary_unit = $unit;
            $summary_tokens = $unit->{tokens};
            $start_unit = $i + 1;
            log_debug('MessageValidator', "Preserving thread_summary ($summary_tokens tokens)");
        } elsif ($first_msg->{role} && $first_msg->{role} eq 'system') {
            # user_context anchor at this position - preserve it. Trailing
            # user_context (at the end of @messages) is handled by the trim
            # walk below since it falls within @remaining.
            if ($content =~ /^\s*<(?:userContext|dynamicContext|sessionGoals)[\s>]/) {
                push @preserved_user_contexts, $unit;
                log_debug('MessageValidator', "Preserving user_context anchor at unit $i");
            }
            # Other system messages (context_files, recovery notices, etc.)
            # between system_msg and the conversation. Preserve them at their
            # leading position to keep the stable prefix constant across
            # trims. Previously these were skipped silently (dropped), which
            # caused context_files (~4864 tokens) to vanish from the prompt
            # on the first trim, changing prompt_stable_prefix_tokens from
            # 29032 to 24168 and permanently collapsing the LCP cache hit.
            else {
                push @preserved_general_system, $unit;
                log_debug('MessageValidator', "Preserving general system message at unit $i (content starts with: " . substr($content, 0, 30) . ")");
            }
        } elsif ($first_msg->{role} && $first_msg->{role} ne 'system') {
            # Hit a non-system message - start of conversation
            $start_unit = $i;
            last;
        }
    }

    # SECOND PASS: scan remaining units for trailing thread_summary.
    # The CSSS summary is placed at the END of the message array by the
    # proactive trim ([sys][dialog...][summary]), but the walk above only
    # finds summaries at LEADING positions (before the dialog). Without
    # this second pass, the CSSS slot is never locked — every trim
    # regenerates the summary with different content/size, changing the
    # LCP prefix boundary and causing sim_best to stay collapsed at ~0.2
    # (observed in the PhotonTERM session logs, 2026-08-26: every trim
    # logged "CSSS: first trim slot target 8000" even at iteration 27+).
    #
    # Find the LAST thread_summary unit. If found, set $summary_unit/
    # $summary_tokens (for CSSS slot locking) and mark the unit with
    # is_trailing_summary so the budget walk skips it — otherwise it's
    # double-counted (kept in conversation AND compressed into new summary).
    for my $i (reverse ($start_unit .. $#$units)) {
        my $unit = $units->[$i];
        next unless $unit && $unit->{messages} && @{$unit->{messages}};
        my $first_msg = $unit->{messages}[0];
        my $content = $first_msg->{content} || '';
        if ($content =~ /<thread_summary>/) {
            $summary_unit = $unit;
            $summary_tokens = $unit->{tokens};
            $unit->{is_trailing_summary} = 1;
            log_debug('MessageValidator',
                "Found trailing thread_summary at unit $i ($summary_tokens tokens) " .
                "- CSSS slot will lock across trims");
            last;
        }
    }
    
    # Find the MOST RECENT user unit for task context preservation.
    # The most recent user message represents the current work; the
    # original task is captured in the thread_summary.
    #
    # Layer 3 of trim-loss fix: we walk newest-to-oldest to find the
    # most recent user-role message and preserve that unit at full
    # content. This handles the case where a long autonomous tool loop
    # (50+ iterations) drops the original user prompt along with the
    # oldest dialog — the budget walk goes newest-to-oldest and the
    # original user message is at the bottom. Without this guard, the
    # model sees only assistant+tool pairs after trim and may hallucinate
    # that there's no active task.
    #
    # We preserve the unit (full content) not just the message text so
    # any tool_calls paired with the user message (rare but possible
    # when the user message is delivered via a tool) survive too.
    # One message, position-stable — does not affect LCP cache hit
    # because the stable prefix (sys + summary + dialog at front) is
    # unchanged regardless of how many user messages are dropped.
    my $last_user_unit;
    my $last_user_tokens = 0;
    my $last_user_idx = -1;
    my $last_user_content = '';
    for my $i ($start_unit .. $#$units) {
        my $unit = $units->[$i];
        next unless $unit && $unit->{messages} && @{$unit->{messages}};
        my $first_msg = $unit->{messages}[0];
        if ($first_msg->{role} && $first_msg->{role} eq 'user') {
            $last_user_unit = $unit;
            $last_user_tokens = $unit->{tokens};
            $last_user_idx = $i;
            $last_user_content = $first_msg->{content} // '';
        }
    }

    if ($last_user_unit) {
        log_debug('MessageValidator', "Found most recent user message at unit $last_user_idx (tokens=$last_user_tokens)");
    }

    # ALSO find the most recent SUBSTANTIVE user message - one whose
    # content is a real task (>= 50 chars) rather than a short directive
    # like "continue", "go", "yes", "ok". The substantive message is the
    # original task anchor the model needs to keep its place after trim.
    #
    # Without this guard, a long autonomous tool loop (50+ iterations)
    # where the user types "continue" between major phases ends up with
    # "continue" (7 tokens) as the only user message in the conversation
    # after the budget walk drops everything else. The model then sees
    # only assistant+tool pairs + an empty "continue" prompt, concludes
    # there's no active task, and starts over (observed in session
    # a6a0eb10, 2026-08-29 — agent "lost its place" and emitted "no
    # actual user message yet" reasoning).
    #
    # We walk the full unit list (not just from $start_unit) so the
    # substantive user is found even when it ended up in the dropped
    # tail (the common case after budget walk). The substantive user
    # is NOT injected into the conversation by this function — that
    # decision lives in the post-trim assembly, which decides whether
    # to (a) inject the substantive user as a real user message, or
    # (b) surface it via the user_context (<userContext>) system
    # message so the model sees it as a fresh directive rather than
    # archival metadata.
    my $substantive_user_unit;
    my $substantive_user_tokens = 0;
    my $substantive_user_idx = -1;
    my $substantive_user_content = '';
    my $min_substantive_len = 50;
    for my $i ($start_unit .. $#$units) {
        my $unit = $units->[$i];
        next unless $unit && $unit->{messages} && @{$unit->{messages}};
        my $first_msg = $unit->{messages}[0];
        next unless $first_msg && $first_msg->{role} && $first_msg->{role} eq 'user';
        my $content = $first_msg->{content} // '';
        # Skip the chunk-pointer artifacts YaRN.compress injects.
        next if $content =~ /^\s*\w[\w\-_.]+\s+\([^)]+:\s*[^)]+\)\s*\(\d+\s*bytes/;
        next if length($content) < $min_substantive_len;
        $substantive_user_unit = $unit;
        $substantive_user_tokens = $unit->{tokens};
        $substantive_user_idx = $i;
        $substantive_user_content = $content;
        last;  # newest first
    }

    if ($substantive_user_unit) {
        if ($substantive_user_idx == $last_user_idx) {
            log_debug('MessageValidator',
                "Found substantive user message at unit $substantive_user_idx "
                . "(tokens=$substantive_user_tokens) - same as most recent user");
        } else {
            log_debug('MessageValidator',
                "Found substantive user message at unit $substantive_user_idx "
                . "(tokens=$substantive_user_tokens), distinct from most recent user at "
                . "unit $last_user_idx (tokens=$last_user_tokens) - the original task is here");
        }
    }

    # Return both the unit (for the existing preserved-user-message
    # injection path) and the content (for any future path that wants
    # the bare text without the unit structure).
    return ($system_msg, $last_user_unit, $start_unit, $system_tokens, $last_user_tokens,
            $summary_unit, $summary_tokens, \@preserved_user_contexts, \@preserved_general_system,
            $substantive_user_unit, $substantive_user_tokens, $substantive_user_content);
}

sub _compress_dropped {
    my ($dropped_units, $last_user_unit, $debug, $previous_summary, $target_tokens) = @_;

    return undef unless $dropped_units && @$dropped_units;

    my @dropped_messages;
    for my $unit (@$dropped_units) {
        push @dropped_messages, @{$unit->{messages}};
    }

    log_debug('MessageValidator', "Compressing " . scalar(@dropped_messages) . " dropped messages" .
        ($target_tokens ? " (CSSS target: $target_tokens tokens)" : ''));

    my $compressed;
    eval {
        require CLIO::Memory::YaRN;
        my $yarn = CLIO::Memory::YaRN->new(debug => $debug);

        # Get task context from most recent user message, falling back to
        # a substantive message from the dropped set if it's too short.
        my $original_task = '';
        if ($last_user_unit && @{$last_user_unit->{messages}}) {
            $original_task = $last_user_unit->{messages}[0]{content} || '';
        }
        $original_task = CLIO::Memory::YaRN::find_substantive_task($original_task, \@dropped_messages);
        
        $compressed = $yarn->compress_messages(\@dropped_messages,
            original_task    => $original_task,
            previous_summary => $previous_summary,
            target_tokens    => $target_tokens,
        );
        
        log_debug('MessageValidator', "Compression successful: " . scalar(@dropped_messages) . 
            " messages -> " . ($compressed->{_metadata}{compressed_tokens} || 0) . " tokens");
    };
    if ($@) {
        log_warning('MessageValidator', "Compression failed: $@");
        return undef;
    }
    
    return $compressed;
}

1;

__END__

=head1 AUTHOR

CLIO Project - Extracted from APIManager.pm

=cut

1;
