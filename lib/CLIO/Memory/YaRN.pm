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

# Truncate text to $max bytes, ending at a word boundary, appending '...'.
sub _truncate {
    my ($text, $max) = @_;
    return '' unless defined $text && length($text);
    return $text unless length($text) > $max;
    my $truncated = substr($text, 0, $max);
    $truncated =~ s/\s+\S*$//;
    return $truncated . '...';
}

# Extract plain text from message content, handling both scalar strings
# and arrayref (multimodal) content. For arrayref content (e.g. image
# uploads), concatenates the text parts and skips non-text parts (image_url,
# image, etc.). Returns '' for empty/undefined content.
sub _extract_content_text {
    my ($content) = @_;
    return '' unless defined $content;
    return $content unless ref($content) eq 'ARRAY';

    my $text = '';
    for my $part (@$content) {
        next unless ref($part) eq 'HASH';
        if (($part->{type} // '') eq 'text' && defined $part->{text}) {
            $text .= $part->{text};
        }
    }
    return $text;
}

# ---------------------------------------------------------------------------
# Context-aware compression parameters
# ---------------------------------------------------------------------------

# Default limits (designed for 128K-context models). _compute_limits()
# scales these down for smaller contexts and up for larger ones.
our $DEFAULT_MAX_USER_REQUESTS     = 16;
our $DEFAULT_MAX_DECISIONS         = 8;
our $DEFAULT_MAX_COLLABORATION     = 10;
our $DEFAULT_MAX_FILES             = 50;
our $DEFAULT_MAX_COMMITS           = 30;
our $DEFAULT_MAX_TOOL_TYPES        = 8;
our $DEFAULT_USER_REQUEST_LEN      = 600;
our $DEFAULT_DECISION_LEN          = 500;
our $DEFAULT_COLLABORATION_LEN     = 1500;

# Summary cap bounds (characters). The actual cap is derived from the
# model's context window via _compute_summary_cap(); these prevent
# pathological values.
our $MIN_SUMMARY_CAP = 4000;    # ~1K-2K tokens — usable for 32K local models
our $MAX_SUMMARY_CAP = 60000;   # ~15-20K tokens — enough for extreme contexts

=head2 _default_context_window

Return the default context window in tokens (from CLIO::Core::Defaults).

=cut

sub _default_context_window {
    require CLIO::Core::Defaults;
    return CLIO::Core::Defaults::DEFAULT_CONTEXT_WINDOW();
}

=head2 _get_chars_per_token

Return the current characters-per-token ratio from TokenEstimator
(learned ratio if available, else the default of 4.0).

=cut

sub _get_chars_per_token {
    require CLIO::Memory::TokenEstimator;
    return CLIO::Memory::TokenEstimator::get_effective_ratio();
}

=head2 _compute_summary_cap

Compute the maximum character count for a thread_summary based on the
model's context window. Reserves ~2.5% of the context window in tokens,
converted to characters:

    32K ctx  -> ~800 tokens  -> ~2,400 chars
    64K ctx  -> ~1,600 tokens -> ~6,400 chars
    128K ctx -> ~3,200 tokens -> ~12,800 chars
    256K ctx -> ~6,400 tokens -> ~25,600 chars
    1M ctx   -> ~15,000 tokens (capped) -> ~60,000 chars (capped)

Bounded by $MIN_SUMMARY_CAP / $MAX_SUMMARY_CAP so the summary never
consumes so much context that it harms the current task.

=cut

sub _compute_summary_cap {
    my ($context_window) = @_;
    $context_window //= _default_context_window();
    $context_window = _default_context_window() unless $context_window && $context_window > 0;

    my $ratio = _get_chars_per_token();

    my $cap_tokens = int($context_window * 0.025);
    $cap_tokens = 1000  if $cap_tokens < 1000;
    $cap_tokens = 15000 if $cap_tokens > 15000;

    my $cap_chars = int($cap_tokens * $ratio);
    $cap_chars = $MIN_SUMMARY_CAP if $cap_chars < $MIN_SUMMARY_CAP;
    $cap_chars = $MAX_SUMMARY_CAP if $cap_chars > $MAX_SUMMARY_CAP;
    return $cap_chars;
}

=head2 _compute_limits

Compute context-aware compression limits (counts and text lengths).
128K is the baseline. Scales DOWN for smaller contexts (< 128K,
local models) and UP for larger contexts (>= 256K). See DESIGN NOTES.

=cut

sub _compute_limits {
    my ($context_window) = @_;
    $context_window //= _default_context_window();
    $context_window = _default_context_window() unless $context_window && $context_window > 0;

    my %limits = (
        user_requests      => $DEFAULT_MAX_USER_REQUESTS,
        decisions          => $DEFAULT_MAX_DECISIONS,
        collaboration      => $DEFAULT_MAX_COLLABORATION,
        files              => $DEFAULT_MAX_FILES,
        commits            => $DEFAULT_MAX_COMMITS,
        tool_types         => $DEFAULT_MAX_TOOL_TYPES,
        user_request_len   => $DEFAULT_USER_REQUEST_LEN,
        decision_len       => $DEFAULT_DECISION_LEN,
        collaboration_len  => $DEFAULT_COLLABORATION_LEN,
    );

    if ($context_window < 131072) {
        my $scale = $context_window / 131072;
        for my $k (qw(user_requests decisions collaboration files commits)) {
            $limits{$k} = int($limits{$k} * $scale);
        }
        $limits{user_requests}  = 5  if $limits{user_requests}  < 5;
        $limits{decisions}      = 2  if $limits{decisions}      < 2;
        $limits{collaboration}  = 2  if $limits{collaboration}  < 2;
        $limits{files}          = 10 if $limits{files}          < 10;
        $limits{commits}        = 5  if $limits{commits}        < 5;
    }
    elsif ($context_window >= 262144) {
        my $scale = 1.5;  # 256K and above: start at 1.5x
        $scale = 2.0 if $context_window >= 524288;
        $scale = 4.0 if $context_window >= 1048576;
        for my $k (qw(user_requests decisions collaboration files commits
                      user_request_len decision_len collaboration_len)) {
            $limits{$k} = int($limits{$k} * $scale);
        }
    }

    return \%limits;
}

=head2 compress_messages

Compress a sequence of messages into a summary message.

Strategy:
- Extracts key information: user requests, decisions, files touched,
  commits, collaboration Q/A pairs, and tool operation counts
- Preserves semantic meaning while reducing token count
- Uses context-aware limits (scales with model context window)
- Uses CLIO::Memory::TokenEstimator for token estimation

Arguments:
- $messages: Array reference of message hashes to compress
- %opts: Optional parameters
  * original_task:  Most recent user message (for current task context)
  * previous_summary: Prior thread_summary text (for cross-cycle carryover)
  * context_window:  Model context window in tokens (for scaling)
  * max_chars:       Explicit character cap (overrides context_window-derived cap)

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

    my $original_task    = $opts{original_task}    || '';
    my $previous_summary = $opts{previous_summary} || '';
    my $context_window   = $opts{context_window}   || _default_context_window();
    my $message_count    = scalar(@$messages);

    log_debug('YaRN', "Compressing $message_count messages (ctx=$context_window)");

    # Compute context-aware limits and summary cap.
    my $limits = _compute_limits($context_window);
    my $max_chars = _compute_summary_cap($context_window);
    $max_chars = $opts{max_chars} if exists $opts{max_chars} && defined $opts{max_chars} && $opts{max_chars} > 0;

    my $max_ur_len         = $limits->{user_request_len};
    my $max_decisions      = $limits->{decisions};
    my $max_collaboration  = $limits->{collaboration};
    my $max_files          = $limits->{files};
    my $max_commits        = $limits->{commits};
    my $max_tool_types     = $limits->{tool_types};
    my $max_ur_display     = $limits->{user_requests};
    my $max_collab_len     = $limits->{collaboration_len};
    my $max_decision_len   = $limits->{decision_len};

    # Extraction buckets
    my @user_requests;
    my @commits;
    my @files_touched;
    my @decisions;
    my @collaboration_exchanges;  # Agent question + user response pairs
    my %tool_counts;              # tool_name => total call count (cumulative)

    # Track collaboration tool_call IDs so we can pair them with responses
    my %collab_tool_calls;  # tool_call_id => agent's question text

    # Seed buckets from previous summary so accumulated history isn't lost
    # across trim cycles. _parse_previous_summary parses ALL sections
    # (commits, files, decisions, collaboration, tool counts) — not just
    # user requests — so no historical information is silently dropped
    # between compression cycles.
    if ($previous_summary) {
        _parse_previous_summary($previous_summary, {
            commits                 => \@commits,
            files_touched           => \@files_touched,
            decisions               => \@decisions,
            user_requests           => \@user_requests,
            collaboration_exchanges => \@collaboration_exchanges,
            tool_counts             => \%tool_counts,
        });
    }

    # Carry forward the original task marker. Anchored to the bullet
    # line so body text mentioning "[original]" elsewhere isn't adopted.
    # Also support the legacy "Original task:" header (pre-current format).
    if ($previous_summary =~ /^- \[original\] ([^\n]{1,$max_ur_len})$/m) {
        $opts{_carried_original} = $1;
    } elsif ($previous_summary =~ /- \[original\] ([^\n]{1,$max_ur_len})/s) {
        $opts{_carried_original} = $1;
    }
    if (!$opts{_carried_original}
        && $previous_summary =~ /^Original task: (.{1,$max_ur_len})$/m) {
        $opts{_carried_original} = $1;
    }
    # Carry forward the Current task line (used when caller's
    # original_task is too short to be substantive).
    if ($previous_summary =~ /^Current task: (.{1,$max_ur_len})$/m) {
        my $prev_task = $1;
        $prev_task =~ s/\s+$//;
        if (!$original_task || length($original_task) < 50) {
            $opts{_carried_task} = $prev_task;
        }
    }
    if (!$opts{_carried_task}
        && $previous_summary =~ /^Original task: (.{1,$max_ur_len})$/m) {
        my $prev_task = $1;
        $prev_task =~ s/\s+$//;
        if (!$original_task || length($original_task) < 50) {
            $opts{_carried_task} = $prev_task;
        }
    }

    for my $msg (@$messages) {
        my $role    = $msg->{role}    || '';
        my $content = _extract_content_text($msg->{content});

        if ($role eq 'user') {
            my $summary = substr($content, 0, $max_ur_len);
            $summary .= '...' if length($content) > $max_ur_len;
            push @user_requests, $summary;
        }
        elsif ($role eq 'assistant') {
            # Collaboration/decision messages (identified by metadata or
            # legacy text prefix)
            my $collab_type = $msg->{metadata} && $msg->{metadata}{collaboration};
            if ($collab_type) {
                my $dec = $content;
                $dec =~ s/\s+/ /g;
                push @decisions, substr($dec, 0, $max_decision_len);
            } elsif ($content =~ /\[COLLABORATION\](.+)/s) {
                # Legacy: [COLLABORATION] text prefix (backward compat)
                my $dec = $1;
                $dec =~ s/\s+/ /g;
                push @decisions, substr($dec, 0, $max_decision_len);
            }

            # Tool calls - extract paths, count operations, pair interact calls
            if ($msg->{tool_calls} && ref($msg->{tool_calls}) eq 'ARRAY') {
                for my $tc (@{$msg->{tool_calls}}) {
                    my $name     = $tc->{function}{name}      || 'unknown';
                    my $args_str = $tc->{function}{arguments} || '{}';

                    # Count tool operations (cumulative across carryover)
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
                $question = substr($question, 0, $max_collab_len) . '...'
                    if length($question) > $max_collab_len;
                $response = substr($response, 0, $max_collab_len) . '...'
                    if length($response) > $max_collab_len;
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

    # Deduplicate and limit each bucket.
    # Files: dedup, cap at max_files.
    my %seen;
    @files_touched = grep { !$seen{$_}++ } @files_touched;
    splice(@files_touched, $max_files) if @files_touched > $max_files;

    # Commits: dedup BY HASH (keeping most recent subject for each hash),
    # then cap at max_commits. Dedup by full string would miss same-hash
    # different-subject entries (e.g. truncated subjects that vary).
    @commits = do {
        my %by_hash;
        my @ordered;
        for my $c (reverse @commits) {
            my ($hash) = $c =~ /^([a-f0-9]{7,12})/;
            # Guard against commit strings that don't start with a hex
            # hash (e.g. legacy prose or malformed entries) — without this,
            # $hash is undef, $by_hash{undef}++ triggers an
            # uninitialized-value warning under strict, and the entry gets
            # silently dropped from dedup (kept only by chance of ordering).
            next unless defined $hash;
            next if $by_hash{$hash}++;
            unshift @ordered, $c;
        }
        @ordered;
    };
    splice(@commits, $max_commits) if @commits > $max_commits;

    # Decisions: keep most recent N (reverse, dedup, reverse back).
    @decisions = reverse(@decisions);
    @decisions = do { my %s; grep { !$s{$_}++ } @decisions };
    @decisions = reverse(@decisions);
    splice(@decisions, $max_decisions) if @decisions > $max_decisions;

    # Collaboration exchanges: keep last N (most recent).
    splice(@collaboration_exchanges, 0,
        @collaboration_exchanges > $max_collaboration
            ? @collaboration_exchanges - $max_collaboration : 0);

    # Always preserve the FIRST user request (the original session task)
    # when we have more than the display limit. Use carried original
    # from previous summary if available (survives cycles).
    my $first_user_request;
    if (@user_requests > $max_ur_display) {
        $first_user_request = $user_requests[0];
        splice(@user_requests, 0, 1);
        my $keep = $max_ur_display - 1;
        splice(@user_requests, 0, @user_requests - $keep) if @user_requests > $keep;
    }
    if ($opts{_carried_original}) {
        my $carried = $opts{_carried_original};
        unless (grep { $_ eq $carried } @user_requests) {
            $first_user_request = $carried unless $first_user_request;
        }
    }

    # Find effective task: prefer carried task, then most recent
    # substantive user request, falling back to the caller's
    # original_task. Short acknowledgements ("yes", "go ahead")
    # do not replace a meaningful current task.
    my @all_requests = @user_requests;
    unshift @all_requests, $first_user_request if $first_user_request;

    my $effective_task;
    if ($opts{_carried_task} && length($opts{_carried_task})) {
        $effective_task = $opts{_carried_task};
    } else {
        $effective_task = find_substantive_task(
            $original_task,
            \@all_requests
        );
    }

    # Build summary. Includes tool operations with cumulative counts
    # and collaboration exchanges, in a self-consistent format that
    # _parse_previous_summary can round-trip.
    my @parts;
    push @parts, "<thread_summary>";
    push @parts, "";

    if ($effective_task) {
        push @parts, "Current task: " . substr($effective_task, 0, $max_ur_len);
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

    # Key decisions (collaboration metadata + [COLLABORATION] prefix)
    if (@decisions) {
        push @parts, "Key decisions:";
        for my $d (@decisions) {
            push @parts, "- " . substr($d, 0, $max_decision_len);
        }
        push @parts, "";
    }

    # Files the model worked on (deduped, path-only).
    if (@files_touched) {
        push @parts, "Files worked on:";
        for my $f (@files_touched) {
            push @parts, "- " . substr($f, 0, 200);
        }
        push @parts, "";
    }

    # Tool operations: cumulative counts per tool type (deduplicated).
    if (%tool_counts) {
        push @parts, "Tool operations:";
        my @sorted = sort { $tool_counts{$b} <=> $tool_counts{$a}
                             || $a cmp $b } keys %tool_counts;
        my $shown = 0;
        for my $name (@sorted) {
            last if $shown >= $max_tool_types;
            push @parts, "- $name: $tool_counts{$name}";
            $shown++;
        }
        push @parts, "";
    }

    # Commits made during the dropped turns (deduped, most recent kept).
    if (@commits) {
        push @parts, "Commits:";
        push @parts, "- $_" for @commits;
        push @parts, "";
    }

    # Collaboration Q/A exchanges (from interact tool calls).
    if (@collaboration_exchanges) {
        push @parts, "Discussion:";
        for my $ex (@collaboration_exchanges) {
            my $q = substr($ex->{question}, 0, $max_collab_len);
            $q =~ s/\s+/ /g;
            my $a = substr($ex->{response}, 0, $max_collab_len);
            $a =~ s/\s+/ /g;
            push @parts, "- Q: " . $q;
            push @parts, "  A: " . $a;
        }
        push @parts, "";
    }

    push @parts, "</thread_summary>";

    my $summary_content = join("\n", @parts);

    # Cap at the context-aware limit (max_chars or _compute_summary_cap).
    if (length($summary_content) > $max_chars) {
        $summary_content = _truncate($summary_content, $max_chars);
        $summary_content .= '...';
    }

    # Estimate token counts using TokenEstimator (learned ratio).
    require CLIO::Memory::TokenEstimator;
    my $original_tokens = 0;
    for my $msg (@$messages) {
        $original_tokens += CLIO::Memory::TokenEstimator::estimate_tokens($msg->{content} || '');
    }
    my $compressed_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($summary_content);

    if ($original_tokens > 0) {
        log_debug('YaRN', "Compression: $original_tokens -> $compressed_tokens tokens (" .
            sprintf("%.1f", 100 * ($original_tokens - $compressed_tokens) / $original_tokens) . "% reduction");
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

    # Scan messages newest-first for the most recent SUBSTANTIVE user
    # message (>= 50 chars). Short acknowledgements like "yes", "go ahead",
    # "do it" are skipped — they do not represent a meaningful current
    # task and would cause the compressed summary to lose the real task
    # context. This matches the documented contract (">= 50 chars").
    if ($messages && ref($messages) eq 'ARRAY') {
        for my $item (reverse @$messages) {
            if (ref($item) eq 'HASH') {
                next unless ($item->{role} // '') eq 'user';
                my $content = _extract_content_text($item->{content});
                return $content if length($content) >= 50;
            } else {
                # Plain string (e.g. from @user_requests)
                return $item if defined $item && length($item) >= 50;
            }
        }
    }

    # No substantive user message (>= 50 chars) found. Fall back to
    # any non-empty user message, so we still surface *something*
    # rather than silently losing all task context.
    if ($messages && ref($messages) eq 'ARRAY') {
        for my $item (reverse @$messages) {
            if (ref($item) eq 'HASH') {
                next unless ($item->{role} // '') eq 'user';
                my $content = _extract_content_text($item->{content});
                return $content if length($content) > 0;
            } else {
                return $item if defined $item && length($item) > 0;
            }
        }
    }

    # No user message found at all - fall back to candidate
    # (which may be the active_task from session goals or the
    # current user input)
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
        my $content = _extract_content_text($item->{content});
        return $content if length($content) >= $min_len;
    }

    # Fall back to whatever user message we have, even if short.
    for my $item (@$thread) {
        next unless ref($item) eq 'HASH';
        next unless ($item->{role} // '') eq 'user';
        my $content = _extract_content_text($item->{content});
        return $content if length $content;
    }

    return '';
}

# Parse ALL structured sections from a previous thread_summary to seed
# extraction buckets. This is the cross-cycle carryover mechanism: without
# parsing commits, files, decisions, tool counts, and collaboration
# exchanges, those sections would be silently lost between trim cycles (only
# user_requests were parsed previously, causing progressive information loss).
#
# Supports both the current format (produced by this function's output) and
# legacy formats ("Original task:", "Files created/modified:",
# "Tool usage:", "Tools:") for backward compatibility with existing
# serialized YaRN state.
sub _parse_previous_summary {
    my ($summary_text, $buckets) = @_;

    return unless $summary_text && $buckets;

    # Strip thread_summary tags
    $summary_text =~ s/<\/?thread_summary>//g;

    my $user_requests          = $buckets->{user_requests}          || [];
    my $decisions              = $buckets->{decisions}              || [];
    my $files_touched          = $buckets->{files_touched}          || [];
    my $commits                = $buckets->{commits}                || [];
    my $collaboration_exchanges = $buckets->{collaboration_exchanges} || [];
    my $tool_counts            = $buckets->{tool_counts}            || {};

    # Parse a bulleted section: captures lines starting with "- " after
    # the header line, stopping at the next header (Capitalized words +
    # colon) or end of text.
    my $parse_bullets = sub {
        my ($text, $header_re) = @_;
        return unless $text =~ /(?:^|\n)$header_re:\s*\n(.*?)(?=\n(?:[A-Z][\w ]+:|\z))/s;
        my $block = $1;
        my @items;
        for my $line (split /\n/, $block) {
            if ($line =~ /^\s*- (.+)$/) {
                push @items, $1;
            }
        }
        return @items;
    };

    # Parse a comma-separated file list (legacy format: "path1, path2")
    my $parse_file_list = sub {
        my ($text, $header_re) = @_;
        return unless $text =~ /(?:^|\n)$header_re:\s*\n([^\n]+)/s;
        my $line = $1;
        return unless $line =~ /,/;
        my @items;
        for my $f (split /,\s*/, $line) {
            push @items, $f if length $f;
        }
        return @items;
    };

    # --- Recent user requests (current + legacy headers) ---
    my @items = $parse_bullets->($summary_text, qr/Recent user requests/i);
    for my $item (@items) {
        # Strip [original] prefix for user_requests carryover
        $item =~ s/^\[original\]\s*//;
        push @$user_requests, $item;
    }

    # --- Key decisions ---
    @items = $parse_bullets->($summary_text, qr/Key decisions/i);
    push @$decisions, @items if @items;

    # --- Files touched (current one-per-line + legacy comma-separated) ---
    # Try one-per-line format first, then comma-separated
    @items = $parse_bullets->($summary_text, qr/Files worked on/i);
    push @$files_touched, @items if @items;
    if (!@items) {
        # Legacy: "Files created/modified:" with one-per-line bullets
        @items = $parse_bullets->($summary_text, qr/Files created\/modified/i);
        push @$files_touched, @items if @items;
    }
    if (!@items) {
        # Legacy: "Files:" with comma-separated list
        @items = $parse_file_list->($summary_text, qr/^Files:/m);
        push @$files_touched, @items if @items;
    }

    # --- Tool operations (current "Tool operations:" + legacy "Tool usage:" / "Tools:") ---
    for my $hdr (qr/Tool operations/i, qr/Tool usage/i, qr/^Tools:/m) {
        @items = $parse_bullets->($summary_text, $hdr);
        if (@items) {
            for my $item (@items) {
                if ($item =~ /^(\w[\w_]*)\s*:\s*(\d+)/) {
                    my ($name, $count) = ($1, $2);
                    # Accumulate counts across carryover cycles
                    $tool_counts->{$name} += $count;
                }
            }
            last;
        }
    }

    # --- Commits (current "Commits:" + legacy "Git commits made during compressed period:") ---
    for my $hdr (qr/Commits/i, qr/Git commits made during compressed period/i) {
        @items = $parse_bullets->($summary_text, $hdr);
        if (@items) {
            push @$commits, @items;
            last;
        }
    }

    # --- Discussion / collaboration Q&A ---
    if ($summary_text =~ /(?:^|\n)Discussion:\s*\n(.*?)(?=\n(?:[A-Z][\w ]+:|\z))/s) {
        my $block = $1;
        my @lines = split /\n/, $block;
        my $i = 0;
        while ($i < @lines) {
            # Use separate match statements so each captures its own $1.
            # A single "regex1 && regex2" test would leave $1 bound to the
            # second (A:) regex's capture, making question => $1 return the
            # answer text. And storing $lines[$i+1] directly would include
            # the "  A: " prefix, doubling it on re-emission.
            my ($q_text) = $lines[$i] =~ /^\s*- Q:\s*(.+)$/;
            my ($a_text) = ($i + 1 < @lines)
                ? ($lines[$i + 1] =~ /^\s*A:\s*(.+)$/ ? $1 : undef)
                : undef;
            if (defined $q_text && defined $a_text) {
                push @$collaboration_exchanges, {
                    question => $q_text,
                    response => $a_text,
                };
                $i += 2;
            } else {
                $i++;
            }
        }
    }

    return 1;
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
  * C<context_window>  : Model context window in tokens (for context-aware
    scaling of limits and summary cap). Defaults to DEFAULT_CONTEXT_WINDOW.
  * C<max_chars>       : Explicit character cap for the summary. When
    provided, overrides the context-window-derived cap.

Returns: Hashref as from L</compress_messages>

    my $result = $yarn->compress_for_context_recovery(\@dropped,
        original_task => $task, context_window => 128000);

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
        context_window   => $opts{context_window},
        max_chars        => $opts{max_chars},
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
        my $content = _extract_content_text($msg->{content});
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
2. B<State> (session trim): removed — storage-level trimming was
   eliminated; the projection compresses dropped turns into
   compressed_tail instead of mutating session history.
3. B<WorkflowOrchestrator> (reactive): C<_compress_dropped_for_recovery>
   compresses dropped messages after a token-limit error from the provider.

All paths produce a single C<< <thread_summary> >> message (the
compression format marker) that preserves:
- User requests (truncated to ~600 chars each; the first/original
  request kept as C<<- [original] >>)
- Key decisions (collaboration exchanges; capped at 8 for 128K+)
- Files worked on (path-only, deduplicated; capped at 50 for 128K+)
- Tool operations (cumulative counts per tool type; top 8 shown)
- Commits (deduped, most recent kept; capped at 30 for 128K+)
- Discussion (collaboration Q/A pairs from interact calls; capped at 10 for 128K+)

The current task line ("Current task:") reflects the most recent
substantive direction. Short acknowledgements ("yes", "go ahead")
do not replace a meaningful current task — they are filtered or
outvoted by longer substantive requests.

=head2 Context-Aware Budgeting

The summary size and extraction limits scale with the model's context
window (passed as C<context_window> tokens). This replaces the previous
hardcoded cap (C<UC_CAP = 4000>) and fixed limits.

Summary cap (C<_compute_summary_cap>): ~2.5% of the context window in
tokens, converted to characters via the TokenEstimator ratio. Bounded
by C<$MIN_SUMMARY_CAP> (4,000) and C<$MAX_SUMMARY_CAP> (60,000).

    32K ctx  -> ~2,400 chars
    64K ctx  -> ~6,400 chars
    128K ctx -> ~12,800 chars
    256K ctx -> ~25,600 chars
    1M ctx   -> ~60,000 chars (capped)

Extraction limits (C<_compute_limits>): 128K is the baseline
(16 user requests, 8 decisions, 10 discussion pairs, 50 files,
30 commits, 8 tool types). Scales DOWN for contexts below 128K
(local models, 64K and smaller) and UP for 256K+ contexts.

Callers that know the model's context window should pass it:
C<ContextBuilder> (via C<build_projection>), C<MessageValidator>
(via C<$caps>), and C<WorkflowOrchestrator> (via C<api_manager>).
When C<context_window> is not provided, the default is
C<DEFAULT_CONTEXT_WINDOW> (128K). An explicit C<max_chars> option
overrides the computed cap.

=head2 Large-Context Scaling

The design target is 128K contexts with a summary budget of ~12K-16K
chars. For 256K+ contexts, limits scale proportionally so the
historical projection grows richer without requiring code changes.
For 1M-context models (MiniMax-M3, Z.A.I. GLM-5), the summary cap
reaches its 60K ceiling while extraction limits scale 4x.

For contexts below 128K (local inference at 64K/32K), limits scale
down proportionally with floors that ensure usable recall even on
small windows.

=head2 Cross-Cycle Carryover and Lossless Durable History

C<compress_for_context_recovery()> extracts the most recent
C<< <thread_summary> >> block from the message array (via
C<_extract_thread_summary_from_messages>) and feeds it as
C<previous_summary> to C<compress_messages>, so accumulated summaries
survive successive trim cycles instead of being reset each time.
C<_parse_previous_summary> parses ALL sections (user requests,
decisions, files, commits, tool operations, discussion) — not just
user requests — so no historical information is silently dropped
between cycles.

C<compress_messages> accepts C<%tool_counts> (accumulated counts) in
the buckets hash; these are added to rather than replaced, producing
cumulative tool-operation totals across the entire session.

C<YaRN> is the durable, lossless record. C<State::add_message> stores
every message in both C<$self->{history}> (active window) and
C<$self->{yarn}> (durable thread). C<get_thread> returns the full
history; C<add_to_thread> appends without ever removing. The
C<< <thread_summary> >> is a lossy projection — a disposable view
over the durable truth — and is never written back to the thread.
C<recover_substantive_task> walks the durable thread to find the
original task when active history has been trimmed past it.

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

GPL-3.0-only

=cut

1;
