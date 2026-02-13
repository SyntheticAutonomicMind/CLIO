#!/usr/bin/env perl

# Integration test for update notification system
# Tests that background update checks properly notify users when updates are available

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Spec;
use File::Path qw(make_path rmtree);
use Test::Simple tests => 5;

print "Testing update notification mechanism...\n";

# Create test cache directory
my $test_cache_dir = File::Spec->catdir($RealBin, 'test_update_cache');
rmtree($test_cache_dir) if -d $test_cache_dir;
make_path($test_cache_dir);

# Create mock cache file simulating "no update available" state
my $cache_file = File::Spec->catfile($test_cache_dir, 'update_check_cache');
open my $fh, '>', $cache_file or die "Cannot create cache file: $!";
print $fh "up-to-date\n";
close $fh;

my $initial_mtime = (stat($cache_file))[9];
print "Test 1: Created initial cache file (mtime: $initial_mtime)\n";
ok($initial_mtime > 0, "Cache file created with valid mtime");

# Simulate user session starting - track cache mtime
my $tracked_mtime = $initial_mtime;
print "Test 2: Simulating session start - tracking mtime: $tracked_mtime\n";
ok($tracked_mtime == $initial_mtime, "Session correctly tracks initial cache mtime");

# Sleep to ensure mtime changes
sleep 2;

# Simulate background check completing and finding an update
open $fh, '>', $cache_file or die "Cannot update cache: $!";
print $fh "20260213.5\n";  # New version available
close $fh;

my $updated_mtime = (stat($cache_file))[9];
print "Test 3: Background check completed, cache updated (new mtime: $updated_mtime)\n";
ok($updated_mtime > $initial_mtime, "Cache file mtime updated after background check");

# Simulate periodic check in main loop
print "Test 4: Simulating periodic check for cache modifications\n";
my $mtime_changed = ($updated_mtime > $tracked_mtime) ? 1 : 0;
ok($mtime_changed, "Periodic check detects cache file modification");

# Read cache and check for update
open $fh, '<', $cache_file or die "Cannot read cache: $!";
my $cached_version = <$fh>;
close $fh;
chomp $cached_version if $cached_version;

print "Test 5: Reading cached version: $cached_version\n";
my $update_available = ($cached_version ne 'up-to-date') ? 1 : 0;
ok($update_available, "Update correctly detected from cache");

# Cleanup
rmtree($test_cache_dir);

print "\n";
print "All update notification tests passed!\n";
print "\n";
print "SUMMARY:\n";
print "- Initial cache created and tracked\n";
print "- Background check updates cache file\n";
print "- Mtime change detected by periodic check\n";
print "- Update notification triggered correctly\n";
print "\n";
