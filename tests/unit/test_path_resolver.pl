#!/usr/bin/env perl

# Unit tests for CLIO::Util::PathResolver - specifically find_clio_dir

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Spec;
use File::Path qw(make_path remove_tree);
use Cwd qw(abs_path);

my ($pass, $fail) = (0, 0);

sub ok {
    my ($cond, $desc) = @_;
    if ($cond) { print "PASS: $desc\n"; $pass++; }
    else { print "FAIL: $desc\n"; $fail++; }
}

sub is {
    my ($got, $expected, $desc) = @_;
    if (defined($got) && defined($expected) && $got eq $expected) {
        print "PASS: $desc\n"; $pass++;
    } else {
        $got //= '(undef)'; $expected //= '(undef)';
        print "FAIL: $desc\n      got:      $got\n      expected: $expected\n"; $fail++;
    }
}

sub like {
    my ($got, $regex, $desc) = @_;
    if (defined($got) && $got =~ $regex) {
        print "PASS: $desc\n"; $pass++;
    } else {
        $got //= '(undef)';
        print "FAIL: $desc\n      got:      $got\n      expected: match $regex\n"; $fail++;
    }
}

sub use_ok: {
    my $ok = CLIO::Util::PathResolver->can('find_clio_dir');
    ok($ok, 'find_clio_dir is a callable method');
}

print "\n--- find_clio_dir exports and works ---\n";

{
    require CLIO::Util::PathResolver;
    use_ok: {
        my $ok = CLIO::Util::PathResolver->can('find_clio_dir');
        ok($ok, 'find_clio_dir is a callable method');
    }

    # Test exported
    my @exports = @CLIO::Util::PathResolver::EXPORT_OK;
    ok(grep(/find_clio_dir/, @exports), 'find_clio_dir is in EXPORT_OK list');

    # Test it finds the project root from a subdirectory
    my $dir = CLIO::Util::PathResolver::find_clio_dir("$RealBin/../../lib/CLIO/Core");
    ok(-d File::Spec->catdir($dir, '.clio'), 'find_clio_dir finds project root containing .clio/');

    # Test it returns a usable path
    ok(-d $dir, 'find_clio_dir returns an existing directory');
}

print "\n--- find_clio_dir works in PromptBuilder ---\n";

{
    require CLIO::Core::PromptBuilder;
    my $pb = CLIO::Core::PromptBuilder->new();
    ok($pb, 'PromptBuilder can be instantiated without find_clio_dir errors');
    # _read_session_goals / get_user_context (the old <sessionContext>
    # XML path) were removed in the role-based history refactor; the
    # live path now renders the environment via the ContextBuilder
    # projection. The constructor check above still exercises find_clio_dir
    # avoidance at construction time.
}

print "\n";
printf "%d passed, %d failed\n", $pass, $fail;
exit($fail > 0 ? 1 : 0);
