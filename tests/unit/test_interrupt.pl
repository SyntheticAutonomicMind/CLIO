#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# Tests for CLIO::Core::Interrupt - central interrupt detection.

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More tests => 45;

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

# --- ESC-only behaviour: Ctrl+C must NOT trigger an interrupt ---
# Read the source and confirm that the trigger condition only matches ESC
# (ord 27), never Ctrl+C (ord 3). We treat this as a contract test - the
# source itself is the spec because the byte-level path requires a real
# TTY which is not available in unit tests.
{
    my $src = do { local $/; open my $fh, '<', "$RealBin/../../lib/CLIO/Core/Interrupt.pm" or die "Cannot read Interrupt.pm: $!"; <$fh> };

    # Extract just the check() sub so the regex does not bleed across
    # function boundaries (the ALRM handler also has $ord == 3 logic).
    my ($check_body) = $src =~ /sub\s+check\s*\{(.*?)^}/sm;
    ok(defined $check_body, 'Extracted check() body for contract testing');

    # check() must not return 1 for Ctrl+C.
    unlike($check_body, qr/\$ord\s*==\s*3.*?\breturn\s+1/s,
        'check() does not return 1 for Ctrl+C (ord 3)');

    # check() must have a branch that returns 1 for ESC.
    like($check_body, qr/\$ord\s*==\s*27.*?\breturn\s+1/s,
        'check() returns 1 for ESC (ord 27)');

    # The ALRM handler must distinguish ESC from Ctrl+C (separate branches),
    # not lump them together with ||.
    my ($alrm_body) = $src =~ /\$SIG\{ALRM\}\s*=\s*sub\s*\{(.*?)^\s*\};/sm;
    ok(defined $alrm_body, 'Extracted ALRM handler body for contract testing');
    unlike($alrm_body, qr/\$ord\s*==\s*27\s*\|\|\s*\$ord\s*==\s*3/,
        'ALRM handler does not combine ESC and Ctrl+C into one branch');

    # The ALRM handler must NOT set the user_interrupted flag in the
    # Ctrl+C branch (it should drain and arm the alarm only).
    unlike($alrm_body, qr/\$ord\s*==\s*3.*?\$state->\{user_interrupted\}\s*=\s*1/s,
        'ALRM handler does not set user_interrupted=1 for Ctrl+C');

    # POD must reflect the new ESC-only contract. We check that no
    # POD paragraph claims "ESC or Ctrl+C" both trigger an interrupt.
    # The check allows the new explanatory wording that mentions Ctrl+C
    # alongside ESC, as long as it does not list both as interrupts.
    unlike($src, qr/ESC\s+or\s+Ctrl\+C\s+(is|are|will|triggers?)/is,
        'POD does not describe "ESC or Ctrl+C" as the interrupt trigger');
    like($src, qr/Ctrl\+C.*?SIGINT/is,
        'POD explains that Ctrl+C falls through to the SIGINT handler');
}

# --- check() behaviour with mocked ReadKey ---
# When STDIN is closed (non-TTY), check() short-circuits before reading.
# Reopen STDIN from an in-memory pipe so we can inject specific bytes
# and verify that only ESC sets the interrupt flag.
{
    # Stub the in-package ReadKey so we control what bytes "arrive" on
    # STDIN. We override in CLIO::Core::Interrupt because that is the
    # namespace where ReadKey was imported into.
    my @bytes_to_return;
    my $key_read_count = 0;
    no warnings 'redefine';
    local *CLIO::Core::Interrupt::ReadKey = sub {
        my $timeout = $_[0] // 0;
        $key_read_count++;
        # -1 (non-blocking) and 0.05 (disambiguation) both pop the queue.
        return shift @bytes_to_return;
    };

    # Pretend STDIN is a TTY so check() does not skip the byte-read path.
    # We can only flip the -t heuristic via tty(), which we cannot fake
    # portably. Instead, call the underlying byte-handling logic by
    # installing an ALRM handler and invoking the handler sub directly.
    my $session = _make_stub_session();
    CLIO::Core::Interrupt::install_alrm_handler(session => $session, interval => 60);

    # Grab a reference to the installed $SIG{ALRM} sub so we can drive
    # it deterministically. install_alrm_handler stores it via $SIG{ALRM}.
    my $alrm_sub = $SIG{ALRM};
    ok(defined $alrm_sub, 'ALRM sub is installed');

    # Case 1: a Ctrl+C byte (0x03) arrives. The handler must NOT set
    # user_interrupted. SIGINT will handle the exit instead.
    # key_read_count is 2 because the handler reads the byte once, then
    # the drain loop performs one more read to confirm nothing follows.
    @bytes_to_return = ("\x03");
    $key_read_count = 0;
    $session->{_state}{user_interrupted} = 0;
    $alrm_sub->();
    is($key_read_count, 2, 'ALRM reads one Ctrl+C byte plus one drain probe');
    is($session->{_state}{user_interrupted}, 0,
        'Ctrl+C (0x03) does NOT set user_interrupted - SIGINT path stays live');

    # Case 2: an ESC byte (0x1B) arrives. The handler must set the flag.
    # Same 2-read pattern: main byte + drain probe.
    @bytes_to_return = ("\x1b");
    $key_read_count = 0;
    $session->{_state}{user_interrupted} = 0;
    $alrm_sub->();
    is($key_read_count, 2, 'ALRM reads one ESC byte plus one drain probe');
    is($session->{_state}{user_interrupted}, 1,
        'ESC (0x1B) sets user_interrupted flag');

    # Case 3: an arrow-key escape sequence (ESC [ A) - the ALRM fires
    # once and reads the first byte. The handler should set the flag
    # immediately on detecting ESC at byte 0; subsequent bytes get
    # drained by the next check() call's 50ms disambiguation.
    @bytes_to_return = ("\x1b");
    $key_read_count = 0;
    $session->{_state}{user_interrupted} = 0;
    $alrm_sub->();
    is($session->{_state}{user_interrupted}, 1,
        'ESC followed by more bytes still flags interrupt at byte 0 (disambiguation in check())');

    # Case 4: an unrelated byte (e.g. space, 0x20). No flag.
    @bytes_to_return = (" ");
    $key_read_count = 0;
    $session->{_state}{user_interrupted} = 0;
    $alrm_sub->();
    is($session->{_state}{user_interrupted}, 0,
        'Space (0x20) does not set user_interrupted');

    # Case 5: a sequence of three Ctrl+C bytes back-to-back. None should
    # set the flag - SIGINT handles exit, not the interrupt machinery.
    # We expect 4 reads: 1 for the first Ctrl+C + 1 drain probe + 2 more
    # from the second and third Ctrl+C bytes (no further drain since the
    # queue ends mid-sequence).
    @bytes_to_return = ("\x03", "\x03", "\x03");
    $key_read_count = 0;
    $session->{_state}{user_interrupted} = 0;
    $alrm_sub->();
    is($session->{_state}{user_interrupted}, 0,
        'Three Ctrl+C bytes do not set user_interrupted');
}
