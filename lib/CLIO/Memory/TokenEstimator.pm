# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Memory::TokenEstimator;

use strict;
use warnings;
use utf8;
use POSIX qw(ceil);
use Exporter 'import';

our @EXPORT_OK = qw(estimate_tokens get_effective_ratio compute_prompt_budget);

=head1 NAME

CLIO::Memory::TokenEstimator - Utility for estimating token counts in text

=head1 DESCRIPTION

Provides token estimation for context management.
Uses a heuristic based on characters-per-token ratio. The default ratio is 4.0
(conservative estimate for English text), but this can be improved at runtime
by feeding back actual token counts from API responses via set_learned_ratio().

When a learned ratio is available, all estimation functions automatically use it
for more accurate token counting. This affects trim decisions in both
ConversationManager and Session::State.

=head1 SYNOPSIS

    use CLIO::Memory::TokenEstimator;
    
    my $tokens = CLIO::Memory::TokenEstimator::estimate_tokens($text);
    
    # After receiving API response with actual token counts:
    CLIO::Memory::TokenEstimator::set_learned_ratio(3.2);
    
    # Subsequent estimates use the learned ratio
    my $better_estimate = CLIO::Memory::TokenEstimator::estimate_tokens($text);

=cut

# Default characters per token (conservative estimate)
use constant DEFAULT_CHARS_PER_TOKEN => 4.0;

# Per-message overhead constants (from OpenAI tokenizer analysis)
# Every message costs additional tokens for role framing
use constant TOKENS_PER_MESSAGE    => 3;   # role + delimiters
use constant TOKENS_PER_NAME       => 1;   # tool_call_id or name field
use constant TOKENS_PER_COMPLETION => 3;   # response priming overhead
use constant TOOL_CALL_OVERHEAD    => 10;  # JSON structure of a tool_call

# Context management threshold: trim at this percentage of max context
# Used as a fallback when model max_output_tokens is unknown. Real trim
# paths (MessageValidator, ConversationManager, Session::State,
# ErrorHandler) prefer compute_prompt_budget() which uses the actual
# model output cap rather than this percentage.
use constant SAFE_CONTEXT_PERCENT  => 0.75;

# Package-level learned ratio - updated from API response feedback
# When undef, falls back to DEFAULT_CHARS_PER_TOKEN
my $learned_ratio;

=head2 set_learned_ratio

Set the learned characters-per-token ratio from API response feedback.
Called by APIManager after observing actual prompt_tokens from API responses.
Propagates to ALL subsequent estimate_tokens calls across the codebase.

Arguments:
- $ratio: Characters per token (typically 2.0-4.0, clamped to [1.5, 5.0])

=cut

sub set_learned_ratio {
    my ($ratio) = @_;
    return unless defined $ratio && $ratio > 0;
    
    # Clamp to reasonable bounds
    $ratio = 1.5 if $ratio < 1.5;
    $ratio = 5.0 if $ratio > 5.0;
    
    $learned_ratio = $ratio;
}

=head2 get_effective_ratio

Returns the currently active characters-per-token ratio.
Uses learned ratio if available, otherwise the default.

Returns: Current ratio (float)

=cut

sub get_effective_ratio {
    return $learned_ratio // DEFAULT_CHARS_PER_TOKEN;
}

=head2 has_learned_ratio

Returns true if a learned ratio has been set from API feedback.

=cut

sub has_learned_ratio {
    return defined $learned_ratio;
}

=head2 estimate_tokens

Estimate token count for a string.
Uses learned ratio from API feedback when available, otherwise DEFAULT_CHARS_PER_TOKEN.

Arguments:
- $text: The text to estimate tokens for

 Also accepts arrayref content (multimodal messages): sums text parts and
 adds image token estimates (85 tokens per image for low-res, scaled for
 high-res based on dimensions).

Returns: Estimated number of tokens

=cut

sub estimate_tokens {
    my ($text) = @_;
    return 0 unless defined $text;
    
    # Handle arrayref content (multimodal messages)
    if (ref($text) eq 'ARRAY') {
        my $total = 0;
        for my $part (@$text) {
            next unless ref($part) eq 'HASH';
            if ((($part->{type} // '') eq 'text') && defined $part->{text}) {
                $total += estimate_tokens($part->{text});
            }
            elsif (($part->{type} // '') eq 'image_url') {
                # OpenAI image token estimate: low-res = 85 tokens
                # For data URLs we can't easily get dimensions, so use conservative estimate
                $total += 85;
            }
        }
        return $total;
    }
    
    return 0 unless length($text) > 0;
    
    my $ratio = get_effective_ratio();
    my $char_count = length($text);
    return int(ceil($char_count / $ratio));
}

=head2 exceeds_limit

Check if text would exceed a token limit.

Arguments:
- $text: The text to check
- $limit: Maximum token count allowed

Returns: True if text exceeds limit

=cut

sub exceeds_limit {
    my ($text, $limit) = @_;
    return estimate_tokens($text) > $limit;
}

=head2 truncate

Truncate text to fit within a token limit.

Arguments:
- $text: The text to truncate
- $limit: Maximum token count allowed

Returns: Truncated text that fits within limit

=cut

sub truncate {
    my ($text, $limit) = @_;
    
    my $estimated_tokens = estimate_tokens($text);
    
    return $text unless $estimated_tokens > $limit;
    
    # Calculate character limit using current ratio (with some buffer)
    my $ratio = get_effective_ratio();
    my $max_chars = int($limit * $ratio * 0.95);
    
    return $text unless length($text) > $max_chars;
    
    # Truncate to character limit
    my $truncated = substr($text, 0, $max_chars);
    return $truncated . "\n\n[Content truncated to fit token limit. Original size: $estimated_tokens tokens, truncated to $limit tokens]";
}

=head2 split_into_chunks

Split text into chunks that fit within a token limit.

Arguments:
- $text: The text to split
- $chunk_limit: Maximum tokens per chunk

Returns: Array of text chunks, each within the token limit

=cut

sub split_into_chunks {
    my ($text, $chunk_limit) = @_;
    
    my $total_tokens = estimate_tokens($text);
    
    return ($text) unless $total_tokens > $chunk_limit;
    
    # Split by lines first
    my @lines = split /\n/, $text;
    my @chunks;
    my @current_chunk;
    my $current_tokens = 0;
    
    for my $line (@lines) {
        my $line_tokens = estimate_tokens($line);
        
        if ($current_tokens + $line_tokens > $chunk_limit && @current_chunk) {
            # Current chunk is full, start new one
            push @chunks, join("\n", @current_chunk);
            @current_chunk = ($line);
            $current_tokens = $line_tokens;
        } else {
            push @current_chunk, $line;
            $current_tokens += $line_tokens;
        }
    }
    
    # Add remaining chunk
    if (@current_chunk) {
        push @chunks, join("\n", @current_chunk);
    }
    
    return @chunks;
}

=head2 estimate_messages_tokens

Estimate total token count for an array of messages.
Includes per-message overhead constants and uses learned ratio when available.

Arguments:
- $messages: Array reference of message hashes with 'role' and 'content'

Returns: Estimated total tokens including message overhead

=cut

sub estimate_messages_tokens {
    my ($messages) = @_;
    return 0 unless ref $messages eq 'ARRAY';

    my $total = TOKENS_PER_COMPLETION;  # Response priming overhead

    for my $msg (@$messages) {
        next unless ref $msg eq 'HASH';

        # Per-message overhead (role + delimiters)
        $total += TOKENS_PER_MESSAGE;

        # Content tokens
        if (defined $msg->{content}) {
            $total += estimate_tokens($msg->{content});
        }
        elsif (defined $msg->{parts} && ref($msg->{parts}) eq 'ARRAY') {
            # Google Gemini format: parts array with text/inlineData
            for my $part (@{$msg->{parts}}) {
                if ($part->{text}) {
                    $total += estimate_tokens($part->{text});
                }
                elsif ($part->{inlineData}) {
                    $total += 85;  # Image token estimate
                }
            }
        }

        # Name/tool_call_id overhead
        $total += TOKENS_PER_NAME if $msg->{tool_call_id} || $msg->{name};

        # Tool call tokens (if present)
        if ($msg->{tool_calls} && ref $msg->{tool_calls} eq 'ARRAY') {
            for my $tool_call (@{$msg->{tool_calls}}) {
                my $tool_text = ($tool_call->{function}->{name} // '') .
                               ($tool_call->{function}->{arguments} // '');
                $total += estimate_tokens($tool_text);
                $total += TOOL_CALL_OVERHEAD;  # JSON structure overhead
            }
        }
    }

    return $total;
}

=head2 compute_prompt_budget($caps)

Compute the prompt budget for a model from its capabilities.

The prompt budget is the maximum number of tokens the conversation
(messages + tools + system prompt) may consume before trimming. It is
the model's context window minus the reserve for the model's actual
output, minus a small estimation buffer.

NO hard cap is applied to the output reserve - we use whatever the
model actually supports. This is a deliberate departure from the
previous SAFE_CONTEXT_PERCENT heuristic, which reserved a flat 25%
(or 50% post-trim) of context for output regardless of the model's
real output cap. For 1M-context models with 128K output (MiniMax-M3,
Z.AI GLM-5), the previous behavior reserved 500K for output (50%);
this function reserves 128K, leaving 822K for prompt (172K more
usable context).

For 1M-context models with 16K output (NVIDIA Nemotron 3 Ultra, Llama
4), the reserve is just 16K, leaving ~934K for prompt.

Arguments:
    $caps - Hashref from ModelCapabilitiesManager::get_capabilities or
            APIManager::get_model_capabilities. Recognized keys:
              - max_context_window_tokens (or context_window)
              - max_prompt_tokens          (used as context_window when set)
              - max_output_tokens

Returns:
    Integer prompt budget in tokens. Always >= 1000 to keep a usable
    floor for even tiny-context local models.

=cut

sub compute_prompt_budget {
    my ($caps) = @_;
    return 1000 unless ref $caps eq 'HASH';

    require CLIO::Core::Defaults;

    # Resolve context window. Prefer max_context_window_tokens (the
    # model's true context window), fall back to max_prompt_tokens
    # (which MCM populates from context_window for most paths anyway),
    # and ultimately to DEFAULT_CONTEXT_WINDOW.
    my $context_window = $caps->{max_context_window_tokens}
                      || $caps->{context_window}
                      || $caps->{max_prompt_tokens}
                      || CLIO::Core::Defaults::DEFAULT_CONTEXT_WINDOW();
    $context_window = CLIO::Core::Defaults::DEFAULT_CONTEXT_WINDOW() if $context_window <= 0;

    # Resolve output reserve. Use the model's actual max_output_tokens
    # directly - no hard cap (per design: each model knows its own
    # output limit, and reserving more wastes context). Fall back to
    # DEFAULT_MAX_OUTPUT_TOKENS only when the model has no reported
    # output cap (e.g. local models, unmapped providers).
    my $output_reserve = $caps->{max_output_tokens}
                      || CLIO::Core::Defaults::DEFAULT_MAX_OUTPUT_TOKENS();
    $output_reserve = CLIO::Core::Defaults::DEFAULT_MAX_OUTPUT_TOKENS() if $output_reserve <= 0;

    # Estimation buffer: constant + proportional, capped. Covers
    # token estimation error, per-message overhead not captured by the
    # character heuristic, and provider-specific formatting tokens.
    #   32k ctx  -> 8192 + 160 = 9792
    #   128k ctx -> 8192 + 640 = 14592
    #   200k ctx -> 8192 + 10000 = 18192
    #   1M ctx   -> 8192 + 50000 = 58192, capped at 51200
    my $est_buffer = CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER()
                   + int($context_window * CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER_PCT());
    my $buffer_cap = CLIO::Core::Defaults::OUTPUT_ESTIMATION_BUFFER_MAX();
    $est_buffer = $buffer_cap if $est_buffer > $buffer_cap;

    my $budget = $context_window - $output_reserve - $est_buffer;
    $budget = 1000 if $budget < 1000;

    return $budget;
}

1;

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0

=cut

1;
