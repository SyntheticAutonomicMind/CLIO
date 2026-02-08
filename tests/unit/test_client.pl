#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

test_client.pl - Unit tests for Coordination Client

=head1 DESCRIPTION

Tests client module loading and syntax.

=cut

use Test::More;

# Test 1: Module loads
BEGIN { use_ok('CLIO::Coordination::Client') or BAIL_OUT("Cannot load Client"); }

# Test 2: Required modules imported
ok(defined &IO::Socket::UNIX::new, 'IO::Socket::UNIX imported');
ok(defined &JSON::PP::encode_json, 'JSON::PP imported');

# Test 3: Package methods exist
can_ok('CLIO::Coordination::Client', qw(new connect disconnect send_and_wait));
can_ok('CLIO::Coordination::Client', qw(request_file_lock release_file_lock));
can_ok('CLIO::Coordination::Client', qw(send_discovery send_warning get_status));

done_testing();

print "\n✓ Client unit tests PASSED\n";
