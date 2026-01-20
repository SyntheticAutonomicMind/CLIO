if ($ENV{CLIO_DEBUG}) {
    print STDERR "[TRACE] CLIO::Session::State loaded\n";
}
package CLIO::Session::State;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use CLIO::Util::PathResolver;
use File::Spec;
use JSON::PP;
use Cwd qw(getcwd abs_path);
use POSIX qw(strftime);
use CLIO::Memory::ShortTerm;
use CLIO::Memory::LongTerm;
use CLIO::Memory::YaRN;
use CLIO::Memory::TokenEstimator;

sub new {
    my ($class, %args) = @_;
    if ($ENV{CLIO_DEBUG} || $args{debug}) {
        print STDERR "[DEBUG][State::new] called with args: ", join(", ", map { "$_=$args{$_}" } keys %args), "\n";
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
        print STDERR "[STATE] yarn object ref: $self->{yarn}\n";
        print STDERR "[DEBUG][State::new] returning self: $self\n";
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
    open my $fh, '>', $self->{file} or die "Cannot save session: $!";
    my $data = {
        history => $self->{history},
        stm     => $self->{stm}->{history},
        ltm     => $self->{ltm}->{store},
        yarn    => $self->{yarn}->{threads},
        working_directory => $self->{working_directory},
        created_at => $self->{created_at},  # Preserve session creation timestamp
        lastGitHubCopilotResponseId => $self->{lastGitHubCopilotResponseId},
        _stateful_markers => $self->{_stateful_markers} || [],  # GitHub Copilot session continuation
        billing => $self->{billing},  # Save billing data
        context_files => $self->{context_files} || [],  # Save context files
        selected_model => $self->{selected_model},  # Save currently selected model
        style => $self->{style},  # Save current color style
        theme => $self->{theme},  # Save current output theme
    };
    use Data::Dumper;
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        print STDERR "[STATE][DEBUG] Data to save: " . Dumper($data) . "\n";
    }
    print $fh encode_json($data);
    close $fh;
}
sub load {
    my ($class, $session_id, %args) = @_;
    my $file = _session_file($session_id);
    print STDERR "[DEBUG][State::load] called for session_id: $session_id, file: $file\n" if $args{debug} || $ENV{CLIO_DEBUG};
    return unless -e $file;
    open my $fh, '<', $file or return;
    local $/; my $json = <$fh>; close $fh;
    my $data = eval { decode_json($json) };
    print STDERR "[DEBUG][State::load] loaded data: ", (defined $data ? 'ok' : 'undef'), "\n" if $args{debug} || $ENV{CLIO_DEBUG};
    return unless $data;
    my $stm  = CLIO::Memory::ShortTerm->new(history => $data->{stm} // [], debug => $args{debug});
    my $ltm  = CLIO::Memory::LongTerm->new(store => $data->{ltm} // {}, debug => $args{debug});
    my $yarn = CLIO::Memory::YaRN->new(threads => $data->{yarn} // {}, debug => $args{debug});
    my $self = {
        session_id => $session_id,
        history    => $data->{history} || [],
        debug      => $args{debug} // 0,
        file       => $file,
        stm        => $stm,
        ltm        => $ltm,
        yarn       => $yarn,
        working_directory => $data->{working_directory} || getcwd(),
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
    print STDERR "[DEBUG][State::load] returning self: $self\n" if $args{debug} || $ENV{CLIO_DEBUG};
    
    # Restore model to ENV if one was saved (so it persists across resume)
    if ($self->{selected_model}) {
        $ENV{OPENAI_MODEL} = $self->{selected_model};
        print STDERR "[INFO][State::load] Restored model from session: $self->{selected_model}\n" if $args{debug} || $ENV{CLIO_DEBUG};
    }
    
    return $self;
}

# Accessors for memory modules
sub stm  { $_[0]->{stm} }
sub ltm  { $_[0]->{ltm} }
sub yarn { $_[0]->{yarn} }

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
    
    # Add provider response ID if available (for assistant messages)
    if ($role eq 'assistant' && $self->{lastGitHubCopilotResponseId}) {
        $message->{metadata}{providerResponseId} = $self->{lastGitHubCopilotResponseId};
    }
    
    # Calculate and tag with importance score
    $message->{_importance} = $self->calculate_message_importance($message);
    
    # Add to active conversation history
    push @{$self->{history}}, $message;
    
    # Store ALL messages in YaRN for persistent recall
    my $thread_id = $self->{session_id};
    $self->{yarn}->create_thread($thread_id) unless $self->{yarn}->get_thread($thread_id);
    $self->{yarn}->add_to_thread($thread_id, $message);
    
    # Check if context trimming needed
    my $current_size = $self->get_conversation_size();
    if ($current_size > $self->{summarize_threshold}) {
        if ($ENV{CLIO_DEBUG} || $self->{debug}) {
            print STDERR "[STATE] Context size ($current_size tokens) exceeds threshold ($self->{summarize_threshold}), trimming...\n";
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
- Role: user (1.5x), assistant with tool_calls (2.0x)
- Recency: exponential decay (older = less important)
- Keywords: error/bug/fix/critical (1.3x)
- Length: log scaling (longer = more detail)

Returns: Importance score (0.0 - 10.0)

=cut

sub calculate_message_importance {
    my ($self, $message) = @_;
    
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
Preserves: system messages, recent messages (last 20), high-importance messages.
Moves trimmed messages to YaRN for later recall.

=cut

sub trim_context {
    my ($self) = @_;
    
    my @messages = @{$self->{history}};
    return unless @messages > 15;  # Don't trim very short conversations
    
    # Separate message types
    my @system = grep { $_->{role} eq 'system' } @messages;
    my @recent = @messages[-20 .. -1];  # Keep last 20 messages
    
    # Get middle messages to analyze
    my $recent_start = @messages - 20;
    my @middle = @messages[scalar(@system) .. $recent_start - 1];
    
    # Sort by importance, keep top 50%
    my @sorted = sort { ($b->{_importance} // 0) <=> ($a->{_importance} // 0) } @middle;
    my $keep_count = int(@sorted * 0.5);
    my @important = @sorted[0 .. $keep_count - 1];
    
    # Restore chronological order for important messages
    my %important_ids = map { $_ => 1 } @important;
    @important = grep { $important_ids{$_} } @middle;
    
    # Reconstruct trimmed history
    my @trimmed = (@system, @important, @recent);
    
    # Log trimming
    my $before = scalar(@messages);
    my $after = scalar(@trimmed);
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        print STDERR "[STATE] Trimmed context: $before -> $after messages (" . 
                     int(($after / $before) * 100) . "% retained)\n";
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
            # Fetch multiplier from GitHub Copilot API
            require CLIO::Core::GitHubCopilotModelsAPI;
            my $api = CLIO::Core::GitHubCopilotModelsAPI->new(debug => $self->{debug});
            my $billing_info = $api->get_model_billing($model);
            if ($billing_info && defined $billing_info->{multiplier}) {
                $multiplier = $billing_info->{multiplier};
                $self->{billing}{multiplier} = $multiplier;
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
        print STDERR "[DEBUG][State] Recorded API usage: " .
            "model=" . ($model || 'unknown') . ", " .
            "multiplier=${multiplier}x, " .
            "tokens=$total_tokens\n";
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
