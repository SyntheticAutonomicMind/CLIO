#!/usr/bin/env perl
# Test LTM integration end-to-end

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use lib "$RealBin/../lib";

use CLIO::Session::Manager;
use CLIO::Memory::LongTerm;
use CLIO::Core::PromptManager;
use CLIO::Core::WorkflowOrchestrator;
use Data::Dumper;

print "Testing LTM Integration...\n\n";

# 1. Create a test LTM with sample patterns
print "[1] Creating test LTM with sample patterns...\n";
my $ltm = CLIO::Memory::LongTerm->new(
    project_root => $RealBin,
    debug => 1
);

# Store test patterns
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

$ltm->save();
print "   Stored 3 test patterns\n\n";

# 2. Create session with LTM
print "[2] Creating test session with LTM...\n";

# Don't use session manager - it creates a fresh LTM
# Instead, manually create state with our LTM
require CLIO::Session::State;
require CLIO::Memory::ShortTerm;
require CLIO::Memory::YaRN;

my $stm = CLIO::Memory::ShortTerm->new(debug => 0);
my $yarn = CLIO::Memory::YaRN->new(debug => 0);

my $session = CLIO::Session::State->new(
    session_id => 'test-session-123',
    debug => 0,
    working_directory => $RealBin,
    stm => $stm,
    ltm => $ltm,  # Use our test LTM with patterns
    yarn => $yarn,
);

# Add get_long_term_memory method if not present
unless ($session->can('get_long_term_memory')) {
    no strict 'refs';
    *{"CLIO::Session::State::get_long_term_memory"} = sub {
        my $self = shift;
        return $self->{ltm};
    };
}

print "   Session created with LTM\n\n";

# 3. Create WorkflowOrchestrator (without real API manager)
print "[3] Creating WorkflowOrchestrator...\n";

# Mock API manager for testing
my $mock_api = bless {}, 'MockAPIManager';

my $orchestrator = CLIO::Core::WorkflowOrchestrator->new(
    api_manager => $mock_api,
    session => $session,
    debug => 1
);

print "   Orchestrator created\n\n";

# 4. Test get_dynamic_context with session (LTM moved to user message for cache stability)
print "[4] Testing get_dynamic_context with LTM content...\n";

# Debug: verify LTM is accessible
my $test_ltm = $session->get_long_term_memory();
print "   LTM accessible: " . (defined $test_ltm ? "YES" : "NO") . "\n";
if ($test_ltm) {
    my $test_disc = $test_ltm->query_discoveries();
    print "   LTM has " . scalar(@$test_disc) . " discoveries\n";
}

my $system_prompt;
my $dynamic_context;
eval {
    my $pm = CLIO::Core::PromptManager->new(debug => 1);
    $system_prompt = $pm->get_system_prompt($session);
    $dynamic_context = $pm->get_dynamic_context($session);
};
if ($@) {
    print "   [FAIL] PromptManager errored: $@\n";
    $system_prompt = '';
    $dynamic_context = '';
}

# Verify LTM is NOT in the system prompt (moved to dynamic context for cache stability)
if ($system_prompt =~ /Long-Term Memory Patterns/) {
    print "   [FAIL] LTM section found in system prompt (should be in dynamic context only)\n";
} else {
    print "   [OK] LTM section NOT in system prompt (cache-stable)\n";
}

# Verify LTM IS in the dynamic context
if ($dynamic_context && $dynamic_context =~ /Long-Term Memory Patterns/) {
    print "   [OK] LTM section found in dynamic context\n";
} else {
    print "   [FAIL] LTM section NOT found in dynamic context\n";
}

if ($dynamic_context && $dynamic_context =~ /Test discovery: CLIO uses Perl/) {
    print "   [OK] Discovery pattern in dynamic context\n";
} else {
    print "   [FAIL] Discovery pattern NOT found in dynamic context\n";
}

if ($dynamic_context && $dynamic_context =~ /API timeout error/) {
    print "   [OK] Solution pattern in dynamic context\n";
} else {
    print "   [FAIL] Solution pattern NOT found in dynamic context\n";
}

if ($dynamic_context && $dynamic_context =~ /use strict; use warnings/) {
    print "   [OK] Code pattern in dynamic context\n";
} else {
    print "   [FAIL] Code pattern NOT found in dynamic context\n";
}

print "\n[5] System prompt length: " . length($system_prompt) . " characters (stable portion)\n";
print "   Dynamic context length: " . length($dynamic_context // '') . " characters\n";
print "   (LTM patterns now injected into user message for cache stability)\n\n";

# 5. Query LTM patterns directly
print "[6] Querying LTM patterns directly...\n";
my $discoveries = $ltm->query_discoveries(limit => 3);
my $solutions = $ltm->query_solutions(limit => 3);
my $patterns = $ltm->query_patterns(limit => 3);

print "   Discoveries: " . scalar(@$discoveries) . "\n";
print "   Solutions: " . scalar(@$solutions) . "\n";
print "   Patterns: " . scalar(@$patterns) . "\n\n";

# Cleanup
unlink "$RealBin/.clio/ltm.json";

print "Test completed successfully!\n";

# Mock API Manager package
package MockAPIManager;
sub new { bless {}, shift; }
1;
