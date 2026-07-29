#!/usr/bin/env perl
# Test: /preview command for styles and themes
# Covers:
#   - /preview (no args) previews current style+theme
#   - /preview style <name> previews a specific style, restores original
#   - /preview theme <name> previews a specific theme, restores original
#   - /preview style with bad name errors out and restores
#   - /preview always restores original style/theme (never persists)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use FindBin qw($RealBin);
use Cwd qw(abs_path);
use lib '../../lib';

BEGIN {
    no warnings 'redefine';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (80, 24); };
}

use CLIO::UI::Theme;
use CLIO::UI::Commands::Config;

my ($pass, $fail) = (0, 0);

sub ok_int {
    my ($got, $expected, $label) = @_;
    if (defined $got && $got == $expected) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (got=" . (defined $got ? $got : 'undef') . ", expected=$expected)\n";
        $fail++;
    }
}

sub ok_str {
    my ($got, $expected, $label) = @_;
    if (defined $got && $got eq $expected) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (got='$got', expected='$expected')\n";
        $fail++;
    }
}

# Build a fake chat object that captures output without color substitution.
# This lets us test that /preview's structure is correct without depending
# on the full Chat/Display stack.
package FakeChat;
sub new {
    my ($cls, $theme) = @_;
    return bless { theme_mgr => $theme, debug => 0, no_color => 1, _output => [] }, $cls;
}
sub output { return $_[0]->{_output} }
sub clear_output { $_[0]->{_output} = [] }
sub colorize { my ($self, $text, $role) = @_; return $text; }
sub writeline {
    my ($self, $text, %opts) = @_;
    push @{$self->{_output}}, $text if defined $text;
}
sub display_command_header { my ($self, $t) = @_; push @{$self->{_output}}, "=== $t ==="; }
sub display_system_message { my ($self, $t) = @_; push @{$self->{_output}}, "[SYSTEM] $t"; }
sub display_error_message { my ($self, $t) = @_; push @{$self->{_output}}, "[ERROR] $t"; }
sub display_info_message { my ($self, $t) = @_; push @{$self->{_output}}, "[INFO] $t"; }
sub display_warning_message { my ($self, $t) = @_; push @{$self->{_output}}, "[WARN] $t"; }
sub display_success_message { my ($self, $t) = @_; push @{$self->{_output}}, "[OK] $t"; }

package main;

# Find the repo root by walking up from the test location. Theme.pm uses
# base_dir as the location of styles/ and themes/ directories, so we have
# to give it an absolute path - relative paths get resolved against cwd
# which can change between test runs.
my $repo_root = abs_path("$RealBin/../..");

CLIO::UI::Theme->clear_cache();
my $theme = CLIO::UI::Theme->new(
    debug => 0,
    style => 'default',
    theme => 'default',
    base_dir => $repo_root,
);
my $chat = FakeChat->new($theme);
my $config = bless {}, 'FakeConfig';
my $cmd = CLIO::UI::Commands::Config->new(chat => $chat, config => $config, debug => 0);

# Sanity check: Theme must have actually loaded styles from disk.
unless (exists $theme->{styles}->{dracula} && exists $theme->{styles}->{monokai}) {
    die "Test setup error: Theme->{styles} missing expected styles. "
      . "base_dir=$repo_root, loaded="
      . scalar(keys %{$theme->{styles}}) . "\n";
}

# --- /preview (no args) renders expected sections ---
{
    $chat->clear_output();
    $cmd->handle_preview_command();

    my @out = @{$chat->output()};

    my @expected_sections = (
        'PREVIEW: current',
        '[ BANNER ]',
        '[ CONVERSATION ]',
        '[ THINKING ]',
        '[ TOOL CALL ]',
        '[ STATUS ]',
        '[ MARKDOWN ]',
        '[ PROMPT ]',
        'Preview only',
    );

    my $missing = 0;
    for my $section (@expected_sections) {
        unless (grep { /\Q$section\E/ } @out) {
            print "FAIL: /preview section missing: '$section'\n";
            $missing++;
            $fail++;
        }
    }
    if ($missing == 0) {
        print "PASS: /preview (no args) renders all expected sections\n";
        $pass++;
    }

    # Active style/theme unchanged after preview
    ok_str($theme->get_current_style(), 'default', '/preview (no args) restores active style');
    ok_str($theme->get_current_theme(), 'default', '/preview (no args) restores active theme');
}

# --- /preview style <name> switches to named style, then restores ---
{
    $chat->clear_output();
    $cmd->handle_preview_command('style', 'dracula');

    my @out = @{$chat->output()};

    if (grep { /PREVIEW: style: dracula/ } @out) {
        print "PASS: /preview style dracula uses dracula label\n";
        $pass++;
    } else {
        print "FAIL: /preview style dracula missing label\n";
        $fail++;
    }

    # Dracula style has @MAGENTA@ primary - banner line should contain it.
    if (grep { /CLIO/ } @out) {
        print "PASS: /preview style dracula renders banner line\n";
        $pass++;
    } else {
        print "FAIL: /preview style dracula missing banner\n";
        $fail++;
    }

    ok_str($theme->get_current_style(), 'default', '/preview style restores active style');
    ok_str($theme->get_current_theme(), 'default', '/preview style restores active theme');
}

# --- /preview theme <name> switches to named theme, then restores ---
{
    $chat->clear_output();
    $cmd->handle_preview_command('theme', 'compact');

    my @out = @{$chat->output()};

    if (grep { /PREVIEW: theme: compact/ } @out) {
        print "PASS: /preview theme compact uses compact label\n";
        $pass++;
    } else {
        print "FAIL: /preview theme compact missing label\n";
        $fail++;
    }

    # Compact theme has banner_line1 with "v1.0" - banner should render differently.
    if (grep { /v1\.0|CLIO/ } @out) {
        print "PASS: /preview theme compact renders banner\n";
        $pass++;
    } else {
        print "FAIL: /preview theme compact missing banner\n";
        $fail++;
    }

    ok_str($theme->get_current_style(), 'default', '/preview theme restores active style');
    ok_str($theme->get_current_theme(), 'default', '/preview theme restores active theme');
}

# --- /preview style with bad name errors and restores ---
{
    my $orig_style = $theme->get_current_style();
    my $orig_theme = $theme->get_current_theme();

    $chat->clear_output();
    $cmd->handle_preview_command('style', 'no_such_style');

    my @out = @{$chat->output()};

    if (grep { /\[ERROR\].*no_such_style/ } @out) {
        print "PASS: /preview style with bad name produces error\n";
        $pass++;
    } else {
        print "FAIL: /preview style with bad name missing error message\n";
        $fail++;
    }

    ok_str($theme->get_current_style(), $orig_style, '/preview style (bad) restores style');
    ok_str($theme->get_current_theme(), $orig_theme, '/preview style (bad) restores theme');
}

# --- /preview theme with bad name errors and restores ---
{
    my $orig_style = $theme->get_current_style();
    my $orig_theme = $theme->get_current_theme();

    $chat->clear_output();
    $cmd->handle_preview_command('theme', 'no_such_theme');

    my @out = @{$chat->output()};

    if (grep { /\[ERROR\].*no_such_theme/ } @out) {
        print "PASS: /preview theme with bad name produces error\n";
        $pass++;
    } else {
        print "FAIL: /preview theme with bad name missing error message\n";
        $fail++;
    }

    ok_str($theme->get_current_style(), $orig_style, '/preview theme (bad) restores style');
    ok_str($theme->get_current_theme(), $orig_theme, '/preview theme (bad) restores theme');
}

# --- /preview bad action shows usage ---
{
    $chat->clear_output();
    $cmd->handle_preview_command('garbage');

    my @out = @{$chat->output()};

    if (grep { /\[ERROR\].*Usage/ } @out) {
        print "PASS: /preview garbage shows usage error\n";
        $pass++;
    } else {
        print "FAIL: /preview garbage missing usage error\n";
        $fail++;
    }
}

# --- /preview does not persist (config still unchanged after multiple previews) ---
{
    # config is empty FakeConfig - if anything in /preview touched it, we'd see keys
    my %before = %{$config};
    $cmd->handle_preview_command('style', 'monokai');
    $cmd->handle_preview_command('theme', 'verbose');
    my %after = %{$config};

    my $changed = 0;
    for my $k (keys %before) {
        if (!exists $after{$k} || $before{$k} ne $after{$k}) {
            $changed++;
        }
    }
    for my $k (keys %after) {
        if (!exists $before{$k}) {
            $changed++;
        }
    }
    ok_int($changed, 0, '/preview never persists to config');
}

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);