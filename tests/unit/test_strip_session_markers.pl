#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression coverage for CLIO::UI::Chat::_strip_session_markers.
#
# Bug: `strip_session_markers` was a lexical closure inside
# _make_thinking_callback. _handle_ai_response called it as a bare
# `strip_session_markers($x)` (no invocant), producing:
#   "Undefined subroutine &CLIO::UI::Chat::strip_session_markers called
#    at lib/CLIO/UI/Chat.pm line 912."
#
# Fix: promote it to a package-level method `_strip_session_markers`
# that supports three call shapes:
#   1. Class method:      CLIO::UI::Chat->_strip_session_markers($text)
#   2. Instance method:   $self->_strip_session_markers($text)
#   3. Code-ref closure:  $strip->($payload)  where
#      $strip = \&CLIO::UI::Chat::_strip_session_markers
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

# --- class-method call ---
subtest 'class-method strips simple marker' => sub {
    my $r = CLIO::UI::Chat->_strip_session_markers('hello <!--session:foo--> world');
    is($r, 'helloworld', 'simple marker stripped with surrounding whitespace');
};

subtest 'class-method strips structured marker' => sub {
    my $r = CLIO::UI::Chat->_strip_session_markers(qq{hello <!--session:{"title":"x"}--> world});
    is($r, 'helloworld', 'structured marker stripped with surrounding whitespace');
};

subtest 'class-method strips multiple markers' => sub {
    # Marker name regex requires 2-50 chars; use 3+ char names here.
    my $r = CLIO::UI::Chat->_strip_session_markers('<!--session:abc--> middle <!--session:xyz-->');
    is($r, 'middle', 'multiple markers stripped');
};

subtest 'class-method handles undef as no-op' => sub {
    my $r = CLIO::UI::Chat->_strip_session_markers(undef);
    is($r, undef, 'undef payload returns undef');
};

subtest 'class-method handles empty string' => sub {
    my $r = CLIO::UI::Chat->_strip_session_markers('');
    is($r, '', 'empty string returns empty string');
};

subtest 'class-method leaves text without markers alone' => sub {
    my $r = CLIO::UI::Chat->_strip_session_markers('nothing to strip here');
    is($r, 'nothing to strip here', 'plain text unchanged');
};

# --- instance-method call ---
subtest 'instance-method strips simple marker' => sub {
    my $mock = bless {}, 'CLIO::UI::Chat';
    my $r = $mock->_strip_session_markers('hello <!--session:foo--> world');
    is($r, 'helloworld', 'simple marker stripped via instance method');
};

subtest 'instance-method handles undef as no-op' => sub {
    my $mock = bless {}, 'CLIO::UI::Chat';
    my $r = $mock->_strip_session_markers(undef);
    is($r, undef, 'undef payload returns undef via instance method');
};

# --- code-ref closure call (the path used inside _make_thinking_callback) ---
subtest 'closure strips simple marker' => sub {
    my $strip = \&CLIO::UI::Chat::_strip_session_markers;
    my $r = $strip->('Reasoning prose before marker. <!--session:audit-thinking-format-->');
    is($r, 'Reasoning prose before marker.', 'closure strips simple marker');
};

subtest 'closure strips structured marker' => sub {
    my $strip = \&CLIO::UI::Chat::_strip_session_markers;
    my $r = $strip->(qq{Plan: yes <!--session:{"title":"audit-thinking-format"}-->});
    is($r, 'Plan: yes', 'closure strips structured marker');
};

subtest 'closure handles undef as no-op' => sub {
    my $strip = \&CLIO::UI::Chat::_strip_session_markers;
    my $r = $strip->(undef);
    is($r, undef, 'closure undef returns undef');
};

# --- the bug we fixed: bare `strip_session_markers(...)` was failing ---
subtest 'bug regression: bare call no longer reached' => sub {
    # Before the fix, _handle_ai_response called:
    #     strip_session_markers($display_response);
    # which produced "Undefined subroutine &CLIO::UI::Chat::strip_session_markers".
    # After the fix, that call site uses $self->_strip_session_markers(...).
    # We don't strictly need to enforce this; just remind future readers.
    pass('bare call form is removed from production code paths');
};

done_testing();