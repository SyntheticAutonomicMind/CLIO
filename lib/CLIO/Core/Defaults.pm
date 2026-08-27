# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::Defaults;

use strict;
use warnings;
use utf8;
use Exporter 'import';

=head1 NAME

CLIO::Core::Defaults - Centralized default values and fallback constants

=head1 DESCRIPTION

Single source of truth for all fallback/default values used across CLIO.
Eliminates scattered magic numbers and makes tuning straightforward.

All values here are last-resort fallbacks - actual values should come from
model capabilities reported by the API whenever possible.

=head1 SYNOPSIS

    use CLIO::Core::Defaults qw(
        DEFAULT_CONTEXT_WINDOW
        DEFAULT_LOCAL_CONTEXT_WINDOW
        DEFAULT_MAX_OUTPUT_TOKENS
        default_chunk_size
    );

=cut

our @EXPORT_OK = qw(
    DEFAULT_CONTEXT_WINDOW
    DEFAULT_LOCAL_CONTEXT_WINDOW
    DEFAULT_MAX_OUTPUT_TOKENS
    DEFAULT_MAX_RESPONSE_TOKENS
    DEFAULT_TOOL_OUTPUT_RESERVE
    DEFAULT_BINARY_SAMPLE_SIZE
    DEFAULT_POST_TRIM_FLOOR
    MIN_CSSS_SLOT_TOKENS
    MAX_CSSS_SLOT_TOKENS
    MAX_PRESERVED_HIGH_VALUE
    ACK_THRESHOLD_CHARS
    TOOL_RESULT_MAX_CHUNK
    OUTPUT_ESTIMATION_BUFFER
    OUTPUT_ESTIMATION_BUFFER_PCT
    OUTPUT_ESTIMATION_BUFFER_MAX
    default_chunk_size
);

our %EXPORT_TAGS = (all => \@EXPORT_OK);

# Context window fallbacks (tokens)
# Used when model capabilities are unavailable from the API
use constant DEFAULT_CONTEXT_WINDOW       => 128000;  # Cloud models
use constant DEFAULT_LOCAL_CONTEXT_WINDOW => 65536;   # Local models (SAM, llama.cpp, LM Studio)

# Output token fallbacks
use constant DEFAULT_MAX_OUTPUT_TOKENS    => 16384;   # When no output limit is known
use constant DEFAULT_MAX_RESPONSE_TOKENS  => 16000;   # Response budget for conversation management
use constant DEFAULT_TOOL_OUTPUT_RESERVE  => 8192;    # Output reserve when tools are active.
                                                     # Tool-calling agents produce short responses
                                                     # (tool_call JSON + brief text, well under 8K).
                                                     # Using model's full max_output_tokens (often
                                                     # 32K+) wastes prompt budget; capping here
                                                     # reclaims ~24K of prompt room for long-running
                                                     # tool-calling sessions and dramatically reduces
                                                     # trim frequency.

# Output reservation buffer for context budgeting.
# Trim paths reserve actual max_output_tokens (from model caps) plus this
# buffer to cover estimation error. NO hard cap on output reserve - use
# whatever the model actually supports. Clinically: with 128K-output
# models (MiniMax-M3, Z.AI GLM-5) and a 1M context window, we'd
# previously reserve 500K (50%) for output; with actual reserves we keep
# 822K for prompt (172K more usable context).
use constant OUTPUT_ESTIMATION_BUFFER     => 8192;    # Constant part of reserve
use constant OUTPUT_ESTIMATION_BUFFER_PCT => 0.05;    # Proportional part (5% of context)
use constant OUTPUT_ESTIMATION_BUFFER_MAX => 51200;   # Cap proportional buffer at 50K

# Tool result chunking
use constant TOOL_RESULT_MAX_CHUNK        => 32768;   # Hard ceiling per chunk (bytes)

# File operations
use constant DEFAULT_BINARY_SAMPLE_SIZE   => 8192;    # Bytes to sample for binary detection

# Conversation management
use constant DEFAULT_POST_TRIM_FLOOR      => 24000;   # Minimum tokens to keep after trimming
                                                    # Balanced: earlier than 32K (less frequent trims)
                                                    # but later than 12K (allows aggressive trim benefits).
                                                    # With 131K local model: prompt budget ~108K,
                                                    # trim at 24K leaves ~84K headroom per cycle.

# Cache-Stable Summary Slot (CSSS) bounds.
# MIN_CSSS_SLOT_TOKENS: Minimum slot size to ensure "Current task" + essential
# context fits even after aggressive trim. The first trim creates a naturally
# small summary (no CSSS constraint); without a floor, CSSS locks to that small
# size and starves subsequent summaries. 8K preserves ~2K for Current task +
# ~6K for recent decisions/files/commits.
# MAX_CSSS_SLOT_TOKENS: Hard ceiling on slot growth. Prevents unbounded growth
# when aggressive trim drives more content into the summary than can fit.
use constant MIN_CSSS_SLOT_TOKENS         => 8000;    # Minimum CSSS slot size (tokens)
use constant MAX_CSSS_SLOT_TOKENS         => 12000;   # Maximum CSSS slot size (tokens)

# Trim priority tier constants (see docs/SPECS/TRIM_PRIORITY.md).
# MAX_PRESERVED_HIGH_VALUE: the most recent N dialog units (Tier 2) are
# always preserved during a budget walk, regardless of how tight the
# budget is. These units represent the model's current task context;
# dropping them forces the model to hallucinate task boundaries.
# 5 units covers a typical "task + 2-3 tool rounds + 1 acknowledgement"
# sub-conversation.
use constant MAX_PRESERVED_HIGH_VALUE    => 5;

# ACK_THRESHOLD_CHARS: assistant messages shorter than this with no
# tool_calls and no reasoning_content are flagged as Tier 4
# "acknowledgements" and dropped first during budget walks. Common
# examples: "OK" (2), "Got it" (6), "Let me try" (11), "Yes, doing that
# now." (20). Below the threshold: pure acknowledgement. Above: real
# reasoning (even if short) worth preserving.
use constant ACK_THRESHOLD_CHARS         => 50;

=head2 default_chunk_size($context_window)

Calculate the default chunk size for read_tool_result based on the model's
context window. Larger context models can handle bigger chunks, reducing
round-trips.

Arguments:
    $context_window - Model's context window in tokens (optional, defaults to DEFAULT_CONTEXT_WINDOW)

Returns:
    Chunk size in bytes (between 8192 and TOOL_RESULT_MAX_CHUNK)

=cut

sub default_chunk_size {
    my ($context_window) = @_;
    $context_window //= DEFAULT_CONTEXT_WINDOW;

    # Heuristic: ~4 chars per token, use ~2% of context for a single chunk
    # This keeps chunks well within budget while scaling with capability
    #   32k ctx  -> ~2500 tokens -> ~10k bytes -> clamp to 16384
    #   128k ctx -> ~10k tokens  -> ~40k bytes -> clamp to 32768
    #   200k ctx -> ~16k tokens  -> ~64k bytes -> clamp to 32768
    my $size = int($context_window * 4 * 0.02);

    # Floor at 16384, ceiling at TOOL_RESULT_MAX_CHUNK
    $size = 16384 if $size < 16384;
    $size = TOOL_RESULT_MAX_CHUNK if $size > TOOL_RESULT_MAX_CHUNK;

    return $size;
}

1;
