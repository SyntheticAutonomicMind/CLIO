#!/usr/bin/env perl
# Test the MiniMax think tag partial suffix detection functions
use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

print "Testing MiniMax think tag suffix detection...\n\n";

# Import the functions from APIManager
require CLIO::Core::APIManager;

my $pass = 0;
my $fail = 0;

sub ok {
    my ($test, $desc) = @_;
    if ($test) {
        print "ok - $desc\n";
        $pass++;
    } else {
        print "NOT ok - $desc\n";
        $fail++;
    }
}

# === Test _has_partial_open_think_suffix ===
print "--- Open <think> suffix detection ---\n";

# Should match: valid <think> prefixes
ok(CLIO::Core::APIManager::_has_partial_open_think_suffix("hello <"), "bare < at end");
ok(CLIO::Core::APIManager::_has_partial_open_think_suffix("hello <t"), "<t at end");
ok(CLIO::Core::APIManager::_has_partial_open_think_suffix("hello <th"), "<th at end");
ok(CLIO::Core::APIManager::_has_partial_open_think_suffix("hello <thi"), "<thi at end");
ok(CLIO::Core::APIManager::_has_partial_open_think_suffix("hello <thin"), "<thin at end");
ok(CLIO::Core::APIManager::_has_partial_open_think_suffix("hello <think"), "<think at end");

# Should NOT match: not a <think> prefix
ok(!CLIO::Core::APIManager::_has_partial_open_think_suffix("hello <a"), "<a should not match");
ok(!CLIO::Core::APIManager::_has_partial_open_think_suffix("hello <b"), "<b should not match");
ok(!CLIO::Core::APIManager::_has_partial_open_think_suffix("hello <div"), "<div should not match");
ok(!CLIO::Core::APIManager::_has_partial_open_think_suffix("hello <span"), "<span should not match");
ok(!CLIO::Core::APIManager::_has_partial_open_think_suffix("hello <ta"), "<ta should not match");
ok(!CLIO::Core::APIManager::_has_partial_open_think_suffix("x < 5"), "comparison < 5 should not match");
ok(!CLIO::Core::APIManager::_has_partial_open_think_suffix("hello"), "no < at all");
ok(!CLIO::Core::APIManager::_has_partial_open_think_suffix(""), "empty string");

# Should NOT match: complete <think> tag (already handled by s{} regex)
ok(!CLIO::Core::APIManager::_has_partial_open_think_suffix("hello <think>"), "complete <think> should not match");

print "\n--- Close </think> suffix detection ---\n";

# Should match: valid </think> prefixes
ok(CLIO::Core::APIManager::_has_partial_close_think_suffix("hello <"), "bare < at end (close)");
ok(CLIO::Core::APIManager::_has_partial_close_think_suffix("hello </"), "</ at end");
ok(CLIO::Core::APIManager::_has_partial_close_think_suffix("hello </t"), "</t at end");
ok(CLIO::Core::APIManager::_has_partial_close_think_suffix("hello </th"), "</th at end");
ok(CLIO::Core::APIManager::_has_partial_close_think_suffix("hello </thi"), "</thi at end");
ok(CLIO::Core::APIManager::_has_partial_close_think_suffix("hello </thin"), "</thin at end");
ok(CLIO::Core::APIManager::_has_partial_close_think_suffix("hello </think"), "</think at end");

# Should NOT match: not a </think> prefix
ok(!CLIO::Core::APIManager::_has_partial_close_think_suffix("hello </a"), "</a should not match");
ok(!CLIO::Core::APIManager::_has_partial_close_think_suffix("hello </div"), "</div should not match");
ok(!CLIO::Core::APIManager::_has_partial_close_think_suffix("hello"), "no < at all (close)");
ok(!CLIO::Core::APIManager::_has_partial_close_think_suffix(""), "empty string (close)");

# Should NOT match: complete </think> tag
ok(!CLIO::Core::APIManager::_has_partial_close_think_suffix("hello </think>"), "complete </think> should not match");

print "\n--- Edge cases ---\n";
# Mixed content that could confuse regex
ok(CLIO::Core::APIManager::_has_partial_open_think_suffix("code < 100 and <th"), "content with < earlier and <th at end");
ok(!CLIO::Core::APIManager::_has_partial_open_think_suffix("x < y < z"), "multiple < but none are think prefix");
ok(CLIO::Core::APIManager::_has_partial_open_think_suffix("<"), "just a bare <");
ok(CLIO::Core::APIManager::_has_partial_close_think_suffix("</"), "just </");

print "\n========================================\n";
print "Results: $pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);
