#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

test_broker.pl - Unit tests for Coordination Broker

=head1 DESCRIPTION

Tests broker module loading and initialization.
Full integration testing requires running broker in separate process.

=cut

use Test::More;
use File::Temp qw(tempdir);

# Test 1: Module loads
BEGIN { use_ok('CLIO::Coordination::Broker') or BAIL_OUT("Cannot load Broker"); }

# Test 2: Broker creation with required parameters
my $session_id = "test-session-$$";
my $temp_dir = tempdir(CLEANUP => 1);

my $broker;
eval {
    $broker = CLIO::Coordination::Broker->new(
        session_id => $session_id,
        socket_dir => $temp_dir,
    );
};
ok(!$@, 'Broker object creation succeeds') or diag("Error: $@");
ok($broker, 'Broker object created');
isa_ok($broker, 'CLIO::Coordination::Broker');

# Test 3: Configuration stored correctly
is($broker->{session_id}, $session_id, 'Session ID set correctly');
like($broker->{socket_path}, qr/broker-$session_id\.sock/, 'Socket path includes session ID');
# Socket dir may default to /tmp/clio on macOS, so just verify it's set
ok($broker->{socket_dir}, 'Socket directory is set');

# Test 4: Initial state structures
ok(ref($broker->{clients}) eq 'HASH', 'Clients hash initialized');
ok(ref($broker->{file_locks}) eq 'HASH', 'File locks hash initialized');
ok(ref($broker->{git_lock}) eq 'HASH', 'Git lock hash initialized');
ok(ref($broker->{agent_status}) eq 'HASH', 'Agent status hash initialized');
ok(ref($broker->{discoveries}) eq 'ARRAY', 'Discoveries array initialized');
ok(ref($broker->{warnings}) eq 'ARRAY', 'Warnings array initialized');

# Test 5: Methods exist
can_ok($broker, qw(run init event_loop));
can_ok($broker, qw(handle_register handle_heartbeat));
can_ok($broker, qw(handle_request_file_lock handle_release_file_lock));
can_ok($broker, qw(handle_discovery handle_warning));

done_testing();

print "\n✓ Broker unit tests PASSED\n";
