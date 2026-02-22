if ($ENV{CLIO_DEBUG}) {
    log_debug('SessionState', "CLIO::Session::State loaded");
}
package CLIO::Session::State;

=head1 NAME

CLIO::Session::State - Session state persistence and serialization

=head1 DESCRIPTION

Manages the persistent state of a CLIO session, including conversation history,
memory modules (STM, LTM, YaRN), billing/usage tracking, and session metadata.
Handles atomic file saves, state migration from older formats, and session cleanup.

=head1 SYNOPSIS

    use CLIO::Session::State;
    
    # Create new state
    my $state = CLIO::Session::State->new(session_id => $id);
    $state->add_message('user', 'Hello');
    $state->save();
    
    # Load existing state
    my $state = CLIO::Session::State->load($session_id);

=cut

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use Carp qw(croak);
use CLIO::Core::Logger qw(log_error log_warning log_debug log_info);
use CLIO::Util::PathResolver;
use File::Spec;
use CLIO::Util::JSON qw(encode_json decode_json);
use Cwd qw(getcwd abs_path);
use POSIX qw(strftime);
use CLIO::Memory::ShortTerm;
use CLIO::Memory::LongTerm;
use CLIO::Memory::YaRN;
use CLIO::Memory::TokenEstimator;

sub new {
    my ($class, %args) = @_;
    if ($ENV{CLIO_DEBUG} || $args{debug}) {
        log_debug('State::new', "called with args: " . join(", ", map { "$_=$args{$_}" } keys %args));
    }
    my $self = {
        session_id => $args{session_id},
        history    => [],
        debug      => $args{debug} // 0,
        file       => _session_file($args{session_id}),
        stm        => $args{stm} // CLIO::Memory::ShortTerm->new(debug => $args{debug}),
        ltm        => $args{ltm} // CLIO::Memory::LongTerm->new(debug => $args{debug}),
        yarn       => $args{yarn} // CLIO::Memory::YaRN->new(debug => $args{debug}),
        # Working directory
        working_directory => $args{working_directory} || getcwd(),
        # GitHub Copilot session continuation
        _stateful_markers => [],
        # Session creation timestamp (for proper resume ordering)
        created_at => $args{created_at} // time(),
        # Billing tracking fields
        billing    => {
            total_prompt_tokens => 0,
            total_completion_tokens => 0,
            total_tokens => 0,
            total_requests => 0,
            total_premium_requests => 0,  # GitHub Copilot premium requests charged
            model => undef,  # Current model being used
            multiplier => 0,  # Billing multiplier from GitHub Copilot
            requests => [],  # Array of individual request billing records
        },
        # Context files
        context_files => [],
        # Context management configuration
        max_tokens => $args{max_tokens} // 128000,           # API hard limit
        summarize_threshold => $args{summarize_threshold} // 102400,  # 80% of max
        compression_threshold => $args{compression_threshold} // 51200, # 40% of max
    };
    bless $self, $class;
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        log_debug('SessionState', "[STATE] yarn object ref: $self->{yarn}");
        log_debug('State::new', "returning self: $self");
    }
    return $self;
}

sub _session_file {
    my ($session_id) = @_;
    return CLIO::Util::PathResolver::get_session_file($session_id);
}

sub save {
    my ($self) = @_;
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        print "[STATE][FORCE] Entered save method for $self->{file}\n";
    }
    
    # Save project-level LTM to .clio/ltm.json (shared across all sessions)
    # Use getcwd() for the LTM path, not stored working_directory
    # This prevents issues when sessions are shared across different machines
    # where the stored path may not exist (e.g., /Users/... on Linux)
    if ($self->{ltm}) {
        my $current_dir = getcwd();
        my $ltm_file = File::Spec->catfile($current_dir, '.clio', 'ltm.json');
        eval { $self->{ltm}->save($ltm_file); };
        if ($@) {
            log_warning('State', "Failed to save LTM: $@");
        }
    }
    
    # Prepare data to save
    my $data = {
        history => $self->{history},
        stm     => $self->{stm}->{history},
        # LTM is now saved separately to .clio/ltm.json (project-level, not session-level)
        yarn    => $self->{yarn}->{threads},
        working_directory => $self->{working_directory},
        created_at => $self->{created_at},  # Preserve session creation timestamp
        lastGitHubCopilotResponseId => $self->{lastGitHubCopilotResponseId},
        _stateful_markers => $self->{_stateful_markers} || [],  # GitHub Copilot session continuation
        billing => $self->{billing},  # Save billing data
        context_files => $self->{context_files} || [],  # Save context files
        selected_model => $self->{selected_model},  # Save currently selected model
        api_config => $self->{api_config} || {},  # Save API config (from /api set --session)
        style => $self->{style},  # Save current color style
        theme => $self->{theme},  # Save current output theme
    };
    use Data::Dumper;
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        log_debug('SessionState', "[STATE][DEBUG] Data to save: " . Dumper($data) . "");
    }
    
    # Ensure session directory exists before writing
    my $dir = File::Basename::dirname($self->{file});
    unless (-d $dir) {
        require File::Path;
        eval { File::Path::make_path($dir) };
        if ($@) {
            warn "[WARN][State] Failed to create session directory: $@";
        }
    }
    
    # Atomic write: write to temp file, then rename
    # This prevents corruption if process is killed during write
    # Use process ID in temp filename to prevent race conditions with multiple agents
    my $temp_file = $self->{file} . '.tmp.' . $$;
    open my $fh, '>', $temp_file or croak "Cannot create temp session file: $!";
    print $fh encode_json($data);
    close $fh;
    
    # Atomic rename (overwrites target file atomically on Unix)
    rename $temp_file, $self->{file} or croak "Cannot save session (rename failed): $!";
}
sub load {
    my ($class, $session_id, %args) = @_;
    my $file = _session_file($session_id);
    log_debug('State::load', "called for session_id: $session_id, file: $file");
    return unless -e $file;
    open my $fh, '<', $file or return;
    local $/; my $json = <$fh>; close $fh;
    my $data = eval { decode_json($json) };
    log_debug('SessionState', "State::load loaded data: " . (defined $data ? 'ok' : 'undef'));
    return unless $data;
    
    # Determine working directory for loading project LTM
    # Use getcwd() for cross-platform compatibility
    # The stored working_directory may be from a different machine (e.g., /Users/... on Linux)
    my $working_dir = getcwd();
    
    # Load project-level LTM from .clio/ltm.json (shared across all sessions)
    my $ltm_file = File::Spec->catfile($working_dir, '.clio', 'ltm.json');
    my $ltm = CLIO::Memory::LongTerm->load($ltm_file, debug => $args{debug});
    
    # Fallback: If old session has ltm->{store} data, migrate it
    if (!-e $ltm_file && $data->{ltm} && ref($data->{ltm}) eq 'HASH') {
        log_info('State', "Migrating legacy LTM data to new format");
        $ltm = CLIO::Memory::LongTerm->new(debug => $args{debug});
        # Convert old store format to discoveries
        for my $key (keys %{$data->{ltm}}) {
            $ltm->add_discovery("$key: $data->{ltm}{$key}", 0.5, 0);
        }
        # Save migrated data
        eval { $ltm->save($ltm_file); };
    }
    
    # Load STM - with migration for corrupted data from old sessions
    my $stm_data = $data->{stm} // [];
    
    # MIGRATION: Clean up corrupted STM entries where role is a hash instead of string
    # Old bug caused: {role => {role => "user", content => "text"}, content => undef}
    # Should be: {role => "user", content => "text"}
    my @cleaned_stm;
    for my $entry (@$stm_data) {
        next unless ref($entry) eq 'HASH';
        
        my $role = $entry->{role};
        my $content = $entry->{content};
        
        # Fix nested role structure
        if (ref($role) eq 'HASH') {
            $content = $role->{content} if defined $role->{content};
            $role = $role->{role} if defined $role->{role};
        }
        
        # Only add if we have valid data
        if (defined $role && !ref($role)) {
            push @cleaned_stm, {
                role => $role,
                content => $content // ''
            };
        }
    }
    
    my $stm  = CLIO::Memory::ShortTerm->new(history => \@cleaned_stm, debug => $args{debug});
    my $yarn = CLIO::Memory::YaRN->new(threads => $data->{yarn} // {}, debug => $args{debug});
    my $self = {
        session_id => $session_id,
        history    => $data->{history} || [],
        debug      => $args{debug} // 0,
        file       => $file,
        stm        => $stm,
        ltm        => $ltm,
        yarn       => $yarn,
        working_directory => $working_dir,
        lastGitHubCopilotResponseId => $data->{lastGitHubCopilotResponseId},
        # Load session creation timestamp (for proper resume ordering)
        created_at => $data->{created_at} // time(),
        # Load billing data or initialize if not present
        billing    => $data->{billing} || {
            total_prompt_tokens => 0,
            total_completion_tokens => 0,
            total_tokens => 0,
            total_requests => 0,
            total_premium_requests => 0,  # GitHub Copilot premium requests charged
            model => undef,
            multiplier => 0,
            requests => [],
        },
        # Load context files or initialize if not present
        context_files => $data->{context_files} || [],
        # Load selected model or default to undef
        selected_model => $data->{selected_model},
        # Load API config (from /api set --session)
        api_config => $data->{api_config} || {},
        # Load theme settings
        style => $data->{style} || 'default',
        theme => $data->{theme} || 'default',
        # Load stateful markers for GitHub Copilot session continuation
        _stateful_markers => $data->{_stateful_markers} || [],
        # Context management configuration
        max_tokens => $args{max_tokens} // 128000,
        summarize_threshold => $args{summarize_threshold} // 102400,
        compression_threshold => $args{compression_threshold} // 51200,
    };
    bless $self, $class;
    
    # Validate and repair conversation history
    # Detect orphaned tool_calls (incomplete tool execution due to interruption)
    my $repaired = $self->_validate_and_repair_history();
    if ($repaired) {
        # Store repair message to be displayed to user as styled system message
        # (instead of raw debug warnings)
        $self->{repair_notification} = $repaired;
    }
    
    log_debug('State::load', "returning self: $self");
    
    # Restore model to ENV if one was saved (so it persists across resume)
    if ($self->{selected_model}) {
        $ENV{OPENAI_MODEL} = $self->{selected_model};
        log_info('State::load', "Restored model from session: $self->{selected_model}");
    }
    
    return $self;
}

# Accessors for memory modules
sub stm  { $_[0]->{stm} }
sub ltm  { $_[0]->{ltm} }
sub yarn { $_[0]->{yarn} }

# Get repair notification if session history was repaired on load
sub repair_notification { $_[0]->{repair_notification} }

=head2 _validate_and_repair_history

Validate conversation history and repair orphaned tool_calls.

When a session is interrupted (e.g., Ctrl-C) during tool execution, the history
may contain assistant messages with tool_calls that don't have matching tool
result messages. This causes API errors on resume.

This method:
1. Scans for all tool_call_ids from assistant messages with tool_calls
2. Collects all tool_call_ids from tool result messages
3. Identifies orphaned tool_calls (those without matching results)
4. Removes the incomplete conversation exchange (user + assistant with orphans)

Returns: 1 if repairs were made, 0 if history was clean

=cut

sub _validate_and_repair_history {
    my ($self) = @_;
    
    return 0 unless $self->{history} && @{$self->{history}};
    
    my @history = @{$self->{history}};
    my %tool_result_ids;  # Track all tool_call_ids that have results
    my %tool_call_ids;    # Track all tool_call_ids from assistant messages
    my %orphan_indices;   # Track message indices that need to be removed
    
    # Pass 1: Collect all tool_call_ids from assistant messages with tool_calls
    for (my $i = 0; $i < @history; $i++) {
        my $msg = $history[$i];
        if ($msg->{role} && $msg->{role} eq 'assistant' && 
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$msg->{tool_calls}}) {
                $tool_call_ids{$tc->{id}} = $i if $tc->{id};
            }
        }
    }
    
    # Pass 2: Collect all tool_call_ids that have matching tool results
    for (my $i = 0; $i < @history; $i++) {
        my $msg = $history[$i];
        if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
            $tool_result_ids{$msg->{tool_call_id}} = $i;
        }
    }
    
    # Pass 3: Find assistant messages with tool_calls that lack complete results
    for (my $i = 0; $i < @history; $i++) {
        my $msg = $history[$i];
        
        # Check assistant messages with tool_calls
        if ($msg->{role} && $msg->{role} eq 'assistant' && 
            $msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
            
            # Check if ALL tool_calls have matching results
            my @missing_ids;
            for my $tc (@{$msg->{tool_calls}}) {
                my $tc_id = $tc->{id};
                next unless $tc_id;
                
                unless ($tool_result_ids{$tc_id}) {
                    push @missing_ids, $tc_id;
                }
            }
            
            # If any tool_calls are missing results, mark this message for removal
            if (@missing_ids) {
                $orphan_indices{$i} = 1;
                
                # Log to debug only (not to user - suppressing raw [WARNING] messages)
                log_debug('SessionState', "Found orphaned tool_calls at index $i: " . join(', ', @missing_ids));
                
                # Also mark the preceding user message (if any) since they form a unit
                if ($i > 0 && $history[$i-1]{role} && $history[$i-1]{role} eq 'user') {
                    $orphan_indices{$i-1} = 1;
                    log_debug('SessionState', "Removing associated user message at index " . ($i-1));
                }
                
                # Also remove any partial tool results for THIS assistant's tool_calls
                # (in case some completed but not all)
                for my $tc (@{$msg->{tool_calls}}) {
                    my $tc_id = $tc->{id};
                    next unless $tc_id;
                    
                    # Find and mark any tool results for this tool_call_id
                    for (my $j = $i + 1; $j < @history; $j++) {
                        if ($history[$j]{role} && $history[$j]{role} eq 'tool' &&
                            $history[$j]{tool_call_id} && 
                            $history[$j]{tool_call_id} eq $tc_id) {
                            $orphan_indices{$j} = 1;
                        }
                    }
                }
            }
        }
    }
    
    # Pass 4: Find orphaned tool_results (tool_results without matching tool_calls)
    # This catches the reverse case: "unexpected tool_use_id found in tool_result blocks"
    for (my $i = 0; $i < @history; $i++) {
        my $msg = $history[$i];
        if ($msg->{role} && $msg->{role} eq 'tool' && $msg->{tool_call_id}) {
            unless (exists $tool_call_ids{$msg->{tool_call_id}}) {
                $orphan_indices{$i} = 1;
                log_debug('SessionState', "Found orphaned tool_result at index $i: " . $msg->{tool_call_id} . " (no matching tool_call)");
            }
        }
    }
    
    # If no orphans found, history is clean
    return 0 unless keys %orphan_indices;
    
    # Pass 5: Rebuild history without orphaned messages
    my @cleaned_history;
    for (my $i = 0; $i < @history; $i++) {
        unless ($orphan_indices{$i}) {
            push @cleaned_history, $history[$i];
        }
    }
    
    my $removed_count = scalar(@history) - scalar(@cleaned_history);
    $self->{history} = \@cleaned_history;
    
    # Log to debug only (not to user - suppressing raw [WARNING] messages)
    log_debug('State', "Removed $removed_count messages with incomplete tool execution");
    
    # Save the repaired session immediately to persist the fix
    eval { $self->save(); };
    if ($@) {
        log_error('State', "Failed to save repaired session: $@");
    }
    
    # Return user-friendly message instead of just 1 (now this message will be displayed)
    return "Session restored. Ready to continue." if $removed_count >= 1;
    
    return 0;  # No repairs were made
}

# Strip out conversation markup
sub strip_conversation_tags {
    my ($text) = @_;
    return $text unless defined $text;
    $text =~ s/\[conversation\](.*?)\[\/conversation\]/$1/gs;
    return $text;
}

sub add_message {
    my ($self, $role, $content, $opts) = @_;
    $content = strip_conversation_tags($content);
    
    # Generate unique turn ID (SAM compatibility)
    my $turn_id = $self->_generate_turn_id();
    
    # Build message with SAM-compatible metadata
    my $message = { 
        role => $role, 
        content => $content,
        id => $turn_id,  # Turn ID for referencing specific messages
        timestamp => strftime("%Y-%m-%dT%H:%M:%SZ", gmtime()),  # ISO 8601 format (SAM compatible)
        metadata => {
            sessionId => $self->{session_id},  # SAM compatibility
            source => $opts->{source} || 'primary',  # Track message origin (primary, subagent, etc.)
            unix_timestamp => time(),  # Keep Unix timestamp for backwards compatibility
        },
    };
    
    # Add tool_calls if provided (for assistant messages with tool execution)
    if ($opts && $opts->{tool_calls}) {
        $message->{tool_calls} = $opts->{tool_calls};
        log_debug('State::add_message', "Added tool_calls to message");
    }
    
    # Add tool_call_id if provided (for tool result messages)
    if ($opts && $opts->{tool_call_id}) {
        $message->{tool_call_id} = $opts->{tool_call_id};
        log_debug('State::add_message', "Added tool_call_id=$opts->{tool_call_id} to message");
    }
    
    # Add provider response ID if available (for assistant messages)
    if ($role eq 'assistant' && $self->{lastGitHubCopilotResponseId}) {
        $message->{metadata}{providerResponseId} = $self->{lastGitHubCopilotResponseId};
    }
    
    # Calculate and tag with importance score
    # Pass the message index so first user message gets special treatment
    my $message_index = scalar(@{$self->{history}});
    $message->{_importance} = $self->calculate_message_importance($message, $message_index);
    
    # DEBUG: Log final message structure
    if (($ENV{CLIO_DEBUG} || $self->{debug}) && $role eq 'tool') {
        log_debug('SessionState', "State::add_message] Final tool message structure: " . "role=$message->{role}, " .
            "has_tool_call_id=" . (exists $message->{tool_call_id} ? 'YES' : 'NO') . ", " .
            "tool_call_id=" . ($message->{tool_call_id} // 'MISSING'));
    }
    
    # Add to active conversation history
    push @{$self->{history}}, $message;
    
    # Store ALL messages in YaRN for persistent recall
    my $thread_id = $self->{session_id};
    $self->{yarn}->create_thread($thread_id) unless $self->{yarn}->get_thread($thread_id);
    $self->{yarn}->add_to_thread($thread_id, $message);
    
    # Aggressively trim context to stay within safe token budget
    # Use percentage-based threshold for model-agnostic operation
    my $current_size = $self->get_conversation_size();
    
    # Dynamic threshold based on max_tokens (model context window):
    # Trim at 58% of max context to provide 42% safety margin
    # This accounts for max response (typically 12-16% of context) and other overhead
    my $max_tokens = $self->{max_tokens} // 128000;  # Default to 128k if not set
    my $trim_threshold = int($max_tokens * 0.58);
    
    if ($current_size > $trim_threshold) {
        if ($ENV{CLIO_DEBUG} || $self->{debug}) {
            log_debug('SessionState', "[STATE] Context size ($current_size tokens) exceeds safe threshold ($trim_threshold of $max_tokens max), trimming...");
        }
        $self->trim_context();
    }
}

# Generate unique turn ID (UUID-like format)
sub _generate_turn_id {
    my ($self) = @_;
    my $uuid = sprintf('%04x%04x-%04x-%04x-%04x-%04x%04x%04x',
        int(rand(0x10000)), int(rand(0x10000)),
        int(rand(0x10000)),
        int(rand(0x10000)) | 0x4000,
        int(rand(0x10000)) | 0x8000,
        int(rand(0x10000)), int(rand(0x10000)), int(rand(0x10000))
    );
    return $uuid;
}

=head2 calculate_message_importance

Calculate importance score for a message.
Higher scores mean message is more important to preserve.

Factors:
- First user message: ALWAYS highest priority (10.0) - this is the original task
- Role: user (1.5x), assistant with tool_calls (2.0x)
- Recency: exponential decay (older = less important) - except first user
- Keywords: error/bug/fix/critical (1.3x)
- Length: log scaling (longer = more detail)

Returns: Importance score (0.0 - 10.0)

=cut

sub calculate_message_importance {
    my ($self, $message, $message_index) = @_;
    
    # The FIRST user message (message index 1, after system) is the original task request
    # It MUST be preserved above all other messages to prevent context loss
    # Without this, GPT-style models lose track of what they were asked to do
    if (defined $message_index && $message_index == 1 && 
        $message->{role} && $message->{role} eq 'user') {
        return 10.0;  # Maximum importance - never truncate
    }
    
    my $score = 1.0;
    
    # Recency factor (exponential decay)
    my $age = $self->message_age($message);
    $score *= exp(-$age / 10);  # Older messages decay
    
    # Role importance
    if ($message->{role} eq 'user') {
        $score *= 1.5;  # User messages always important
    }
    
    if ($message->{role} eq 'assistant' && $message->{tool_calls}) {
        $score *= 2.0;  # Tool calls are important
    }
    
    # Keyword detection
    if (defined $message->{content} && $message->{content} =~ /\b(error|bug|fix|critical|important|decision|warning)\b/i) {
        $score *= 1.3;
    }
    
    # Length indicates detail/importance
    my $length = length($message->{content} // '');
    if ($length > 0) {
        $score *= (1 + log($length) / 10);
    }
    
    return $score;
}

=head2 message_age

Calculate age of message in number of messages since it was added.

=cut

sub message_age {
    my ($self, $message) = @_;
    
    my $total = scalar(@{$self->{history}});
    
    # Find position of this message
    for my $i (0 .. $#{$self->{history}}) {
        if ($self->{history}->[$i] == $message) {
            return $total - $i;
        }
    }
    
    return $total;  # Fallback: treat as oldest
}

=head2 get_conversation_size

Calculate total token count of current conversation history.

Returns: Estimated token count

=cut

sub get_conversation_size {
    my ($self) = @_;
    return CLIO::Memory::TokenEstimator::estimate_messages_tokens($self->{history});
}

=head2 trim_context

Intelligently trim context when approaching token limits.
Preserves: system messages, recent messages (last 10), high-importance messages.
Moves trimmed messages to YaRN for later recall.

Also injects a notification message to inform the agent about what was trimmed
and how to recover the context.

=cut

sub trim_context {
    my ($self) = @_;
    
    my @messages = @{$self->{history}};
    return unless @messages > 15;  # Don't trim very short conversations
    
    # Aggressive trimming strategy:
    # Keep system messages + last 10 messages + some high-importance from middle
    # This targets ~25-30k tokens for conversation (accounting for system prompt ~10-12k)
    
    # Separate message types
    my @system = grep { $_->{role} eq 'system' } @messages;
    
    # Keep last 10 messages (most recent context)
    # This is the core of what agent needs for continuity
    my $keep_recent = 10;
    my @recent = @messages >= $keep_recent ? @messages[-$keep_recent .. -1] : @messages;
    
    # Get messages before the recent set for importance filtering
    my $start_idx = @messages - $keep_recent;
    my @middle = @messages[scalar(@system) .. $start_idx - 1];
    
    # From middle messages, keep only the most important (top 30%)
    # This provides context for earlier parts of conversation
    my @sorted_middle = sort { 
        ($b->{_importance} // 0) <=> ($a->{_importance} // 0) 
    } @middle;
    
    my $keep_important_count = int(@sorted_middle * 0.3);  # Reduced from 0.5 to 0.3
    my @important = @sorted_middle[0 .. $keep_important_count - 1];
    
    # Restore chronological order for important messages
    my %important_indices = map { $_ => 1 } @important;
    @important = grep { $important_indices{$_} } @middle;
    
    # Calculate trimming statistics
    my $before = scalar(@messages);
    my $dropped_count = $before - scalar(@system) - scalar(@important) - scalar(@recent);
    
    # Create trim notification message to inject
    # This informs the agent that context was trimmed and how to recover
    my $trim_notice = {
        role => 'system',
        content => "[CONTEXT TRIM: $dropped_count messages archived]\n" .
                   "Token limit approached. Older messages moved to YaRN archive.\n" .
                   "Recent $keep_recent messages preserved. To recover archived context:\n" .
                   "  memory_operations(operation: 'recall_sessions', query: '...')\n" .
                   "All work preserved in session history file.",
        _importance => 0.5,  # Medium importance - should be retained in next trim
    };
    
    # Reconstruct trimmed history with notification
    # Insert notification after system messages but before important/recent
    my @trimmed = (@system, $trim_notice, @important, @recent);
    
    # Log trimming
    my $after = scalar(@trimmed);
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        use CLIO::Memory::TokenEstimator;
        my $before_tokens = CLIO::Memory::TokenEstimator::estimate_messages_tokens(\@messages);
        my $after_tokens = CLIO::Memory::TokenEstimator::estimate_messages_tokens(\@trimmed);
        log_info('SessionState', "Aggressive trim: $before -> $after messages ($before_tokens -> $after_tokens tokens, " .
                     int(($after_tokens / $before_tokens) * 100) . "% retained)");
        log_debug('SessionState', "[STATE] Trim notification injected - agent notified of archived context");
    }
    
    # Update history (trimmed messages already in YaRN from add_message)
    $self->{history} = \@trimmed;
}

sub get_history {
    my ($self) = @_;
    return $self->{history};
}

sub cleanup {
    my ($self) = @_;
    unlink $self->{file} if -e $self->{file};
}

=head2 record_api_usage

Record API usage for billing tracking with GitHub Copilot multipliers.

Arguments:
- $usage: Hash with prompt_tokens, completion_tokens
- $model: Model name (optional, for multiplier lookup)

=cut

sub record_api_usage {
    my ($self, $usage, $model, $provider) = @_;
    
    return unless $usage && ref($usage) eq 'HASH';
    
    my $prompt_tokens = $usage->{prompt_tokens} || 0;
    my $completion_tokens = $usage->{completion_tokens} || 0;
    my $total_tokens = $usage->{total_tokens} || ($prompt_tokens + $completion_tokens);
    
    # Update session totals
    $self->{billing}{total_prompt_tokens} += $prompt_tokens;
    $self->{billing}{total_completion_tokens} += $completion_tokens;
    $self->{billing}{total_tokens} += $total_tokens;
    $self->{billing}{total_requests}++;
    
    # Track model and fetch multiplier
    my $multiplier = 0;
    if ($model) {
        $self->{billing}{model} = $model;
        
        # Fetch multiplier from GitHub Copilot API if using GitHub Copilot provider
        # No more hardcoded model name patterns!
        if ($provider && $provider eq 'github_copilot') {
            # Strip provider prefix for API lookup: "github_copilot/gpt-4.1" -> "gpt-4.1"
            # But skip if model has a different provider prefix (e.g. openrouter/...)
            my $api_model = $model;
            my $skip_billing = 0;
            require CLIO::Providers;
            if ($api_model =~ m{^([a-z][a-z0-9_.-]*)/(.+)$}i && CLIO::Providers::provider_exists($1)) {
                if ($1 ne 'github_copilot') {
                    # Model is routed to a different provider - skip GH billing lookup
                    $skip_billing = 1;
                }
                $api_model = $2;
            }
            
            unless ($skip_billing) {
                require CLIO::Core::GitHubCopilotModelsAPI;
                my $api = CLIO::Core::GitHubCopilotModelsAPI->new(debug => $self->{debug});
                my $billing_info = $api->get_model_billing($api_model);
                if ($billing_info && defined $billing_info->{multiplier}) {
                    $multiplier = $billing_info->{multiplier};
                    $self->{billing}{multiplier} = $multiplier;
                }
            }
        }
        # For non-GitHub-Copilot providers, multiplier stays 0 (no billing tracking)
    }
    
    # Record individual request with model and multiplier
    push @{$self->{billing}{requests}}, {
        timestamp => time(),
        model => $model || 'unknown',
        multiplier => $multiplier,
        prompt_tokens => $prompt_tokens,
        completion_tokens => $completion_tokens,
        total_tokens => $total_tokens,
    };
    
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        log_debug('SessionState', "Recorded API usage: " . "model=" . ($model || 'unknown') . ", " .
            "multiplier=${multiplier}x, " .
            "tokens=$total_tokens\n");
    }
}

=head2 get_billing_summary

Get a summary of billing usage for this session.

Returns:
- Hash with billing statistics

=cut

sub get_billing_summary {
    my ($self) = @_;
    
    return {
        total_requests => $self->{billing}{total_requests},
        total_premium_requests => $self->{billing}{total_premium_requests} || 0,
        total_prompt_tokens => $self->{billing}{total_prompt_tokens},
        total_completion_tokens => $self->{billing}{total_completion_tokens},
        total_tokens => $self->{billing}{total_tokens},
        requests => $self->{billing}{requests},
    };
}

1;
