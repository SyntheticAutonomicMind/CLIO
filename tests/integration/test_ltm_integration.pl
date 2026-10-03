#!/usr/bin/env perl
# Test LTM integration end-to-end: relevance scoring + dynamic UC rendering.

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use lib "$RealBin/../lib";

use CLIO::Memory::LongTerm;
use CLIO::Core::ContextBuilder;
use CLIO::Core::MessageHistory;
use CLIO::Util::JSON qw(encode_json decode_json);

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

use Test::More;

print "Testing LTM Integration (relevance-based injection)...\n\n";

# 1. Create a test LTM with sample patterns
print "[1] Creating test LTM with sample patterns...\n";
my $ltm = CLIO::Memory::LongTerm->new(
    project_root => $RealBin,
    debug => 1
);

$ltm->add_discovery('Test discovery: CLIO uses Perl 5.32+', 0.95, 1);
$ltm->add_problem_solution(
    'API timeout error',
    'Add retry logic with exponential backoff',
    ['Seen in WorkflowOrchestrator.pm']
);
$ltm->add_code_pattern(
    'use strict; use warnings; at module top',
    0.99,
    ['lib/CLIO/Core/*.pm', 'lib/CLIO/Tools/*.pm']
);

# 2. Test get_entries_for_projection returns all types
print "[2] Testing get_entries_for_projection...\n";
my $entries = $ltm->get_entries_for_projection();
ok_test(scalar(@$entries) >= 3, "get_entries_for_projection returns all entries (${\(scalar @$entries)})");

my @types = map { $_->{type} } @$entries;
ok_test(grep(/discovery/, @types), "discovery entries included");
ok_test(grep(/solution/, @types), "solution entries included");
ok_test(grep(/pattern/, @types), "pattern entries included");

# 3. Test score_ltm tier penalty is ranking-only (not gate-level)
print "[3] Testing score_ltm relevance scoring with tier penalty...\n";
my $input = 'CLIO uses Perl';
my $task = '';
my $unresolved = [];

# Score with the entry still unverified. The 0.3x tier penalty is a
# RANKING penalty only: an unverified entry with a strong lexical match
# (raw_score >= 5) is still injected, but ranks below trusted entries
# at equal lexical relevance. Previously the penalty was applied at the
# keep/drop gate, which killed ALL fresh memories (add_discovery creates
# 'unverified' by default) — LTM was dead until corroboration.
my $scored = CLIO::Core::ContextBuilder::score_ltm($entries, $input, $task, $unresolved);

my $unverified_score;
my $unverified_in_results = 0;
for my $s (@$scored) {
    if ($s->{content} =~ /CLIO uses Perl/) {
        $unverified_in_results = 1;
        $unverified_score = $s->{score};
        ok_test($s->{tier} eq 'unverified', "entry has tier=unverified before corroboration");
        ok_test(defined $s->{raw_score}, "unverified entry has raw_score field");
        # The penalized score (0.3x) should be lower than the raw score.
        ok_test($s->{score} < $s->{raw_score}, "unverified entry's penalized score < raw_score (ranking penalty applied)");
    }
}
ok_test($unverified_in_results, "unverified-but-relevant entry IS injected (ranking-only, not gate-level)");
ok_test($unverified_score >= 0, "injected unverified entry has a non-negative score");

# 4. Corroborate -> promote to trusted, then re-score
print "\n[4] Testing tier propagation through score_ltm...\n";
$ltm->add_corroboration('CLIO uses Perl', 'agent_a', 'session_a');
$ltm->add_corroboration('CLIO uses Perl', 'agent_b', 'session_b');

my $entries2 = $ltm->get_entries_for_projection();
my $scored2 = CLIO::Core::ContextBuilder::score_ltm($entries2, 'CLIO uses Perl', '', []);

my $found_trusted = 0;
my $trusted_score = undef;
for my $s (@$scored2) {
    if ($s->{content} =~ /CLIO uses Perl/) {
        $found_trusted = 1;
        $trusted_score = $s->{score};
        ok_test($s->{tier} eq 'trusted', "entry promoted to trusted after 2 corroborations");
        ok_test($s->{corroboration_count} == 2, "entry has corroboration_count=2");
        ok_test(defined $trusted_score, "trusted entry has a score");
    }
}
ok_test($found_trusted, "trusted entry found in scored results");

# The trusted entry should rank HIGHER than the unverified entry —
# demonstrating the ranking penalty (trusted sorts above unverified
# at equal lexical relevance). Both pass the threshold (raw_score gate),
# but the trusted entry's score (no penalty) exceeds the unverified's
# penalized score (0.3x).
ok_test($trusted_score > $unverified_score, "trusted entry ranks above unverified entry (ranking penalty)");

# 5. Test messages_to_prose_dynamic renders relevant_memory with badges
print "\n[5] Testing messages_to_prose_dynamic rendering...\n";
my $scored3 = CLIO::Core::ContextBuilder::score_ltm($entries2, 'CLIO uses Perl', '', []);
my $rendered = CLIO::Core::MessageHistory::messages_to_prose_dynamic(
    { relevant_memory => $scored3 }
);

ok_test(length($rendered) > 0, "dynamic UC rendering produced output");
ok_test($rendered =~ /\[TRUSTED\]/, "dynamic UC contains [TRUSTED] badge for promoted entry");
ok_test($rendered =~ /CLIO uses Perl/, "dynamic UC contains the discovery content");

# 6. Test non-relevant entries are NOT injected
print "\n[6] Testing relevance filtering...\n";
my $entries3 = $ltm->get_entries_for_projection();
my $scored4 = CLIO::Core::ContextBuilder::score_ltm($entries3, 'unrelated query about quantum flux', '', []);
ok_test(scalar(@$scored4) == 0, "irrelevant query returns 0 relevant memories");

# 7. Test skip_ltm suppresses rendering (simulated)
print "\n[7] Testing skip_ltm suppression...\n";
# When skip_ltm is set, WorkflowOrchestrator passes [] as ltm entries,
# so score_ltm returns []. messages_to_prose_dynamic with empty
# relevant_memory should produce no memory section.
my $empty_render = CLIO::Core::MessageHistory::messages_to_prose_dynamic(
    { relevant_memory => [] }
);
ok_test($empty_render !~ /relevant context/, "no memory section when relevant_memory is empty");

# 8. Test narrative sanitization in rendered memory
print "\n[8] Testing narrative sanitization in memory rendering...\n";
$ltm->add_discovery('memory_operations(store) is the way to save facts', 0.8);
my $entries4 = $ltm->get_entries_for_projection();
my $scored5 = CLIO::Core::ContextBuilder::score_ltm($entries4, 'save facts', '', []);
my $rendered2 = CLIO::Core::MessageHistory::messages_to_prose_dynamic(
    { relevant_memory => $scored5 }
);
ok_test($rendered2 !~ /memory_operations/, "tool name sanitized out of rendered memory");
ok_test($rendered2 =~ /long-term memory/, "tool name replaced with neutral term");

# Cleanup
# The LTM is constructed in-memory (LongTerm->new with project_root),
# never saved to disk, so there is nothing to unlink. The previous
# implementation called PathResolver::get_project_ltm_file() which
# resolves from the process CWD and deleted the developer's real
# project ltm.json. See agent-memory-atlas report section 9 "Data-loss
# risk is the deletion model" and the test cleanup bug flagged there.

print "\n" . "=" x 60 . "\n";
print "Results: $PASS/$PASS+$FAIL passed";
print " ($FAIL FAILED)" if $FAIL;
print "\n" . "=" x 60 . "\n";

done_testing();

exit($FAIL > 0 ? 1 : 0);
