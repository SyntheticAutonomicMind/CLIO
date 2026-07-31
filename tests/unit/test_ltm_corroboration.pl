#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# test_ltm_corroboration.pl - Regression coverage for LTM trust tier promotion.
#
# Background: agent-memory-atlas (https://neoneye.github.io/agent-memory-atlas/)
# flagged that CLIO's corroboration mechanism could never reach the 2-source
# promotion threshold because $ENV{CLIO_AGENT_ID} and $ENV{CLIO_SESSION_ID}
# were never assigned. Every corroboration defaulted to source key
# "unknown:unknown" and the dedup check silently dropped the second one.
#
# These tests pin down:
#   1. The original bug: default identity never promotes.
#   2. Distinct source identities (agent:session pairs) do promote.
#   3. Same identity twice does not double-count (sybil resistance).
#   4. Env-var-driven identity works (post-fix launch path).
#   5. Render output matches the tier badge ([UNVERIFIED] vs [TRUSTED]).
#   6. Manual /memory promote still works (unconditional override).
#   7. Persisted entries load with their corroboration_sources intact.
#   8. Type-filtered operations accept singular type names ('discovery',
#      'pattern', ...) and resolve them to the plural category keys used
#      in the LTM JSON.

use strict;
use warnings;
use utf8;
use lib 'lib';

use Test::More;
use CLIO::Memory::LongTerm;
use CLIO::Util::JSON qw(encode_json decode_json);
use File::Temp qw(tempfile);

my $tests_run = 0;
my $tests_failed = 0;

# Save/restore any env vars that callers might leak into our tests.
# add_corroboration reads these directly; we never want the test
# process inheriting whatever was in the launcher's environment.
my @saved_env = map { ($_, $ENV{$_}) } grep { exists $ENV{$_} } qw(CLIO_AGENT_ID CLIO_SESSION_ID);
delete $ENV{CLIO_AGENT_ID};
delete $ENV{CLIO_SESSION_ID};
END {
    for (my $i = 0; $i < @saved_env; $i += 2) {
        $ENV{$saved_env[$i]} = $saved_env[$i + 1];
    }
}

# ----- Test 1: Original bug --------------------------------------------------
# With no env vars set, every corroboration collapses to source key
# "unknown:unknown". The dedup check skips the second call, so the
# corroboration_count never reaches the 2-source threshold and the
# entry stays at tier=unverified. This is what the agent-memory-atlas
# flagged - the system was designed to defend against memory poisoning
# but never had a working identity to defend with.
subtest 'default identity collapses to unknown:unknown and never promotes' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery("Default identity test entry", 0.9);

    my $r1 = $ltm->add_corroboration("Default identity test entry");
    is($r1->{found}, 1, "first corroboration found the entry");
    is($r1->{corroboration_count}, 1, "first corroboration increments to 1");
    is($r1->{tier}, 'unverified', "after 1 source: tier=unverified");
    is($r1->{promoted}, 0, "after 1 source: not promoted");

    my $r2 = $ltm->add_corroboration("Default identity test entry");
    # The bug: this call is silently a no-op because the source key
    # "unknown:unknown" is already in corroboration_sources.
    is($r2->{found}, 1, "second corroboration returns found=1");
    is($r2->{corroboration_count}, 1, "second corroboration stays at 1 (no double-count)");
    is($r2->{tier}, 'unverified', "tier remains unverified (NEVER promoted)");
    is($r2->{promoted}, 0, "promoted=0");

    my $r3 = $ltm->add_corroboration("Default identity test entry");
    is($r3->{corroboration_count}, 1, "third corroboration still at 1");
    is($r3->{tier}, 'unverified', "still unverified");

    # Confirm the recorded source.
    my $entry = $ltm->{patterns}{discoveries}[0];
    is_deeply($entry->{corroboration_sources}, ['unknown:unknown'],
        "source collapsed to 'unknown:unknown'");
};

# ----- Test 2: Distinct sources promote --------------------------------------
# When two distinct agent:session pairs corroborate, the entry crosses
# the 2-source threshold and auto-promotes to tier=trusted. This is the
# happy path that the original bug made unreachable.
subtest 'two distinct sources auto-promote to TRUSTED' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery("Distinct sources test entry", 0.9);

    my $r1 = $ltm->add_corroboration(
        "Distinct sources test entry",
        "agent_alpha",
        "session_alpha",
    );
    is($r1->{corroboration_count}, 1, "first source: count=1");
    is($r1->{tier}, 'unverified', "first source: unverified");
    is($r1->{promoted}, 0, "first source: not promoted");

    my $r2 = $ltm->add_corroboration(
        "Distinct sources test entry",
        "agent_beta",
        "session_beta",
    );
    is($r2->{corroboration_count}, 2, "second source: count=2");
    is($r2->{tier}, 'trusted', "second source: tier=trusted");
    is($r2->{promoted}, 1, "second source: PROMOTED");

    my $entry = $ltm->{patterns}{discoveries}[0];
    is_deeply($entry->{corroboration_sources},
        ['agent_alpha:session_alpha', 'agent_beta:session_beta'],
        "both sources recorded");
};

# ----- Test 3: Same agent across two sessions counts as different sources ----
# Design intent: a single agent cannot self-promote within one session,
# but two sessions of the same agent are distinct sessions and DO count
# as different sources. This matches the existing dedup key (agent:session)
# and the threat model (a session restart is a real barrier).
subtest 'same agent across two sessions counts as distinct sources' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery("Two sessions same agent", 0.9);

    my $r1 = $ltm->add_corroboration("Two sessions same agent", "main", "sess_001");
    is($r1->{corroboration_count}, 1, "session 1: count=1");
    is($r1->{tier}, 'unverified', "session 1: unverified");

    my $r2 = $ltm->add_corroboration("Two sessions same agent", "main", "sess_002");
    is($r2->{corroboration_count}, 2, "session 2: count=2 (different session)");
    is($r2->{tier}, 'trusted', "session 2: PROMOTED");
};

# ----- Test 4: Env-var identity -----------------------------------------------
# This is the post-fix launch path: `clio` (and SubAgent.pm) set
# $ENV{CLIO_AGENT_ID} and $ENV{CLIO_SESSION_ID} so LongTerm.pm picks up
# the right identity without callers having to plumb it through.
subtest 'env-var identity works (CLIO_AGENT_ID + CLIO_SESSION_ID)' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery("Env var identity test", 0.9);

    # Session 1 sets env vars and corroborates.
    $ENV{CLIO_AGENT_ID}   = 'main';
    $ENV{CLIO_SESSION_ID} = 'sess_env_001';
    my $r1 = $ltm->add_corroboration("Env var identity test");
    is($r1->{corroboration_count}, 1, "env-var session 1: count=1");
    is($r1->{tier}, 'unverified', "env-var session 1: unverified");

    # Session 2 starts fresh; different CLIO_SESSION_ID, same CLIO_AGENT_ID.
    $ENV{CLIO_SESSION_ID} = 'sess_env_002';
    my $r2 = $ltm->add_corroboration("Env var identity test");
    is($r2->{corroboration_count}, 2, "env-var session 2: count=2");
    is($r2->{tier}, 'trusted', "env-var session 2: PROMOTED");

    my $entry = $ltm->{patterns}{discoveries}[0];
    is_deeply($entry->{corroboration_sources},
        ['main:sess_env_001', 'main:sess_env_002'],
        "env-var sources recorded with full agent:session key");
};

# ----- Test 5: Same source key deduplicates (sybil resistance) ---------------
# One agent:session pair can't double-count. This is the sybil resistance
# mechanism: even if a single agent calls add_corroboration 1000 times,
# the count only goes up once.
subtest 'same source key does not double-count' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery("Sybil resistance test", 0.9);

    for my $i (1..5) {
        $ltm->add_corroboration("Sybil resistance test", "alpha", "sess_a");
    }
    my $entry = $ltm->{patterns}{discoveries}[0];
    is($entry->{corroboration_count}, 1, "5 calls from same source: count still 1");
    is($entry->{tier}, 'unverified', "5 calls from same source: still unverified");
    is_deeply($entry->{corroboration_sources}, ['alpha:sess_a'],
        "source recorded exactly once");
};

# ----- Test 6: Render badge matches tier --------------------------------------
# Render output must reflect the current tier. Until the fix lands, every
# entry would render as [UNVERIFIED]; after, the same entry can render as
# [TRUSTED] once promoted.
subtest 'render badge reflects tier ([UNVERIFIED] vs [TRUSTED])' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery("Render badge test", 0.9);
    $ltm->add_problem_solution("render test error", "render test solution", []);

    my ($section, $included, $total) = $ltm->render_budgeted_section(max_chars => 5000);
    like($section, qr/\[UNVERIFIED\]/,
        "unverified entry renders [UNVERIFIED] badge");
    unlike($section, qr/\[TRUSTED\]/,
        "unverified entry does NOT render [TRUSTED] badge");

    # Promote and re-render.
    $ltm->add_corroboration("Render badge test", "agent_a", "session_a");
    $ltm->add_corroboration("Render badge test", "agent_b", "session_b");
    ($section, $included, $total) = $ltm->render_budgeted_section(max_chars => 5000);
    like($section, qr/\[TRUSTED\]/,
        "promoted entry renders [TRUSTED] badge");
    like($section, qr/\(corroborated x2\)/,
        "promoted entry shows corroboration count");
};

# ----- Test 7: Manual promote is unconditional ---------------------------------
# promote_entry() is the manual /memory promote override. It should work
# regardless of corroboration state and should not be blocked by the
# env-var identity bug. This is the documented fallback path.
subtest 'manual /memory promote bypasses corroboration requirement' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery("Manual promote test", 0.9);

    my $result = $ltm->promote_entry("Manual promote test");
    is($result->{found}, 1, "promote found the entry");
    is($result->{promoted}, 1, "promote returned promoted=1");
    is($result->{tier}, 'trusted', "tier is trusted after manual promote");

    my $entry = $ltm->{patterns}{discoveries}[0];
    is($entry->{tier}, 'trusted', "entry tier is trusted");
    is($entry->{corroboration_count}, 0,
        "manual promote does NOT add corroboration (unconditional)");
};

# ----- Test 8: Persisted entries retain corroboration_sources ----------------
# add_corroboration uses corroboration_sources as the dedup key. After
# save/load, those sources must still be present so future corroborations
# can correctly recognize the prior sources.
subtest 'save/load preserves corroboration_sources' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery("Save load test", 0.9);
    $ltm->add_corroboration("Save load test", "alpha", "sess_alpha");

    my ($fh, $path) = tempfile(SUFFIX => '.json', UNLINK => 1);
    close $fh;
    $ltm->save($path);

    my $loaded = CLIO::Memory::LongTerm->load($path);
    my $entry = $loaded->{patterns}{discoveries}[0];
    is_deeply($entry->{corroboration_sources}, ['alpha:sess_alpha'],
        "corroboration_sources survived save/load");

    # And the dedup still works against the loaded source.
    my $r = $loaded->add_corroboration("Save load test", "alpha", "sess_alpha");
    is($r->{corroboration_count}, 1,
        "duplicate of loaded source is still deduped");

    # A different source still increments.
    my $r2 = $loaded->add_corroboration("Save load test", "beta", "sess_beta");
    is($r2->{corroboration_count}, 2,
        "new source against loaded entry still increments");
    is($r2->{tier}, 'trusted', "loaded entry + new source promotes");
};

# ----- Test 9: Pattern/solution/failure corroboration all work ---------------
# Confirm corroboration works across every category, not just discoveries.
subtest 'corroboration works across all entry categories' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery("disc cat test", 0.9);
    $ltm->add_problem_solution("sol cat error", "sol cat fix", []);
    $ltm->add_code_pattern("pat cat test", 0.9, []);
    $ltm->add_workflow(['read', 'fix'], 1);
    $ltm->add_failure("fail cat what", "fail cat impact", "fail cat prevention");

    for my $term ('disc cat test', 'sol cat', 'pat cat test', 'fix', 'fail cat what') {
        $ltm->add_corroboration($term, "a1", "s1");
        my $r = $ltm->add_corroboration($term, "a2", "s2");
        is($r->{tier}, 'trusted', "category entry '$term' promoted to trusted");
        is($r->{promoted}, 1, "category entry '$term' reported promoted=1");
    }
};

# ----- Test 10: Consolidation respects tier for age-out -----------------------
# Unverified entries age out after 30 days; trusted entries get the full 90.
# This is the second-tier penalty the agent-memory-atlas reported.
subtest 'consolidate respects tier for age-out cutoff' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    my $now = time();

    # Add an unverified entry aged 45 days with low confidence.
    push @{$ltm->{patterns}{discoveries}}, {
        fact => "old unverified",
        confidence => 0.4,
        timestamp => $now - (45 * 86400),
        tier => 'unverified',
    };

    # Add a trusted entry aged 45 days with same confidence.
    push @{$ltm->{patterns}{discoveries}}, {
        fact => "old trusted",
        confidence => 0.4,
        timestamp => $now - (45 * 86400),
        tier => 'trusted',
    };

    $ltm->consolidate(max_age_days => 90);

    my @remaining = @{$ltm->{patterns}{discoveries}};
    my @texts = map { $_->{fact} } @remaining;

    ok(!(grep { $_ eq 'old unverified' } @texts),
        "unverified entry aged 45d removed (30-day cutoff)");
    ok((grep { $_ eq 'old trusted' } @texts),
        "trusted entry aged 45d kept (90-day cutoff)");
};

# ----- Test 11: New add_* methods record env-var source when set --------------
# add_discovery/add_solution/add_code_pattern/add_workflow/add_failure all
# stamp source_agent and source_session on new entries from $ENV{CLIO_AGENT_ID}
# / $ENV{CLIO_SESSION_ID}. Without this the LTM is born blind to its own
# origin (every entry shows source_agent=unknown).
subtest 'add_* methods record env-var identity on new entries' => sub {
    $ENV{CLIO_AGENT_ID}   = 'main';
    $ENV{CLIO_SESSION_ID} = 'sess_origin_001';

    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery("origin discovery", 0.9);
    $ltm->add_problem_solution("origin error", "origin fix", []);
    $ltm->add_code_pattern("origin pattern", 0.9, []);
    $ltm->add_workflow(['read', 'write'], 1);
    $ltm->add_failure("origin failure", "origin impact", "origin prevention");

    my @discoveries = @{$ltm->{patterns}{discoveries}};
    is($discoveries[0]{source_agent}, 'main', 'discovery source_agent=main');
    is($discoveries[0]{source_session}, 'sess_origin_001', 'discovery source_session');

    my @solutions = @{$ltm->{patterns}{problem_solutions}};
    is($solutions[0]{source_agent}, 'main', 'solution source_agent=main');

    my @patterns = @{$ltm->{patterns}{code_patterns}};
    is($patterns[0]{source_agent}, 'main', 'pattern source_agent=main');

    my @workflows = @{$ltm->{patterns}{workflows}};
    is($workflows[0]{source_agent}, 'main', 'workflow source_agent=main');

    my @failures = @{$ltm->{patterns}{failures}};
    is($failures[0]{source_agent}, 'main', 'failure source_agent=main');
};

# ----- Test 12: add_corroboration over explicit args ignores env vars --------
# Caller-supplied source_agent / source_session must take precedence over
# the env-var fallback. This is important for tests and for scripts that
# invoke add_corroboration directly with custom identity (e.g., simulating
# sub-agent corroboration from the parent).
subtest 'explicit args override env-var fallback' => sub {
    $ENV{CLIO_AGENT_ID}   = 'env_agent';
    $ENV{CLIO_SESSION_ID} = 'env_session';

    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery("override test", 0.9);

    $ltm->add_corroboration("override test", "explicit_agent", "explicit_session");
    my $entry = $ltm->{patterns}{discoveries}[0];
    is($entry->{corroboration_sources}[0], 'explicit_agent:explicit_session',
        "explicit args took precedence over env vars");
};

# ----- Test 13: entry_type filters accept singular names ---------------------
# The tool layer passes singular type names ('discovery', 'solution',
# 'pattern', 'workflow', 'failure') but the LTM JSON stores entries under
# plural category keys ('discoveries', 'problem_solutions', 'code_patterns',
# 'workflows', 'failures'). Before the normalization fix, add_corroboration /
# promote_entry / get_entry_tier used the filter string directly as a hash
# key, so a type-filtered call looked in patterns{discovery} (empty) and
# always returned "No entry matching" even for exact substrings. The tool
# schema documents singular names, so this broke every type-filtered call.
subtest 'entry_type filter accepts singular type names' => sub {
    my $ltm = CLIO::Memory::LongTerm->new();
    $ltm->add_discovery("filter disc", 0.9);
    $ltm->add_problem_solution("filter sol error", "filter sol fix", []);
    $ltm->add_code_pattern("filter pat", 0.9, []);
    $ltm->add_workflow(['filter', 'steps'], 1);
    $ltm->add_failure("filter fail what", "filter fail impact", "filter fail prevention");

    # add_corroboration with singular type filter
    my $r = $ltm->add_corroboration("filter disc", "a1", "s1", "discovery");
    is($r->{found}, 1, "discovery filter finds the discovery");
    is($r->{category}, 'discoveries', "discovery filter resolves to plural key");
    is($r->{corroboration_count}, 1, "discovery filter increments count");

    $r = $ltm->add_corroboration("filter sol", "a1", "s1", "solution");
    is($r->{found}, 1, "solution filter finds the solution");
    is($r->{category}, 'problem_solutions', "solution filter resolves to problem_solutions");

    $r = $ltm->add_corroboration("filter pat", "a1", "s1", "pattern");
    is($r->{found}, 1, "pattern filter finds the pattern");
    is($r->{category}, 'code_patterns', "pattern filter resolves to code_patterns");

    $r = $ltm->add_corroboration("filter", "a1", "s1", "workflow");
    is($r->{found}, 1, "workflow filter finds the workflow");
    is($r->{category}, 'workflows', "workflow filter resolves to workflows");

    $r = $ltm->add_corroboration("filter fail", "a1", "s1", "failure");
    is($r->{found}, 1, "failure filter finds the failure");
    is($r->{category}, 'failures', "failure filter resolves to failures");

    # get_entry_tier with singular filter
    my $t = $ltm->get_entry_tier("filter disc", "discovery");
    is($t->{found}, 1, "get_entry_tier(discovery) finds the discovery");
    is($t->{category}, 'discoveries', "get_entry_tier resolves category");

    # promote_entry with singular filter
    my $p = $ltm->promote_entry("filter pat", "pattern");
    is($p->{found}, 1, "promote_entry(pattern) finds the pattern");
    is($p->{tier}, 'trusted', "promote_entry(pattern) promotes");

    # Filtered second source crosses the threshold and promotes.
    my $r2 = $ltm->add_corroboration("filter disc", "a2", "s2", "discovery");
    is($r2->{promoted}, 1, "filtered second source promotes to TRUSTED");
    is($r2->{tier}, 'trusted', "filtered second source tier=trusted");
};

done_testing();
