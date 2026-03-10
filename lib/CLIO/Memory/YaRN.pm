# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Memory::YaRN;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug log_warning);
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

log_debug('YaRN', "CLIO::Memory::YaRN loaded");

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
    
    log_debug('YaRN', "Added message to thread $thread_id (total: " . scalar(@{$self->{threads}{$thread_id}}) . " messages)");
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
    
    log_debug('YaRN', "Retrieved thread $thread_id (" . scalar(@$thread) . " messages)");
    
    return $thread;
}

=head2 list_threads

Get list of all thread IDs.

Returns: Array reference of thread IDs

=cut

sub list_threads {
    my ($self) = @_;
    my @keys = sort keys %{$self->{threads}};
    
    log_debug('YaRN', "Listing threads: " . scalar(@keys) . " total");
    
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
    my $previous_summary = $opts{previous_summary} || '';
    my $message_count = scalar(@$messages);

    log_debug('YaRN', "Compressing $message_count messages");

    # Extraction buckets
    my @user_requests;
    my @commits;
    my @files_touched;
    my @decisions;
    my @collaboration_exchanges;  # Agent question + user response pairs
    my %tool_counts;

    # Track collaboration tool_call IDs so we can pair them with responses
    my %collab_tool_calls;  # tool_call_id => agent's question text

    # Seed buckets from previous summary so accumulated history isn't lost across trim cycles
    if ($previous_summary) {
        _parse_previous_summary($previous_summary, {
            commits       => \@commits,
            files_touched => \@files_touched,
            decisions     => \@decisions,
            tool_counts   => \%tool_counts,
        });
    }

    for my $msg (@$messages) {
        my $role    = $msg->{role}    || '';
        my $content = $msg->{content} || '';

        if ($role eq 'user') {
            my $summary = substr($content, 0, 300);
            $summary .= '...' if length($content) > 300;
            push @user_requests, $summary;
        }
        elsif ($role eq 'assistant') {
            # Collaboration/decision messages (from session add_message)
            if ($content =~ /\[COLLABORATION\](.{1,300})/s) {
                my $dec = $1;
                $dec =~ s/\s+/ /g;
                push @decisions, substr($dec, 0, 250);
            }

            # Tool calls - extract meaningful path/operation details
            if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                for my $tc (@{$msg->{tool_calls}}) {
                    my $name     = $tc->{function}{name}      || 'unknown';
                    my $args_str = $tc->{function}{arguments} || '{}';
                    $tool_counts{$name}++;

                    # Track user_collaboration calls to pair with responses
                    if ($name eq 'user_collaboration' && $tc->{id}) {
                        my $question = '';
                        if ($args_str =~ /"message"\s*:\s*"((?:[^"\\]|\\.)*)"/s) {
                            $question = $1;
                            $question =~ s/\\n/\n/g;
                            $question =~ s/\\"/"/g;
                            $question =~ s/\\\\/\\/g;
                        }
                        $collab_tool_calls{$tc->{id}} = $question;
                    }

                    # Capture file paths for file_operations and apply_patch
                    if ($name =~ /^(file_operations|apply_patch)$/) {
                        while ($args_str =~ /"(?:path|new_path|old_path)"\s*:\s*"([^"]+)"/g) {
                            push @files_touched, $1 unless $1 =~ /^\./;
                        }
                    }
                }
            }
        }
        elsif ($role eq 'tool') {
            # Pair collaboration responses with their questions
            if ($msg->{tool_call_id} && exists $collab_tool_calls{$msg->{tool_call_id}}) {
                my $question = $collab_tool_calls{$msg->{tool_call_id}};
                my $response = $content;
                # Keep more content for collaboration exchanges (1000 chars each)
                $question = substr($question, 0, 1000) . '...' if length($question) > 1000;
                $response = substr($response, 0, 1000) . '...' if length($response) > 1000;
                push @collaboration_exchanges, {
                    question => $question,
                    response => $response,
                };
                delete $collab_tool_calls{$msg->{tool_call_id}};
            }

            # Git commit results: [abc1234] Commit subject line
            while ($content =~ /^\[([a-f0-9]{7,12})\]\s+(.{1,100})/mg) {
                push @commits, "$1: $2";
            }
            # git log --oneline output
            while ($content =~ /^([a-f0-9]{7,12})\s+(.{1,100})/mg) {
                my $entry = "$1: $2";
                push @commits, $entry unless grep { $_ eq $entry } @commits;
            }
        }
    }

    # Deduplicate and limit
    my %seen;
    @files_touched = grep { !$seen{$_}++ } @files_touched;
    @files_touched = @files_touched[0..29] if @files_touched > 30;
    @commits       = do { my %s; grep { !$s{$_}++ } reverse @commits };
    @commits       = @commits[0..14] if @commits > 15;
    @user_requests = @user_requests[-5..-1] if @user_requests > 5;
    @decisions     = @decisions[-3..-1]     if @decisions > 3;
    # Keep last 5 collaboration exchanges (most recent are most relevant)
    @collaboration_exchanges = @collaboration_exchanges[-5..-1]
        if @collaboration_exchanges > 5;

    # Build summary
    my @parts;
    push @parts, "<thread_summary>";
    push @parts, "(Compressed $message_count messages to free context space)";
    push @parts, "";

    if ($original_task) {
        push @parts, "Original task: " . substr($original_task, 0, 300);
        push @parts, "";
    }

    # Collaboration exchanges go FIRST - they represent active design discussions
    # that the agent was in the middle of when context was trimmed
    if (@collaboration_exchanges) {
        push @parts, "Active discussion (agent-user collaboration exchanges):";
        for my $i (0..$#collaboration_exchanges) {
            my $ex = $collaboration_exchanges[$i];
            push @parts, "  Agent asked: " . $ex->{question};
            push @parts, "  User replied: " . $ex->{response};
            push @parts, "" if $i < $#collaboration_exchanges;
        }
        push @parts, "";
    }

    if (@user_requests) {
        push @parts, "Recent user requests:";
        push @parts, "- $_" for @user_requests;
        push @parts, "";
    }

    if (@commits) {
        push @parts, "Git commits made during compressed period:";
        push @parts, "- $_" for @commits;
        push @parts, "";
    }

    if (@files_touched) {
        push @parts, "Files created/modified:";
        push @parts, "- $_" for @files_touched;
        push @parts, "";
    }

    if (@decisions) {
        push @parts, "Key decisions:";
        push @parts, "- $_" for @decisions;
        push @parts, "";
    }

    if (%tool_counts) {
        push @parts, "Tool usage:";
        for my $t (sort { $tool_counts{$b} <=> $tool_counts{$a} } keys %tool_counts) {
            push @parts, "- $t: $tool_counts{$t} calls";
        }
        push @parts, "";
    }

    push @parts, "</thread_summary>";

    my $summary_content = join("\n", @parts);

    # Estimate token counts
    my $original_tokens = 0;
    for my $msg (@$messages) {
        $original_tokens += int(length($msg->{content} || '') / 2.5);
    }
    my $compressed_tokens = int(length($summary_content) / 2.5);

    if ($original_tokens > 0) {
        log_debug('YaRN', "Compression: $original_tokens -> $compressed_tokens tokens (" .
            sprintf("%.1f", 100 * ($original_tokens - $compressed_tokens) / $original_tokens) . "% reduction)");
    }

    return {
        role    => 'system',
        content => $summary_content,
        _metadata => {
            compressed_count   => $message_count,
            original_tokens    => $original_tokens,
            compressed_tokens  => $compressed_tokens,
            compression_ratio  => $original_tokens > 0
                ? $compressed_tokens / $original_tokens : 0,
        },
    };
}

# Parse structured sections from a previous thread_summary to seed extraction buckets.
# This preserves accumulated history across multiple trim cycles.
sub _parse_previous_summary {
    my ($summary_text, $buckets) = @_;
    
    return unless $summary_text && $buckets;
    
    # Strip thread_summary tags
    $summary_text =~ s/<\/?thread_summary>//g;
    
    my $commits       = $buckets->{commits}       || [];
    my $files_touched = $buckets->{files_touched}  || [];
    my $decisions     = $buckets->{decisions}       || [];
    my $tool_counts   = $buckets->{tool_counts}     || {};
    
    # Parse git commits: lines starting with "- " under "Git commits" section
    if ($summary_text =~ /Git commits.*?:\n((?:- .+\n)+)/s) {
        my $block = $1;
        while ($block =~ /^- (.+)$/mg) {
            push @$commits, $1;
        }
    }
    
    # Parse files: lines starting with "- " under "Files created/modified" section
    if ($summary_text =~ /Files created\/modified:\n((?:- .+\n)+)/s) {
        my $block = $1;
        while ($block =~ /^- (.+)$/mg) {
            push @$files_touched, $1;
        }
    }
    
    # Parse decisions: lines starting with "- " under "Key decisions" section
    if ($summary_text =~ /Key decisions:\n((?:- .+\n)+)/s) {
        my $block = $1;
        while ($block =~ /^- (.+)$/mg) {
            push @$decisions, $1;
        }
    }
    
    # Parse tool usage: lines like "- tool_name: N calls"
    if ($summary_text =~ /Tool usage:\n((?:- .+\n)+)/s) {
        my $block = $1;
        while ($block =~ /^- ([^:]+):\s*(\d+)\s*calls?$/mg) {
            $tool_counts->{$1} = ($tool_counts->{$1} || 0) + $2;
        }
    }
    
    my $parsed_items = scalar(@$commits) + scalar(@$files_touched) + scalar(@$decisions) + scalar(keys %$tool_counts);
    log_debug('YaRN', "Parsed $parsed_items items from previous summary") if $parsed_items;
}

1;

__END__

=head1 DESIGN NOTES

**Context Recovery via Compression:**

YaRN's C<compress_messages()> is used in two places:
1. B<MessageValidator> (proactive): Creates summaries when pre-trimming before API calls
2. B<WorkflowOrchestrator> (reactive): Creates summaries when reactive trimming after
   token limit exceeded errors

Both paths produce a C<< <thread_summary> >> block that preserves:
- User requests (summarized)
- Tool operations (deduplicated with counts)
- Key agent events (last 5)

The reactive path additionally injects:
- Current todo/task state (C<< <task_recovery> >> block)
- Most recent user requests from dropped messages (C<< <recent_context> >> block)

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut
