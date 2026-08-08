# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Core::Interrupt;

use strict;
use warnings;
use utf8;
use Exporter 'import';

our @EXPORT_OK = qw(
    check
    pending
    clear
    set
    install_alrm_handler
    uninstall_alrm_handler
    with_alrm_handler
);

use CLIO::Core::Logger qw(log_debug log_info log_warning);
use CLIO::Compat::Terminal qw(ReadKey);

=head1 NAME

CLIO::Core::Interrupt - Centralized interrupt detection for CLIO

=head1 DESCRIPTION

Single source of truth for "did the user ask to interrupt the agent?". The
interrupt signal is ESC (0x1B) pressed on the controlling
TTY. Other keys (mouse events, focus events, resize sequences, arrow keys,
function keys, Ctrl+C) are ignored and silently drained. Ctrl+C is left to
the standard SIGINT handler so it terminates the session in classic Unix
fashion - users who want to break out of CLIO press Ctrl+C, users who want
to interrupt an in-flight AI response press ESC.

Two paths to detection:

=over 4

=item ALRM (passive)

A 1Hz (or faster) timer installed by C<install_alrm_handler> calls
C<scan_input> between Perl opcodes. This catches the keystroke even when
the main loop is blocked in a I/O syscall. The ALRM handler is safe to
call from a signal context: it does only non-blocking I/O and sets an
in-process flag.

=item check (active)

Tools and the workflow loop call C<check> from regular code. check
first checks the in-process flag, then performs a non-blocking read
of STDIN. If it sees ESC, it does a short blocking wait to distinguish
"standalone ESC" from "ESC + arrow/modifier sequence" - the blocking
wait is only done outside signal context, so it can never deadlock.

=back

For backwards compatibility the in-process flag is C<<
$session->state()->{user_interrupted} >> - all callers that used to set
or read this flag still work. New callers should use C<set>, C<clear>,
or C<pending> instead of poking the session state directly.

=head1 SYNOPSIS

    use CLIO::Core::Interrupt;

    # At the start of an agent turn:
    install_alrm_handler(session => $session, interval => 0.25);

    # In a tool loop:
    while (my $chunk = read_more()) {
        last if Interrupt::check(session => $session);
        process($chunk);
    }

    # At the end of the turn:
    uninstall_alrm_handler();

=cut

# Track whether we installed our ALRM handler so we can clean up safely.
my $ALRM_INSTALLED = 0;
my $ALRM_OWNER_PID = 0;
my $ALRM_INTERVAL = 1;  # Default 1s; overridden by install_alrm_handler

=head2 check

Non-blocking interrupt check. Returns 1 if the user has pressed ESC
since the last C<clear>, 0 otherwise. Ctrl+C is intentionally NOT
treated as an interrupt - it falls through to the global SIGINT
handler which terminates CLIO cleanly via the C<cleanup_handler>
installed in the C<clio> script.

Arguments:
- session: Session object (optional but recommended)

Returns:
- 1 if interrupt detected; 0 if not

B<Side effects:> If an interrupt is detected, marks the session state
the same way the ALRM handler does, so downstream callers see the same
state regardless of which path detected it.

=cut

sub check {
    my (%opts) = @_;
    my $session = $opts{session};

    # Fast path: ALRM handler already set the flag.
    return 1 if pending(session => $session);

    # Skip if no TTY (e.g. piped input, syntax check).
    return 0 unless -t STDIN;

    # Non-blocking read. Returns undef if no key is available.
    my $key = eval { ReadKey(-1) };
    return 0 if !defined $key || $@;

    my $ord = ord($key);

    if ($ord == 27) {
        # ESC. Peek for the next byte with a short blocking wait.
        # This is safe here because we are NOT in a signal context - the
        # ALRM handler intentionally avoids this wait so it cannot
        # deadlock. The 50ms timeout is the standard readline convention
        # for distinguishing a standalone ESC from an escape sequence.
        my $next = eval { ReadKey(0.05) };
        if (defined $next) {
            # Escape sequence (arrow key, function key, mouse event, etc).
            # Drain the rest of the sequence and treat as non-interrupt.
            while (defined(eval { ReadKey(-1) })) { }
            return 0;
        }
        # Standalone ESC, treated as interrupt.
        log_info('Interrupt', 'ESC key detected (standalone)');
        while (defined(eval { ReadKey(-1) })) { }
        set(session => $session);
        return 1;
    } elsif ($ord == 3) {
        # Ctrl+C is intentionally NOT treated as an interrupt - we leave
        # it to the standard SIGINT handler so it terminates CLIO cleanly
        # via the cleanup_handler installed in the clio script. This
        # matches classic Unix behaviour where Ctrl+C breaks out of a
        # foreground process. Drain the byte so it does not leak into
        # readline and confuse subsequent input.
        log_debug('Interrupt', 'Ctrl+C ignored (left to SIGINT handler)');
        while (defined(eval { ReadKey(-1) })) { }
        return 0;
    } else {
        # Any other key - drain and ignore.
        while (defined(eval { ReadKey(-1) })) { }
        return 0;
    }
}

=head2 pending

Return the current in-process interrupt flag without doing any I/O.

Arguments:
- session: Session object (optional)

Returns: 1 if flagged, 0 otherwise

=cut

sub pending {
    my (%opts) = @_;
    my $session = $opts{session};
    return 0 unless $session;
    # Accept either a blessed session object (with ->state method) or a
    # bare hashref representing the state directly (test mocks and lightweight
    # callers use this form). Order matters: check can('state') FIRST
    # so blessed session objects with their own ->state() are not mistaken
    # for state hashrefs. Blessed hashrefs with no state method fall through
    # to the is_hashref branch.
    my $state;
    if (eval { $session->can('state') }) {
        $state = $session->state();
    } elsif (ref($session) eq 'HASH') {
        $state = $session;
    } else {
        return 0;
    }
    return 0 unless $state && ref($state) eq 'HASH';
    return $state->{user_interrupted} ? 1 : 0;
}

=head2 set

Mark the interrupt as requested. Persists to session if a session is
provided so other processes / reloaded sessions see the flag.

Arguments:
- session: Session object (optional)
- reason: Short string for logging (optional)

Returns: 1

=cut

sub set {
    my (%opts) = @_;
    my $session = $opts{session};
    my $reason = $opts{reason} // 'user request';

    if ($session && $session->can('state')) {
        my $state = $session->state();
        if ($state && ref($state) eq 'HASH') {
            $state->{user_interrupted} = 1;
            # Best-effort save so the flag survives a crash before the
            # workflow loop notices it. Failure is non-fatal.
            if ($session->can('save')) {
                eval { $session->save(); };
                if ($@) {
                    log_debug('Interrupt', "Failed to save session after interrupt: $@");
                }
            }
        }
    }
    log_info('Interrupt', "Interrupt set ($reason)");
    return 1;
}

=head2 clear

Clear the in-process interrupt flag. Called by the workflow loop after
a detected interrupt has been handled, so the next iteration does not
re-trigger immediately.

Arguments:
- session: Session object (optional)

Returns: 1

=cut

sub clear {
    my (%opts) = @_;
    my $session = $opts{session};
    if ($session && $session->can('state')) {
        my $state = $session->state();
        if ($state && ref($state) eq 'HASH') {
            $state->{user_interrupted} = 0;
        }
    }
    return 1;
}

=head2 install_alrm_handler

Install the periodic ALRM handler that scans STDIN for ESC
between Perl opcodes. Safe to call when an old handler is already
installed - it just replaces the current one.

Arguments:
- session: Session object whose state->{user_interrupted} will be set
- interval: Seconds between scans (default 1, recommend 0.25 in
  streaming contexts for sub-second latency)

Returns: 1

=cut

sub install_alrm_handler {
    my (%opts) = @_;
    my $session = $opts{session};
    my $interval = $opts{interval} // 1;
    $interval = 1 if $interval < 0.05;  # floor: 50ms

    # If we already installed our handler, just update the interval.
    if ($ALRM_INSTALLED && $ALRM_OWNER_PID == $$) {
        $ALRM_INTERVAL = $interval;
        alarm($interval);
        return 1;
    }

    $ALRM_OWNER_PID = $$;
    $ALRM_INTERVAL = $interval;

    # Wrap in a closure so {$session, $interval} are captured without
    # polluting the global namespace. The handler itself is intentionally
    # minimal: non-blocking read of a single byte, set flag, re-arm.
    # The 50ms escape-sequence disambiguation is deliberately deferred
    # to the next call to check() in regular code, where a blocking
    # timeout is safe.
    $SIG{ALRM} = sub {
        return if $ALRM_INSTALLED == 0;  # race: uninstall happened mid-fire
        return unless $session && $session->can('state');
        my $state = $session->state();
        return unless $state && ref($state) eq 'HASH';
        return if $state->{user_interrupted};  # already flagged

        # Non-blocking read of a single byte. Even if we are in a
        # pseudo-signal context, this is non-blocking and safe to call.
        my $key = eval { ReadKey(-1) };
        if (defined $key && !$@) {
            my $ord = ord($key);
            if ($ord == 27) {
                # Bare byte detection: the disambiguation between ESC
                # (interrupt) and ESC [ (arrow key / escape sequence)
                # happens later, in check(), which is not in signal
                # context. This avoids the historical "blocking ReadKey
                # in signal handler" footgun.
                log_debug('Interrupt', "ALRM scan: ESC byte detected");
                # Drain any extra bytes that arrived with this keypress
                # - mouse/focus events and modifier sequences typically
                # send 3-5 bytes starting with ESC. We drain here so
                # the next check() call sees a clean buffer and can run
                # the 50ms disambiguation on a fresh key.
                while (defined(eval { ReadKey(-1) })) { }
                $state->{user_interrupted} = 1;
                # Re-arm best-effort. Use copy of interval to avoid
                # surprises if the next install_alrm_handler call
                # mutates $ALRM_INTERVAL between now and alarm().
                eval { alarm($ALRM_INTERVAL); };
            } elsif ($ord == 3) {
                # Ctrl+C byte detected: do NOT flag this as an
                # interrupt. Leave it for the SIGINT handler so CLIO
                # exits cleanly via cleanup_handler. If we consumed the
                # byte here the SIGINT path would never fire and Ctrl+C
                # would become a no-op instead of "break out of CLIO".
                # We drain the byte but do not re-arm the alarm - the
                # SIGINT path wins.
                log_debug('Interrupt', 'ALRM scan: Ctrl+C byte detected, ignoring (SIGINT will fire)');
                while (defined(eval { ReadKey(-1) })) { }
                eval { alarm($ALRM_INTERVAL); };
            } else {
                # Other key during scan - drain and ignore.
                while (defined(eval { ReadKey(-1) })) { }
                eval { alarm($ALRM_INTERVAL); };
            }
        } else {
            eval { alarm($ALRM_INTERVAL); };
        }
    };

    alarm($interval);
    $ALRM_INSTALLED = 1;
    log_debug('Interrupt', "Installed ALRM handler (interval=${interval}s)");
    return 1;
}

=head2 uninstall_alrm_handler

Remove the periodic ALRM handler. Restores the previous handler if
one was saved when install was called. Idempotent.

Returns: 1

=cut

sub uninstall_alrm_handler {
    return 1 unless $ALRM_INSTALLED;
    return 1 unless $ALRM_OWNER_PID == $$;  # different process; bail

    alarm(0);  # cancel any pending alarm
    $SIG{ALRM} = 'DEFAULT';
    $ALRM_INSTALLED = 0;
    $ALRM_OWNER_PID = 0;
    log_debug('Interrupt', 'Uninstalled ALRM handler');
    return 1;
}

=head2 with_alrm_handler

Convenience wrapper that installs the ALRM handler for the duration of
the supplied block, then uninstalls. Use this anywhere an agent turn
or tool execution wants interrupt detection covered automatically.

    Interrupt::with_alrm_handler(session => $s, interval => 0.25, sub {
        do_work_that_may_block();
    });

Arguments:
- session
- interval
- code: coderef to run

Returns: Whatever the code returns.

=cut

sub with_alrm_handler {
    my (%opts) = @_;
    my $code = $opts{code} || die "with_alrm_handler requires code\n";
    install_alrm_handler(%opts);
    my @result;
    eval {
        @result = wantarray ? $code->() : scalar($code->());
    };
    my $err = $@;
    uninstall_alrm_handler();
    die $err if $err;
    return wantarray ? @result : $result[0];
}

=head2 is_alrm_handler_active

Returns 1 if our ALRM handler is currently installed in this process.

=cut

sub is_alrm_handler_active {
    return $ALRM_INSTALLED && $ALRM_OWNER_PID == $$ ? 1 : 0;
}

1;

__END__

=head1 ARCHITECTURE NOTES

=head2 Why the ALRM handler does NOT do the 50ms escape sequence wait

The previous design called C<ReadKey(0.05)> inside the ALRM handler to
distinguish "ESC" from "ESC [ A" (arrow up). That wait is a blocking
syscall. While Perl's signal model is generally tolerant of blocking
calls inside handlers, doing so creates a window where a second signal
can be delivered and queued. The ALRM handler is also the wrong place
to debounce terminal input - that is a regular-code concern.

The new design splits the responsibility:

=over 4

=item ALRM handler

Non-blocking read of a single byte. If it sees ESC, it sets
the in-process flag and drains any extra bytes that arrived with the
keypress. It does NOT block. Ctrl+C is deliberately not handled here
so the global SIGINT handler can terminate CLIO in classic Unix style.

=item check (called from regular code)

Performs the 50ms disambiguation. If the buffer is empty after the
short wait, it is a standalone ESC and we interrupt. If more bytes
arrived, we drained them as part of an escape sequence and continue.

=back

This avoids both the "blocking read in signal context" footgun and the
"signal handler ignored my keypress" race where the timer fired
between ReadKey calls and the buffered byte was lost.

=head2 Why we drop the session->save() inside the ALRM handler

The previous implementation called C<< $session->save() >> inside the
ALRM handler when it detected an interrupt. Session save can block
(writing to disk, fsync, etc.), which is bad inside a signal handler.
The new design sets the in-process flag and lets the workflow loop
persist the state on its next iteration - this is already what it
does, and the WorkflowOrchestrator saves the session after every tool
round.

If the process is killed between the ALRM detection and the next save,
the I<user_interrupted> flag is lost, but the same was true before
this change. The new path is no worse.

=head1 SEE ALSO

L<CLIO::Core::WorkflowOrchestrator> - primary consumer
L<CLIO::UI::Chat> - secondary consumer (legacy)
L<CLIO::Core::Logger>

=cut
