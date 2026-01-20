#!/usr/bin/env perl
use strict;
use warnings;
use lib 'lib';
use Data::Dumper;

# Set up minimal test
$ENV{OPENAI_API_KEY} = $ENV{OPENAI_API_KEY} || die "Need OPENAI_API_KEY";
$ENV{OPENAI_API_BASE} = 'https://api.githubcopilot.com';
$ENV{OPENAI_MODEL} = 'gpt-4o';

use CLIO::Core::APIManager;
use CLIO::Session::Manager;

# Create session
my $session = CLIO::Session::Manager->create(debug => 1);
print "Session created: " . $session->{session_id} . "\n";

# Create API manager with session
my $api = CLIO::Core::APIManager->new(
    debug => 1,
    session => $session->state()
);
print "API Manager created\n";

# Try a simple request
my $messages = [
    { role => 'user', content => 'Hi, can you hear me?' }
];

print "\nSending request...\n";
my $result = $api->send_request('', messages => $messages);

print "\nResult:\n";
print Dumper($result);

if ($result->{error}) {
    print "\nERROR: $result->{message}\n";
} else {
    print "\nSUCCESS: Got response\n";
    print "Content: " . ($result->{content} || 'no content') . "\n";
}
