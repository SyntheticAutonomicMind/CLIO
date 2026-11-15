#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_strict_warn_attribution.pl - Vendor warnings are reattributed to CLIO callers

=head1 DESCRIPTION

The strict runner used to discard any warning whose blame line named a system
perl tree. A vendor module such as lib.pm reports the undef it was handed, so
the CLIO caller that caused it was classified informational and never gated
the build.

Covers three pieces:

=over 4

=item * CLIO::Test::WarningAttribution - grouping and provenance rules, driven
with synthetic stderr so the cases are exact.

=item * CLIO::Test::WarningTrace - emits a frame only for production code
under C<lib/>, so test code calling a vendor module does not become a CLIO
warning.

=item * The real runner, driven end to end on a synthetic tree.

=back

=cut

use strict;
use warnings;
use utf8;

use Test::More;
use FindBin qw($Bin);
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Path qw(mkpath);
use Cwd qw(abs_path);

use CLIO::Util::JSON qw(decode_json);
use CLIO::Test::WarningAttribution qw(classify_warnings);

my $tests_dir = dirname(abs_path($Bin));
my $repo_root = dirname($tests_dir);
my $runner    = "$repo_root/tests/run_strict_tests.pl";

my @PATTERNS = (
    [qr/\bUse of uninitialized value\b/, 'uninitialized'],
    [qr/\bWide character in\b/,          'wide-character'],
);

sub _q {
    my ($s) = @_;
    $s =~ s/'/'"'"'/g;
    return "'$s'";
}

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or return '';
    local $/;
    my $text = <$fh>;
    close $fh;
    return defined $text ? $text : '';
}

# ---------------------------------------------------------------------------
# Attribution rules
# ---------------------------------------------------------------------------

subtest 'vendor warning with no CLIO frame stays vendored' => sub {
    my $stderr = "Use of uninitialized value in string eq at /usr/share/perl/5.36/lib.pm line 22.\n";
    my ($findings, $vendor) = classify_warnings($stderr, \@PATTERNS, '/repo');
    is($vendor, 1, 'counted as vendor');
    is(scalar(@$findings), 0, 'no CLIO finding');
};

subtest 'vendor warning with a CLIO frame is attributed to the frame' => sub {
    my $stderr = join "\n",
        "Use of uninitialized value in string eq at /usr/share/perl/5.36/lib.pm line 22.",
        "# clio-frame lib/CLIO/Tools/Foo.pm line 41 CLIO::Tools::Foo::bar",
        "";
    my ($findings, $vendor) = classify_warnings($stderr, \@PATTERNS, '/repo');
    is($vendor, 0, 'not vendored');
    is(scalar(@$findings), 1, 'one finding');
    is($findings->[0]{places}[0]{location}, 'lib/CLIO/Tools/Foo.pm:41',
        'location is the CLIO frame');
};

subtest 'CLIO blame line is attributed in place' => sub {
    my $stderr = "Wide character in print at /repo/lib/CLIO/Bar.pm line 7.\n";
    my ($findings, $vendor) = classify_warnings($stderr, \@PATTERNS, '/repo');
    is($vendor, 0, 'not vendored');
    is($findings->[0]{places}[0]{location}, 'lib/CLIO/Bar.pm:7',
        'path is repo-relative');
};

subtest 'repeated warnings at one location are counted' => sub {
    my $stderr = join "\n",
        "Wide character in print at /repo/lib/CLIO/Bar.pm line 7.",
        "Wide character in print at /repo/lib/CLIO/Bar.pm line 7.",
        "";
    my ($findings, $vendor) = classify_warnings($stderr, \@PATTERNS, '/repo');
    is($vendor, 0, 'not vendored');
    is($findings->[0]{count}, 2, 'two occurrences');
};

# ---------------------------------------------------------------------------
# Trace module: production frames only
# ---------------------------------------------------------------------------

subtest 'trace reports production frames and ignores test frames' => sub {
    my $root = tempdir(CLEANUP => 1);
    mkpath("$root/lib");
    mkpath("$root/tests");
    mkpath("$root/mod");

    open my $mf, '>', "$root/mod/Warner.pm" or die "write Warner: $!";
    print $mf "package Warner;\nsub boom { warn 'Use of uninitialized value in string eq'; return 1 }\n1;\n";
    close $mf;

    for my $place (qw(lib tests)) {
        open my $cf, '>', "$root/$place/caller.pl" or die "write caller: $!";
        print $cf "use lib '$root/mod';\nuse Warner;\nWarner::boom();\nexit 0;\n";
        close $cf;
    }

    my $lib_err = "$root/lib.err";
    system(join ' ',
        'CLIO_REPO_ROOT=' . _q($root),
        _q($^X),
        '-I', _q("$repo_root/tests/lib"),
        '-MCLIO::Test::WarningTrace',
        _q("$root/lib/caller.pl"),
        '2>', _q($lib_err),
        '1>/dev/null');
    my $lib_stderr = _slurp($lib_err);
    like($lib_stderr, qr{^# clio-frame lib/caller\.pl line \d+}m,
        'production caller frame is printed');
    like($lib_stderr, qr{at \Q$root\E/mod/Warner\.pm line \d+},
        'blame line is outside lib');

    my $tests_err = "$root/tests.err";
    system(join ' ',
        'CLIO_REPO_ROOT=' . _q($root),
        _q($^X),
        '-I', _q("$repo_root/tests/lib"),
        '-MCLIO::Test::WarningTrace',
        _q("$root/tests/caller.pl"),
        '2>', _q($tests_err),
        '1>/dev/null');
    unlike(_slurp($tests_err), qr{clio-frame},
        'test caller frame is not reported');
};

# ---------------------------------------------------------------------------
# End to end: the runner attributes a vendor warning to the production caller
# ---------------------------------------------------------------------------

subtest 'runner attributes a vendor warning to the CLIO caller' => sub {
    plan skip_all => "strict runner not found at $runner" unless -f $runner;

    # The vendor module lives outside the repository, as a real one does.
    my $vendor_root = tempdir(CLEANUP => 1);
    mkpath("$vendor_root/perl/vendorish");
    open my $vf, '>', "$vendor_root/perl/vendorish/FakeVendor.pm"
        or die "write FakeVendor: $!";
    print $vf <<'VENDOR';
package FakeVendor;
sub boom {
    warn "Use of uninitialized value in string eq";
    return 1;
}
1;
VENDOR
    close $vf;

    # The caller is a synthetic production frame: the trace prefix is pointed
    # at tests/ so the fixture does not have to write into lib/.
    my $caller_root = tempdir('strict-warn-XXXXXX', DIR => $tests_dir, CLEANUP => 1);
    open my $cf, '>', "$caller_root/caller.pl" or die "write caller: $!";
    print $cf <<"CALLER";
use lib '$vendor_root/perl/vendorish';
use FakeVendor;
FakeVendor::boom();
exit 0;
CALLER
    close $cf;

    my $shell = join ' ',
        'CLIO_WARN_FRAME_PREFIX=tests',
        _q($^X),
        '-I', _q("$repo_root/lib"),
        _q($runner),
        '--json',
        _q("$caller_root/caller.pl"),
        '2>/dev/null';

    my $json = `$shell`;
    my $data = eval { decode_json($json) };
    ok($data && ref $data eq 'HASH', 'runner produced parseable JSON')
        or diag("runner output: " . substr($json, 0, 400));

    my $summary = $data->{summary} || {};
    is($summary->{vendor}, 0, 'not classified as vendor');
    ok(($summary->{warnings} || 0) >= 1, 'counted as a CLIO warning');

    my @locations = map { $_->{location} }
        map { @{ $_->{places} || [] } }
        map { @{ $_->{warnings} || [] } }
        @{ $data->{tests} || [] };
    ok((grep { defined $_ && m{caller\.pl:\d+} } @locations),
        'attribution points at the caller')
        or diag("locations: @locations");
};

done_testing();
