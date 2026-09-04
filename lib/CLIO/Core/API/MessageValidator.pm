package CLIO::Core::API::MessageValidator;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug log_warning);
use CLIO::Memory::TokenEstimator qw(estimate_tokens compute_prompt_budget);
use CLIO::Util::JSON qw(safe_encode_json);


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
    my $token_ratio = $args{token_ratio};
    my $config = $args{config};
    my $api_base = $args{api_base} || '';
    my $debug = $args{debug};
    my $model = $args{model} || 'unknown';

    # Sanity-check the token_ratio. The ratio is learned from observed
    # token counts and could be wildly off if APIManager picked it up
    # from a different provider/model. A ratio of 0.5 would make
    # _estimate_tokens over-estimate by ~5x; a ratio of 100 would make
    # it under-estimate by ~40x. Either way, the trim walk misjudges
    # budget pressure and either over-trims or under-trims. Clamp to
    # the documented range (1.0..10.0) so a single bad ratio doesn't
    # silently ruin a long session.
    #
    # The regex is `\d+(\.\d+)?` (not `[\d.]+`) so a bare dot, an empty
    # string, or a number with no leading digit (".5") does not match
    # and falls into the else branch without ever triggering Perl's
    # "isn't numeric in numeric lt" warning. Same class of bug Andrew
    # caught in TodoStore in 64de736c.
    if (!defined $token_ratio) {
        $token_ratio = 2.5;
    } elsif ($token_ratio =~ /^\d+(\.\d+)?$/) {
        if ($token_ratio < 1.0 || $token_ratio > 10.0) {
            log_warning('MessageValidator',
                "token_ratio $token_ratio out of range (1.0..10.0) for model $model; clamping to 2.5");
            $token_ratio = 2.5;
        }
    } else {
        $token_ratio = 2.5;
    }
    
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
    require CLIO::Memory::TokenEstimator;
    my $prompt_budget = CLIO::Memory::TokenEstimator::compute_prompt_budget($caps);

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

    # Normal path: messages are role-based (history pushed individually
    # from WorkflowOrchestrator's projection, not bundled into a single
    # system message). Walk from the oldest end and drop messages until
    # we fit, while preserving the first user message (the original
    # task anchor) and keeping tool_call/tool_result pairs together so
    # we never strand an orphan.
    return _role_based_tail_walk($messages, $effective_limit, $debug);
}

=head2 _role_based_tail_walk

Drop messages from the oldest end until the array fits the budget.
Preserves the first user message (original task anchor) and keeps
tool_call/tool_result pairs together (never leaves a tool_result
without its call, or vice versa).

This is the role-based fallback trim path used when the messageHistory
XML trim is not applicable. It is intentionally simple: tail-walk only,
no YaRN compression (that lives in WorkflowOrchestrator's
_compress_dropped_for_recovery for the reactive-trim path). The goal is
to keep validate_and_truncate from falling off the end when called
with non-XML messages.

Arguments:
- $messages:  ArrayRef of message hashes
- $effective_limit: Token budget for the resulting array
- $debug: 1 to emit debug logs

Returns: Trimmed ArrayRef

=cut

sub _role_based_tail_walk {
    my ($messages, $effective_limit, $debug) = @_;

    return $messages unless $messages && @$messages;

    # First, preserve the index of the first user message. We never
    # drop before this point - it carries the original task.
    my $first_user_idx;
    for my $i (0 .. $#$messages) {
        if (ref($messages->[$i]) eq 'HASH' && ($messages->[$i]{role} // '') eq 'user') {
            $first_user_idx = $i;
            last;
        }
    }
    return $messages unless defined $first_user_idx;

    # Identify "pinned" indices - messages that must survive trimming
    # regardless of budget pressure:
    #  - system_prompt at index 0 (cache-stable prefix anchor)
    #  - the LAST system message that follows a user message
    #    (dynamic userContext - carries active task, todos, memory)
    #  - the LAST user message (current turn's user_input)
    #
    # Without this guard, the proactive trim drops the dynamic
    # userContext and the current user_input under budget pressure,
    # and the model loses its task/todos/relevant memory and the
    # actual question it was asked. Long-session context-loss bug B1.
    my @pinned = ($first_user_idx);
    if ($messages->[0]
        && ($messages->[0]{role} // '') eq 'system'
        && 0 != $first_user_idx) {
        unshift @pinned, 0;
    }
    my $last_system_after_user;
    my $last_user_idx;
    for my $i ($first_user_idx .. $#$messages) {
        my $r = $messages->[$i]{role} // '';
        $last_user_idx = $i if $r eq 'user';
        $last_system_after_user = $i if $r eq 'system';
    }
    push @pinned, $last_system_after_user if defined $last_system_after_user;
    push @pinned, $last_user_idx if defined $last_user_idx && $last_user_idx != $first_user_idx;
    my %pinned_idx = map { $_ => 1 } @pinned;

    # Reserve walk budget for pinned up front. Without this, the walk
    # accumulates non-pinned content close to (or past) effective_limit,
    # and the pinned inclusion loop has to evict - which has to drop
    # pinned messages, defeating the pin. By reserving pinned tokens
    # from the walk budget, the walk stays within (effective_limit -
    # pinned_total) and the pinned loop fits without eviction in
    # typical cases. Fall back to a 0 floor if pinned alone exceeds
    # budget (the bail-out at the end of the function handles that).
    my $pinned_total = 0;
    for my $idx (@pinned) {
        $pinned_total += _estimate_tokens([$messages->[$idx]]);
    }
    my $walk_limit = $effective_limit - $pinned_total;
    $walk_limit = 0 if $walk_limit < 0;

    # Walk backwards from newest to oldest, accumulating until budget
    # exhausted. Pair tool_result with its assistant tool_call so we
    # never strand either.
    #
    # @kept_indices stays in ASCENDING order throughout the walk.
    # Each iteration either splices (for tool_pair call_idx, which is
    # older than the current index) or unshifts (for the current
    # index, which is older than everything already in @kept). Both
    # operations preserve ascending order. Without this discipline,
    # duplicates would appear (old code pushed call_idx to the end
    # then unshifted the tool result to the front, scattering the
    # pair out of conversation order).
    my @kept_indices;
    my $kept_tokens = 0;
    for my $i (reverse 0 .. $#$messages) {
        my $msg = $messages->[$i];
        next unless ref($msg) eq 'HASH';
        # Pinned indices are force-included below; skip the walk for
        # them so the budget is reserved for the dynamic context.
        next if $pinned_idx{$i};
        my $msg_tokens = _estimate_tokens([$msg]);

        # If this is a tool_result, locate its assistant tool_call
        # index and ensure it would also be kept. If the call would be
        # skipped, include it inline (tool pairing invariant).
        if (($msg->{role} // '') eq 'tool' && $msg->{tool_call_id}) {
            my $call_idx = _find_assistant_for_tool_call($messages, $msg->{tool_call_id}, $i);
            if (defined $call_idx && $call_idx >= $first_user_idx
                && !(grep { $_ == $call_idx } @kept_indices)) {
                my $call_msg = $messages->[$call_idx];
                my $call_tokens = _estimate_tokens([$call_msg]);
                if ($kept_tokens + $msg_tokens + $call_tokens <= $walk_limit) {
                    # Splice call_idx into @kept_indices at its
                    # ascending position (call_idx is older than $i
                    # and older than any entry already in @kept).
                    splice(@kept_indices,
                        (scalar grep { $_ < $call_idx } @kept_indices),
                        0,
                        $call_idx);
                    $kept_tokens += $call_tokens;
                } else {
                    last;
                }
            }
        }

        # Skip if already in @kept_indices - the assistant tool_call
        # might have been spliced in for a later tool_result, and we
        # would otherwise add it twice. Without this check the same
        # assistant message appears twice in the trimmed output -
        # the model sees identical tool_call arrays.
        next if grep { $_ == $i } @kept_indices;

        if ($kept_tokens + $msg_tokens <= $walk_limit) {
            # Splice $i into @kept_indices at its ascending position.
            # Since we walk in descending order, every entry already
            # in @kept has value <= $i - 1; but call_idx splices from
            # the tool_pair branch may have placed entries at value
            # less than $i (older assistant). unshift would put $i at
            # position 0 above those older entries, breaking ascending
            # order and scattering tool_call/tool_result pairs.
            splice(@kept_indices,
                (scalar grep { $_ < $i } @kept_indices),
                0,
                $i);
            $kept_tokens += $msg_tokens;
        } else {
            last;
        }
    }

    # Force-include the pinned indices (system_prompt, dynamic
    # userContext, current user_input). If their tokens push us over
    # budget, evict the oldest non-pinned kept messages until we fit.
    # Critical for long sessions: the model needs the dynamic
    # userContext (active task, todos, relevant memory) and the
    # current user_input even when budget is exhausted.
    #
    # BUGFIX (long-session context-loss): the previous eviction loop
    # did `shift @kept_indices; next;` when the front was pinned -
    # which silently dropped the pinned index from the kept set,
    # defeating the pin. The fix is to break out instead: pinned
    # indices are force-included, so evicting them is always wrong.
    # If we can't fit pinned without evicting them, bail to
    # return-as-is (validate_tool_message_pairs still cleans orphans).
    my %kept_set = map { $_ => 1 } @kept_indices;
    for my $idx (sort { $a <=> $b } @pinned) {
        next if $kept_set{$idx};
        my $msg = $messages->[$idx];
        my $msg_tokens = _estimate_tokens([$msg]);
        # Evict from the front (oldest non-pinned) until pinned fits.
        while ($kept_tokens + $msg_tokens > $effective_limit && @kept_indices) {
            my $front = $kept_indices[0];
            # Pinned indices are force-included; evicting them would
            # defeat the pin. Stop evicting instead - the bail-out
            # below handles the over-budget case.
            last if $pinned_idx{$front};
            $kept_tokens -= _estimate_tokens([$messages->[$front]]);
            shift @kept_indices;
            delete $kept_set{$front};
        }
        # If we broke out of the eviction loop with over-budget, the
        # pinned message can't fit alongside any kept content. Bail to
        # return-as-is rather than silently dropping the pin.
        if ($kept_tokens + $msg_tokens > $effective_limit) {
            log_debug('MessageValidator',
                "role-based tail walk: pinned message at index $idx cannot fit (have $kept_tokens, need +$msg_tokens of $effective_limit); returning as-is");
            return validate_tool_message_pairs($messages);
        }
        splice(@kept_indices,
            (scalar grep { $_ < $idx } @kept_indices),
            0,
            $idx);
        $kept_set{$idx} = 1;
        $kept_tokens += $msg_tokens;
    }

    # If we ended up dropping the first user message, drop everything
    # before it and re-emit. This guarantees the original task anchor
    # survives regardless of where the budget cuts off.
    if (@kept_indices && $kept_indices[0] > $first_user_idx) {
        @kept_indices = ($first_user_idx, @kept_indices);
    }

    # If still over budget with only the first user message kept,
    # give up and return as-is (validate_tool_message_pairs will
    # still clean orphans).
    if ($kept_tokens > $effective_limit) {
        log_debug('MessageValidator',
            "role-based tail walk: even first user message exceeds budget ($kept_tokens > $effective_limit); returning as-is");
        return validate_tool_message_pairs($messages);
    }

    my @trimmed = @{$messages}[@kept_indices];

    # Filter continuation-only user prompts that survived trim.
    # Without this, sequences like:
    #   user: continue
    #   assistant: ...
    #   user: continue
    #   ...
    # become via alternation:
    #   user: continue\n\ncontinue\n\n...<actual user input>
    # which is confusing to the model. The actual current user
    # input is preserved (filter skips the LAST user message).
    require CLIO::Core::ConversationManager;
    @trimmed = @{ CLIO::Core::ConversationManager::filter_continuation_prompts(\@trimmed) };

    log_debug('MessageValidator',
        "role-based tail walk: " . scalar(@$messages) . " -> " . scalar(@trimmed) . " messages, $kept_tokens tokens") if $debug;
    return validate_tool_message_pairs(\@trimmed);
}

=head2 _find_assistant_for_tool_call

Locate the index of the assistant message whose tool_calls include the
given tool_call_id, scanning earlier in the array. Returns undef if not
found.

=cut

sub _find_assistant_for_tool_call {
    my ($messages, $tool_call_id, $before_idx) = @_;
    for my $j (reverse 0 .. ($before_idx - 1)) {
        my $prev = $messages->[$j];
        next unless ref($prev) eq 'HASH';
        next unless ($prev->{role} // '') eq 'assistant';
        next unless ref($prev->{tool_calls}) eq 'ARRAY';
        for my $tc (@{$prev->{tool_calls}}) {
            return $j if ($tc->{id} // '') eq $tool_call_id;
        }
    }
    return undef;
}

=head2 validate_tool_message_pairs

Bidirectional validation of tool_calls and tool_results.
Removes orphaned tool_calls (strips from assistant messages) and
orphaned tool_results (removes entirely).

Also de-duplicates tool_call_ids within the same message (and
across messages) so the OpenAI/Anthropic API doesn't reject the
payload with "Duplicate tool_call_id found". The first occurrence
of each id wins; subsequent ones are dropped. This handles a
recurring failure mode where a long session accumulates the same
tool_call_ids in two adjacent turns (e.g. a duplicate trim /
rebuild cycle or a tool re-invocation on retry).

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

    # Identify duplicate tool_call_ids (any id that appears more than
    # once across all tool_calls). OpenAI/Anthropic reject these.
    # We track which ids have been seen so the rebuild pass can
    # keep only the first occurrence and drop the rest.
    my %seen_tc_ids;
    my %duplicate_tc_ids;
    for my $i (0 .. $#$messages) {
        my $msg = $messages->[$i];
        next unless $msg->{role} && $msg->{role} eq 'assistant' &&
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY';
        for my $tc (@{$msg->{tool_calls}}) {
            my $id = $tc->{id} // '';
            next unless length $id;
            if ($seen_tc_ids{$id}++) {
                $duplicate_tc_ids{$id} = 1;
            }
        }
    }

    if (%duplicate_tc_ids) {
        my $dup_count = scalar keys %duplicate_tc_ids;
        log_debug('MessageValidator', "Found $dup_count duplicate tool_call_id(s) - will dedupe");
    }

    # If no orphans and no duplicates, return original. We don't
    # special-case "duplicates only" because the per-message loop
    # below handles dedup as it walks (the %seen_in_output hash
    # tracks ids already added to the rebuilt message stream, and
    # duplicates are dropped on the fly without re-walking the
    # input). So we always take the rebuild path when duplicates
    # exist, which is fine for performance (messages are bounded
    # by the post-trim count, usually <1000).
    if (!keys %orphaned_tc_ids && !keys %orphaned_result_indices && !%duplicate_tc_ids) {
        log_debug('MessageValidator', "Tool message validation: all pairs valid");
        return $messages;
    }

    # Rebuild: remove orphaned results entirely, strip orphaned OR
    # duplicate tool_calls (keeping the first occurrence only).
    # ALWAYS rebuild (don't short-circuit on "no fixes needed") so
    # that the dedup pass is the single source of truth for tool_call
    # id uniqueness - any path that produces duplicate ids lands here
    # and gets cleaned up.
    my @validated;
    my $fixes = 0;
    # We track which ids have been kept in the OUTPUT so far. A
    # tool_call in the input is dropped if its id is already in
    # this set (cross-message duplicate) OR if it's a known
    # duplicate by the %duplicate_tc_ids pre-scan.
    my %kept_ids;
    for (my $i = 0; $i < @$messages; $i++) {
        my $msg = $messages->[$i];

        # Drop orphaned tool results
        if ($orphaned_result_indices{$i}) {
            log_debug('MessageValidator', "Removing orphaned tool_result at index $i");
            $fixes++;
            next;
        }

        # For assistant messages with tool_calls, strip orphaned AND
        # duplicate ones (first occurrence wins).
        if ($msg->{role} && $msg->{role} eq 'assistant' &&
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {

            my @kept_calls;
            my @dropped_calls;
            for my $tc (@{$msg->{tool_calls}}) {
                my $id = $tc->{id};
                my $already_kept = defined $id && exists $kept_ids{$id};
                my $is_dup = $already_kept
                    || (defined $id && $duplicate_tc_ids{$id});
                my $is_orphan = defined $id && $orphaned_tc_ids{$id};
                # A tool_call is dropped if:
                # 1. It's a cross-message duplicate (id already in
                #    %kept_ids) - second/third/... occurrences.
                # 2. It's a duplicate AND an orphan - in this case
                #    prefer to drop the duplicate occurrence rather
                #    than the orphan, so the first occurrence survives
                #    even if its result was lost. This handles the
                #    common case where the same tool_call_id appears
                #    in a rebuilt history that lost a tool_result.
                # 3. It's an orphan with no prior duplicate - the
                #    result was lost and we have no way to recover.
                if ($is_dup && !$already_kept) {
                    # This is a known-duplicate id but we haven't seen
                    # it before in the output. The first occurrence
                    # is the canonical one - we keep this regardless
                    # of orphan status. (Don't drop the first on
                    # orphan grounds; if the first id is orphaned,
                    # the duplicate handler will keep this and the
                    # orphan check can do nothing for it.)
                    push @kept_calls, $tc;
                    $kept_ids{$id} = 1 if defined $id;
                } elsif ($already_kept) {
                    # Second/third occurrence of an id we've already
                    # kept. Always drop.
                    push @dropped_calls, $id;
                } elsif ($is_orphan) {
                    push @dropped_calls, $id;
                } else {
                    push @kept_calls, $tc;
                    $kept_ids{$id} = 1 if defined $id;
                }
            }

            if (@kept_calls || @dropped_calls) {
                # We need to emit the message. If it had any kept calls,
                # include them. If all were dropped (orphan or dup),
                # emit a plain assistant with the original content.
                $fixes += scalar(@dropped_calls);
                if (@dropped_calls) {
                    log_debug('MessageValidator', "Stripped " . scalar(@dropped_calls) .
                        " tool_calls from assistant at index $i" .
                        " (kept " . scalar(@kept_calls) . ")");
                }
                if (@kept_calls) {
                    push @validated, {
                        %$msg,
                        tool_calls => \@kept_calls,
                    };
                } else {
                    push @validated, { role => $msg->{role}, content => $msg->{content} || '' };
                }
                next;
            } else {
                # No orphans and no dups within this message. Emit
                # the assistant unchanged so callers don't lose
                # tool_calls metadata. The ids were already added
                # to %kept_ids by the kept_calls branch above.
                push @validated, $msg;
                next;
            }
        }

        push @validated, $msg;
    }

    log_debug('MessageValidator', "Fixed $fixes orphaned tool messages") if $fixes > 0;

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




1;

__END__

=head1 AUTHOR

CLIO Project - Extracted from APIManager.pm

=cut
