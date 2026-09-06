package CLIO::Core::MessageHistory;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;

use Exporter 'import';
our @EXPORT_OK = qw(
    messages_to_prose
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
the prose — see the metadata-leak fix in C<messages_to_prose_dynamic>.

The renderer produces markdown with the dynamic sections only. The
stable parts (anchor + recent turns) are pushed by WorkflowOrchestrator
as role-based messages, not as prose:

    # Earlier work      (compressed summary of dropped turns, dynamic)
    # Active task       (dynamic, no label scaffolding)
    # Active todos      (dynamic)
    # Environment       (dynamic - working dir, language, date/time)
    [CONTEXT FILES]     (dynamic - pre-rendered block from caller)

Cache stability (Anthropic): the projection's anchor + recent
turns are pushed as role-based messages. The dynamic userContext
sits AFTER them as a separate system message. Anthropic's
`cache_control: ephemeral` is only set on the system_prompt and
the last tool (see Providers/Anthropic.pm), not on the dynamic
userContext. This means for Anthropic the cache segment is:
  segment1 = system_prompt + dynamic_userContext (concatenated by
              `_separate_system_prompt`)
  segment2 = messages[...] (role-based history + user_input + ...)
A change to the dynamic userContext (datetime_iso, todo mutations,
LTM rescore) invalidates segment1 in the role-based format - same
behavior as the previous XML format (where segment1 was
system_prompt + messageHistory_XML). The role-based refactor does
NOT improve Anthropic cache stability vs the XML format; it only
moves the dynamic content out of the message history so it can be
re-rendered per-iteration without rebuilding the history.
For providers with per-message cache_control (or auto-detected
segment boundaries), the role-based format may give better cache
behavior because the system_prompt and dynamic_userContext sit at
distinct positions and the dynamic one can be re-rendered without
re-emitting the system_prompt. This is theoretical and not
verified end-to-end.

Public API:
- L</messages_to_prose_dynamic> - the only renderer used in
  production. Returns the dynamic prose block.
- L</messages_to_prose> - alias for messages_to_prose_dynamic,
  kept for tests and debug inspection.

The earlier `messages_to_prose_stable` renderer and the
`_render_prose_turn_messages` helper were deleted in this commit -
they're dead code in the role-based history world. The "stable"
portion (anchor + recent turns) is now delivered as role-based
messages, not as prose.

=head1 WHY THIS EXISTS

Before the role-based history refactor, history was collapsed into
a single XML system message (C<<messageHistory>...</messageHistory>>)
that mixed stable and dynamic content. Trimming that block required
a custom XML parser (trim_xml_history, since deleted), and the
structure was brittle: empty-body blocks (first turn with no
turns but a rich userContext) tripped the closing-tag regex
check, producing a "cannot parse messageHistory block" WARN.

By pushing history as role-based messages and isolating dynamic
context in a separate system message, we eliminate the XML parser
entirely. Context trim goes back to the role-based tail walk in
L<CLIO::Core::API::MessageValidator>, which is the same path that
existed before the XML experiment was introduced.

=cut

=head2 messages_to_prose

Serialize a ContextBuilder projection (and its source history) into a
single prose string suitable for inclusion as one system message content.

This is the active history renderer. It consumes the projection
hashref (from L<CLIO::Core::ContextBuilder/build_projection>) and
renders the content as plain markdown. After the role-based history
refactor the rebuild path pushes the projection's anchor + recent
turns directly as role-based messages; this renderer is used only
for the dynamic userContext system message that follows them.

Why prose, not XML:

=over

=item *

Smaller prompts. The XML serialization adds attribute overhead (state=,
repeats=, confidence=, timestamp=) that the model does not need.
Empirical comparison on an 8-turn fragment with 5 tool calls:
the XML form was 895 prompt tokens vs. 656 prompt tokens for prose
(27% smaller). On long sessions the gap is similar; the absolute
token savings dominate the relative percentage because tool result bodies
are identical.

=item *

Per-position cache stability (theoretical). The XML prefix mutates
per-turn (turn index, repeats, digest, confidence values) - same
content but different attributes invalidates cache hits. The
prose prefix is content-based: as long as the task anchor and
compressed summary are byte-identical, the underlying content
holds. Note: Anthropic's cache_control is set on system_prompt
and last tool only, not on the dynamic userContext. So changes to
datetime_iso / todos / LTM invalidate the system_prompt cache
segment in BOTH XML and prose formats - the prose format is not
more cache-stable than XML for Anthropic. The advantage is mainly
token efficiency and easier rendering.

=item *

Easier to read. The model is a language model; it reads prose natively
without having to parse tag grammar.

=back

Arguments:
- $projection: Hashref from L<CLIO::Core::ContextBuilder/build_projection>.
  Required fields consumed:
    - anchor          : arrayref of messages (the original-task turn) or undef
    - turns           : arrayref of arrayrefs (recent complete turns)
    - compressed_tail : string (YaRN-compressed summary of dropped turns)
    - relevant_memory : arrayref of {confidence, content} (optional)
    - active_task     : string (optional, from the userContext block)
    - active_todos    : arrayref of {id, status, content} (optional)
    - unresolved      : arrayref of strings (optional)
    - environment     : hashref with working_directory, language, datetime_iso (optional)
- %opts: Options hash
  - debug => 0|1

Returns:
- Prose string suitable for use as a single system message content

=cut

sub messages_to_prose {
    # Convenience alias for messages_to_prose_dynamic. The "stable"
    # prose sections were deleted along with _render_prose_turn_messages
    # - the cache-stable prefix (anchor + recent turns) is now pushed
    # by WorkflowOrchestrator as role-based messages, not as prose.
    # This wrapper exists so tests and debug tools can keep using
    # messages_to_prose() to render the dynamic userContext.
    my ($projection, %opts) = @_;
    return messages_to_prose_dynamic($projection, %opts);
}

=head2 messages_to_prose_dynamic

Render only the dynamic portions of a projection as natural prose:
active task (as plain text, no label), active todos as a checklist,
environment (working directory first), and context files.

Removed in the metadata-leak fix: the C<Unresolved:> section
(recycled tool errors) and the C<Relevant memory:> section (LTM
entries) are no longer rendered. LTM relevance scoring still runs
in ContextBuilder but these sections are not injected into the prose.

The compressed tail (YaRN summary of dropped turns) is rendered as-is
— it already contains its own section labels (Commits, Files, etc.)
from YaRN.

Returns content that churns between turns (datetime_iso, todo
mutations, environment changes). WorkflowOrchestrator uses this as a
single system message that sits AFTER the role-based history in the
messages array, so its churn does not invalidate the cache-stable
prefix.

Arguments:
- $projection: Hashref from L<CLIO::Core::ContextBuilder/build_projection>

Returns:
- Prose string containing only the dynamic sections

=cut

sub messages_to_prose_dynamic {
    my ($projection) = @_;
    $projection = {} unless ref($projection) eq 'HASH';

    # SMELL #5 fix (QA review 2026-09-02): cap component sizes so the
    # dynamic userContext cannot balloon the prompt budget on
    # iteration 1 (where no proactive trim runs). 200 todos x 500
    # chars used to produce ~22K tokens of dynamic UC content.
    my $MAX_TODOS = 10;
    my $MAX_TODO_CHARS = 200;

    my $out = '';

    # Lead with operationally-critical fields (working directory first).
    if (my $env = $projection->{environment}) {
        if (ref($env) eq 'HASH' && %$env) {
            $out .= "Working directory: " . ($env->{working_directory} // 'unknown') . "\n";
            $out .= "Language: " . ($env->{language} // 'English') . "\n";
            $out .= "Date: " . ($env->{datetime_iso} // scalar(localtime)) . "\n\n";
        }
    }

    # Active task as work product - emit as plain text without
    # the "Active task:" label scaffolding that tells the model
    # this is framework-managed metadata. The task is already in
    # the user's message; this is a secondary reminder.
    if (my $task = $projection->{active_task}) {
        $out .= _truncate_dynamic_uc($task, 300) . "\n\n";
    }

    # Active todos: checklist with status.
    if (my $todos = $projection->{active_todos}) {
        my @rendered;
        my $todo_count = 0;
        for my $todo (@$todos) {
            next unless ref($todo) eq 'HASH';
            last if $todo_count >= $MAX_TODOS;
            my $status = $todo->{status} // 'pending';
            my $content = $todo->{content} // '';
            $content = _truncate_dynamic_uc($content, $MAX_TODO_CHARS);
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

    return $out;
}

=head2 _truncate_dynamic_uc

Truncate text for inclusion in the dynamic userContext (SMELL #5
budget cap, QA review 2026-09-02). Strips trailing partial word
to avoid rendering garbage, and adds a clear "..." marker so the
model knows the entry was truncated.

=cut

sub _truncate_dynamic_uc {
    my ($text, $max) = @_;
    return '' unless defined $text;
    return $text unless length($text) > $max;
    my $truncated = substr($text, 0, $max);
    # Strip the trailing partial word so the model does not see a
    # half-word at the cut point (which it would try to fix).
    $truncated =~ s/\s+\S*$//;
    return $truncated . '...';
}

1;  # MANDATORY: End every .pm file with 1;
