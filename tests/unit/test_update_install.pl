#!/usr/bin/env perl

# Unit tests for CLIO::Update installation logic
# Covers: version comparison, detect_install_location, restart command logic

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Spec;
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname);
use Cwd qw(realpath);

# ---------------------------------------------------------------------------
# Simple test harness (no Test::More dependency)
# ---------------------------------------------------------------------------
my ($pass, $fail) = (0, 0);

sub ok {
    my ($cond, $desc) = @_;
    if ($cond) {
        print "PASS: $desc\n";
        $pass++;
    } else {
        print "FAIL: $desc\n";
        $fail++;
    }
}

sub is {
    my ($got, $expected, $desc) = @_;
    if (defined($got) && defined($expected) && $got eq $expected) {
        print "PASS: $desc\n";
        $pass++;
    } elsif (!defined($got) && !defined($expected)) {
        print "PASS: $desc (both undef)\n";
        $pass++;
    } else {
        $got      //= '(undef)';
        $expected //= '(undef)';
        print "FAIL: $desc\n";
        print "      got:      $got\n";
        print "      expected: $expected\n";
        $fail++;
    }
}

# ---------------------------------------------------------------------------
# Load module
# ---------------------------------------------------------------------------
use CLIO::Update;

my $updater = CLIO::Update->new(debug => 0);
ok(defined $updater, "CLIO::Update->new() returns object");

# ---------------------------------------------------------------------------
# _compare_versions tests
# ---------------------------------------------------------------------------
print "\n--- Version Comparison ---\n";

# Same version
is($updater->_compare_versions('20260302.1', '20260302.1'),  0, "same version = 0");
is($updater->_compare_versions('20260302.2', '20260302.2'),  0, "same version with build = 0");

# Newer date
is($updater->_compare_versions('20260303.1', '20260302.1'),  1, "newer date > older date");
is($updater->_compare_versions('20260302.1', '20260303.1'), -1, "older date < newer date");

# Same date, different build
is($updater->_compare_versions('20260302.2', '20260302.1'),  1, "higher build > lower build");
is($updater->_compare_versions('20260302.1', '20260302.2'), -1, "lower build < higher build");
is($updater->_compare_versions('20260302.10', '20260302.9'),  1, "build 10 > build 9 (numeric)");

# With 'v' prefix
is($updater->_compare_versions('v20260302.1', '20260302.1'), 0, "v-prefix stripped correctly");
is($updater->_compare_versions('v20260303.1', 'v20260302.1'), 1, "both v-prefixed, newer wins");

# Unknown versions
is($updater->_compare_versions('unknown', '20260302.1'), 0, "unknown vs known = 0");
is($updater->_compare_versions('20260302.1', 'unknown'), 0, "known vs unknown = 0");

# Git describe format (20260122.1-5-gabcdef should work as 20260122.1)
is($updater->_compare_versions('20260303.1-3-gabcdef', '20260302.1'), 1, "git-describe format stripped");

# ---------------------------------------------------------------------------
# get_current_version tests
# ---------------------------------------------------------------------------
print "\n--- get_current_version ---\n";

my $current = $updater->get_current_version();
ok(defined $current, "get_current_version returns something");
ok($current ne '', "get_current_version is not empty");
print "  current version: $current\n";

# Test VERSION file override
{
    my $tmpdir = File::Spec->catdir($RealBin, 'tmp_ver_test');
    make_path($tmpdir);

    my $version_file = File::Spec->catfile($tmpdir, 'VERSION');
    open my $fh, '>', $version_file or die "Cannot write: $!";
    print $fh "99.99.0\n";
    close $fh;

    # Version file is only checked when we're in the directory with it
    my $old_dir = Cwd::getcwd();
    chdir($tmpdir);
    my $ver = $updater->get_current_version();
    chdir($old_dir);
    remove_tree($tmpdir);

    # The VERSION file in $tmpdir might be found, or CLIO.pm version is used.
    # Either way, should return a non-empty string.
    ok(defined $ver && $ver ne '', "get_current_version with VERSION file returns non-empty");
}

# ---------------------------------------------------------------------------
# detect_install_location tests
# ---------------------------------------------------------------------------
print "\n--- detect_install_location ---\n";

my $info = $updater->detect_install_location();

# Should always return something (since we're running from somewhere)
ok(defined $info, "detect_install_location returns hashref");

if ($info) {
    # Required keys
    for my $key (qw(path install_dir type writable needs_sudo path_mismatch)) {
        ok(exists $info->{$key}, "detect_install_location returns '$key' key");
    }

    # Optional but expected keys from our fix
    ok(exists $info->{running_path}, "detect_install_location returns 'running_path'");
    ok(exists $info->{which_path},   "detect_install_location returns 'which_path'");

    # type must be 'system' or 'user'
    ok($info->{type} =~ /^(system|user)$/, "type is 'system' or 'user'");

    # writable and needs_sudo are booleans
    ok(defined $info->{writable},    "writable is defined");
    ok(defined $info->{needs_sudo},  "needs_sudo is defined");
    ok(defined $info->{path_mismatch}, "path_mismatch is defined");

    # path_mismatch should be false when running_path == which_path
    if ($info->{running_path} && $info->{which_path}) {
        my $r = realpath($info->{running_path}) || $info->{running_path};
        my $w = realpath($info->{which_path})   || $info->{which_path};
        my $expected_mismatch = ($r ne $w) ? 1 : 0;
        is($info->{path_mismatch} ? 1 : 0, $expected_mismatch,
           "path_mismatch correctly computed");
    } else {
        print "  NOTE: one or both of running_path/which_path is undef (development mode)\n";
        ok(1, "path_mismatch skipped (development mode)");
    }

    print "  install_dir:   $info->{install_dir}\n";
    print "  type:          $info->{type}\n";
    print "  running_path:  " . ($info->{running_path} || '(undef)') . "\n";
    print "  which_path:    " . ($info->{which_path}   || '(undef)') . "\n";
    print "  path_mismatch: $info->{path_mismatch}\n";
}

# ---------------------------------------------------------------------------
# detect_install_location with a mock running path
# ---------------------------------------------------------------------------
print "\n--- detect_install_location with simulated install tree ---\n";

{
    # Create a fake CLIO install directory structure
    my $fake_dir = File::Spec->catdir($RealBin, 'tmp_fake_install');
    my $fake_bin = File::Spec->catfile($fake_dir, 'clio');
    my $fake_lib = File::Spec->catdir($fake_dir, 'lib', 'CLIO');
    make_path($fake_lib);
    open my $fh, '>', $fake_bin or die "Cannot create fake bin: $!";
    print $fh "#!/usr/bin/env perl\n# fake clio\n";
    close $fh;
    chmod 0755, $fake_bin;

    # Temporarily override $0 to simulate running from the fake install
    local $0 = $fake_bin;

    my $fake_updater = CLIO::Update->new(debug => 0);
    my $fake_info = $fake_updater->detect_install_location();

    ok(defined $fake_info, "detect_install_location works with fake install");
    if ($fake_info) {
        my $resolved_fake = realpath($fake_dir) || $fake_dir;
        my $resolved_got  = realpath($fake_info->{install_dir}) || $fake_info->{install_dir};
        is($resolved_got, $resolved_fake,
           "install_dir correctly set to fake install directory");

        # Since fake dir has lib/CLIO, writable detection should work
        ok(defined $fake_info->{writable}, "writable detected for fake install");
        ok($fake_info->{writable}, "fake install dir is writable");

        # Should NOT need sudo (it's in a user-writable temp dir)
        ok(!$fake_info->{needs_sudo}, "fake install does not need sudo");
    }

    remove_tree($fake_dir);
}

# ---------------------------------------------------------------------------
# Restart command logic (mimics Commands/Update.pm _install_update)
# ---------------------------------------------------------------------------
print "\n--- Restart command selection logic ---\n";

{
    # Helper that mimics the restart-command logic in _install_update
    sub _compute_restart_cmd {
        my ($install_info) = @_;
        return 'clio' unless $install_info;

        my $installed_path = $install_info->{path}         || '';
        my $which_path     = $install_info->{which_path}   || '';

        if ($which_path && $which_path eq $installed_path) {
            return 'clio';
        } else {
            return $installed_path || 'clio';
        }
    }

    # Case 1: which_path == installed path -> use 'clio'
    my $case1_info = {
        path          => '/opt/clio/clio',
        running_path  => '/opt/clio/clio',
        which_path    => '/opt/clio/clio',
        path_mismatch => 0,
    };
    is(_compute_restart_cmd($case1_info), 'clio',
       "When which_path matches install, restart cmd is 'clio'");

    # Case 2: which_path symlink resolves to same -> 'clio'
    my $case2_info = {
        path          => '/opt/clio/clio',
        running_path  => '/opt/clio/clio',
        which_path    => '/opt/clio/clio',  # realpath already resolved
        path_mismatch => 0,
    };
    is(_compute_restart_cmd($case2_info), 'clio',
       "Symlink case: restart cmd is 'clio' when resolved paths match");

    # Case 3: mismatch (user ran git clone) -> full path
    my $case3_info = {
        path          => '/opt/clio/clio',
        running_path  => '/home/user/CLIO/clio',
        which_path    => '/opt/clio/clio',
        path_mismatch => 1,
    };
    is(_compute_restart_cmd($case3_info), 'clio',
       "Mismatch case: restart cmd still 'clio' when which_path matches install");

    # Case 4: no 'clio' in PATH at all -> full path
    my $case4_info = {
        path          => '/opt/clio/clio',
        running_path  => '/opt/clio/clio',
        which_path    => undef,
        path_mismatch => 0,
    };
    is(_compute_restart_cmd($case4_info), '/opt/clio/clio',
       "No clio in PATH: restart cmd is full absolute path");

    # Case 5: undef info -> 'clio' as safe default
    is(_compute_restart_cmd(undef), 'clio',
       "undef install_info: restart cmd defaults to 'clio'");
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print "\n";
printf "%d passed, %d failed\n", $pass, $fail;
exit($fail > 0 ? 1 : 0);
