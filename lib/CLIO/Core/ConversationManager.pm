package CLIO::Core::ConversationManager;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use Carp qw(croak);

use CLIO::Core::Logger qw(log_error log_warning log_debug);
use CLIO::Util::JSON qw(decode_json);
use CLIO::Memory::TokenEstimator;
use Digest::MD5 qw(md5_hex);

use Exporter 'import';
our @EXPORT_OK = qw(
    load_conversation_history
    strip_messages_noise
    _strip_message_noise
    enforce_message_alternation
    filter_continuation_prompts
    inject_context_files
    generate_tool_call_id
    repair_tool_call_json
);

=head1 NAME

CLIO::Core::ConversationManager - Conversation history management and validation

=head1 DESCRIPTION

Manages conversation history for the API workflow loop. Handles loading,
validating, and enforcing message format requirements for different AI
providers.

History is not trimmed here. The single budget authority is
L<CLIO::Core::API::MessageValidator/validate_and_truncate>, which runs
before every API call; this module provides the noise stripping and
format repairs that feed it.

Extracted from WorkflowOrchestrator to reduce module size and improve
separation of concerns. Uses functional style (exported functions).

=head1 SYNOPSIS

    use CLIO::Core::ConversationManager qw(
        load_conversation_history
        enforce_message_alternation
    );

    my $history = load_conversation_history($session, debug => 1);
    my $alternated = enforce_message_alternation($messages, $provider, debug => 1);

=cut

=head2 _coerce_ref_content_to_string (Internal)

Convert a hash/array ref to a string marker. Used as a defensive last-mile
coercion before sending messages to the API. The session loader is the
primary defense (State::load migration), but if a hash-ref content leaks
through anyway (corrupted on-disk, manual edit, different code path) we
still need to produce a string so strict-schema providers (e.g. NVIDIA NIM)
don't reject the message with "data did not match any variant of untagged
enum ChatCompletionRequestUserMessageContent".

Arguments:
    $content - hashref, arrayref, or other ref

Returns:
    String marker. Format: "[CORRUPTED INPUT: TYPE type='X' - repaired at JIT]"

=cut

sub _coerce_ref_content_to_string {
    my ($content) = @_;
    my $ref_type = ref($content);
    return '' unless $ref_type;
    
    # Preserve legitimate multimodal content (arrayref of content parts)
    # Each part should be a hash with 'type' key (text or image_url)
    if ($ref_type eq 'ARRAY') {
        my $valid_multimodal = 1;
        for my $part (@$content) {
            if (!ref($part) || ref($part) ne 'HASH' || !exists $part->{type}) {
                $valid_multimodal = 0;
                last;
            }
            # Valid types: text, image_url (and maybe others in future)
            if ($part->{type} ne 'text' && $part->{type} ne 'image_url') {
                $valid_multimodal = 0;
                last;
            }
        }
        return $content if $valid_multimodal;
    }
    
    my $inner = '';
    if ($ref_type eq 'HASH' && defined $content->{type}) {
        $inner = " type='$content->{type}'";
    }
    return "[CORRUPTED INPUT: " . $ref_type . $inner
        . ' - repaired at JIT]';
}

=head2 load_conversation_history

Load conversation history from session object, validating message structure
and ensuring tool call/result correlation integrity.

Handles:
- Hash-based and object-based session interfaces
- Filtering system messages (fresh system prompt built each request)
- Validating tool message tool_call_id presence
- Preserving tool_calls on assistant messages for API correlation
- Removing orphaned tool_calls (missing results) and tool_results (missing calls)
- Defensive coercion of hash/array ref content to a string marker (belt-and-
  suspenders against corruption like ReadLine control-signal leaks)

Arguments:
- $session: Session object (may be undef)
- %opts: Options hash
  - debug => 0|1 (enable debug logging)

Returns:
- Arrayref of validated message objects (may be empty)

=cut

sub load_conversation_history {
    my ($session, %opts) = @_;
    my $debug = $opts{debug} // 0;

    return [] unless $session;

    # Try to get conversation history from session
    my $history = [];

    if ($session && ref($session) eq 'HASH') {
        if ($session->{conversation_history} &&
            ref($session->{conversation_history}) eq 'ARRAY') {
            $history = $session->{conversation_history};
        }
    } elsif ($session && $session->can('get_conversation_history')) {
        $history = $session->get_conversation_history() || [];
    }

    log_debug('ConversationManager', "Raw history from session has " . scalar(@$history) . " messages");

    # DEBUG: Dump first assistant message (when debug enabled)
    if ($debug) {
        for my $i (0 .. $#{$history}) {
            my $msg = $history->[$i];
            if ($msg->{role} eq 'assistant') {
                require Data::Dumper;
                log_debug('ConversationManager', "First assistant message structure:");
                log_debug('ConversationManager', Data::Dumper::Dumper($msg));
                last;
            }
        }
    }

    log_debug('ConversationManager', "Loaded " . scalar(@$history) . " messages from session");

    # Validate and filter messages
    # Skip system messages from history - we always build fresh with dynamic tools
    my @valid_messages = ();

    log_debug('ConversationManager', "Processing " . scalar(@$history) . " messages");

    for my $msg (@$history) {
        next unless $msg && ref($msg) eq 'HASH';
        next unless $msg->{role};

        # DEFENSIVE: State::load should have coerced ref content already, but
        # belt-and-suspenders: if a hash/array leaked through anyway (session
        # opened via different code path, or manually edited), coerce it to a
        # string marker so strict-schema providers (e.g. NVIDIA NIM) accept it.
        if (ref($msg->{content}) ne '') {
            $msg->{content} = _coerce_ref_content_to_string($msg->{content});
            log_debug('ConversationManager',
                "Coerced ref content to string at JIT time - State::load migration may be stale");
        }

        if ($debug) {
            my $has_tool_calls = exists $msg->{tool_calls} ? 'YES' : 'NO';
            my $tc_count = $msg->{tool_calls} ? scalar(@{$msg->{tool_calls}}) : 0;
            log_debug('ConversationManager', "  Message role=" . $msg->{role} .
                ", has_tool_calls=$has_tool_calls, count=$tc_count");
        }

        # Skip system messages - we build fresh system prompt in process_input.
        # EXCEPTION: preserve <thread_summary> system messages — these carry
        # the YaRN compressed summary from prior trim cycles and must survive
        # reload so the model doesn't lose cross-cycle carryover. Without this
        # exception, every session reload drops the compressed tail, and the
        # next trim cycle can only summarize the raw messages that survived
        # reload — losing the aggregated summary of everything trimmed in prior
        # cycles across prior sessions.
        # NOTE: this does NOT re-add stale system prompts or dynamic UC —
        # those are rebuilt fresh by WorkflowOrchestrator each turn. Only
        # thread_summary summaries are preserved.
        next if $msg->{role} eq 'system'
                && (($msg->{content} // '') !~ /<thread_summary>/);

        # Skip tool result messages without tool_call_id
        # GitHub Copilot API REQUIRES tool_call_id for role=tool messages
        # If missing, API returns "tool call must have a tool call ID" error
        if ($msg->{role} eq 'tool' && !$msg->{tool_call_id}) {
            if ($debug) {
                log_debug('ConversationManager', "Skipping tool message without tool_call_id " .
                    "(content: " . substr($msg->{content} // '', 0, 50) . "...)");
            }
            next;
        }

        # Preserve message structure for API correlation
        if ($msg->{role} eq 'tool') {
            push @valid_messages, {
                role => $msg->{role},
                content => $msg->{content} || '',
                tool_call_id => $msg->{tool_call_id}
            };
            log_debug('ConversationManager', "Preserving tool message with tool_call_id=$msg->{tool_call_id}");
        } elsif ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            log_debug('ConversationManager', "Preserving assistant message with " .
                scalar(@{$msg->{tool_calls}}) . " tool_calls for API correlation");

            my $assistant_msg = {
                role => $msg->{role},
                content => $msg->{content} || '',
                tool_calls => $msg->{tool_calls}
            };
            $assistant_msg->{reasoning_details} = $msg->{reasoning_details} if $msg->{reasoning_details};
            push @valid_messages, $assistant_msg;
        } else {
            next unless $msg->{content} || $msg->{role} eq 'tool';

            push @valid_messages, {
                role => $msg->{role},
                content => $msg->{content} || ''
            };
        }
    }
    
    # Log if reasoning_details was present in any assistant message (for debugging)
    if (grep { $_->{reasoning_details} && $_->{role} eq 'assistant' } @valid_messages) {
        log_debug('ConversationManager', "Preserved reasoning_details in assistant message from history");
    }

    # PASS 1: Validate assistant messages with tool_calls have corresponding tool_results
    # Prevents "tool_use ids were found without tool_result blocks" API errors
    my @validated_messages = ();
    my $idx = 0;
    while ($idx < @valid_messages) {
        my $msg = $valid_messages[$idx];

        if ($msg->{role} eq "assistant" && $msg->{tool_calls} && @{$msg->{tool_calls}}) {
            my %expected_tool_ids = ();
            for my $tc (@{$msg->{tool_calls}}) {
                $expected_tool_ids{$tc->{id}} = 1 if $tc->{id};
            }

            # Collect all immediately following tool messages
            my %found_tool_ids = ();
            my $next_idx = $idx + 1;
            while ($next_idx < @valid_messages && $valid_messages[$next_idx]->{role} eq "tool") {
                if ($valid_messages[$next_idx]->{tool_call_id}) {
                    $found_tool_ids{$valid_messages[$next_idx]->{tool_call_id}} = 1;
                }
                $next_idx++;
            }

            # Check if all expected tool results are present
            my $missing_results = 0;
            for my $id (keys %expected_tool_ids) {
                unless ($found_tool_ids{$id}) {
                    log_debug('ConversationManager', "Orphaned tool_call detected: $id (missing tool_result - normal after context trim)");
                    $missing_results++;
                }
            }

            if ($missing_results > 0) {
                log_debug('ConversationManager', "Removing tool_calls from loaded assistant message ($missing_results missing results - normal after context trim)");

                my $fixed_msg = {
                    role => $msg->{role},
                    content => $msg->{content}
                };
                push @validated_messages, $fixed_msg;
            } else {
                push @validated_messages, $msg;
            }
        } else {
            push @validated_messages, $msg;
        }

        $idx++;
    }

    # PASS 2: Check for orphaned tool_results (tool_results without matching tool_calls)
    my %all_tool_call_ids = ();
    for my $msg (@validated_messages) {
        if ($msg->{role} && $msg->{role} eq 'assistant' &&
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                $all_tool_call_ids{$tc->{id}} = 1 if $tc->{id};
            }
        }
    }

    my @final_messages = ();
    for my $msg (@validated_messages) {
        if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
            unless ($all_tool_call_ids{$msg->{tool_call_id}}) {
                log_debug('ConversationManager', "Removing orphaned tool_result: $msg->{tool_call_id} (no matching tool_call)");
                next;
            }
        }
        push @final_messages, $msg;
    }

    return \@final_messages;
}

=head2 strip_messages_noise

Strip high-volume low-signal content (assistant reasoning_content /
reasoning_blocks) from a history array WITHOUT dropping any messages.
Callers that defer token-budget enforcement to the projection
(ContextBuilder) and the proactive trim (_role_based_tail_walk) use this
to recover the token savings of noise-stripping without losing messages
the compressor would have summarized.

When called from WorkflowOrchestrator::_build_turn_context, the full
(noise-stripped) history reaches ContextBuilder, which selects the
window by budget and compresses the rest into a compressed_tail via
YaRN. The proactive _role_based_tail_walk remains the authoritative
token-budget enforcer and does its own compression.

Arguments:
- $history: ArrayRef of message hashes (not mutated)
- %opts: C<debug => 1> for per-message strip log lines

Returns: ArrayRef of noise-stripped message copies (same length as input).

=cut

sub strip_messages_noise {
    my ($history, %opts) = @_;
    return [] unless $history && @$history;
    my $debug = $opts{debug} // 0;
    return [ map { _strip_message_noise($_, $debug) } @$history ];
}

=head2 _strip_message_noise

Drop content from a single message that is high-volume but low-signal.
Operates on a DEEP copy of the message (non-destructive) so the
caller's hash is not mutated.

For an assistant message, strips:
  - reasoning_content (string - DeepSeek, Anthropic native, Qwen thinking)
  - reasoning_details (arrayref - OpenAI Responses API, OpenRouter, MiniMax)
  - reasoning_blocks (arrayref - Anthropic native thinking blocks)
For a tool message, keeps everything (model needs the result).
For a user message, never strips. User text is sacred.

=cut

sub _strip_message_noise {
    my ($msg, $debug) = @_;
    return $msg unless ref($msg) eq 'HASH';

    my $role = $msg->{role} // '';
    # Deep-ish copy: clone the top-level hash and clone nested
    # arrayrefs that we mutate. tool_calls and content (when arrayref)
    # would otherwise be shared with the caller's data and any later
    # edit to the stripped message would corrupt the original. Strings
    # are immutable in Perl so we don't need to clone them.
    my $stripped = { %$msg };
    for my $key (qw(tool_calls reasoning_details reasoning_blocks)) {
        if (ref($stripped->{$key}) eq 'ARRAY') {
            $stripped->{$key} = [ @{$stripped->{$key}} ];
        }
    }
    if (ref($stripped->{content}) eq 'ARRAY') {
        $stripped->{content} = [ @{$stripped->{content}} ];
    }

    if ($role eq 'assistant') {
        # Strip reasoning_content from old assistant messages. The
        # model produced it once and processed it - keeping it in
        # history just burns tokens.
        if (defined $stripped->{reasoning_content} && length $stripped->{reasoning_content}) {
            my $saved = int(length($msg->{reasoning_content}) / 4);
            $stripped->{_stripped_thinking} = 1;
            delete $stripped->{reasoning_content};
            log_debug('ConversationManager', "Stripped reasoning_content from assistant (saved $saved tokens)") if $debug;
        }

        # reasoning_details (arrayref of OpenRouter/MiniMax/Responses-API
        # blocks). Can be just as large as reasoning_content when the
        # model emits detailed chain-of-thought.
        if (ref($stripped->{reasoning_details}) eq 'ARRAY' && @{$stripped->{reasoning_details}}) {
            my $saved = 0;
            $saved += length($_->{text} // '') for @{$stripped->{reasoning_details}};
            $saved = int($saved / 4);
            $stripped->{_stripped_thinking} = 1;
            delete $stripped->{reasoning_details};
            log_debug('ConversationManager', "Stripped reasoning_details from assistant (saved $saved tokens)") if $debug;
        }

        # reasoning_blocks (arrayref of Anthropic native thinking blocks).
        if (ref($stripped->{reasoning_blocks}) eq 'ARRAY' && @{$stripped->{reasoning_blocks}}) {
            my $saved = 0;
            for my $b (@{$stripped->{reasoning_blocks}}) {
                if (ref($b) eq 'HASH') {
                    $saved += length($b->{thinking} // $b->{text} // '');
                } else {
                    $saved += length($b // '');
                }
            }
            $saved = int($saved / 4);
            $stripped->{_stripped_thinking} = 1;
            delete $stripped->{reasoning_blocks};
            log_debug('ConversationManager', "Stripped reasoning_blocks from assistant (saved $saved tokens)") if $debug;
        }
    }

    return $stripped;
}

=head2 filter_continuation_prompts

Remove continuation-only user messages (e.g. 'continue', 'go on',
'ok', 'yes') from a messages array, EXCEPT keep the very last
user message (which is the actual current input). Continuation
prompts that survive trim pollute the alternation merge: a
sequence like:

    user: continue
    assistant: ...
    user: continue
    assistant: ...

becomes after `enforce_message_alternation`:

    user: continue

continue

<actual user input>

The model sees `continue\n\ncontinue\n\n<actual question>` with
no assistant responses explaining what was being continued.
Stripping the continuation prompts (except the last user, which
is the actual current input) prevents this.

This is a no-op for messages arrays without continuation
prompts.

Arguments:
- $messages: ArrayRef of message hashes

Returns: New ArrayRef with continuation prompts removed (or the
input arrayref if no changes needed)

=cut

sub filter_continuation_prompts {
    my ($messages) = @_;
    return $messages unless $messages && @$messages;

    require CLIO::Core::ContextBuilder;

    # Identify the LAST user message index - keep it as-is even if
    # it's a continuation prompt (e.g. user types 'continue' as their
    # actual current input).
    my $last_user_idx;
    for my $i (0 .. $#$messages) {
        if (ref($messages->[$i]) eq 'HASH' && ($messages->[$i]{role} // '') eq 'user') {
            $last_user_idx = $i;
        }
    }

    my @filtered;
    my $removed = 0;
    for my $i (0 .. $#$messages) {
        my $msg = $messages->[$i];
        if (ref($msg) eq 'HASH'
            && ($msg->{role} // '') eq 'user'
            && defined $last_user_idx
            && $i != $last_user_idx
            && CLIO::Core::ContextBuilder::_is_continuation_prompt($msg->{content} // '', 1)) {
            $removed++;
            next;
        }
        push @filtered, $msg;
    }

    return $messages if $removed == 0;
    log_debug('ConversationManager', "filter_continuation_prompts: removed $removed continuation prompts");
    return \@filtered;
}

=head2 enforce_message_alternation

Enforce role alternation for providers that require it.

Behavior:
1. Preserves tool messages with their tool_call_ids (never merged)
2. Preserves system messages as separate messages (never merged)
3. Preserves arrayref content (multimodal) as separate messages (never merged)
4. Does NOT merge consecutive user messages — all CLIO providers accept
   consecutive user messages natively (OpenAI, Anthropic, Google, Copilot,
   etc.). Merging user messages causes data loss: the model sees the old
   user input and the new input concatenated as one message, losing
   context boundaries. For local-inference providers that use Jinja chat
   templates which may require strict alternation, a minimal placeholder
   assistant message (content='') is inserted between consecutive user
   messages instead of merging.
5. Merges consecutive assistant messages (harmless and useful for dedup)

Arguments:
- $messages: Arrayref of messages
- $provider: Provider name string (e.g., 'github_copilot', 'google')
- %opts: Options hash
  - debug => 0|1

Returns:
- Arrayref of alternation-enforced messages

=cut

sub enforce_message_alternation {
    my ($messages, $provider, %opts) = @_;
    my $debug = $opts{debug} // 0;

    return $messages unless $messages && @$messages;

    log_debug('ConversationManager', "Enforcing message alternation"
        . (defined $provider ? " (provider=$provider)" : ''));

    my @alternating = ();
    my $last_role = undef;
    my $accumulated_content = '';
    my $accumulated_arrayref = undef;  # Preserve arrayref content (multimodal)
    my $accumulated_tool_calls = [];
    my $accumulated_tool_call_id = undef;
    my $accumulated_reasoning_details = undef;  # MiniMax interleaved thinking
    my $accumulated_reasoning_content = undef;  # DeepSeek reasoning_content

    for my $msg (@$messages) {
        my $role = $msg->{role};
        my $is_arrayref = ref($msg->{content}) eq 'ARRAY';

        # Don't merge consecutive USER messages — they are distinct turns
        # that must remain separate to prevent data loss (merging
        # combines old+new user input into one message, losing the
        # model's view of the actual current input). All CLIO cloud
        # providers accept consecutive user messages natively. For
        # local-inference providers that use Jinja chat templates which
        # may require strict alternation, a minimal placeholder
        # assistant message is inserted in the else branch below.
        #
        # Do NOT merge tool messages - each has unique tool_call_id
        # Do NOT merge arrayref content into string - preserve it as a separate message
        # Do NOT merge system messages - each represents a distinct pipeline
        # section (system_prompt, summary, context_files, user_context). Merging
        # them concatenates content into one big system prompt, which couples
        # their cache lifetimes: any section's regeneration invalidates the
        # whole merged prompt for LCP cache purposes. Anthropic's
        # _separate_system_prompt and OpenAI's per-message cache_control both
        # rely on the sections being separate messages.
        my $is_consecutive_user = ($role eq 'user' && defined $last_role
                                    && $last_role eq 'user' && !$is_arrayref);

        # Merge: same role, not tool/system, not arrayref, and not
        # consecutive user messages (those are preserved separately).
        if (defined $last_role && $role eq $last_role && $role ne 'tool' && $role ne 'system' && !$is_arrayref && !$is_consecutive_user) {
            my $has_content = 0;
            if (defined $msg->{content}) {
                if (!ref($msg->{content})) {
                    $has_content = length($msg->{content}) > 0;
                } elsif (ref($msg->{content}) eq 'ARRAY') {
                    $has_content = @{$msg->{content}} > 0;
                }
            }
            # Drop empty assistant content when merging consecutive
            # assistants. This handles the case where trim kept a
            # trailing "Done N" assistant (no tool_calls, just text)
            # but dropped the turn's tool pair - the next assistant
            # "Work N+1" should stand alone rather than being fused
            # with orphaned "Done N" text.
            my $drop_this_content = 0;
            if ($role eq 'assistant' && !$has_content
                && (!defined $msg->{tool_calls} || !@{$msg->{tool_calls}})) {
                $drop_this_content = 1;
            }
            if ($has_content && !$drop_this_content) {
                $accumulated_content .= "\n\n" if length($accumulated_content) > 0;
                if (!ref($msg->{content})) {
                    $accumulated_content .= $msg->{content};
                }
            }

            if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                push @$accumulated_tool_calls, @{$msg->{tool_calls}};
            }
            $accumulated_reasoning_content = $msg->{reasoning_content} if $msg->{reasoning_content};

            log_debug('ConversationManager', "Merged consecutive $role message" . ($drop_this_content ? ' (dropped empty content)' : ''));
        } else {
            # Different role, arrayref content, or tool message - flush accumulated message
            if (defined $last_role) {
                my $flushed = {
                    role => $last_role,
                    content => $accumulated_arrayref // $accumulated_content
                };

                if (@$accumulated_tool_calls) {
                    $flushed->{tool_calls} = $accumulated_tool_calls;
                }

                if ($last_role eq 'tool' && defined $accumulated_tool_call_id) {
                    $flushed->{tool_call_id} = $accumulated_tool_call_id;
                }

                if ($accumulated_reasoning_details) {
                    $flushed->{reasoning_details} = $accumulated_reasoning_details;
                }
                # Set reasoning_content: prefer direct value, fallback to details->text
                if ($accumulated_reasoning_content) {
                    $flushed->{reasoning_content} = $accumulated_reasoning_content;
                } elsif ($accumulated_reasoning_details) {
                    $flushed->{reasoning_content} = $accumulated_reasoning_details->[0]->{text};
                }

                push @alternating, $flushed;
            }

            # For local-inference providers that may require strict
            # alternation (Jinja chat templates like Qwen3 which reject
            # consecutive user messages with "System message must be at
            # the beginning" or similar errors), insert a minimal
            # placeholder assistant message between consecutive user
            # messages instead of merging them. Cloud providers
            # (OpenAI, Anthropic, Google, Copilot, etc.) accept
            # consecutive user messages natively, so no placeholder
            # is needed.
            if ($is_consecutive_user) {
                my $is_local = 0;
                if (defined $provider && length($provider)) {
                    require CLIO::Providers;
                    $is_local = CLIO::Providers::is_local_inference($provider);
                }
                if ($is_local) {
                    push @alternating, {
                        role    => 'assistant',
                        content => '',
                    };
                    log_debug('ConversationManager',
                        "Inserted placeholder assistant message between "
                        . "consecutive user messages (provider=$provider requires strict alternation)");
                }
            }

            # Start new accumulation
            $last_role = $role;
            if ($is_arrayref) {
                $accumulated_content = '';
                $accumulated_arrayref = $msg->{content};
            } else {
                $accumulated_content = $msg->{content} // '';
                $accumulated_arrayref = undef;
            }
            $accumulated_tool_calls = $msg->{tool_calls} ? [@{$msg->{tool_calls}}] : [];
            $accumulated_tool_call_id = $msg->{tool_call_id};
            $accumulated_reasoning_details = $msg->{reasoning_details};
            $accumulated_reasoning_content = $msg->{reasoning_content};
        }
    }

    # Flush final accumulated message
    if (defined $last_role) {
        my $flushed = {
            role => $last_role,
            content => $accumulated_arrayref // $accumulated_content
        };

        if (@$accumulated_tool_calls) {
            $flushed->{tool_calls} = $accumulated_tool_calls;
        }

        if ($last_role eq 'tool' && defined $accumulated_tool_call_id) {
            $flushed->{tool_call_id} = $accumulated_tool_call_id;
        }

        if ($accumulated_reasoning_details) {
            $flushed->{reasoning_details} = $accumulated_reasoning_details;
        }
        if ($accumulated_reasoning_content) {
            $flushed->{reasoning_content} = $accumulated_reasoning_content;
        } elsif ($accumulated_reasoning_details) {
            $flushed->{reasoning_content} = $accumulated_reasoning_details->[0]->{text};
        }

        push @alternating, $flushed;
    }

        log_debug('ConversationManager', "Alternation complete: " . scalar(@$messages) . " -> " . scalar(@alternating) . " messages");

    return \@alternating;
}

=head2 inject_context_files

Inject user-added context files into the messages array.

Called after system prompt but before conversation history.
Context files are added via /context add command.

Arguments:
- $session: Session object (CLIO::Session::State)
- $messages: Reference to messages array (modified in-place)
- %opts: Options hash
  - debug => 0|1

=cut

sub inject_context_files {
    my ($session, $messages, %opts) = @_;
    my $debug = $opts{debug} // 0;

    return unless $session && $session->{context_files};

    my @context_files = @{$session->{context_files}};
    return unless @context_files;

    log_debug('ConversationManager', "Injecting " . scalar(@context_files) . " context file(s)");

    my $context_content = "";
    my $total_tokens = 0;

    for my $file (@context_files) {
        unless (-f $file) {
            log_debug('ConversationManager', "Context file not found: $file");
            next;
        }

        eval {
            open my $fh, '<', $file or croak "Cannot read file: $!";
            my $content = do { local $/; <$fh> };
            close $fh;

            my $tokens = int(length($content) / 4);
            $total_tokens += $tokens;

            $context_content .= "\n<context_file path=\"$file\" tokens=\"~$tokens\">\n";
            $context_content .= $content;
            $context_content .= "\n</context_file>\n";

            log_debug('ConversationManager', "Injected context file: $file (~$tokens tokens)");
        };

        if ($@) {
            log_debug('ConversationManager', "Failed to read context file $file (skipping): $@");
        }
    }

    if ($context_content) {
        my $context_message = {
            role => 'user',
            content => "[CONTEXT FILES]\n" .
                "The following files were added to context by the user.\n" .
                "Reference these files when relevant to the conversation.\n" .
                "Total estimated tokens: ~$total_tokens\n" .
                $context_content
        };

        push @$messages, $context_message;

        log_debug('ConversationManager', "Context injection complete (~$total_tokens tokens)");
    }
}

=head2 generate_tool_call_id

Generate a unique ID for a tool call in OpenAI format.

Returns:
- String tool call ID (e.g., "call_abc123xyz789...")

=cut

sub generate_tool_call_id {
    my $unique = time() . rand();
    my $hash = md5_hex($unique);
    return 'call_' . substr($hash, 0, 24);
}

=head2 repair_tool_call_json

Attempt to repair common JSON errors in tool call arguments.

Common issues:
- Missing values: {"offset":,"length":8192}
- Trailing commas: {"offset":0,"length":8192}
- Unescaped quotes
- Decimals without leading zero: {"progress":0.1}

Arguments:
- $json_str: Potentially malformed JSON string
- %opts: Options hash
  - debug => 0|1

Returns:
- Repaired JSON string if successful, undef if repair failed

=cut

sub repair_tool_call_json {
    my ($json_str, %opts) = @_;
    my $debug = $opts{debug} // 0;

    return undef unless defined $json_str;

    # Use JSONRepair utility if available
    eval {
        require CLIO::Util::JSONRepair;
        my $repaired = CLIO::Util::JSONRepair::repair_malformed_json($json_str, $debug);
        return $repaired if $repaired;
    };
    if ($@) {
        log_debug('ConversationManager', "JSONRepair module not available: $@");
    }

    # Fallback: Apply common repair patterns manually
    my $repaired = $json_str;

    # Fix 1: Missing values in key-value pairs
    $repaired =~ s/:\s*,/: null,/g;
    $repaired =~ s/:\s*\}/: null}/g;
    $repaired =~ s/:\s*\]/: null]/g;

    # Fix 2: Decimals without leading zero
    $repaired =~ s/:(\s*)\.(\d)/:${1}0.$2/g;
    $repaired =~ s/:(\s*)-\.(\d)/:${1}-0.$2/g;

    # Fix 3: Trailing commas before closing braces/brackets
    $repaired =~ s/,\s*\}/}/g;
    $repaired =~ s/,\s*\]/]/g;

    # Validate that repair worked
    eval {
        decode_json($repaired);
    };

    if ($@) {
        log_debug('ConversationManager', "JSON repair attempt failed: $@");
        return undef;
    }

    return $repaired;
}

1;

__END__

=head1 AUTHOR

Andrew Wyatt (Fewtarius)

=head1 LICENSE

GPL-3.0-only

=cut

1;
