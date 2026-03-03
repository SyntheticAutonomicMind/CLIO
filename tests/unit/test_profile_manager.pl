#!/usr/bin/env perl
# Test CLIO::Profile::Manager - profile storage, loading, and injection
#
# Tests the Manager's ability to save, load, clear, and generate
# prompt sections from user profiles.

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);

use CLIO::Profile::Manager;

# Override HOME for testing so we don't touch real profile
my $test_home = tempdir(CLEANUP => 1);
local $ENV{HOME} = $test_home;

# Test 1: Constructor
subtest 'constructor' => sub {
    my $mgr = CLIO::Profile::Manager->new();
    ok(defined $mgr, 'Manager created');
    is($mgr->{debug}, 0, 'Debug defaults to 0');

    my $mgr2 = CLIO::Profile::Manager->new(debug => 1);
    is($mgr2->{debug}, 1, 'Debug can be set');
};

# Test 2: profile_path
subtest 'profile_path' => sub {
    my $mgr = CLIO::Profile::Manager->new();
    my $path = $mgr->profile_path();
    ok(defined $path, 'Path returned');
    like($path, qr/profile\.md$/, 'Path ends with profile.md');
    like($path, qr/\.clio/, 'Path contains .clio directory');
};

# Test 3: profile_exists - no profile
subtest 'profile_exists - no profile' => sub {
    my $mgr = CLIO::Profile::Manager->new();
    is($mgr->profile_exists(), 0, 'No profile exists initially');
};

# Test 4: save_profile
subtest 'save_profile' => sub {
    my $mgr = CLIO::Profile::Manager->new();
    my $content = "## User Profile\n\n**Communication:** Direct and collaborative.\n";

    my $result = $mgr->save_profile($content);
    is($result, 1, 'Save returns success');
    ok(-f $mgr->profile_path(), 'Profile file created');
};

# Test 5: profile_exists - after save
subtest 'profile_exists - after save' => sub {
    my $mgr = CLIO::Profile::Manager->new();
    is($mgr->profile_exists(), 1, 'Profile exists after save');
};

# Test 6: load_profile
subtest 'load_profile' => sub {
    my $mgr = CLIO::Profile::Manager->new();
    my $content = $mgr->load_profile();
    ok(defined $content, 'Content loaded');
    like($content, qr/User Profile/, 'Content contains expected text');
    like($content, qr/Direct and collaborative/, 'Content preserved correctly');
};

# Test 7: load_profile - roundtrip with UTF-8
subtest 'load_profile - UTF-8 roundtrip' => sub {
    my $mgr = CLIO::Profile::Manager->new();
    my $utf8_content = "## Profile\n\n**Style:** Uses emoji sparingly - prefers unicode symbols (\x{2713}, \x{2717}, \x{2192}).\n";

    $mgr->save_profile($utf8_content);
    my $loaded = $mgr->load_profile();
    ok(defined $loaded, 'UTF-8 content loaded');
    like($loaded, qr/\x{2713}/, 'Unicode checkmark preserved');
    like($loaded, qr/\x{2192}/, 'Unicode arrow preserved');
};

# Test 8: generate_prompt_section
subtest 'generate_prompt_section' => sub {
    my $mgr = CLIO::Profile::Manager->new();
    $mgr->save_profile("## User Profile\n\n**Communication:** Direct.\n");

    my $section = $mgr->generate_prompt_section();
    ok(length($section) > 0, 'Section generated');
    like($section, qr/# User Profile/, 'Contains header');
    like($section, qr/following profile describes the human/, 'Contains injection header');
    like($section, qr/Direct/, 'Contains profile content');
};

# Test 9: generate_prompt_section - no profile
subtest 'generate_prompt_section - no profile' => sub {
    my $mgr = CLIO::Profile::Manager->new();

    # Use a fresh temp home with no profile
    my $empty_home = tempdir(CLEANUP => 1);
    local $ENV{HOME} = $empty_home;

    my $section = $mgr->generate_prompt_section();
    is($section, '', 'Empty string when no profile');
};

# Test 10: load_profile - too short
subtest 'load_profile - too short content' => sub {
    my $mgr = CLIO::Profile::Manager->new();
    $mgr->save_profile("short");

    my $loaded = $mgr->load_profile();
    is($loaded, undef, 'Returns undef for profile shorter than 10 chars');
};

# Test 11: clear_profile
subtest 'clear_profile' => sub {
    my $mgr = CLIO::Profile::Manager->new();

    # Save something first
    $mgr->save_profile("## User Profile\n\nSome content here for testing.\n");
    is($mgr->profile_exists(), 1, 'Profile exists before clear');

    my $result = $mgr->clear_profile();
    is($result, 1, 'Clear returns success');
    is($mgr->profile_exists(), 0, 'Profile gone after clear');
};

# Test 12: clear_profile - no profile
subtest 'clear_profile - already empty' => sub {
    my $mgr = CLIO::Profile::Manager->new();

    my $empty_home = tempdir(CLEANUP => 1);
    local $ENV{HOME} = $empty_home;

    my $result = $mgr->clear_profile();
    is($result, 1, 'Clear succeeds when no profile exists');
};

# Test 13: save creates directory
subtest 'save creates .clio directory' => sub {
    my $fresh_home = tempdir(CLEANUP => 1);
    local $ENV{HOME} = $fresh_home;

    my $clio_dir = File::Spec->catdir($fresh_home, '.clio');
    ok(!-d $clio_dir, '.clio does not exist yet');

    my $mgr = CLIO::Profile::Manager->new();
    $mgr->save_profile("## Profile\n\nTest content for directory creation.\n");

    ok(-d $clio_dir, '.clio directory created');
    ok(-f $mgr->profile_path(), 'Profile file created');
};

done_testing();
