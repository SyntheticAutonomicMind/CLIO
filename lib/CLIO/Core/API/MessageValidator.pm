package CLIO::Core::API::MessageValidator;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
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
    
    # Extract system message and most recent user message
    my ($system_msg, $last_user_unit, $start_unit, $system_tokens, $last_user_tokens,
        $summary_unit, $summary_tokens, $_unused) = 
        _extract_preserved_units(\@units);
    
    # Build conversation from newest to oldest
    # Deinterleave collections: dialog at the front (LCP-critical), tool_results
    # at the END (defer until budget is allocated).
    my @dialog = ();
    my @deferred_tool_results = ();
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
    
    my @remaining = @units[$start_unit .. $#units];
    
    # Post-trim target: keep context at the prompt budget computed
    # from model capabilities. The estimation buffer in
    # compute_prompt_budget already covers next-burst headroom; no
    # additional percentage-based haircut is needed.
    #
    # Ring-buffer / sliding window approach: target stays at prompt_budget.
    # Trim only drops the OLDEST non-critical content when budget is exceeded.
    # CSSS (Cache-Stable Summary Slot) handles cache stability for the summary.
    # DEFAULT_POST_TRIM_FLOOR acts as absolute safety floor.
    my $post_trim_keep_limit = $prompt_budget;
    $post_trim_keep_limit = CLIO::Core::Defaults::DEFAULT_POST_TRIM_FLOOR() if $post_trim_keep_limit < CLIO::Core::Defaults::DEFAULT_POST_TRIM_FLOOR();
    log_debug('MessageValidator', "Post-trim keep target: $post_trim_keep_limit tokens (prompt budget for $model)");

    # DIAGNOSTIC: Append post_trim_keep_limit to the validator diagnostic (CLIO_TRIM_DIAG=1 to enable)
    if ($ENV{CLIO_TRIM_DIAG}) {
    eval {
        my $ts = POSIX::strftime('%Y%m%d_%H%M%S', localtime);
        # Append to the most recent validator log
        my @logs = glob("/tmp/clio_trim_validator_*_$$.log");
        if (@logs) {
            my $latest = $logs[-1];
            if (open my $dfh, '>>:encoding(UTF-8)', $latest) {
                print $dfh "post_trim_keep_limit: $post_trim_keep_limit\n";
                print $dfh "system_tokens: $system_tokens\n";
                print $dfh "last_user_tokens: $last_user_tokens\n";
                print $dfh "summary_tokens: $summary_tokens\n";
                print $dfh "units_count: " . scalar(@units) . "\n";
                print $dfh "remaining_units: " . scalar(@remaining) . "\n";
                close $dfh;
            }
        }
    };
    }

    for my $unit (reverse @remaining) {
        if ($unit->{is_orphan_tool_result}) {
            log_debug('MessageValidator', "Skipping orphan tool_result unit (tool_id: $unit->{orphan_tool_id})");
            next;
        }
        
        # Deinterleave: classify each message in the unit as dialog or tool_result.
        # We trim tool_results FIRST (oldest first) before dropping dialog, so the
        # dialog stays at the front of the prompt. This keeps the LCP cache
        # match alive through sys + summary + dialog across trims.
        my $unit_dialog_tokens = 0;
        my @unit_dialog;
        my @unit_tool_results;
        for my $msg (@{$unit->{messages}}) {
            if (($msg->{role} // '') eq 'tool' || $msg->{tool_call_id}) {
                push @unit_tool_results, $msg;
            } else {
                push @unit_dialog, $msg;
                $unit_dialog_tokens += estimate_tokens($msg->{content} // '') + 4;
                $unit_dialog_tokens += 8 if ($msg->{role} // '') eq 'tool';
                # Include tool_call JSON tokens (assistant's tool_calls travel
                # with the dialog, not with the tool_results).
                if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                    for my $tc (@{$msg->{tool_calls}}) {
                        my $json = safe_encode_json($tc, '');
                        $unit_dialog_tokens += estimate_tokens($json);
                    }
                }
            }
        }

        # Always keep dialog if budget allows. Tool_results are deferred and
        # added in the second pass with newest-first priority.
        if (@unit_dialog && $current_tokens + $unit_dialog_tokens <= $post_trim_keep_limit) {
            unshift @dialog, @unit_dialog;
            $current_tokens += $unit_dialog_tokens;
            for my $id (keys %{$unit->{tool_call_ids} || {}}) {
                $included_tool_ids{$id} = 1;
            }
        } elsif (@unit_dialog) {
            # Dialog alone exceeds budget - drop entire unit (rare, only
            # when the conversation itself is larger than the budget).
            push @dropped_units, $unit;
        }

        # Defer tool_results without consuming budget. They'll be added in the
        # second pass in chronological order (already collected in reverse walk).
        unshift @deferred_tool_results, @unit_tool_results;
    }

    # Second pass: add deferred tool_results from NEWEST to OLDEST until the
    # budget is reached. This drops the oldest tool_results first (they're
    # the most expendable - the agent can re-call the tool if needed).
    my @kept_tool_results;
    for my $i (reverse 0 .. $#deferred_tool_results) {
        my $tr = $deferred_tool_results[$i];
        my $tr_tokens = estimate_tokens($tr->{content} // '') + 8;
        if ($current_tokens + $tr_tokens <= $post_trim_keep_limit) {
            unshift @kept_tool_results, $tr;
            $current_tokens += $tr_tokens;
        }
    }

    # Combine: dialog first (in chronological order), then tool_results at the END.
    # The deinterleaved layout keeps the conversation dialog stable at the front
    # of the prompt so llama.cpp's LCP cache match extends through sys + summary
    # + matching dialog instead of collapsing at the first dropped tool message.
    my @conversation = (@dialog, @kept_tool_results);
    if (@deferred_tool_results) {
        log_debug('MessageValidator', sprintf(
            "Deinterleave: %d dialog + %d tool_results kept, %d deferred dropped",
            scalar(@dialog), scalar(@kept_tool_results),
            scalar(@deferred_tool_results) - scalar(@kept_tool_results)));
    }
    
    # Calculate total tokens in dropped units for proactive CSSS slot growth
    my $dropped_tokens = 0;
    $dropped_tokens += $_->{tokens} for @dropped_units;
    
    # Compress dropped units
    # Create merged summary only if there are dropped messages to compress.
    # If nothing was dropped, preserve the existing summary as-is.
    my $summary_to_use;
    # Cache-Stable Summary Slot (CSSS): when an existing thread_summary exists,
    # use its current token count as the target slot size. Subsequent trims
    # regenerate the summary to fit this same slot, so llama.cpp's prefix
    # cache stays valid for everything before and after the summary slot.
    #
    # CRITICAL: The first trim has NO previous summary, so it creates a
    # naturally small summary. If we lock CSSS to that small size, all
    # subsequent trims are starved. Use MIN_CSSS_SLOT_TOKENS as a floor.
    # Also allow proactive growth when dropped content significantly exceeds
    # the current slot (1.5x), rather than waiting for hard truncation.
    my $summary_slot_target = 0;
    if ($summary_unit && $summary_unit->{tokens}) {
        my $current_slot = $summary_unit->{tokens};
        my $min_slot = CLIO::Core::Defaults::MIN_CSSS_SLOT_TOKENS();
        # Use the larger of current slot or minimum floor
        $summary_slot_target = $current_slot < $min_slot ? $min_slot : $current_slot;
        log_debug('MessageValidator', "CSSS: base slot target $summary_slot_target (current: $current_slot, min: $min_slot)");

        # Proactive growth: if dropped content is > 1.5x slot, grow the slot
        # before compression. This prevents the summary from being hard-truncated
        # and silently dropping the "Current task" or other critical context.
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
        # First trim: no existing summary to lock to. Use MIN_CSSS_SLOT_TOKENS
        # as the initial slot size so subsequent trims have a stable target to
        # lock against. Without this, the first summary is naturally tiny
        # (a few tokens for "Current task" + whatever drops compress to) and
        # locks CSSS to that small size forever.
        $summary_slot_target = CLIO::Core::Defaults::MIN_CSSS_SLOT_TOKENS();
        log_debug('MessageValidator', "CSSS: first trim slot target $summary_slot_target (MIN_CSSS_SLOT_TOKENS floor)");
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
    
    # Post-truncation validation
    my @validated;
    for my $msg (@conversation) {
        my $is_tool_result = $msg->{tool_call_id} || ($msg->{role} && $msg->{role} eq 'tool');
        if ($is_tool_result && $msg->{tool_call_id} && !$included_tool_ids{$msg->{tool_call_id}}) {
            log_debug('MessageValidator', "Dropping orphaned tool_result after truncation");
            next;
        }
        push @validated, $msg;
    }
    
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
    my @truncated;
    push @truncated, $system_msg if $system_msg;
    # Cache-stable ordering: summary at position 1 (right after the system
    # prompt) so the LCP match extends through sys + summary on every turn.
    # llama.cpp's server-context.cpp prompt_stable_prefix_tokens floor is
    # explicitly designed for this layout:
    #   "if the caller told us how many leading tokens form a stable prefix
    #    (system prompt + thread_summary), reject any slot whose stored
    #    prompt does not share that prefix"
    # Combined with the deinterleaved tool_results layout below, the LCP
    # match survives a context trim instead of collapsing at the first
    # dropped position. Order: [system][summary][dialog][tool_results]
    push @truncated, $summary_to_use if $summary_to_use;
    push @truncated, @validated;

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
            push @units, { messages => [$msg], tokens => $msg_tokens, tool_call_ids => {} };
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
    
    # Extract system message
    if (@$units && @{$units->[0]{messages}} && $units->[0]{messages}[0]{role} eq 'system') {
        $system_msg = $units->[0]{messages}[0];
        $system_tokens = $units->[0]{tokens};
        $start_unit = 1;
    }
    
    # Find any thread_summary units between system msg and conversation
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
        } elsif ($first_msg->{role} && $first_msg->{role} ne 'system') {
            # Hit a non-system, non-summary message - start of conversation
            $start_unit = $i;
            last;
        }
    }
    
    # Find the MOST RECENT user unit for task context preservation.
    # The most recent user message represents the current work; the
    # original task is captured in the thread_summary.
    my $last_user_unit;
    my $last_user_tokens = 0;
    my $last_user_idx = -1;
    for my $i ($start_unit .. $#$units) {
        my $unit = $units->[$i];
        next unless $unit && $unit->{messages} && @{$unit->{messages}};
        my $first_msg = $unit->{messages}[0];
        if ($first_msg->{role} && $first_msg->{role} eq 'user') {
            $last_user_unit = $unit;
            $last_user_tokens = $unit->{tokens};
            $last_user_idx = $i;
        }
    }
    
    if ($last_user_unit) {
        log_debug('MessageValidator', "Found most recent user message at unit $last_user_idx (tokens=$last_user_tokens)");
    }
    
    return ($system_msg, $last_user_unit, $start_unit, $system_tokens, $last_user_tokens,
            $summary_unit, $summary_tokens, undef);
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
