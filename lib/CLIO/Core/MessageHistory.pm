package CLIO::Core::MessageHistory;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(
    messages_to_prose_dynamic
);

use CLIO::Core::Logger qw(log_debug log_warning log_error);

=head1 NAME

CLIO::Core::MessageHistory - Prose renderer for conversation history

=head1 DESCRIPTION

Renders a C<ContextProjection> (built by L<CLIO::Core::ContextBuilder>)
as markdown sections suitable for inclusion as system message content.
The history is now pushed directly into the @messages array as
role-based messages (user, assistant, tool) rather than being
collapsed into a single XML block. The dynamic userContext (active task, active todos, environment,
context files) is rendered separately by L</messages_to_prose_dynamic>
and pushed as one system message after the history, sitting at the
recency anchor. The unresolved state and relevant memory fields are
computed by ContextBuilder (for LTM scoring) but are NOT rendered into
the prose -- see the metadata-leak fix in C<messages_to_prose_dynamic>.
LTM remains accessible on demand via memory_operations(search).

The renderer produces markdown with the dynamic sections only. The
stable parts (anchor + recent turns) are pushed by WorkflowOrchestrator
as role-based messages, not as prose:

    # Earlier work      (compressed summary of dropped turns, dynamic)
    # Active todos      (dynamic)
    [CONTEXT FILES]     (dynamic - pre-rendered block from caller)

Cache stability (Anthropic): the projection's anchor + recent
turns are pushed as role-based messages. The dynamic userContext
is prepended to the user message that follows them. Anthropic uses
top-level automatic `cache_control: ephemeral` (see
Providers/Anthropic.pm) which caches the system_prompt + tools +
conversation history prefix without per-message markers. The dynamic
userContext sitting in the user message means it is NOT part of any
cache segment — it churns per-turn (todo mutations, LTM rescore,
compressed_tail changes) and the model sees it as conversation
context, not instructions.

Public API:
- L</messages_to_prose_dynamic> - the only renderer used in
  production. Returns the dynamic prose block.

=cut

=head2 messages_to_prose_dynamic

Render the dynamic portions of a projection as natural prose:
active task (as plain text, no label), active todos as a checklist,
environment (working directory first), and context files. Relevant
memory (LTM) is not rendered here; it is available on demand via
memory_operations(search).

The compressed tail (YaRN summary of dropped turns) is rendered
as-is - it already contains its own section labels (Commits, Files,
etc.) from YaRN.

Prose rather than XML keeps the dynamic block ~27% smaller on an
8-turn fragment (656 vs 895 tokens) and avoids XML parse failures
on first-turn sessions.

Returns content that churns between turns (todo mutations, LTM
rescore). WorkflowOrchestrator prepends this to the user message, so
its churn does not invalidate the cache-stable prefix. Environment info
(working directory, language, date/time) is handled by
PromptBuilder::get_user_context() — not rendered here — to avoid
date/time duplication across the system prompt and the dynamic block.

The compressed_tail, active_todos, context_files_block, and
relevant_memory fields are rendered as natural prose (no XML tags, no
# headers). relevant_memory entries are scored per-request by
ContextBuilder::score_ltm and appear with tier badges ([TRUSTED] or
[UNVERIFIED]) so the model can calibrate trust before acting on
procedural suggestions.

Arguments:
- $projection: Hashref from L<CLIO::Core::ContextBuilder/build_projection>.
  Fields consumed:
    - compressed_tail   : string (YaRN-compressed summary of dropped turns) or ''
    - active_todos      : arrayref of {id, status, content} (optional)
    - context_files_block : string (optional, pre-rendered context files block)
    - relevant_memory     : arrayref of {content, confidence, type, score,
                          tier, corroboration_count} (optional)

Returns:
- Prose string suitable for use as a single system message content

=cut

sub messages_to_prose_dynamic {
    my ($projection) = @_;
    $projection = {} unless ref($projection) eq 'HASH';

    # Cap component sizes so the dynamic userContext cannot balloon
    # the prompt budget on iteration 1 (where no proactive trim runs).
    my $MAX_TODOS = 10;
    my $MAX_TODO_CHARS = 200;

    # Lazily load ContextBuilder for the shared _truncate helper.
    require CLIO::Core::ContextBuilder;

    my $out = '';

    # NOTE: Environment (working directory, language, date/time) is
    # rendered by PromptBuilder::get_user_context() and prepended to
    # the user message — NOT rendered here. This is the single source
    # for environment info, keeping it out of the noise-stripped
    # compressed tail.

    # Active task is not rendered here. It is prepended to the user
    # input by WorkflowOrchestrator via PromptBuilder::get_user_context().
    # Re-rendering it in the UC would cause the model to refocus on
    # the original request every turn (context bug #1).

    # Active todos: checklist with status.
    if (my $todos = $projection->{active_todos}) {
        my @rendered;
        my $todo_count = 0;
        for my $todo (@$todos) {
            next unless ref($todo) eq 'HASH';
            last if $todo_count >= $MAX_TODOS;
            my $status = $todo->{status} // 'pending';
            my $content = $todo->{content} // '';
            $content = CLIO::Core::ContextBuilder::_truncate($content, $MAX_TODO_CHARS);
            push @rendered, "- [$status] $content";
            $todo_count++;
        }
        if (@rendered) {
            $out .= "Active todos:\n" . join("\n", @rendered) . "\n\n";
            if (scalar(@$todos) > $todo_count) {
                $out .= sprintf("...and %d more (use todo_operations to read full list)\n\n",
                    scalar(@$todos) - $todo_count);
            }
        }
    }

    # Compressed tail: the YaRN-compressed summary of dropped turns.
    # Only present when budget pressure caused older turns to be
    # collapsed. Rendered as-is (YaRN output has its own section
    # labels). No framing narration.
    if (my $tail = $projection->{compressed_tail}) {
        $out .= $tail . "\n\n";
    }

    # Context files: pre-rendered block of file contents added via
    # /context add. Placed last so its content churn (file contents
    # changing) does not invalidate the cache-stable blocks above.
    if (my $cf_block = $projection->{context_files_block}) {
        if (length $cf_block) {
            $out .= $cf_block;
            $out .= "\n" unless $cf_block =~ /\n\z/;
        }
    }

    # Relevant memory: per-request LTM entries scored by
    # ContextBuilder::score_ltm against the current input, active task,
    # and unresolved state. These are relevance-filtered (not a blind
    # dump), so stale memories from unrelated work are unlikely to
    # match. Tier badges ([TRUSTED] / [UNVERIFIED]) let the model
    # calibrate trust before acting on procedural suggestions.
    #
    # Sanitized lazily: pre-existing entries may contain
    # framework-narration words written before the sanitizer existed.
    # For pattern/solution entries we preserve tool/function names
    # (drop-only sanitize); for other types we run the full sanitizer.
    if (my $mems = $projection->{relevant_memory}) {
        require CLIO::Memory::LongTerm;
        # Reuse the same lazy sanitizer pattern as score_ltm: create
        # a throwaway LongTerm object for sanitize_narration* calls,
        # which are stateless (package-level @SANITIZE_* data).
        my $sanitizer = CLIO::Memory::LongTerm->new();
        require CLIO::Core::ContextBuilder;
        my @rendered;
        my $rendered_count = 0;
        my $MAX_MEMORIES = 5;
        my $MAX_MEM_CHARS = 500;
        for my $mem (@$mems) {
            next unless ref($mem) eq 'HASH';
            last if $rendered_count >= $MAX_MEMORIES;
            my $raw     = $mem->{content} // '';
            my $type    = $mem->{type} // '';
            my $tier    = $mem->{tier} // 'unverified';
            my $conf    = $mem->{confidence} // 0.5;

            if ($type eq 'pattern' || $type eq 'solution') {
                $raw = $sanitizer->sanitize_narration_drop_only($raw);
            } else {
                $raw = $sanitizer->sanitize_narration($raw);
            }
            next unless length $raw;
            $raw = CLIO::Core::ContextBuilder::_truncate($raw, $MAX_MEM_CHARS);

            my $badge = $tier eq 'trusted' ? '[TRUSTED]' : '[UNVERIFIED]';
            push @rendered, "- ${badge} $raw";
            $rendered_count++;
        }
        if (@rendered) {
            $out .= "Relevant context from previous sessions:\n"
                 . join("\n", @rendered) . "\n\n";
        }
    }

    return $out;
}

1;  # MANDATORY: End every .pm file with 1;
