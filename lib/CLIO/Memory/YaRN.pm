# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Memory::YaRN;

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug log_warning);
use CLIO::Util::JSON qw(decode_json encode_json safe_encode_json safe_decode_json);

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

C<save()> writes the C<threads> hash to a file as JSON. C<load()> reads it back.
Both are exercised by tests/unit/test_yarn_save_carryover.pl. In production,
YaRN state piggybacks on C<Session::State>'s atomic save rather than being
written independently.

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
            log_debug('YaRN', "Failed to decode JSON message: $@");
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
    my $json = safe_encode_json($self->{threads});
    croak "Cannot serialize YaRN threads" unless defined $json;
    print $fh $json;
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
    my $threads = safe_decode_json($json);
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
  * original_task: Most recent user message (for current task context)
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

    # Track collaboration tool_call IDs so we can pair them with responses
    my %collab_tool_calls;  # tool_call_id => agent's question text

    # Seed buckets from previous summary so accumulated history isn't lost across trim cycles
    if ($previous_summary) {
        _parse_previous_summary($previous_summary, {
            commits                 => \@commits,
            files_touched           => \@files_touched,
            decisions               => \@decisions,
            user_requests           => \@user_requests,
            collaboration_exchanges => \@collaboration_exchanges,
        });
    }

    # If previous summary had a preserved original request, carry it forward.
    # The carryover is intentionally bounded and anchored to the literal
    # "- [original] " marker so a body line that happens to mention
    # "[original]" elsewhere in the conversation does not get adopted as
    # the original task. The capture stops at the next newline to avoid
    # swallowing subsequent bullets/sections across section boundaries.
    if ($previous_summary =~ /^- \[original\] ([^\n]{1,300})$/m) {
        $opts{_carried_original} = $1;
    } elsif ($previous_summary =~ /^- \[original\] ([^\n]{1,300})/) {
        # Fall back to first-line match if the marker is not at column 0
        # (legacy summaries may have leading whitespace).
        $opts{_carried_original} = $1;
    }
    # If previous summary had a Current task, carry it forward. Anchored
    # to the line so a stray "Current task:" string elsewhere (e.g. in a
    # file path or commit message body) does not get adopted. Newlines
    # are not matched (. in default mode), so the capture is bounded to
    # a single line.
    if ($previous_summary =~ /^Current task: (.{1,300})$/m) {
        my $prev_task = $1;
        $prev_task =~ s/\s+$//;
        if (!$original_task || length($original_task) < 50) {
            $opts{_carried_task} = $prev_task;
        }
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
            # Collaboration/decision messages (identified by metadata or legacy text prefix)
            my $collab_type = $msg->{metadata} && $msg->{metadata}{collaboration};
            if ($collab_type) {
                # Modern: collaboration metadata on message
                my $dec = substr($content, 0, 300);
                $dec =~ s/\s+/ /g;
                push @decisions, substr($dec, 0, 250);
            } elsif ($content =~ /\[COLLABORATION\](.{1,300})/s) {
                # Legacy: [COLLABORATION] text prefix (backward compat)
                my $dec = $1;
                $dec =~ s/\s+/ /g;
                push @decisions, substr($dec, 0, 250);
            }

            # Tool calls - extract meaningful path/operation details
            if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                for my $tc (@{$msg->{tool_calls}}) {
                    my $name     = $tc->{function}{name}      || 'unknown';
                    my $args_str = $tc->{function}{arguments} || '{}';

                    # Track interact calls to pair with responses
                    if ($name eq 'interact' && $tc->{id}) {
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

    # Deduplicate and limit. Files are deduped as encountered and capped at
    # 30. Commits are deduped keeping the most recent occurrence (the body
    # order is preserved so reverse() ensures last-wins, then we cap at 15).
    my %seen;
    @files_touched = grep { !$seen{$_}++ } @files_touched;
    @files_touched = @files_touched[0..29] if @files_touched > 30;
    @commits       = do { my %s; grep { !$s{$_}++ } reverse @commits };
    @commits       = @commits[0..14] if @commits > 15;
    @decisions     = @decisions[-3..-1]     if @decisions > 3;
    @collaboration_exchanges = @collaboration_exchanges[-5..-1]
        if @collaboration_exchanges > 5;

    # Always preserve the FIRST user request (the original session task).
    # When trimming to last N, we risk losing the original task context
    # that started the session. Keep it separately if we have many requests.
    my $first_user_request;
    if (@user_requests > 8) {
        $first_user_request = $user_requests[0];
        @user_requests = @user_requests[-7..-1];
    }
    # Use carried original from previous summary if available (survives cycles)
    if ($opts{_carried_original}) {
        my $carried = $opts{_carried_original};
        unless (grep { $_ eq $carried } @user_requests) {
            $first_user_request = $carried unless $first_user_request;
        }
    }
    # Cap at 8 total (up from 5)

    # Find a substantive task description. Short confirmations like "yes" or
    # "go ahead" are useless as task context - scan user_requests for better.
    # Prefer a carried task from previous summary over the caller's original_task
    # (which is often the most recent user message, not the real task).
    my @all_requests = @user_requests;
    unshift @all_requests, $first_user_request if $first_user_request;
    my $effective_task = find_substantive_task(
        $opts{_carried_task} || $original_task,
        \@all_requests
    );

    # Build summary — minimal, byte-stable, and useful.
    # Only the original task and recent user requests are preserved.
    # NO commits, files, decisions, or collaboration exchanges: these
    # are statistical noise that changes every turn and busts KV cache
    # of the stable message prefix. The compressed_tail lives in the
    # dynamic UC system message (which is non-stable by design), so
    # any per-turn content is acceptable there — but we keep it lean.
    my @parts;
    push @parts, "<thread_summary>";
    push @parts, "";

    if ($effective_task) {
        push @parts, "Current task: " . substr($effective_task, 0, 300);
        push @parts, "";
    }

    if (@user_requests || $first_user_request) {
        push @parts, "Recent user requests:";
        # Include original request first if it was preserved separately
        if ($first_user_request && !grep { $_ eq $first_user_request } @user_requests) {
            push @parts, "- [original] $first_user_request";
        }
        push @parts, "- $_" for @user_requests;
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

=head2 find_substantive_task

Class method. Given a candidate task string and a source of user messages,
returns a substantive task description (>= 50 chars). Falls back to the
candidate if no better option is found.

The messages parameter accepts either:
- An arrayref of message hashes ({role => 'user', content => '...'})
- An arrayref of plain strings (treated as user messages)

    my $task = CLIO::Memory::YaRN::find_substantive_task($candidate, \@messages);

=cut

sub find_substantive_task {
    my ($candidate, $messages) = @_;
    my $min_len = 50;

    return $candidate if $candidate && length($candidate) >= $min_len;

    # Scan messages newest-first for a substantive user message
    if ($messages && ref($messages) eq 'ARRAY') {
        for my $item (reverse @$messages) {
            if (ref($item) eq 'HASH') {
                next unless ($item->{role} || '') eq 'user';
                my $content = $item->{content} || '';
                return $content if length($content) >= $min_len;
            } else {
                # Plain string (e.g. from @user_requests)
                return $item if defined $item && length($item) >= $min_len;
            }
        }
    }

    # No substantive message found - return whatever we have
    return $candidate || '';
}

=head2 recover_substantive_task

Class method. Anchor-recovery fallback for CLIO::Core::ContextBuilder
when the source history has been trimmed past the original user task.
Walks the session's durable YaRN thread (which is never trimmed) and
returns the oldest substantive user message found.

Arguments:
- $session_or_yarn: Either a session object (with ->yarn accessor)
                    or a YaRN instance directly. If undef, returns ''.
- $thread_id: The thread ID to query (usually the session ID).
              If undef and $session_or_yarn is a session, falls back
              to $session->id().

Returns:
- Scalar: the original user task (>= 50 chars), or '' if nothing is
  recoverable from the durable thread.

The returned string is suitable for use as a synthetic anchor in a
projection when no live history is available. The ContextBuilder
turns it into a one-message synthetic turn (a role:user message) so
the model still sees the original task.

=cut

sub recover_substantive_task {
    my ($session_or_yarn, $thread_id) = @_;
    return '' unless $session_or_yarn;

    my $yarn;
    if (ref($session_or_yarn) && $session_or_yarn->isa('CLIO::Memory::YaRN')) {
        $yarn = $session_or_yarn;
        $thread_id //= $ENV{CLIO_SESSION_ID} // '';
    } else {
        return '' unless $session_or_yarn->can('yarn');
        $yarn = $session_or_yarn->yarn;
        $thread_id //= ($session_or_yarn->can('id') ? $session_or_yarn->id() : ($ENV{CLIO_SESSION_ID} // ''));
    }
    return '' unless $yarn && ref($yarn) && $yarn->can('get_thread');

    my $thread = $yarn->get_thread($thread_id);
    return '' unless $thread && ref($thread) eq 'ARRAY' && @$thread;

    # Walk oldest-first looking for a substantive user message.
    # YaRN stores the full message history of the session in this
    # thread, so even messages that got trimmed out of state->{history}
    # are still here.
    my $min_len = 50;
    for my $item (@$thread) {
        next unless ref($item) eq 'HASH';
        next unless ($item->{role} // '') eq 'user';
        my $content = $item->{content} // '';
        return $content if length($content) >= $min_len;
    }

    # Fall back to whatever user message we have, even if short.
    for my $item (@$thread) {
        next unless ref($item) eq 'HASH';
        next unless ($item->{role} // '') eq 'user';
        my $content = $item->{content} // '';
        return $content if length $content;
    }

    return '';
}

# Parse structured sections from a previous thread_summary to seed extraction buckets.
# This preserves accumulated history across multiple trim cycles.
sub _parse_previous_summary {
    my ($summary_text, $buckets) = @_;
    
    return unless $summary_text && $buckets;
    
    # Strip thread_summary tags
    $summary_text =~ s/<\/?thread_summary>//g;
    
    my $user_requests = $buckets->{user_requests} || [];
    
    if ($summary_text =~ /(?:^|\n)Recent user requests:\n((?:- [^\n]+\n)+)/) {
        my $block = $1;
        while ($block =~ /^- (?:\[original\] )?([^\n]+)$/mg) {
            push @$user_requests, $1;
        }
    }
}

=head2 compress_for_context_recovery

Unified entry point for all context compression paths (proactive trim,
session trim, recovery, projection). Extracts the most recent
C<< <thread_summary> >> block from the message array — if present —
and passes it as C<previous_summary> to L</compress_messages>, enabling
cross-cycle carryover.

The caller should pass the messages that are being compressed (the
"dropped" set). If those messages include a prior thread_summary
system message, its content is harvested for carryover and the message
itself is filtered out before compression so it is not double-counted.

Arguments:
- C<$messages> : ArrayRef of message hashes to compress
- C<%opts>      : Optional parameters
  * C<original_task>   : Most recent user message text (for current task context)
  * C<previous_summary>: Pre-extracted summary text. When provided,
    overrides the internal scan. Callers use this when the summary
    lives in the *kept* (non-dropped) set.

Returns: Hashref as from L</compress_messages>

    my $result = $yarn->compress_for_context_recovery(\@dropped, original_task => $task);

=cut

sub compress_for_context_recovery {
    my ($self, $messages, %opts) = @_;

    return unless $messages && ref($messages) eq 'ARRAY' && @$messages;

    # Extract previous_summary — prefer an explicit opt, otherwise
    # scan the message array for system messages containing a
    # <thread_summary> block.
    my $previous_summary = $opts{previous_summary};
    unless (defined $previous_summary && length $previous_summary) {
        $previous_summary = $self->_extract_thread_summary_from_messages($messages);
    }

    # Filter out old thread_summary system messages so they are not
    # processed as regular content during compression (system messages
    # are skipped by compress_messages' role loop anyway, but filtering
    # avoids inflating the compressed_count / token estimate).
    my @compress_msgs = grep {
        my $m = $_;
        !(ref($m) eq 'HASH'
          && ($m->{role} // '') eq 'system'
          && ($m->{content} // '') =~ /<thread_summary>/);
    } @$messages;

    return $self->compress_messages(\@compress_msgs,
        previous_summary => $previous_summary,
        original_task    => $opts{original_task} || '',
    );
}

=head2 _extract_thread_summary_from_messages (Internal)

Scan a message array (newest-last) in reverse for system messages
whose content contains a C<< <thread_summary> >> block. Returns the
content of the most recent such block (including the tags), or an
empty string when none is found.

This is the carryover mechanism that lets C<compress_for_context_recovery>
find a summary injected by a previous trim cycle — even when the
summary lives in the "dropped" set that was passed in for compression.

=cut

sub _extract_thread_summary_from_messages {
    my ($self, $messages) = @_;

    return '' unless $messages && ref($messages) eq 'ARRAY';

    for my $msg (reverse @$messages) {
        next unless ref($msg) eq 'HASH';
        next unless ($msg->{role} // '') eq 'system';
        my $content = $msg->{content} || '';
        if ($content =~ /<thread_summary>.*?<\/thread_summary>/s) {
            return $content;
        }
    }
    return '';
}

1;

__END__

=head1 DESIGN NOTES

**Context Recovery via Compression:**

C<compress_for_context_recovery()> is the unified entry point used by all
compression paths:
1. B<MessageValidator> (proactive): C<_role_based_tail_walk> compresses
   dropped messages before an API call when the projected payload exceeds
   the token budget.
2. B<State> (session trim): C<trim_context> compresses the dropped tail
   when the session exceeds its hard message limit.
3. B<WorkflowOrchestrator> (reactive): C<_compress_dropped_for_recovery>
   compresses dropped messages after a token-limit error from the provider.

All paths produce a single C<< <thread_summary> >> system message (the
compression format marker) that preserves:
- User requests (summarized; the first/original request kept as
  C<<- [original] >>)
- Tool operations (deduplicated with counts)
- Commits (deduped, most recent kept, capped at 15)
- Files touched (deduped, capped at 30)
- Key decisions (last 3)
- Active discussion turns (last 5 Q/A pairs, if any)

Cross-cycle carryover: C<compress_for_context_recovery> extracts the most
recent C<< <thread_summary> >> block from the message array (via
C<_extract_thread_summary_from_messages>) and feeds it as C<previous_summary>
to C<compress_messages>, so accumulated summaries survive successive trim
cycles instead of being reset each time. Old summary blocks are filtered
out of the compressed set and replaced by the single new one.

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut

1;
