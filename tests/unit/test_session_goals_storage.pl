#!/usr/bin/env perl
# Tests for Session::State session_goals storage
#
# Verifies that session goals are stored in session state (not a separate
# file), making them:
# - Race-free across concurrent sessions
# - Always visible to PromptBuilder::user_context (no loading step)
# - Surviving context trims
# - Persisting across --resume

use strict;
use warnings;
use utf8;

use CLIO::Session::State;
use CLIO::Util::JSON qw(encode_json decode_json);

sub make_state {
    my $state = CLIO::Session::State->new(
        session_id => 'test-' . int(rand(100000)),
        working_directory => '/tmp',
    );
    return $state;
}

# Test 1: new state has empty session_goals
{
    my $state = make_state();
    my $goals = $state->session_goals();
    if (ref($goals) eq 'ARRAY' && scalar(@$goals) == 0) {
        print "ok 1 - new state has empty session_goals arrayref\n";
    } else {
        print "not ok 1 - new state session_goals not empty arrayref\n";
    }
}

# Test 2: set_session_goals stores goals
{
    my $state = make_state();
    my $goals = [
        { id => 1, title => 'Test goal', description => 'A test', status => 'active', created_at => 1234 },
        { id => 2, title => 'Done', status => 'completed', created_at => 1235 },
    ];
    $state->set_session_goals($goals);

    my $retrieved = $state->session_goals();
    if (scalar(@$retrieved) == 2 && $retrieved->[0]{title} eq 'Test goal') {
        print "ok 2 - set_session_goals + session_goals roundtrip works\n";
    } else {
        print "not ok 2 - set/get roundtrip failed\n";
    }
}

# Test 3: get_session_goals returns same as session_goals
{
    my $state = make_state();
    my $goals = [{ id => 1, title => 'Goal', status => 'active' }];
    $state->set_session_goals($goals);

    my $a = $state->session_goals();
    my $b = $state->get_session_goals();

    if (ref($a) eq 'ARRAY' && ref($b) eq 'ARRAY' && scalar(@$a) == scalar(@$b)) {
        print "ok 3 - session_goals and get_session_goals are equivalent\n";
    } else {
        print "not ok 3 - session_goals and get_session_goals differ\n";
    }
}

# Test 4: set_session_goals with undef clears goals
{
    my $state = make_state();
    $state->set_session_goals([{ id => 1, title => 'X', status => 'active' }]);
    $state->set_session_goals(undef);

    my $goals = $state->session_goals();
    if (ref($goals) eq 'ARRAY' && scalar(@$goals) == 0) {
        print "ok 4 - set_session_goals(undef) clears goals\n";
    } else {
        print "not ok 4 - set_session_goals(undef) didn't clear\n";
    }
}

# Test 5: session_goals survives JSON serialization
{
    my $state = make_state();
    my $goals = [
        { id => 1, title => 'Important goal', description => 'Survives trim', status => 'active', created_at => 999 },
    ];
    $state->set_session_goals($goals);

    my $serialized = encode_json({ session_goals => $state->session_goals() });
    my $loaded_data = decode_json($serialized);

    if (ref($loaded_data->{session_goals}) eq 'ARRAY'
        && $loaded_data->{session_goals}[0]{title} eq 'Important goal') {
        print "ok 5 - session_goals survive JSON serialization\n";
    } else {
        print "not ok 5 - session_goals did not survive serialization\n";
    }
}

print "1..5\n";