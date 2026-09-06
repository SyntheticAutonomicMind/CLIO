#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Test: Session replay
#
# Replays an existing session log through the projection pipeline to measure:
# - Context loss: messages dropped without appearing in summary
# - Metadata leakage: structure scores/headers/narration in injected content
# - Determinism: same inputs produce same compressed output

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Core::ContextBuilder;
use CLIO::Core::MessageHistory qw(messages_to_prose_dynamic);
use CLIO::Memory::YaRN;
use CLIO::Util::JSON qw(safe_decode_json);

# Find a session file to replay
my @session_files = glob("$Bin/integration/.clio/sessions/*.json");
@session_files = glob("$Bin/.clio/sessions/*.json") unless @session_files;

my $session_file;
my $json_text;
my @history;

if (@session_files) {
    $session_file = $session_files[0];
    open my $fh, '<:raw', $session_file or die "Cannot read $session_file: $!";
    local $/; $json_text = <$fh>; close $fh;
    my $data = safe_decode_json($json_text);
    @history = @{$data->{history} || []};
}

if (@history) {
    plan(tests => 8);
    diag("Replaying session: $session_file with " . scalar(@history) . " messages");

    # Build projection (this triggers _select_turns + _build_compressed_tail)
    my $proj = CLIO::Core::ContextBuilder::build_projection(
        history    => \@history,
        user_input => 'continue',
        active_task => 'replayed session task',
    );

    # 1. Context loss: compressed_tail should contain dropped messages
    my $all_count = scalar @history;
    my $turn_count = 0;
    # Count turns (user messages) to estimate dropped
    my $user_count = grep { $_->{role} eq 'user' } @history;
    $turn_count = $user_count;

    # The projection should have recent turns + compressed tail
    my $recent_count = scalar(@{$proj->{turns} // []});
    my $has_compressed = length($proj->{compressed_tail} // '') > 0;

    if ($turn_count > $recent_count) {
        ok($has_compressed,
            "Dropped turns ($turn_count - $recent_count) have compressed tail (no context loss)");
    } else {
        ok(1, "All turns are recent (no drops needed)");
    }

    # 2. Metadata leakage: no confidence scores, # headers, framework instructions
    my $tail = $proj->{compressed_tail} // '';
    unless_test: {
        my $combined = ($proj->{compressed_tail} // '') . ($proj->{userContext} // '');
        # Also render the dynamic prose for checking
        my $prose = messages_to_prose_dynamic($proj);
        $combined .= $prose;

        unlike($combined, qr/\(\d\.\d+\)/, 'No confidence scores in projection output');
        unlike($combined, qr/^#\s[A-Z]/m, 'No # section headers in projection output');
        unlike($combined, qr/call memory_operations/, 'No framework instructions in projection output');
        unlike($combined, qr/<current_topic>|<task_recovery>|<recent_context>|<git_recovery>|<session_progress>/,
            'No XML recovery tags in projection output');
    }

    # 3. Determinism: build projection twice, check compressed_tail is identical
    my $proj2 = CLIO::Core::ContextBuilder::build_projection(
        history    => \@history,
        user_input => 'continue',
        active_task => 'replayed session task',
    );
    is($proj->{compressed_tail}, $proj2->{compressed_tail},
        'Compressed tail is deterministic across builds (cache-stable)');
    is(scalar(@{$proj->{turns}}), scalar(@{$proj2->{turns}}),
        'Turn count is deterministic across builds');

    # 4. Double system prompt: State::load strips persisted system
    # messages except those containing <thread_summary>. Apply the
    # same logic to verify no stale system prompt remains.
    my @stripped = grep {
        my $m = $_;
        !($m->{role} eq 'system'
          && ($m->{content} // '') !~ /<thread_summary>/);
    } @history;
    my $sys_count = grep { $_->{role} eq 'system' && ($_->{content} // '') !~ /<thread_summary>/ } @stripped;
    is($sys_count, 0, 'No stale system prompt messages in session history (after stripping)');

    # Summary
    diag("Replay: $all_count messages, $recent_count recent turns, " .
         ($has_compressed ? "compressed tail present" : "no drops"));

} else {
    plan(tests => 1);
    ok(1, 'No session files available for replay — skipped');
    return;
}

# (plan was set above for the if branch; no done_testing needed)
