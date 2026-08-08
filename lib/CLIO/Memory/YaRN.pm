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

    return undef unless $messages && ref($messages) eq 'ARRAY' && @$messages;

    my $original_task = $opts{original_task} || '';
    my $previous_summary = $opts{previous_summary} || '';
    my $target_tokens = $opts{target_tokens};   # Cache-Stable Summary Slot: fit to N tokens
    my $message_count = scalar(@$messages);

    log_debug('YaRN', "Compressing $message_count messages" . ($target_tokens ? " (target: $target_tokens tokens)" : ''));

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
            commits                 => \@commits,
            files_touched           => \@files_touched,
            decisions               => \@decisions,
            tool_counts             => \%tool_counts,
            user_requests           => \@user_requests,
            collaboration_exchanges => \@collaboration_exchanges,
        });
        # If previous summary had a preserved original request, carry it forward
        if ($previous_summary =~ /\[original\]\s*(.{1,500})/s) {
            my $orig = $1;
            $orig =~ s/\s+$//;
            $opts{_carried_original} = substr($orig, 0, 300);
        }
        # If previous summary had a Current task, carry it forward
        if ($previous_summary =~ /Current task:\s*(.{1,500})/s) {
            my $prev_task = $1;
            $prev_task =~ s/\s+$//;
            $prev_task =~ s/[\r\n].*//s;
            if (!$original_task || length($original_task) < 50) {
                $opts{_carried_task} = $prev_task;
            }
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
                    $tool_counts{$name}++;

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

    # Deduplicate and limit
    my %seen;
    @files_touched = grep { !$seen{$_}++ } @files_touched;
    # Cap policy: when a section exceeds its cap, drop the OLDEST items.
    # Why: new items appear at the end of each section (push order), so dropping
    # from the front keeps the section's text byte-stable for everything that
    # was already there. CSSS relies on this to keep llama.cpp's prompt cache
    # hit on the prefix portion of the summary. The previous code kept NEWEST
    # items ([0..N] for commits after a reverse) - this made new commits
    # appear at the TOP of the section, shifting every other item's position
    # and invalidating the cache on the entire Git commits section.
    # Commits dedup: previous code did `reverse; dedup; cap [0..14]` which
    # kept the NEWEST occurrence of each commit. With append-only growth the
    # same commit can be observed many times across dropped messages. We now
    # dedup oldest-first (keep first occurrence) and cap at newest 15 by
    # slicing [-15..-1], preserving oldest-first render order.
    my %seen_commits;
    @commits = grep { !$seen_commits{$_}++ } @commits;
    @files_touched = @files_touched[-30..-1] if @files_touched > 30;
    @commits       = @commits[-15..-1]      if @commits > 15;
    @decisions     = @decisions[-3..-1]     if @decisions > 3;
    # Keep last 5 collaboration exchanges (most recent are most relevant)
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

    # Build summary
    my @parts;
    push @parts, "<thread_summary>";
    push @parts, "";

    if ($effective_task) {
        push @parts, "Current task: " . substr($effective_task, 0, 300);
        push @parts, "";
    }

    # Collaboration exchanges go FIRST - they represent active design discussions
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
        # Include original request first if it was preserved separately
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

    push @parts, "</thread_summary>";

    my $summary_content = join("\n", @parts);

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
        # Too big - drop sections from least-critical to most-critical.
        # The Current task section is NEVER dropped (it's the agent's
        # active task context).
        log_debug('YaRN', "CSSS: summary $current tokens > target $target_tokens, trimming");
        my @sections = _parse_summary_sections($summary_content);

        # Map drop-key back to its header prefix. (Same mapping that
        # _parse_summary_sections uses to identify section boundaries.)
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

        # If still too big after dropping all droppable sections, hard truncate.
        if ($current > $target_tokens + $tolerance) {
            my $ratio = CLIO::Memory::TokenEstimator::get_effective_ratio();
            my $max_chars = int($target_tokens * $ratio * 0.95);
            if (length($summary_content) > $max_chars) {
                $summary_content = substr($summary_content, 0, $max_chars);
                $summary_content =~ s/\s+\z//;
                $summary_content .= "\n\n[Summary truncated to fit cache-stable slot of $target_tokens tokens]";
                $current = CLIO::Memory::TokenEstimator::estimate_tokens($summary_content);
                log_warning('YaRN', "CSSS: hard-truncated summary to $current tokens (target: $target_tokens)");
            }
        }
    }
    elsif ($current < $target_tokens) {
        # Too small - pad with cache-stable filler. The filler must be
        # byte-deterministic so subsequent regenerations produce identical
        # bytes (cache hit on the filler portion too).
        #
        # Round the filler length to a 64-char bucket so that small shortfall
        # jitter (driven by varying compress_messages output) doesn't shift
        # the slot size. 64 chars is ~16 tokens at the typical ratio, well
        # inside the 10% tolerance check above. Without bucketing, a 1-token
        # shortfall change could shift filler by 4 chars and invalidate the
        # cache that CSSS exists to protect.
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
