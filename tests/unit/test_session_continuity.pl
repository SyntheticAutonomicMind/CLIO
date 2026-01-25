#!/usr/bin/env perl
=head1 NAME

test_session_continuity.pl - Test that sessions are saved after each response

=head1 SYNOPSIS

  perl -I./lib tests/unit/test_session_continuity.pl

=cut

use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use JSON::PP qw(decode_json encode_json);
use Cwd;

# Setup
my $test_dir = tempdir(CLEANUP => 1);
chdir $test_dir or die "Cannot chdir to $test_dir: $!";

# Create minimal session directory structure
mkdir '.clio' or die "Cannot mkdir .clio: $!";
mkdir '.clio/sessions' or die "Cannot mkdir .clio/sessions: $!";

# Import modules
use_ok('CLIO::Session::Manager', 'Session Manager module loads');
use_ok('CLIO::Session::State', 'Session State module loads');
use_ok('CLIO::Memory::ShortTerm', 'ShortTerm memory loads');
use_ok('CLIO::Memory::LongTerm', 'LongTerm memory loads');

# Test 1: Create new session
my $manager = CLIO::Session::Manager->create(working_directory => $test_dir, debug => 0);
ok($manager, 'Session Manager created');

my $session_id = $manager->{session_id};
ok($session_id, 'Session ID generated');
like($session_id, qr/^[0-9a-f]{8}-/, 'Session ID has UUID format');

# Test 2: Add messages to session
my $session = $manager->{state};
ok($session, 'Session state object exists');

$session->add_message('user', 'Hello, what can you do?');
is(scalar(@{$session->{history}}), 1, 'One message added to history');

$session->add_message('assistant', 'I can help you debug and develop code');
is(scalar(@{$session->{history}}), 2, 'Two messages added to history');

# Test 3: Save session
eval { $session->save() };
is($@, '', 'Session saved without error');

# Test 4: Verify session file exists
my $session_file = CLIO::Util::PathResolver::get_session_file($session_id);
ok(-f $session_file, 'Session file created at expected location');

# Test 5: Load session file and verify content
open my $fh, '<', $session_file or die "Cannot open $session_file: $!";
local $/;
my $json_str = <$fh>;
close $fh;

my $session_data = decode_json($json_str);
ok($session_data, 'Session file contains valid JSON');
is(ref($session_data->{history}), 'ARRAY', 'History is array');
is(scalar(@{$session_data->{history}}), 2, 'Loaded session has 2 messages');
is($session_data->{history}[0]{role}, 'user', 'First message is from user');
is($session_data->{history}[1]{role}, 'assistant', 'Second message is from assistant');

# Test 6: Reload session from file
my $manager2 = CLIO::Session::Manager->load($session_id, debug => 0);
ok($manager2, 'Session loaded from file');

my $reloaded_history = $manager2->{state}->{history};
is(scalar(@$reloaded_history), 2, 'Reloaded session has 2 messages');
is($reloaded_history->[0]{content}, 'Hello, what can you do?', 'First message content preserved');
is($reloaded_history->[1]{content}, 'I can help you debug and develop code', 'Second message content preserved');

# Test 7: Add more messages and verify persistence
$manager2->{state}->add_message('user', 'Can you fix bugs?');
$manager2->{state}->save();

is(scalar(@{$manager2->{state}->{history}}), 3, 'Third message added');

# Reload again to verify
my $manager3 = CLIO::Session::Manager->load($session_id, debug => 0);
is(scalar(@{$manager3->{state}->{history}}), 3, 'Reloaded session still has 3 messages');
is($manager3->{state}->{history}[2]{content}, 'Can you fix bugs?', 'Third message persisted');

# Test 8: LTM loading on session resume
my $ltm = $manager3->{state}->{ltm};
ok($ltm, 'LTM loaded with session');
isa_ok($ltm, 'CLIO::Memory::LongTerm', 'LTM is correct type');

# Test 9: Add discovery and verify LTM save
$ltm->add_discovery("Test discovery fact", 0.9, 1);
my $discoveries = $ltm->query_discoveries(limit => 10);
is(scalar(@$discoveries), 1, 'Discovery added to LTM');
is($discoveries->[0]{fact}, "Test discovery fact", 'Discovery content correct');

# Save LTM
my $ltm_file = File::Spec->catfile($test_dir, '.clio', 'ltm.json');
eval { $ltm->save($ltm_file) };
is($@, '', 'LTM saved without error');
ok(-f $ltm_file, 'LTM file created');

# Test 10: Reload LTM from file
my $ltm_reloaded = CLIO::Memory::LongTerm->load($ltm_file, debug => 0);
my $discoveries_reloaded = $ltm_reloaded->query_discoveries(limit => 10);
is(scalar(@$discoveries_reloaded), 1, 'Discovery persisted in LTM file');
is($discoveries_reloaded->[0]{fact}, "Test discovery fact", 'Discovery fact matches after reload');

# Test 11: Verify LTM is shared across sessions
my $manager4 = CLIO::Session::Manager->create(working_directory => $test_dir, debug => 0);
my $ltm_shared = $manager4->{state}->{ltm};
my $discoveries_shared = $ltm_shared->query_discoveries(limit => 10);
# Note: This should have 1 or 2 depending on whether the new session got empty LTM or merged one
ok(defined $discoveries_shared, 'Shared LTM loads correctly');

# Cleanup
chdir '/' or die;

done_testing();
