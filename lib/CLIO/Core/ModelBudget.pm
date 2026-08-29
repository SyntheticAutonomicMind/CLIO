# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::ModelBudget;

=head1 NAME

CLIO::Core::ModelBudget - Context-window-class aware budget allocation

=head1 DESCRIPTION

Models with small context windows (32K-64K) cannot fit the full CLIO
system prompt + AGENTS.md + LTM + tools schema + dialog. Without
budget scaling, the first tool call exhausts context and the session
fails. Without budget scaling, mid-session trims happen constantly,
burning CPU and causing cache invalidation.

ModelBudget classifies a model's context window into a "class" (XS/S/M/L/XL)
and returns a budget allocation table that APIManager uses to scale
down the prompt components.

Class boundaries:

=over 4

=item XS: <= 32K (4K-8K quantized, very small local models)

=item S:  32K-64K (CachyLLama llama.cpp UD-Q5_K_XL, small local models)

=item M:  64K-128K (default for most cloud models with reported context)

=item L:  128K-256K (Claude Sonnet, GPT-4.1)

=item XL: > 256K (MiniMax M3 1M, Gemini 2.5, DeepSeek-V4)

=back

The default budget table is documented in docs/SPECS/MODEL_BUDGETS.md.

=cut

use strict;
use warnings;
use utf8;
use Exporter 'import';

# Logger imports are deferred to avoid a load-order dependency: ModelBudget
# is loaded by APIManager very early in initialization, and Logger may not
# be available yet. Use require + fully-qualified call inside subroutines.

our @EXPORT_OK = qw(
    model_class
    budget_for
    effective_budget
    apply_budget_to_payload
    known_classes
);

our %EXPORT_TAGS = (all => \@EXPORT_OK);

# Default budget table for each model class. See docs/SPECS/MODEL_BUDGETS.md.
# Each entry maps a prompt section to a token budget. -1 means "unlimited
# (use the actual size)" and 0 means "skip this section entirely". The
# AGENTS.md and tools schema sections use byte counts because they are
# file-based rather than tokenized at load time.

# csss_slot is a CEILING on the summary size, not a target. Earlier
# versions used it as a hard lock with padding to enforce byte-level
# stability for llama.cpp cache; that approach was abandoned because
# the padding was visible to the model as a massive artifact inside
# <thread_summary>. See YaRN.pm:_fit_summary_to_target.
my %DEFAULT_BUDGETS = (
    'XS' => {
        # <= 32K context. Aggressive scaling: drop everything that's not
        # required for behavior.
        system_prompt         => -1,    # REQUIRED for behavior
        context_files         => -1,    # user-curated
        instructions_md       => -1,    # REQUIRED for behavior
        agents_md             => 0,     # SKIP entirely
        ltm                   => 0,     # SKIP entirely
        session_goals         => 200,   # truncated to 200 tokens
        tools_schema          => 6000,  # tools filtered to essentials
        csss_slot             => 2000,  # summary ceiling (XS scale)
        dialog                => 8000,  # hard cap on dialog
        description           => 'XS (<=32K): aggressive scaling, drop AGENTS.md and LTM',
    },
    'S' => {
        # 32K-64K context. Moderate scaling.
        system_prompt         => -1,    # REQUIRED for behavior
        context_files         => -1,    # user-curated
        instructions_md       => -1,    # REQUIRED for behavior
        agents_md             => 5000,  # truncated to first 5K
        ltm                   => 2000,  # top 3 most-recent entries
        session_goals         => -1,    # full
        tools_schema          => 12000, # filter to essentials
        csss_slot             => 4000,  # summary ceiling (S scale)
        dialog                => 16000, # hard cap
        description           => 'S (32K-64K): moderate scaling',
    },
    'M' => {
        # 64K-128K context. Tighter than L but full everything fits.
        system_prompt         => -1,
        context_files         => -1,
        instructions_md       => -1,
        agents_md             => 15000, # full plus a buffer
        ltm                   => 6000,  # top 6-8 most-recent
        session_goals         => -1,
        tools_schema          => -1,    # all tools
        csss_slot             => 8000,  # summary ceiling (M default)
        dialog                => -1,    # no hard cap
        description           => 'M (64K-128K): full, comfortable',
    },
    'L' => {
        # 128K-256K context. Full everything.
        system_prompt         => -1,
        context_files         => -1,
        instructions_md       => -1,
        agents_md             => -1,
        ltm                   => 10000,
        session_goals         => -1,
        tools_schema          => -1,
        csss_slot             => 8000,  # summary ceiling (L)
        dialog                => -1,
        description           => 'L (128K-256K): full everything, comfortable',
    },
    'XL' => {
        # > 256K context. Full everything with headroom.
        system_prompt         => -1,
        context_files         => -1,
        instructions_md       => -1,
        agents_md             => -1,
        ltm                   => -1,    # full LTM
        session_goals         => -1,
        tools_schema          => -1,
        csss_slot             => 8000,  # summary ceiling (XL)
        dialog                => -1,
        description           => 'XL (>256K): full everything, plenty of headroom',
    },
);

=head2 model_class($context_window)

Classify a context window into XS/S/M/L/XL.

Arguments:
    $context_window - Model's context window in tokens

Returns:
    Class name (string): 'XS', 'S', 'M', 'L', or 'XL'

=cut

sub model_class {
    my ($context_window) = @_;
    $context_window //= 0;

    return 'XS' if $context_window <= 32768;
    return 'S'  if $context_window <= 65536;
    return 'M'  if $context_window <= 131072;
    return 'L'  if $context_window <= 262144;
    return 'XL';
}

=head2 budget_for($class)

Get the budget table for a model class.

Arguments:
    $class - Model class ('XS', 'S', 'M', 'L', 'XL')

Returns:
    HashRef of section => token_budget, or undef if class is unknown.
    Use the keys for section names; values are token budgets (-1 = unlimited,
    0 = skip).

=cut

sub budget_for {
    my ($class) = @_;
    return undef unless defined $class && $class =~ /^(?:XS|S|M|L|XL)$/;
    return { %{ $DEFAULT_BUDGETS{$class} } };
}

=head2 effective_budget($context_window, $section)

Convenience: get the effective token budget for a section based on the
context window.

Arguments:
    $context_window - Model's context window in tokens
    $section        - Section key (e.g. 'ltm', 'csss_slot')

Returns:
    Token budget (integer) or -1 if unlimited.

=cut

sub effective_budget {
    my ($context_window, $section) = @_;
    my $class = model_class($context_window);
    my $budget = budget_for($class);
    return -1 unless $budget && defined $budget->{$section};
    return $budget->{$section};
}

=head2 apply_budget_to_payload($budget, $section, $content)

Apply a budget constraint to content. Truncates content to fit within
the budget (estimated tokens), or returns undef if the section is
skipped (budget = 0).

Arguments:
    $budget  - Token budget for this section (integer or -1)
    $section - Section name (for logging)
    $content - The content (string) to budget

Returns:
    $content (unchanged) if budget is -1 (unlimited).
    $content truncated if budget > 0 and content exceeds budget.
    undef if budget is 0 (section skipped).

=cut

sub apply_budget_to_payload {
    my ($budget, $section, $content) = @_;
    return undef unless defined $content;
    return $content if $budget == -1;
    return undef if $budget == 0;

    require CLIO::Memory::TokenEstimator;
    my $current_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($content);
    if ($current_tokens <= $budget) {
        return $content;
    }

    # Truncate to fit. Use a per-char cutoff based on the ratio
    # current_tokens/len so we approximate the right number of characters.
    my $len = length($content);
    return $content if $len == 0;
    my $ratio = $current_tokens / $len;
    my $target_chars = int($budget / ($ratio || 1));
    $target_chars = $len if $target_chars > $len;
    my $truncated = substr($content, 0, $target_chars);

    require CLIO::Core::Logger;
    CLIO::Core::Logger::log_debug('ModelBudget',
        sprintf('truncated section [%s] from %d tokens (%d bytes) to %d tokens (%d bytes)',
            $section, $current_tokens, $len,
            CLIO::Memory::TokenEstimator::estimate_tokens($truncated), $target_chars));

    return $truncated;
}

=head2 known_classes

Return the list of known model classes.

Returns:
    ArrayRef of class names.

=cut

sub known_classes {
    return [qw(XS S M L XL)];
}

1;

__END__

=head1 AUTHOR

CLIO Project

=cut