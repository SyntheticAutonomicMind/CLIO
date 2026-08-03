#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Tests for CLIO::Core::Interrupt - central interrupt detection.

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More tests => 29;

# Force a non-TTY environment so the helpers never try to read from STDIN.
BEGIN {
    if (open my $devnull, '<', '/dev/null') {
        close STDIN;
        open(STDIN, '<&', $devnull) or die "Cannot dup /dev/null over STDIN: $!";
    }
}

use CLIO::Core::Interrupt;

# Helper: build a stub session that exposes state() and save().
sub _make_stub_session {
    my $s = bless { _state => { user_interrupted => 0 }, _save_count => 0 }, 'StubSession';
    no strict 'refs';
    *{"StubSession::state"} = sub { $_[0]->{_state} };
    *{"StubSession::save"} = sub { $_[0]->{_save_count}++ };
    return $s;
}

# --- pending() before any set ---
{
    my $s = _make_stub_session();

    ok(!CLIO::Core::Interrupt::pending(session => $s),
        'pending() returns 0 when no interrupt set');

    CLIO::Core::Interrupt::set(session => $s, reason => 'test set');
    ok(CLIO::Core::Interrupt::pending(session => $s),
        'pending() returns 1 after set()');
    is($s->{_save_count}, 1, 'set() calls save() once');

    CLIO::Core::Interrupt::clear(session => $s);
    ok(!CLIO::Core::Interrupt::pending(session => $s),
        'pending() returns 0 after clear()');

    CLIO::Core::Interrupt::clear(session => $s);
    ok(!CLIO::Core::Interrupt::pending(session => $s),
        'clear() is idempotent');
}

# --- pending() / check() with no session ---
{
    ok(!CLIO::Core::Interrupt::pending(),
        'pending() with no session returns 0');
    ok(!CLIO::Core::Interrupt::check(),
        'check() with no session returns 0 (no TTY)');
}

# --- is_alrm_handler_active() ---
{
    ok(!CLIO::Core::Interrupt::is_alrm_handler_active(),
        'ALRM handler is not active by default');
    CLIO::Core::Interrupt::uninstall_alrm_handler();
    ok(!CLIO::Core::Interrupt::is_alrm_handler_active(),
        'uninstall on inactive handler is a no-op');
}

# --- install + uninstall ALRM handler ---
{
    my $s = _make_stub_session();

    CLIO::Core::Interrupt::install_alrm_handler(session => $s, interval => 0.05);
    ok(CLIO::Core::Interrupt::is_alrm_handler_active(),
        'ALRM handler is active after install');

    CLIO::Core::Interrupt::install_alrm_handler(session => $s, interval => 0.1);
    ok(CLIO::Core::Interrupt::is_alrm_handler_active(),
        'ALRM handler remains active after re-install');

    ok(!$s->{_state}{user_interrupted},
        'user_interrupted flag is 0 with no keypress');

    CLIO::Core::Interrupt::uninstall_alrm_handler();
    ok(!CLIO::Core::Interrupt::is_alrm_handler_active(),
        'ALRM handler is inactive after uninstall');
}

# --- check() in non-TTY context returns 0 (no I/O happens) ---
{
    my $result = CLIO::Core::Interrupt::check();
    ok(!$result, 'check() returns 0 in non-TTY environment');
}

# --- Constants are reasonable ---
{
    require CLIO::Core::WorkflowOrchestrator;
    ok(CLIO::Core::WorkflowOrchestrator::INTERRUPT_ALRM_INTERVAL() > 0,
        'INTERRUPT_ALRM_INTERVAL is positive');
    ok(CLIO::Core::WorkflowOrchestrator::INTERRUPT_ALRM_INTERVAL() <= 1,
        'INTERRUPT_ALRM_INTERVAL is <= 1 second (sub-second latency)');
    ok(CLIO::Core::WorkflowOrchestrator::INTERRUPT_POLL_INTERVAL_MS() > 0,
        'INTERRUPT_POLL_INTERVAL_MS is positive');
}

# --- Check_interrupt helper on Tool.pm ---
{
    require CLIO::Tools::Tool;
    my $tool = CLIO::Tools::Tool->new(
        name => 'test_tool',
        description => 'unit test tool',
        supported_operations => ['noop'],
    );
    ok($tool->can('check_interrupt'),
        'Tool base class exposes check_interrupt method');

    # The tool's check_interrupt looks for the session inside the
    # context hash. Real callers pass $context = { session => $session,
    # ... }. Mirror that shape for the unit test.
    my $session = _make_stub_session();
    my $ctx = { session => $session };
    ok(!$tool->check_interrupt($ctx),
        'check_interrupt returns 0 when no interrupt set');

    CLIO::Core::Interrupt::set(session => $session);
    ok($tool->check_interrupt($ctx),
        'check_interrupt returns 1 after Interrupt::set()');
    CLIO::Core::Interrupt::clear(session => $session);
}

# --- with_alrm_handler wrapper installs and cleans up ---
{
    my $s = _make_stub_session();

    ok(!CLIO::Core::Interrupt::is_alrm_handler_active(),
        'precondition: ALRM inactive');

    my $ran = 0;
    CLIO::Core::Interrupt::with_alrm_handler(
        session => $s, interval => 0.05, code => sub {
            $ran++;
            ok(CLIO::Core::Interrupt::is_alrm_handler_active(),
                'ALRM active inside with_alrm_handler block');
            return 'result_value';
        });
    is($ran, 1, 'with_alrm_handler ran the code once');
    ok(!CLIO::Core::Interrupt::is_alrm_handler_active(),
        'ALRM cleaned up after with_alrm_handler');
}

# --- with_alrm_handler re-raises exceptions but still cleans up ---
{
    my $s = _make_stub_session();

    eval {
        CLIO::Core::Interrupt::with_alrm_handler(
            session => $s, interval => 0.05, code => sub {
                die "boom\n";
            });
    };
    like($@, qr/boom/, 'with_alrm_handler re-raises die from code');
    ok(!CLIO::Core::Interrupt::is_alrm_handler_active(),
        'ALRM cleaned up even after code died');
}

# --- set() persists the state correctly via the session ---
{
    my $s = _make_stub_session();

    CLIO::Core::Interrupt::set(session => $s, reason => 'persistence test');
    is($s->{_state}{user_interrupted}, 1,
        'set() persists user_interrupted flag to session state');
    is($s->{_save_count}, 1, 'set() called save() once on the session');

    CLIO::Core::Interrupt::clear(session => $s);
    is($s->{_state}{user_interrupted}, 0,
        'clear() resets user_interrupted flag in session state');
}

# --- Module-level cleanup ---
END {
    CLIO::Core::Interrupt::uninstall_alrm_handler();
}
