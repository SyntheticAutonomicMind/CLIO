#!/usr/bin/env perl

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";  # Correct path to lib directory

# Test script for tool calling implementation
# Task 5: Direct testing of WorkflowOrchestrator

print "=" x 80 . "\n";
print "CLIO Tool Calling Test\n";
print "=" x 80 . "\n\n";

# Check environment
unless ($ENV{OPENAI_API_KEY}) {
    die "ERROR: OPENAI_API_KEY not set. Please set it before running this test.\n";
}

print "Configuration:\n";
print "  API Base: " . ($ENV{OPENAI_API_BASE} || 'openai') . "\n";
print "  Model: " . ($ENV{OPENAI_MODEL} || 'qwen3-coder-max') . "\n";
print "  Debug: " . ($ENV{CLIO_LOG_LEVEL} ? 'ON' : 'OFF') . "\n";
print "\n";

# Initialize components
print "Initializing components...\n";

# Register protocol handlers (normally done in clio main script)
require CLIO::Protocols::Manager;
CLIO::Protocols::Manager->register(name => 'FILE_OP', handler => 'CLIO::Protocols::FileOp');
CLIO::Protocols::Manager->register(name => 'GIT', handler => 'CLIO::Protocols::Git');
CLIO::Protocols::Manager->register(name => 'URL_FETCH', handler => 'CLIO::Protocols::UrlFetch');
print "  ✓ Protocol handlers registered\n";

require CLIO::Core::APIManager;
my $api_manager = CLIO::Core::APIManager->new(
    debug => $ENV{CLIO_LOG_LEVEL} ? 1 : 0
);
print "  ✓ APIManager initialized\n";

require CLIO::Core::WorkflowOrchestrator;
my $orchestrator = CLIO::Core::WorkflowOrchestrator->new(
    api_manager => $api_manager,
    session => undef,  # No session for this test
    debug => $ENV{CLIO_LOG_LEVEL} ? 1 : 0
);
print "  ✓ WorkflowOrchestrator initialized\n";
print "\n";

# Test 1: URL Fetch (user requested this)
print "=" x 80 . "\n";
print "Test 1: Fetch today's headlines from Google News\n";
print "=" x 80 . "\n";
print "User request: Can you fetch today's headlines from https://news.google.com?\n\n";

my $result1 = $orchestrator->process_input(
    "Can you fetch today's headlines from https://news.google.com?",
    undef
);

print "Result:\n";
print "  Success: " . ($result1->{success} ? "YES" : "NO") . "\n";
print "  Iterations: " . ($result1->{iterations} || 0) . "\n";
print "  Tool calls: " . ($result1->{tool_calls_made} ? scalar(@{$result1->{tool_calls_made}}) : 0) . "\n";
print "\n";

if ($result1->{success}) {
    print "AI Response:\n";
    print "-" x 80 . "\n";
    print $result1->{content} . "\n";
    print "-" x 80 . "\n";
} else {
    print "ERROR: " . ($result1->{error} || "Unknown error") . "\n";
}

print "\n";

# Show tool calls that were made
if ($result1->{tool_calls_made} && @{$result1->{tool_calls_made}}) {
    print "Tools Used:\n";
    for my $tc (@{$result1->{tool_calls_made}}) {
        print "  - $tc->{name}\n";
        my $args = eval { require JSON::PP; JSON::PP::decode_json($tc->{arguments}) };
        if ($args && ref($args) eq 'HASH') {
            for my $k (keys %$args) {
                my $v = $args->{$k};
                if (length($v) > 60) {
                    $v = substr($v, 0, 60) . "...";
                }
                print "    $k: $v\n";
            }
        }
    }
    print "\n";
}

print "=" x 80 . "\n";
print "Test Complete\n";
print "=" x 80 . "\n";

1;
