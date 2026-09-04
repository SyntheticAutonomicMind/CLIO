package CLIO::Core::ContextBuilder;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use CLIO::Core::Logger qw(log_debug log_warning log_error);
use CLIO::Memory::TokenEstimator qw(estimate_messages_tokens);
use CLIO::Memory::LongTerm ();
# YaRN does not use Exporter; call its subs via fully-qualified name.
# Loading the module here ensures the symbol is defined before the
# _select_turns fallback tries to call CLIO::Memory::YaRN::
# recover_substantive_task - which previously hit "Undefined
# subroutine" because nothing in ContextBuilder loaded YaRN.
use CLIO::Memory::YaRN ();

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
    use CLIO::Core::MessageHistory qw(messages_to_prose messages_to_prose_dynamic);

    my $projection = CLIO::Core::ContextBuilder::build_projection(
        history       => $session->get_conversation_history(),
        user_input    => $user_input,
        active_task   => $active_task_text,       # scalar (optional)
        active_todos  => \@active_todos,          # arrayref (optional)
        ltm           => \@ltm_entries,           # arrayref of {confidence, content, type}
        unresolved    => \@unresolved_strings,    # arrayref (optional)
        budget_tokens => 8000,                    # soft budget for the history portion
    );

    # The projection's anchor + turns can be pushed directly into the
    # role-based messages array as individual messages. The dynamic
    # parts (active task, todos, LTM, environment, context files) get
    # rendered as a single trailing system message so the cache-stable
    # prefix (system_prompt + role-based history) stays unchanged
    # across turns while dynamic context refreshes.
    my $dynamic_usercontext = messages_to_prose_dynamic($projection);

=cut

our $VERSION = '1.0.0';

# Tunables (defaults align with scratch/optimize.md)
our $RELEVANCE_THRESHOLD = 5;
our $MAX_RELEVANT_MEMORIES = 5;
our $MIN_MEMORY_CONFIDENCE = 0.5;
our $RECENT_FULL_TURNS = 1;   # always include the latest N turns in full
our $RECENT_FULL_TURNS_IF_BUDGET = 2;  # include one extra if budget allows

# Session-length-aware scaling for the recent window. Long sessions
# benefit from a wider recent window (more cache churn per turn,
# but better trajectory recall) while short sessions are unchanged
# (preserve the current 1/2 default). Bands picked empirically from
# the 2024-message session (2b80d82f) where RECENT=1 leaves the
# model with 7% of history; RECENT=4 gives 25% before trim.
# Final word on what the model sees is the proactive trim
# (MessageValidator::_role_based_tail_walk), which respects the
# actual context window. These are *targets* the trim works back
# from, not guarantees.
our $RECENT_SCALING_BANDS = [
    # [max_total_turns, recent_count]
    [30,   1],   # short sessions: original behavior
    [100,  2],   # medium: still compact
    [300,  4],   # long: enough to span a few tasks
    [1e9,  8],   # very long: hard cap at 8 recent turns
];

our $DEFAULT_HISTORY_BUDGET_TOKENS = 8000;

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
- budget_tokens: Token budget for the projection's history portion (optional,
  defaults to C<$DEFAULT_HISTORY_BUDGET_TOKENS>).
- session: Session object (optional; used for anchor fallback via YaRN).

Returns a hashref:
    {
        turns             => [ ... ],  # selected full turns (newest 1-2)
        anchor            => { ... },  # original task turn (1 element) or undef
        compressed_tail   => "...",    # one combined thread_summary text, or ''
        userContext       => "<userContext>...</userContext>",
        relevant_memory   => [ ... ],  # arrayref of {confidence, content}
        active_task       => "...",    # for per-iteration LTM re-score
        user_input        => "...",    # for per-iteration LTM re-score
        token_estimate    => $int,
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
    my $budget_tokens = $args{budget_tokens} // $DEFAULT_HISTORY_BUDGET_TOKENS;
    my $session       = $args{session};

    # context_files: callers pass either an arrayref of file paths
    # (which we render here, see _render_user_context) or a
    # pre-rendered string block (context_files_block). The pre-rendered
    # form is used when the caller needs access to disk content (e.g.
    # /context add files), which _render_user_context does not have.
    my $context_files       = $args{context_files}       || [];
    my $context_files_block = $args{context_files_block} // '';

    my $turns = _split_into_turns($history);

    # Select anchor (first substantive user turn) and recent turns
    my ($anchor_turn, $recent_turns, $dropped_turns) =
        _select_turns($turns, $session, $history, $active_task);

    # Build the compressed tail if any turns were dropped
    my $compressed_tail = _build_compressed_tail($dropped_turns, $active_task);

    # Recent turns from _select_turns are already an arrayref of
    # role-based messages per turn (the shape produced by
    # _split_into_turns). The within-turn dedup pass
    # (collapse_repeated_tool_calls) was originally written for the
    # old {tools => [...]} turn shape and is a no-op for role-based
    # turns - dropped from the pipeline.
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
        # The first element of the chain is the anchor; the rest are
        # recent turns. If the anchor was collapsed into the
        # subsequent turn, we need to either drop the anchor (if its
        # tool call was already represented) or keep it. The current
        # implementation only ever drops the SECOND turn of a pair,
        # so the anchor stays in the chain.
        @deduped_recent = @$deduped_chain[1 .. $#$deduped_chain];
    } else {
        @deduped_recent = @$deduped_chain;
    }

    # Score LTM entries against the current request
    my $relevant = score_ltm($ltm, $user_input, $active_task, $unresolved);
    # Total entries passed to score_ltm (before relevance filtering).
    # Used by the prose renderer to surface a "N more available - call
    # memory_operations(search) to retrieve" hint when relevant entries
    # are filtered out. The model gets to know LTM exists and is
    # searchable even when nothing scored high enough.
    my $ltm_total_count = ref($ltm) eq 'ARRAY' ? scalar(@$ltm) : 0;

    # After the role-based history refactor, the structured userContext
    # is rendered by the prose renderer (messages_to_prose_dynamic)
    # using the projection's structured fields directly. We no longer
    # build an XML userContext string here. The userContext field
    # below is kept as an empty string for backwards compatibility
    # with tests that read it.
    my $user_context = '';

    # Estimate tokens (rough). Token accounting is approximate; the
    # exact budget pass happens in MessageValidator's
    # _role_based_tail_walk.
    my $anchor_list = ref($anchor_turn) eq 'ARRAY' ? $anchor_turn : [];
    my @all_messages;
    push @all_messages, @$anchor_list;
    push @all_messages, @deduped_recent;
    my $token_estimate = estimate_messages_tokens(\@all_messages) + int(length($user_context) / 4);

    # The compressed_tail is rendered by messages_to_xml when the
    # projection is passed in. Return it as a separate field so the
    # serializer can splice it in at the right position.
    #
    # Also return the structured fields (active_todos, unresolved,
    # environment) directly so non-XML serializers (prose renderer)
    # can use them without having to re-parse the userContext XML.
    return {
        turns               => \@deduped_recent,
        anchor              => $anchor_turn,
        compressed_tail     => $compressed_tail,
        userContext         => $user_context,
        relevant_memory     => $relevant,
        ltm_total_count      => $ltm_total_count,
        active_task         => $active_task,
        active_todos        => $active_todos,
        unresolved          => $unresolved,
        context_files       => $context_files,
        context_files_block => $context_files_block,
        environment         => _build_environment_hash(),
        # user_input is preserved on the projection so per-iteration
        # refresh in WorkflowOrchestrator can re-score LTM against
        # the ORIGINAL input. Re-scoring against the model's evolving
        # output would be unstable (each tool result shifts the
        # topic).
        user_input          => $user_input,
        token_estimate      => $token_estimate,
    };
}

=head2 _build_environment_hash

Internal: build the environment hashref consumed by non-XML
serializers (prose renderer). Returns:
    {
        working_directory => '/path/to/cwd',
        language          => 'English',
        datetime_iso      => '2026-09-01T13:51:42',
    }

=cut

sub _build_environment_hash {
    my $cwd = eval { require Cwd; Cwd::getcwd(); } || '';
    my @t = localtime(time);
    my $ts = sprintf("%04d-%02d-%02dT%02d:%02d:%02d",
        $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
    return {
        working_directory => $cwd,
        language          => _detect_language_name(),
        datetime_iso      => $ts,
    };
}

=head2 _detect_language_name

Detect the user's preferred language from environment variables
(LC_ALL, LANG, LC_MESSAGES, LANGUAGE). Returns the friendly
language name (e.g. 'English'). Defaults to 'en' if no locale
is set or the locale is unrecognized.

Returns:
- String with the friendly language name

=cut

sub _detect_language_name {
    my $locale = $ENV{LC_ALL} || $ENV{LANG} || $ENV{LC_MESSAGES} || $ENV{LANGUAGE} || '';
    $locale = (split /:/, $locale)[0] if $locale =~ /:/;
    my $code = lc($locale);
    $code =~ s/\.[^.]+$//;
    $code =~ s/_.*$//;
    $code =~ s/[^a-z]//g;
    $code ||= 'en';
    $code = 'en' if $code eq 'c' || $code eq 'posix';

    my %NAMES = (
        en => 'English',  zh => 'Chinese',  ja => 'Japanese',
        ko => 'Korean',   de => 'German',   fr => 'French',
        es => 'Spanish',  it => 'Italian',  pt => 'Portuguese',
        ru => 'Russian',  ar => 'Arabic',   hi => 'Hindi',
        nl => 'Dutch',   pl => 'Polish',   tr => 'Turkish',
        sv => 'Swedish',  da => 'Danish',   no => 'Norwegian',
    );
    return $NAMES{$code} || $code;
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

sub score_ltm {
    my ($ltm, $current_input, $active_task, $unresolved) = @_;
    $ltm ||= [];

    return [] unless @$ltm;

    my $input_keywords  = _keywords($current_input // '');
    my $task_keywords   = _keywords($active_task // '');
    my $unres_keywords  = _keywords(join(' ', @$unresolved));

    # Lazy sanitize: pre-existing LTM entries may contain
    # framework-narration words (memory_operations, prompt cache,
    # etc.) written before the sanitizer existed. Clean them on read
    # so the prose renderer never sees the framework smell.
    my $sanitizer = CLIO::Memory::LongTerm->new();

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
        $score += 2 * _keyword_overlap($task_keywords, $mem_keywords);
        $score += 2 * _keyword_overlap($unres_keywords, $mem_keywords);
        $score += 1 * $confidence;
        # Category boost: +2 if the user is doing framework work and
        # the memory is about framework work. This rescues
        # meta-relevant memories that would otherwise be filtered
        # out by pure lexical scoring.
        $score += 2 if $input_is_meta && _category_match($content);

        push @scored, {
            content    => $content,
            confidence => $confidence,
            type       => $entry->{type},
            score      => $score,
            _is_meta   => ($input_is_meta && _category_match($content)) ? 1 : 0,
        };
    }

    # Highest score first. Two threshold tiers:
    # - Regular memories: score >= RELEVANCE_THRESHOLD (5)
    # - Category-matched memories (input is framework work AND
    #   memory is about framework work): score >= 3, because the
    #   meta-relevance is signal enough on its own.
    @scored = sort { $b->{score} <=> $a->{score} } @scored;
    my @kept = grep {
        my $s = $_->{score};
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

When all three hold, the second turn&apos;s tool call is dropped (it is
already represented by the first turn&apos;s tool call with a bumped
repeats=N) and the user message of the second turn is marked with
a C<_continuation_user_msg> flag so the prose renderer can render it
as a short "(user: continue)" prefix instead of a full turn block.

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
    my ($text) = @_;
    return 0 unless defined $text;
    $text = '' . $text;
    return 0 if length($text) > 80;
    return 1 if grep { $text =~ $_ } @CONTINUATION_PHRASES;
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
# Note: tool_call_id is intentionally NOT part of the signature. The
# id is an opaque identifier assigned by the assistant each turn; it
# differs for two semantically-identical calls. The semantic identity
# is (name, args, result) - if those match, the calls are equivalent
# for the purpose of "did the model just retry the same call".
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
            # Mark the dropped turn's user message so the prose
            # renderer can show "(user: continue)" inline rather than
            # as a full turn block.
            for my $msg (@$turn) {
                if (ref($msg) eq 'HASH' && ($msg->{role} // '') eq 'user') {
                    $msg->{_continuation_user_msg} = 1;
                    last;
                }
            }
            next;  # don't emit the duplicate turn
        }
        push @out, $turn;
    }

    return \@out;
}

=head2 digest

Compute a short content digest for duplicate detection. Uses
SHA-256 truncated to 16 hex chars (64 bits) - collision-safe enough
for within-session dedup, cheap to serialize.

=cut

sub digest {
    my ($content) = @_;
    $content //= '';
    require Digest::SHA;
    return substr(Digest::SHA::sha256_hex($content), 0, 16);
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

=head2 _recent_count_for_turns

Map a session's total turn count to a target recent-window size.

Returns the number of recent turns to keep in the projection for a
session with $total_turns turns. The bands are configurable via
$RECENT_SCALING_BANDS; default bands (1/2/4/8) match what
scratch/optimize.md identified as the right tradeoff between
cache stability (smaller window) and trajectory recall (bigger
window).

A session with 5 turns gets 1 recent; 50 turns gets 2; 200 turns
gets 4; 1000 turns gets 8. The hard cap of 8 matches the anchor
cap of 8 - both are cache-stable prefix bounds, and keeping them
the same width means the cache invalidation surface is predictable.

=cut

sub _recent_count_for_turns {
    my ($total_turns) = @_;
    $total_turns = 0 unless defined $total_turns && $total_turns =~ /^\d+$/;
    for my $band (@$RECENT_SCALING_BANDS) {
        my ($max, $count) = @$band;
        return $count if $total_turns <= $max;
    }
    # Should be unreachable because the last band has max=1e9.
    return $RECENT_FULL_TURNS;
}

=head2 _select_turns

Pick the anchor turn (first substantive user message), the recent
turns (latest 1 or 2 full turns), and return the remaining turns as
dropped for compression.

Returns ($anchor_arrayref_or_undef, \@recent_turns, \@dropped_turns).
A "turn" here is the message arrayref produced by L<_split_into_turns>.

=cut

sub _select_turns {
    my ($turns, $session, $history, $active_task) = @_;

    # Compute the effective recent-window target from session length.
    # Short sessions keep the original 1/2 defaults; long sessions
    # scale up to 4 or 8 recent turns for better trajectory recall.
    # The proactive trim (MessageValidator) is the final word on
    # what fits the model's context window.
    my $total_turns = scalar(@$turns);
    my $recent_target = _recent_count_for_turns($total_turns);
    my $recent_if_budget = $recent_target + 1;

    # Anchor selection: first user message with >=50 chars content
    # (matches YaRN::find_substantive_task threshold). Fall back to
    # the first user message if none meets the threshold. Fall back
    # to YaRN's find_substantive_task if the source history has no
    # substantive user message.
    my $anchor_idx;
    for my $i (0 .. $#$turns) {
        my $turn = $turns->[$i];
        for my $msg (@$turn) {
            if (($msg->{role} // '') eq 'user') {
                my $content = $msg->{content} // '';
                if (length($content) >= 50) {
                    $anchor_idx = $i;
                    last;
                }
            }
        }
        last if defined $anchor_idx;
    }

    # If no turn had a substantive (>=50 char) user message, the
    # anchor would be a continuation prompt like "continue" or "go on".
    # That's not a useful task anchor. Recover the original task from
    # YaRN's durable thread (which is never trimmed by context trimming)
    # and synthesize a one-message anchor turn from it. If YaRN also
    # can't recover, fall back to the first user message we have -
    # even a short continuation prompt is better than no anchor.
    if (!defined $anchor_idx && $session) {
        my $recovered = CLIO::Memory::YaRN::recover_substantive_task($session);
        if (length $recovered) {
            my $sanitized = $recovered;
            if (eval { require CLIO::Util::TextSanitizer; 1 }) {
                $sanitized = CLIO::Util::TextSanitizer::sanitize_text($recovered, mode => 'model_safe');
                $sanitized //= $recovered;
            }
            push @$turns, [ { role => 'user', content => $sanitized } ];
            $anchor_idx = scalar(@$turns) - 1;
        }
    }

    # Last-resort anchor: pick the first user message we have, even if
    # it is a short continuation prompt. Without this, the projection
    # would have no anchor and the dynamic userContext would be the
    # only sense of "what are we doing" - bad when the model has lost
    # its place.
    if (!defined $anchor_idx) {
        for my $i (0 .. $#$turns) {
            my $turn = $turns->[$i];
            for my $msg (@$turn) {
                if (($msg->{role} // '') eq 'user') {
                    $anchor_idx = $i;
                    last;
                }
            }
            last if defined $anchor_idx;
        }
    }

    my $anchor = defined $anchor_idx ? [ @{$turns->[$anchor_idx]} ] : undef;

    # Cap the anchor turn size and preserve the trimmed portion in
    # the compressed_tail instead of silently dropping it (BUG #1
    # fix from QA review 2026-09-02).
    #
    # Threshold: cap at MAX_ANCHOR_MESSAGES messages. 8 is enough
    # to carry the original user + first assistant + first tool
    # call + first tool result + a few follow-up assistant turns.
    my $anchor_trimmed_tail;  # synthetic turn for compressed_tail
    my $MAX_ANCHOR_MESSAGES = 8;
    if (ref($anchor) eq 'ARRAY' && @$anchor > $MAX_ANCHOR_MESSAGES) {
        my @trimmed_anchor;
        for my $i (0 .. $#$anchor) {
            last if @trimmed_anchor >= $MAX_ANCHOR_MESSAGES;
            push @trimmed_anchor, $anchor->[$i];
        }
        # Capture the trimmed portion as a synthetic turn. We don't
        # push it onto @$turns (that would confuse the recent/dropped
        # index bookkeeping below); instead we append it to @dropped
        # directly after @dropped is assembled.
        $anchor_trimmed_tail = [@{$anchor}[$MAX_ANCHOR_MESSAGES .. $#$anchor]];

        my $orig_count = scalar @$anchor;
        $anchor = \@trimmed_anchor;
        log_debug('ContextBuilder',
            "Capped anchor turn: $orig_count -> " . scalar(@$anchor)
            . " messages (trimmed portion queued for compressed_tail)");
    }

    # Recent turns: latest $RECENT_FULL_TURNS turns, plus optionally one
    # extra if budget allows. We don't budget-check here - the caller
    # passes a soft budget, MessageValidator::_role_based_tail_walk is
    # the safety net for actual over-budget situations.
    my @recent = ();
    my $recent_count = $recent_target;
    for my $i (reverse 0 .. $#$turns) {
        next if defined $anchor_idx && $i == $anchor_idx;
        last if @recent >= $recent_count;
        unshift @recent, $turns->[$i];
    }

    # Optionally include the second-to-last turn if there is room.
    # Earlier versions took a $budget_tokens hint here but it was
    # never used (the budget check lives in MessageValidator's
    # _role_based_tail_walk). Drop the dead positional argument.
    if ($recent_count == $recent_target
        && @$turns > 1
        && @recent < $recent_if_budget) {
        # Pick the second-to-last turn that isn't anchor
        for my $i (reverse 0 .. $#$turns) {
            next if defined $anchor_idx && $i == $anchor_idx;
            next if grep { $_ == $turns->[$i] } @recent;
            unshift @recent, $turns->[$i];
            last;
        }
    }

    # Everything else is "dropped" for compression
    my @dropped;
    my %kept_idx;
    for my $t (@recent) {
        # Find the index of $t in @$turns so we can mark it kept.
        for my $i (0 .. $#$turns) {
            if ($turns->[$i] == $t) { $kept_idx{$i} = 1; last; }
        }
    }
    $kept_idx{$anchor_idx} = 1 if defined $anchor_idx;
    for my $i (0 .. $#$turns) {
        push @dropped, $turns->[$i] unless $kept_idx{$i};
    }
    # BUG #1 fix: append the anchor's trimmed portion (if any) to
    # the dropped list so _build_compressed_tail surfaces it in the
    # "Earlier work" section. Without this, the messages past the
    # anchor cap silently disappear - a 95-message anchor turn loses
    # messages 9..95 (the model's final summary on the original task).
    push @dropped, $anchor_trimmed_tail if $anchor_trimmed_tail;

    return ($anchor, \@recent, \@dropped);
}

=head2 _build_compressed_tail

Combine all dropped turns into one compressed summary string suitable
for the # Earlier work prose section. Uses YaRN::compress_messages
when available (the real compressor) with a template-based fallback
for the rare case where YaRN is unavailable or returns empty.

The compressor is the same one Session::State::trim_context uses on
hard trim, so the # Earlier work section now carries the same
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
    my ($dropped_turns, $active_task) = @_;

    return '' unless $dropped_turns && @$dropped_turns;

    # Pre-filter: drop the obvious continuation prompts ("continue",
    # "ok", "y", etc.) before handing to YaRN. YaRN doesn't filter
    # these by default, but the test_compressed_tail_filter test
    # expects the dropped-tail section to be free of pure-continuation
    # noise (long sessions used to render as "User: continue. |
    # continue. | continue. ..." which is useless to the model and
    # wastes budget).
    my @flat_msgs;
    for my $turn (@$dropped_turns) {
        for my $msg (@$turn) {
            next unless ref($msg) eq 'HASH';
            my $role    = $msg->{role}    // '';
            my $content = $msg->{content} // '';
            next unless length $content;
            next if $role eq 'user' && _is_continuation_text($content);
            push @flat_msgs, { %$msg };  # shallow copy so we don't mutate source
        }
    }

    # Try YaRN compression first.
    my $yarn_out = _yarn_compress_dropped(\@flat_msgs, $active_task);

    # Cap parameters. These bound the worst-case size of the
    # # Earlier work section regardless of how many turns were
    # dropped. The anchor + recent turns already carry the most
    # important content.
    my $MAX_USER_MESSAGES = 3;
    my $MAX_ASSISTANT_MESSAGES = 3;
    my $MAX_USER_CHARS = 120;     # per user message
    my $MAX_ASSISTANT_CHARS = 120; # per assistant message
    my $OVERALL_CAP = 900;        # hard cap on the whole section

    my $tail;
    if (defined $yarn_out && length $yarn_out) {
        # YaRN path: use the compressed output as-is (with a safety
        # cap so a session with hundreds of dropped turns doesn't
        # blow the dynamic UC budget).
        $tail = $yarn_out;
        if (length($tail) > $OVERALL_CAP) {
            $tail = _truncate($tail, $OVERALL_CAP);
            $tail .= '...';
        }
    } else {
        # Fallback: template-based joiner. Used when YaRN is
        # unavailable (it shouldn't be - the module is always
        # loaded) or returns empty (the pre-filter ate everything).
        $tail = _build_compressed_tail_template(
            $dropped_turns, $MAX_USER_MESSAGES, $MAX_ASSISTANT_MESSAGES,
            $MAX_USER_CHARS, $MAX_ASSISTANT_CHARS, $OVERALL_CAP,
        );
    }

    return $tail;
}

# YaRN-backed compression. Takes a flat message array (the same
# shape YaRN::compress_messages expects) and an optional task hint,
# returns a thread_summary string with the XML wrapper tags stripped,
# or undef if the result is empty / YaRN is unavailable.
sub _yarn_compress_dropped {
    my ($flat_msgs, $active_task) = @_;

    return undef unless $flat_msgs && @$flat_msgs;

    # YaRN expects a class instance or the package name. Use the
    # package method form to avoid storing an instance on $self.
    my $yarn;
    eval {
        require CLIO::Memory::YaRN;
        $yarn = CLIO::Memory::YaRN->new();
    };
    return undef if $@ || !$yarn;

    my $compressed = eval {
        $yarn->compress_messages($flat_msgs, original_task => ($active_task // ''));
    };
    return undef if $@ || !$compressed || !ref($compressed);

    my $content = $compressed->{content} // '';
    return undef unless length $content;

    # Strip <thread_summary> wrapper tags and trim.
    $content =~ s{</?thread_summary>}{}g;
    $content =~ s/^\s+//;
    $content =~ s/\s+$//;
    return undef unless length $content;

    return "Earlier work in this session (YaRN-compressed; anchor + recent turns above carry the active work):\n$content";
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
                next if _is_continuation_text($content);
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
    return $out;
}

# Lightweight continuation detector (no overhead of the full
# _is_continuation_prompt from collapse_repeated_tool_calls_across_turns
# which assumes a pure tool turn - we just need to filter obvious
# "continue" / "ok" / "go on" prompts from the dropped-tail).
sub _is_continuation_text {
    my ($text) = @_;
    return 0 unless defined $text && length $text;
    return 0 if length($text) > 80;
    return 1 if $text =~ /\A(continue|go on|okay|ok|yes|y|proceed|keep going|please continue|go ahead|same as before|again|and\?+)\.?\z/i;
    return 0;
}

sub _truncate {
    my ($text, $max) = @_;
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