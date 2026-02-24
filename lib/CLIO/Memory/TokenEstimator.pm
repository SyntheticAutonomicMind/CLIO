package CLIO::Memory::TokenEstimator;

use strict;
use warnings;
use utf8;
use POSIX qw(ceil);

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

# Per-message overhead constants (from OpenAI/Anthropic tokenizer analysis)
# Every message costs additional tokens for role framing
use constant TOKENS_PER_MESSAGE    => 3;   # role + delimiters
use constant TOKENS_PER_NAME       => 1;   # tool_call_id or name field
use constant TOKENS_PER_COMPLETION => 3;   # response priming overhead
use constant TOOL_CALL_OVERHEAD    => 10;  # JSON structure of a tool_call

# Context management threshold: trim at this percentage of max context
# Leaves (1 - SAFE_CONTEXT_PERCENT) as safety margin for response + estimation error
use constant SAFE_CONTEXT_PERCENT  => 0.58;

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

Returns: Estimated number of tokens

=cut

sub estimate_tokens {
    my ($text) = @_;
    return 0 unless defined $text && length($text) > 0;
    
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

1;

=head1 AUTHOR

CLIO Project

=head1 LICENSE

GPL-3.0

=cut
