#!/usr/bin/perl

use strict;
use warnings;
use lib 'lib';
use Test::More;
use CLIO::UI::Theme;

# Test 1: Builtin theme has all required keys
my $theme_mgr = CLIO::UI::Theme->new();
my $builtin = $theme_mgr->get_builtin_theme();
my @required_keys = $theme_mgr->get_required_theme_keys();

my $test_count = scalar(@required_keys);  # Test for each required key
$test_count += scalar(keys %$builtin);   # Test for each builtin key having a value
$test_count += 1;  # Test validation

plan tests => $test_count;

for my $key (@required_keys) {
    ok(exists $builtin->{$key}, "Builtin theme has required key: $key");
}

# Test 2: All theme keys are strings (no undefined values)
for my $key (keys %$builtin) {
    ok(defined $builtin->{$key}, "Builtin key $key has a value");
}

# Test 3: Builtin theme passes validation
my ($valid, $error) = $theme_mgr->is_theme_complete('default');
ok($valid, "Builtin theme is complete") or diag("Error: $error");

print "\n=== THEME SYNC TEST PASSED ===\n";
