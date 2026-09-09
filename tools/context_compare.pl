#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# context_compare.pl - Side-by-side comparison of the four message arrays
# that CLIO could send to the model from a single session JSON.
#
# The four scenarios:
#   1. pre-trim     (rebuild, no budget pressure)
#   2. post-trim    (rebuild, after MessageValidator trim)
#   3. fast-resume  (cached last_api_payload, drift-checked)
#   4. rebuild      (forced rebuild on resume - fast-path disabled)
#
# Use cases:
#   - Investigate context-management bugs by comparing what the model
#     actually sees across the four code paths.
#   - Regression test changes to ContextBuilder / MessageValidator /
#     WorkflowOrchestrator: diff a session before vs after a code change.
#   - Verify the fast-path cache (last_api_payload) actually matches
#     what a rebuild would produce, or surface where they diverge.
#
# Usage:
#   tools/context_compare.pl <session.json>
#   tools/context_compare.pl <session.json> --budget=8000
#   tools/context_compare.pl <session.json> --diff-only
#   tools/context_compare.pl <session.json> --json
#   tools/context_compare.pl <session_a.json> <session_b.json> --json
#   tools/context_compare.pl <session.json> --messages=pre-trim:0-50
#
# See tools/context_compare_README.md for the full field reference.

use strict;
use warnings;
use utf8;

use JSON::PP;
use File::Basename;
use File::Spec;
use Encode qw(encode_utf8);
use Getopt::Long qw(GetOptions);
use Data::Dumper;
$Data::Dumper::Sortkeys = 1;
$Data::Dumper::Indent = 1;

# CLIO modules - use the real pipeline so what we see is what
# production sends. Path adjustments are made in BEGIN so the tool
# works whether invoked from project root or directly.
use FindBin;
use lib "$FindBin::Bin/../lib";

require CLIO::Core::Logger;
require CLIO::Core::ConversationManager;
require CLIO::Core::PromptBuilder;
require CLIO::Core::ContextBuilder;
require CLIO::Core::MessageHistory;
require CLIO::Core::API::MessageValidator;
require CLIO::Memory::TokenEstimator;
require CLIO::Memory::LongTerm;
require CLIO::Memory::YaRN;
require CLIO::Tools::Registry;

binmode(STDOUT, ":encoding(UTF-8)");
binmode(STDERR, ":encoding(UTF-8)");

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

my $session_a_file;
my $session_b_file;
my $budget;
my $current_provider;   # Simulate a specific provider for drift check
my $current_tools_sig;  # Override the tool signature (default: matches cached)
my $model_class;
my $json_output = 0;
my $diff_only = 0;
my $messages_arg;
my $help = 0;
my $quiet = 0;

GetOptions(
    "session-a=s"   => \$session_a_file,
    "session-b=s"   => \$session_b_file,
    "budget=s"      => \$budget,
    "provider=s"    => \$current_provider,
    "tools-sig=s"   => \$current_tools_sig,
    "model-class=s" => \$model_class,
    "json"          => \$json_output,
    "diff-only"     => \$diff_only,
    "messages=s"    => \$messages_arg,
    "help|h"        => \$help,
    "quiet"         => \$quiet,
) or die "Bad options. Try --help\n";

# Positional args: one or two session files
$session_a_file //= $ARGV[0];
$session_b_file //= $ARGV[1];

if ($help || !$session_a_file) {
    print <<"END";
context_compare.pl - Compare the four message arrays CLIO could send to the model

Usage:
  $0 <session.json>                          Single-session comparison
  $0 <session_a.json> <session_b.json>       Two-session comparison (regression testing)
  $0 <session.json> --budget=8000            Simulate a smaller context window
  $0 <session.json> --diff-only              Just show the divergence report
  $0 <session.json> --json                   Machine-readable JSON output
  $0 <session.json> --messages=pre-trim:0-50 Inspect a specific range
  $0 --help                                  Show this help

Options:
  --session-a=FILE      First session (positional 1)
  --session-b=FILE      Second session (positional 2, optional)
  --budget=N            Force a context budget (overrides session's max_tokens)
  --provider=NAME       Simulate current provider for drift check (default: cached)
  --tools-sig=HEX       Simulate current tools signature for drift check
  --model-class=XS|S|M|L|XL
                        Label the model's context window class
  --json                JSON output (for CI / regression tests)
  --diff-only           Skip the per-message dump, just show divergence
  --messages=SCOPE:RANGE
                        Dump a specific scenario's messages, e.g. pre-trim:0-50
  --quiet               Suppress the header / banner
END
    exit($help ? 0 : 1);
}

# Resolve session paths (tolerate bare session IDs in .clio/sessions/)
$session_a_file = _resolve_session_path($session_a_file);
$session_b_file = _resolve_session_path($session_b_file) if $session_b_file;

# ---------------------------------------------------------------------------
# Session loaders
# ---------------------------------------------------------------------------

sub _resolve_session_path {
    my ($f) = @_;
    return $f if -f $f;
    my $alt = File::Spec->catfile(".clio", "sessions", basename($f));
    return $alt if -f $alt;
    my $alt2 = File::Spec->catfile(".clio", "sessions", "$f.json");
    return $alt2 if -f $alt2;
    die "File not found: $f (tried $alt and $alt2)\n";
}

sub load_session_json {
    my ($file) = @_;
    open my $fh, "<:raw", $file or die "Cannot read $file: $!\n";
    local $/;
    my $raw = <$fh>;
    close $fh;
    return decode_json($raw);
}

# ---------------------------------------------------------------------------
# Stub session - a minimal quacks-like object that exposes the methods the
# ContextBuilder / ConversationManager / PromptBuilder need.
#
# We do NOT need full Session::Manager; we just need:
#   - state() returning an object with session_goals, working_directory
#   - get_conversation_history() returning the @history arrayref
#   - can() for capability checks
#   - id() for YaRN::recover_substantive_task (only called as a fallback)
#   - stm/ltm/yarn for `_active_task_text` YaRN fallback paths
#
# The stub holds a reference to the raw JSON and the file path so the
# underlying modules can read whatever they need. add_message is a
# no-op (we never write to the session in this tool).
# ---------------------------------------------------------------------------

package StubSession;
use strict;
use warnings;
use utf8;

sub new {
    my ($class, $json, $file) = @_;
    return bless { json => $json, file => $file }, $class;
}

sub can { 1 }  # advertise every method so `if ($session->can(...))` passes

sub state {
    my ($self) = @_;
    return $self->{_state} //= StubState->new($self->{json});
}

sub get_conversation_history {
    my ($self) = @_;
    return $self->{json}{history} || [];
}

sub add_message { }  # no-op for this read-only tool

sub id {
    my ($self) = @_;
    return $self->{json}{_session_id} || basename($self->{file}, '.json');
}

# Optional memory systems - not required for the projection but the
# WorkflowOrchestrator::_active_task_text YaRN fallback path may ask
# for them. Return empty stubs so we never load disk state.
sub stm  { StubMemory->new('stm') }
sub ltm  { StubMemory->new('ltm') }
sub yarn { StubMemory->new('yarn') }

# Forward working_directory to the State object so the prose renderer
# can read it.
sub working_directory { $_[0]->state->working_directory }

package StubState;
use strict;
use warnings;

sub new {
    my ($class, $json) = @_;
    return bless { json => $json }, $class;
}

sub session_goals { $_[0]->{json}{session_goals} || [] }
sub working_directory {
    $_[0]->{json}{working_directory} || Cwd::getcwd();
}
sub max_tokens { $_[0]->{json}{max_tokens} }

# Method shim that PromptBuilder may call for sync. No-op here.
sub last_api_payload    { $_[0]->{json}{last_api_payload}    || [] }
sub last_api_metadata   { $_[0]->{json}{last_api_metadata}   || {} }

package StubMemory;
sub new { bless { kind => $_[1] }, $_[0] }

# ---------------------------------------------------------------------------
# The four scenario builders. Each returns a hashref:
#   { name, label, messages, tokens, status, drift?, notes => [] }
# ---------------------------------------------------------------------------

package main;

# ---------- Scenario 1: pre-trim rebuild ----------
# What _build_turn_context produces when we rebuild on resume and
# there's plenty of room. Includes:
#   [0]     system_prompt
#   [1..N]  anchor + recent turn messages (role-based, post ContextBuilder)
#   [N+1]   dynamic userContext (single system message)
#   [N+2]   user_input
sub build_scenario_pre_trim {
    my ($session, $user_input) = @_;
    my @msgs = ();
    my @notes;

    # 1. System prompt - fresh, built per turn.
    # An empty tool registry is fine - the tools section just shows
    # "(no tools available)" which is accurate for this offline tool.
    my $pb = CLIO::Core::PromptBuilder->new(
        debug => 0,
        skip_custom => 0,
        skip_ltm => 0,
        non_interactive => 0,
        tool_registry => CLIO::Tools::Registry->new(debug => 0),
    );
    my $system_prompt;
    eval {
        $system_prompt = $pb->build_system_prompt($session);
    };
    if ($@ || !defined $system_prompt) {
        push @notes, "build_system_prompt failed: " . ($@ || '(no output)');
        $system_prompt = '[SYSTEM PROMPT BUILD FAILED]';
    }
    push @msgs, { role => 'system', content => $system_prompt };

    # 2. Load history (replicates load_conversation_history logic)
    my $raw_history = $session->get_conversation_history();
    my $history = CLIO::Core::ConversationManager::load_conversation_history(
        $session, debug => 0
    );
    my $skipped = (@$raw_history - @$history);
    if ($skipped > 0) {
        push @notes, "load_conversation_history skipped $skipped messages (orphans/systems)";
    }

    # 3. Noise-strip (reasoning_content, reasoning_details, etc.)
    my $stripped = CLIO::Core::ConversationManager::strip_messages_noise(
        $history, debug => 0
    );
    my $stripped_chars = 0;
    my $orig_chars = 0;
    for my $i (0..$#$stripped) {
        $stripped_chars += length($stripped->[$i]{content} // '');
        $orig_chars     += length($history->[$i]{content}    // '');
    }
    if ($orig_chars > $stripped_chars) {
        push @notes, sprintf("strip_messages_noise saved %d chars (reasoning_content/details stripped)",
            $orig_chars - $stripped_chars);
    }

    # 4. Build projection (anchor + recent + YaRN-compressed tail)
    my $ltm_entries = [];
    eval {
        # Use session ltm if available, else empty
        if ($session->can('ltm')) {
            my $ltm = $session->ltm;
            $ltm_entries = $ltm->can('entries') ? $ltm->entries() : [];
        }
    };
    my $active_task = _active_task_text($session, $user_input);
    my $active_todos = _read_active_todos($session);
    my $unresolved = $session->can('state') ? [] : [];

    my $projection;
    eval {
        $projection = CLIO::Core::ContextBuilder::build_projection(
            history             => $stripped,
            user_input          => $user_input,
            active_task         => $active_task,
            active_todos        => $active_todos,
            ltm                 => $ltm_entries,
            unresolved          => $unresolved,
            session             => $session,
        );
    };
    if ($@ || !$projection) {
        push @notes, "build_projection failed: " . ($@ || '(undef)');
        $projection = { anchor => [], turns => [], compressed_tail => '' };
    }

    if ($projection->{anchor} && ref($projection->{anchor}) eq 'ARRAY' && @{$projection->{anchor}}) {
        push @msgs, @{$projection->{anchor}};
    }
    for my $turn (@{ $projection->{turns} || [] }) {
        next unless ref($turn) eq 'ARRAY' && @$turn;
        push @msgs, @$turn;
    }

    # 5. user_input
    push @msgs, { role => 'user', content => $user_input };

    # 6. dynamic userContext (one system message, after user_input -
    #    the recency anchor)
    my $dynamic = CLIO::Core::MessageHistory::messages_to_prose_dynamic($projection);
    if (length $dynamic) {
        push @msgs, { role => 'system', content => $dynamic };
    }

    if ($projection->{compressed_tail} && length $projection->{compressed_tail}) {
        push @notes, sprintf("compressed_tail: %d chars (YaRN summary of dropped turns)",
            length $projection->{compressed_tail});
    }

    return {
        name => 'pre-trim',
        label => 'Pre-trim rebuild (no budget pressure)',
        messages => \@msgs,
        notes => \@notes,
    };
}

# ---------- Scenario 2: post-trim rebuild ----------
# Same as pre-trim, then run through MessageValidator::validate_and_truncate
# with the model's actual context window.
sub build_scenario_post_trim {
    my ($session, $user_input, $budget, $pre_scenario) = @_;
    my @notes;

    # Reuse the pre-trim scenario if provided (avoids a second
    # build_projection call, which would produce a different timestamp).
    # In real CLIO, build_projection is called once per turn.
    my $pre = $pre_scenario // build_scenario_pre_trim($session, $user_input);
    my @msgs = @{$pre->{messages}};
    push @notes, @{ $pre->{notes} || [] };

    my $ctx_window = $budget // ($session->can('state') ? $session->state->max_tokens : undef) // 128000;

    # Token budget = context window minus a reserve for output. Use the
    # same formula MessageValidator uses internally when not given a
    # trim_threshold.
    my $trim_budget = int($ctx_window * 0.75);

    my $tools = [];  # we don't have tool definitions without APIManager

    my $trimmed_ref;
    eval {
        $trimmed_ref = CLIO::Core::API::MessageValidator::validate_and_truncate(
            messages           => \@msgs,
            model_capabilities => {
                max_prompt_tokens  => $ctx_window,
                max_output_tokens  => 16000,
            },
            tools              => $tools,
            token_ratio        => 2.5,
            trim_threshold     => $trim_budget,
            disable_post_trim_floor => 1,
        );
    };
    if ($@ || !$trimmed_ref || ref($trimmed_ref) ne 'ARRAY') {
        push @notes, "validate_and_truncate failed: " . ($@ || 'non-array return');
        $trimmed_ref = \@msgs;
    }
    my @trimmed = @$trimmed_ref;

    my $dropped = @msgs - @trimmed;
    if ($dropped > 0) {
        push @notes, sprintf("post-trim dropped %d of %d messages (budget=%d)",
            $dropped, scalar @msgs, $trim_budget);
    } else {
        push @notes, sprintf("no trim needed (budget=%d, msgs=%d)",
            $trim_budget, scalar @msgs);
    }

    return {
        name => 'post-trim',
        label => "Post-trim rebuild (budget=$trim_budget)",
        messages => $trimmed_ref,
        notes => \@notes,
    };
}

# ---------- Scenario 3: fast-resume (cached payload) ----------
# What would be sent if the fast-path succeeds. Comes straight from
# the session's last_api_payload. The tool also runs the drift check
# and reports the status with reasons.
sub build_scenario_fast_resume {
    my ($session, $user_input, $opts) = @_;
    my @notes;

    my $payload = $session->can('state') ? $session->state->last_api_payload : [];
    my $meta = $session->can('state') ? ($session->state->last_api_metadata || {}) : {};

    # Drift check - what would WorkflowOrchestrator::_try_resume_from_payload
    # actually do? Replicate the four conditions:
    #   1. payload non-empty
    #   2. provider matches
    #   3. tools_signature matches
    #   4. current context_window >= saved context_window
    my ($drift_status, @drift_reasons);
    if (!$payload || !@$payload) {
        $drift_status = 'NO_CACHE';
        push @drift_reasons, "last_api_payload is empty (cache miss)";
    } else {
        $drift_status = 'OK';
        my $current_prov = $opts->{current_provider} // ($meta->{provider} // '');
        my $saved_prov   = $meta->{provider} // '';
        if ($current_prov ne $saved_prov) {
            $drift_status = 'DRIFT';
            push @drift_reasons, "provider drift: current='$current_prov' saved='$saved_prov'";
        }
        my $current_sig = $opts->{current_tools_sig} // ($meta->{tools_signature} // '');
        my $saved_sig   = $meta->{tools_signature} // '';
        if ($current_sig ne $saved_sig) {
            $drift_status = 'DRIFT';
            push @drift_reasons, "tools_signature drift: current=" . substr($current_sig,0,12) . " saved=" . substr($saved_sig,0,12);
        }
        # Context window check (only if user overrode)
        if (defined $opts->{budget} && $meta->{context_window}) {
            if ($opts->{budget} < $meta->{context_window}) {
                $drift_status = 'DRIFT';
                push @drift_reasons, "context_window shrunk: current=$opts->{budget} saved=$meta->{context_window}";
            }
        }
    }

    # Note: the cached payload includes the assistant/tool/results from
    # the last turn but does NOT include the FRESH system prompt that
    # _build_turn_context would add. The fast-path in
    # WorkflowOrchestrator reuses the payload verbatim; the system
    # prompt only changes if ContextBuilder::build_projection re-runs
    # the per-iteration refresh (which appends dynamic UC, not system_prompt).
    # This means the fast-path payload's [0] is usually an assistant or
    # tool message, NOT a system prompt. That's intentional but
    # surprising - flag it loudly.
    if (@$payload && $payload->[0]{role} && $payload->[0]{role} ne 'system') {
        push @notes, sprintf(
            "fast-resume payload starts with role='%s' (no system prompt at [0]) - this is the cached post-turn state",
            $payload->[0]{role});
    }

    return {
        name => 'fast-resume',
        label => "Fast-resume (cached payload, drift=$drift_status)",
        messages => $payload,
        notes => \@notes,
        drift_status => $drift_status,
        drift_reasons => \@drift_reasons,
    };
}

# ---------- Scenario 4: rebuild on resume (forced) ----------
# Same as pre-trim but for documentation purposes we call it the
# "rebuild" path. There's no behavioral difference vs scenario 1 in
# this tool, but the label makes it clear in the side-by-side that
# this is the path that runs when fast-path is unavailable.
# In real CLIO, build_projection() is called ONCE per turn, producing a
# single timestamp from _build_environment_hash(). The tool calls it
# twice (pre-trim and rebuild) without sharing, causing the timestamp
# in the dynamic userContext to differ — a tool artifact. To simulate
# the real single-call-per-turn behavior, rebuild reuses pre-trim's
# messages arrayref instead of calling build_projection again.
sub build_scenario_rebuild {
    my ($session, $user_input, $pre_scenario) = @_;
    $pre_scenario //= build_scenario_pre_trim($session, $user_input);
    return {
        name => 'rebuild',
        label => 'Rebuild (fast-path disabled)',
        messages => $pre_scenario->{messages},
        notes => [@{ $pre_scenario->{notes} || [] },
                  '(reuses pre-trim messages — same code path, single build_projection call per turn)'],
    };
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Mirror WorkflowOrchestrator::_active_task_text but from the stub
# session. We don't need the full YaRN fallback chain for this tool -
# a coarse derivation is good enough to surface divergence.
sub _active_task_text {
    my ($session, $user_input) = @_;
    return '' unless $session;

    if ($session->can('state')) {
        my $state = $session->state();
        if ($state->can('session_goals')) {
            my $list = $state->session_goals();
            if (ref($list) eq 'ARRAY') {
                for my $g (reverse @$list) {
                    if (ref($g) eq 'HASH' && ($g->{status} // '') eq 'active') {
                        my $t = $g->{title} || '';
                        if (length $t) {
                            $t .= ': ' . ($g->{description} || '') if length($g->{description} // '');
                            return $t;
                        }
                    }
                }
            }
        }
    }
    if (defined $user_input && length($user_input // '') >= 50) {
        return $user_input;
    }
    # Fallback: scan history newest-first for a substantive user message.
    my $hist = $session->get_conversation_history();
    for my $i (reverse 0..$#$hist) {
        my $m = $hist->[$i];
        next unless ($m->{role} // '') eq 'user';
        my $c = $m->{content} // '';
        return $c if length($c) >= 50;
    }
    return '';
}

sub _read_active_todos {
    my ($session) = @_;
    # The full path reads from TodoStore. For this tool we keep it
    # minimal - just return whatever the State file exposes. The
    # ContextBuilder only uses status + content, so empty is fine.
    return [];
}

# Bucket a message into one of the 6 layout sections (system_prompt,
# context_files, dialog, summary, user_context, user_input) so the
# tree view matches what the model actually sees.
#
# This needs the whole messages array to make the right decision
# (e.g. which system message is "the" user_context, which user
# message is "the" user_input). For per-message iteration, pass
# the full array as the 3rd arg.
sub classify_message {
    my ($msg, $idx, $total, $scenario, $all_messages) = @_;
    my $role = $msg->{role} // '?';
    my $content = $msg->{content} // '';
    return 'unknown' unless ref($msg) eq 'HASH';
    $all_messages ||= [$msg];
    my $nm = scalar(@$all_messages);

    # System messages: classify by content shape.
    if ($role eq 'system') {
        # The system_prompt lives at index 0 when present. Detect
        # by size (>1KB) and absence of trim/UC markers - the
        # full CLIO system prompt is ~20K tokens.
        if ($idx == 0 && length($content) > 1000
            && $content !~ /<thread_summary>/
            && $content !~ /^\[CONTEXT TRIM:/
            && $content !~ /^\s*Working directory:/) {
            return 'system_prompt';
        }
        # Compressed-tail summary (YaRN output)
        if ($content =~ /<thread_summary>/) { return 'summary' }
        # The trim notification that some providers insert
        if ($content =~ /^\[CONTEXT TRIM:/) { return 'summary' }
        # Dynamic userContext rendered as XML (legacy format)
        if ($content =~ /^\s*<(?:userContext|dynamicContext|sessionGoals)/) {
            return 'user_context'
        }
        # Dynamic userContext rendered as prose (current format)
        if ($content =~ /^\s*Working directory:/) {
            return 'user_context'
        }
        # All other system messages sit in the context_files slot
        # (the post-rebuild pre-dialog position).
        return 'context_files';
    }

    # User input: the LAST user message in the array. In the rebuild
    # path the user_input is at position N+1, with the dynamic UC
    # appended at N+2. In the fast-resume (cached) path, the last
    # user message is also the user_input (no fresh UC after it).
    if ($role eq 'user') {
        my $last_user_idx;
        for my $j (reverse 0..$#$all_messages) {
            if (ref($all_messages->[$j]) eq 'HASH'
                && ($all_messages->[$j]{role} // '') eq 'user') {
                $last_user_idx = $j;
                last;
            }
        }
        if (defined $last_user_idx && $last_user_idx == $idx) {
            return 'user_input';
        }
    }

    return 'dialog';
}

sub section_label {
    {
        system_prompt => 'system_prompt',
        context_files => 'context_files',
        dialog        => 'dialog',
        summary       => 'summary',
        user_context  => 'user_context',
        user_input    => 'user_input',
    }->{$_[0]} // $_[0];
}

# ---------------------------------------------------------------------------
# Bucketing and token accounting
# ---------------------------------------------------------------------------

sub bucket_messages {
    my ($messages) = @_;
    my $total = @$messages;
    my %buckets = map { $_ => { count => 0, tokens => 0, msgs => [] } }
        qw(system_prompt context_files dialog summary user_context user_input);
    my $total_tokens = 0;
    for my $i (0..$#$messages) {
        my $m = $messages->[$i];
        unless (ref($m) eq 'HASH') {
            # Defensive: skip malformed entries (CLIO should never
            # produce these, but a corrupt session JSON could).
            next;
        }
        my $content = $m->{content} // '';
        my $tokens;
        if (ref($content) eq 'ARRAY') {
            # Multimodal: estimate each part. Tolerant of mixed
            # HASH and SCALAR parts (some providers include plain
            # strings in multimodal arrays).
            my $s = '';
            for my $part (@$content) {
                if (ref($part) eq 'HASH') {
                    $s .= ($part->{text} // '');
                } elsif (!ref($part)) {
                    $s .= $part;
                }
            }
            $tokens = CLIO::Memory::TokenEstimator::estimate_tokens($s) + 4;
        } else {
            $tokens = CLIO::Memory::TokenEstimator::estimate_tokens($content) + 4;
        }
        $tokens += 8 if ($m->{role} // '') eq 'tool';
        if ($m->{tool_calls}) {
            for my $tc (@{$m->{tool_calls}}) {
                # Match MessageValidator._estimate_tokens: encode the
                # full tool call object as JSON, not just the arguments.
                # safe_encode_json matches CLIO::Providers::safe_encode_json.
                my $tc_json = eval {
                    require CLIO::Util::JSON;
                    CLIO::Util::JSON::encode_json($tc);
                } || JSON::PP::encode_json($tc);
                $tokens += CLIO::Memory::TokenEstimator::estimate_tokens($tc_json || '');
            }
        }
        my $sec = classify_message($m, $i, $total, undef, $messages);
        $buckets{$sec}{count}++;
        $buckets{$sec}{tokens} += $tokens;
        push @{$buckets{$sec}{msgs}}, { idx => $i, tokens => $tokens, role => $m->{role} // '?' };
        $total_tokens += $tokens;
    }
    return (\%buckets, $total_tokens);
}

# ---------------------------------------------------------------------------
# Diff engine
# ---------------------------------------------------------------------------

# Compute a structural diff between two message arrays. The diff is
# content-aware but tolerant: two messages with the same role and
# content hash are "common", everything else is added/removed.
sub diff_messages {
    my ($a, $b) = @_;
    return { added => [], removed => [], common => 0, reorder_score => 0, byte_stable => 1, prefix_match_full_mismatch => 0, legacy_common => 0 } if !$a && !$b;

    # Same-reference short-circuit: if both arrays are the exact same
    # Perl arrayref (e.g. rebuild reuses pre-trim's messages), they are
    # byte-identical by definition. The hash-based comparison below would
    # falsely report byte_stable=0 when duplicate SHA-256 signatures
    # collide in the hash map (two identical messages collapse to one key).
    if ($a && $b && $a == $b) {
        return {
            added => [], removed => [], common => scalar(@$a),
            reorder_score => 0, byte_stable => 1,
            prefix_match_full_mismatch => 0, legacy_common => scalar(@$a),
        };
    }

    sub _sig {
        my ($m) = @_;
        return '' unless ref($m) eq 'HASH';
        my $content = $m->{content} // '';
        if (ref($content) eq 'ARRAY') {
            # Multimodal - hash the text parts only, ignore image
            # base64 (large, would dominate the hash).
            my $s = '';
            for my $part (@$content) {
                if (ref($part) eq 'HASH') {
                    $s .= ($part->{text} // '');
                } elsif (!ref($part)) {
                    $s .= $part;
                }
            }
            $content = $s;
        }
        return join("\x1f",
            $m->{role} // '?',
            $m->{tool_call_id} // '',
            substr($content, 0, 500),  # LEGACY: 500-char cap for backward compat
        );
    }

    # Full-content SHA-256 signature. Hashes the COMPLETE content
    # (no 500-char cap) so subtle byte-level differences beyond the
    # prefix - timestamps, token counts, IDs, dynamic values - are
    # detected. This is what makes 'byte_stable' meaningful: two
    # messages that look identical in the first 500 chars but differ
    # later will hash differently and be flagged as non-common.
    sub _full_sig {
        my ($m) = @_;
        return '' unless ref($m) eq 'HASH';
        my $content = $m->{content} // '';

        if (ref($content) eq 'ARRAY') {
            # Multimodal: hash text parts only (ignore image base64).
            my $s = '';
            for my $part (@$content) {
                if (ref($part) eq 'HASH') {
                    $s .= ($part->{text} // '');
                } elsif (!ref($part)) {
                    $s .= $part;
                }
            }
            $content = $s;
        }

        # Include tool_calls arguments in the hash so changes to
        # tool call parameters are detected (not just content).
        my $tc_args = '';
        if ($m->{tool_calls} && ref($m->{tool_calls}) eq 'ARRAY') {
            for my $tc (@{$m->{tool_calls}}) {
                my $def = $tc->{function} || $tc;
                $tc_args .= '|' . ($def->{name} // '') . '|' . ($def->{arguments} // '');
            }
        }

        require Digest::SHA;
        my $hash = Digest::SHA::sha256_hex(encode_utf8(
            ($m->{role} // '?') . "\x1f" .
            ($m->{tool_call_id} // '') . "\x1f" .
            $tc_args . "\x1f" .
            $content
        ));
        return join("\x1f",
            $m->{role} // '?',
            $m->{tool_call_id} // '',
            $tc_args,
            $hash,
        );
    }

    # Use full-signature sets for accurate matching. Legacy _sig (500-char)
    # is still computed to flag the "first 500 chars match but full content
    # diverges" case in the report.
    my %a_full = map { _full_sig($_) => $_ } @$a;
    my %b_full = map { _full_sig($_) => $_ } @$b;
    my %a_legacy = map { _sig($_) => $_ } @$a;
    my %b_legacy = map { _sig($_) => $_ } @$b;

    my @added;
    my @removed;
    my $common = 0;
    for my $s (keys %a_full) {
        if (exists $b_full{$s}) {
            $common++;
        } else {
            push @removed, $a_full{$s};
        }
    }
    for my $s (keys %b_full) {
        unless (exists $a_full{$s}) {
            push @added, $b_full{$s};
        }
    }

    # byte_stable: 1 only if arrays have the same length AND every
    # position has an identical full-signature hash. Position-aware
    # comparison avoids the hash-collision issue where two identical
    # messages in the array collapse to one hash key, making
    # count-based comparison unreliable.
    my $counts_match = (scalar(@$a) == scalar(@$b));
    my $byte_stable = 0;
    if ($counts_match && @$a) {
        $byte_stable = 1;
        for my $i (0 .. $#$a) {
            if (_full_sig($a->[$i]) ne _full_sig($b->[$i])) {
                $byte_stable = 0;
                last;
            }
        }
    }

    # Detect "500-char prefix matches but full content diverges" case.
    # This happens when legacy _sig (500-char cap) matches at every
    # position but _full_sig (SHA-256) does not. Critical for catching
    # subtle byte-level differences that the old 500-char diff engine
    # would miss.
    my $prefix_match_full_mismatch = 0;
    if (!$byte_stable && $counts_match && @$a) {
        my $legacy_pos_match = 1;
        for my $i (0 .. $#$a) {
            if (_sig($a->[$i]) ne _sig($b->[$i])) {
                $legacy_pos_match = 0;
                last;
            }
        }
        $prefix_match_full_mismatch = $legacy_pos_match ? 1 : 0;
    }

    # Reorder score: fraction of common (full-sig) messages whose position
    # changed. A high score means the order diverged (would break LCP
    # cache even if content is identical).
    my @a_sigs = map { _full_sig($_) } @$a;
    my @b_sigs = map { _full_sig($_) } @$b;
    my %a_pos = map { $a_sigs[$_] => $_ } 0..$#a_sigs;
    my $reorder = 0;
    my $reorder_total = 0;
    for my $i (0..$#b_sigs) {
        my $sig = $b_sigs[$i];
        if (exists $a_pos{$sig}) {
            $reorder_total++;
            $reorder++ if $a_pos{$sig} != $i;
        }
    }
    my $reorder_score = $reorder_total ? $reorder / $reorder_total : 0;

    return {
        added => \@added,
        removed => \@removed,
        common => $common,
        reorder_score => $reorder_score,
        byte_stable => $byte_stable,
        prefix_match_full_mismatch => $prefix_match_full_mismatch,
        legacy_common => scalar(keys %a_legacy & %b_legacy),
    };
}

# ---------------------------------------------------------------------------
# System prompt extraction and byte-level comparison
# ---------------------------------------------------------------------------

# Extract the system prompt from a scenario's messages.
# In the rebuild path, [0] is always 'system' (the cache-stable system prompt).
# In fast-resume, [0] may be 'assistant' if the system prompt was stripped.
sub extract_system_prompt {
    my ($scenario) = @_;
    return undef unless $scenario && $scenario->{messages} && @{$scenario->{messages}};
    my $msgs = $scenario->{messages};

    for my $i (0..$#{$msgs}) {
        my $m = $msgs->[$i];
        next unless ref($m) eq 'HASH';
        next unless ($m->{role} // '') eq 'system';
        my $content = $m->{content} // '';
        next if $content =~ /<thread_summary>/;
        next if $content =~ /^\s*Working directory:/;
        next if $content =~ /^\s*<userContext/;
        next if $content =~ /^\[CONTEXT TRIM:/;
        return { idx => $i, content => $content };
    }
    return undef;
}

# Compare system prompts across all four scenarios.
# Reports byte count, SHA-256, first differing byte offset, and
# identifies which scenario(s) are missing the system prompt.
sub diff_system_prompts {
    my ($scenarios) = @_;
    my %by_name = map { $_->{name} => $_ } @$scenarios;
    my @order = qw(pre-trim post-trim fast-resume rebuild);

    require Digest::SHA;
    my @lines;
    push @lines, "";
    push @lines, "SYSTEM PROMPT BYTE STABILITY";
    push @lines, "-" x 78;

    my %extracts;
    for my $name (@order) {
        my $s = $by_name{$name};
        next unless $s;
        my $sp = extract_system_prompt($s);
        if ($sp) {
            my $sha = Digest::SHA::sha256_hex(encode_utf8($sp->{content}));
            $extracts{$name} = $sp;
            push @lines, sprintf("  %-14s  idx=%-4d  bytes=%-8d  sha256=%s",
                $name, $sp->{idx}, length($sp->{content}), substr($sha, 0, 16));
        } else {
            $extracts{$name} = undef;
            push @lines, sprintf("  %-14s  %-32s  (MISSING - no system prompt found)",
                $name, "MISSING");
        }
    }

    my $canonical;
    for my $name (qw(pre-trim rebuild)) {
        if ($extracts{$name}) {
            $canonical = $extracts{$name};
            last;
        }
    }

    if ($canonical) {
        my $can_sha = Digest::SHA::sha256_hex(encode_utf8($canonical->{content}));
        push @lines, "";
        push @lines, sprintf("  Canonical (from pre-trim): %d bytes, sha256=%s",
            length($canonical->{content}), $can_sha);

        for my $name (@order) {
            next unless exists $extracts{$name};
            if (!defined $extracts{$name}) {
                push @lines, sprintf("  ! %-14s  MISSING system prompt at [0] - model sees different context shape",
                    $name);
            } else {
                my $other_sha = Digest::SHA::sha256_hex(encode_utf8($extracts{$name}{content}));
                if ($other_sha ne $can_sha) {
                    my $a_content = $canonical->{content};
                    my $b_content = $extracts{$name}{content};
                    my $min_len = length($a_content) < length($b_content) ? length($a_content) : length($b_content);
                    my $diff_pos;
                    for (my $i = 0; $i < $min_len; $i++) {
                        if (substr($a_content, $i, 1) ne substr($b_content, $i, 1)) {
                            $diff_pos = $i;
                            last;
                        }
                    }
                    $diff_pos //= $min_len;
                    my $ctx_start = $diff_pos > 50 ? $diff_pos - 50 : 0;
                    my $ctx_len = 100;
                    my $a_ctx = substr($a_content, $ctx_start, $ctx_len);
                    my $b_ctx = substr($b_content, $ctx_start, $ctx_len);
                    $a_ctx =~ s/\n/ /g;
                    $b_ctx =~ s/\n/ /g;
                    push @lines, sprintf("  ! %-14s  system prompt DIFFERS at byte %d (len %d vs %d):",
                        $name, $diff_pos, length($a_content), length($b_content));
                    push @lines, sprintf("      canonical: ...%s...", $a_ctx);
                    push @lines, sprintf("      %s: ...%s...", $name, $b_ctx);
                } else {
                    push @lines, sprintf("  = %-14s  system prompt byte-identical to canonical", $name);
                }
            }
        }
    } else {
        push @lines, "  (no system prompt found in any scenario - unusual)";
    }

    return join("\n", @lines);
}

# ---------------------------------------------------------------------------
# Output renderers
# ---------------------------------------------------------------------------

sub render_scenario_block {
    my ($scenario, $opts) = @_;
    my $name = $scenario->{name};
    my $label = $scenario->{label};
    my $msgs = $scenario->{messages};
    my $notes = $scenario->{notes} || [];

    my @lines;
    push @lines, "## $label";
    push @lines, "";

    if (!@$msgs) {
        push @lines, "  (empty)";
        return join("\n", @lines);
    }

    my ($buckets, $total) = bucket_messages($msgs);

    # Section summary
    push @lines, sprintf("  %d messages, %d tokens (estimated)", scalar(@$msgs), $total);
    push @lines, "";
    push @lines, sprintf("  %-18s  %6s  %8s  %6s", 'Section', 'Count', 'Tokens', '%');
    push @lines, "  " . "-" x 60;
    my @order = qw(system_prompt context_files dialog summary user_context user_input);
    for my $sec (@order) {
        my $count = $buckets->{$sec}{count};
        my $tokens = $buckets->{$sec}{tokens};
        my $pct = $total > 0 ? sprintf("%5.1f%%", 100 * $tokens / $total) : '  0.0%';
        my $bar = $total > 0 ? '#' x int(($tokens / $total) * 30) : '';
        push @lines, sprintf("  %-18s  %6d  %8d  %6s  %s",
            section_label($sec), $count, $tokens, $pct, $bar);
    }
    push @lines, "";

    # Notes (warnings, drift status, etc.)
    if (@$notes) {
        push @lines, "  Notes:";
        for my $n (@$notes) {
            push @lines, "    - $n";
        }
        push @lines, "";
    }

    # Per-message dump (unless diff-only)
    unless ($opts->{diff_only}) {
        my $range = $opts->{range}{$name};
        my @indices;
        if ($range) {
            @indices = @$range;
        } else {
            # Default: show first 10 + last 5 if there are many.
            if (@$msgs > 20) {
                @indices = (0..9, $#$msgs - 4 .. $#$msgs);
            } else {
                @indices = (0..$#$msgs);
            }
        }
        push @lines, "  Messages:";
        for my $i (@indices) {
            next if $i < 0 || $i > $#$msgs;
            my $m = $msgs->[$i];
            unless (ref($m) eq 'HASH') {
                push @lines, sprintf("    [%3d] <NOT-A-HASH: %s>", $i, ref($m) || 'SCALAR');
                next;
            }
            my $role = $m->{role} // '?';
            my $content = $m->{content} // '';
            my $sec = classify_message($m, $i, scalar(@$msgs), $name, $msgs);
            my $sec_tag = "[$sec]";

            my $content_display = $content;
            if (ref($content) eq 'ARRAY') {
                my $s = '';
                $s .= ($_->{text} // '[' . ($_->{type} // '?') . ']') . ' ' for @$content;
                $content_display = $s;
            }
            my $tok = CLIO::Memory::TokenEstimator::estimate_tokens($content_display) + 4;
            $tok += 8 if $role eq 'tool';
            if ($m->{tool_calls}) {
                $tok += CLIO::Memory::TokenEstimator::estimate_tokens(
                    join('', map { $_->{function}{arguments} // '' } @{$m->{tool_calls}}));
            }
            my $tc_tag = '';
            if ($m->{tool_calls}) {
                $tc_tag = " [TC=" . scalar(@{$m->{tool_calls}}) . "]";
            }
            my $preview = $content_display;
            $preview =~ s/\n/ /g;
            $preview = substr($preview, 0, 100);
            $preview .= '...' if length($content_display) > 100;
            push @lines, sprintf("    [%3d] %-10s %-13s %5d tok%s %s",
                $i, $role, $sec_tag, $tok, $tc_tag, $preview);
        }
        push @lines, "";
    }

    return join("\n", @lines);
}

# Render a 4-way divergence report.
sub render_divergence {
    my ($scenarios) = @_;
    my @lines;
    push @lines, "=" x 78;
    push @lines, "DIVERGENCE REPORT";
    push @lines, "=" x 78;

    my @order = qw(pre-trim post-trim fast-resume rebuild);
    my %by_name = map { $_->{name} => $_ } @$scenarios;

    # Per-pair structural diff
    push @lines, "";
    push @lines, "Pairwise message-array diffs (added/removed = content differs):";
    push @lines, "";
    push @lines, sprintf("  %-22s  %8s  %8s  %8s  %8s", 'Pair', 'A msgs', 'B msgs', 'Common', 'Reorder%');
    push @lines, "  " . "-" x 70;

    my @pairs = (
        ['pre-trim',    'fast-resume',  'rebuild vs fast-path cache'],
        ['pre-trim',    'post-trim',    'rebuild before/after trim'],
        ['pre-trim',    'rebuild',      'scenarios 1 vs 4 (sanity)'],
        ['fast-resume', 'rebuild',      'cache vs rebuild (drift)'],
    );
    for my $p (@pairs) {
        my ($na, $nb, $label) = @$p;
        my $a = $by_name{$na};
        my $b = $by_name{$nb};
        next unless $a && $b;
        my $d = diff_messages($a->{messages}, $b->{messages});
        my $byte_flag = $d->{byte_stable} ? '' : ' (!byte-stable)';
        if ($d->{prefix_match_full_mismatch}) {
            $byte_flag = ' (500-char match but full content differs!)';
        }
        push @lines, sprintf("  %-22s  %8d  %8d  %8d  %7.1f%%  %s%s",
            $label,
            scalar(@{$a->{messages}}),
            scalar(@{$b->{messages}}),
            $d->{common},
            100 * $d->{reorder_score},
            ($d->{added} || $d->{removed}) ? '<-- divergence' : '',
            $byte_flag);
    }

    # Token-budget summary
    push @lines, "";
    push @lines, "Token budget per scenario:";
    push @lines, "";
    push @lines, sprintf("  %-22s  %8s  %8s", 'Scenario', 'Msgs', 'Tokens');
    push @lines, "  " . "-" x 45;
    for my $name (@order) {
        my $s = $by_name{$name};
        next unless $s;
        my ($b, $t) = bucket_messages($s->{messages});
        push @lines, sprintf("  %-22s  %8d  %8d", $s->{label}, scalar(@{$s->{messages}}), $t);
    }

    # Highlight red flags
    push @lines, "";
    push @lines, "Red flags:";
    my $flags = 0;
    my $pre = $by_name{'pre-trim'};
    my $fast = $by_name{'fast-resume'};
    my $post = $by_name{'post-trim'};

    if ($pre && $fast && @{$fast->{messages}}) {
        my $d = diff_messages($pre->{messages}, $fast->{messages});
        my $total_change = scalar(@{$d->{added}}) + scalar(@{$d->{removed}});
        if ($total_change > 0) {
            $flags++;
            push @lines, sprintf("  ! fast-resume (%d msgs) diverges from pre-trim rebuild (%d msgs): %d added, %d removed, %.0f%% reorder",
                scalar(@{$fast->{messages}}), scalar(@{$pre->{messages}}),
                scalar(@{$d->{added}}), scalar(@{$d->{removed}}),
                100 * $d->{reorder_score});
            push @lines, "      This means resuming from cache sees a DIFFERENT conversation than rebuilding.";
            push @lines, "      Causes: drift in tools_signature, provider change, or context-window shrinkage.";
        } elsif (!$d->{byte_stable}) {
            $flags++;
            push @lines, sprintf("  ! fast-resume vs pre-trim: same message count (%d) but BYTE-UNSTABLE",
                scalar(@{$pre->{messages}}));
            if ($d->{prefix_match_full_mismatch}) {
                push @lines, "      First 500 chars match on all messages but FULL content differs";
                push @lines, "      (models are sensitive to differences the 500-char cap would miss)";
            } else {
                push @lines, "      Full SHA-256 differs on " . scalar(@{$d->{removed}}) . " message(s)";
            }
        } else {
            push @lines, "  . fast-resume matches pre-trim rebuild (byte-stable)";
        }
    }
    if ($pre && $post) {
        my $d = diff_messages($pre->{messages}, $post->{messages});
        my $dropped = @{$pre->{messages}} - @{$post->{messages}};
        if ($dropped > 0) {
            $flags++;
            push @lines, sprintf("  ! post-trim dropped %d messages from pre-trim (budget enforcement)",
                $dropped);
        }
    }
    if ($fast && $fast->{drift_status} && $fast->{drift_status} ne 'OK') {
        $flags++;
        push @lines, sprintf("  ! fast-path DRIFT: %s", $fast->{drift_status});
        for my $r (@{$fast->{drift_reasons} || []}) {
            push @lines, "      - $r";
        }
        push @lines, "      Resume will fall through to rebuild path (scenario 4).";
    }
    if ($flags == 0) {
        push @lines, "  . No divergence detected - all four scenarios align.";
    }

    return join("\n", @lines);
}

# Extract system prompt info for JSON output.
sub _json_system_prompt_info {
    my ($scenario) = @_;
    my $sp = extract_system_prompt($scenario);
    return undef unless $sp;
    require Digest::SHA;
    return {
        idx => $sp->{idx},
        bytes => length($sp->{content}),
        sha256 => Digest::SHA::sha256_hex(encode_utf8($sp->{content})),
    };
}

sub render_json {
    my ($scenarios, $session_meta) = @_;
    my %by_name = map { $_->{name} => $_ } @$scenarios;

    my @scenario_out;
    for my $s (@$scenarios) {
        my ($b, $t) = bucket_messages($s->{messages});
        my %sections;
        for my $sec (keys %$b) {
            $sections{$sec} = {
                count => $b->{$sec}{count},
                tokens => $b->{$sec}{tokens},
            };
        }
        push @scenario_out, {
            name => $s->{name},
            label => $s->{label},
            message_count => scalar(@{$s->{messages}}),
            total_tokens => $t,
            sections => \%sections,
            notes => $s->{notes} || [],
            drift_status => $s->{drift_status},
            drift_reasons => $s->{drift_reasons} || [],
            # System prompt extraction for byte-level verification
            system_prompt => _json_system_prompt_info($s),
        };
    }

    my @pair_diffs;
    my @pairs = (
        ['pre-trim',    'fast-resume'],
        ['pre-trim',    'post-trim'],
        ['pre-trim',    'rebuild'],
        ['fast-resume', 'rebuild'],
    );
    for my $p (@pairs) {
        my ($na, $nb) = @$p;
        my $a = $by_name{$na};
        my $b = $by_name{$nb};
        next unless $a && $b;
        my $d = diff_messages($a->{messages}, $b->{messages});
        push @pair_diffs, {
            a => $na,
            b => $nb,
            a_count => scalar(@{$a->{messages}}),
            b_count => scalar(@{$b->{messages}}),
            common => $d->{common},
            added_count => scalar(@{$d->{added}}),
            removed_count => scalar(@{$d->{removed}}),
            reorder_pct => sprintf("%.2f", 100 * $d->{reorder_score}),
            byte_stable => $d->{byte_stable} ? 1 : 0,
            prefix_match_full_mismatch => $d->{prefix_match_full_mismatch} ? 1 : 0,
        };
    }

    return {
        session => $session_meta,
        scenarios => \@scenario_out,
        pair_diffs => \@pair_diffs,
    };
}

# ---------------------------------------------------------------------------
# Two-session mode (regression testing)
# ---------------------------------------------------------------------------

sub run_for_session {
    my ($json, $opts) = @_;
    my $session = StubSession->new($json, $opts->{file});

    # Determine the "user input" to use for the pre-trim / rebuild
    # scenarios. We need a real user message to pass to the projection.
    # If the last history message is a user message, use it; otherwise
    # fall back to the last user message in the history; otherwise
    # use a synthetic "<resumed session>" placeholder.
    my $hist = $json->{history} || [];
    my $user_input;
    if (@$hist && ($hist->[-1]{role} // '') eq 'user') {
        $user_input = $hist->[-1]{content} // '';
    } else {
        for my $i (reverse 0..$#$hist) {
            if (($hist->[$i]{role} // '') eq 'user') {
                $user_input = $hist->[$i]{content} // '';
                last;
            }
        }
    }
    $user_input //= '<resumed session>';

    my @scenarios;
    my $pre = build_scenario_pre_trim($session, $user_input);
    push @scenarios, $pre;
    push @scenarios, build_scenario_post_trim($session, $user_input, $opts->{budget}, $pre);
    push @scenarios, build_scenario_fast_resume($session, $user_input, {
        current_provider => $opts->{provider},
        current_tools_sig => $opts->{tools_sig},
        budget => $opts->{budget},
    });
    push @scenarios, build_scenario_rebuild($session, $user_input, $pre);
    return (\@scenarios, $user_input);
}

sub two_session_diff {
    my ($json_a, $json_b) = @_;
    # Build scenarios for both, then diff scenario-by-scenario.
    my $opts = {
        file => '(a)',
        budget => $budget,
        provider => $current_provider,
        tools_sig => $current_tools_sig,
    };
    my ($sc_a, $in_a) = run_for_session($json_a, $opts);
    $opts->{file} = '(b)';
    my ($sc_b, $in_b) = run_for_session($json_b, $opts);

    my @lines;
    push @lines, "=" x 78;
    push @lines, "TWO-SESSION DIFF (regression test mode)";
    push @lines, "=" x 78;
    push @lines, "A: " . ($json_a->{session_name} || basename($session_a_file));
    push @lines, "    history=" . scalar(@{$json_a->{history}||[]}) .
                 " payload=" . scalar(@{$json_a->{last_api_payload}||[]});
    push @lines, "B: " . ($json_b->{session_name} || basename($session_b_file));
    push @lines, "    history=" . scalar(@{$json_b->{history}||[]}) .
                 " payload=" . scalar(@{$json_b->{last_api_payload}||[]});
    push @lines, "";

    my %by_a = map { $_->{name} => $_ } @$sc_a;
    my %by_b = map { $_->{name} => $_ } @$sc_b;
    for my $name (qw(pre-trim post-trim fast-resume rebuild)) {
        my $a = $by_a{$name};
        my $b = $by_b{$name};
        next unless $a && $b;
        my $d = diff_messages($a->{messages}, $b->{messages});
        my $ta = (bucket_messages($a->{messages}))[1];
        my $tb = (bucket_messages($b->{messages}))[1];
        my $delta_tok = $tb - $ta;
        my $delta_msgs = scalar(@{$b->{messages}}) - scalar(@{$a->{messages}});
        push @lines, sprintf("[%s] A=%d msgs/%d tok  vs  B=%d msgs/%d tok  delta=%+d msgs/%+d tok  added=%d removed=%d reorder=%.1f%%",
            $name,
            scalar(@{$a->{messages}}), $ta,
            scalar(@{$b->{messages}}), $tb,
            $delta_msgs, $delta_tok,
            scalar(@{$d->{added}}), scalar(@{$d->{removed}}),
            100 * $d->{reorder_score},
        );
    }
    return join("\n", @lines) . "\n";
}

# ---------------------------------------------------------------------------
# --messages=SCOPE:RANGE parser
# ---------------------------------------------------------------------------

sub parse_messages_arg {
    my ($arg) = @_;
    return {} unless defined $arg && $arg =~ /^(\S+):(\d+)-(\d+)$/;
    return { $1 => [$2..$3] };
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

sub main {
    my $json_a = load_session_json($session_a_file);
    my $opts = {
        file => $session_a_file,
        budget => $budget,
        provider => $current_provider,
        tools_sig => $current_tools_sig,
    };

    my $range = parse_messages_arg($messages_arg);
    my %by_name;
    if ($session_b_file) {
        my $json_b = load_session_json($session_b_file);
        if ($json_output) {
            # JSON mode for two-session - emit structured comparison
            my $opts_a = { %$opts };
            my $opts_b = { %$opts, file => $session_b_file };
            my ($sa, $ia) = run_for_session($json_a, $opts_a);
            my ($sb, $ib) = run_for_session($json_b, $opts_b);
            my %ba = map { $_->{name} => $_ } @$sa;
            my %bb = map { $_->{name} => $_ } @$sb;
            my @diffs;
            for my $name (qw(pre-trim post-trim fast-resume rebuild)) {
                my $a = $ba{$name};
                my $b = $bb{$name};
                next unless $a && $b;
                my $d = diff_messages($a->{messages}, $b->{messages});
                push @diffs, {
                    scenario => $name,
                    a_messages => scalar(@{$a->{messages}}),
                    b_messages => scalar(@{$b->{messages}}),
                    common => $d->{common},
                    added => scalar(@{$d->{added}}),
                    removed => scalar(@{$d->{removed}}),
                    reorder_pct => sprintf("%.2f", 100 * $d->{reorder_score}),
                    byte_stable => $d->{byte_stable} ? 1 : 0,
                    prefix_match_full_mismatch => $d->{prefix_match_full_mismatch} ? 1 : 0,
                };
            }

            print encode_json({
                mode => 'two-session',
                session_a => $session_a_file,
                session_b => $session_b_file,
                scenario_diffs => \@diffs,
            }), "\n";
        } else {
            print two_session_diff($json_a, $json_b);
        }
        return 0;
    }

    my ($scenarios, $user_input) = run_for_session($json_a, $opts);
    %by_name = map { $_->{name} => $_ } @$scenarios;

    if ($json_output) {
        my $meta = {
            file => $session_a_file,
            name => $json_a->{session_name},
            model => $json_a->{selected_model},
            max_tokens => $budget // $json_a->{max_tokens},
            history_count => scalar(@{$json_a->{history}||[]}),
            last_api_payload_count => scalar(@{$json_a->{last_api_payload}||[]}),
        };
        print encode_json(render_json($scenarios, $meta)), "\n";
        return 0;
    }

    if (!$quiet) {
        print "=" x 78, "\n";
        print "CONTEXT COMPARE - ", basename($session_a_file), "\n";
        print "=" x 78, "\n";
        print "Session name:  ", ($json_a->{session_name} // '(none)'), "\n";
        print "Model:         ", ($json_a->{selected_model} // '(unknown)'), "\n";
        print "max_tokens:    ", (defined $json_a->{max_tokens} ? $json_a->{max_tokens} : '(unset)'), "\n";
        print "history:       ", scalar(@{$json_a->{history}||[]}), " messages\n";
        print "last_api_payload: ", scalar(@{$json_a->{last_api_payload}||[]}), " messages\n";
        if (my $m = $json_a->{last_api_metadata}) {
            print "cached model:  ", ($m->{model} // '(unset)'), "\n";
            print "cached provider: ", ($m->{provider} // '(unset)'), "\n";
            print "cached ctx:    ", ($m->{context_window} // '(unset)'), "\n";
        }
        if ($budget) {
            print "Override budget: $budget (forcing trim)\n";
        }
        print "\n";
        print "user_input used for rebuild: ", substr($user_input, 0, 80),
            (length($user_input) > 80 ? '...' : ''), "\n";
        print "\n";
    }

    my @order = qw(pre-trim post-trim fast-resume rebuild);
    for my $name (@order) {
        my $s = $by_name{$name};
        next unless $s;
        my $block = render_scenario_block($s, { diff_only => $diff_only, range => $range });
        print $block, "\n";
    }

    print render_divergence($scenarios), "\n";
    print diff_system_prompts($scenarios), "\n";
    return 0;
}

main() unless caller;

1;
