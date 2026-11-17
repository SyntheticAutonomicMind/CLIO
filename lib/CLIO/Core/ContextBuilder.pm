# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::ContextBuilder;

use strict;
use warnings;
use utf8;
use feature 'state';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use CLIO::Core::Logger qw(log_debug log_warning log_error);
use CLIO::Memory::TokenEstimator qw(estimate_messages_tokens message_character_count);
use CLIO::Memory::LongTerm ();
use Digest::SHA qw(sha256_hex);
use Encode qw(encode_utf8);
# YaRN does not use Exporter; call its subs via fully-qualified name.
# Loading the module here ensures the symbol is defined before
# _select_turns tries to call recover_substantive_task.
use CLIO::Memory::YaRN ();

=encoding UTF-8

=head1 NAME

CLIO::Core::ContextBuilder - Relevance-aware projection builder for CLIO

=head1 DESCRIPTION

Builds the per-request model-facing projection from a session's full
role-based history, structured active state, and long-term memory.

The projection is what the model sees inside the C<<messageHistory>>
XML block. The full session history (state->{history}) is never
mutated by this module - the projection is generated fresh each
request and discarded after serialization.

Three responsibilities:

=over

=item *

Turn selection - pick the anchor turn (original substantive task), the
recent complete turns, and the compressed tail. The oldest content is
collapsed into one or more C<<compressedTurn>> markers when budget is
tight.

=item *

LTM relevance - score long-term memory entries against the current
request, active task, and unresolved state. Return only the entries
that meet the relevance threshold and cap the list.

=item *

Structured userContext - render the trailing context block as
discrete elements (C<<activeTask>>, C<<activeTodos>>,
C<<unresolvedState>>, C<<relevantMemory>>, C<<environment>>) instead
of free-form markdown. Drop framework narration, tier labels, and the
index footer that previously lived in the userContext.

=back

The projection is deterministic given the same inputs.

=head1 SYNOPSIS

    use CLIO::Core::ContextBuilder;

    my $projection = CLIO::Core::ContextBuilder::build_projection(
        history      => $session->get_conversation_history(),
        user_input   => $user_input,
        active_task  => $active_task_text,       # scalar (optional)
        active_todos => \@active_todos,          # arrayref (optional)
        ltm          => \@ltm_entries,           # arrayref of {confidence, content, type}
        unresolved   => \@unresolved_strings,    # arrayref (optional)
    );

    # The projection's anchor + turns can be pushed directly into the
    # role-based messages array as individual messages. The dynamic
    # parts (active task, todos, LTM, environment, context files) get
    # rendered via get_user_context() in WorkflowOrchestrator so the cache-stable
    # prefix (system_prompt + role-based history) stays unchanged
    # across turns while dynamic context refreshes.

=cut

our $VERSION = '1.0.0';

# Tunables (defaults align with scratch/optimize.md)
our $RELEVANCE_THRESHOLD = 5;
our $MAX_RELEVANT_MEMORIES = 5;
our $MIN_MEMORY_CONFIDENCE = 0.5;

# Package-level cache for lazy compressed_tail regeneration.
# Keyed on _compressed_tail_sig($dropped_turns, $active_task).
# Bounded to prevent unbounded growth across long sessions; oldest
# entries are evicted when the limit is exceeded (LRU via ordered keys).
my %_compressed_tail_cache;
my @_compressed_tail_cache_order;
our $COMPRESSED_TAIL_CACHE_MAX = 50;

# Recent-window selection is token-budgeted, not turn-counted.
#
# A turn-count window is blind to how large a turn is. In an agentic
# session one "turn" can be hundreds of tool calls, so counting turns
# either keeps far more than the budget allows or discards hundreds of
# thousands of tokens while most of the window is empty. Selection
# therefore fills the available prompt budget and drops from the oldest
# end by measured size.
#
# Feedback and hysteresis:
# - selection fills up to RECENT_FILL_FRACTION of the available budget
# - when the total exceeds that, it drops until it is below
#   RECENT_LOW_FRACTION. The gap is headroom: without it, one new turn
#   crosses the line again and every request re-prefills the array
# - RECENT_MIN_TURNS always survives, whatever it costs, so the model
#   never loses the turns it is currently working in
our $RECENT_MIN_TURNS       = 2;
our $RECENT_FILL_FRACTION   = 0.70;
our $RECENT_LOW_FRACTION    = 0.55;


# ============================================================================
# Public API
# ============================================================================

=head2 build_projection

Class method. Build a C<ContextProjection> from session state.

Arguments:
- history: Arrayref of role-based message hashes (the source of truth;
  this method does NOT mutate it).
- user_input: Current user input string.
- active_task: Scalar describing the original substantive task (optional).
- active_todos: Arrayref of todo hashes {id, status, content} (optional).
- ltm: Arrayref of LTM entries as {confidence, content, type} (optional).
- unresolved: Arrayref of strings describing unresolved state (optional).
- session: Session object (optional; used for anchor fallback via YaRN).
- context_window: Model context window in tokens (optional; used to
  scale the compressed tail budget). Defaults to 128K.
- prompt_budget: Tokens available to the whole prompt for this model
  (optional). When provided, recent-window selection fills this budget
  instead of keeping a fixed number of turns.
- reserved_tokens: Tokens already committed to non-history content -
  system prompt and tool schema (optional, default 0). Subtracted from
  prompt_budget before selecting turns.
- context_files: Arrayref of file paths to render into the userContext
  block (optional).
- context_files_block: Pre-rendered context-files string (optional). Use
  this instead of C<context_files> when the caller already has the disk
  content, e.g. C</context add files>.

Returns a hashref:
   {
       turns             => [ ... ],  # selected full turns (newest 1-2)
       anchor            => { ... },  # original task turn (1 element) or undef
       compressed_tail   => "...",    # one combined thread_summary text, or ''
       relevant_memory   => [ ... ],  # arrayref of {confidence, content}
       active_task       => "...",    # for per-iteration LTM re-score
       user_input        => "...",    # for per-iteration LTM re-score
       token_estimate    => $int,
       stats             => { ... },  # selection record: recent_turns,
                                      # dropped_turns/messages/chars/estimate,
                                      # compressed_tail_chars, kept_estimate
   }

=cut

sub build_projection {
    my (%args) = @_;

    my $history       = $args{history}       || [];
    my $user_input    = $args{user_input}    // '';
    my $active_task   = $args{active_task}   // '';
    my $active_todos  = $args{active_todos}  || [];
    my $ltm           = $args{ltm}           || [];
    my $unresolved    = $args{unresolved}    || [];
    my $session       = $args{session};
    my $context_window = $args{context_window};

    # context_files: callers pass either an arrayref of file paths
    # (which we render here, see _render_user_context) or a
    # pre-rendered string block (context_files_block). The pre-rendered
    # form is used when the caller needs access to disk content (e.g.
    # /context add files), which _render_user_context does not have.
    my $context_files       = $args{context_files}       || [];
    my $context_files_block = $args{context_files_block} // '';

    # Prompt budget for the whole request, and the tokens already
    # committed to things that are not history (system prompt, tool
    # schema). Recent-window selection fills only the remainder.
    my $prompt_budget   = $args{prompt_budget};
    my $reserved_tokens = $args{reserved_tokens} // 0;
    my $budget = {
        prompt_budget => $prompt_budget,
        reserved      => $reserved_tokens,
    };

    my $turns = _split_into_turns($history);

    # Select anchor (first substantive user turn) and recent turns
    my ($anchor_turn, $recent_turns, $dropped_turns) =
        _select_turns($turns, $session, $history, $active_task, $budget);

    # Build the compressed tail if any turns were dropped
    my $compressed_tail = _build_compressed_tail($dropped_turns, $active_task, $context_window, $active_todos, $unresolved, $ltm, $prompt_budget);

    my @deduped_recent = @$recent_turns;

    # Cross-turn dedup: collapses two adjacent pure-tool turns that
    # both call the same tool with the same args and the same result,
    # provided the second turn's user message is a short continuation
    # prompt. Operates on the full chain (anchor + recent_turns) so a
    # recent turn that matches the anchor also collapses. Safe by
    # construction - any non-pure-tool turn or any non-continuation
    # user message is left untouched.
    my $chain = defined $anchor_turn ? [$anchor_turn, @deduped_recent] : [@deduped_recent];
    my $deduped_chain = collapse_repeated_tool_calls_across_turns($chain);
    if (defined $anchor_turn) {
        @deduped_recent = @$deduped_chain[1 .. $#$deduped_chain];
    } else {
        @deduped_recent = @$deduped_chain;
    }

    # Score LTM entries against the current request.
    my $relevant = score_ltm($ltm, $user_input, $active_task, $unresolved);

    # Agent tool-loop collapse. A run of repeated tool exchanges carries
    # no user message between the exchanges, so _split_into_turns puts
    # the whole run in ONE turn and the cross-turn collapse above cannot
    # see it. Collapse those runs per turn, then render the repeat
    # markers so the model can see that it repeated the call.
    my @collapsed_recent = map {
        _render_repeat_markers(collapse_repeated_tool_exchanges($_))
    } @deduped_recent;
    my $anchor_collapsed = ref($anchor_turn) eq 'ARRAY'
        ? _render_repeat_markers(collapse_repeated_tool_exchanges($anchor_turn))
        : undef;

    my $anchor_list = ref($anchor_collapsed) eq 'ARRAY' ? $anchor_collapsed : [];
    my @all_messages;
    push @all_messages, @$anchor_list;
    # @collapsed_recent holds one arrayref per turn. Flatten it: pushing
    # the turn arrayrefs made every message invisible to the estimator
    # (which skips non-hash entries), so token_estimate was always just
    # the priming overhead.
    push @all_messages, map { @$_ } @collapsed_recent;
    my $token_estimate = estimate_messages_tokens(\@all_messages);

    # Selection record: what the projection kept and what it archived.
    # Without this, a turn-window change is invisible in the session —
    # the only symptom is a smaller prompt on the next request.
    my ($dropped_messages, $dropped_chars) = (0, 0);
    for my $turn (@$dropped_turns) {
        next unless ref($turn) eq 'ARRAY';
        for my $msg (@$turn) {
            next unless ref($msg) eq 'HASH';
            $dropped_messages++;
            $dropped_chars += message_character_count($msg->{content});
            if (ref($msg->{tool_calls}) eq 'ARRAY') {
                for my $call (@{$msg->{tool_calls}}) {
                    next unless ref($call) eq 'HASH';
                    $dropped_chars += length($call->{function}{name} // '');
                    $dropped_chars += length($call->{function}{arguments} // '');
                }
            }
        }
    }
    my @dropped_messages_flat;
    for my $turn (@$dropped_turns) {
        push @dropped_messages_flat, grep { ref($_) eq 'HASH' } @$turn
            if ref($turn) eq 'ARRAY';
    }

    my $recent_message_count = 0;
    $recent_message_count += scalar(@$_) for @collapsed_recent;

    my $stats = {
        turns_total          => scalar(@$turns),
        prompt_budget        => $prompt_budget,
        reserved_tokens      => $reserved_tokens,
        budget_available     => (defined $prompt_budget && $prompt_budget > 0)
                                    ? $prompt_budget - $reserved_tokens : undef,
        recent_turns         => scalar(@collapsed_recent),
        recent_messages      => $recent_message_count,
        anchor_messages      => scalar(@$anchor_list),
        dropped_turns        => scalar(@$dropped_turns),
        dropped_messages     => $dropped_messages,
        dropped_chars        => $dropped_chars,
        dropped_estimate     => estimate_messages_tokens(\@dropped_messages_flat),
        compressed_tail_chars => length($compressed_tail // ''),
        kept_estimate        => $token_estimate,
    };

    return {
        turns               => \@collapsed_recent,
        anchor              => $anchor_collapsed,
        compressed_tail     => $compressed_tail,
        relevant_memory     => $relevant,
        active_task         => $active_task,
        active_todos        => $active_todos,
        unresolved          => $unresolved,
        context_files       => $context_files,
        context_files_block => $context_files_block,
        # user_input is preserved on the projection for reference.
        user_input          => $user_input,
        token_estimate      => $token_estimate,
        stats               => $stats,
        # Note: budget_tokens is no longer accepted — the proactive
        # trim (MessageValidator::_role_based_tail_walk) is the
        # authoritative token-budget enforcer via compute_prompt_budget().
        # The projection's compressed_tail handles lossy summarization of
        # dropped turns; it does not need an independent token budget.
    };
}

=head2 score_ltm

Score LTM entries against the current request, active task, and
unresolved state. Returns up to C<MAX_RELEVANT_MEMORIES> entries with
score >= C<RELEVANCE_THRESHOLD>, sorted by score desc.

Scoring formula:
    score = 3 * keyword_overlap(current_input, content)
          + 2 * keyword_overlap(active_task, content)
          + 2 * keyword_overlap(unresolved, content)
          + 1 * confidence
          + 2 * category_recognition(content)
    (capped at the MAX_RELEVANT_MEMORIES entries)

The C<category_recognition> term is +2 if the memory body mentions
any of the framework-meta category words (prompt, context, cache,
ltm, framework, projection, model-facing, narration, etc.). This
lifts meta-relevant memories (e.g. "Model-facing prompt paths must
NOT tell the model about framework internals") above the relevance
threshold when the user is working on framework code, even when
lexical overlap with the immediate question is low.

Returns arrayref of {confidence, content, score, type}.

=cut

# Category words that signal a memory is about the framework itself
# (prompt construction, context management, LTM, cache behavior, etc.).
# These memories are *meta-relevant* when the user is working on the
# framework and should surface even if the lexical overlap with the
# current question is low. A small, conservative set - adding too
# many words here would over-surface and dilute the score.
my @CATEGORY_WORDS = qw(
    prompt
    prompts
    context
    contexts
    cache
    caching
    ltm
    long-term memory
    framework
    projection
    model-facing
    narration
    trim
    trimming
    prompt-history
    messageHistory
    message history
    userContext
    user context
);

sub _category_match {
    my ($content) = @_;
    return 0 unless defined $content && length $content;
    my $lc = lc $content;
    for my $word (@CATEGORY_WORDS) {
        return 1 if index($lc, lc $word) >= 0;
    }
    return 0;
}

=head2 _meta_category_count

Count how many distinct framework-category words appear in the content.
Used to gate the category boost: the boost only fires when the entry
contains multiple framework terms (not just one common word like
"context" or "framework" that could appear in any context).

Arguments:
- $content: Text to check

Returns: Integer count of distinct category words found

=cut

sub _meta_category_count {
    my ($content) = @_;
    return 0 unless defined $content && length $content;
    my $lc = lc $content;
    my %seen;
    my $count = 0;
    for my $word (@CATEGORY_WORDS) {
        my $lc_word = lc $word;
        next if $lc_word !~ /^[a-z]/;  # skip multi-word like "long-term memory"
        next if $seen{$lc_word}++;     # deduplicate (e.g. "context" appears
                                     # twice: standalone + from "user context"
        $count++ if index($lc, $lc_word) >= 0;
    }
    return $count;
}

sub score_ltm {
    my ($ltm, $current_input, $active_task, $unresolved) = @_;
    $ltm ||= [];

    return [] unless @$ltm;

    my $input_keywords  = _keywords($current_input // '');
    my $task_keywords   = _keywords($active_task // '');
    my $unres_keywords  = _keywords(join(' ', @$unresolved));

    # Guard against double-counting: when _active_task_text falls back
    # to user_input (common for first-turn or no-goal sessions),
    # task_keywords is identical to input_keywords. Counting the
    # overlap both as input (3x) and task (2x) inflates the score by
    # 5x instead of 3x, causing unrelated entries with incidental
    # keyword overlap (e.g. "this", "with") to pass the relevance
    # threshold. Only count task overlap when the task text differs.
    my $task_differs = ($active_task // '') ne ($current_input // '');

    # Lazy sanitize: pre-existing LTM entries may contain
    # framework-narration words (memory_operations, prompt cache,
    # etc.) written before the sanitizer existed. Clean them on read
    # so the prose renderer never sees the framework smell.
    # Cache the LongTerm instance — sanitize_narration* are stateless
    # (they only reference package-level @SANITIZE_DROP_PHRASES and
    # %SANITIZE_REPLACEMENTS), so creating a new object per call is
    # wasted work (two time() syscalls + nested data-structure init).
    state $sanitizer = CLIO::Memory::LongTerm->new();

    # The category boost is meaningful when the user is working on
    # the framework itself. Detect that by checking if the current
    # input or active task contains a category word too - this
    # gates the boost so it doesn't surface prompt-hygiene memories
    # during, say, a code review of unrelated infrastructure.
    my $input_is_meta = _category_match($current_input)
                     || _category_match($active_task);

    my @scored;
    for my $entry (@$ltm) {
        next unless ref($entry) eq 'HASH';
        my $content = $entry->{content} // '';

        # Code patterns (type=pattern) and problem solutions
        # (type=solution) legitimately need tool/function names -
        # the model needs to be able to recall "use this specific
        # tool to do this specific thing". Apply only the
        # drop-phrase cleanup (narration-sentence removal), not the
        # tool-name replacement. For other entry types (discoveries,
        # workflows, failures, rules) run the full sanitizer so
        # framework narration doesn't leak into the model context.
        my $entry_type = $entry->{type} // '';
        if ($entry_type eq 'pattern' || $entry_type eq 'solution') {
            $content = $sanitizer->sanitize_narration_drop_only($content);
        } else {
            $content = $sanitizer->sanitize_narration($content);
        }
        next unless length $content;

        my $confidence = $entry->{confidence};
        $confidence = 0.5 unless defined $confidence && $confidence =~ /^-?\d+(?:\.\d+)?$/;

        # Confidence floor - memories below the floor are dropped
        # unconditionally. The plan's tier labels are gone, but we
        # still want to suppress obviously-stale entries.
        next if $confidence < $MIN_MEMORY_CONFIDENCE;

        my $mem_keywords = _keywords($content);
        my $score = 0;
        $score += 3 * _keyword_overlap($input_keywords, $mem_keywords);
        $score += ($task_differs ? 2 : 0) * _keyword_overlap($task_keywords, $mem_keywords);
        $score += 2 * _keyword_overlap($unres_keywords, $mem_keywords);
        $score += 1 * $confidence;
        # Category boost: +2 if the user is doing framework work and
        # the memory is about framework work. This rescues
        # meta-relevant memories that would otherwise be filtered
        # out by pure lexical scoring. Requires 2+ distinct category
        # words in the entry to avoid false positives from common
        # words like "context" or "framework" that appear in any text.
        $score += 2 if $input_is_meta && _meta_category_count($content) >= 2;

        # Tier weight: unverified entries get a 0.3x scoring penalty so
        # they rank below trusted entries at injection time, matching
        # docs/MEMORY.md's described three-channel enforcement
        # (scoring penalty + prompt badge + differential decay).
        # The bug flagged in the agent-memory-atlas report was that this
        # penalty lived only in score_entry (used by consolidate's cap
        # eviction) and was never applied in score_ltm's injection path.
        my $tier = $entry->{entry}{tier} // 'unverified';
        my $tier_weight = ($tier eq 'trusted') ? 1.0 : 0.3;

        # Tier weight is a RANKING penalty only: trusted entries sort above
        # unverified entries with equal lexical relevance, but the keep/drop
        # gate is evaluated against the raw (pre-penalty) score. Applying the
        # 0.3x multiplier at the gate eliminated every unverified entry -- and
        # add_discovery/add_problem_solution/etc. all create 'unverified'
        # entries by default (promoted to 'trusted' only after two
        # corroborations). That made LTM projection dead for all freshly
        # observed memories, since a strong lexical match (raw score up to ~6)
        # was crushed to ~1.8 and fell below RELEVANCE_THRESHOLD (5). This
        # matches docs/MEMORY.md's three-channel enforcement: scoring penalty
        # (ranking), prompt badge ([UNVERIFIED]), differential decay -- the
        # penalty lowers ordering, it does not veto injection.
        my $raw_score  = $score;
        $score         = $score * $tier_weight;

        push @scored, {
           content    => $content,
           confidence => $confidence,
           type       => $entry->{type},
           score      => $score,
           raw_score  => $raw_score,
           _is_meta   => ($input_is_meta && _meta_category_count($content) >= 2) ? 1 : 0,
           tier       => $tier,
           corroboration_count => $entry->{entry}{corroboration_count} // 0,
       };
   }

    # Highest score first (penalized score ranks trusted above unverified).
    # Two threshold tiers:
    # - Regular memories: raw_score >= RELEVANCE_THRESHOLD (5)
    # - Category-matched memories (input is framework work AND
    #   memory is about framework work): raw_score >= 3, because the
    #   meta-relevance is signal enough on its own.
    @scored = sort { $b->{score} <=> $a->{score} } @scored;
    my @kept = grep {
        my $s = $_->{raw_score};       # gate on relevance, not trust tier
        my $is_meta = $_->{_is_meta};  # set in the loop above
        $s >= $RELEVANCE_THRESHOLD || ($is_meta && $s >= 3);
    } @scored;

    # Cap the list
    if (@kept > $MAX_RELEVANT_MEMORIES) {
        @kept = @kept[0 .. ($MAX_RELEVANT_MEMORIES - 1)];
    }

    return \@kept;
}

=head2 collapse_repeated_tool_calls_across_turns

Cross-turn variant of L<collapse_repeated_tool_calls>. Operates on
an arrayref of turns where each turn is an arrayref of role-based
messages (the shape produced by L<_split_into_turns> and stored in
C<< $projection->{turns} >>). For each pair of adjacent turns,
checks the strict condition that makes cross-turn collapse safe:

  1. Both turns contain exactly one assistant message with exactly
     one tool call, and exactly one tool result.
  2. The two tool calls have identical name, arguments, AND result
     digest.
  3. The user message of the second turn is a short continuation
     prompt (a single non-question sentence under 80 chars, or a
     common continuation phrase like "continue", "ok", "go on").

When all three hold, the second turn's tool call is dropped (it is
already represented by the first turn's tool call with a bumped
repeats=N) and the user message of the second turn is preserved by
appending it to the first turn's message array. This ensures the
user's input is not silently lost — it remains visible in the
projection as a separate message after the tool result.

If any condition fails for a turn pair, the second turn is left
untouched (safe default: prefer over-rendering to losing information).

Returns the arrayref (mutated in place; the caller controls whether
to mutate the source).

=cut

# Common short continuation phrases the model can recognize as
# "go ahead with whatever you were doing". Case-insensitive match.
# Declared with `our` so it's shared safely across the grep closure
# in _is_continuation_prompt (a `my` here triggered a closure warning
# under strict).
our @CONTINUATION_PHRASES = (
    qr/\Acontinue\.?\z/i,
    qr/\Ago on\.?\z/i,
    qr/\Aok\.?\z/i,
    qr/\Aokay\.?\z/i,
    qr/\Aproceed\.?\z/i,
    qr/\Akeep going\.?\z/i,
    qr/\Ayes\.?\z/i,
    qr/\Ay\.?\z/i,
    qr/\Aplease continue\.?\z/i,
    qr/\Ago ahead\.?\z/i,
    qr/\Asame as before\.?\z/i,
    qr/\Aagain\.?\z/i,
    qr/\Aand\?+\s*\z/i,
);

sub _is_continuation_prompt {
    my ($text, $phrase_only) = @_;
    return 0 unless defined $text;
    $text = '' . $text;
    return 0 if length($text) > 80;
    return 1 if grep { $text =~ $_ } @CONTINUATION_PHRASES;
    # When $phrase_only is set, stop after exact phrase matching (used by
    # _build_compressed_tail pre-filter and filter_continuation_prompts,
    # which must not filter short non-continuation text).
    return 0 if $phrase_only;
    return 0 if $text =~ /\?/;
    return 0 if $text =~ /\b(why|how|what|when|where|which|who|can|could|would|should|will|do|does|did|is|are|was|were)\b/i;
    return 1 if length($text) < 30;
    return 0;
}

# Extract the (assistant_with_tool_call, tool_result_message) pair
# from a turn. Returns () if the turn is not a "pure tool turn".
sub _turn_tool_pair {
    my ($turn) = @_;
    return () unless ref($turn) eq 'ARRAY' && @$turn;

    my ($assistant, $tool);
    for my $msg (@$turn) {
        next unless ref($msg) eq 'HASH';
        my $role = $msg->{role} // '';
        if ($role eq 'assistant') {
            return () if $assistant;  # more than one assistant -> not pure
            $assistant = $msg;
        } elsif ($role eq 'tool') {
            return () if $tool;  # more than one tool result -> not pure
            $tool = $msg;
        } elsif ($role eq 'user') {
            # allowed (must be exactly one)
        }
    }
    return () unless $assistant && $tool;
    return () unless $assistant->{tool_calls}
                  && ref($assistant->{tool_calls}) eq 'ARRAY'
                  && @{ $assistant->{tool_calls} } == 1;
    # Allow short conclusion text ("Reading.", "Looking at it.") but
    # not long reasoning text. Long content means the model is
    # explaining something substantial - keep that turn as-is so the
    # model can see the reasoning.
    return () if length($assistant->{content} // '') > 80;
    return ($assistant, $tool);
}

# Compute the dedup signature: tool name + arguments + result digest.
# tool_call_id is intentionally NOT part of the signature - it's an
# opaque identifier assigned by the assistant each turn and differs for
# two semantically-identical calls. Semantic identity is
# (name, args, result).
sub _turn_signature {
    my ($turn) = @_;
    my ($assistant, $tool) = _turn_tool_pair($turn);
    return '' unless $assistant && $tool;
    my $tc = $assistant->{tool_calls}[0];
    my $name = $tc->{function}{name} // '';
    my $args = $tc->{function}{arguments} // '';
    my $result_digest = digest($tool->{content} // '');
    return "$name|$args|$result_digest";
}

# Get the user message content of a turn (the first user message).
sub _turn_user_content {
    my ($turn) = @_;
    return undef unless ref($turn) eq 'ARRAY';
    for my $msg (@$turn) {
        next unless ref($msg) eq 'HASH';
        if (($msg->{role} // '') eq 'user') {
            return $msg->{content};
        }
    }
    return undef;
}

sub collapse_repeated_tool_calls_across_turns {
    my ($turns) = @_;
    return $turns unless ref($turns) eq 'ARRAY' && @$turns > 1;

    my @out;
    for my $i (0 .. $#$turns) {
        my $turn = $turns->[$i];
        if ($i > 0
            && @out  # there IS a previously-emitted turn to compare against
            && _turn_signature($out[-1])
            && _turn_signature($out[-1]) eq _turn_signature($turn)
            && _is_continuation_prompt(_turn_user_content($turn))) {
            # The previously-emitted turn already represents this tool
            # call. Bump its repeats counter instead of emitting the
            # duplicate.
            my ($prev_assistant, $prev_tool) = _turn_tool_pair($out[-1]);
            $prev_tool->{_repeats} = ($prev_tool->{_repeats} // 1) + 1;
            # Preserve the continuation user message by appending it to
            # the previous turn. Dropping the entire turn — including
            # the user's message — silently lost the user's input.
            # Appending it to the previous turn is safe: the turn is
            # later flattened into individual messages and
            # enforce_message_alternation preserves consecutive user
            # messages as-is (no merging).
            for my $msg (@$turn) {
                if (ref($msg) eq 'HASH' && ($msg->{role} // '') eq 'user') {
                    push @{$out[-1]}, { %$msg };
                    last;
                }
            }
            next;  # don't emit the duplicate turn
        }
        push @out, $turn;
    }

    return \@out;
}

=head2 collapse_repeated_tool_exchanges

Collapse a run of repeated tool exchanges inside a single turn.

An agent tool loop produces a message run shaped like

    [user] [assistant+tool_call] [tool result] [assistant+tool_call] [tool result] ...

with no user message between the exchanges. L</_split_into_turns> starts
a turn at a user message, so that whole run lands in ONE turn and
L</collapse_repeated_tool_calls_across_turns> never sees the duplicates:
it needs two adjacent pure-tool *turns*, and the within-turn variant it
was derived from has been removed.

A model that re-issues the same call then finds N copies of the same
call/result pair in its context. Each copy reinforces the pattern, so
the repetition becomes self-sustaining instead of ending on its own.
This function collapses such a run to its last exchange - the most
recent result is the current state - and records the run length on the
tool message so the count can be rendered for the model.

Only mechanical exchanges collapse: exactly one tool call and no
substantive assistant text (the same 80-character rule the pure-tool
turn check uses). An exchange where the model wrote a real explanation
is left alone, as is any exchange separated from the next by a user or
assistant-text message.

Returns a new arrayref. The input messages are not modified.

=cut

sub collapse_repeated_tool_exchanges {
    my ($messages) = @_;
    return $messages unless ref($messages) eq 'ARRAY' && @$messages;

    my @out;
    my $i = 0;
    my $total = scalar(@$messages);

    while ($i < $total) {
        my $exchange = _tool_exchange_at($messages, $i);
        if (!$exchange) {
            push @out, $messages->[$i];
            $i++;
            next;
        }

        my ($assistant, $tool, $after) = @$exchange;
        my $signature = _exchange_signature($assistant);
        my $count = 1;
        my $last_assistant = $assistant;
        my $last_tool = $tool;
        my $cursor = $after;

        # Walk forward over adjacent exchanges with the same signature.
        # _tool_exchange_at only matches a pair that starts at the
        # cursor, so anything between two exchanges (a user message, an
        # assistant message with prose, a multi-call assistant) stops the
        # run - which is the correct boundary.
        while ($cursor < $total) {
            my $next = _tool_exchange_at($messages, $cursor);
            last unless $next;
            my ($next_assistant, $next_tool, $next_after) = @$next;
            last unless _exchange_signature($next_assistant) eq $signature;
            $count++;
            $last_assistant = $next_assistant;
            $last_tool = $next_tool;
            $cursor = $next_after;
        }

        if ($count > 1) {
            push @out, _copy_with_repeat_count($last_assistant, $last_tool, $count);
        } else {
            push @out, $assistant, $tool;
        }
        $i = $cursor;
    }

    return \@out;
}

# Match a tool exchange at $idx: an assistant message carrying exactly
# one tool call, immediately followed by its tool result. Returns
# [assistant, tool, index_after_the_pair] or undef.
sub _tool_exchange_at {
    my ($messages, $idx) = @_;
    return undef if $idx + 1 > $#$messages;
    my $assistant = $messages->[$idx];
    my $tool = $messages->[$idx + 1];
    return undef unless ref($assistant) eq 'HASH' && ref($tool) eq 'HASH';
    return undef unless ($assistant->{role} // '') eq 'assistant';
    return undef unless ($tool->{role} // '') eq 'tool';
    my $calls = $assistant->{tool_calls};
    return undef unless ref($calls) eq 'ARRAY' && @$calls == 1;
    my $content = $assistant->{content};
    return undef if ref($content);  # structured content - not mechanical
    return undef if length($content // '') > 80;
    return [$assistant, $tool, $idx + 2];
}

# Identity of a tool exchange: the tool name plus its arguments.
# The result is deliberately excluded - the same call with the same
# arguments can legitimately produce a different result on each run
# (a growing counter, a changing file). The tool_call_id is excluded
# for the same reason as in _turn_signature: it is an opaque per-turn
# identifier.
sub _exchange_signature {
    my ($assistant) = @_;
    return '' unless ref($assistant) eq 'HASH';
    my $calls = $assistant->{tool_calls};
    return '' unless ref($calls) eq 'ARRAY' && @$calls;
    my $call = $calls->[0];
    return '' unless ref($call) eq 'HASH';
    my $function = $call->{function};
    return '' unless ref($function) eq 'HASH';
    my $name = $function->{name} // '';
    my $arguments = $function->{arguments} // '';
    if (ref($arguments) eq 'HASH') {
        $arguments = join(',',
            map { $_ . '=' . (defined $arguments->{$_} ? $arguments->{$_} : '') }
            sort keys %{$arguments});
    } elsif (ref($arguments) eq 'ARRAY') {
        $arguments = join(',', map { defined $_ ? $_ : '' } @{$arguments});
    }
    return $name . '|' . $arguments;
}

# Copy an exchange and stamp the repeat count on the tool message. The
# copies keep the original history untouched; the count is rendered
# into the tool content by _render_repeat_markers.
sub _copy_with_repeat_count {
    my ($assistant, $tool, $count) = @_;
    my %assistant_copy = %{$assistant};
    my %tool_copy = %{$tool};
    my $existing = $tool_copy{_repeats} // 1;
    $tool_copy{_repeats} = $existing > $count ? $existing : $count;
    return (\%assistant_copy, \%tool_copy);
}

=head2 _render_repeat_markers

Render the repeat count recorded on a tool message into its content so
the model can see how many times it repeated the call. The count alone
is not enough - a collapsed run that looks like a single call gives
the model no reason to change behavior.

Returns a new arrayref. The input messages are not modified.

=cut

sub _render_repeat_markers {
    my ($messages) = @_;
    return $messages unless ref($messages) eq 'ARRAY';
    my @out;
    for my $msg (@$messages) {
        if (ref($msg) eq 'HASH'
            && ($msg->{role} // '') eq 'tool'
            && ($msg->{_repeats} // 0) > 1) {
            my $content = $msg->{content};
            if (!defined $content) {
                push @out, { %{$msg}, content => _repeat_note($msg->{_repeats}) };
                next;
            }
            if (!ref($content)) {
                push @out, { %{$msg}, content => _repeat_note($msg->{_repeats}) . $content };
                next;
            }
        }
        push @out, $msg;
    }
    return \@out;
}

sub _repeat_note {
    my ($count) = @_;
    return "[repeated call: this exact call ran $count times in succession. "
         . "The result shown is from the last run; all $count runs took effect.]\n";
}

=head2 digest

Compute a short content digest for duplicate detection. Uses
SHA-256 truncated to 16 hex chars (64 bits) - collision-safe enough
for within-session dedup, cheap to serialize.

=cut

sub digest {
    my ($content) = @_;
    return substr(sha256_hex(encode_utf8($content // '')), 0, 16);
}

# ============================================================================
# Internal helpers
# ============================================================================

=head2 _split_into_turns

Group the source history into per-turn arrays of messages. A turn
starts at a user message and includes everything that follows until
the next user message (or end of array). Each turn is an arrayref
of role-based messages (user, assistant, tool) - the same structure
the rebuild path pushes into @messages after the role-based history
refactor.

Returns an arrayref of turn arrayrefs.

=cut

sub _split_into_turns {
    my ($history) = @_;
    my @turns;
    my $current;
    for my $msg (@$history) {
        next unless ref($msg) eq 'HASH';
        my $role = $msg->{role} // '';
        if ($role eq 'user') {
            $current = [];
            push @turns, $current;
        }
        next unless $current;
        push @$current, $msg;
    }
    return \@turns;
}

=head2 _recent_count_for_budget($turns, $budget)

Choose how many recent turns fit the available prompt budget.

$budget is a hashref:
    prompt_budget => tokens available to the whole prompt
    reserved      => tokens already committed (system prompt, tool schema)
    min_turns     => floor (optional, default $RECENT_MIN_TURNS)

Behaviour:
- With no usable budget, every turn is kept. Guessing a turn count is
  worse than keeping the session intact; the proactive trim
  (MessageValidator::_role_based_tail_walk) still enforces the limit.
- If the turns fit within RECENT_FILL_FRACTION of the available budget,
  keep them all.
- Otherwise drop from the oldest end until the remainder is below
  RECENT_LOW_FRACTION. Filling to the same threshold that triggers a
  drop would make the next turn cross it again, and every request would
  re-prefill the array.

Returns the number of turns to keep.

=cut

sub _recent_count_for_budget {
    my ($turns, $budget) = @_;

    my $total = scalar(@$turns);
    return 0 if $total == 0;

    my $min_turns = $budget->{min_turns} // $RECENT_MIN_TURNS;
    $min_turns = $total if $min_turns > $total;

    my $prompt_budget = $budget->{prompt_budget};
    my $reserved      = $budget->{reserved} // 0;
    my $available     = (defined $prompt_budget && $prompt_budget > 0)
        ? $prompt_budget - $reserved : 0;

    # No usable budget: keep everything. The floor only rejects nonsense
    # (a caller that passed nothing, or a budget consumed entirely by the
    # system prompt) - the min-turns floor handles genuinely tiny budgets.
    return $total unless $available >= 200;

    my @cost = map {
        ref($_) eq 'ARRAY' ? estimate_messages_tokens($_) : 0
    } @$turns;
    my $total_cost = 0;
    $total_cost += $_ for @cost;

    my $fill = int($available * $RECENT_FILL_FRACTION);
    return $total if $total_cost <= $fill;

    my $low = int($available * $RECENT_LOW_FRACTION);

    # Accumulate from the newest turn backwards, stopping before the next
    # older turn would take the window past the low watermark.
    my $keep = 0;
    my $acc  = 0;
    for (my $i = $total - 1; $i >= 0; $i--) {
        last if $keep >= $min_turns && $acc + $cost[$i] > $low;
        $acc += $cost[$i];
        $keep++;
    }

    log_debug('ContextBuilder',
        sprintf('recent window: %d/%d turns kept (%d of %d available tokens, fill=%d low=%d)',
            $keep, $total, int($acc), int($available), $fill, $low));

    return $keep;
}

=head2 _select_turns

Pick the most recent N turns (5 by default, scaling up for long sessions)
and return the remaining turns as dropped for compression.

The original task is surfaced via the dynamic userContext (active_task from
session goals), not via a special anchor turn in the message history. The
YaRN thread_summary (in the compressed tail) preserves the original request
via the C<[original]> marker for cross-cycle carryover.

Returns (undef, \@recent_turns, \@dropped_turns). The first element (anchor)
is always undef in the new pipeline — the active task lives in the dynamic
userContext.

=cut

sub _select_turns {
    my ($turns, $session, $history, $active_task, $budget) = @_;
    $budget ||= {};

    my $total_turns = scalar(@$turns);
    return (undef, [], []) if $total_turns == 0;

    # Exclude ALL trailing incomplete turns, not just the last one.
    # Session resumes can leave multiple orphaned user messages at the
    # end of history (from interrupted turns). The last one is the
    # current turn (delivered separately); the rest are orphan user
    # messages from prior interrupted sessions that must be excluded
    # from the recent window to avoid consecutive-user-message
    # duplication in the @messages array (see enforce_message_alternation).
    my @trailing_incomplete;
    while ($total_turns > 0) {
        my $last_turn = $turns->[-1];
        last unless ref($last_turn) eq 'ARRAY';
        my $has_assistant_or_tool = 0;
        for my $msg (@$last_turn) {
            if (ref($msg) eq 'HASH'
                && ($msg->{role} // '') =~ /^(assistant|tool)$/) {
                $has_assistant_or_tool = 1;
                last;
            }
        }
        if (!$has_assistant_or_tool) {
            # Last turn is just a user message with no assistant/tool
            # response (current turn or prior interrupted session).
            push @trailing_incomplete, pop @$turns;
            $total_turns--;
        } else {
            last;
        }
    }

    # Discard the current turn (the last popped incomplete turn).
    # Its user input is delivered separately as the final user message
    # in _build_turn_context. Prior incomplete turns (if any) are kept
    # in @trailing_incomplete for compression into the dropped set.
    shift @trailing_incomplete if @trailing_incomplete;

    # After popping trailing incomplete turns, recompute $total_turns
    # from the remaining array to ensure consistency (pop already
    # decremented it, but this is a defensive double-check).
    $total_turns = scalar(@$turns);
    return (undef, [], \@trailing_incomplete) if $total_turns == 0;

    # Compute the recent window from the prompt budget: keep as many
    # complete turns as fit, drop from the oldest end when the total
    # exceeds the fill threshold.
    my $recent_target = _recent_count_for_budget($turns, $budget);
    my $recent_count = $recent_target;

    # Tool-turn preservation: if the most recent turn (or the 2nd-most
    # recent) contains assistant messages with tool_calls, always
    # include that turn in the recent window even if it would otherwise
    # be compressed. Without this, tool_calls from a prior turn get
    # compressed into prose via _build_compressed_tail, and the model
    # loses the actual tool_call/tool_result pairs — it re-issues the
    # same calls because it can't see the results (model looping bug).
    # The proactive trim (_role_based_tail_walk) has its own batch-atomic
    # drop logic, but _select_turns compressing the turn entirely is a
    # different path that loses the pairing at the turn-selection layer.
    my $force_include = 0;
    for my $offset (0, 1) {
        my $idx = $total_turns - 1 - $offset;
        next if $idx < 0;
        my $turn = $turns->[$idx];
        if (ref($turn) eq 'ARRAY') {
            for my $msg (@$turn) {
                if (ref($msg) eq 'HASH'
                    && ($msg->{role} // '') eq 'assistant'
                    && ref($msg->{tool_calls}) eq 'ARRAY'
                    && @{$msg->{tool_calls}}) {
                    $force_include = $offset + 1;
                    last;
                }
            }
        }
        last if $force_include;
    }
    if ($force_include && $recent_count < $force_include) {
        $recent_count = $force_include;
        log_debug('ContextBuilder',
            "Tool-turn preservation: extending recent window to include "
            . "$force_include turn(s) with tool_calls (was $recent_target)");
    }

    # Select the last $recent_count turns as "recent" (cache-stable prefix).
    my $start_idx = $total_turns - $recent_count;
    my @recent = @$turns[$start_idx .. $#$turns];

    # Everything before the recent window is "dropped" for compression.
    my @dropped;
    if ($start_idx > 0) {
        @dropped = @{$turns}[0 .. ($start_idx - 1)];
    }

    # Add prior incomplete turns (from session resumes) to the dropped
    # set so YaARN compresses their user message content rather than
    # silently losing it. @trailing_incomplete is ordered newest-first
    # (from pop); reverse for oldest-first to match @dropped ordering.
    if (@trailing_incomplete) {
        push @dropped, reverse @trailing_incomplete;
    }

    # Scan the recent window for mid-window incomplete turns (orphan
    # user messages from corrupted history that aren't at the trailing
    # edge). Move them to the dropped set for compression rather than
    # letting them create consecutive user messages in @messages.
    if (@recent) {
        my @filtered_recent;
        my @mid_incomplete;
        for my $turn (@recent) {
            my $has_assistant_or_tool = 0;
            if (ref($turn) eq 'ARRAY') {
                for my $msg (@$turn) {
                    if (ref($msg) eq 'HASH'
                        && ($msg->{role} // '') =~ /^(assistant|tool)$/) {
                        $has_assistant_or_tool = 1;
                        last;
                    }
                }
            }
            if ($has_assistant_or_tool) {
                push @filtered_recent, $turn;
            } else {
                push @mid_incomplete, $turn;
            }
        }
        if (@mid_incomplete) {
            @recent = @filtered_recent;
            push @dropped, @mid_incomplete;
            log_debug('ContextBuilder',
                "Moved " . scalar(@mid_incomplete) . " mid-window incomplete turn(s) to dropped set");
        }
    }

    return (undef, \@recent, \@dropped);
}

=head2 _build_compressed_tail

Combine all dropped turns into one compressed summary string suitable
for the # Earlier work prose section. Uses YaRN::compress_messages
when available (the real compressor) with a template-based fallback
for the rare case where YaRN is unavailable or returns empty.

The compressor is the same one used by the proactive trim
(MessageValidator::_role_based_tail_walk) on hard trim, so the
# Earlier work section now carries the same
information density as the cross-cycle thread_summary. For dropped
turns that contained real work (file reads, git commits, tool calls)
the section surfaces file paths and commit hashes, which the
template-based version could not.

To avoid ballooning the dynamic userContext (which is per-turn
cache-stable for Anthropic and most providers), we cap the dropped-
turn summary at a fixed character budget and prioritize substantive
turns over continuation turns. The anchor turn already carries the
original task, and the recent 1-2 turns carry the immediate prior
reasoning, so the compressed tail is the "what else was happening"
hint that links recent work back to the broader trajectory.

Returns '' when there are no dropped turns.

=cut

sub _build_compressed_tail {
    my ($dropped_turns, $active_task, $context_window, $active_todos, $unresolved, $ltm, $prompt_budget) = @_;

    return '' unless $dropped_turns && @$dropped_turns;

    # Cap for the compressed tail. Proportional to how much it replaces,
    # bounded by the caller's budget.
    my @dropped_messages;
    for my $turn (@$dropped_turns) {
        push @dropped_messages, grep { ref($_) eq 'HASH' } @$turn
            if ref($turn) eq 'ARRAY';
    }
    my $dropped_estimate = estimate_messages_tokens(\@dropped_messages);
    my $OVERALL_CAP = _compute_compressed_tail_cap($context_window, $dropped_estimate, $prompt_budget);

    # Lazy regeneration: cache the compressed tail keyed on a signature
    # of the dropped turns + active_task. If the inputs are unchanged,
    # reuse the cached result (deterministic — same inputs produce same
    # output from compress_for_context_recovery).
    my $sig = _compressed_tail_sig($dropped_turns, $active_task, $OVERALL_CAP);
    if (exists $_compressed_tail_cache{$sig}) {
        log_debug('ContextBuilder', "Reusing cached compressed_tail (sig=$sig)");
        return $_compressed_tail_cache{$sig};
    }

    # Pre-filter: drop the obvious continuation prompts ("continue",
    # "ok", "y", etc.) before handing to YaRN.
    my @flat_msgs;
    for my $turn (@$dropped_turns) {
        for my $msg (@$turn) {
            next unless ref($msg) eq 'HASH';
            my $role    = $msg->{role}    // '';
            my $content = $msg->{content} // '';
            next unless length $content;
            next if $role eq 'user' && _is_continuation_prompt($content, 1);
            push @flat_msgs, { %$msg };  # shallow copy so we don't mutate source
        }
    }

    # Try YaRN compression first.
    my $yarn_out = _yarn_compress_dropped(\@flat_msgs, $active_task, $context_window, $OVERALL_CAP, $active_todos, $unresolved, $ltm);

    my $tail;
    if (defined $yarn_out && length $yarn_out) {
        $tail = $yarn_out;
        if (length($tail) > $OVERALL_CAP) {
            $tail = _truncate($tail, $OVERALL_CAP);
            $tail .= '...';
        }
    } else {
        # Fallback: template-based joiner (when YaRN unavailable or
        # pre-filter ate everything).
        $tail = _build_compressed_tail_template(
            $dropped_turns, 3, 3, 120, 120, $OVERALL_CAP,
        );
    }

    # Cache the result for lazy regeneration. Evict oldest entry if the
    # cache has reached its maximum size (LRU via insertion-order tracking).
    if (scalar(keys %_compressed_tail_cache) >= $COMPRESSED_TAIL_CACHE_MAX) {
        my $oldest = shift @_compressed_tail_cache_order;
        delete $_compressed_tail_cache{$oldest};
    }
    push @_compressed_tail_cache_order, $sig;
    $_compressed_tail_cache{$sig} = $tail;

    return $tail;
}

# Compute a cache signature from the dropped turns + active_task.
# Uses truncated content to keep the key short.
sub _compressed_tail_sig {
    my ($dropped_turns, $active_task, $cap) = @_;
    my $sig = 't' . scalar(@$dropped_turns) . ':c' . ($cap // 0) . ':';
    for my $turn (@$dropped_turns) {
        next unless ref($turn) eq 'ARRAY';
        $sig .= scalar(@$turn) . '|' if @$turn;
        for my $msg (@$turn) {
            next unless ref($msg) eq 'HASH';
            $sig .= substr($msg->{content} // '', 0, 40);
        }
        $sig .= ',';
    }
    $sig .= ':' . substr($active_task // '', 0, 40);
    return $sig;
}

# Compute the character cap for the compressed tail.
#
# The tail replaces whole turns, so its size is proportional to what it
# replaces rather than fixed by the model's window. A fixed 0.5% of the
# window meant a 130k-token archive could be summarized into 5k tokens
# while 700k of budget sat unused - a 96% loss performed for no reason.
#
#   10% of the dropped tokens, floored at 0.5% of the window (so short
#   archives still get a usable tail) and capped at 4% of the prompt
#   budget (so the tail cannot crowd out live context).
#
# The tail sits in the last user message, at the END of the array, so its
# churn does not invalidate the provider's cached prefix.
sub _compute_compressed_tail_cap {
    my ($context_window, $dropped_estimate, $prompt_budget) = @_;
    require CLIO::Core::Defaults;
    $context_window //= CLIO::Core::Defaults::DEFAULT_CONTEXT_WINDOW();

    require CLIO::Memory::TokenEstimator;
    my $ratio = CLIO::Memory::TokenEstimator::get_effective_ratio();

    my $floor_tokens = int($context_window * 0.005);
    $floor_tokens = 300 if $floor_tokens < 300;

    my $cap_tokens = $floor_tokens;
    if ($dropped_estimate && $dropped_estimate > 0) {
        my $proportional = int($dropped_estimate * 0.10);
        $cap_tokens = $proportional if $proportional > $cap_tokens;
    }

    if ($prompt_budget && $prompt_budget > 0) {
        my $ceiling = int($prompt_budget * 0.04);
        $ceiling = $floor_tokens if $ceiling < $floor_tokens;
        $cap_tokens = $ceiling if $cap_tokens > $ceiling;
    }

    return int($cap_tokens * $ratio);
}

# YaRN-backed compression. Takes a flat message array (the same
# shape YaRN::compress_messages expects) and an optional task hint,
# calls compress_for_context_recovery (which extracts previous_summary
# from any <thread_summary> blocks in the array for cross-cycle carryover),
# and returns a thread_summary string WITH <thread_summary> wrapper tags
# intact (so it can be rendered as a canonical system message by
# WorkflowOrchestrator, and found/replaced by the trim paths). Returns
# undef if the result is empty / YaRN is unavailable.
sub _yarn_compress_dropped {
    my ($flat_msgs, $active_task, $context_window, $max_chars, $active_todos, $unresolved, $ltm) = @_;

    return undef unless $flat_msgs && @$flat_msgs;

    # YaRN->new() is cheap (hashref only), but compress_for_context_recovery
    # is stateless w.r.t. the instance — cache it per-process.
    state $yarn = CLIO::Memory::YaRN->new();

    my $compressed = eval {
        $yarn->compress_for_context_recovery($flat_msgs,
            original_task  => ($active_task // ''),
            context_window => $context_window,
            max_chars      => $max_chars,
            active_todos   => $active_todos,
            unresolved     => $unresolved,
            ltm_entries    => $ltm,
        );
    };
    return undef if $@ || !$compressed || !ref($compressed);

    my $content = $compressed->{content} // '';
    return undef unless length $content;

    # Ensure content is wrapped in <thread_summary> tags. YaRN's
    # compress_messages always emits these tags, but the fallback
    # template does not — normalize here so callers can always
    # detect the canonical compaction artifact by tag presence.
    # But first strip tags to check whether there is any MEANINGFUL
    # content inside — an empty summary (just tags + whitespace) is
    # treated as no-op so the caller falls through to the template
    # fallback or returns empty.
    my $inner = $content;
    $inner =~ s{</?thread_summary>}{}g;
    $inner =~ s/^\s+//;
    $inner =~ s/\s+$//;
    return undef unless length $inner;

    # Re-wrap with tags (YaRN's output already has them; this handles
    # the case where compress_messages returned untagged content).
    unless ($content =~ /<thread_summary>/) {
        $content = "<thread_summary>\n" . $inner . "\n</thread_summary>";
    }
    return undef unless length $content;

    return $content;
}

# Legacy template-based fallback. Preserved for the case where YaRN
# is unavailable or the pre-filter removed every dropped message.
sub _build_compressed_tail_template {
    my ($dropped_turns, $max_user, $max_asst, $max_user_chars, $max_asst_chars, $overall_cap) = @_;

    my @substantive_user;     # new -> old
    my @substantive_assistant;
    my $user_count = 0;
    my $assistant_count = 0;

    for my $turn (@$dropped_turns) {
        for my $msg (@$turn) {
            my $role = $msg->{role} // '';
            my $content = $msg->{content} // '';
            next unless length $content;
            next if $role eq 'tool';  # tool results are noise in a summary
            if ($role eq 'user') {
                next if _is_continuation_prompt($content, 1);
                next if length($content) < 30;  # too short to be substantive
                next if $user_count >= $max_user;
                push @substantive_user, _truncate($content, $max_user_chars);
                $user_count++;
            } elsif ($role eq 'assistant') {
                next if length($content) < 30;
                next if $assistant_count >= $max_asst;
                push @substantive_assistant, _truncate($content, $max_asst_chars);
                $assistant_count++;
            }
        }
        last if $user_count >= $max_user
                && $assistant_count >= $max_asst;
    }

    return '' unless @substantive_user || @substantive_assistant;

    my $out = '';
    $out .= "Earlier work in this session (compressed; anchor + recent turns above carry the active work):\n";
    if (@substantive_user) {
        $out .= "User: " . join(' | ', @substantive_user) . "\n";
    }
    if (@substantive_assistant) {
        $out .= "Assistant: " . join(' | ', @substantive_assistant) . "\n";
    }

    if (length($out) > $overall_cap) {
        $out = _truncate($out, $overall_cap);
        $out .= '...';
    }

    # Wrap in <thread_summary> tags so the fallback is a canonical
    # compaction artifact just like the YaRN-backed path.
    return "<thread_summary>\n" . $out . "\n</thread_summary>";
}

sub _truncate {
    my ($text, $max) = @_;
    return '' unless defined $text && length($text);
    return $text unless length($text) > $max;
    my $truncated = substr($text, 0, $max);
    $truncated =~ s/\s+\S*$//;
    return $truncated . '...';
}

=head2 _keywords

Extract lowercase keywords of length >= 4 from a text. Returns a
hashref (set) of keyword => 1.

=cut

sub _keywords {
    my ($text) = @_;
    $text //= '';
    my %set;
    while ($text =~ /\b([A-Za-z][A-Za-z0-9_]{3,})\b/g) {
        $set{lc $1} = 1;
    }
    # Also seed the keyword set with category words that appear in
    # the text. This is what rescues meta-relevant memories from the
    # lexical-only keyword overlap: if both the user input and the
    # memory mention "prompt", "context", "framework", etc., the
    # overlap count catches the topical relationship even when the
    # specific words differ.
    for my $word (@CATEGORY_WORDS) {
        my $lc = lc $word;
        next if $lc !~ /^[a-z]/;  # skip multi-word like "long-term memory"
        if (index(lc $text, $lc) >= 0) {
            $set{$lc} = 1;
        }
    }
    return \%set;
}

=head2 _keyword_overlap

Count keyword overlaps between two keyword sets. Returns integer count.

=cut

sub _keyword_overlap {
    my ($a, $b) = @_;
    return 0 unless $a && $b;
    my $count = 0;
    for my $k (keys %$a) {
        $count++ if $b->{$k};
    }
    return $count;
}

# ============================================================================
# Module return
# ============================================================================

1;

__END__

=head1 AUTHOR

Andrew Wyatt (Fewtarius)

=head1 LICENSE

GPL-3.0-only

=cut