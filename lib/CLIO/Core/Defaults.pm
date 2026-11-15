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
    DEFAULT_BINARY_SAMPLE_SIZE
    COPILOT_EDITOR_VERSION
    COPILOT_PLUGIN_VERSION
    COPILOT_LS_VERSION
    COPILOT_API_VERSION
    COPILOT_USER_API_VERSION
    TOOL_RESULT_MAX_CHUNK
    CONTEXT_TRIM_TARGET
    TOKEN_RATIO_MIN
    TOKEN_RATIO_MAX
    TOKEN_RATIO_PRIOR_SAMPLE
    OUTPUT_ESTIMATION_BUFFER
    OUTPUT_ESTIMATION_BUFFER_PCT
    OUTPUT_ESTIMATION_BUFFER_MAX
    default_chunk_size
);

our %EXPORT_TAGS = (all => \@EXPORT_OK);

# Context window fallbacks (tokens)
# Used when model capabilities are unavailable from the API
use constant DEFAULT_CONTEXT_WINDOW       => 128000;  # Cloud models
use constant DEFAULT_LOCAL_CONTEXT_WINDOW => 65536;   # Local models (llama.cpp, LM Studio)

# Output token fallbacks
use constant DEFAULT_MAX_OUTPUT_TOKENS    => 16384;   # When no output limit is known
use constant MAX_MODEL_OUTPUT_TOKENS      => 131072;  # Hard ceiling on output reserve
use constant DEFAULT_MAX_RESPONSE_TOKENS  => 16000;   # Response budget for conversation management

# Output reservation buffer for context budgeting.
# Trim paths reserve actual max_output_tokens (from model caps) plus this
# buffer to cover estimation error. No hard cap on output reserve - use
# whatever the model actually supports.
use constant OUTPUT_ESTIMATION_BUFFER     => 8192;    # Constant part of reserve
use constant OUTPUT_ESTIMATION_BUFFER_PCT => 0.05;    # Proportional part (5% of context)
use constant OUTPUT_ESTIMATION_BUFFER_MAX => 51200;   # Cap proportional buffer at 50K

# Context trim target. The proactive trim drops whole messages from the
# oldest end, so the provider's cached prefix ends at the first dropped
# message: the next request re-prefills everything that survived. Trimming
# only until the array fits pays a full re-prefill every few turns.
# Trimming down to this fraction of the prompt budget instead buys headroom,
# so the conversation grows for many turns before the next trim.
#   0.75 of a 224K budget -> ~56K tokens of headroom, ~150 turns at the
#   measured 370 tokens of growth per turn.
use constant CONTEXT_TRIM_TARGET          => 0.75;

# Bounds for the learned characters-per-token ratio. The ratio is measured,
# not guessed: too narrow a ceiling forces every estimate to be inflated,
# which trims early and often. The floor catches a corrupted measurement.
use constant TOKEN_RATIO_MIN              => 1.0;
use constant TOKEN_RATIO_MAX              => 10.0;

# Weight of a ratio observation is tokens/(tokens + prior). The prior is the
# prompt size that moves the learned ratio by roughly a third: small replies
# barely nudge it, a full prompt sets it.
use constant TOKEN_RATIO_PRIOR_SAMPLE     => 2000;

# Tool result chunking
use constant TOOL_RESULT_MAX_CHUNK        => 32768;   # Hard ceiling per chunk (bytes)

# File operations
use constant DEFAULT_BINARY_SAMPLE_SIZE   => 8192;    # Bytes to sample for binary detection

# GitHub Copilot editor identification constants.
# These match the vscode-copilot-chat reference implementation headers.
use constant COPILOT_EDITOR_VERSION       => 'vscode/2.0.0';
use constant COPILOT_PLUGIN_VERSION       => 'GitHubCopilotChat/0.38.0';
use constant COPILOT_LS_VERSION           => '1.378.1799';
use constant COPILOT_API_VERSION          => '2026-01-09';
use constant COPILOT_USER_API_VERSION     => '2025-04-01';

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
