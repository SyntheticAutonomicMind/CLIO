package CLIO::Memory::TokenEstimator;

use strict;
use warnings;
use utf8;
use POSIX qw(ceil);

=head1 NAME

CLIO::Memory::TokenEstimator - Utility for estimating token counts in text

=head1 DESCRIPTION

Provides token estimation for context management.
Uses a simple heuristic: 1 token ≈ 4 characters (conservative estimate for English text).
This is faster than actual tokenization and sufficient for preventing context window overflows.

Based on SAM's TokenEstimator.swift implementation.

=head1 SYNOPSIS

    use CLIO::Memory::TokenEstimator;
    
    my $tokens = CLIO::Memory::TokenEstimator::estimate_tokens($text);
    
    if (CLIO::Memory::TokenEstimator::exceeds_limit($text, 128000)) {
        my $truncated = CLIO::Memory::TokenEstimator::truncate($text, 128000);
    }
    
    my @chunks = CLIO::Memory::TokenEstimator::split_into_chunks($text, 4096);

=cut

# Characters per token (conservative estimate)
use constant CHARS_PER_TOKEN => 4.0;

=head2 estimate_tokens

Estimate token count for a string.

Arguments:
- $text: The text to estimate tokens for

Returns: Estimated number of tokens

=cut

sub estimate_tokens {
    my ($text) = @_;
    return 0 unless defined $text && length($text) > 0;
    
    my $char_count = length($text);
    return int(ceil($char_count / CHARS_PER_TOKEN));
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
    
    # Calculate character limit (with some buffer)
    my $max_chars = int($limit * CHARS_PER_TOKEN * 0.95);
    
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

Arguments:
- $messages: Array reference of message hashes with 'role' and 'content'

Returns: Estimated total tokens including message overhead

=cut

sub estimate_messages_tokens {
    my ($messages) = @_;
    return 0 unless ref $messages eq 'ARRAY';
    
    my $total = 0;
    
    for my $msg (@$messages) {
        next unless ref $msg eq 'HASH';
        
        # Role overhead (typically 1-2 tokens per message)
        $total += 3;
        
        # Content tokens
        if (defined $msg->{content}) {
            $total += estimate_tokens($msg->{content});
        }
        
        # Tool call tokens (if present)
        if ($msg->{tool_calls} && ref $msg->{tool_calls} eq 'ARRAY') {
            for my $tool_call (@{$msg->{tool_calls}}) {
                my $tool_text = ($tool_call->{function}->{name} // '') . 
                               ($tool_call->{function}->{arguments} // '');
                $total += estimate_tokens($tool_text);
                $total += 10;  # Tool call structure overhead
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

1;
