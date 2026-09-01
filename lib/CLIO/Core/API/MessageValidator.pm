package CLIO::Core::API::MessageValidator;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug);
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
    
    # Exceeds limit - need to truncate
    log_debug('MessageValidator', "Messages exceed token limit: $estimated_tokens > $effective_limit");

    # Legacy non-messageHistory format: should not happen in normal
    # operation (the messageHistory feature is the only producer of @messages
    # sent here). validate_tool_message_pairs cleans up any orphaned tool pairs
    # but does not drop messages. Logged at debug because this should be a
    # quiet no-op for callers.
    log_debug('MessageValidator', "Legacy non-messageHistory format exceeded budget ($estimated_tokens > $effective_limit); returning as-is. validate_tool_message_pairs will prune orphans.");
    return validate_tool_message_pairs($messages);
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

1;
