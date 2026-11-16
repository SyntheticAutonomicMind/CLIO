# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::ToolLoopDetector;

use strict;
use warnings;
use utf8;
use feature 'say';
use CLIO::Tools::Registry ();

=head1 NAME

CLIO::Core::ToolLoopDetector - Notice non-converging runs of successful near-duplicate tool calls

=head1 SYNOPSIS

    use CLIO::Core::ToolLoopDetector;

    my $detector = CLIO::Core::ToolLoopDetector->new();
    my $verdict = $detector->record_call('terminal_operations', $tool_args, $result_content);
    if ($verdict->{guidance}) {
        # Append $verdict->{guidance} to the tool result the model sees.
    }

=head1 DESCRIPTION

Two existing mechanisms collapse repeated tool calls, and neither notices
the failure mode where every call SUCCEEDS but nothing new comes back:

=over 4

=item * L<CLIO::Core::ToolErrorGuidance> plus the error-loop breaker in
WorkflowOrchestrator handles repeated tool ERRORS.

=item * ContextBuilder collapses byte-identical repeated calls in the
context projection.

=item * This module notices the loop where every call succeeds with
DIFFERENT arguments but near-identical results - a model re-running a
search against the same target fifteen times with new wording.

=back

This module is a B<guidance provider>, not a circuit breaker. It watches
recent read-only tool calls in a sliding window, counts calls sharing a
loose signature that collapses argument variations (the search term is
dropped; the tool, operation, and target are kept), and gates on result
similarity: the current result must be near-identical (token overlap) to
an earlier result with the same signature (not necessarily the
immediately previous one). A search that keeps producing new information
never produces guidance.

When a run is confirmed, C<record_call> returns a note explaining the
pattern with the measured overlap and concrete exits. The caller appends
the note to the tool result the model sees. A full notice fires at
C<guidance_threshold> and a compact reminder repeats every
C<reminder_interval> similar calls while the pattern continues. The
module never ends a turn, never injects user-role text, and never
escalates to enforcement: ending a turn is the orchestrator's decision
(iteration budget, error handling), not a detector's.

Calls are classified in three ways:

=over 4

=item * B<tracked> - search/discovery reads whose results can vary and
repeat (grep/search/list/outline/web fetch). These enter the window.

=item * B<neutral> - reads that return stable content by design
(read_file, file_exists) and bookkeeping operations (todo_read,
skill_list, interact). These are ignored: they neither enter the window
nor clear it. A model that reads a file between searches is not looping,
and the read is not evidence that the search loop stopped.

=item * B<mutating> - writes, patches, builds, and unknown tools. These
reset the window: the world changed, so prior search runs no longer
indicate thrash.

=back

All thresholds are constructor arguments so tests can exercise the
guidance ladder without large call counts.

=cut

# Default thresholds. Overridable via constructor arguments.
our $DEFAULT_WINDOW_SIZE        = 8;      # sliding window of recent calls
our $DEFAULT_GUIDANCE_THRESHOLD = 3;      # similar results before the first notice
our $DEFAULT_REMINDER_INTERVAL  = 2;      # similar calls between reminders
our $DEFAULT_SIMILARITY         = 0.75;   # token-overlap ratio for "same result"
our $DEFAULT_TOKENIZE_BYTES     = 65536;  # content prefix considered for similarity

# Terminal commands recognized as read-only. Anything else (make, perl,
# npm, git mutations, ...) is treated as mutating and clears the window.
# Deliberately strict: a mutating command that slips through as read-only
# only weakens detection slightly, but a read-only command treated as
# mutating suppresses detection entirely.
my %READ_ONLY_COMMANDS = map { $_ => 1 } qw(
    grep egrep fgrep zgrep rg ack ag
    sed awk
    ls find locate fd
    cat zcat head tail
    wc sort uniq comm cut paste
    diff diff3 cmp
    stat file du df free
    date pwd which whereis type
    whoami id groups
    printf echo true false test
    jq nl rev fold fmt column tree
    md5sum sha256sum sha1sum
    xxd hexdump od base64
    strings
    ps pgrep pidof
    basename dirname realpath readlink
    printenv
    cksum sha512sum
);

# git subcommands that only read repository state. Everything else
# (add, commit, checkout, reset, ...) is state-changing.
my %READ_ONLY_GIT_SUBCOMMANDS = map { $_ => 1 } qw(
    log status diff show blame
    describe rev-parse ls-files ls-remote
    cat-file shortlog reflog
);

# Command wrappers that sit in front of the real command. Stripped before
# classification and signature extraction, so "cd repo && sudo grep ..."
# is recognized as the grep it really is.
my %WRAPPERS = map { $_ => 1 } qw(
    sudo sudoedit doas time command builtin nohup env nice ionice stdbuf
    timeout xargs
);

# Operational detail for wrappers whose flags consume a following value.
# Parsing these keeps the first non-flag token from being mistaken for the
# command (e.g. "sudo -u root grep" -> grep, not root).
my %WRAPPER_FLAGS_WITH_VALUE = (
    sudo => { map { $_ => 1 } qw(
        -u -g -p -C -T -U -h --user --group --prompt --close-from
        --command-timeout --other-user --host
    ) },
    nice     => { map { $_ => 1 } qw(-n --adjustment) },
    ionice   => { map { $_ => 1 } qw(-c -n -p -t --class --classdata) },
    stdbuf   => { map { $_ => 1 } qw(-i -o -e --input --output --error) },
    timeout  => { map { $_ => 1 } qw(-s -k --signal --kill-after) },
    env      => { map { $_ => 1 } qw(-u --unset -C --chdir -S --split-string) },
    xargs    => { map { $_ => 1 } qw(-n -I -P -L -s -d -E -a) },
);

# file_operations operations whose results can vary across calls and
# repeat without progress: search and discovery. read_file and
# file_exists are NOT here. They return identical content by design (the
# same path always yields the same bytes), so they are neutral: ignored
# by the window rather than counted as a loop or treated as a reset.
my %READ_ONLY_FILE_OPS = map { $_ => 1 } qw(
    list_dir get_file_info
    file_search grep_search semantic_search
    get_errors read_tool_result
);

# file_operations operations that read stable content. Ignored entirely.
my %NEUTRAL_FILE_OPS = map { $_ => 1 } qw(
    read_file file_exists
);

# version_control operations that only read state.
my %READ_ONLY_GIT_OPS = map { $_ => 1 } qw(
    status log diff blame
);

# memory_operations operations that search rather than write.
my $READ_ONLY_MEMORY_RE = qr/^(?:retrieve|search|list|recall_sessions|ltm_stats)$/;

=head1 METHODS

=head2 new

Arguments: %args with optional keys window_size, guidance_threshold,
reminder_interval, similarity_threshold, tokenize_bytes (all numeric;
defaults from the package-level $DEFAULT_* constants).

Returns: blessed detector with fresh (empty) state.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = {
        window_size          => $args{window_size} // $DEFAULT_WINDOW_SIZE,
        guidance_threshold   => $args{guidance_threshold} // $DEFAULT_GUIDANCE_THRESHOLD,
        reminder_interval    => $args{reminder_interval} // $DEFAULT_REMINDER_INTERVAL,
        similarity_threshold => $args{similarity_threshold} // $DEFAULT_SIMILARITY,
        tokenize_bytes       => $args{tokenize_bytes} // $DEFAULT_TOKENIZE_BYTES,
    };
    bless $self, $class;
    $self->reset();
    return $self;
}

=head2 reset

Clears the sliding window and per-signature notice state. Called by the
orchestrator at the start of every turn (loop tracking is per-turn, not
per-session), on a mutating tool call, and whenever the interact tool
returns user input - user engagement is a strategy change, so old runs
no longer mean anything.

Returns: $self.

=cut

sub reset {
    my ($self) = @_;
    $self->{state} = {
        window     => [],
        call_index => 0,
        notice     => {},    # sig => call_index of the last guidance emit
    };
    return $self;
}

=head2 record_call

Record a successful tool call and evaluate it against recent history.

Arguments:
    $tool_name    - tool name as dispatched (canonical or emitted callable)
    $args         - parsed tool arguments hashref (or undef)
    $content      - the result content the model will receive (string)
    $display_name - optional name the model actually called, used in text

Returns a hashref:
    tracked  - 1 if the call entered the loop window, 0 for neutral and
               mutating calls
    count    - number of window entries sharing this call's signature
    sig      - the loose signature of this call ('' when not tracked)
    level    - 0 none, 1 notice, 2 reminder
    guidance - guidance note string to append to the tool result, or undef

No field in this result authorizes ending the turn. Callers decide that
on their own authority.

=cut

sub record_call {
    my ($self, $tool_name, $args, $content, $display_name) = @_;
    $args = {} unless ref($args) eq 'HASH';
    my $quiet = { tracked => 0, count => 0, sig => '', level => 0, guidance => undef };

    my ($tool, $op) = $self->_resolve_call($tool_name, $args);
    my $kind = $self->_classify($tool, $op, $args);

    if ($kind eq 'mutating') {
        # The model changed the world; prior search runs are no longer
        # evidence of thrash.
        $self->reset();
        return $quiet;
    }
    # Neutral reads are neither loop evidence nor a strategy change. They
    # must not reset the window: reads interleave with searches constantly,
    # and resetting here would make an ongoing loop invisible.
    return $quiet if $kind eq 'neutral';

    my $sig    = $self->call_signature($tool_name, $args);
    my $st     = $self->{state};
    my $tokens = $self->_tokenize($content);

    # Result-similarity gate: compare this result against ANY earlier
    # window entry with the same signature, keeping the best match. The
    # current call is excluded because this runs before the push. Checking
    # any prior run (not just the immediately previous one) keeps
    # interleaved searches detectable: A, B, A still fires when the second
    # A result repeats the first A result.
    my $best_sim = 0;
    for my $entry (@{ $st->{window} }) {
        next unless $entry->{sig} eq $sig;
        my $sim = $self->_similarity($tokens, $entry->{tokens});
        $best_sim = $sim if $sim > $best_sim;
    }

    push @{ $st->{window} }, { sig => $sig, tokens => $tokens };
    shift @{ $st->{window} } while @{ $st->{window} } > $self->{window_size};

    my $count = 0;
    $count++ for grep { $_->{sig} eq $sig } @{ $st->{window} };

    $st->{call_index}++;
    $self->_prune_notice_state();

    # A search producing new information is convergence, not a loop.
    return { tracked => 1, count => $count, sig => $sig, level => 0, guidance => undef }
        if $best_sim < $self->{similarity_threshold};

    return { tracked => 1, count => $count, sig => $sig, level => 0, guidance => undef }
        if $count < $self->{guidance_threshold};

    my $last   = $st->{notice}{$sig};
    my $source = $display_name // $tool;
    my $pct    = sprintf('%d', $best_sim * 100 + 0.5);

    my $level;
    my $text;
    if (!defined $last) {
        $level = 1;
        $text  = $self->_notice_text($source, $sig, $count, $pct);
    } elsif (($st->{call_index} - $last) >= $self->{reminder_interval}) {
        $level = 2;
        $text  = $self->_reminder_text($source, $count, $pct);
    } else {
        return { tracked => 1, count => $count, sig => $sig, level => 0, guidance => undef };
    }

    $st->{notice}{$sig} = $st->{call_index};

    return { tracked => 1, count => $count, sig => $sig, level => $level, guidance => $text };
}

=head2 call_signature

Compute the loose signature for a tool call. Argument variations that do
not change the target collapse to one signature: the search term is
dropped, flags are dropped, command wrappers are stripped, and the tool,
operation, and target are kept.

Arguments: $tool_name, $args (parsed arguments hashref or undef)

Returns: signature string.

=cut

sub call_signature {
    my ($self, $tool_name, $args) = @_;
    $args = {} unless ref($args) eq 'HASH';

    my ($tool, $op) = $self->_resolve_call($tool_name, $args);

    if ($tool eq 'terminal_operations') {
        return $self->_terminal_signature($args->{command} // '', $op // '');
    }

    if ($tool eq 'file_operations') {
        if ($op eq 'grep_search') {
            # Drop the query; keep the path and the file glob filter.
            return $self->_scoped_signature($tool, $op, $args, qw(path pattern));
        }
        if ($op eq 'file_search') {
            # The pattern IS the search term here; the directory is the target.
            return $self->_scoped_signature($tool, $op, $args, qw(directory));
        }
        if ($op eq 'semantic_search') {
            return $self->_scoped_signature($tool, $op, $args, qw(scope));
        }
        if ($op eq 'read_tool_result') {
            return $self->_scoped_signature($tool, $op, $args, qw(toolCallId offset length));
        }
        if ($op =~ /^(?:list_dir|get_errors|get_file_info)$/) {
            return $self->_scoped_signature($tool, $op, $args, qw(path recursive));
        }
    }

    if ($tool eq 'web_operations' && $op eq 'search_web') {
        # Every query looks different; the repeated search is the loop.
        return join('|', $tool, $op);
    }

    if ($tool eq 'memory_operations' && $op =~ /^(?:search|recall_sessions)$/) {
        return join('|', $tool, $op);
    }

    # Generic fallback: tool name + operation + normalized scalar params.
    # Deliberately strict (near byte-identical calls collide) because the
    # operations above cover the observed loop modes.
    my @parts = ($tool);
    push @parts, $op if defined $op && length $op;
    for my $key (sort keys %$args) {
        next if $key eq 'operation';
        my $value = $args->{$key};
        next if !defined $value || ref $value;
        next unless length $value;
        (my $norm = lc $value) =~ s/\s+/ /g;
        push @parts, "$key=" . substr($norm, 0, 60);
    }
    return join('|', @parts);
}

=head1 INTERNAL METHODS

=head2 _resolve_call (Internal)

Resolve a callable or grouping name plus operation to the canonical tool
and operation, so the same logical call gets the same signature and
classification regardless of which name the caller used.

Returns: ($tool, $operation)

=cut

sub _resolve_call {
    my ($self, $tool_name, $args) = @_;
    $tool_name = 'unknown' unless defined $tool_name && length $tool_name;
    my $op = ref($args) eq 'HASH' ? $args->{operation} : undef;

    my $owner = CLIO::Tools::Registry->classify_callable($tool_name, $op);
    if ($owner) {
        my $resolved_op = defined $owner->{operation} ? $owner->{operation} : $op;
        return ($owner->{tool}, $resolved_op);
    }
    return ($tool_name, $op);
}

=head2 _classify (Internal)

Classify a resolved call as 'tracked', 'neutral', or 'mutating'.

=cut

sub _classify {
    my ($self, $tool, $op, $args) = @_;

    if (!defined $op && CLIO::Tools::Registry->is_grouping_name($tool)) {
        # None of the tables below can match, so the call lands in the
        # mutating default and resets the window. That is the safe answer
        # for an unclassifiable call, but it silently disables detection -
        # say so, so the cause is diagnosable from logs.
        log_debug('ToolLoopDetector',
            "Grouping name '$tool' recorded without an operation - "
            . "treating as mutating (loop detection disabled for it)");
    }

    return 'mutating' if $tool eq 'apply_patch';

    if ($tool eq 'file_operations') {
        my $operation = $op // '';
        return 'tracked'  if $READ_ONLY_FILE_OPS{$operation};
        return 'neutral'  if $NEUTRAL_FILE_OPS{$operation};
        return 'mutating';
    }
    if ($tool eq 'version_control') {
        return ($READ_ONLY_GIT_OPS{ $op // '' }) ? 'tracked' : 'mutating';
    }
    if ($tool eq 'memory_operations') {
        return (($op // '') =~ $READ_ONLY_MEMORY_RE) ? 'tracked' : 'mutating';
    }
    if ($tool eq 'terminal_operations') {
        return 'neutral' if ($op // '') eq 'validate';
        my $head = $self->_terminal_head($args->{command} // '');
        my ($binary) = $head =~ /^\s*(\S+)/;
        $binary = lc($binary // '');
        $binary =~ s{^.*/}{};
        # Empty/malformed command is not productive work and not a
        # strategy signal: treat it as mutating so it clears the window
        # instead of polluting a legitimate read-only run.
        return 'mutating' unless length $binary;
        return 'tracked' if $READ_ONLY_COMMANDS{$binary};
        if ($binary eq 'git') {
            my ($sub) = $head =~ /^\s*git\s+([^\s-]\S*)/;
            return ($READ_ONLY_GIT_SUBCOMMANDS{ lc($sub // '') }) ? 'tracked' : 'mutating';
        }
        return 'mutating';
    }
    if ($tool eq 'code_intelligence') {
        return 'tracked';  # list_usages / outline / search_history
    }
    if ($tool eq 'web_operations') {
        return (($op // '') =~ /^(?:search_web|fetch_url)$/) ? 'tracked' : 'mutating';
    }
    if ($tool eq 'todo_operations') {
        return (($op // '') eq 'read') ? 'neutral' : 'mutating';
    }
    if ($tool eq 'skill_operations') {
        return (($op // '') =~ /^(?:list|load)$/) ? 'neutral' : 'mutating';
    }
    if ($tool eq 'interact') {
        return 'neutral';
    }

    # Unknown tools: conservative - treat as mutating so the window is
    # cleared rather than letting an unrelated call inherit a search run.
    return 'mutating';
}

=head2 _is_state_changing (Internal)

Compatibility wrapper: true only for calls that reset the window.

=cut

sub _is_state_changing {
    my ($self, $tool_name, $args) = @_;
    my ($tool, $op) = $self->_resolve_call($tool_name, $args);
    return $self->_classify($tool, $op, $args) eq 'mutating' ? 1 : 0;
}

=head2 _terminal_head (Internal)

Return the command word of the first pipeline stage after stripping
quoted strings, command wrappers, leading assignments, and leading
C<cd> stages ("cd repo && grep ..." is a grep).

=cut

sub _terminal_head {
    my ($self, $command) = @_;
    $command = '' unless defined $command;

    # Quoted content is neutralized BEFORE pipeline splitting so a pipe
    # inside a grep pattern does not truncate the stage.
    (my $stripped = $command) =~ s/'[^']*'/ /g;
    $stripped =~ s/"[^"]*"/ /g;

    for my $stage (split /\s*(?:&&|\|\||;)\s*/, $stripped) {
        my ($head) = split /\s*\|\s*/, $stage, 2;
        next unless defined $head;
        my $normalized = $self->_strip_wrappers($head);
        next unless length $normalized;
        # A bare cd changes nothing in a non-persistent shell.
        next if $normalized =~ /^\s*cd(?:\s|$)/;
        return $normalized;
    }
    return '';
}

=head2 _strip_wrappers (Internal)

Drop leading environment assignments and command wrappers (with their
flag values) so the first token is the command that actually runs.

=cut

sub _strip_wrappers {
    my ($self, $stage) = @_;
    my @tokens = split /\s+/, $stage // '';

    while (@tokens) {
        my $token = $tokens[0];

        # VAR=value prefix
        if ($token =~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
            shift @tokens;
            next;
        }

        last unless $WRAPPERS{$token};
        my $wrapper = $token;
        shift @tokens;

        my $valued = $WRAPPER_FLAGS_WITH_VALUE{$wrapper} || {};
        while (@tokens && $tokens[0] =~ /^-/) {
            my $flag = shift @tokens;
            # --flag=value carries its value inline.
            shift @tokens if $flag !~ /=/ && $valued->{$flag} && @tokens;
        }

        # timeout's duration operand comes after its flags.
        if ($wrapper eq 'timeout' && @tokens && $tokens[0] !~ /^-/) {
            shift @tokens;
        }
    }

    return join(' ', @tokens);
}

=head2 _terminal_signature (Internal)

Signature for a terminal command: the operation, the command word, the
git subcommand when present, and the last non-flag operand as the
target. Relative directory names count as targets ("grep foo lib"); an
earlier version kept only path-like tokens, which collapsed searches in
different relative directories into one signature.

=cut

sub _terminal_signature {
    my ($self, $command, $operation) = @_;
    my $head = $self->_terminal_head($command);
    my @tokens = split /\s+/, $head;
    my $binary = lc(shift @tokens // '');
    $binary =~ s{^.*/}{};

    my @parts = ('terminal', $operation // '', $binary);
    my $subcommand = '';

    if ($binary eq 'git') {
        for my $token (@tokens) {
            next if $token =~ /^-/;
            $subcommand = lc $token;
            last;
        }
        # The subcommand alone identifies the read. Option values are not
        # targets ("git log -n 5" must collapse with "git log --oneline"),
        # and the result-similarity gate handles different refs.
        push @parts, $subcommand if length $subcommand;
        return join('|', @parts);
    }

    my @operands = grep { !/^-/ && !/^[A-Za-z_][A-Za-z0-9_]*=/ } @tokens;
    push @parts, lc $operands[-1] if @operands;

    return join('|', @parts);
}

=head2 _scoped_signature (Internal)

Signature built from the tool, operation, and the named scope keys.
Values not present are omitted, so calls that differ only in the dropped
arguments collapse to the same signature.

=cut

sub _scoped_signature {
    my ($self, $tool, $op, $args, @keys) = @_;
    my @parts = ($tool, $op // '');
    for my $key (@keys) {
        my $value = $args->{$key};
        next if !defined $value || ref $value || !length $value;
        (my $norm = lc $value) =~ s/\s+/ /g;
        push @parts, "$key=" . substr($norm, 0, 60);
    }
    return join('|', @parts);
}

=head2 _similarity (Internal)

Token-overlap (Jaccard) ratio between two result token lists. Two empty
results are identical (ratio 1: repeated no-result searches are a loop
signal); an empty and a non-empty result share nothing (ratio 0).

=cut

sub _similarity {
    my ($self, $a, $b) = @_;
    $a //= [];
    $b //= [];
    return 1 unless @$a || @$b;      # both empty: identical
    return 0 if !@$a || !@$b;        # one empty: nothing in common
    my %b_set = map { $_ => 1 } @$b;
    my $inter = grep { $b_set{$_} } @$a;
    my $union = scalar(@$a) + scalar(@$b) - $inter;
    return $union ? ($inter / $union) : 1;
}

=head2 _tokenize (Internal)

Lowercase, strip non-alphanumerics, return a sorted unique token list.
Only the first C<tokenize_bytes> of the content are considered, which
bounds memory for very large tool results.

=cut

sub _tokenize {
    my ($self, $text) = @_;
    return [] if !defined $text || ref $text || !length $text;
    $text = substr($text, 0, $self->{tokenize_bytes})
        if length $text > $self->{tokenize_bytes};
    (my $norm = lc $text) =~ s/[^a-z0-9]+/ /g;
    my %set = map { $_ => 1 } grep { length } split /\s+/, $norm;
    return [sort keys %set];
}

=head2 _prune_notice_state (Internal)

Drop notice entries older than the window. A signature that is still in
the window always has a last emit within the window, so pruning cannot
re-fire a notice for an active run.

=cut

sub _prune_notice_state {
    my ($self) = @_;
    my $st     = $self->{state};
    my $cutoff = $st->{call_index} - $self->{window_size};
    for my $sig (keys %{ $st->{notice} }) {
        delete $st->{notice}{$sig} if $st->{notice}{$sig} < $cutoff;
    }
    return;
}

=head2 _notice_text (Internal)

First guidance note for a confirmed run. Mirrors ToolErrorGuidance:
state the problem, show the evidence, give concrete exits. No threat of
enforcement, because this module has none.

=cut

sub _notice_text {
    my ($self, $tool_name, $sig, $count, $pct) = @_;
    return "LOOP NOTICE (from CLIO): '$tool_name' has now returned a near-identical "
         . "result $count times (signature: $sig; latest result ${pct}% identical to an "
         . "earlier one). The search is not producing new information. The data you need "
         . "is already in this conversation.\n"
         . "Prefer one of these next steps:\n"
         . "1. Act on what you already have - make the edit, run the build, or write the answer.\n"
         . "2. Change the question, not just the wording: a different tool or a different target.\n"
         . "3. If the remaining work needs a decision only the user can make, ask.\n"
         . "This note repeats while the pattern continues; it does not end the turn.";
}

=head2 _reminder_text (Internal)

Compact reminder for a run that continued after the first notice.

=cut

sub _reminder_text {
    my ($self, $tool_name, $count, $pct) = @_;
    return "LOOP REMINDER (from CLIO): '$tool_name' returned another near-identical "
         . "result (#$count, ${pct}% overlap). Nothing new. Act on the data you have, "
         . "or change target.";
}

1;  # MANDATORY: End every .pm file with 1;
