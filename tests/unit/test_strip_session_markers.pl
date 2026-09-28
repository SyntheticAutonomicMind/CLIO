#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression coverage for session-marker stripping.
#
# The canonical regex lives in CLIO::Util::TextSanitizer::strip_session_markers
# (the single source of truth). CLIO::UI::Chat::_strip_session_markers is a
# thin wrapper. StreamingController calls the canonical function directly via
# lazy require.
#
# Bug coverage:
#   1. Original bug: `strip_session_markers` was a lexical closure inside
#      _make_thinking_callback. _handle_ai_response called it as a bare
#      `strip_session_markers($x)` (no invocant), producing:
#        "Undefined subroutine &CLIO::UI::Chat::strip_session_markers called
#         at lib/CLIO/UI/Chat.pm line 912."
#      Fix: promote to package-level method with three call shapes.
#
#   2. Dot-in-name bug: simple-format regex `[a-z0-9_-]{2,50}` rejected dots.
#      Date-version tags like `doc-sync-20260904.1` (documented in AGENTS.md
#      and INSTALLATION.md as the `YYYYMMDD.N` convention) failed to match and
#      leaked into visible output.
#      Fix: include `.` in the character class.
#
# Run: perl -I./lib tests/unit/test_strip_session_markers.pl

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use CLIO::UI::Chat;
use CLIO::Util::TextSanitizer qw(strip_session_markers);

# --- canonical function (single source of truth) ---
subtest 'TextSanitizer::strip_session_markers strips simple marker' => sub {
    my $r = strip_session_markers('hello <!--session:foo--> world');
    is($r, 'helloworld', 'simple marker stripped with surrounding whitespace');
};

subtest 'TextSanitizer::strip_session_markers strips structured marker' => sub {
    my $r = strip_session_markers(qq{hello <!--session:{"title":"x"}--> world});
    is($r, 'helloworld', 'structured marker stripped with surrounding whitespace');
};

subtest 'TextSanitizer::strip_session_markers strips multiple markers' => sub {
    my $r = strip_session_markers('<!--session:abc--> middle <!--session:xyz-->');
    is($r, 'middle', 'multiple markers stripped');
};

subtest 'TextSanitizer::strip_session_markers handles undef as no-op' => sub {
    my $r = strip_session_markers(undef);
    is($r, undef, 'undef payload returns undef');
};

subtest 'TextSanitizer::strip_session_markers handles empty string' => sub {
    my $r = strip_session_markers('');
    is($r, '', 'empty string returns empty string');
};

subtest 'TextSanitizer::strip_session_markers leaves plain text alone' => sub {
    my $r = strip_session_markers('nothing to strip here');
    is($r, 'nothing to strip here', 'plain text unchanged');
};

# --- dot-in-name regression coverage ---
subtest 'dot-in-name regression' => sub {
    my @cases = (
        ['<!--session:doc-sync-20260904.1-->',              '', 'date-version tag'],
        ['hello <!--session:doc-sync-20260904.1--> world',  'helloworld', 'date-version tag with surrounding text'],
        ['<!--session:v3.2.1-->',                           '', 'semver-like'],
        ['work <!--session:fix.1.bug--> done',              'workdone', 'dotted tokens mid-name'],
        ['<!--session:a.b.c.d.e.f.g-->',                    '', 'many dots'],
    );
    for my $c (@cases) {
        is(strip_session_markers($c->[0]), $c->[1], $c->[2]);
    }
};

# --- characters that should NOT match ---
subtest 'rejects non-conforming names' => sub {
    my @cases = (
        ['<!--session:A-->',          'uppercase first letter'],
        ['<!--session:1abc-->',       'starts with digit'],
        ['<!--session:ab-->',         'too short (2 chars)'],
        ['<!--session:-->',           'empty name'],
        ['<!--session:foo bar-->',    'spaces in name'],
        ['<!--session:foo/bar-->',    'slash in name'],
        ['look <!-- not a session --> here', 'random HTML comment'],
    );
    for my $c (@cases) {
        is(strip_session_markers($c->[0]), $c->[0], "preserves: $c->[1]");
    }
};

# --- Newline preservation around session markers ---
# Regression: strip_session_markers used \s* around markers, which matches
# \n and collapses paragraph breaks in thinking output.  The fix uses
# [ \t]* so only spaces/tabs are consumed, preserving newlines.
subtest 'strip_session_markers preserves newlines around markers' => sub {
    # Marker on its own line between paragraphs
    my $r = strip_session_markers("First para\n<!--session:foo-->\nSecond para\n");
    like($r, qr/^First para\n\nSecond para\n$/,
        'paragraph breaks preserved when marker is on own line');

    # Structured marker on its own line
    my $r2 = strip_session_markers("Para one\n<!--session:{\"title\":\"x\"}-->\nPara two\n");
    like($r2, qr/^Para one\n\nPara two\n$/,
        'structured marker on own line preserves paragraph breaks');

    # Marker at end of line with content before it
    my $r3 = strip_session_markers("Some text <!--session:foo-->\nMore text\n");
    like($r3, qr/^Some text\nMore text\n$/,
        'marker at end of line preserves the following newline');

    # Multiple markers, each on own line
    my $r4 = strip_session_markers("A\n<!--session:foo-->\nB\n<!--session:bar-->\nC\n");
    like($r4, qr/^A\n\nB\n\nC\n$/,
        'multiple markers on own lines preserve all paragraph breaks');
};

# --- Chat wrapper still works (three call shapes) ---
subtest 'Chat::_strip_session_markers class method' => sub {
    my $r = CLIO::UI::Chat->_strip_session_markers('hello <!--session:foo--> world');
    is($r, 'helloworld', 'class-method strips simple marker');
};

subtest 'Chat::_strip_session_markers structured via class method' => sub {
    my $r = CLIO::UI::Chat->_strip_session_markers(qq{hello <!--session:{"title":"x"}--> world});
    is($r, 'helloworld', 'class-method strips structured marker');
};

subtest 'Chat::_strip_session_markers instance method' => sub {
    my $mock = bless {}, 'CLIO::UI::Chat';
    my $r = $mock->_strip_session_markers('hello <!--session:foo--> world');
    is($r, 'helloworld', 'instance method strips simple marker');
};

subtest 'Chat::_strip_session_markers instance method handles undef' => sub {
    my $mock = bless {}, 'CLIO::UI::Chat';
    my $r = $mock->_strip_session_markers(undef);
    is($r, undef, 'undef returns undef via instance method');
};

subtest 'Chat::_strip_session_markers code-ref closure (simple)' => sub {
    my $strip = \&CLIO::UI::Chat::_strip_session_markers;
    my $r = $strip->('Reasoning prose before marker. <!--session:audit-thinking-format-->');
    is($r, 'Reasoning prose before marker.', 'closure strips simple marker');
};

subtest 'Chat::_strip_session_markers code-ref closure (structured)' => sub {
    my $strip = \&CLIO::UI::Chat::_strip_session_markers;
    my $r = $strip->(qq{Plan: yes <!--session:{"title":"audit-thinking-format"}-->});
    is($r, 'Plan: yes', 'closure strips structured marker');
};

subtest 'Chat::_strip_session_markers code-ref closure handles undef' => sub {
    my $strip = \&CLIO::UI::Chat::_strip_session_markers;
    my $r = $strip->(undef);
    is($r, undef, 'closure undef returns undef');
};

# --- delegation parity: Chat wrapper must produce same output as canonical ---
subtest 'Chat wrapper delegates identically to TextSanitizer' => sub {
    my @inputs = (
        '<!--session:foo-->',
        '<!--session:doc-sync-20260904.1-->',
        'hello <!--session:abc--> middle <!--session:{"title":"x"}--> world',
        'no markers here',
        '',
        '<!--session:too.short-->',
    );
    for my $input (@inputs) {
        is(CLIO::UI::Chat->_strip_session_markers($input),
           strip_session_markers($input),
           "parity for: $input");
    }
};

done_testing();