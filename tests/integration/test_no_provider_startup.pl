#!/usr/bin/env perl
# Regression test: CLIO handles missing provider gracefully
#
# Bug (fixed in 3c54e465): When no provider was configured, CLIO would
# crash on startup instead of starting gracefully and allowing the user
# to configure one via /api.
#
# This test verifies:
#   1. CLIO starts successfully (exit 0) when no provider is configured
#   2. The no-provider path is detected and handled, not crashed through

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use FindBin qw($RealBin);

# Capture::Tiny may not be available (not a core module), so use
# pipe-based capture instead to keep the test dependency-free.

# Helper: run clio and capture stdout, stderr, exit code
sub run_clio {
    my ($args, $env) = @_;
    $args //= [];
    $env //= {};

    my $clio_bin = File::Spec->catfile($RealBin, '..', '..', 'clio');
    my @cmd = ($^X, $clio_bin, @$args);

    my $pid = open(my $fh, '-|');
    if (!defined $pid) {
        die "fork failed: $!";
    }

    if ($pid == 0) {
        # Child: redirect STDERR to STDOUT for capture
        open(STDERR, '>&', STDOUT);
        # Set environment
        for my $k (keys %$env) {
            $ENV{$k} = $env->{$k};
        }
        exec @cmd;
        exit 127;  # exec failed
    }

    local $/;
    my $output = <$fh>;
    close $fh;

    my $exit_code = $? >> 8;
    return ($output, $exit_code);
}

subtest 'clio starts successfully with no provider' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $clio_dir = File::Spec->catdir($tmpdir, '.clio');
    make_path($clio_dir);

    # Empty config: no provider, no API keys
    open my $cfg_fh, '>', File::Spec->catfile($clio_dir, 'config.json')
        or die "Cannot create config: $!";
    print $cfg_fh '{}';
    close $cfg_fh;

    my ($output, $exit_code) = run_clio(
        ['--input', 'test', '--exit'],
        {
            HOME    => $tmpdir,
            NO_COLOR => '1',
        },
    );

    is($exit_code, 0, 'clio exits with code 0 when no provider configured');

    # No-provider path was taken: graceful message, not a crash
    like($output, qr/No AI provider configured/i,
        'output contains no-provider system message');
};

subtest 'no false positive: provider configured does not trigger no-provider path' => sub {
    my $tmpdir = tempdir(CLEANUP => 1);
    my $clio_dir = File::Spec->catdir($tmpdir, '.clio');
    make_path($clio_dir);

    # Config with openai provider but no key - still a configured provider
    open my $cfg_fh, '>', File::Spec->catfile($clio_dir, 'config.json')
        or die "Cannot create config: $!";
    print $cfg_fh '{"provider":"openai"}';
    close $cfg_fh;

    my ($output, $exit_code) = run_clio(
        ['--input', 'test', '--exit'],
        {
            HOME    => $tmpdir,
            NO_COLOR => '1',
        },
    );

    # No-provider guard should NOT fire when provider IS set
    unlike($output, qr/No AI provider configured/i,
        'output does NOT contain no-provider message when provider is set');
};

done_testing();
