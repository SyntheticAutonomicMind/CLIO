#!/usr/bin/env perl
# Test: The CACHE MISS diagnostic in APIManager must be at log_debug level,
# not log_warning. A cache miss is an internal implementation detail that
# the user does not need to see in normal (non-debug) operation.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ":encoding(UTF-8)");

use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

my ($pass, $fail) = (0, 0);
sub ok { my ($cond, $label) = @_; if ($cond) { $pass++; print "OK: $label\n"; } else { $fail++; print "FAIL: $label\n"; } }

my $file = "$RealBin/../../lib/CLIO/Core/APIManager.pm";
open my $fh, "<:encoding(UTF-8)", $file or die "Cannot read $file: $!";
my $content = do { local $/; <$fh> };
close $fh;

# The "CACHE MISS" diagnostic must use log_debug, not log_warning.
{
    my $idx = index($content, "CACHE MISS: prompt_stable_prefix_tokens");
    ok($idx >= 0, "CACHE MISS diagnostic found in APIManager.pm");
    if ($idx >= 0) {
        my $snippet = substr($content, $idx - 500, 500);
        my ($last_log) = ($snippet =~ /.*(log_\w+)/sg);
        ok($last_log && $last_log eq "log_debug",
           "CACHE MISS uses log_debug (not log_warning)");
    }
}

# Also verify the "Stable prefix: excluded user_context" message is log_debug
{
    my $idx = index($content, "Stable prefix: excluded");
    ok($idx >= 0, "\"Stable prefix: excluded\" diagnostic found");
    if ($idx >= 0) {
        my $snippet = substr($content, $idx - 500, 500);
        my ($last_log) = ($snippet =~ /.*(log_\w+)/sg);
        ok($last_log && $last_log eq "log_debug",
           "Stable prefix exclusion message uses log_debug (not log_warning)");
    }
}

print "\nPassed: $pass\n";
print "Failed: $fail\n";
exit($fail == 0 ? 0 : 1);
