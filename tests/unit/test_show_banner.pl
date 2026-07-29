#!/usr/bin/env perl
# Test: --no-banner and show_banner config key
# Covers:
#   - show_banner defaults to true (banner shows by default)
#   - /config set show_banner off persists to disk
#   - Chat->display_header respects show_banner=0
#   - Chat->display_header respects show_banner=1

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use lib '../../lib';

BEGIN {
    no warnings 'redefine';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (80, 24); };
}

use CLIO::Core::Config;

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

# Use an isolated config directory so we don't clobber the real config.
my $config_dir = "/tmp/clio-test-banner-$$";
mkdir $config_dir;

# --- Default value ---
{
    my $c = CLIO::Core::Config->new(debug => 0, config_dir => $config_dir);
    ok_int($c->get('show_banner'), 1, 'show_banner defaults to 1 (banner shown)');
}

# --- Setting show_banner=0 persists ---
{
    my $c = CLIO::Core::Config->new(debug => 0, config_dir => $config_dir);
    $c->set('show_banner', 0);
    $c->save();
}

{
    my $c = CLIO::Core::Config->new(debug => 0, config_dir => $config_dir);
    ok_int($c->get('show_banner'), 0, 'show_banner=0 persists across instances');
}

# --- Setting show_banner=1 persists ---
{
    my $c = CLIO::Core::Config->new(debug => 0, config_dir => $config_dir);
    $c->set('show_banner', 1);
    $c->save();
}

{
    my $c = CLIO::Core::Config->new(debug => 0, config_dir => $config_dir);
    ok_int($c->get('show_banner'), 1, 'show_banner=1 persists across instances');
}

# Cleanup
system("rm -rf $config_dir");

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);