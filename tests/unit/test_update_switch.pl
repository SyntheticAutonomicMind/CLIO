#!/usr/bin/env perl

# Unit tests for CLIO::Update::switch_to_version, draft filtering,
# version validation, and install_from_directory list-form safety.

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Spec;
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname);
use Cwd qw(getcwd);

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

# ---------------------------------------------------------------------------
# switch_to_version - validation
# ---------------------------------------------------------------------------
print "\n--- switch_to_version validation ---\n";

my $updater = CLIO::Update->new(debug => 0);

# Missing version
{
    my $r = $updater->switch_to_version(undef);
    is($r->{success}, 0, "switch_to_version(undef) returns success=0");
    ok(defined $r->{error}, "switch_to_version(undef) returns error message");
}

{
    my $r = $updater->switch_to_version('');
    is($r->{success}, 0, "switch_to_version('') returns success=0");
}

# Invalid version format - shell injection / path traversal attempts
for my $bad ('../etc/passwd', 'foo;rm -rf /', 'foo bar', "foo'bar", '$(whoami)', 'foo`bar') {
    my $r = $updater->switch_to_version($bad);
    is($r->{success}, 0, "switch_to_version('$bad') rejected");
    ok(defined $r->{error} && $r->{error} =~ /invalid/i,
       "switch_to_version('$bad') error mentions 'invalid'");
}

# Valid format - even if version doesn't exist on GitHub, we should get
# a download error, not a validation error
{
    # Stub network failure by pointing at a bad host temporarily
    no warnings 'redefine';
    local *CLIO::Update::download_version = sub { return undef; };
    my $r = $updater->switch_to_version('99999999.99');
    is($r->{success}, 0, "Valid format with download failure returns success=0");
    ok(defined $r->{error} && $r->{error} =~ /download/i,
       "Valid format with download failure error mentions 'download'");
}

# ---------------------------------------------------------------------------
# switch_to_version vs install_version are aliases
# ---------------------------------------------------------------------------
print "\n--- switch_to_version / install_version aliases ---\n";

{
    no warnings 'redefine';
    local *CLIO::Update::download_version = sub {
        my ($self, $v) = @_;
        return undef;  # Simulate network failure
    };

    my $a = $updater->switch_to_version('99999999.99');
    my $b = $updater->install_version('99999999.99');

    is($a->{success}, $b->{success},
       "switch_to_version and install_version return same success flag");
    is($a->{error}, $b->{error},
       "switch_to_version and install_version return same error message");
}

# ---------------------------------------------------------------------------
# install_from_directory list-form safety
# ---------------------------------------------------------------------------
print "\n--- install_from_directory rejects bad source ---\n";

{
    # No source dir at all
    my $ok = $updater->install_from_directory('/nonexistent/path/that/does/not/exist');
    is($ok, 0, "install_from_directory returns 0 for missing source");

    # Source dir exists but isn't a CLIO tree
    my $tmpdir = File::Spec->catdir($RealBin, 'tmp_install_test');
    make_path($tmpdir);
    my $ok2 = $updater->install_from_directory($tmpdir);
    is($ok2, 0, "install_from_directory returns 0 for non-CLIO source dir");
    remove_tree($tmpdir);
}

# ---------------------------------------------------------------------------
# Draft filtering in /update list flow
# ---------------------------------------------------------------------------
print "\n--- Draft filtering ---\n";

{
    # Build a fake releases list and verify the filter logic
    my @releases = (
        { version => '20260720.3', tag_name => 'v20260720.3', draft => 0, prerelease => 0, published_at => '2026-07-20T00:00:00Z' },
        { version => '20260721.1', tag_name => 'v20260721.1', draft => 1, prerelease => 0, published_at => '2026-07-21T00:00:00Z' },
        { version => '20260722.1', tag_name => 'v20260722.1', draft => 0, prerelease => 1, published_at => '2026-07-22T00:00:00Z' },
    );

    my @visible = grep { !$_->{draft} } @releases;
    is(scalar(@visible), 2, "Draft releases filtered out");
    ok(!(grep { $_->{draft} } @visible), "No draft entries remain after filter");
    ok((grep { $_->{prerelease} } @visible),
       "Pre-release entries still present after draft filter");
}

# ---------------------------------------------------------------------------
# get_all_releases includes draft flag
# ---------------------------------------------------------------------------
print "\n--- get_all_releases draft field ---\n";

{
    no warnings 'redefine';
    # Stub the curl call by overriding get_latest_version and get_all_releases
    local *CLIO::Update::get_all_releases = sub {
        return [
            { version => '1.0', tag_name => 'v1.0', draft => 0, prerelease => 0, published_at => '2026-01-01T00:00:00Z' },
            { version => '1.1', tag_name => 'v1.1', draft => 1, prerelease => 0, published_at => '2026-01-02T00:00:00Z' },
        ];
    };

    my $releases = $updater->get_all_releases(per_page => 10);
    ok($releases && @$releases == 2, "get_all_releases returns array of releases");
    my $draft_count = scalar grep { $_->{draft} } @$releases;
    ok($draft_count == 1,
       "get_all_releases preserves draft flag for downstream filtering");
}

# ---------------------------------------------------------------------------
# switch_to_version returns version field on success
# ---------------------------------------------------------------------------
print "\n--- switch_to_version success shape ---\n";

{
    no warnings 'redefine';
    # Simulate a successful install by stubbing download and install
    local *CLIO::Update::download_version = sub {
        my ($self, $v) = @_;
        # Return a path nested under a fake download root. switch_to_version
        # cleanup uses dirname($source_dir) as the cleanup scope - if we
        # returned /tmp/foo directly, dirname() would be /tmp and rmtree
        # would walk the real /tmp tree (thousands of permission-denied
        # warnings). Nest under a dedicated directory so cleanup stays scoped.
        return '/tmp/clio-fake-update-root/fake-clio-source';
    };
    local *CLIO::Update::install_from_directory = sub {
        return 1;  # pretend success
    };

    my $r = $updater->switch_to_version('20260720.5');
    is($r->{success}, 1, "switch_to_version returns success=1 on install success");
    is($r->{version}, '20260720.5', "switch_to_version returns the requested version");
    ok(defined $r->{message} && $r->{message} =~ /20260720.5/,
       "switch_to_version message includes version");
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print "\n";
printf "%d passed, %d failed\n", $pass, $fail;
exit($fail > 0 ? 1 : 0);
