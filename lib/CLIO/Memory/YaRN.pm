# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Memory::YaRN;

use strict;
use warnings;
use utf8;
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

    # Empty $messages is valid when the caller wants to re-emit a previous
    # summary (e.g. a check after a no-op trim). We only short-circuit on
    # truly empty input with no previous summary to recycle.
    my $previous_summary = $opts{previous_summary} || '';
    return undef if !$messages && !$previous_summary;
    $messages ||= [];
    return undef unless ref($messages) eq 'ARRAY';

    my $original_task = $opts{original_task} || '';
    my $target_tokens = $opts{target_tokens};   # Cache-Stable Summary Slot: fit to N tokens
    my $message_count = scalar(@$messages);

    log_debug('YaRN', "Compressing $message_count messages" . ($target_tokens ? " (target: $target_tokens tokens)" : ''));

    # Task-aware extraction buckets. If <task_boundary ...> markers are
    # present in @messages, we group dropped messages by owning task.
    # Without task markers we fall back to a single '_flat' bucket for
    # backward compatibility with sessions that predate the todo integration.
    my %task_buckets;  # task_id => bucket hash
    my $has_task_boundaries = _scan_for_task_boundaries($messages);
    my $current_task_id = $has_task_boundaries ? '_pre_task' : '_flat';
    my %collab_tool_calls;  # tool_call_id => agent's question text (shared across tasks)

    # Seed buckets from previous summary so accumulated history isn't lost
    # across trim cycles. Pick parser based on whether previous summary used
    # the task layout (<task ...> blocks) or the legacy flat layout.
    if ($previous_summary) {
        if ($previous_summary =~ /<task\b/i) {
            _parse_previous_task_summary($previous_summary, \%task_buckets);
        } else {
            # Pre-initialize buckets so _parse_previous_summary mutates the
            # passed-in hash instead of writing to local-only arrays.
            # Without this, $flat ends up empty after a previous_summary that
            # doesn't match any section regex (or matches only some) and
            # the dedup loop at line ~415 crashes on undef keys.
            my %flat;
            $flat{user_requests}           = [];
            $flat{commits}                 = [];
            $flat{files_touched}           = [];
            $flat{decisions}               = [];
            $flat{tool_counts}             = {};
            $flat{collaboration_exchanges} = [];
            $flat{persisted_chunks}        = [];
            _parse_previous_summary($previous_summary, \%flat);
            $task_buckets{_flat} = \%flat;
        }
        # Carried-original + carried-task tokens used by find_substantive_task
        if ($previous_summary =~ /\[original\]\s*(.{1,500})/s) {
            my $orig = $1;
            $orig =~ s/\s+$//;
            $opts{_carried_original} = substr($orig, 0, 300);
        }
        if ($previous_summary =~ /Current task:\s*(.{1,500})/s) {
            my $prev_task = $1;
            # Current task line in the persisted-chunks format is
            # "<toolCallId> (<source_tool>: <source_path>) (<bytes>, <remaining>)"
            # which is gibberish as a task name. Skip the carry if the
            # captured "task" looks like a chunk pointer rather than a
            # human-readable task description.
            $prev_task =~ s/\s+$//;
            $prev_task =~ s/[\r\n].*//s;
            if ($prev_task =~ /^\s*\w[\w\-_.]+\s+\([^)]+:\s*[^)]+\)\s*\(\d+\s*bytes/) {
                # Looks like a leaked chunk pointer — drop the carry so
                # the substantive_task fallback can find the real task.
            } elsif (!$original_task || length($original_task) < 50) {
                $opts{_carried_task} = $prev_task;
            }
        }
    }

    # Walk the message stream. <task_boundary> markers switch the active
    # bucket; everything between two markers belongs to the preceding task.
    for my $msg (@$messages) {
        my $role    = $msg->{role}    || '';
        my $content = $msg->{content} || '';

        # Detect task boundary: switch the active bucket.
        if ($role eq 'system' && $content =~ /<task_boundary\b([^>]*?)\/?>/) {
            my $attrs = $1;
            my $tid = 'unknown-task';
            my $tname = '';
            my $ttodo_id;
            my $tstatus = 'active';
            if ($attrs =~ /\bid="([^"]*)"/)      { $tid = $1; }
            if ($attrs =~ /\bname="([^"]*)"/)    { $tname = $1; }
            if ($attrs =~ /\btodo_id="([^"]*)"/) { $ttodo_id = $1; }
            if ($attrs =~ /\bstatus="([^"]*)"/)  { $tstatus = $1; }

            my $bucket = $task_buckets{$tid} ||= {
                user_requests           => [],
                commits                 => [],
                files_touched           => [],
                decisions               => [],
                collaboration_exchanges => [],
                tool_counts             => {},
                persisted_chunks        => [],
                name                    => '',
                todo_id                 => undef,
                status                  => 'unknown',
                started_at              => undef,
                completed_at            => undef,
            };
            $bucket->{name} = $tname;
            $bucket->{todo_id} = $ttodo_id;
            $bucket->{status} = $tstatus;
            $current_task_id = $tid;
            next;
        }

        my $bucket = $task_buckets{$current_task_id} ||= {
            user_requests           => [],
            commits                 => [],
            files_touched           => [],
            decisions               => [],
            collaboration_exchanges => [],
            tool_counts             => {},
            persisted_chunks        => [],
            name                    => '',
            todo_id                 => undef,
            status                  => 'unknown',
            started_at              => undef,
            completed_at            => undef,
        };

        if ($role eq 'user') {
            my $summary = substr($content, 0, 300);
            $summary .= '...' if length($content) > 300;
            push @{$bucket->{user_requests}}, $summary;
        }
        elsif ($role eq 'assistant') {
            # Collaboration/decision messages (identified by metadata,
            # explicit [COLLABORATION] tag, or progress-marker regex).
            #
            # Three capture paths:
            #   1. metadata.collaboration set (programmatic, future)
            #   2. [COLLABORATION] text prefix (model-emitted tag)
            #   3. Progress-marker regex (catches what the model forgot
            #      to tag): "Done with X", "Moving to Y",
            #      "Item N complete", "I found that...", etc.
            #
            # The regex fallback exists because we don't want to force
            # the model to remember a tag. If it says something that
            # clearly looks like progress, we capture it. False positives
            # pollute the Decisions bucket, so the whitelist is tight.
            my $captured_decision;
            my $collab_type = $msg->{metadata} && $msg->{metadata}{collaboration};
            if ($collab_type) {
                $captured_decision = $content;
            } elsif ($content =~ /\[COLLABORATION\](.{1,500})/s) {
                $captured_decision = $1;
            } else {
                # Progress-marker heuristic. The pattern must:
                #   - start at a sentence boundary (^|\.\s+|then\s+|\n\s*)
                #   - contain a known progress phrase
                #   - have non-trivial content after the phrase
                # Without ^/boundary anchoring we'd capture mid-sentence
                # continuations that happen to contain the word
                # "complete" or "found".
                if ($content =~ /(?:^|[.;]\s+|\n)\s*(?:(?:I\s+have|I've|I|We\s+have|We've|We)\s+(?:completed?|finished|done|found|identified|discovered|located)\s+|Found\s+|Done\s+with\s+|Finished\s+|Moving\s+to\s+|Now\s+(?:proceeding|starting|implementing|working)\s+|The\s+(?:fix|root\s+cause|bug|problem|solution|approach|plan)\s+(?:is|was)\s+|Next\s+(?:step|phase|item)\s+(?:is|will\s+be)\s+|Item\s+\d+\s+(?:complete|done)\s*[:.]?\s*|Proceeding\s+with\s+|The\s+plan\s+is\s+(?:to\s+)?)(.{15,500})/i) {
                    $captured_decision = $1;
                }
            }

            if (defined $captured_decision) {
                my $dec = $captured_decision;
                $dec =~ s/\s+/ /g;
                $dec =~ s/^\s+|\s+$//g;
                # Cap at 250 chars to keep the Decisions section compact.
                # Same limit as the existing [COLLABORATION] capture path.
                $dec = substr($dec, 0, 250);
                # Dedup by exact string match so repeated "Moving to X"
                # markers don't bloat the bucket across trim cycles.
                my $dup = grep { $_ eq $dec } @{$bucket->{decisions}};
                push @{$bucket->{decisions}}, $dec unless $dup;
            }

            # Tool calls - extract meaningful path/operation details
            if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                for my $tc (@{$msg->{tool_calls}}) {
                    my $name     = $tc->{function}{name}      || 'unknown';
                    my $args_str = $tc->{function}{arguments} || '{}';
                    $bucket->{tool_counts}{$name}++;

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
                            push @{$bucket->{files_touched}}, $1 unless $1 =~ /^\./;
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
                push @{$bucket->{collaboration_exchanges}}, {
                    question => $question,
                    response => $response,
                };
                delete $collab_tool_calls{$msg->{tool_call_id}};
            }

            # Persisted chunk tracking: if this tool result carries
            # _metadata.persisted_chunks, the original content was
            # persisted to disk because it exceeded the inline limit.
            # Capture the chunk reference so the summary can tell the
            # model how to re-read the full content via read_tool_result
            # after this tool result gets dropped by a trim cycle.
            #
            # Authoritative source: structured _metadata.persisted_chunks
            # attached by WorkflowOrchestrator. Falls back to regex over
            # content for messages persisted before that plumbing existed
            # (legacy sessions).
            if (ref($msg->{_metadata}) eq 'HASH' && ref($msg->{_metadata}{persisted_chunks}) eq 'ARRAY') {
                for my $chunk (@{$msg->{_metadata}{persisted_chunks}}) {
                    next unless ref($chunk) eq 'HASH' && $chunk->{tool_call_id};
                    # Skip persist-failed chunks; no file on disk to read.
                    next if $chunk->{persist_failed};
                    push @{$bucket->{persisted_chunks}}, {
                        tool_call_id => $chunk->{tool_call_id},
                        source_path  => $chunk->{source_path}  || '',
                        source_tool  => $chunk->{source_tool}  || '',
                        total_length => $chunk->{total_length} || 0,
                        remaining    => $chunk->{remaining}    || 0,
                    };
                }
            }
            # Legacy fallback: regex over content for [TOOL_RESULT_STORED: ...]
            # markers. Used when sessions persisted before this code path
            # are loaded and re-trimmed.
            elsif ($content =~ /\[TOOL_RESULT_STORED:\s*toolCallId=([^\s,]+)/g) {
                my $legacy_tcid = $1;
                # Dedupe: if structured metadata already named this chunk
                # in the same summary, skip.
                my $already = grep { $_->{tool_call_id} eq $legacy_tcid } @{$bucket->{persisted_chunks} || []};
                next if $already;
                push @{$bucket->{persisted_chunks}}, {
                    tool_call_id => $legacy_tcid,
                    source_path  => '',
                    source_tool  => '',
                    total_length => 0,
                    remaining    => 0,
                    legacy       => 1,
                };
            }

            # Git commit results: [abc1234] Commit subject line
            while ($content =~ /^\[([a-f0-9]{7,12})\]\s+(.{1,100})/mg) {
                push @{$bucket->{commits}}, "$1: $2";
            }
            # git log --oneline output
            while ($content =~ /^([a-f0-9]{7,12})\s+(.{1,100})/mg) {
                my $entry = "$1: $2";
                push @{$bucket->{commits}}, $entry
                    unless grep { $_ eq $entry } @{$bucket->{commits}};
            }
        }
    }

    # Per-bucket dedup + limit.
    for my $tid (keys %task_buckets) {
        my $b = $task_buckets{$tid};
        my %seen;
        @{$b->{files_touched}} = grep { !$seen{$_}++ } @{$b->{files_touched}};
        @{$b->{files_touched}} = @{$b->{files_touched}}[0..29] if @{$b->{files_touched}} > 30;
        @{$b->{commits}}       = do { my %s; grep { !$s{$_}++ } reverse @{$b->{commits}} };
        @{$b->{commits}}       = @{$b->{commits}}[0..14] if @{$b->{commits}} > 15;
        @{$b->{decisions}}     = @{$b->{decisions}}[-3..-1] if @{$b->{decisions}} > 3;
        @{$b->{collaboration_exchanges}} = @{$b->{collaboration_exchanges}}[-5..-1]
            if @{$b->{collaboration_exchanges}} > 5;
    }

    # Pick renderer: task-aware if we saw real task boundaries; legacy flat otherwise.
    my $real_task_count = grep { $_ ne '_flat' && $_ ne '_pre_task' } keys %task_buckets;
    my $use_task_layout = $real_task_count > 0 || $has_task_boundaries;

    my $summary_content;
    if ($use_task_layout) {
        $summary_content = _render_task_summary(\%task_buckets,
            original_task    => $original_task,
            carried_task     => $opts{_carried_task},
            carried_original => $opts{_carried_original},
        );
    }
    else {
        $summary_content = _render_flat_summary($task_buckets{_flat} || {},
            original_task    => $original_task,
            carried_task     => $opts{_carried_task},
            carried_original => $opts{_carried_original},
        );
    }

    # Cache-Stable Summary Slot (CSSS): if caller requested a target token size,
    # fit the summary to that size. Truncate oldest items first if too big,
    # pad with neutral filler if too small. This keeps the summary at a constant
    # byte length across trim cycles, so llama.cpp's prompt cache can reuse
    # everything before and after the summary slot.
    if ($target_tokens && $target_tokens > 0) {
        $summary_content = _fit_summary_to_target($summary_content, $target_tokens);
    }

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

# Returns 1 if @messages contains any <task_boundary ...> markers.
sub _scan_for_task_boundaries {
    my ($messages) = @_;
    for my $msg (@$messages) {
        next unless ($msg->{role} // '') eq 'system';
        my $c = $msg->{content} // '';
        return 1 if $c =~ /<task_boundary\b/;
    }
    return 0;
}

=head2 _render_flat_summary

Legacy flat-list renderer. Kept for sessions that never had task boundaries
(messages emitted before the todo integration). Renders the same layout
compress_messages used to emit: Current task, collaboration, requests,
commits, files, decisions, tool counts.

Arguments:
    $bucket              - Hashref with user_requests/commits/files_touched/etc.
    %opts                - original_task, carried_task, carried_original, previous_summary

Returns:
    Rendered <thread_summary>...</thread_summary> string.

=cut

sub _render_flat_summary {
    my ($bucket, %opts) = @_;

    my $original_task    = $opts{original_task}     || '';
    my $carried_task     = $opts{carried_task}      || '';
    my $carried_original = $opts{carried_original}  || '';

    my @user_requests           = @{$bucket->{user_requests}           || []};
    my @commits                 = @{$bucket->{commits}                 || []};
    my @files_touched           = @{$bucket->{files_touched}           || []};
    my @decisions               = @{$bucket->{decisions}               || []};
    my @collaboration_exchanges = @{$bucket->{collaboration_exchanges} || []};
    my %tool_counts             = %{$bucket->{tool_counts}             || {}};

    my $first_user_request;
    if (@user_requests > 8) {
        $first_user_request = $user_requests[0];
        @user_requests = @user_requests[-7..-1];
    }
    if ($carried_original) {
        unless (grep { $_ eq $carried_original } @user_requests) {
            $first_user_request = $carried_original unless $first_user_request;
        }
    }

    my @all_requests = @user_requests;
    unshift @all_requests, $first_user_request if $first_user_request;
    my $effective_task = find_substantive_task(
        $carried_task || $original_task,
        \@all_requests
    );

    my @parts;
    push @parts, "<thread_summary>";
    push @parts, "";

    if ($effective_task) {
        push @parts, "Current task: " . substr($effective_task, 0, 300);
        push @parts, "";
    }

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

    if (@user_requests || $first_user_request) {
        push @parts, "Recent user requests:";
        if ($first_user_request && !grep { $_ eq $first_user_request } @user_requests) {
            push @parts, "- [original] $first_user_request";
        }
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

    # Persisted chunks: tool results that exceeded the inline limit and
    # were persisted to disk. Render the toolCallId + source path so the
    # model can re-read the full content via read_tool_result after this
    # summary regenerates. Without this section, large file reads are
    # black-holed by trim — the preview survives but the model has no
    # way to know which persisted file to fetch.
    my @persisted_chunks = @{$bucket->{persisted_chunks} || []};
    if (@persisted_chunks) {
        push @parts, "Persisted chunks (re-read with file_operations read_tool_result, toolCallId=<id>, offset=<bytes>):";
        for my $chunk (@persisted_chunks) {
            my $line = "- $chunk->{tool_call_id}";
            $line .= " ($chunk->{source_tool}: $chunk->{source_path})" if $chunk->{source_path};
            $line .= " ($chunk->{total_length} bytes, $chunk->{remaining} remaining)" if $chunk->{total_length};
            $line .= " [legacy: detected from content marker]" if $chunk->{legacy};
            push @parts, $line;
        }
        push @parts, "";
    }

    push @parts, "</thread_summary>";

    return join("\n", @parts);
}

=head2 _render_task_summary

Task-aware renderer. Emits one <task>...</task> block per task bucket,
preserving the per-task semantics that the legacy flat layout could not
capture.

Arguments:
    $task_buckets - Hashref of task_id => bucket hash
    %opts         - original_task, carried_task, carried_original

Returns:
    Rendered <thread_summary>...</thread_summary> string.

=cut

sub _render_task_summary {
    my ($task_buckets, %opts) = @_;

    my $original_task    = $opts{original_task}    || '';
    my $carried_task     = $opts{carried_task}     || '';
    my $carried_original = $opts{carried_original} || '';

    # Order tasks oldest-first by started_at; sentinel keys are dropped.
    my @ordered_task_ids;
    for my $tid (sort keys %$task_buckets) {
        next if $tid eq '_flat' || $tid eq '_pre_task';
        push @ordered_task_ids, $tid;
    }
    @ordered_task_ids = sort {
        my $aa = $task_buckets->{$a}{started_at} || 0;
        my $bb = $task_buckets->{$b}{started_at} || 0;
        $aa <=> $bb;
    } @ordered_task_ids;

    # Most-recent task's name seeds the Current task line.
    my $most_recent_task_id = $ordered_task_ids[-1];
    my $most_recent_name = $most_recent_task_id
        ? ($task_buckets->{$most_recent_task_id}{name} || '')
        : '';

    my @all_user_requests;
    for my $tid (@ordered_task_ids) {
        push @all_user_requests, @{$task_buckets->{$tid}{user_requests} || []};
    }
    # When called with task-aware extraction, prefer the most recent task's
    # name as the Current task line. find_substantive_task can pull a very
    # long user message (truncated for display via substr) but for the
    # Current task line we want the concise task name, not a substring of
    # the latest user prompt.
    my $effective_task = $most_recent_name
        || find_substantive_task(
            $carried_task || $original_task,
            \@all_user_requests
        );

    my @parts;
    push @parts, "<thread_summary>";
    push @parts, "";

    if ($effective_task) {
        push @parts, "Current task: " . substr($effective_task, 0, 300);
        push @parts, "";
    }

    # Render one <task> block per task, oldest first so the most recent
    # task is at the end (stable reading order).
    for my $tid (@ordered_task_ids) {
        my $b = $task_buckets->{$tid};
        push @parts, _render_single_task_block($tid, $b);
        push @parts, "";
    }

    push @parts, "</thread_summary>";

    return join("\n", @parts);
}

# Render a single <task id="..." status="...">...</task> block from a
# task bucket. The block is a self-contained summary of one task's work.
sub _render_single_task_block {
    my ($tid, $b) = @_;

    my @lines;
    my $status = $b->{status} || 'completed';
    push @lines, qq{<task id="$tid" status="$status">};

    if ($b->{name}) {
        push @lines, "Task: " . $b->{name};
    }

    my @collab = @{$b->{collaboration_exchanges} || []};
    @collab = @collab[-3..-1] if @collab > 3;
    if (@collab) {
        push @lines, "Active discussion:";
        for my $ex (@collab) {
            push @lines, "  Agent asked: " . substr($ex->{question}, 0, 300);
            push @lines, "  User replied: " . substr($ex->{response} // '', 0, 300);
        }
    }

    if (@{$b->{decisions} || []}) {
        push @lines, "Decisions:";
        push @lines, "- $_" for @{$b->{decisions}};
    }

    if (@{$b->{files_touched} || []}) {
        push @lines, "Files:";
        push @lines, "- $_" for @{$b->{files_touched}};
    }

    if (@{$b->{commits} || []}) {
        push @lines, "Commits:";
        push @lines, "- $_" for @{$b->{commits}};
    }

    if (%{$b->{tool_counts} || {}}) {
        my @tool_lines;
        for my $tool (sort keys %{$b->{tool_counts}}) {
            push @tool_lines, "$tool: $b->{tool_counts}{$tool}";
        }
        push @lines, "Tools: " . join(", ", @tool_lines);
    }

    # Persisted chunks: same as flat renderer — emit toolCallId + source
    # so the model can re-read large files after trim drops the original
    # tool result content.
    if (@{$b->{persisted_chunks} || []}) {
        push @lines, "Persisted chunks:";
        for my $chunk (@{$b->{persisted_chunks}}) {
            my $line = "- $chunk->{tool_call_id}";
            $line .= " ($chunk->{source_tool}: $chunk->{source_path})" if $chunk->{source_path};
            $line .= " ($chunk->{total_length} bytes, $chunk->{remaining} remaining)" if $chunk->{total_length};
            $line .= " [legacy: detected from content marker]" if $chunk->{legacy};
            push @lines, $line;
        }
    }

    push @lines, "</task>";
    return join("\n", @lines);
}

# Parse a previously-rendered <thread_summary> that uses the task layout.
# Seeds %task_buckets in place; one entry per <task id="..."> block.
sub _parse_previous_task_summary {
    my ($summary_text, $task_buckets) = @_;

    return unless $summary_text && $task_buckets;

    # Match each <task id="..." status="...">...</task> block. The content
    # of each block is rendered as a sequence of lines that begin with one
    # of the known section labels ("Task:", "Decisions:", "Files:", etc.)
    # or with "  Agent asked:" / "  User replied:" for collaboration.
    while ($summary_text =~ /<task\s+([^>]*?)>(.*?)<\/task>/sg) {
        my $attrs = $1;
        my $body = $2;
        my $tid = 'unknown-task';
        my $tstatus = 'completed';
        if ($attrs =~ /\bid="([^"]*)"/)     { $tid = $1; }
        if ($attrs =~ /\bstatus="([^"]*)"/) { $tstatus = $1; }

        my $bucket = $task_buckets->{$tid} ||= {
            user_requests           => [],
            commits                 => [],
            files_touched           => [],
            decisions               => [],
            collaboration_exchanges => [],
            tool_counts             => {},
            persisted_chunks        => [],
            name                    => '',
            todo_id                 => undef,
            status                  => $tstatus,
            started_at              => undef,
            completed_at            => undef,
        };

        # Extract the task name (rendered as "Task: <name>" on its own line).
        if ($body =~ /^Task:\s*(.+)$/m) {
            $bucket->{name} = $1;
        }

        # Extract collaboration exchanges (must be parsed as a pair).
        my @collab_q;
        my @collab_r;
        for my $line (split /\n/, $body) {
            if    ($line =~ /^\s*Agent asked:\s*(.*)$/) { push @collab_q, $1; }
            elsif ($line =~ /^\s*User replied:\s*(.*)$/) { push @collab_r, $1; }
        }
        for (my $i = 0; $i < @collab_q; $i++) {
            push @{$bucket->{collaboration_exchanges}}, {
                question => $collab_q[$i],
                response => $collab_r[$i] // '',
            };
        }

        # Extract sections: lines after the label up to the next label or end.
        my %section_re = (
            Decisions        => qr/^Decisions:\s*$/,
            Files            => qr/^Files:\s*$/,
            Commits          => qr/^Commits:\s*$/,
            Tools            => qr/^Tools:\s*$/,
            'Persisted chunks' => qr/^Persisted chunks:\s*$/,
        );
        my %sections = (
            Decisions          => [],
            Files              => [],
            Commits            => [],
            Tools              => [],
            'Persisted chunks' => [],
        );
        my $current_label;
        for my $line (split /\n/, $body) {
            my $matched;
            for my $label (keys %section_re) {
                if ($line =~ $section_re{$label}) {
                    $matched = $label;
                    last;
                }
            }
            if ($matched) {
                $current_label = $matched;
            }
            elsif ($current_label && $line =~ /^- (.+)$/) {
                push @{$sections{$current_label}}, $1;
            }
            elsif ($current_label && $current_label eq 'Tools' && $line =~ /^Tools:\s*(.+)$/) {
                # Tools are rendered as a single comma-joined line, not bullets.
                for my $pair (split /\s*,\s*/, $1) {
                    if ($pair =~ /^([^:]+):\s*(\d+)/) {
                        $bucket->{tool_counts}{$1} = ($bucket->{tool_counts}{$1} || 0) + $2;
                    }
                }
                $current_label = undef;
            }
        }
        push @{$bucket->{decisions}},          @{$sections{Decisions}};
        push @{$bucket->{files_touched}},      @{$sections{Files}};
        push @{$bucket->{commits}},            @{$sections{Commits}};

        # Persisted chunks are stored differently from other sections:
        # each line is "<toolCallId> (<source_tool>: <source_path>) (<bytes>, <remaining>)".
        # Re-parse into the bucket's persisted_chunks list.
        for my $line (@{$sections{'Persisted chunks'}}) {
            # Extract toolCallId (first whitespace-delimited token).
            my ($tcid, $rest) = split /\s+/, $line, 2;
            next unless $tcid && $tcid =~ /^[\w\-_.]+$/;
            my $chunk = {
                tool_call_id => $tcid,
                source_path  => '',
                source_tool  => '',
                total_length => 0,
                remaining    => 0,
                legacy       => 0,
            };
            if ($rest =~ /\(([^:]+):\s*([^)]+)\)/) {
                $chunk->{source_tool} = $1;
                $chunk->{source_path} = $2;
            }
            if ($rest =~ /\((\d+)\s*bytes,\s*(\d+)\s*remaining\)/) {
                $chunk->{total_length} = $1;
                $chunk->{remaining}    = $2;
            }
            $chunk->{legacy} = 1 if $rest =~ /\[legacy:/;
            push @{$bucket->{persisted_chunks}}, $chunk;
        }
    }
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

    # A carried-task that looks like a leaked persisted-chunk pointer
    # (<toolCallId> (<source_tool>: <path>) (<bytes>, <remaining>)) is
    # gibberish as a task description. Treat it as missing so we fall
    # through to the messages scan.
    my $looks_like_chunk_pointer = $candidate
        && $candidate =~ /^\s*\w[\w\-_.]+\s+\([^)]+:\s*[^)]+\)\s*\(\d+\s*bytes/;

    return $candidate if $candidate && !$looks_like_chunk_pointer && length($candidate) >= $min_len;

    # Scan messages newest-first for a substantive user message
    if ($messages && ref($messages) eq 'ARRAY') {
        for my $item (reverse @$messages) {
            if (ref($item) eq 'HASH') {
                next unless ($item->{role} || '') eq 'user';
                my $content = $item->{content} || '';
                next if $content =~ /^\s*\w[\w\-_.]+\s+\([^)]+:\s*[^)]+\)\s*\(\d+\s*bytes/;
                return $content if length($content) >= $min_len;
            } else {
                # Plain string (e.g. from @user_requests)
                next if defined $item && $item =~ /^\s*\w[\w\-_.]+\s+\([^)]+:\s*[^)]+\)\s*\(\d+\s*bytes/;
                return $item if defined $item && length($item) >= $min_len;
            }
        }
    }

    # No substantive message found - return whatever we have
    return $candidate || '';
}

# Parse structured sections from a previous thread_summary to seed extraction buckets.
# This preserves accumulated history across multiple trim cycles.
sub _parse_previous_summary {
    my ($summary_text, $buckets) = @_;
    
    return unless $summary_text && $buckets;
    
    # Strip thread_summary tags
    $summary_text =~ s/<\/?thread_summary>//g;
    
    my $commits                 = $buckets->{commits}                 || [];
    my $files_touched           = $buckets->{files_touched}           || [];
    my $decisions               = $buckets->{decisions}               || [];
    my $tool_counts             = $buckets->{tool_counts}             || {};
    my $user_requests           = $buckets->{user_requests}           || [];
    my $collaboration_exchanges = $buckets->{collaboration_exchanges} || [];
    my $persisted_chunks        = $buckets->{persisted_chunks}        || [];

    # Parse persisted chunks: lines under "Persisted chunks:" section.
    # Each line is "- <toolCallId> (<source_tool>: <source_path>) (<bytes>, <remaining>)"
    # or "- <toolCallId> [legacy: detected from content marker]".
    if ($summary_text =~ /Persisted chunks \(re-read with [^)]+\):\n((?:- [^\n]+\n)+)/s) {
        my $block = $1;
        while ($block =~ /^- ([^\n]+)$/mg) {
            my $line = $1;
            my ($tcid, $rest) = split /\s+/, $line, 2;
            next unless $tcid && $tcid =~ /^[\w\-_.]+$/;
            my $chunk = {
                tool_call_id => $tcid,
                source_path  => '',
                source_tool  => '',
                total_length => 0,
                remaining    => 0,
                legacy       => 0,
            };
            $rest //= '';
            if ($rest =~ /\(([^:]+):\s*([^)]+)\)/) {
                $chunk->{source_tool} = $1;
                $chunk->{source_path} = $2;
            }
            if ($rest =~ /\((\d+)\s*bytes,\s*(\d+)\s*remaining\)/) {
                $chunk->{total_length} = $1;
                $chunk->{remaining}    = $2;
            }
            $chunk->{legacy} = 1 if $rest =~ /\[legacy:/;
            push @$persisted_chunks, $chunk;
        }
    }

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
    
    # Parse user requests: lines under "Recent user requests:" (preserving [original] marker)
    if ($summary_text =~ /Recent user requests:\n((?:- .+\n)+)/s) {
        my $block = $1;
        while ($block =~ /^- (?:\[original\]\s*)?(.+)$/mg) {
            my $req = $1;
            $req =~ s/\s+$//;
            push @$user_requests, $req;
        }
    }
    
    # Parse active discussion: agent-user exchange pairs
    if ($summary_text =~ /Active discussion.*?:\n((?:  Agent asked:.+\n(?:  User replied:.+\n)?)+)/s) {
        my $block = $1;
        while ($block =~ /  Agent asked:\s*(.{1,1000})\n(?:  User replied:\s*(.{1,1000})\n)?/g) {
            push @$collaboration_exchanges, {
                question => $1,
                response => $2 || '',
            };
        }
    }
    
    my $parsed_items = scalar(@$commits) + scalar(@$files_touched) + scalar(@$decisions)
                     + scalar(keys %$tool_counts) + scalar(@$user_requests)
                     + scalar(@$collaboration_exchanges);
    log_debug('YaRN', "Parsed $parsed_items items from previous summary") if $parsed_items;
}

=head2 _fit_summary_to_target

Adjust a thread_summary string to fit a target token budget.

Strategy:
- If too big: drop sections in least-critical-first order (tool_counts,
  decisions, files, commits, collaboration, user_requests). Within a section,
  truncate oldest items. Always preserve the Current task line.
- If too small: pad with a single HTML comment line of neutral filler that
  # is byte-stable across calls (so it caches the same way each time).

Arguments:
  $summary_content - Already-rendered thread_summary string
  $target_tokens   - Desired token count (approximate; tolerance ~10%)

Returns: Adjusted summary string.

=cut

sub _fit_summary_to_target {
    my ($summary_content, $target_tokens) = @_;

    require CLIO::Memory::TokenEstimator;
    my $current = CLIO::Memory::TokenEstimator::estimate_tokens($summary_content);

    # Within 10% of target - leave as is. Estimation accuracy is ~5-10% so
    # chasing exact equality causes thrashing without benefit.
    my $tolerance = int($target_tokens * 0.10);
    return $summary_content if abs($current - $target_tokens) <= $tolerance;

    if ($current > $target_tokens) {
        log_debug('YaRN', "CSSS: summary $current tokens > target $target_tokens, trimming");

        # Two-pass strategy: first try to fit by trimming task blocks, then
        # if still too big, fall back to dropping sections within the most
        # recent task. The "Current task" line is NEVER dropped.
        if ($summary_content =~ /<task\b/i) {
            my @task_blocks = _parse_task_blocks($summary_content);
            my $current_task_line = '';
            if ($summary_content =~ /(Current task:[^\n]*\n)/) {
                $current_task_line = $1;
            }

            # Drop whole task blocks oldest-first, never dropping the most
            # recent task (the agent is currently working on it).
            # We also always keep at least the most-recent task block, even
            # if dropping it would fit the budget - losing active context
            # is worse than running slightly over budget.
            #
            # Strategy: try the full set, drop one at a time until we fit
            # (or hit the keep-at-least-most-recent floor). The candidate
            # is rendered once per iteration to measure.
            my $fit_achieved = 0;
            while (@task_blocks > 1) {
                my $candidate = _render_with_task_blocks($current_task_line, \@task_blocks);
                my $size = CLIO::Memory::TokenEstimator::estimate_tokens($candidate);
                if ($size <= $target_tokens + $tolerance) {
                    $summary_content = $candidate;
                    $current = $size;
                    $fit_achieved = 1;
                    last;
                }
                shift @task_blocks;  # Drop oldest, try again
            }
            # If we never achieved fit but the final set is still too big,
            # we leave it as-is and fall through to the section-level
            # drops and hard-truncate safety net below.
            if (!$fit_achieved) {
                $summary_content = _render_with_task_blocks($current_task_line, \@task_blocks);
                $current = CLIO::Memory::TokenEstimator::estimate_tokens($summary_content);
            }

            # If still too big with only the most recent task, trim its
            # internal sections (Tools first, then Commits, then Files).
            if ($current > $target_tokens + $tolerance && @task_blocks == 1) {
                my $trimmed = _trim_most_recent_task($task_blocks[0], $target_tokens);
                $summary_content = _render_with_task_blocks($current_task_line, [$trimmed])
                    if $trimmed;
                $current = CLIO::Memory::TokenEstimator::estimate_tokens($summary_content);
            }
        }

        # Legacy fall-through: section-level drops for non-task summaries.
        if ($current > $target_tokens + $tolerance) {
            my @sections = _parse_summary_sections($summary_content);
            my %key_to_prefix = (
                tool_counts    => 'Tool usage',
                decisions      => 'Key decisions',
                files          => 'Files created/modified',
                commits        => 'Git commits',
                collab         => 'Active discussion',
                user_requests  => 'Recent user requests',
            );
            my @drop_order = qw(tool_counts decisions files commits collab user_requests);
            for my $key (@drop_order) {
                my $prefix = $key_to_prefix{$key};
                my $idx = _find_section_index(\@sections, $prefix);
                next if $idx < 0;
                splice @sections, $idx, 1;
                my $candidate = _render_sections(\@sections);
                my $size = CLIO::Memory::TokenEstimator::estimate_tokens($candidate);
                if ($size <= $target_tokens + $tolerance) {
                    $summary_content = $candidate;
                    $current = $size;
                    last;
                }
            }
        }

        # If still too big after dropping all droppable sections, hard truncate.
        if ($current > $target_tokens + $tolerance) {
            my $ratio = CLIO::Memory::TokenEstimator::get_effective_ratio();
            my $max_chars = int($target_tokens * $ratio * 0.95);

            # CRITICAL: Extract and preserve "Current task" before hard truncation.
            my $current_task = '';
            if ($summary_content =~ /Current task:\s*(.+?)(?:\n\n|\z)/s) {
                $current_task = "Current task: $1\n\n";
            }

            if (length($summary_content) > $max_chars) {
                my $task_chars = length($current_task);
                my $available_chars = $max_chars - $task_chars - 100;
                $available_chars = 1000 if $available_chars < 1000;

                $summary_content = substr($summary_content, 0, $available_chars);
                $summary_content =~ s/\s+\z//;

                $summary_content = $current_task . $summary_content . "\n\n[Summary truncated to fit cache-stable slot of $target_tokens tokens]";
                $current = CLIO::Memory::TokenEstimator::estimate_tokens($summary_content);
                log_warning('YaRN', "CSSS: hard-truncated summary to $current tokens (target: $target_tokens, preserved Current task)");
            }
        }
    }
    elsif ($current < $target_tokens) {
        # Too small - pad with cache-stable filler. The filler must be
        # byte-deterministic so subsequent regenerations produce identical
        # bytes (cache hit on the filler portion too).
        my $shortfall = $target_tokens - $current;
        my $ratio = CLIO::Memory::TokenEstimator::get_effective_ratio();
        my $BUCKET = 64;
        my $filler_chars = int(($shortfall * $ratio + $BUCKET - 1) / $BUCKET) * $BUCKET;
        $filler_chars = $BUCKET if $filler_chars < $BUCKET;
        $summary_content .= "\n<!-- csss:padding:" . ('x' x $filler_chars) . " -->\n";
        $current = CLIO::Memory::TokenEstimator::estimate_tokens($summary_content);
        log_debug('YaRN', "CSSS: padded summary to $current tokens (target: $target_tokens, filler=$filler_chars)");
    }

    return $summary_content;
}

# Split a <thread_summary>...</thread_summary> body into a list of task-block
# strings, oldest-first, EXCLUDING the <thread_summary> wrapper itself.
# Each element is the raw text of one <task id="...">...</task> block.
sub _parse_task_blocks {
    my ($summary_content) = @_;
    my @blocks;
    while ($summary_content =~ /(<task\s+[^>]*?>.*?<\/task>)/sg) {
        push @blocks, $1;
    }
    return @blocks;
}

# Reassemble a <thread_summary> with the given task blocks (and the
# preserved "Current task" line if present).
sub _render_with_task_blocks {
    my ($current_task_line, $task_blocks) = @_;

    my $out = "<thread_summary>\n\n";
    if ($current_task_line) {
        $out .= $current_task_line . "\n";
    }
    for my $block (@$task_blocks) {
        $out .= "\n" . $block . "\n";
    }
    $out .= "</thread_summary>";
    return $out;
}

# Trim the most-recent (and only remaining) task block to fit a target.
# Drops sections in least-critical-first order within the task block.
sub _trim_most_recent_task {
    my ($task_block, $target_tokens) = @_;

    require CLIO::Memory::TokenEstimator;
    my $tolerance = int($target_tokens * 0.10);

    # Sections within a <task> block, ordered least-critical first.
    my @drop_order = qw(Tools Commits Files Decisions);
    for my $section (@drop_order) {
        # Strip the section (label line + body lines up to next label or </task>).
        my $stripped = $task_block;
        $stripped =~ s/^$section:.*?(?=\n[A-Z][a-z]+:|\n?<\/task>|\z)//sm;
        my $size = CLIO::Memory::TokenEstimator::estimate_tokens($stripped);
        if ($size <= $target_tokens + $tolerance) {
            return $stripped;
        }
    }
    return $task_block;
}

# Parse a rendered thread_summary into ordered sections. Returns an array of
# { name => $key, header => $text, body => $text } hashes. The opening
# <thread_summary> and closing </thread_summary> tags are stripped.
#
# Robustness notes:
# - Headers always end with a colon (rendered by the writing code). Matching
#   on the colon at end-of-prefix prevents body lines like "Git commits:" that
#   happen to start with the same prefix from being misidentified.
# - Section keys are sorted by length DESCENDING so longer (more specific)
#   prefixes like "Files created/modified" match before shorter ones like
#   "Files" (which is not a real key, but illustrates the principle). Hash
#   iteration order is randomised in Perl, which would otherwise make this
#   non-deterministic.
sub _parse_summary_sections {
    my ($content) = @_;

    my @sections;
    my $body = $content;
    $body =~ s/<\/?thread_summary>\n?//g;

    my @lines = split /\n/, $body;
    my $current;

    # Sorted by length descending - longer (more specific) prefixes match first
    # to avoid ambiguity (e.g. "Files created/modified:" beats "Files:" if a
    # body line happens to start with "Files").
    my @section_prefixes = sort { length($b) <=> length($a) } (
        'Current task',
        'Active discussion',
        'Recent user requests',
        'Git commits',
        'Files created/modified',
        'Key decisions',
        'Tool usage',
    );

    for my $line (@lines) {
        my $matched;
        for my $prefix (@section_prefixes) {
            # A header line starts with the prefix AND ends with a colon
            # (the colon distinguishes it from any body line that happens
            # to begin with the same words).
            if ($line =~ /^\Q$prefix\E:/) {
                $matched = $prefix;
                last;
            }
        }
        if (defined $matched) {
            push @sections, $current if $current;
            $current = { header => $line, body => '' };
        }
        elsif ($current) {
            $current->{body} .= ($current->{body} ne '' ? "\n" : '') . $line;
        }
    }
    push @sections, $current if $current;

    return @sections;
}

sub _find_section_index {
    my ($sections, $header_prefix) = @_;
    for my $i (0 .. $#$sections) {
        my $header = $sections->[$i]{header} // '';
        return $i if $header =~ /^\Q$header_prefix\E:/;
    }
    return -1;
}

sub _render_sections {
    my ($sections) = @_;
    my $out = "<thread_summary>\n";
    for my $sec (@$sections) {
        $out .= "\n" . $sec->{header} . "\n";
        if (length $sec->{body}) {
            $out .= $sec->{body} . "\n";
        }
    }
    $out .= "\n</thread_summary>";
    return $out;
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

1;
