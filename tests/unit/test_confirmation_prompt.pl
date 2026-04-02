#!/usr/bin/env perl
# Test confirmation prompt rendering across all themes
#
# Usage:
#   perl -I./lib tests/unit/test_confirmation_prompt.pl
#   perl -I./lib tests/unit/test_confirmation_prompt.pl --visual   # show rendered prompts

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use FindBin qw($RealBin);
use File::Spec;
use Test::More;

# Visual mode shows rendered prompts for manual inspection
my $visual = grep { $_ eq '--visual' } @ARGV;

# Ensure we load from the project root
my $project_root = File::Spec->catdir($RealBin, '..', '..');
chdir $project_root or die "Cannot chdir to $project_root: $!";

use lib 'lib';
use CLIO::UI::Theme;

# ──────────────────────────────────────────────────────────────
# Test 1: Theme loads correctly
# ──────────────────────────────────────────────────────────────

my $theme_mgr = CLIO::UI::Theme->new(base_dir => '.', debug => 0);
ok($theme_mgr, 'Theme manager created');

# ──────────────────────────────────────────────────────────────
# Test 2: All theme files have the required confirmation keys
# ──────────────────────────────────────────────────────────────

my @theme_names = sort keys %{$theme_mgr->{themes}};
ok(scalar @theme_names > 0, 'At least one theme loaded');

for my $name (@theme_names) {
    my $theme = $theme_mgr->{themes}{$name};
    ok(defined $theme->{confirmation_prompt} && $theme->{confirmation_prompt} ne '',
       "Theme '$name' has confirmation_prompt template");
    ok(defined $theme->{confirmation_prompt_no_options} && $theme->{confirmation_prompt_no_options} ne '',
       "Theme '$name' has confirmation_prompt_no_options template");
    ok(defined $theme->{confirmation_prompt_short} && $theme->{confirmation_prompt_short} ne '',
       "Theme '$name' has confirmation_prompt_short template");
}

# ──────────────────────────────────────────────────────────────
# Test 3: get_confirmation_prompt returns a non-empty string
# ──────────────────────────────────────────────────────────────

for my $name (@theme_names) {
    $theme_mgr->set_theme($name);

    # Full prompt (question + options + default_action)
    my $full = $theme_mgr->get_confirmation_prompt("Install update?", "yes/no", "cancel");
    ok(defined $full && ref($full) eq '', "Theme '$name' full prompt returns scalar (not ref)");
    ok(length($full) > 10, "Theme '$name' full prompt has content (len=" . length($full) . ")");

    # No-options prompt (question + default_action, no options)
    my $no_opts = $theme_mgr->get_confirmation_prompt("Enter learnings", "", "skip");
    ok(defined $no_opts && length($no_opts) > 5, "Theme '$name' no-options prompt has content");

    # Short prompt (question only, no options or default)
    my $short = $theme_mgr->get_confirmation_prompt("Commit message", "", "");
    ok(defined $short && length($short) > 5, "Theme '$name' short prompt has content");

    if ($visual) {
        print "\n--- Theme: $name ---\n";
        print "Full:     $full\n";
        print "No-opts:  $no_opts\n";
        print "Short:    $short\n";
    }
}

# ──────────────────────────────────────────────────────────────
# Test 4: Prompt contains expected text fragments
# ──────────────────────────────────────────────────────────────

$theme_mgr->set_theme('default');

my $prompt = $theme_mgr->get_confirmation_prompt("Delete file?", "yes/no", "cancel");
# Strip ANSI escape sequences for content checking
(my $stripped = $prompt) =~ s/\e\[[0-9;]*m//g;

like($stripped, qr/Delete file\?/, 'Full prompt contains question text');
like($stripped, qr/yes\/no/, 'Full prompt contains options text');
like($stripped, qr/cancel/, 'Full prompt contains default_action text');

my $no_opts = $theme_mgr->get_confirmation_prompt("Enter learnings", "", "skip");
(my $stripped_no = $no_opts) =~ s/\e\[[0-9;]*m//g;
like($stripped_no, qr/Enter learnings/, 'No-options prompt contains question text');
like($stripped_no, qr/skip/, 'No-options prompt contains default_action text');
unlike($stripped_no, qr/yes\/no/, 'No-options prompt does not contain options');

my $short = $theme_mgr->get_confirmation_prompt("Commit message", "", "");
(my $stripped_short = $short) =~ s/\e\[[0-9;]*m//g;
like($stripped_short, qr/Commit message/, 'Short prompt contains question text');

# ──────────────────────────────────────────────────────────────
# Test 5: Old template keys should NOT exist (migration check)
# ──────────────────────────────────────────────────────────────

for my $name (@theme_names) {
    my $theme = $theme_mgr->{themes}{$name};
    ok(!exists $theme->{confirmation_header},
       "Theme '$name' does not have old confirmation_header key");
    ok(!exists $theme->{confirmation_input},
       "Theme '$name' does not have old confirmation_input key");
}

done_testing();
