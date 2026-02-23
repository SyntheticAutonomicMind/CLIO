package CLIO::Core::ConversationManager;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

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

=head2 load_conversation_history

Load conversation history from session object, validating message structure
and ensuring tool call/result correlation integrity.

Handles:
- Hash-based and object-based session interfaces
- Filtering system messages (fresh system prompt built each request)
- Validating tool message tool_call_id presence
- Preserving tool_calls on assistant messages for API correlation
- Removing orphaned tool_calls (missing results) and tool_results (missing calls)

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
                use Data::Dumper;
                log_debug('ConversationManager', "First assistant message structure:");
                log_debug('ConversationManager', Dumper($msg));
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

        # Preserve message structure for proper API correlation
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

            push @valid_messages, {
                role => $msg->{role},
                content => $msg->{content} || '',
                tool_calls => $msg->{tool_calls}
            };
        } else {
            next unless $msg->{content} || $msg->{role} eq 'tool';

            push @valid_messages, {
                role => $msg->{role},
                content => $msg->{content} || ''
            };
        }
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
    my $model_context = $opts{model_context_window} // 128000;
    my $max_response = $opts{max_response_tokens} // 16000;

    # Calculate dynamic safe threshold based on model's context window
    # Start trimming at 58% of max context (leaves 42% safety margin)
    my $safe_threshold_percent = 0.58;
    my $safe_threshold = int($model_context * $safe_threshold_percent);

    # Estimate current size
    my $system_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($system_prompt);
    my $history_tokens = CLIO::Memory::TokenEstimator::estimate_messages_tokens($history);
    my $current_total = $system_tokens + $history_tokens + 500;

    if ($current_total <= $safe_threshold) {
        if ($debug) {
            log_debug('ConversationManager', "History OK: $history_tokens tokens (total: $current_total of $safe_threshold safe limit, model context: $model_context)");
        }
        return $history;
    }

    if ($debug) {
        log_warning('ConversationManager', "History exceeds safe limit: $current_total tokens (safe: $safe_threshold of $model_context total). Trimming...");
        log_debug('ConversationManager', "Model context window: $model_context tokens");
        log_debug('ConversationManager', "Max response: $max_response tokens");
        log_debug('ConversationManager', "Safe trim threshold: " . int($safe_threshold_percent * 100) . "% = $safe_threshold tokens");
        log_debug('ConversationManager', "System prompt: $system_tokens tokens");
        log_debug('ConversationManager', "History: $history_tokens tokens");
        log_debug('ConversationManager', "Messages in history: " . scalar(@$history) . "");
    }

    my @messages = @$history;
    my @trimmed = ();

    # Calculate target based on available space
    my $target_tokens = int(($safe_threshold - $system_tokens) * 0.9);

    if ($target_tokens < 5000) {
        $target_tokens = 5000;
        log_warning('ConversationManager', "Target tokens very low ($target_tokens), system prompt may be too large");
    }

    my $keep_recent = 10;
    my $current_count = scalar(@messages);

    # Step 1: Extract and preserve the first user message (critical for context)
    my $first_user_msg = undef;
    my $first_user_tokens = 0;
    my $first_user_idx = -1;

    for my $i (0 .. $#messages) {
        my $msg = $messages[$i];
        if ($msg->{role} && $msg->{role} eq 'user') {
            if (($msg->{_importance} // 0) >= 10.0) {
                $first_user_msg = $msg;
                $first_user_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($msg->{content} // '');
                $first_user_idx = $i;
                log_debug('ConversationManager', "Preserving first user message (importance=" . ($msg->{_importance} // 0) . ", tokens=$first_user_tokens)");
            }
            last;
        }
    }

    my $reserved_tokens = $first_user_tokens;
    my $available_tokens = $target_tokens - $reserved_tokens;

    if ($current_count > $keep_recent) {
        my @recent = ();
        for my $i (($current_count - $keep_recent) .. ($current_count - 1)) {
            next if $i == $first_user_idx;
            push @recent, $messages[$i] if $i >= 0;
        }

        my @older = ();
        for my $i (0 .. ($current_count - $keep_recent - 1)) {
            next if $i == $first_user_idx;
            push @older, $messages[$i] if $i >= 0;
        }

        my @sorted_older = sort {
            ($b->{_importance} // 0) <=> ($a->{_importance} // 0)
        } @older;

        my $trimmed_tokens = 0;
        my @kept_recent = ();

        for my $msg (@recent) {
            my $msg_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($msg->{content} // '');
            if ($trimmed_tokens + $msg_tokens <= $available_tokens) {
                push @kept_recent, $msg;
                $trimmed_tokens += $msg_tokens;
            }
        }

        my @kept_older = ();
        for my $msg (@sorted_older) {
            my $msg_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($msg->{content} // '');
            if ($trimmed_tokens + $msg_tokens <= $available_tokens) {
                push @kept_older, $msg;
                $trimmed_tokens += $msg_tokens;
            }
        }

        @trimmed = ();
        push @trimmed, $first_user_msg if $first_user_msg;

        @kept_older = sort {
            my $idx_a = 0;
            my $idx_b = 0;
            for my $i (0 .. $#messages) {
                $idx_a = $i if $messages[$i] == $a;
                $idx_b = $i if $messages[$i] == $b;
            }
            $idx_a <=> $idx_b
        } @kept_older;

        push @trimmed, @kept_older;
        push @trimmed, @kept_recent;

        my $final_tokens = $reserved_tokens + $trimmed_tokens;
        if ($debug) {
            log_debug('ConversationManager', "Trimmed: " . scalar(@messages) . " -> " . scalar(@trimmed) . " messages");
            log_debug('ConversationManager', "First user preserved: " . ($first_user_msg ? 'YES' : 'NO') .
                ($first_user_msg ? " ($first_user_tokens tokens)" : ""));
            log_debug('ConversationManager', "Token reduction: $history_tokens -> $final_tokens tokens");
            log_debug('ConversationManager', "Final total with system: " . ($system_tokens + $final_tokens) . " of $safe_threshold safe limit");
        }

        return \@trimmed;
    }

    return $history;
}

=head2 enforce_message_alternation

Enforce strict user/assistant alternation for provider compatibility.

Some providers (like Claude via GitHub Copilot) require alternating roles.
This function:
1. Converts tool messages to user messages for providers without role=tool support
2. Merges consecutive same-role messages into one
3. Strips orphaned tool_calls when provider doesn't support role=tool

Arguments:
- $messages: Arrayref of messages
- $provider: Provider name string (e.g., 'github_copilot', 'anthropic')
- %opts: Options hash
  - debug => 0|1

Returns:
- Arrayref of alternation-enforced messages

=cut

sub enforce_message_alternation {
    my ($messages, $provider, %opts) = @_;
    my $debug = $opts{debug} // 0;

    return $messages unless $messages && @$messages;

    log_debug('ConversationManager', "Enforcing message alternation (Claude compatibility)");

    my @alternating = ();
    my $last_role = undef;
    my $accumulated_content = '';
    my $accumulated_tool_calls = [];
    my $accumulated_tool_call_id = undef;

    # Determine if provider supports role=tool
    my $provider_supports_tool_role = ($provider =~ /github|openai/i);

    for my $msg (@$messages) {
        my $role = $msg->{role};

        # Convert tool messages to user messages ONLY for providers that don't support role=tool
        if ($role eq 'tool' && !$provider_supports_tool_role) {
            $role = 'user';

            my $tool_content = $msg->{content} || '{}';
            my $tool_id = $msg->{tool_call_id} || 'unknown';

            $msg = {
                role => 'user',
                content => "Tool Result (ID: $tool_id):\n$tool_content"
            };

            log_debug('ConversationManager', "Converted tool message to user message");
        }

        # Check if same role as previous (needs merging)
        # Do NOT merge tool messages - each has unique tool_call_id
        if (defined $last_role && $role eq $last_role && $role ne 'tool') {
            if ($msg->{content} && length($msg->{content}) > 0) {
                $accumulated_content .= "\n\n" if length($accumulated_content) > 0;
                $accumulated_content .= $msg->{content};
            }

            if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                push @$accumulated_tool_calls, @{$msg->{tool_calls}};
            }

            log_debug('ConversationManager', "Merged consecutive $role message");
        } else {
            # Different role - flush accumulated message if any
            if (defined $last_role) {
                my $flushed = {
                    role => $last_role,
                    content => $accumulated_content
                };

                if (@$accumulated_tool_calls) {
                    $flushed->{tool_calls} = $accumulated_tool_calls;
                }

                if ($last_role eq 'tool' && defined $accumulated_tool_call_id) {
                    $flushed->{tool_call_id} = $accumulated_tool_call_id;
                }

                push @alternating, $flushed;
            }

            # Start new accumulation
            $last_role = $role;
            $accumulated_content = $msg->{content} || '';
            $accumulated_tool_calls = $msg->{tool_calls} ? [@{$msg->{tool_calls}}] : [];
            $accumulated_tool_call_id = $msg->{tool_call_id};
        }
    }

    # Flush final accumulated message
    if (defined $last_role) {
        my $flushed = {
            role => $last_role,
            content => $accumulated_content
        };

        if (@$accumulated_tool_calls) {
            $flushed->{tool_calls} = $accumulated_tool_calls;
        }

        if ($last_role eq 'tool' && defined $accumulated_tool_call_id) {
            $flushed->{tool_call_id} = $accumulated_tool_call_id;
        }

        push @alternating, $flushed;
    }

    # Strip tool_calls from assistant messages if provider doesn't support role=tool
    if (!$provider_supports_tool_role) {
        for my $msg (@alternating) {
            if ($msg->{role} eq 'assistant' && $msg->{tool_calls}) {
                delete $msg->{tool_calls};
                log_debug('ConversationManager', "Stripped tool_calls from assistant message (provider doesn't support role=tool)");
            }
        }
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
            open my $fh, '<', $file or die "Cannot read file: $!";
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
