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
collapsed into a single XML block. The dynamic userContext (active
task, active todos, unresolved state, relevant memory, environment,
context files) is rendered separately by L</messages_to_prose_dynamic>
and pushed as one system message after the history, sitting at the
recency anchor.

The renderer produces markdown with the dynamic sections only. The
stable parts (anchor + recent turns) are pushed by WorkflowOrchestrator
as role-based messages, not as prose:

    # Earlier work      (compressed summary of dropped turns, dynamic)
    # Active task       (dynamic)
    # Active todos      (dynamic)
    # Unresolved state  (dynamic)
    # Relevant memory   (dynamic)
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

Render only the dynamic portions of a projection: # Earlier work
(compressed tail), # Active task, # Active todos, # Unresolved state,
# Relevant memory, # Environment, and the [CONTEXT FILES] block.
Returns content that churns between turns (datetime_iso, todo
mutations, LTM rescore, environment changes). WorkflowOrchestrator
uses this as a single system message that sits AFTER the
role-based history in the messages array, so its churn does not
invalidate the cache-stable prefix.

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
    #
    # Tunables chosen so the model still sees enough context to keep
    # its place but the worst-case dynamic UC stays bounded:
    #   - 10 todos x 200 chars   = 2K chars (~500 tokens)
    #   - 5 LTM x 500 chars each = 2.5K chars (~625 tokens)
    #   - 5 unresolved x 200 chars = 1K chars (~250 tokens)
    # All caps are inclusive - the Nth entry IS rendered, the
    # (N+1)th is dropped. The "and N more" hint preserves awareness
    # of items beyond the cap.
    my $MAX_TODOS = 10;
    my $MAX_TODO_CHARS = 200;
    my $MAX_LTM_ENTRIES = 5;       # also capped upstream by MAX_RELEVANT_MEMORIES
    my $MAX_LTM_CHARS = 500;
    my $MAX_UNRESOLVED = 5;        # also capped upstream at 10
    my $MAX_UNRESOLVED_CHARS = 200;

    my $out = '';

    # Compressed tail: the YaRN-compressed summary of dropped turns.
    # Only present when budget pressure caused older turns to be
    # collapsed. Considered dynamic for cache purposes because it
    # changes whenever budget pressure triggers new compression.
    if (my $tail = $projection->{compressed_tail}) {
        $out .= "# Earlier work\n" . $tail . "\n\n";
    }

    # Active task: from session_goals (the first substantive user
    # message is already shown above under # Task; this adds the
    # active session goal description if different).
    if (my $task = $projection->{active_task}) {
        $out .= "# Active task\n" . $task . "\n\n";
    }

    # Active todos: structured checklist with status.
    if (my $todos = $projection->{active_todos}) {
        my @rendered;
        my $todo_count = 0;
        for my $todo (@$todos) {
            next unless ref($todo) eq 'HASH';
            last if $todo_count >= $MAX_TODOS;
            my $status = $todo->{status} // 'pending';
            my $content = $todo->{content} // '';
            $content = _truncate_dynamic_uc($content, $MAX_TODO_CHARS);
            # Drop the internal todo id from the prose - it is
            # framework bookkeeping for the todo_operations tool,
            # not something the model needs to read or remember.
            # The model only needs to see status + content.
            push @rendered, "- [$status] $content";
            $todo_count++;
        }
        if (@rendered) {
            $out .= "# Active todos\n" . join("\n", @rendered) . "\n\n";
            if (scalar(@$todos) > $todo_count) {
                $out .= sprintf("...and %d more (use todo_operations to read full list)\n\n",
                    scalar(@$todos) - $todo_count);
            }
        }
    }

    # Unresolved state: failures, blocked todos, test failures.
    if (my $unresolved = $projection->{unresolved}) {
        my @rendered;
        my $unres_count = 0;
        for my $item (@$unresolved) {
            next unless defined $item && length $item;
            last if $unres_count >= $MAX_UNRESOLVED;
            push @rendered, "- " . _truncate_dynamic_uc($item, $MAX_UNRESOLVED_CHARS);
            $unres_count++;
        }
        if (@rendered) {
            $out .= "# Unresolved state\n" . join("\n", @rendered) . "\n\n";
        }
    }

    # Relevant memory: top-scored LTM entries with confidence in parens.
    # When LTMs exist but none passed the relevance threshold, render
    # an explicit "no auto-surfaced memories" hint + the on-demand
    # search affordance so the model knows it can still query.
    my $relevant = $projection->{relevant_memory};
    my $ltm_total = $projection->{ltm_total_count};
    if ($relevant && @$relevant) {
        my @rendered;
        my $mem_count = 0;
        for my $mem (@$relevant) {
            last if $mem_count >= $MAX_LTM_ENTRIES;
            my $conf = $mem->{confidence} // 0;
            my $content = $mem->{content} // '';
            $content = _truncate_dynamic_uc($content, $MAX_LTM_CHARS);
            push @rendered, sprintf("- (%.2f) %s", $conf, $content);
            $mem_count++;
        }
        $out .= "# Relevant memory\n" . join("\n", @rendered) . "\n";
        # On-demand search affordance. The literal tool name is hard-
        # coded here (NOT run through sanitize_narration) so the model
        # sees the real tool name and can use it. Uses [keyword]
        # placeholder instead of <keyword> so the prose doesn't
        # contain XML-like delimiters that the prose-vs-XML assertions
        # confuse with real XML.
        if (defined $ltm_total && $ltm_total > $mem_count) {
            $out .= sprintf(
                "(%d more memories available - call memory_operations(operation: \"search\", query: \"[keyword]\") to retrieve)\n\n",
                $ltm_total - $mem_count);
        } else {
            $out .= "\n";
        }
    } elsif (defined $ltm_total && $ltm_total > 0) {
        # No memories met the threshold but LTM is non-empty. Tell the
        # model how to query on demand so it doesn't assume LTM is empty.
        $out .= "# Relevant memory\n";
        $out .= sprintf("(no memories met the relevance threshold; %d available - call memory_operations(operation: \"search\", query: \"[keyword]\") to retrieve)\n\n",
            $ltm_total);
    }

    # Environment: working directory, language, date/time.
    # The timestamp moves every minute; this section is NOT part of
    # the cache-stable prefix. It sits at the end so its churn doesn't
    # invalidate earlier blocks.
    if (my $env = $projection->{environment}) {
        if (ref($env) eq 'HASH' && %$env) {
            $out .= "# Environment\n";
            $out .= "Working directory: " . ($env->{working_directory} // 'unknown') . "\n";
            $out .= "Language: " . ($env->{language} // 'English') . "\n";
            $out .= "Date: " . ($env->{datetime_iso} // scalar(localtime)) . "\n\n";
        }
    }

    # Context files: pre-rendered block of file contents added via
    # /context add. The caller (WorkflowOrchestrator) renders the
    # block once per turn via _render_context_files_for_user_context
    # and passes it through the projection as context_files_block.
    # Placed after Environment so its content churn (file contents
    # changing) does not invalidate the cache-stable prefix blocks
    # above.
    if (my $cf_block = $projection->{context_files_block}) {
        if (length $cf_block) {
            $out .= $cf_block;
            $out .= "\n" unless $cf_block =~ /\n\z/;
        }
    }

    return $out;
}

=head2 _render_prose_turn_messages

Render a single turn's worth of messages as prose. A turn is an
arrayref of role-based messages starting with a user message.

Tool calls become a delimited block:

    Tool call: <name> (called <K> times, identical args and results)
      Args: <json>
      Result: <text>

When the projection carries collapse metadata (a C<_repeats> field on
the tool result), the count is rendered in the prose header.

=cut

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
    # Strip the trailing partial word so the model doesn't see a
    # half-word at the cut point (which it would try to "fix").
    $truncated =~ s/\s+\S*$//;
    return $truncated . '...';
}

sub _render_prose_turn_messages {
    # DELETED in this commit. The role-based history refactor
    # pushed anchor + recent turns as role-based messages instead of
    # as prose, so this renderer has no callers. If you need to
    # inspect the rendered form of a role-based turn for debugging,
    # use WorkflowOrchestrator's actual message array (see
    # _build_turn_context) rather than re-deriving it from scratch.
    return '';
}

sub _truncate_prose {
    # DELETED in this commit alongside _render_prose_turn_messages.
    # No callers remain.
    my ($text, $max) = @_;
    return '' unless defined $text;
    return $text unless length($text) > $max;
    my $truncated = substr($text, 0, $max);
    $truncated =~ s/\s+\S*$//;
    return $truncated . '...';
}

1;  # MANDATORY: End every .pm file with 1;
