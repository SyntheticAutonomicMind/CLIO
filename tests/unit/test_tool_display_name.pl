#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_tool_display_name.pl - Tool headers label the callable the model emitted

=head1 DESCRIPTION

Phase 3 rewrites an emitted callable to the tool that owns it, so a `read_file`
call reaches the dispatcher as `file_operations`. The header used to be built
from that rewritten name, so a perfectly legitimate `file_search` call rendered
as "FILE OPERATIONS" and looked like the model had invented a grouping-name
call that the strict surface check is supposed to reject.

This test pins three things:

1. The rendered header uses the emitted callable, not the rewritten one.
2. A call that was not rewritten still renders its own name.
3. A grouping name with no operation is genuinely rejected, so nothing in the
   error-recovery path guesses an operation on the model's behalf.

=cut

use strict;
use warnings;
use utf8;

use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Temp qw(tempdir);

my $temp_dir = tempdir(CLEANUP => 1);
$ENV{HOME} = $temp_dir;
$ENV{CLIO_LOG_LEVEL} = 'ERROR';

use CLIO::UI::SessionReplay;
use CLIO::Tools::Registry;
use CLIO::Core::ToolExecutor;
use CLIO::Tools::FileOperations;

{
    package MockChat;
    sub new { my $class = shift; return bless { non_interactive => 0, enable_markdown => 0 }, $class }
    sub colorize              { my ($self, $text) = @_; return $text }
    sub agent_name            { return 'CLIO' }
    sub writeline             { return }
    sub render_markdown       { my ($self, $text) = @_; return $text }
    sub display_system_message { return }
    sub display_info_message   { return }
    sub display_error_message  { return }
    sub display_success_message { return }
}

sub _render_capture {
    my ($history) = @_;
    my $chat   = MockChat->new();
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat);

    my $buf = '';
    {
        # Match the real STDOUT encoding so box-drawing characters do not warn.
        open my $fh, '>:encoding(UTF-8)', \$buf or die "capture: $!";
        local *STDOUT = $fh;
        $replay->render_history($history);
    }
    return $buf;
}

sub _history_with {
    my (%call) = @_;
    return (
        { role => 'user', content => 'find it' },
        {
            role    => 'assistant',
            content => 'Looking.',
            tool_calls => [
                {
                    id       => 'call_1',
                    type     => 'function',
                    %call,
                }
            ],
        },
        {
            role               => 'tool',
            content            => '[]',
            tool_call_id       => 'call_1',
            tool_name          => $call{function}{name},
            action_description => 'searching',
            suppressed_display => 0,
            is_error           => 0,
        },
    );
}

# ---------------------------------------------------------------------------
# 1. Rewritten callable renders the emitted name
# ---------------------------------------------------------------------------

my $rewritten = _render_capture([
    _history_with(
        _emitted_name => 'file_search',
        function      => { name => 'file_operations', arguments => '{"pattern":"x"}' },
    )
]);

like($rewritten, qr/FILE SEARCH/, 'header labels the emitted callable (FILE SEARCH)');
unlike($rewritten, qr/FILE OPERATIONS/,
    'header does not show the rewritten grouping name (FILE OPERATIONS)');

# ---------------------------------------------------------------------------
# 2. A call that was not rewritten keeps its own label
# ---------------------------------------------------------------------------

my $direct = _render_capture([
    _history_with(
        function => { name => 'terminal_operations', arguments => '{"command":"ls","operation":"exec"}' },
    )
]);

like($direct, qr/TERMINAL OPERATIONS/, 'unrewritten call keeps its own label');

# ---------------------------------------------------------------------------
# 3. The emitted name really is a published callable for that operation
# ---------------------------------------------------------------------------

my $registry = CLIO::Tools::Registry->new();
$registry->register_tool(CLIO::Tools::FileOperations->new(debug => 0));

ok($registry->is_emitted_name('file_search'),
    'file_search is a published callable, so emitting it is legitimate');
ok(!$registry->is_emitted_name('file_operations'),
    'file_operations is a grouping name, not a callable');

my $alias = $registry->get_alias_info('file_search');
is($alias && $alias->{operation}, 'file_search',
    'file_search resolves to the file_search operation');

# ---------------------------------------------------------------------------
# 4. Nothing guesses an operation for an invented grouping-name call
# ---------------------------------------------------------------------------

my $executor = CLIO::Core::ToolExecutor->new(
    tool_registry => $registry,
    session       => {},
    debug         => 0,
);

my $out = $executor->execute_tool(
    {
        id       => 'call_2',
        type     => 'function',
        function => { name => 'file_operations', arguments => '{"pattern":"x"}' },
    },
    'call_2',
);

my $decoded = eval { CLIO::Util::JSON::decode_json($out) };
ok($decoded && !$decoded->{success}, 'grouping name with no operation is rejected');
like($decoded->{error} // '', qr/Unknown tool: file_operations/,
    'rejection names the invented callable');

done_testing();
