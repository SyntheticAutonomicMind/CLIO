#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";

# Regression: three modules had "fully-qualified function call without
# explicit module load" patterns that worked in production only because
# of load-order accidents:
#
# 1. lib/CLIO/Session/State.pm used File::Basename::dirname() inside
#    sub save() without 'use File::Basename'. Worked because 13 other
#    CLIO files load it transitively. Fix: explicit use File::Basename.
#
# 2. lib/CLIO/Logging/ToolLogger.pm used File::Basename::basename()
#    inside sub filter() without 'use File::Basename'. Same fragility.
#    Fix: explicit use File::Basename.
#
# 3. lib/CLIO/Core/API/ErrorHandler.pm called
#    CLIO::Core::WorkflowOrchestrator::_compress_dropped_for_recovery()
#    and ::_checkpoint_session_progress() in 4 places. Worked in
#    production because WO loads first (WO 'use's this module), but
#    a direct require of ErrorHandler left WO un-loaded and the calls
#    would fail with "Undefined subroutine". Fix: lazy
#    'require CLIO::Core::WorkflowOrchestrator' at the top of the
#    two functions that call into it.

use Test::More;

# Test 1: State.pm should explicitly load File::Basename so sub save works
# even if no other module has loaded it yet.
{
    # Simulate "fresh" process: don't rely on other modules having been
    # loaded. We test the import contract.
    my $state_pm_source = do { local $/; open my $fh, '<', 'lib/CLIO/Session/State.pm' or die; <$fh> };
    like($state_pm_source, qr/^\s*use File::Basename qw\(dirname\)/m,
        'State.pm explicitly loads File::Basename');
}

# Test 2: ToolLogger.pm should explicitly load File::Basename
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Logging/ToolLogger.pm' or die; <$fh> };
    like($src, qr/^\s*use File::Basename qw\(basename\)/m,
        'ToolLogger.pm explicitly loads File::Basename');
}

# Test 3: ErrorHandler.pm should lazy-require WorkflowOrchestrator inside
# the functions that call into it.
{
    my $src = do { local $/; open my $fh, '<', 'lib/CLIO/Core/API/ErrorHandler.pm' or die; <$fh> };
    like($src, qr/require CLIO::Core::WorkflowOrchestrator/,
        'ErrorHandler.pm has lazy require for WorkflowOrchestrator');
    # Should be inside sub handle_api_error, not at file top (would create
    # a true circular import at compile time)
    unlike($src, qr/^use CLIO::Core::WorkflowOrchestrator;/m,
        'ErrorHandler.pm does NOT use WorkflowOrchestrator at compile time (would be circular)');
}

# Test 4: Verify ErrorHandler functions work standalone. Loading ErrorHandler
# without WO first should NOT fail, and calling handle_api_error should
# trigger the lazy require so WO subs become available.
{
    # Force fresh load
    delete $INC{'CLIO/Core/API/ErrorHandler.pm'};
    delete $INC{'CLIO/Core/WorkflowOrchestrator.pm'};
    delete $::{'CLIO::Core::WorkflowOrchestrator::'};

    require CLIO::Core::API::ErrorHandler;

    # Before calling any function, the WO sub may not exist (that's the bug
    # we're fixing - but the lazy require only fires inside the function).
    # The fix is that calling the function should make WO available.

    # Call handle_api_error with a minimal mock. We don't care about the
    # result - just that it doesn't error out on the WO sub lookup.
    my $ctx = {
        messages            => [],
        retry_count         => \my $rc,
        session_error_count => \my $sec,
        iteration           => 0,
        tool_calls_made     => 0,
        max_retries         => 3,
        max_server_retries  => 3,
        max_session_errors  => 3,
        on_system_message   => sub {},
    };
    my $err_str = '';
    my $result = eval {
        CLIO::Core::API::ErrorHandler::handle_api_error(undef, { error => 'mock' }, $ctx);
        1;
    };
    $err_str = $@;
    ok($result, 'handle_api_error runs without "Undefined subroutine" on WO')
        or diag("Error: $err_str");

    ok(defined &CLIO::Core::WorkflowOrchestrator::_compress_dropped_for_recovery,
        'After handle_api_error, WO::_compress_dropped_for_recovery is defined (lazy require fired)');
}

done_testing();
