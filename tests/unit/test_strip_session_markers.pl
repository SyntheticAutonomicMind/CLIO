#!/usr/bin/env perl
# Test strip_session_markers utility function

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Util::TextSanitizer qw(strip_session_markers);

subtest 'structured format' => sub {
    my $text = "Hello world\n<!--session:{\"title\":\"fix bug\"}-->\n";
    my $result = strip_session_markers($text);
    unlike($result, qr/<!--session:/, "Structured marker stripped");
    like($result, qr/Hello world/, "Content preserved");
};

subtest 'simple format' => sub {
    my $text = "Response text\n\n<!--session:fix-session-naming-->\n";
    my $result = strip_session_markers($text);
    unlike($result, qr/<!--session:/, "Simple marker stripped");
    like($result, qr/Response text/, "Content preserved");
};

subtest 'no marker' => sub {
    my $text = "Just a regular message with no markers.";
    my $result = strip_session_markers($text);
    is($result, $text, "Text unchanged when no marker");
};

subtest 'empty input' => sub {
    is(strip_session_markers(undef), undef, "undef passes through");
    is(strip_session_markers(''), '', "empty string passes through");
};

subtest 'multiple markers' => sub {
    my $text = "A <!--session:{\"title\":\"first\"}--> B <!--session:second--> C";
    my $result = strip_session_markers($text);
    unlike($result, qr/<!--session:/, "All markers stripped");
    like($result, qr/A.*B.*C/s, "Content between markers preserved");
};

done_testing();
