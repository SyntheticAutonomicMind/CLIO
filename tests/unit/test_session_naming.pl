#!/usr/bin/env perl
# Test session naming: programmatic auto-naming + optional AI marker support
#
# Session naming is now owned by CLIO, not the model. State::auto_name_session()
# derives a name from the first user message after it's saved to history.
# The <!--session:name--> marker is still supported as an optional rename —
# the model may emit it to override the auto-generated name, but it's never
# required.

use strict;
use warnings;
use utf8;
use Test::More;
use lib './lib';

# Test 1: Default system prompt does NOT contain session naming instruction
subtest 'prompt has no session naming instruction' => sub {
    require CLIO::Core::PromptManager;
    my $pm = CLIO::Core::PromptManager->new();
    
    # generate_session_naming_section should no longer exist
    ok(!$pm->can('generate_session_naming_section'), "generate_session_naming_section removed");
    
    # Default prompt content should not contain the session naming instructions
    my $prompt = $pm->_get_default_prompt_content();
    ok($prompt !~ /<!--session:/, "No session marker in default prompt");
    ok($prompt !~ /## Session Naming/, "No Session Naming section in default prompt");
    ok($prompt !~ /CRITICAL: Give every session a meaningful name/, "No naming imperative in default prompt");
};

# Test 2: State::auto_name_session derives name from first user message
subtest 'auto_name_session from first user message' => sub {
    require CLIO::Session::State;
    
    # Build a minimal State with history containing a user message
    my $state = CLIO::Session::State->new(session_id => 'test-auto-name');
    $state->add_message('user', 'fix the session naming bug');
    
    # No name set yet
    ok(!defined($state->session_name()), "No name before auto_name");
    
    my $result = $state->auto_name_session();
    ok($result, "auto_name_session returned true");
    is($state->session_name(), 'Fix the session naming bug', "Name derived from first user message");
};

# Test 3: auto_name_session does NOT overwrite an existing name
subtest 'auto_name_session respects existing name' => sub {
    require CLIO::Session::State;
    my $state = CLIO::Session::State->new(session_id => 'test-existing');
    $state->session_name('existing-name');
    $state->add_message('user', 'some user message');
    
    my $result = $state->auto_name_session();
    is($result, 0, "auto_name_session returned false (name already set)");
    is($state->session_name(), 'existing-name', "Existing name preserved");
};

# Test 4: auto_name_session with no user messages
subtest 'auto_name_session with no user messages' => sub {
    require CLIO::Session::State;
    my $state = CLIO::Session::State->new(session_id => 'test-no-user');
    $state->add_message('system', 'system message');
    
    my $result = $state->auto_name_session();
    ok(!$result, "Returns false with no user messages");
    ok(!defined($state->session_name()), "No name set");
};

# Test 5: _generate_session_name handles edge cases
subtest 'generate_session_name edge cases' => sub {
    require CLIO::Session::State;
    
    # Access the internal function via State's namespace
    my $generate = \&CLIO::Session::State::_generate_session_name;
    
    is($generate->('fix the session naming'), 'Fix the session naming', 'Simple input');
    is($generate->('please fix the bug'), 'Fix the bug', 'Strips filler');
    is($generate->('hi'), undef, 'Too short');
    is($generate->('A very long message that goes on and on and on and on about nothing in particular'), 'A very long message that goes on and on and on and on about...', 'Truncated at 60 chars');
    is($generate->(''), undef, 'Empty string');
    is($generate->('   '), undef, 'Whitespace only');
    is($generate->('hey can you fix this thing please'), 'Can you fix this thing please', 'Strips leading filler only');
};

# Test 6: Marker extraction regex (optional AI rename, used in WorkflowOrchestrator)
subtest 'AI marker extraction (optional rename)' => sub {
    my @tests = (
        {
            input => "Hello world\n<!--session:{\"title\":\"fix session naming\"}-->",
            title => "fix session naming",
            desc  => "basic marker at end",
        },
        {
            input => "No marker here",
            title => undef,
            desc  => "no marker present",
        },
        {
            input => "<!--session:{\"title\":\"ab\"}-->",
            title => undef,
            desc  => "title too short (< 3 chars)",
        },
    );

    for my $t (@tests) {
        my $content = $t->{input};
        my $title = undef;

        if ($content =~ s/\s*<!--session:\{[^}]*"title"\s*:\s*"([^"]{3,80})"[^}]*\}-->\s*//s) {
            $title = $1;
            $title =~ s/^\s+|\s+$//g;
            $title = undef if length($title) < 3;
        }

        if (defined $t->{title}) {
            is($title, $t->{title}, "$t->{desc}: extracted '$t->{title}'");
        } else {
            ok(!defined($title), "$t->{desc}: no title extracted");
        }
    }
};

done_testing();
