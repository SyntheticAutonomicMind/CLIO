#!/usr/bin/env perl
# Tests for LTM token-budget rendering, scoring, consolidation, and dedup

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Memory::LongTerm;

my $PASS = 0;
my $FAIL = 0;

sub ok_test {
    my ($condition, $name) = @_;
    if ($condition) {
        $PASS++;
        ok(1, $name);
    } else {
        $FAIL++;
        ok(0, $name);
    }
}

# ============================================================
# Test 1: score_entry basics
# ============================================================

my $ltm = CLIO::Memory::LongTerm->new();
my $now = time();

# Recent high-confidence entry should score higher than old low-confidence
my $recent_high = {
    fact => "Recent high confidence",
    confidence => 0.95,
    verified => 1,
    timestamp => $now,
    updated => $now,
};

my $old_low = {
    fact => "Old low confidence",
    confidence => 0.3,
    verified => 0,
    timestamp => $now - 120 * 86400,  # 120 days old
    updated => $now - 120 * 86400,
};

my $score_rh = $ltm->score_entry($recent_high, 'discovery', $now);
my $score_ol = $ltm->score_entry($old_low, 'discovery', $now);

ok_test($score_rh > $score_ol, "score_entry: recent high-confidence > old low-confidence ($score_rh vs $score_ol)");
ok_test($score_rh > 0, "score_entry: positive score for valid entry");

# Solutions should score slightly higher than discoveries at same confidence
my $sol = { error => "test", solution => "fix", confidence => 0.8, solved_count => 3, timestamp => $now };
my $disc = { fact => "test", confidence => 0.8, verified => 1, timestamp => $now };

my $sol_score = $ltm->score_entry($sol, 'solution', $now);
my $disc_score = $ltm->score_entry($disc, 'discovery', $now);
ok_test($sol_score > $disc_score, "score_entry: solution scores higher than discovery at same confidence ($sol_score vs $disc_score)");

# ============================================================
# Test 2: get_scored_entries
# ============================================================

$ltm = CLIO::Memory::LongTerm->new();
$ltm->{patterns}{discoveries} = [
    { fact => "Fact 1", confidence => 0.9, verified => 1, timestamp => $now },
    { fact => "Fact 2", confidence => 0.5, verified => 0, timestamp => $now - 60 * 86400 },
];
$ltm->{patterns}{problem_solutions} = [
    { error => "Err 1", solution => "Fix 1", confidence => 0.8, solved_count => 5, timestamp => $now },
];

my $scored = $ltm->get_scored_entries($now);
ok_test(scalar(@$scored) == 3, "get_scored_entries: returns all entries (got " . scalar(@$scored) . ")");
ok_test($scored->[0]{score} >= $scored->[1]{score}, "get_scored_entries: sorted by score descending");

# ============================================================
# Test 3: render_budgeted_section - basic rendering
# ============================================================

$ltm = CLIO::Memory::LongTerm->new();
for my $i (1..10) {
    push @{$ltm->{patterns}{discoveries}}, {
        fact => "Discovery number $i with some detail about topic $i",
        confidence => 0.9 - ($i * 0.05),
        verified => 1,
        timestamp => $now - ($i * 86400),
        updated => $now - ($i * 86400),
    };
}
for my $i (1..10) {
    push @{$ltm->{patterns}{problem_solutions}}, {
        error => "Error pattern $i that occurs in module $i",
        solution => "Solution for error $i: apply fix number $i to the codebase",
        confidence => 0.8,
        solved_count => $i,
        timestamp => $now - ($i * 86400),
        updated => $now - ($i * 86400),
    };
}

my ($section, $included, $total) = $ltm->render_budgeted_section(max_chars => 12000);
ok_test($included > 0, "render_budgeted: included $included entries");
ok_test($total == 20, "render_budgeted: total is 20 (got $total)");
ok_test(length($section) <= 12000, "render_budgeted: within budget (" . length($section) . " chars)");
ok_test($section =~ /Key Discoveries/, "render_budgeted: has discoveries section");
ok_test($section =~ /Problem Solutions/, "render_budgeted: has solutions section");
ok_test($section =~ /highest-priority patterns/, "render_budgeted: has updated header");

# ============================================================
# Test 4: render_budgeted_section - tight budget forces exclusions
# ============================================================

my ($section_tight, $inc_tight, $tot_tight) = $ltm->render_budgeted_section(max_chars => 2000);
ok_test($inc_tight < $total, "render_budgeted tight: excluded some entries ($inc_tight < $tot_tight)");
ok_test(length($section_tight) <= 2000, "render_budgeted tight: within tight budget (" . length($section_tight) . " chars)");

# Check for index footer
ok_test($section_tight =~ /Additional memories available/, "render_budgeted tight: has index footer");
ok_test($section_tight =~ /memory_operations/, "render_budgeted tight: index footer has search hint");

# ============================================================
# Test 5: _extract_keywords
# ============================================================

my @test_entries = (
    { entry => { fact => "Terminal corruption when spawning sub-agents" }, type => 'discovery' },
    { entry => { fact => "Terminal state after fork requires ReadMode reset" }, type => 'discovery' },
    { entry => { error => "SSH connection timeout handling" }, type => 'solution' },
);

my $keywords = $ltm->_extract_keywords(\@test_entries, 3);
ok_test(defined $keywords && length($keywords) > 0, "_extract_keywords: returns keywords");
ok_test($keywords =~ /terminal/i, "_extract_keywords: found 'terminal' keyword ($keywords)");

# ============================================================
# Test 6: Jaccard similarity
# ============================================================

my $sim1 = $ltm->_jaccard_similarity(
    "The quick brown fox jumps over the lazy dog",
    "The quick brown fox leaps over the lazy dog"
);
ok_test($sim1 > 0.7, "jaccard: high similarity for near-identical ($sim1)");

my $sim2 = $ltm->_jaccard_similarity(
    "Terminal corruption when spawning processes",
    "Authentication OAuth token refresh cycle"
);
ok_test($sim2 < 0.3, "jaccard: low similarity for unrelated ($sim2)");

# ============================================================
# Test 7: consolidate - confidence decay
# ============================================================

$ltm = CLIO::Memory::LongTerm->new();
$ltm->{patterns}{discoveries} = [
    {
        fact => "Old stale discovery",
        confidence => 0.8,
        verified => 0,
        timestamp => $now - 120 * 86400,
        updated => $now - 120 * 86400,  # 120 days, no update
    },
    {
        fact => "Recent discovery",
        confidence => 0.9,
        verified => 1,
        timestamp => $now,
        updated => $now,
    },
];

my $stats = $ltm->consolidate(confidence_decay_days => 60);
ok_test($stats->{decayed} >= 1, "consolidate: decayed stale entry");

my $old_entry = $ltm->{patterns}{discoveries}[0];
ok_test(
    $old_entry->{confidence} < 0.8,
    "consolidate: confidence reduced from 0.8 to $old_entry->{confidence}"
);

# ============================================================
# Test 8: consolidate - deduplication
# ============================================================

$ltm = CLIO::Memory::LongTerm->new();
$ltm->{patterns}{discoveries} = [
    { fact => "CLIO memory operations store and retrieve work correctly in scratch test", confidence => 0.9, timestamp => $now, updated => $now },
    { fact => "CLIO memory operations store and retrieve work as expected in scratch test", confidence => 0.8, timestamp => $now, updated => $now },
    { fact => "Something completely different about OAuth tokens", confidence => 0.7, timestamp => $now, updated => $now },
];

$stats = $ltm->consolidate(dedup_threshold => 0.7);
ok_test($stats->{deduped} >= 1, "consolidate: deduped near-duplicate entries");
ok_test(
    scalar(@{$ltm->{patterns}{discoveries}}) <= 2,
    "consolidate: removed duplicate (have " . scalar(@{$ltm->{patterns}{discoveries}}) . ")"
);

# Verify the higher-confidence one was kept
my @facts = map { $_->{fact} } @{$ltm->{patterns}{discoveries}};
my @high_conf = grep { /correctly/ } @facts;
ok_test(scalar(@high_conf) >= 1, "consolidate: kept higher-confidence duplicate");

# ============================================================
# Test 9: consolidate - hard caps
# ============================================================

$ltm = CLIO::Memory::LongTerm->new();
for my $i (1..50) {
    push @{$ltm->{patterns}{discoveries}}, {
        fact => "Unique discovery $i: " . ('x' x (20 + $i)) . " about " . ('topic' . $i) x 3,
        confidence => 0.5 + rand(0.5),
        verified => 1,
        timestamp => $now - ($i * 86400),
        updated => $now - ($i * 86400),
    };
}

$stats = $ltm->consolidate(max_discoveries => 10, dedup_threshold => 0.95);
ok_test(
    scalar(@{$ltm->{patterns}{discoveries}}) <= 10,
    "consolidate: hard cap applied (have " . scalar(@{$ltm->{patterns}{discoveries}}) . ", max 10)"
);

# ============================================================
# Test 10: maybe_consolidate - gate conditions
# ============================================================

$ltm = CLIO::Memory::LongTerm->new();
$ltm->{metadata}{last_consolidated} = $now;  # Just consolidated

# Should skip - too recent
my $result = $ltm->maybe_consolidate(min_hours => 24);
ok_test(!defined $result, "maybe_consolidate: skipped (too recent)");

# Should skip - not enough entries
$ltm->{metadata}{last_consolidated} = $now - 48 * 3600;  # 48 hours ago
$result = $ltm->maybe_consolidate(min_entries => 20);
ok_test(!defined $result, "maybe_consolidate: skipped (too few entries)");

# Should run - old enough and enough entries
for my $i (1..25) {
    push @{$ltm->{patterns}{discoveries}}, {
        fact => "Entry $i", confidence => 0.8, timestamp => $now, updated => $now,
    };
}
$result = $ltm->maybe_consolidate(min_hours => 24, min_entries => 20);
ok_test(defined $result, "maybe_consolidate: ran (conditions met)");

# ============================================================
# Test 11: absolutize_dates
# ============================================================

my $text = "I found this bug today and it was also happening yesterday";
my $abs = $ltm->absolutize_dates($text);
ok_test($abs !~ /\btoday\b/i, "absolutize_dates: replaced 'today'");
ok_test($abs !~ /\byesterday\b/i, "absolutize_dates: replaced 'yesterday'");
ok_test($abs =~ /\d{4}-\d{2}-\d{2}/, "absolutize_dates: contains absolute date");

my $no_dates = "This is a normal fact with no date references";
my $unchanged = $ltm->absolutize_dates($no_dates);
ok_test($unchanged eq $no_dates, "absolutize_dates: no change when no dates present");

# ============================================================
# Test 12: get_stats includes last_consolidated
# ============================================================

$ltm = CLIO::Memory::LongTerm->new();
$ltm->{metadata}{last_consolidated} = $now;
my $ltm_stats = $ltm->get_stats();
ok_test(defined $ltm_stats->{last_consolidated}, "get_stats: includes last_consolidated");
ok_test($ltm_stats->{last_consolidated} == $now, "get_stats: correct last_consolidated value");

# ============================================================
# Test 13: render_budgeted_section - empty LTM
# ============================================================

$ltm = CLIO::Memory::LongTerm->new();
my ($empty_section, $empty_inc, $empty_tot) = $ltm->render_budgeted_section();
ok_test($empty_section eq '', "render_budgeted: empty for empty LTM");
ok_test($empty_inc == 0, "render_budgeted: 0 included for empty LTM");

# ============================================================
# 8. search_entries
# ============================================================

my $search_ltm = CLIO::Memory::LongTerm->new();
$search_ltm->add_discovery('Terminal corruption from fork processes', 0.9);
$search_ltm->add_discovery('Session resume broken for providers', 0.8);
$search_ltm->add_problem_solution(
    'ESC interrupt stops working after terminal_operations call',
    'Root cause: TerminalOperations used local SIG ALRM',
    [],
    0.95,
);
$search_ltm->add_code_pattern('Always use process groups with fork', 0.9, []);

# Exact substring match
my $results = $search_ltm->search_entries('Terminal corruption');
ok_test(scalar(@$results) >= 1, "search_entries: exact match found");
ok_test($results->[0]{type} eq 'discovery', "search_entries: correct type");

# Multi-word fuzzy match
my $results2 = $search_ltm->search_entries('terminal fork processes');
ok_test(scalar(@$results2) >= 1, "search_entries: multi-word match");

# No match
my $results3 = $search_ltm->search_entries('xyzzy nonexistent unicorn');
ok_test(scalar(@$results3) == 0, "search_entries: no false positives");

# Refresh updates timestamp
my $before_ts = $search_ltm->{patterns}{discoveries}[0]{updated} || 0;
sleep(1);
my $results4 = $search_ltm->search_entries('Terminal corruption', refresh => 1);
my $after_ts = $search_ltm->{patterns}{discoveries}[0]{updated} || 0;
ok_test($after_ts > $before_ts, "search_entries: refresh updates timestamp");

# search_count incremented
ok_test(($search_ltm->{patterns}{discoveries}[0]{search_count} || 0) >= 1,
    "search_entries: search_count incremented");

# search_count boosts score
my $entry_with_search = {
    fact       => 'test entry',
    confidence => 0.8,
    updated    => time(),
    search_count => 5,
};
my $entry_without_search = {
    fact       => 'test entry',
    confidence => 0.8,
    updated    => time(),
    search_count => 0,
};
my $score_with = $search_ltm->score_entry($entry_with_search, 'discovery');
my $score_without = $search_ltm->score_entry($entry_without_search, 'discovery');
ok_test($score_with > $score_without, "score_entry: search_count boosts score");

# ============================================================
# 9. update_entry
# ============================================================

my $update_ltm = CLIO::Memory::LongTerm->new();
$update_ltm->add_discovery('We deploy to marvin for testing', 0.9);
$update_ltm->add_discovery('Config stored in CLIO::Core::Config', 0.8);
$update_ltm->add_problem_solution(
    'SSH fails to marvin with timeout',
    'Check if marvin is on the VPN first',
    [],
    0.85,
);
$update_ltm->add_code_pattern('Always run tests on marvin before release', 0.9, []);

# Update a discovery (substring match on "deploy to marvin")
my $u1 = $update_ltm->update_entry(search => 'deploy to marvin', replacement => 'We deploy to zaphod for testing');
ok_test($u1->{found} == 1, "update_entry: found matching discovery");
ok_test($u1->{type} eq 'discovery', "update_entry: correct type returned");
ok_test($u1->{new_text} eq 'We deploy to zaphod for testing', "update_entry: replacement applied");
# Verify the old text is gone
my $check = $update_ltm->search_entries('deploy to marvin');
ok_test(scalar(@$check) == 0, "update_entry: old text no longer matches in discoveries");
my $check2 = $update_ltm->search_entries('deploy to zaphod');
ok_test(scalar(@$check2) >= 1, "update_entry: new text is searchable");

# Update a solution (match in error field)
my $u2 = $update_ltm->update_entry(search => 'SSH fails to marvin', replacement => 'SSH fails to zaphod with timeout');
ok_test($u2->{found} == 1, "update_entry: found matching solution");
ok_test($u2->{type} eq 'solution', "update_entry: solution type");

# Update a pattern
my $u3 = $update_ltm->update_entry(search => 'tests on marvin', replacement => 'Always run tests on zaphod before release');
ok_test($u3->{found} == 1, "update_entry: found matching pattern");
ok_test($u3->{type} eq 'pattern', "update_entry: pattern type");

# No match returns found=0
my $u4 = $update_ltm->update_entry(search => 'nonexistent entry', replacement => 'whatever');
ok_test($u4->{found} == 0, "update_entry: no match returns found=0");

# Type filter works
my $update_ltm2 = CLIO::Memory::LongTerm->new();
$update_ltm2->add_discovery('Server is marvin', 0.9);
$update_ltm2->add_code_pattern('Server is marvin for deploys', 0.8, []);
my $u5 = $update_ltm2->update_entry(search => 'marvin', replacement => 'Server is zaphod', type => 'pattern');
ok_test($u5->{found} == 1, "update_entry: type filter finds pattern");
ok_test($u5->{type} eq 'pattern', "update_entry: type filter respected");
# Discovery should still have marvin
my $disc_check = $update_ltm2->search_entries('Server is marvin');
ok_test(scalar(@$disc_check) >= 1, "update_entry: type filter didn't modify other types");

# Updated entry gets timestamp refresh
ok_test(defined $update_ltm->{patterns}{discoveries}[0]{updated}, "update_entry: timestamp set on updated entry");
ok_test(($update_ltm->{patterns}{discoveries}[0]{search_count} || 0) >= 1, "update_entry: search_count incremented");

# ============================================================
# Summary
# ============================================================

done_testing();

my $total_tests = $PASS + $FAIL;
print "\n" . "=" x 60 . "\n";
print "Results: $PASS/$total_tests passed";
print " ($FAIL FAILED)" if $FAIL;
print "\n" . "=" x 60 . "\n";

exit($FAIL > 0 ? 1 : 0);
