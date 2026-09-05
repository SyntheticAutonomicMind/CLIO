#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression coverage for session naming after the move from
# prompt-instructed marker naming to programmatic naming.
#
# Coverage:
#   1. System prompt no longer asks the model to emit a marker.
#   2. _generate_session_name (now in Session::State) extracts
#      sensible titles from first user messages.
#   3. Session::State::auto_name_session fires after the first user
#      message and is idempotent (won't overwrite an existing name).
#   4. _extract_session_marker still works for the user-typed rename
#      affordance, including dotted date-version tags.

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;

# Test 1: PromptBuilder no longer asks the model to emit markers
subtest 'system prompt has no session-marker instruction' => sub {
    require CLIO::Core::PromptBuilder;
    require CLIO::Tools::Registry;

    my $registry = CLIO::Tools::Registry->new(debug => 0);
    my $builder = CLIO::Core::PromptBuilder->new(
        skip_custom   => 1,
        skip_ltm      => 1,
        tool_registry => $registry,
    );
    my $prompt = $builder->build_system_prompt();

    unlike($prompt, qr/<!--session:/,
        'system prompt does not instruct the model to emit a session marker');
    unlike($prompt, qr/## Session Naming/,
        'system prompt no longer contains the Session Naming section');
    unlike($prompt, qr/give every session a meaningful name/i,
        'system prompt no longer contains the Session Naming imperative');
};

# Test 2: _generate_session_name heuristic
subtest '_generate_session_name produces sensible titles' => sub {
    require CLIO::Session::State;

    my @cases = (
        ['fix the session naming',         'Fix the session naming',  'capitalizes + preserves'],
        ['please fix the bug',             'Fix the bug',             'strips conversational filler'],
        ['can you help with this',         'Help with this',          'strips "can you" filler'],
        ['hey can you help with this',     'Can you help with this',  'strips leading filler only (single-pass)'],
        ['hi',                             undef,                     'too short after cleanup'],
        ['',                               undef,                     'empty input'],
        ['   whitespace   around   ',      'Whitespace around',       'collapses whitespace'],
        ['update Chat.pm regex',           'Update Chat.pm regex',    'preserves dots'],
        ['release v3.2.1',                 'Release v3.2.1',          'preserves semver-style dots'],
    );
    for my $c (@cases) {
        is(CLIO::Session::State::_generate_session_name($c->[0]),
           $c->[1], $c->[2]);
    }
};

# Test 3: auto_name_session fires on first user message
subtest 'auto_name_session derives name from first user message' => sub {
    require CLIO::Session::State;
    my $state = CLIO::Session::State->new(session_id => 'test-2');

    # No name and no history -> no-op.
    ok(!defined $state->auto_name_session(),
        'returns undef when there is no history');

    # Add a user message and trigger auto-name.
    $state->add_message('user', 'fix the auth flow');
    my $name = $state->auto_name_session();
    is($name, 'Fix the auth flow', 'auto-named from first user input');
    is($state->session_name(), 'Fix the auth flow', 'name persisted on state');

    # Idempotent: a second call must NOT overwrite.
    $state->add_message('user', 'a totally different second message');
    is($state->auto_name_session(), 'Fix the auth flow',
        'subsequent calls do not overwrite the existing name');
    is($state->session_name(), 'Fix the auth flow',
        'name still set after idempotent call');

    # User-set names are preserved.
    $state->session_name('my-custom-name');
    is($state->auto_name_session(), 'my-custom-name',
        'auto_name_session preserves a user-set name');
};

# Test 4: _extract_session_marker regex covers dotted names
subtest 'marker extraction regex covers dotted names' => sub {
    my @cases = (
        {
            input => "Hello world\n<!--session:{\"title\":\"fix session naming\"}-->",
            title => "fix session naming",
            desc  => "structured form",
        },
        {
            input => "Response text\n<!--session:doc-sync-20260904.1-->\n",
            title => "doc-sync-20260904.1",
            desc  => "simple form with date-version tag",
        },
        {
            input => "Plan: yes <!--session:debug-api-auth-->",
            title => "debug-api-auth",
            desc  => "simple form mid-line",
        },
        {
            input => "No marker here",
            title => undef,
            desc  => "no marker present",
        },
        {
            input => "<!--session:{\"title\":\"ab\"}-->",
            title => undef,
            desc  => "structured title too short (< 3 chars)",
        },
        {
            input => "<!--session:ab-->",
            title => undef,
            desc  => "simple name too short (< 3 chars)",
        },
        {
            input => "<!--session:A.B-->",
            title => "A.B",
            desc  => "simple form is case-insensitive (allows mixed case)",
        },
    );

    for my $t (@cases) {
        my $content = $t->{input};
        my $title;
        if ($content =~ s/\s*<!--session:\{[^}]*"title"\s*:\s*"([^"]{3,80})"[^}]*\}-->\s*//s) {
            $title = $1;
            $title =~ s/^\s+|\s+$//g;
            $title = undef if length($title) < 3;
        } elsif ($content =~ s/\s*<!--session:([a-z][a-z0-9._-]{2,50})-->\s*//si) {
            $title = $1;
            $title =~ s/^\s+|\s+$//g;
            $title = undef if length($title) < 3;
        }
        if (defined $t->{title}) {
            is($title, $t->{title}, "$t->{desc}: extracted '$t->{title}'");
        } else {
            ok(!defined $title, "$t->{desc}: no title extracted");
        }
    }
};

# Test 5: Content cleanup after marker extraction
subtest 'content cleanup after extraction' => sub {
    my $content = "Here is my response.\n\n<!--session:{\"title\":\"session naming feature\"}-->\n";

    $content =~ s/\s*<!--session:\{[^}]*"title"\s*:\s*"([^"]{3,80})"[^}]*\}-->\s*//s;
    my $title = $1;

    is($title, "session naming feature", "Title extracted correctly");
    unlike($content, qr/<!--session:/, "Marker removed from content");
    like($content, qr/Here is my response/, "Original content preserved");
};

done_testing();