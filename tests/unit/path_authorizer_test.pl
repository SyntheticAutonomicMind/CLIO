#!/usr/bin/env perl

use strict;
use warnings;
use feature 'say';
use FindBin;
use lib "$FindBin::Bin/lib";

use CLIO::Security::PathAuthorizer;
use File::Temp qw(tempdir);
use Cwd;

# Test PathAuthorizer
say "=== Testing CLIO::Security::PathAuthorizer ===\n";

my $authorizer = CLIO::Security::PathAuthorizer->new(debug => 1);

my $tests_passed = 0;
my $tests_total = 0;

# Create temp working directory for testing
my $working_dir = tempdir(CLEANUP => 1);
say "Working directory: $working_dir\n";

# Test 1: Path resolution
$tests_total++;
say "Test 1: Path resolution";
my $resolved = $authorizer->resolvePath("test.txt", $working_dir);
if ($resolved =~ /^\/.*test\.txt$/) {
    say "✅ PASS: Relative path resolved to absolute";
    say "   Input: test.txt";
    say "   Output: $resolved";
    $tests_passed++;
} else {
    say "❌ FAIL: Path resolution failed";
    say "   Output: $resolved";
}
say "";

# Test 2: User-initiated operation (always allowed)
$tests_total++;
say "Test 2: User-initiated operation";
my $result = $authorizer->checkPathAuthorization(
    path => '/outside/path/file.txt',
    working_directory => $working_dir,
    conversation_id => 'test_conv',
    operation => 'file_operations.create_file',
    is_user_initiated => 1,
);
if ($result->{status} eq 'allowed' && $result->{reason} =~ /user.initiated/i) {
    say "✅ PASS: User-initiated operation allowed";
    say "   Status: $result->{status}";
    say "   Reason: $result->{reason}";
    $tests_passed++;
} else {
    say "❌ FAIL: User-initiated operation not allowed";
    say "   Status: $result->{status}";
}
say "";

# Test 3: Inside working directory (auto-approved)
$tests_total++;
say "Test 3: Path inside working directory";
$result = $authorizer->checkPathAuthorization(
    path => "$working_dir/test.txt",
    working_directory => $working_dir,
    conversation_id => 'test_conv',
    operation => 'file_operations.create_file',
    is_user_initiated => 0,
);
if ($result->{status} eq 'allowed' && $result->{reason} =~ /inside working directory/i) {
    say "✅ PASS: Inside working directory auto-approved";
    say "   Status: $result->{status}";
    say "   Reason: $result->{reason}";
    $tests_passed++;
} else {
    say "❌ FAIL: Inside working directory not auto-approved";
    say "   Status: $result->{status}";
    say "   Reason: $result->{reason}";
}
say "";

# Test 4: Outside working directory (requires authorization)
$tests_total++;
say "Test 4: Path outside working directory";
$result = $authorizer->checkPathAuthorization(
    path => '/tmp/outside.txt',
    working_directory => $working_dir,
    conversation_id => 'test_conv',
    operation => 'file_operations.create_file',
    is_user_initiated => 0,
);
if ($result->{status} eq 'requires_authorization' && $result->{reason} =~ /outside working directory/i) {
    say "✅ PASS: Outside working directory requires authorization";
    say "   Status: $result->{status}";
    say "   Reason: $result->{reason}";
    $tests_passed++;
} else {
    say "❌ FAIL: Outside working directory check failed";
    say "   Status: $result->{status}";
    say "   Reason: $result->{reason}";
}
say "";

# Test 5: Grant authorization
$tests_total++;
say "Test 5: Grant and use authorization";
$authorizer->grantAuthorization('test_conv', 'file_operations.create_file', 1);
if ($authorizer->isAuthorized('test_conv', 'file_operations.create_file')) {
    say "✅ PASS: Authorization granted and verified";
    $tests_passed++;
} else {
    say "❌ FAIL: Authorization grant failed";
}
say "";

# Test 6: One-time use consumed
$tests_total++;
say "Test 6: One-time authorization consumed";
if (!$authorizer->isAuthorized('test_conv', 'file_operations.create_file')) {
    say "✅ PASS: One-time authorization consumed after first use";
    $tests_passed++;
} else {
    say "❌ FAIL: One-time authorization not consumed";
}
say "";

# Test 7: Multi-use authorization
$tests_total++;
say "Test 7: Multi-use authorization";
$authorizer->grantAuthorization('test_conv', 'file_operations.write_file', 0);  # one_time_use = false
my $first_use = $authorizer->isAuthorized('test_conv', 'file_operations.write_file');
my $second_use = $authorizer->isAuthorized('test_conv', 'file_operations.write_file');
if ($first_use && $second_use) {
    say "✅ PASS: Multi-use authorization works multiple times";
    $tests_passed++;
} else {
    say "❌ FAIL: Multi-use authorization consumed";
    say "   First use: $first_use, Second use: $second_use";
}
say "";

# Test 8: Auto-approve
$tests_total++;
say "Test 8: Auto-approve conversation";
$authorizer->setAutoApprove(1, 'auto_conv');
$result = $authorizer->checkPathAuthorization(
    path => '/anywhere/file.txt',
    working_directory => $working_dir,
    conversation_id => 'auto_conv',
    operation => 'file_operations.delete_file',
    is_user_initiated => 0,
);
if ($result->{status} eq 'allowed' && $result->{reason} =~ /auto.approve/i) {
    say "✅ PASS: Auto-approve bypasses authorization";
    say "   Status: $result->{status}";
    say "   Reason: $result->{reason}";
    $tests_passed++;
} else {
    say "❌ FAIL: Auto-approve not working";
    say "   Status: $result->{status}";
}
say "";

# Test 9: Revoke authorization
$tests_total++;
say "Test 9: Revoke authorization";
$authorizer->grantAuthorization('test_conv', 'file_operations.delete_file', 0);
$authorizer->revokeAuthorization('test_conv', 'file_operations.delete_file');
if (!$authorizer->isAuthorized('test_conv', 'file_operations.delete_file')) {
    say "✅ PASS: Authorization revoked successfully";
    $tests_passed++;
} else {
    say "❌ FAIL: Authorization not revoked";
}
say "";

# Test 10: Revoke all for conversation
$tests_total++;
say "Test 10: Revoke all authorizations for conversation";
$authorizer->grantAuthorization('test_conv', 'op1', 0);
$authorizer->grantAuthorization('test_conv', 'op2', 0);
$authorizer->revokeAllForConversation('test_conv');
my $op1_auth = $authorizer->isAuthorized('test_conv', 'op1');
my $op2_auth = $authorizer->isAuthorized('test_conv', 'op2');
if (!$op1_auth && !$op2_auth) {
    say "✅ PASS: All authorizations revoked";
    $tests_passed++;
} else {
    say "❌ FAIL: Some authorizations remain";
    say "   op1: $op1_auth, op2: $op2_auth";
}
say "";

# Summary
say "=" x 60;
say "SUMMARY: $tests_passed/$tests_total tests passed";
if ($tests_passed == $tests_total) {
    say "✅ ALL TESTS PASSED";
    exit 0;
} else {
    say "❌ SOME TESTS FAILED";
    exit 1;
}
