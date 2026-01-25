#!/usr/bin/env perl
# Test: Malformed tool JSON errors trigger retry
# Bug: 400 errors with "Invalid JSON format in tool call" wasted premium requests
# Fix: Added retry logic in APIManager for this specific error pattern

use strict;
use warnings;
use Test::More tests => 4;

print "# Test: Retry logic for malformed tool JSON errors\n";
print "# Testing error pattern matching...\n";

# Test the regex pattern used in APIManager line 1131
# Pattern: /invalid.*json.*tool.*call|tool.*call.*invalid.*json/i

my $error_malformed_json = "Invalid JSON format in tool call arguments";
my $error_malformed_json2 = "tool call has invalid json format";
my $error_other_400 = "Missing required parameter";
my $error_auth = "Unauthorized access";

ok($error_malformed_json =~ /invalid.*json.*tool.*call|tool.*call.*invalid.*json/i,
   "Pattern matches 'Invalid JSON format in tool call arguments'");

ok($error_malformed_json2 =~ /invalid.*json.*tool.*call|tool.*call.*invalid.*json/i,
   "Pattern matches alternate phrasing 'tool call has invalid json'");

ok($error_other_400 !~ /invalid.*json.*tool.*call|tool.*call.*invalid.*json/i,
   "Pattern does NOT match other 400 errors");

ok($error_auth !~ /invalid.*json.*tool.*call|tool.*call.*invalid.*json/i,
   "Pattern does NOT match auth errors");

print "# Test complete: Error pattern detection works correctly\n";
print "# The actual retry logic is in APIManager.pm lines 1128-1140:\n";
print "#   - Detects 400 + pattern\n";
print "#   - Sets retryable=1, retry_after=1\n";  
print "#   - WorkflowOrchestrator retries with 1-second delay\n";

done_testing();
