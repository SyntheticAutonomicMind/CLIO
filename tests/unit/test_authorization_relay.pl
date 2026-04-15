#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use_ok('CLIO::Security::AuthorizationRelay');

my $relay = CLIO::Security::AuthorizationRelay->new();
ok($relay, 'Constructor works');
is(ref($relay), 'CLIO::Security::AuthorizationRelay', 'Correct class');
ok(!$relay->available(), 'Not available without broker_client');

my $fake1 = bless { socket => undef }, 'FakeBroker';
my $r1 = CLIO::Security::AuthorizationRelay->new(broker_client => $fake1);
ok(!$r1->available(), 'Not available when broker has no socket');

my $fake2 = bless { socket => 1 }, 'FakeBroker';
my $r2 = CLIO::Security::AuthorizationRelay->new(broker_client => $fake2);
ok($r2->available(), 'Available with connected broker');

my $result = $relay->request_authorization(
    category    => 'command_execution',
    description => 'some risky command',
);
ok(!$result->{approved}, 'Denied when no broker');
is($result->{grant_type}, 'denied', 'Grant type is denied');
is($result->{reason}, 'no broker connection', 'Reason correct');

is($relay->{timeout}, 60, 'Default timeout is 60s');
my $r3 = CLIO::Security::AuthorizationRelay->new(timeout => 30);
is($r3->{timeout}, 30, 'Custom timeout stored');

my $analysis = { risk_level => 'high', flags => [{ category => 'system_destructive' }] };
my $cmd_r = $relay->request_command_authorization('echo danger', $analysis, {});
ok(!$cmd_r->{approved}, 'Command auth denied without broker');

my $scan = { risk_level => 'standard', flags => [] };
my $scr_r = $relay->request_script_authorization('/tmp/test.sh', $scan, {});
ok(!$scr_r->{approved}, 'Script auth denied without broker');

my $chk = { flags => [] };
my $url_r = $relay->request_url_authorization('http://example.com', $chk, {});
ok(!$url_r->{approved}, 'URL auth denied without broker');

require CLIO::Coordination::Broker;
my $broker = CLIO::Coordination::Broker->new(session_id => 'test-auth');
ok(exists $broker->{authorization_pending}, 'Broker has auth pending state');
is(ref($broker->{authorization_pending}), 'HASH', 'Auth pending is hash');
ok($broker->can('handle_authorization_request'), 'Broker has auth request handler');
ok($broker->can('handle_authorization_response'), 'Broker has auth response handler');

require CLIO::Coordination::Client;
ok(CLIO::Coordination::Client->can('request_authorization'), 'Client has request_authorization');
ok(CLIO::Coordination::Client->can('send_authorization_response'), 'Client has send_auth_response');

done_testing();
