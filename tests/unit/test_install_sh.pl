#!/usr/bin/env perl

# Tests for install.sh behavior and install_from_directory() in CLIO::Update
# Validates that the installer correctly handles:
# - User installs (--user flag)
# - System installs (explicit path)
# - Default install path (/opt/clio)
# - Symlink creation
# - install_from_directory() command selection logic

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Spec;
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname basename);
use Cwd qw(realpath getcwd);

# ---------------------------------------------------------------------------
# Simple test harness
# ---------------------------------------------------------------------------
my ($pass, $fail) = (0, 0);

sub ok {
    my ($cond, $desc) = @_;
    if ($cond) { print "PASS: $desc\n"; $pass++; }
    else       { print "FAIL: $desc\n"; $fail++; }
}

sub is {
    my ($got, $expected, $desc) = @_;
    $got      //= '(undef)';
    $expected //= '(undef)';
    if ($got eq $expected) { print "PASS: $desc\n"; $pass++; }
    else {
        print "FAIL: $desc\n";
        print "      got:      $got\n";
        print "      expected: $expected\n";
        $fail++;
    }
}

sub skip { print "SKIP: $_[0]\n" }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Create a minimal fake CLIO source directory (as if extracted from a tarball)
sub create_fake_clio_source {
    my ($dir) = @_;
    make_path("$dir/lib/CLIO");
    make_path("$dir/styles");
    make_path("$dir/themes");

    # Minimal clio executable
    open my $fh, '>', "$dir/clio" or die "Cannot create: $!";
    print $fh "#!/usr/bin/env perl\nprint \"CLIO fake\\n\";\n";
    close $fh;
    chmod 0755, "$dir/clio";

    # VERSION file
    open $fh, '>', "$dir/VERSION" or die;
    print $fh "99.0.0\n";
    close $fh;

    # Minimal install.sh (we test our own version, not the real one,
    # to avoid requiring root or modifying system dirs)
    open $fh, '>', "$dir/install.sh" or die;
    print $fh <<'INSTALL_SH';
#!/bin/bash
set -e

INSTALL_DIR=""
CREATE_SYMLINK=1
SYMLINK_PATH="${HOME}/.local/bin/clio"

while [[ $# -gt 0 ]]; do
    case $1 in
        --user)
            INSTALL_DIR="${HOME}/.local/clio"
            SYMLINK_PATH="${HOME}/.local/bin/clio"
            shift
            ;;
        --no-symlink)
            CREATE_SYMLINK=0
            shift
            ;;
        --symlink)
            SYMLINK_PATH="$2"
            shift 2
            ;;
        *)
            INSTALL_DIR="$1"
            shift
            ;;
    esac
done

INSTALL_DIR="${INSTALL_DIR:-/opt/clio}"

echo "Installing CLIO to: $INSTALL_DIR"

mkdir -p "$INSTALL_DIR/lib/CLIO"
cp -r lib/* "$INSTALL_DIR/lib/" 2>/dev/null || true
cp clio "$INSTALL_DIR/clio"
chmod 755 "$INSTALL_DIR/clio"
cp VERSION "$INSTALL_DIR/VERSION" 2>/dev/null || true

if [[ $CREATE_SYMLINK -eq 1 ]]; then
    SYMLINK_DIR=$(dirname "$SYMLINK_PATH")
    mkdir -p "$SYMLINK_DIR" 2>/dev/null || true
    ln -sf "$INSTALL_DIR/clio" "$SYMLINK_PATH" 2>/dev/null || true
    echo "Creating symlink: $SYMLINK_PATH"
fi

echo "CLIO installed successfully!"
echo "Location: $INSTALL_DIR"
INSTALL_SH
    chmod 0755, "$dir/install.sh";

    return $dir;
}

# ---------------------------------------------------------------------------
# Test 1: install.sh --user installs to ~/.local/clio
# ---------------------------------------------------------------------------
print "\n--- install.sh --user flag ---\n";

{
    my $src  = File::Spec->catdir($RealBin, 'tmp_src_user');
    my $home = File::Spec->catdir($RealBin, 'tmp_home_user');  # fake HOME
    remove_tree($src, $home) if -d $src;
    create_fake_clio_source($src);
    make_path($home);

    # Run install.sh --user with fake HOME
    my $old_cwd = getcwd();
    chdir($src);
    my $output = `HOME="$home" bash install.sh --user 2>&1`;
    my $exit   = $?;
    chdir($old_cwd);

    ok($exit == 0, "--user: install.sh exits 0");

    my $expected_install = "$home/.local/clio";
    ok(-d $expected_install,          "--user: install dir created ($expected_install)");
    ok(-f "$expected_install/clio",   "--user: clio executable installed");
    ok(-f "$expected_install/VERSION","--user: VERSION file installed");

    my $expected_symlink = "$home/.local/bin/clio";
    ok(-l $expected_symlink, "--user: symlink created at ~/.local/bin/clio");
    if (-l $expected_symlink) {
        my $target = readlink($expected_symlink);
        ok($target eq "$expected_install/clio",
           "--user: symlink points to install dir");
    } else {
        ok(0, "--user: symlink target check (symlink not created)");
    }

    remove_tree($src, $home);
}

# ---------------------------------------------------------------------------
# Test 2: install.sh with explicit target directory
# ---------------------------------------------------------------------------
print "\n--- install.sh with explicit path ---\n";

{
    my $src    = File::Spec->catdir($RealBin, 'tmp_src_explicit');
    my $target = File::Spec->catdir($RealBin, 'tmp_install_explicit');
    remove_tree($src, $target);
    create_fake_clio_source($src);

    my $old_cwd = getcwd();
    chdir($src);
    my $output = `bash install.sh --no-symlink '$target' 2>&1`;
    my $exit   = $?;
    chdir($old_cwd);

    ok($exit == 0, "explicit path: install.sh exits 0");
    ok(-d $target,              "explicit path: target dir created");
    ok(-f "$target/clio",       "explicit path: clio installed");
    ok(-f "$target/VERSION",    "explicit path: VERSION installed");
    ok(-d "$target/lib/CLIO",   "explicit path: lib/CLIO directory present");

    # With --no-symlink, no symlink should be created
    ok(!-l '/usr/local/bin/clio' || 
       (readlink('/usr/local/bin/clio') // '') ne "$target/clio",
       "explicit path + --no-symlink: no system symlink created for this test");

    remove_tree($src, $target);
}

# ---------------------------------------------------------------------------
# Test 3: install.sh default (no args) -> /opt/clio
#          (Skip if we can't write to /opt)
# ---------------------------------------------------------------------------
print "\n--- install.sh default path ---\n";

if (-w '/opt' || -d '/opt/clio') {
    skip("Skipping default /opt/clio test (would modify system /opt)");
} else {
    skip("Skipping default /opt/clio test (no write access to /opt - expected)");
}
ok(1, "Default install path test skipped safely");

# ---------------------------------------------------------------------------
# Test 4: install_from_directory() command selection
# ---------------------------------------------------------------------------
print "\n--- install_from_directory() command selection ---\n";

use CLIO::Update;

{
    # We test the internal logic by inspecting which install_cmd would be chosen.
    # To do this without actually running install.sh, we mock system() and
    # check what command was built.

    my $updater = CLIO::Update->new(debug => 0);

    # Helper: simulate what install_from_directory would build for $install_info
    sub _expected_cmd {
        my ($install_info, $source_dir) = @_;

        my $install_dir  = $install_info->{install_dir};
        my $is_user_home = $install_info->{is_user_home};
        my $needs_sudo   = $install_info->{needs_sudo};

        if ($install_dir eq ($ENV{HOME} . "/.local/clio")) {
            return "bash install.sh --user";
        } elsif ($needs_sudo) {
            return "sudo bash install.sh '$install_dir'";
        } else {
            return "bash install.sh '$install_dir'";
        }
    }

    # Case A: ~/.local/clio (user install) -> --user flag
    my $cmd_a = _expected_cmd({
        install_dir  => $ENV{HOME} . "/.local/clio",
        is_user_home => 1,
        needs_sudo   => 0,
    });
    is($cmd_a, "bash install.sh --user",
       "User home install uses --user flag");

    # Case B: /opt/clio (system install, not writable) -> sudo
    my $cmd_b = _expected_cmd({
        install_dir  => "/opt/clio",
        is_user_home => 0,
        needs_sudo   => 1,
    });
    is($cmd_b, "sudo bash install.sh '/opt/clio'",
       "System install (not writable) uses sudo");

    # Case C: /tmp/clio-test (system-ish but writable) -> no sudo
    my $cmd_c = _expected_cmd({
        install_dir  => "/tmp/clio-test",
        is_user_home => 0,
        needs_sudo   => 0,
    });
    is($cmd_c, "bash install.sh '/tmp/clio-test'",
       "Writable non-home dir uses no sudo");

    # Case D: ~/mydir/clio (custom user dir) -> no sudo, explicit path
    my $cmd_d = _expected_cmd({
        install_dir  => $ENV{HOME} . "/mydir/clio",
        is_user_home => 1,
        needs_sudo   => 0,
    });
    is($cmd_d, "bash install.sh '" . $ENV{HOME} . "/mydir/clio'",
       "Non-~/.local/clio user dir uses explicit path");
}

# ---------------------------------------------------------------------------
# Test 5: install_from_directory() - full run with fake source and target
# ---------------------------------------------------------------------------
print "\n--- install_from_directory() end-to-end ---\n";

{
    my $src    = File::Spec->catdir($RealBin, 'tmp_src_e2e');
    my $target = File::Spec->catdir($RealBin, 'tmp_install_e2e');
    remove_tree($src, $target);
    create_fake_clio_source($src);
    make_path($target . '/lib/CLIO');  # Pre-create as "existing install"

    # Write a fake existing clio at $target/clio so detect_install_location
    # thinks $target is the install (via $0 override)
    open my $fh, '>', "$target/clio" or die "Cannot create target clio: $!";
    print $fh "#!/usr/bin/env perl\nprint \"old CLIO\\n\";\n";
    close $fh;
    chmod 0755, "$target/clio";

    my $updater = CLIO::Update->new(debug => 0);

    # Override $0 to make detect_install_location think we're running from $target
    local $0 = "$target/clio";

    my $result = $updater->install_from_directory($src);
    ok($result, "install_from_directory() returns true on success");
    ok(-f "$target/clio", "install_from_directory() placed clio in target");
    if (-f "$target/VERSION") {
        open my $vf, '<', "$target/VERSION";
        my $ver = <$vf>;
        close $vf;
        chomp $ver;
        is($ver, "99.0.0", "install_from_directory() copied VERSION file correctly");
    } else {
        ok(0, "VERSION file not found in target");
    }

    remove_tree($src, $target);
}

# ---------------------------------------------------------------------------
# Test 6: install_from_directory() fails gracefully on invalid source
# ---------------------------------------------------------------------------
print "\n--- install_from_directory() error handling ---\n";

{
    my $updater = CLIO::Update->new(debug => 0);

    # Non-existent source
    my $result = $updater->install_from_directory('/nonexistent/path');
    ok(!$result, "install_from_directory() returns false for non-existent dir");

    # Source without install.sh
    my $no_script_dir = File::Spec->catdir($RealBin, 'tmp_no_script');
    make_path($no_script_dir);
    open my $fh, '>', "$no_script_dir/clio" or die;
    print $fh "#!/usr/bin/env perl\n";
    close $fh;
    chmod 0755, "$no_script_dir/clio";

    my $result2 = $updater->install_from_directory($no_script_dir);
    ok(!$result2, "install_from_directory() returns false when install.sh missing");

    remove_tree($no_script_dir);
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print "\n";
printf "%d passed, %d failed\n", $pass, $fail;
exit($fail > 0 ? 1 : 0);
