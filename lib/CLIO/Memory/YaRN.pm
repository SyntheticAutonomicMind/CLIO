package CLIO::Memory::YaRN;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use JSON::PP;

=head1 NAME

CLIO::Memory::YaRN - Yet another Recurrence Navigation (conversation threading)

=head1 DESCRIPTION

YaRN manages conversation threads for CLIO. Each session has a primary thread
that stores ALL messages for persistent recall, even when messages are trimmed
from active context due to token limits.

This enables:
- Full conversation history retention
- Thread-based recall (future: semantic search)
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
    
    print STDERR "[DEBUG][YaRN] Creating thread: $thread_id\n" if should_log('DEBUG');
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
        eval { $msg = JSON::PP::decode_json($msg); };
        if ($@) {
            print STDERR "[WARN][YaRN] Failed to decode JSON message: $@\n" if should_log('WARNING');
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
    open my $fh, '>', $file or die "Cannot save YaRN: $!";
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

1;

__END__

=head1 FUTURE ENHANCEMENTS

- Semantic search within threads using embeddings
- Thread summarization for long conversations
- Cross-thread pattern detection
- Importance-based thread pruning

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same terms as Perl itself.

=cut

1;
