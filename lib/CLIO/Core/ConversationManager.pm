package CLIO::Core::ConversationManager;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use Carp qw(croak);

use CLIO::Core::Logger qw(log_error log_warning log_info log_debug);
use CLIO::Util::JSON qw(decode_json);
use CLIO::Memory::TokenEstimator;
use Digest::MD5 qw(md5_hex);

use Exporter 'import';
our @EXPORT_OK = qw(
    load_conversation_history
    trim_conversation_for_api
    enforce_message_alternation
    inject_context_files
    generate_tool_call_id
    repair_tool_call_json
);

=head1 NAME

CLIO::Core::ConversationManager - Conversation history management and validation

=head1 DESCRIPTION

Manages conversation history for the API workflow loop. Handles loading,
validating, trimming, and enforcing message format requirements for
different AI providers.

Extracted from WorkflowOrchestrator to reduce module size and improve
separation of concerns. Uses functional style (exported functions).

=head1 SYNOPSIS

    use CLIO::Core::ConversationManager qw(
        load_conversation_history
        trim_conversation_for_api
        enforce_message_alternation
    );

    my $history = load_conversation_history($session, debug => 1);
    my $trimmed = trim_conversation_for_api($history, $system_prompt, %opts);
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
            log_warning('ConversationManager',
                "Coerced ref content to string at JIT time - State::load migration may be stale");
        }

        if ($debug) {
            my $has_tool_calls = exists $msg->{tool_calls} ? 'YES' : 'NO';
            my $tc_count = $msg->{tool_calls} ? scalar(@{$msg->{tool_calls}}) : 0;
            log_debug('ConversationManager', "  Message role=" . $msg->{role} .
                ", has_tool_calls=$has_tool_calls, count=$tc_count");
        }

        # Skip system messages - we build fresh system prompt in process_input
        next if $msg->{role} eq 'system';

        # Skip tool result messages without tool_call_id
        # GitHub Copilot API REQUIRES tool_call_id for role=tool messages
        # If missing, API returns "tool call must have a tool call ID" error
        if ($msg->{role} eq 'tool' && !$msg->{tool_call_id}) {
            if ($debug) {
                log_warning('ConversationManager', "Skipping tool message without tool_call_id " .
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

=head2 trim_conversation_for_api

Trim conversation history to fit within model's token limits.

Strategy:
1. Always preserve first user message (original task context)
2. Keep recent messages for continuity
3. Fill remaining budget with high-importance older messages
4. Preserve tool_call/tool_result pairs together (never split them)

Arguments:
- $history: Arrayref of message objects
- $system_prompt: System prompt string (for token accounting)
- %opts: Options hash
  - model_context_window => int (default: 128000)
  - max_response_tokens => int (default: 16000)
  - debug => 0|1

Returns:
- Arrayref of trimmed messages (may be same ref if no trimming needed)

=cut

sub trim_conversation_for_api {
    my ($history, $system_prompt, %opts) = @_;

    return $history unless $history && @$history;

    my $debug = $opts{debug} // 0;
    require CLIO::Core::Defaults;
    my $model_context = $opts{model_context_window} // CLIO::Core::Defaults::DEFAULT_CONTEXT_WINDOW();
    my $max_response = $opts{max_response_tokens} // CLIO::Core::Defaults::DEFAULT_MAX_RESPONSE_TOKENS();

    # Compute prompt budget from model capabilities. Uses the model's
    # actual max_response_tokens (passed in as max_response_tokens,
    # originally from Provider.max_output_tokens) plus an estimation
    # buffer. NO hard cap on the reserve - whatever the model supports.
    my $caps_for_budget = {
        max_context_window_tokens => $model_context,
        max_output_tokens         => $max_response,
    };
    my $prompt_budget = CLIO::Memory::TokenEstimator::compute_prompt_budget($caps_for_budget);
    my $safe_threshold = $prompt_budget;

    # Estimate current size
    my $system_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($system_prompt);
    my $history_tokens = CLIO::Memory::TokenEstimator::estimate_messages_tokens($history);
    my $current_total = $system_tokens + $history_tokens + 500;

    if ($current_total <= $safe_threshold) {
        if ($debug) {
            log_debug('ConversationManager', "History OK: $history_tokens tokens (total: $current_total of $safe_threshold prompt budget, model context: $model_context)");
        }
        return $history;
    }

    if ($debug) {
        log_warning('ConversationManager', "History exceeds prompt budget: $current_total tokens (budget: $safe_threshold of $model_context total). Trimming...");
        log_debug('ConversationManager', "Model context window: $model_context tokens");
        log_debug('ConversationManager', "Max response: $max_response tokens");
        log_debug('ConversationManager', "Prompt budget (ctx - output - buffer): $safe_threshold tokens");
        log_debug('ConversationManager', "System prompt: $system_tokens tokens");
        log_debug('ConversationManager', "History: $history_tokens tokens");
        log_debug('ConversationManager', "Messages in history: " . scalar(@$history) . "");
    }

    my @messages = @$history;

    # Calculate target based on available space (90% of remaining budget
    # after system prompt reserve - gives 10% headroom for next burst).
    my $target_tokens = int(($safe_threshold - $system_tokens) * 0.9);

    if ($target_tokens < 5000) {
        $target_tokens = 5000;
        log_warning('ConversationManager', "Target tokens very low ($target_tokens), system prompt may be too large");
    }

    my $current_count = scalar(@messages);

    # Tail-preserving trim: walk backwards from newest message, keeping
    # messages until token budget is exhausted. This ensures the most recent
    # context (current task) survives, not old completed tasks.
    # The proactive trim in MessageValidator handles sophisticated compression
    # with thread_summary generation. This is a simple budget-based tail keep.
    #
    # IMPORTANT: Preserve tool_call/tool_result pairs together - never split them.

    my @kept = ();
    my $kept_tokens = 0;

    for my $i (reverse 0 .. $#messages) {
        my $msg = $messages[$i];
        my $msg_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($msg->{content} // '');
        
        # Check if this is a tool_result that needs its tool_call partner
        my $is_tool_result = ($msg->{role} // '') eq 'tool';
        my $tool_call_id = $msg->{tool_call_id};
        
        # If this is a tool_result, check if we have its tool_call in the kept messages
        # If not, we need to also keep the tool_call (which would be earlier in the array)
        if ($is_tool_result && $tool_call_id) {
            # Look for the matching tool_call in the remaining messages (earlier indices)
            my $has_tool_call = 0;
            for my $j (0 .. $i - 1) {
                my $prev_msg = $messages[$j];
                if (($prev_msg->{role} // '') eq 'assistant' && $prev_msg->{tool_calls}) {
                    for my $tc (@{$prev_msg->{tool_calls}}) {
                        if ($tc->{id} eq $tool_call_id) {
                            $has_tool_call = 1;
                            last;
                        }
                    }
                }
                last if $has_tool_call;
            }
            
            # If we don't have the tool_call in kept messages, we need to include it
            # This means we need to also include the assistant message with the tool_call
            if (!$has_tool_call) {
                # Find the assistant message with this tool_call
                for my $j (0 .. $i - 1) {
                    my $prev_msg = $messages[$j];
                    if (($prev_msg->{role} // '') eq 'assistant' && $prev_msg->{tool_calls}) {
                        for my $tc (@{$prev_msg->{tool_calls}}) {
                            if ($tc->{id} eq $tool_call_id) {
                                # Include this assistant message (and its tool_calls)
                                my $assistant_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($prev_msg->{content} // '');
                                if ($kept_tokens + $msg_tokens + $assistant_tokens <= $target_tokens) {
                                    unshift @kept, $prev_msg;
                                    $kept_tokens += $assistant_tokens;
                                }
                                last;
                            }
                        }
                    }
                }
            }
        }
        
        if ($kept_tokens + $msg_tokens <= $target_tokens) {
            unshift @kept, $msg;
            $kept_tokens += $msg_tokens;
        } else {
            # Budget exhausted - stop adding older messages
            last;
        }
    }

    # Always preserve the first user message (original task context).
    # The reverse walk may have dropped it if budget was tight.
    # Find and prepend it if missing - the documented policy is "always".
    my $first_user_msg;
    for my $msg (@messages) {
        if (($msg->{role} // '') eq 'user') {
            $first_user_msg = $msg;
            last;
        }
    }
    if ($first_user_msg) {
        my $already_kept = 0;
        for my $k (@kept) {
            if ($k eq $first_user_msg) {
                $already_kept = 1;
                last;
            }
        }
        unless ($already_kept) {
            # Truncate to 2000 chars if needed to avoid blowing budget,
            # but always preserve the core of the original task.
            my $preserved = { %$first_user_msg };
            if (length($preserved->{content} // '') > 2000) {
                $preserved->{content} = substr($preserved->{content}, 0, 2000) . '...';
            }
            unshift @kept, $preserved;
            if ($debug) {
                log_debug('ConversationManager', "Preserved first user message (original task context)");
            }
        }
    }

    if ($debug) {
        log_debug('ConversationManager', "Trimmed: " . scalar(@messages) . " -> " . scalar(@kept) . " messages");
        log_debug('ConversationManager', "Token reduction: $history_tokens -> $kept_tokens tokens");
        log_debug('ConversationManager', "Final total with system: " . ($system_tokens + $kept_tokens) . " of $safe_threshold prompt budget");
    }

    return \@kept if @kept;

    return $history;
}

=head2 enforce_message_alternation

Enforce strict user/assistant alternation.

Some providers require alternating roles.
This function:
1. Merges consecutive same-role messages into one
2. Preserves tool messages with their tool_call_ids

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

    log_debug('ConversationManager', "Enforcing message alternation");

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

        # Check if same role as previous (needs merging)
        # Do NOT merge tool messages - each has unique tool_call_id
        # Do NOT merge arrayref content into string - preserve it as a separate message
        if (defined $last_role && $role eq $last_role && $role ne 'tool' && !$is_arrayref) {
            my $has_content = 0;
            if (defined $msg->{content}) {
                if (!ref($msg->{content})) {
                    $has_content = length($msg->{content}) > 0;
                } elsif (ref($msg->{content}) eq 'ARRAY') {
                    $has_content = @{$msg->{content}} > 0;
                }
            }
            if ($has_content) {
                $accumulated_content .= "\n\n" if length($accumulated_content) > 0;
                if (!ref($msg->{content})) {
                    $accumulated_content .= $msg->{content};
                }
            }

            if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                push @$accumulated_tool_calls, @{$msg->{tool_calls}};
            }
            $accumulated_reasoning_content = $msg->{reasoning_content} if $msg->{reasoning_content};

            log_debug('ConversationManager', "Merged consecutive $role message");
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
            log_warning('ConversationManager', "Context file not found: $file");
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
