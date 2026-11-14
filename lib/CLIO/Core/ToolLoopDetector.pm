# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::ToolLoopDetector;

use strict;
use warnings;
use utf8;
use feature 'say';
use CLIO::Tools::Registry ();

=head1 NAME

CLIO::Core::ToolLoopDetector - Detect non-converging runs of successful near-duplicate tool calls

=head1 SYNOPSIS

    use CLIO::Core::ToolLoopDetector;

    my $detector = CLIO::Core::ToolLoopDetector->new();
    my $verdict = $detector->record_call('terminal_operations', $tool_args, $result_content);
    if ($verdict->{break} && $verdict->{nudge}) {
        # Escalation with nudge budget remaining: inject $verdict->{nudge_text}
        # as a user message and keep the turn running.
    } elsif ($verdict->{break}) {
        # Hard break: end the turn and report to the user.
    } elsif ($verdict->{guidance}) {
        # Append $verdict->{guidance} to the tool result the model sees.
    }

=head1 DESCRIPTION

Two existing mechanisms guard against agent tool loops, and neither catches
the third failure mode:

=over 4

=item * L<CLIO::Core::ToolErrorGuidance> plus the error-loop breaker in
WorkflowOrchestrator handles repeated tool ERRORS.

=item * ContextBuilder collapses byte-identical repeated calls in the
context projection.

=item * NOTHING handles the loop where every call succeeds with DIFFERENT
arguments but near-identical results - a model re-running grep with new
patterns against the same target fifteen times in a row.

=back

This module tracks recent read-only tool calls in a sliding window and
counts calls sharing a loose signature that collapses argument variations
(grep flags and quoted patterns are ignored; the command word and target
paths are kept). Escalation requires the result-similarity gate: the
current result must be near-identical (token overlap) to an earlier
result with the same signature (not necessarily the immediately previous
one). A search that keeps producing new information never triggers.

    N = guidance_threshold (3)  -> inject a "stop searching" note into the
                                   tool result the model sees
    N = break_threshold (5), or any similar call after guidance fired for
        the same signature -> escalation. Guidance state is tracked per
        signature: a model that interleaves two similar-result searches
        gets escalated, not re-warned, and a window that alternates two
        signatures still caps per-signature counts, so the count path
        alone is unreachable there - the guidance path completes the
        ladder. While nudge budget remains, the
        break is converted into a loop-break INSTRUCTION (nudge) that the
        orchestrator injects as a user message and the turn CONTINUES -
        an advisory note the model can ignore becomes a direct order it
        must follow. When the nudge budget is exhausted, the call breaks
        hard and the caller ends the turn.

State-changing calls (file writes, patches, builds, mutating git commands)
clear the window: a model that edits between searches is doing legitimate
work, not looping. Only contiguous read-only thrash escalates.

All thresholds are constructor arguments so tests can exercise escalation
without large call counts.

=cut

# Default thresholds. Overridable via constructor arguments.
our $DEFAULT_WINDOW_SIZE        = 8;     # sliding window of recent calls
our $DEFAULT_GUIDANCE_THRESHOLD = 3;     # similar calls before guidance note
our $DEFAULT_BREAK_THRESHOLD    = 5;     # similar calls before escalation
our $DEFAULT_SIMILARITY         = 0.75;  # token-overlap ratio for "same result"
our $DEFAULT_NUDGE_BUDGET       = 2;     # break->nudge conversions before hard break

# Terminal commands recognized as read-only. Anything else (make, perl,
# npm, git mutations, ...) is treated as state-changing and clears the
# window. Deliberately strict: a mutating command that slips through as
# read-only only weakens detection slightly, but a read-only command
# treated as mutating suppresses detection entirely.
my %READ_ONLY_COMMANDS = map { $_ => 1 } qw(
    grep egrep fgrep zgrep rg ack ag
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
);

# git subcommands that only read repository state. Everything else
# (add, commit, checkout, reset, ...) is state-changing.
my %READ_ONLY_GIT_SUBCOMMANDS = map { $_ => 1 } qw(
    log status diff show blame
    describe rev-parse ls-files ls-remote
    cat-file shortlog reflog
);

# file_operations operations that only read state.
my %READ_ONLY_FILE_OPS = map { $_ => 1 } qw(
    read_file list_dir file_exists get_file_info
    file_search grep_search semantic_search
    get_errors read_tool_result
);

# version_control operations that only read state.
my %READ_ONLY_GIT_OPS = map { $_ => 1 } qw(
    status log diff blame
);

=head1 METHODS

=head2 new

Arguments: %args with optional keys window_size, guidance_threshold,
break_threshold, similarity_threshold, nudge_budget (all numeric;
defaults from the package-level $DEFAULT_* constants).

Returns: blessed detector with fresh (empty) state.

=cut

sub new {
    my ($class, %args) = @_;
    my $self = {
        window_size          => $args{window_size} // $DEFAULT_WINDOW_SIZE,
        guidance_threshold   => $args{guidance_threshold} // $DEFAULT_GUIDANCE_THRESHOLD,
        break_threshold      => $args{break_threshold} // $DEFAULT_BREAK_THRESHOLD,
        similarity_threshold => $args{similarity_threshold} // $DEFAULT_SIMILARITY,
        nudge_budget         => $args{nudge_budget} // $DEFAULT_NUDGE_BUDGET,
    };
    bless $self, $class;
    $self->reset();
    return $self;
}

=head2 reset

Clears the sliding window and per-signature guidance state. Called by
the orchestrator
at the start of every turn (loop tracking is per-turn, not per-session)
and whenever the interact tool returns user input, which counts as a
strategy change. The nudge budget is restored: a cleared window means a
fresh escalation ladder.

Returns: $self.

=cut

sub reset {
    my ($self) = @_;
    $self->{state} = {
        window         => [],
        call_index     => 0,
        guidance_fired => {},    # sig => call_index of the guidance fire
        nudges_used    => 0,
    };
    return $self;
}

=head2 record_call

Record a successful tool call and evaluate it against recent history.

Arguments:
    $tool_name - tool name as dispatched (e.g. 'terminal_operations')
    $args      - parsed tool arguments hashref (or undef)
    $content   - the result content the model will receive (string)

Returns a hashref:
    tracked    - 1 if the call was recorded, 0 if it was state-changing
                 (state-changing calls reset the window and are not tracked)
    count      - number of window entries sharing this call's signature
    sig        - the loose signature of this call
    guidance   - guidance note string, or undef (inject into the tool
                 result the model sees)
    break      - 1 when escalation fired (see C<nudge>)
    nudge      - 1 when the break was converted into a loop-break
                 instruction (C<nudge_text>) because budget remained.
                 The caller injects nudge_text as a user message and
                 CONTINUES the turn. 0/undef when this is a real break.
    nudge_text - the loop-break instruction text (present when nudge is 1)

=cut

sub record_call {
    my ($self, $tool_name, $args, $content) = @_;
    $content = '' unless defined $content;

    # A state-changing call resets the window: the model just changed the
    # world, so prior search runs no longer indicate thrash.
    if ($self->_is_state_changing($tool_name, $args)) {
        $self->reset();
        return { tracked => 0, count => 0, sig => '', guidance => undef, break => 0 };
    }

    my $sig     = $self->call_signature($tool_name, $args);
    my $st      = $self->{state};
    my $tokens  = $self->_tokenize($content);

    # Result-similarity gate: compare this result against ANY earlier
    # window entry with the same signature, keeping the best match.
    # Computed before the push so the current call is excluded. Checking
    # any prior run (not just the immediately previous one) keeps
    # interleaved searches detectable: A, B, A still triggers when the
    # second A result repeats the first A result.
    my $best_sim   = 0;
    my $best_match = undef;
    for my $entry (@{$st->{window}}) {
        next unless $entry->{sig} eq $sig;
        my $sim = $self->_similarity($tokens, $entry->{tokens});
        if (!defined $best_match || $sim > $best_sim) {
            $best_sim   = $sim;
            $best_match = $entry;
        }
    }

    push @{$st->{window}}, { sig => $sig, tokens => $tokens };
    shift @{$st->{window}} while @{$st->{window}} > $self->{window_size};

    my $count = 0;
    for my $entry (@{$st->{window}}) {
        $count++ if $entry->{sig} eq $sig;
    }

    # Without this gate, legitimately converging searches would be
    # penalized: a search producing new information never escalates.
    $st->{call_index}++;
    return {
        tracked => 1, count => $count, sig => $sig, guidance => undef, break => 0,
    } unless $best_match && $best_sim >= $self->{similarity_threshold};

    # Guidance is tracked per signature. The model may interleave two
    # (or more) similar-result searches, and with single-slot bookkeeping
    # each guidance fire was overwritten by the alternating partner, so
    # the warning re-fired forever and escalation never became reachable.
    my $fired = $st->{guidance_fired}{ $sig };
    my $guidance_active = defined $fired
        && ($st->{call_index} - $fired) <= $self->{window_size};

    if ($guidance_active || $count >= $self->{break_threshold}) {
        # Escalation. The advisory guidance note was either already active
        # or the break threshold was hit directly. A hard break that ends
        # the turn is the last resort, not the first: while nudge budget
        # remains, return the break WITH a loop-break instruction the
        # orchestrator injects as a user message so the turn continues.
        # A model that ignored a note woven into tool results usually
        # obeys a direct instruction. Budget exhausted -> real break.
        if ($st->{nudges_used} < $self->{nudge_budget}) {
            $st->{nudges_used}++;
            return {
                tracked    => 1, count => $count, sig => $sig,
                guidance   => undef, break => 1, nudge => 1,
                nudge_text => $self->_nudge_text($tool_name, $sig, $count),
            };
        }
        return { tracked => 1, count => $count, sig => $sig, guidance => undef, break => 1 };
    }
    if ($count >= $self->{guidance_threshold}) {
        $st->{guidance_fired}{ $sig } = $st->{call_index};
        $self->_prune_guidance_state();
        return {
            tracked => 1, count => $count, sig => $sig, break => 0,
            guidance => $self->_guidance_text($tool_name, $sig, $count),
        };
    }
    return { tracked => 1, count => $count, sig => $sig, guidance => undef, break => 0 };
}

=head2 call_signature

Compute the loose signature for a tool call. Variations in flags, quoted
patterns, and other noise collapse to the same signature; the command
word (or operation) and target paths are preserved.

Arguments: $tool_name, $args (parsed arguments hashref or undef)

Returns: signature string.

=cut

sub call_signature {
    my ($self, $tool_name, $args) = @_;
    $tool_name //= 'unknown';
    $args = {} unless ref($args) eq 'HASH';

    if ($tool_name eq 'terminal_operations') {
        return $self->_terminal_signature(
            $args->{command} // '',
            $args->{operation} // '',
        );
    }

    # Generic fallback: tool name + operation + normalized scalar params.
    # Deliberately strict (near byte-identical calls collide) because the
    # observed loop mode is terminal search commands; ContextBuilder
    # already collapses byte-identical repeats for the strict case.
    my @parts = ($tool_name);
    push @parts, $args->{operation}
        if defined $args->{operation} && length $args->{operation};
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

=head2 _terminal_signature (Internal)

Signature for a terminal command: strip quoted strings first (patterns
must not fragment the signature, and quoted pipes must not split the
pipeline), then take the first pipeline stage, drop flags, and keep the
binary plus up to two path-like tokens as targets.

=cut

sub _terminal_signature {
    my ($self, $command, $operation) = @_;
    my $head = $self->_terminal_head($command);
    my @tokens = split /\s+/, $head;
    my $binary = lc(shift @tokens // '');
    $binary =~ s{^.*/}{};
    my @targets;
    for my $token (@tokens) {
        next if $token =~ /^-{1,2}/;
        push @targets, lc $token if $token =~ m{[/.\\*]};
        last if @targets >= 2;
    }
    return join('|', 'terminal', $operation, $binary, @targets);
}

=head2 _terminal_head (Internal)

Return the first pipeline stage of a command with quoted strings removed.
Quoted content is neutralized BEFORE pipeline splitting so a pipe inside a
grep pattern does not truncate the stage.

=cut

sub _terminal_head {
    my ($self, $command) = @_;
    $command = '' unless defined $command;
    (my $stripped = $command) =~ s/'[^']*'/ /g;
    $stripped =~ s/"[^"]*"/ /g;
    my ($head) = split /\s*(?:&&|\|\||;|\|)\s*/, $stripped, 2;
    return $head // '';
}

=head2 _is_state_changing (Internal)

Classify a tool call as state-changing (clears the window) or read-only
(tracked). Read-only terminal commands come from %READ_ONLY_COMMANDS plus
%READ_ONLY_GIT_SUBCOMMANDS; file/version-control operations from their
respective tables. Unknown tools default to state-changing.

=cut

sub _is_state_changing {
    my ($self, $tool_name, $args) = @_;
    $args = {} unless ref($args) eq 'HASH';

    # Calls arrive under the emitted callable name (write_file, grep_search,
    # todo_read), not the grouping tool. Resolve to the owning tool and
    # operation so the read-only tables below keep matching.
    my $owner = CLIO::Tools::Registry->classify_callable(
        $tool_name, $args->{operation});
    if ($owner) {
        $tool_name = $owner->{tool};
        $args = { %$args, operation => $owner->{operation} }
            if defined $owner->{operation};
    }

    return 1 if $tool_name eq 'apply_patch';

    if ($tool_name eq 'file_operations') {
        return $READ_ONLY_FILE_OPS{ $args->{operation} // '' } ? 0 : 1;
    }
    if ($tool_name eq 'version_control') {
        return $READ_ONLY_GIT_OPS{ $args->{operation} // '' } ? 0 : 1;
    }
    if ($tool_name eq 'memory_operations') {
        my $op = $args->{operation} // '';
        return ($op =~ /^(retrieve|search|list|recall_sessions|ltm_stats)$/) ? 0 : 1;
    }
    if ($tool_name eq 'terminal_operations') {
        return 0 if ($args->{operation} // '') eq 'validate';
        my $head = $self->_terminal_head($args->{command} // '');
        my ($binary) = $head =~ /^\s*(\S+)/;
        $binary = lc($binary // '');
        $binary =~ s{^.*/}{};
        # Empty/malformed command is not productive work and not a
        # strategy signal: treat it as state-changing so it clears the
        # window instead of polluting a legitimate read-only run.
        # Repeated empty calls surface through error handling instead.
        return 1 unless length $binary;
        return 0 if $READ_ONLY_COMMANDS{$binary};
        if ($binary eq 'git') {
            my ($sub) = $head =~ /^\s*git\s+(\S+)/;
            return ($READ_ONLY_GIT_SUBCOMMANDS{ lc($sub // '') }) ? 0 : 1;
        }
        return 1;
    }
    if ($tool_name eq 'code_intelligence') {
        return 0;  # list_usages / search_history are read-only
    }
    if ($tool_name eq 'web_operations') {
        my $op = $args->{operation} // '';
        return ($op =~ /^(search_web|fetch_url)$/) ? 0 : 1;
    }
    if ($tool_name eq 'todo_operations' || $tool_name eq 'skill_operations') {
        return 0;  # bookkeeping calls never invalidate file-search context
    }
    # Unknown tools: conservative - treat as state-changing.
    return 1;
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

=cut

sub _tokenize {
    my ($self, $text) = @_;
    return [] unless defined $text && length $text;
    (my $norm = lc $text) =~ s/[^a-z0-9]+/ /g;
    my %set = map { $_ => 1 } grep { length } split /\s+/, $norm;
    return [sort keys %set];
}

=head2 _prune_guidance_state (Internal)

Drop guidance-fired entries older than the staleness window. Inert by
the guidance_active check anyway; pruning keeps the hash bounded.

=cut

sub _prune_guidance_state {
    my ($self) = @_;
    my $st     = $self->{state};
    my $cutoff = $st->{call_index} - $self->{window_size};
    for my $sig (keys %{ $st->{guidance_fired} }) {
        delete $st->{guidance_fired}{$sig}
            if $st->{guidance_fired}{$sig} < $cutoff;
    }
    return;
}

=head2 _guidance_text (Internal)

Build the "stop searching" note injected into the tool result. Mirrors the
ToolErrorGuidance style: state the problem, give concrete actions.

=cut

sub _guidance_text {
    my ($self, $tool_name, $sig, $count) = @_;
    return "LOOP WARNING (from CLIO): this is call #${count} in a run of similar "
         . "'$tool_name' calls (signature: $sig) returning near-identical results. "
         . "The search is not converging. STOP searching and do one of:\n"
         . "1. Summarize what you already know and act on it.\n"
         . "2. Change strategy entirely: different tool, different target, or ask the user.\n"
         . "Do not re-run the same search with another variation. Continuing this "
         . "pattern will trigger a forced loop-break instruction, and then the turn ends.";
}

=head2 _nudge_text (Internal)

Build the loop-break instruction injected as a user message when a break
escalation is converted into a nudge. Unlike the guidance note (advice
woven into a tool result), this is a direct order from the framework.
It states the loop, points at the existing data, gives concrete exits,
and declares the consequence of ignoring it.

=cut

sub _nudge_text {
    my ($self, $tool_name, $sig, $count) = @_;
    return "LOOP BREAK (from CLIO): This is call #${count} in a run of near-identical "
         . "'$tool_name' calls (signature: $sig) that all returned the same result. "
         . "The information you need is already in this conversation - repeating this "
         . "call produces nothing new. Change tactic NOW:\n"
         . "1. Act on the results you already have (edit, build, commit, or reason from them).\n"
         . "2. Switch to a different tool or target - do something that changes state.\n"
         . "3. If the work is done, give your final answer and stop making tool calls.\n"
         . "This instruction will not repeat: another call with this signature ends the "
         . "turn and returns control to the user.";
}

1;  # MANDATORY: End every .pm file with 1;
