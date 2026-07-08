#!/usr/bin/env perl
# Test that all four reasoning/thinking metadata fields persist through
# Session::State::add_message and survive a load/save round-trip.
#
# Background: thinking_content, reasoning_details, reasoning_blocks, and
# responses_reasoning_items were all being attached to assistant messages
# during API responses, but State.pm was only persisting reasoning_content.
# Anthropic/Google replay reasoning_blocks on subsequent turns; OpenAI
# Responses uses responses_reasoning_items for native chaining. Without
# persistence, providers restart reasoning from scratch each turn.
use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

use Test::More;
use CLIO::Session::State;
use CLIO::Memory::LongTerm;
use CLIO::Memory::ShortTerm;
use CLIO::Memory::YaRN;
use CLIO::Util::JSON qw(decode_json);
use File::Temp qw(tempdir);

my $tmpdir = tempdir(CLEANUP => 1);
my $state_file = "$tmpdir/session.json";

my $ltm  = CLIO::Memory::LongTerm->new();
my $stm  = CLIO::Memory::ShortTerm->new();
my $yarn = CLIO::Memory::YaRN->new();

my $state = CLIO::Session::State->new(
    file              => $state_file,
    session_id        => 'test-reasoning-001',
    working_directory => $tmpdir,
    ltm               => $ltm,
    stm               => $stm,
    yarn              => $yarn,
);

# --- 1. reasoning_content persists ---
$state->add_message('assistant', 'first turn answer', {
    reasoning_content => 'I should think about this carefully...',
});

my $history = $state->{history};
is($history->[-1]{reasoning_content},
   'I should think about this carefully...',
   'reasoning_content persisted on message');

# --- 2. reasoning_details persists (OpenAI Chat Completions format) ---
my $details = [
    { type => 'reasoning.text', text => 'thinking step 1', index => 0 },
    { type => 'reasoning.summary', summary => 'condensed step 1', index => 0 },
];
$state->add_message('assistant', 'second turn answer', {
    reasoning_details => $details,
});

$history = $state->{history};
is_deeply($history->[-1]{reasoning_details}, $details,
          'reasoning_details persisted (arrayref preserved)');

# --- 3. reasoning_blocks persists (Anthropic extended thinking format) ---
my $blocks = [
    { type => 'thinking', thinking => 'Anthropic-style thinking', signature => 'sig-abc' },
];
$state->add_message('assistant', 'third turn answer', {
    reasoning_blocks => $blocks,
});

$history = $state->{history};
is_deeply($history->[-1]{reasoning_blocks}, $blocks,
          'reasoning_blocks persisted (arrayref preserved)');

# --- 4. responses_reasoning_items persists (OpenAI Responses API format) ---
my $rri = [
    { type => 'reasoning', id => 'rs_abc123', summary => [{ type => 'summary_text', text => 'a' }] },
];
$state->add_message('assistant', 'fourth turn answer', {
    responses_reasoning_items => $rri,
});

$history = $state->{history};
is_deeply($history->[-1]{responses_reasoning_items}, $rri,
          'responses_reasoning_items persisted (arrayref preserved)');

# --- 5. all four on the same message ---
my $all_four = {
    reasoning_content  => 'inline thinking',
    reasoning_details  => [ { type => 'reasoning.text', text => 'detail' } ],
    reasoning_blocks   => [ { type => 'thinking', thinking => 'block' } ],
    responses_reasoning_items => [ { type => 'reasoning', id => 'rs_xyz' } ],
};
$state->add_message('assistant', 'all four', $all_four);

$history = $state->{history};
is($history->[-1]{reasoning_content},  'inline thinking',                 'all-four: reasoning_content');
is_deeply($history->[-1]{reasoning_details},  $all_four->{reasoning_details},  'all-four: reasoning_details');
is_deeply($history->[-1]{reasoning_blocks},   $all_four->{reasoning_blocks},   'all-four: reasoning_blocks');
is_deeply($history->[-1]{responses_reasoning_items}, $all_four->{responses_reasoning_items}, 'all-four: responses_reasoning_items');

# --- 6. save+load round-trip preserves everything ---
# --- 6. save+load round-trip preserves everything ---
# Note: State.pm derives its save path from session_id via _session_file(),
# so the round-trip uses the canonical sessions dir and we clean up after.
$state->save();

# Locate the file that save() actually wrote
my $saved_file = CLIO::Util::PathResolver::get_session_file('test-reasoning-001');
ok(-e $saved_file, "save() wrote to $saved_file");

open my $fh, '<:raw', $saved_file or die "Cannot read $saved_file: $!";
my $raw = do { local $/; <$fh> };
close $fh;
my $persisted = decode_json($raw);

my @msgs = @{$persisted->{history}};
is(scalar @msgs, 5, 'all 5 messages persisted to disk');

# Last message must contain all four fields
my $last = $msgs[-1];
is($last->{reasoning_content}, 'inline thinking',         'round-trip: reasoning_content');
is_deeply($last->{reasoning_details}, $all_four->{reasoning_details}, 'round-trip: reasoning_details');
is_deeply($last->{reasoning_blocks},  $all_four->{reasoning_blocks},  'round-trip: reasoning_blocks');
is_deeply($last->{responses_reasoning_items}, $all_four->{responses_reasoning_items}, 'round-trip: responses_reasoning_items');

# --- 7. load() back into a fresh State object recovers the fields ---
my $ltm2  = CLIO::Memory::LongTerm->new();
my $stm2  = CLIO::Memory::ShortTerm->new();
my $yarn2 = CLIO::Memory::YaRN->new();

my $state2 = CLIO::Session::State->new(
    session_id        => 'test-reasoning-001',
    working_directory => $tmpdir,
    ltm               => $ltm2,
    stm               => $stm2,
    yarn              => $yarn2,
);
# State::load is a class method that returns a fully populated State.
my $state2_loaded = CLIO::Session::State->load(
    'test-reasoning-001',
    working_directory => $tmpdir,
);
ok(defined $state2_loaded, 'load() returned a defined object');

my $reloaded = $state2_loaded->{history};
is_deeply($reloaded->[-1]{reasoning_details}, $all_four->{reasoning_details},
          'reloaded reasoning_details matches');
is_deeply($reloaded->[-1]{reasoning_blocks},  $all_four->{reasoning_blocks},
          'reloaded reasoning_blocks matches');
is_deeply($reloaded->[-1]{responses_reasoning_items}, $all_four->{responses_reasoning_items},
          'reloaded responses_reasoning_items matches');
is($reloaded->[-1]{reasoning_content}, 'inline thinking',
   'reloaded reasoning_content matches');

# Cleanup: remove the test session file from the canonical sessions dir
unlink $saved_file;

# --- 8. opts that are not arrayrefs are silently ignored (defense) ---
$state->add_message('assistant', 'malformed input', {
    reasoning_details => 'not-an-arrayref',  # should be skipped, not crash
});
$history = $state->{history};
ok(!exists $history->[-1]{reasoning_details},
   'scalar reasoning_details is ignored (defense in depth)');

done_testing();
