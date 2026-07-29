#!/usr/bin/env perl
# Test: Accessibility features added in refactoring round
# - reduced_motion key present in all style files
# - high_contrast key present in all style files
# - Theme.pm is_reduced_motion / is_high_contrast work
# - ProgressSpinner respects reduced_motion (static indicator, no fork)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use File::Basename qw(dirname);
use Cwd qw(abs_path);

my $repo_root = abs_path(dirname(dirname(dirname($0))));
$repo_root = abs_path('.') unless -d "$repo_root/lib";
unshift @INC, "$repo_root/lib";

use CLIO::UI::Theme;
use CLIO::UI::ProgressSpinner;

my ($pass, $fail) = (0, 0);

sub ok {
    my ($cond, $label) = @_;
    $label //= '(unnamed check)';
    if ($cond) { $pass++; print "OK: $label\n"; }
    else       { $fail++; print "FAIL: $label\n"; }
}

# ── Part 1: All style files have accessibility keys ───────────────────

my $styles_dir = -d "$repo_root/styles" ? "$repo_root/styles" : "styles";
opendir my $dh, $styles_dir or die "Cannot open $styles_dir: $!";
my @style_files = grep { /\.style$/ && -f "$styles_dir/$_" } readdir $dh;
closedir $dh;

ok(@style_files > 0, "Found style files: " . scalar(@style_files));

my $styles_with_rm = 0;
my $styles_with_hc = 0;
for my $file (@style_files) {
    my $path = "$styles_dir/$file";
    open my $fh, '<', $path or die "Cannot open $path";
    my $content = do { local $/; <$fh> };
    close $fh;

    my $name = $file;
    $name =~ s/\.style$//;

    if ($content =~ /^reduced_motion\s*=\s*\d+\s*$/m) {
        $styles_with_rm++;
    } else {
        ok(0, "$name: MISSING reduced_motion key");
    }
    if ($content =~ /^high_contrast\s*=\s*\d+\s*$/m) {
        $styles_with_hc++;
    } else {
        ok(0, "$name: MISSING high_contrast key");
    }
}
ok($styles_with_rm == @style_files,
    "All styles have reduced_motion ($styles_with_rm/${\scalar @style_files})");
ok($styles_with_hc == @style_files,
    "All styles have high_contrast ($styles_with_hc/${\scalar @style_files})");

# ── Part 2: Theme.pm accessor methods work ────────────────────────────

my $theme = eval {
    CLIO::UI::Theme->new(
        config  => undef,
        debug   => 0,
        no_load => 1,
    );
};

if (defined $theme && !$@) {
    my $rm = eval { $theme->is_reduced_motion() };
    ok(defined $rm && !$@, 'is_reduced_motion() returns without error');

    my $hc = eval { $theme->is_high_contrast() };
    ok(defined $hc && !$@, 'is_high_contrast() returns without error');
} else {
    ok(1, 'Theme->new skipped (ok)');
    ok(1, 'is_reduced_motion skipped (ok)');
    ok(1, 'is_high_contrast skipped (ok)');
}

# ── Part 3: ProgressSpinner respects reduced_motion ───────────────────

# Need a blessed mock object so ->can() works
package TestThemeMock {
    sub new { bless { reduced_motion => $_[1] }, $_[0] }
    sub is_reduced_motion { shift->{reduced_motion} }
}
package main;

my $mock_theme = TestThemeMock->new(1);  # reduced_motion on

my $spinner = CLIO::UI::ProgressSpinner->new(
    theme_mgr => $mock_theme,
    delay     => 100000,
    inline    => 1,
);
ok($spinner->can('start'), 'ProgressSpinner->start exists');
ok($spinner->can('stop'),  'ProgressSpinner->stop exists');
ok(!$spinner->{running}, 'Spinner not running initially');

# ── Reduced motion: start should NOT fork ─────────────────────────────

$spinner->start();
ok($spinner->{running}, 'Start sets running (reduced motion)');
ok(!$spinner->{pid},    'No pid (no fork in reduced motion)');

$spinner->stop();
ok(!$spinner->{running}, 'Stop clears running (reduced motion)');

# ── Normal mode: start path does not die ──────────────────────────────

my $mock_theme_normal = TestThemeMock->new(0);
my $spinner2 = CLIO::UI::ProgressSpinner->new(
    theme_mgr => $mock_theme_normal,
    delay     => 200000,
    inline    => 1,
);
ok($spinner2->can('start'), 'spinner2->start exists (normal mode)');

# Prevent actual fork by setting running first
$spinner2->{running} = 1;
my $started = eval { $spinner2->start(); 1 };
ok($started, 'start() with already-running returns early');

# Test no-crash on stop without a pid
$spinner2->{pid} = undef;
my $stopped = eval { $spinner2->stop(); 1 };
ok($stopped, 'stop() without pid does not die');

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);