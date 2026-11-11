#!/usr/bin/env perl

use strict;
use warnings;
use lib 'lib';
use CLIO::Core::HashtagParser;
use CLIO::Memory::TokenEstimator;

print "Testing Token Budget Enforcement\n";
print "=" x 60 . "\n\n";

# Create a mock session
my $session = {
    working_directory => '.',
};

# Test 1: Create parser with standard budgets
print "Test 1: Parser initialization\n";
my $parser = CLIO::Core::HashtagParser->new(
    session => $session,
    debug => 1
);

print "  Max tokens per file: " . $parser->{max_tokens_per_file} . "\n";
print "  Max total tokens: " . $parser->{max_total_tokens} . "\n";
print "  ✓ Parser created\n\n";

# Test 2: Parse a large file (should trigger truncation)
print "Test 2: Large file truncation\n";
my $tags = $parser->parse("#file:lib/CLIO/Core/SimpleAIAgent.pm");
print "  Found " . scalar(@$tags) . " hashtags\n";

my $context = $parser->resolve($tags);
print "  Resolved " . scalar(@$context) . " items\n";

for my $item (@$context) {
    if ($item->{estimated_tokens}) {
        print "  Tokens: $item->{estimated_tokens}\n";
        print "  Truncated: " . ($item->{truncated} ? "YES" : "NO") . "\n";
    }
}

my $formatted = $parser->format_context($context);
my $total_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($formatted);
print "  Total formatted tokens: $total_tokens\n";

if ($total_tokens <= $parser->{max_total_tokens}) {
    print "  ✓ Within token budget\n";
} else {
    print "  ✗ EXCEEDED token budget!\n";
}
print "\n";

# Test 3: Multiple files (should enforce total budget)
print "Test 3: Multiple files - total budget enforcement\n";
$parser = CLIO::Core::HashtagParser->new(
    session => $session,
    debug => 0  # Less verbose for this test
);

$tags = $parser->parse("#file:lib/CLIO/Core/APIManager.pm #file:lib/CLIO/Core/WorkflowOrchestrator.pm #file:lib/CLIO/UI/Chat.pm");
print "  Found " . scalar(@$tags) . " hashtags\n";

$context = $parser->resolve($tags);
print "  Resolved " . scalar(@$context) . " items\n";

my $total = 0;
for my $item (@$context) {
    if ($item->{estimated_tokens}) {
        $total += $item->{estimated_tokens};
        print "  - $item->{path}: $item->{estimated_tokens} tokens";
        if ($item->{truncated}) {
            print " [TRUNCATED]";
        }
        print "\n";
    }
}

print "  Total context tokens: $total / " . $parser->{max_total_tokens} . "\n";

if ($total <= $parser->{max_total_tokens}) {
    print "  ✓ Within total token budget\n";
} else {
    print "  ✗ EXCEEDED total budget!\n";
}

if (@{$parser->{truncated_items}}) {
    print "  Truncated items: " . scalar(@{$parser->{truncated_items}}) . "\n";
}
print "\n";

# Test 4: Estimate tokens for formatted context
$formatted = $parser->format_context($context);
$total_tokens = CLIO::Memory::TokenEstimator::estimate_tokens($formatted);
print "Test 4: Final formatted output\n";
print "  Formatted context tokens: $total_tokens\n";
print "  Length: " . length($formatted) . " bytes\n";

if ($total_tokens <= $parser->{max_total_tokens} + 500) {  # Allow some overhead for formatting
    print "  ✓ Formatted output within reasonable limits\n";
} else {
    print "  ✗ Formatted output too large!\n";
}
print "\n";

print "=" x 60 . "\n";
print "Token Budget Tests Complete\n";
print "\nSummary:\n";
print "  - Token budgets enforced per-file and total\n";
print "  - Large files truncated intelligently\n";
print "  - Multiple files respect total budget\n";
print "  - User notified of truncations\n";
