#!/usr/bin/env perl

use strict;
use warnings;
use JSON::PP qw(encode_json);
use lib 'lib';
use CLIO::Util::TextSanitizer qw(sanitize_text);

# Test string with emojis
my $text = "❌ WRONG: test ✅ RIGHT: test → arrow";

print "Original: $text\n";

my $sanitized = sanitize_text($text);
print "Sanitized: $sanitized\n";

my $json = encode_json({content => $sanitized});
print "JSON: $json\n";

# Test that it doesn't have escape sequences
if ($json =~ /\\x\{/) {
    print "ERROR: JSON still contains escape sequences!\n";
} else {
    print "SUCCESS: JSON is clean!\n";
}
