#!/usr/bin/env perl
# Test script for ProgressSpinner robustness improvements

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More tests => 13;
use Time::HiRes qw(time usleep);

use_ok('CLIO::UI::ProgressSpinner');

# Test 1: Basic create
{
    my $spinner = CLIO::UI::ProgressSpinner->new(
        frames => ['.', 'o', 'O'],
        delay => 50000,
    );
    ok($spinner, "Spinner created successfully");
    ok(!$spinner->is_running(), "Spinner not running after creation");
}

# Test 2: Start and stop
{
    my $spinner = CLIO::UI::ProgressSpinner->new(
        frames => ['.', 'o', 'O'],
        delay => 50000,
    );
    $spinner->start();
    ok($spinner->is_running(), "Spinner running after start");
    usleep(100000);  # Let it run for 100ms
    $spinner->stop();
    ok(!$spinner->is_running(), "Spinner not running after stop");
}

# Test 3: Double stop is safe
{
    my $spinner = CLIO::UI::ProgressSpinner->new(
        frames => ['.'],
        delay => 50000,
    );
    $spinner->start();
    usleep(50000);
    $spinner->stop();
    $spinner->stop();  # Should not crash
    ok(!$spinner->is_running(), "Double stop is safe");
}

# Test 4: Stop without start is safe
{
    my $spinner = CLIO::UI::ProgressSpinner->new(
        frames => ['.'],
        delay => 50000,
    );
    $spinner->stop();  # Should not crash
    ok(!$spinner->is_running(), "Stop without start is safe");
}

# Test 5: Default frames are correct (not nested arrayref)
{
    my $spinner = CLIO::UI::ProgressSpinner->new();
    my $frames = $spinner->{frames};
    ok(ref($frames) eq 'ARRAY', "Frames is an arrayref");
    # Each frame should be a string, not an arrayref
    ok(!ref($frames->[0]), "First frame is a string, not a nested ref");
    ok(length($frames->[0]) > 0, "First default frame is non-empty");
}

# Test 6: Stop timing - should complete within 500ms (no hanging)
{
    my $spinner = CLIO::UI::ProgressSpinner->new(
        frames => ['.', 'o'],
        delay => 50000,
    );
    $spinner->start();
    usleep(100000);  # Let it run 100ms
    
    my $start = time();
    $spinner->stop();
    my $elapsed = time() - $start;
    
    ok($elapsed < 0.5, "Stop completed within 500ms (was ${elapsed}s)");
}

# Test 7: is_running detects dead child
{
    my $spinner = CLIO::UI::ProgressSpinner->new(
        frames => ['.'],
        delay => 50000,
    );
    $spinner->start();
    ok($spinner->is_running(), "Spinner reports running after start");
    
    # Kill the child directly to simulate crash
    if ($spinner->{pid}) {
        kill('KILL', $spinner->{pid});
        usleep(50000);  # Let it die
    }
    
    # is_running should detect the dead child
    ok(!$spinner->is_running(), "is_running detects dead child process");
    
    # Cleanup (stop should handle already-dead child gracefully)
    $spinner->stop();
}

print "\n Progress spinner tests complete!\n";
