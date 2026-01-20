#!/usr/bin/env perl

use strict;
use warnings;
use lib 'lib';
use CLIO::Util::TextSanitizer qw(sanitize_text);
use JSON::PP qw(encode_json);

# Test that numbers aren't turned into strings
my $payload = {
    temperature => 0.2,
    top_p => 0.95,
    text => "Hello ❌ world"
};

print "BEFORE sanitization:\n";
print "  temperature type: " . (ref(\$payload->{temperature}) ? 'ref' : 'scalar') . "\n";
print "  temperature value: $payload->{temperature}\n";
print "  JSON: " . encode_json($payload) . "\n\n";

# Sanitize recursively like _sanitize_payload_recursive does
sub sanitize_recursive {
    my ($data) = @_;
    if (!defined $data) {
        return undef;
    } elsif (ref($data) eq 'HASH') {
        my %sanitized;
        for my $key (keys %$data) {
            $sanitized{$key} = sanitize_recursive($data->{$key});
        }
        return \%sanitized;
    } elsif (ref($data) eq 'ARRAY') {
        return [ map { sanitize_recursive($_) } @$data ];
    } elsif (!ref($data)) {
        return sanitize_text($data);
    } else {
        return $data;
    }
}

my $sanitized = sanitize_recursive($payload);

print "AFTER sanitization:\n";
print "  temperature type: " . (ref(\$sanitized->{temperature}) ? 'ref' : 'scalar') . "\n";
print "  temperature value: $sanitized->{temperature}\n";
my $json = encode_json($sanitized);
print "  JSON: $json\n";

# Check if numbers became strings in JSON
if ($json =~ /"temperature":"0\.2"/) {
    print "\nERROR: Numbers became strings!\n";
} elsif ($json =~ /"temperature":0\.2/) {
    print "\nSUCCESS: Numbers are still numbers!\n";
} else {
    print "\nUNKNOWN: Can't determine JSON format\n";
}
