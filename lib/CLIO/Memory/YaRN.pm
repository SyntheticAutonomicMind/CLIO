package CLIO::Memory::YaRN;

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::Core::Logger qw(should_log log_debug log_warning);
use CLIO::Util::JSON qw(decode_json);

=head1 NAME

CLIO::Memory::YaRN - Yet another Recurrence Navigation (conversation threading)

=head1 DESCRIPTION

YaRN manages conversation threads for CLIO. Each session has a primary thread
that stores ALL messages for persistent recall, even when messages are trimmed
from active context due to token limits.

This enables:
- Full conversation history retention
- Thread-based recall (searchable via LTM/grep)
- Context preservation across session resumption

=head1 SYNOPSIS

    my $yarn = CLIO::Memory::YaRN->new();
    
    # Create thread for a session
    $yarn->create_thread($session_id);
    
    # Add messages to thread
    $yarn->add_to_thread($session_id, $message_hash);
    
    # Retrieve thread
    my $thread = $yarn->get_thread($session_id);
    
    # List all threads
    my $thread_ids = $yarn->list_threads();
    
    # Get summary
    my $summary = $yarn->summarize_thread($session_id);

=cut

print STDERR "[TRACE] CLIO::Memory::YaRN loaded\n" if should_log('DEBUG');

sub new {
    my ($class, %args) = @_;
    my $self = {
        threads => $args{threads} // {},
        debug => $args{debug} // 0,
    };
    bless $self, $class;
    return $self;
}

=head2 create_thread

Create a new conversation thread.

Arguments:
- $thread_id: Unique identifier for the thread (typically session ID)

=cut

sub create_thread {
    my ($self, $thread_id) = @_;
    
    log_debug('YaRN', "Creating thread: $thread_id");
    $self->{threads}{$thread_id} = [];
}

=head2 add_to_thread

Add a message to an existing thread. Creates thread if it doesn't exist.

Arguments:
- $thread_id: Thread identifier
- $msg: Message hash {role => "user", content => "text", ...}

=cut

sub add_to_thread {
    my ($self, $thread_id, $msg) = @_;
    
    # Auto-create thread if it doesn't exist
    $self->{threads}{$thread_id} ||= [];
    
    # Handle both hashref and JSON string input
    if (defined $msg && !ref $msg && $msg =~ /^\s*\{.*\}\s*$/) {
        eval { $msg = decode_json($msg); };
        if ($@) {
            log_warning('YaRN', "Failed to decode JSON message: $@");
            return;
        }
    }
    
    push @{$self->{threads}{$thread_id}}, $msg;
    
    print STDERR "[DEBUG][YaRN] Added message to thread $thread_id (total: " . 
                 scalar(@{$self->{threads}{$thread_id}}) . " messages)\n" 
        if should_log('DEBUG');
}

=head2 get_thread

Retrieve all messages in a thread.

Arguments:
- $thread_id: Thread identifier

Returns: Array reference of message hashes, or empty array if thread doesn't exist

=cut

sub get_thread {
    my ($self, $thread_id) = @_;
    
    my $thread = $self->{threads}{$thread_id};
    $thread = [] unless defined $thread;
    
    print STDERR "[DEBUG][YaRN] Retrieved thread $thread_id (" . 
                 scalar(@$thread) . " messages)\n" 
        if should_log('DEBUG');
    
    return $thread;
}

=head2 list_threads

Get list of all thread IDs.

Returns: Array reference of thread IDs

=cut

sub list_threads {
    my ($self) = @_;
    my @keys = sort keys %{$self->{threads}};
    
    print STDERR "[DEBUG][YaRN] Listing threads: " . scalar(@keys) . " total\n" 
        if should_log('DEBUG');
    
    return \@keys;
}

=head2 summarize_thread

Get summary of a thread (message count, latest message).

Arguments:
- $thread_id: Thread identifier

Returns: Hashref with thread_id, message_count, latest_message

=cut

sub summarize_thread {
    my ($self, $thread_id) = @_;
    my $thread = $self->get_thread($thread_id);
    return {
        thread_id => $thread_id,
        message_count => scalar(@$thread),
        latest_message => $thread->[-1],
    };
}

=head2 save

Save YaRN threads to file.

Arguments:
- $file: File path to save to

=cut

sub save {
    my ($self, $file) = @_;
    open my $fh, '>', $file or croak "Cannot save YaRN: $!";
    print $fh encode_json($self->{threads});
    close $fh;
}

=head2 load

Load YaRN threads from file.

Arguments:
- $file: File path to load from
- %args: Additional arguments (debug, etc.)

Returns: New YaRN instance with loaded threads

=cut

sub load {
    my ($class, $file, %args) = @_;
    return unless -e $file;
    open my $fh, '<', $file or return;
    local $/; my $json = <$fh>; close $fh;
    my $threads = eval { decode_json($json) };
    return $class->new(threads => $threads, %args);
}

=head2 compress_messages

Compress a sequence of messages into a summary message.

Strategy:
- Extracts key information: user requests, agent actions, tool operations, decisions
- Preserves semantic meaning while reducing token count
- Returns a summary message suitable for injection into conversation

Arguments:
- $messages: Array reference of message hashes to compress
- %opts: Optional parameters
  * original_task: First user message (for context)
  * compression_ratio_target: Desired compression (default 0.2 = 80% reduction)

Returns: Hashref with compressed summary message
{
    role => 'system',
    content => '<compressed summary>',
    _metadata => { compressed_count => N, original_tokens => X, compressed_tokens => Y }
}

=cut

sub compress_messages {
    my ($self, $messages, %opts) = @_;
    
    return undef unless $messages && ref($messages) eq 'ARRAY' && @$messages;
    
    my $original_task = $opts{original_task} || '';
    my $message_count = scalar(@$messages);
    
    log_debug('YaRN', "Compressing $message_count messages");
    
    # Extract key events from the conversation
    my @events = ();
    my @tool_operations = ();
    my @decisions = ();
    my @user_requests = ();
    
    for my $msg (@$messages) {
        my $role = $msg->{role} || '';
        my $content = $msg->{content} || '';
        
        # Extract user requests
        if ($role eq 'user') {
            # Keep user messages concise but preserve intent
            my $summary = substr($content, 0, 200);
            $summary .= '...' if length($content) > 200;
            push @user_requests, $summary;
        }
        
        # Extract agent actions
        elsif ($role eq 'assistant') {
            # Summarize assistant responses
            if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                # Tool invocations
                for my $tc (@{$msg->{tool_calls}}) {
                    my $tool_name = $tc->{function}->{name} || 'unknown';
                    push @tool_operations, "Used $tool_name";
                }
            } elsif (length($content) > 0) {
                # Text responses - extract first sentence or key point
                my $summary = $content;
                if ($summary =~ /^(.{1,150}[.!?])/) {
                    $summary = $1;
                } else {
                    $summary = substr($summary, 0, 150) . '...';
                }
                push @events, "Agent: $summary";
            }
        }
        
        # Extract tool results (keep very brief)
        elsif ($role eq 'tool') {
            # Tool results usually contain data - just note that they completed
            # Don't include actual results (too verbose)
            push @tool_operations, "received result";
        }
    }
    
    # Build compressed summary
    my @summary_parts = ();
    
    # Add compression metadata
    push @summary_parts, "<thread_summary>";
    push @summary_parts, "(Compressed $message_count previous messages to preserve context space)";
    push @summary_parts, "";
    
    # Add original task if provided
    if ($original_task) {
        push @summary_parts, "Original task: $original_task";
        push @summary_parts, "";
    }
    
    # Add user requests
    if (@user_requests) {
        push @summary_parts, "User requests:";
        for my $req (@user_requests) {
            push @summary_parts, "- $req";
        }
        push @summary_parts, "";
    }
    
    # Add tool operations summary
    if (@tool_operations) {
        # Deduplicate and count
        my %tool_counts = ();
        for my $op (@tool_operations) {
            $tool_counts{$op}++;
        }
        
        push @summary_parts, "Tools used:";
        for my $tool (sort keys %tool_counts) {
            my $count = $tool_counts{$tool};
            push @summary_parts, "- $tool" . ($count > 1 ? " ($count times)" : "");
        }
        push @summary_parts, "";
    }
    
    # Add key events
    if (@events) {
        push @summary_parts, "Key events:";
        # Keep only most recent events (up to 5)
        my @recent_events = @events > 5 ? @events[-5..-1] : @events;
        for my $event (@recent_events) {
            push @summary_parts, "- $event";
        }
        push @summary_parts, "";
    }
    
    push @summary_parts, "</thread_summary>";
    
    my $summary_content = join("\n", @summary_parts);
    
    # Estimate tokens (rough approximation: chars / 2.5)
    my $original_tokens = 0;
    for my $msg (@$messages) {
        $original_tokens += int(length($msg->{content} || '') / 2.5);
    }
    my $compressed_tokens = int(length($summary_content) / 2.5);
    
    print STDERR "[DEBUG][YaRN] Compression: $original_tokens tokens -> $compressed_tokens tokens (" . 
        sprintf("%.1f", 100 * ($original_tokens - $compressed_tokens) / $original_tokens) . "% reduction)\n"
        if should_log('DEBUG');
    
    return {
        role => 'system',
        content => $summary_content,
        _metadata => {
            compressed_count => $message_count,
            original_tokens => $original_tokens,
            compressed_tokens => $compressed_tokens,
            compression_ratio => $compressed_tokens / $original_tokens,
        },
    };
}

1;

__END__

=head1 DESIGN NOTES

**Why no summarization?**

Thread summarization was considered but not implemented because:
1. Summarization inherently loses information
2. CLIO already has better alternatives:
   - LTM patterns/discoveries persist important learnings
   - `recall_sessions` searches previous session content
   - Full thread history is preserved on disk in session files
   - Smart context trimming keeps recent messages available

**Better alternatives:**
- Smart re-injection of relevant older messages when context is trimmed
- Thread keyword search via existing grep/search tools
- LTM for cross-session pattern memory

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same terms as Perl itself.

=cut

=head2 compress_messages

Compress a sequence of messages into a summary message.

Strategy:
- Extracts key information: user requests, agent actions, tool operations, decisions
- Preserves semantic meaning while reducing token count
- Returns a summary message suitable for injection into conversation

Arguments:
- $messages: Array reference of message hashes to compress
- %opts: Optional parameters
  * original_task: First user message (for context)
  * compression_ratio_target: Desired compression (default 0.2 = 80% reduction)

Returns: Hashref with compressed summary message
{
    role => 'system',
    content => '<compressed summary>',
    _metadata => { compressed_count => N, original_tokens => X, compressed_tokens => Y }
}

=cut

sub compress_messages {
    my ($self, $messages, %opts) = @_;
    
    return undef unless $messages && ref($messages) eq 'ARRAY' && @$messages;
    
    my $original_task = $opts{original_task} || '';
    my $message_count = scalar(@$messages);
    
    log_debug('YaRN', "Compressing $message_count messages");
    
    # Extract key events from the conversation
    my @events = ();
    my @tool_operations = ();
    my @decisions = ();
    my @user_requests = ();
    
    for my $msg (@$messages) {
        my $role = $msg->{role} || '';
        my $content = $msg->{content} || '';
        
        # Extract user requests
        if ($role eq 'user') {
            # Keep user messages concise but preserve intent
            my $summary = substr($content, 0, 200);
            $summary .= '...' if length($content) > 200;
            push @user_requests, $summary;
        }
        
        # Extract agent actions
        elsif ($role eq 'assistant') {
            # Summarize assistant responses
            if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                # Tool invocations
                for my $tc (@{$msg->{tool_calls}}) {
                    my $tool_name = $tc->{function}->{name} || 'unknown';
                    push @tool_operations, "Used $tool_name";
                }
            } elsif (length($content) > 0) {
                # Text responses - extract first sentence or key point
                my $summary = $content;
                if ($summary =~ /^(.{1,150}[.!?])/) {
                    $summary = $1;
                } else {
                    $summary = substr($summary, 0, 150) . '...';
                }
                push @events, "Agent: $summary";
            }
        }
        
        # Extract tool results (keep very brief)
        elsif ($role eq 'tool') {
            # Tool results usually contain data - just note that they completed
            # Don't include actual results (too verbose)
            push @tool_operations, "received result";
        }
    }
    
    # Build compressed summary
    my @summary_parts = ();
    
    # Add compression metadata
    push @summary_parts, "<thread_summary>";
    push @summary_parts, "(Compressed $message_count previous messages to preserve context space)";
    push @summary_parts, "";
    
    # Add original task if provided
    if ($original_task) {
        push @summary_parts, "Original task: $original_task";
        push @summary_parts, "";
    }
    
    # Add user requests
    if (@user_requests) {
        push @summary_parts, "User requests:";
        for my $req (@user_requests) {
            push @summary_parts, "- $req";
        }
        push @summary_parts, "";
    }
    
    # Add tool operations summary
    if (@tool_operations) {
        # Deduplicate and count
        my %tool_counts = ();
        for my $op (@tool_operations) {
            $tool_counts{$op}++;
        }
        
        push @summary_parts, "Tools used:";
        for my $tool (sort keys %tool_counts) {
            my $count = $tool_counts{$tool};
            push @summary_parts, "- $tool" . ($count > 1 ? " ($count times)" : "");
        }
        push @summary_parts, "";
    }
    
    # Add key events
    if (@events) {
        push @summary_parts, "Key events:";
        # Keep only most recent events (up to 5)
        my @recent_events = @events > 5 ? @events[-5..-1] : @events;
        for my $event (@recent_events) {
            push @summary_parts, "- $event";
        }
        push @summary_parts, "";
    }
    
    push @summary_parts, "</thread_summary>";
    
    my $summary_content = join("\n", @summary_parts);
    
    # Estimate tokens (rough approximation: chars / 2.5)
    my $original_tokens = 0;
    for my $msg (@$messages) {
        $original_tokens += int(length($msg->{content} || '') / 2.5);
    }
    my $compressed_tokens = int(length($summary_content) / 2.5);
    
    print STDERR "[DEBUG][YaRN] Compression: $original_tokens tokens -> $compressed_tokens tokens (" . 
        sprintf("%.1f", 100 * ($original_tokens - $compressed_tokens) / $original_tokens) . "% reduction)\n"
        if should_log('DEBUG');
    
    return {
        role => 'system',
        content => $summary_content,
        _metadata => {
            compressed_count => $message_count,
            original_tokens => $original_tokens,
            compressed_tokens => $compressed_tokens,
            compression_ratio => $compressed_tokens / $original_tokens,
        },
    };
}

1;
