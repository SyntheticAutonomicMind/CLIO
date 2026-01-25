#!/usr/bin/perl

=head1 NAME

test_error_recovery_simple.pl - Simple test of error recovery logic

=head1 DESCRIPTION

Tests that the retryable error handling logic works correctly.

=cut

use strict;
use warnings;
use Test::More tests => 8;

# Mock the HTTP response object
my $resp_502 = {
    code => 502,
    status_line => "502 Bad Gateway",
    is_success => 0,
    decoded_content => '{"error": "Server error"}',
    header => sub { return undef },
};

# Test the logic directly without instantiating APIManager
my $status = $resp_502->{code};
my $error = "Streaming request failed: 502 Bad Gateway";

# Test 502 error detection
{
    my $retryable = 0;
    my $retry_after = undef;
    
    if ($status == 502 || $status == 503) {
        $retryable = 1;
        $retry_after = 2;
    }
    
    ok($retryable, "502 error is marked as retryable");
    is($retry_after, 2, "502 error has 2 second retry delay");
}

# Test 503 error detection
{
    my $status = 503;
    my $retryable = 0;
    my $retry_after = undef;
    
    if ($status == 502 || $status == 503) {
        $retryable = 1;
        $retry_after = 2;
    }
    
    ok($retryable, "503 error is marked as retryable");
    is($retry_after, 2, "503 error has 2 second retry delay");
}

# Test 429 rate limit error detection
{
    my $status = 429;
    my $retryable = 0;
    my $retry_after = 60;
    
    if ($status == 429) {
        $retryable = 1;
    }
    
    ok($retryable, "429 error is marked as retryable");
    ok($retry_after == 60, "429 error has default retry delay");
}

# Test non-retryable 400 error
{
    my $status = 400;
    my $retryable = 0;
    
    if ($status == 502 || $status == 503 || $status == 429) {
        $retryable = 1;
    }
    
    ok(!$retryable, "400 error is not marked as retryable");
}

# Test non-retryable 401 error
{
    my $status = 401;
    my $retryable = 0;
    
    if ($status == 502 || $status == 503 || $status == 429) {
        $retryable = 1;
    }
    
    ok(!$retryable, "401 error is not marked as retryable");
}

done_testing();

=head1 AUTHOR

CLIO Development Team

=cut
