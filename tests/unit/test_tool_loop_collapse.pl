#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Tests for the agent tool-loop collapse in CLIO::Core::ContextBuilder.
#
# Background: an agent tool loop produces a message run with no user
# message between the tool exchanges. _split_into_turns starts a turn at
# a user message, so the whole run lands in ONE turn and the cross-turn
# collapse cannot see the duplicates. collapse_repeated_tool_exchanges
# handles that shape: it collapses a run of identical tool exchanges to
# its last exchange and records the run length, which
# _render_repeat_markers then puts in front of the tool result so the
# model can see that it repeated.

use strict;
use warnings;
use utf8;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use Test::More;
use CLIO::Core::ContextBuilder;

*build_projection = \&CLIO::Core::ContextBuilder::build_projection;
*collapse_repeated_tool_exchanges = \&CLIO::Core::ContextBuilder::collapse_repeated_tool_exchanges;
*render_repeat_markers = \&CLIO::Core::ContextBuilder::_render_repeat_markers;

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# One tool exchange: an assistant message with a single tool call
# followed by its tool result.
sub exchange {
    my (%args) = @_;
    my $id = $args{id} // 'call_1';
    my $name = $args{name} // 'terminal_operations';
    my $arguments = $args{arguments} // '{"operation":"exec","command":"free -b"}';
    my $content = $args{content};
    my $assistant_content = $args{assistant_content};
    return (
        { role => 'assistant',
          (defined $assistant_content ? (content => $assistant_content) : ()),
          tool_calls => [ { id => $id, type => 'function',
                            function => { name => $name, arguments => $arguments } } ] },
        { role => 'tool', tool_call_id => $id, content => $content },
    );
}

# A history shaped like a runaway agent tool loop: one user message,
# then N identical tool exchanges with no user message between them.
# The result changes on every run (a counter that ticks), which is what
# defeated the cross-turn collapse's result-digest comparison.
sub loop_history {
    my ($count) = @_;
    my @messages = ({ role => 'user', content => 'Check the memory picture, then continue.' });
    for my $i (1 .. $count) {
        push @messages, exchange(
            id => "call_$i",
            content => "Mem: 27064918016  1392709632  10835582976  " . (34144256 + $i * 4096),
        );
    }
    return \@messages;
}

# ---------------------------------------------------------------------------
# Direct tests of collapse_repeated_tool_exchanges
# ---------------------------------------------------------------------------

subtest 'run of identical exchanges collapses to the last one' => sub {
    my $history = loop_history(12);
    my $result = collapse_repeated_tool_exchanges($history);

    # 1 user message + 1 assistant + 1 tool
    is(scalar(@$result), 3, 'Twelve exchanges collapsed to one');

    my $assistant = $result->[1];
    my $tool = $result->[2];
    is($assistant->{tool_calls}[0]{id}, 'call_12', 'Last exchange kept');
    is($tool->{tool_call_id}, 'call_12', 'Tool result pairs with the kept call');
    like($tool->{content}, qr/27064918016/, 'Latest result kept');
    is($tool->{_repeats}, 12, 'Repeat count recorded');
};

subtest 'exchange with a different argument is not collapsed' => sub {
    my @messages = ({ role => 'user', content => 'go' });
    push @messages, exchange(id => 'call_1', arguments => '{"command":"free -b"}', content => 'a');
    push @messages, exchange(id => 'call_2', arguments => '{"command":"free -h"}', content => 'b');

    my $result = collapse_repeated_tool_exchanges(\@messages);
    is(scalar(@$result), 5, 'Different arguments are kept apart');
};

subtest 'a user message between exchanges stops the run' => sub {
    my @messages = ({ role => 'user', content => 'go' });
    push @messages, exchange(id => 'call_1', content => 'a');
    push @messages, { role => 'user', content => 'now do something else' };
    push @messages, exchange(id => 'call_2', content => 'b');

    my $result = collapse_repeated_tool_exchanges(\@messages);
    is(scalar(@$result), 6, 'Run stops at the user message');
};

subtest 'assistant text above 80 characters stops the run' => sub {
    my @messages = ({ role => 'user', content => 'go' });
    push @messages, exchange(id => 'call_1', content => 'a',
                             assistant_content => 'This is a real explanation of what I am doing '
                                                 . 'and why it matters for the next step of the work.');
    push @messages, exchange(id => 'call_2', content => 'b');

    my $result = collapse_repeated_tool_exchanges(\@messages);
    is(scalar(@$result), 5, 'Substantive assistant text is left alone');
};

subtest 'single exchange is untouched' => sub {
    my $history = loop_history(1);
    my $result = collapse_repeated_tool_exchanges($history);
    is(scalar(@$result), 3, 'Single exchange preserved');
    is($result->[2]{_repeats}, undef, 'No repeat count on a single exchange');
};

subtest 'source messages are not modified' => sub {
    my $history = loop_history(5);
    collapse_repeated_tool_exchanges($history);
    is(scalar(@$history), 11, 'Source history length unchanged');
    is($history->[2]{_repeats}, undef, 'Source tool message has no repeat count');
};

# ---------------------------------------------------------------------------
# Repeat marker rendering
# ---------------------------------------------------------------------------

subtest 'repeat marker lands in front of the tool result' => sub {
    my $history = loop_history(7);
    my $collapsed = collapse_repeated_tool_exchanges($history);
    my $rendered = render_repeat_markers($collapsed);

    my $content = $rendered->[2]{content};
    like($content, qr/^\[repeated call: this exact call ran 7 times in succession\./,
         'Note is the first thing the model reads');
    like($content, qr/Mem: 27064918016/, 'Result follows the note');
};

subtest 'no marker without a repeat count' => sub {
    my $history = loop_history(1);
    my $collapsed = collapse_repeated_tool_exchanges($history);
    my $rendered = render_repeat_markers($collapsed);
    unlike($rendered->[2]{content}, qr/repeated call/, 'Single call carries no note');
};

# ---------------------------------------------------------------------------
# Projection level: the whole runaway history collapses
# ---------------------------------------------------------------------------

subtest 'projection collapses a runaway tool loop' => sub {
    my $history = loop_history(20);
    my $projection = build_projection(
        history    => $history,
        user_input => 'continue',
    );

    my @messages;
    push @messages, @{$projection->{anchor} || []};
    for my $turn (@{$projection->{turns} || []}) {
        push @messages, @$turn;
    }

    my @tools = grep { ($_->{role} // '') eq 'tool' } @messages;
    is(scalar(@tools), 1, 'Twenty tool results collapsed to one');

    like($tools[0]{content}, qr/this exact call ran 20 times in succession/,
         'The model is told how many times it repeated');
    like($tools[0]{content}, qr/Mem: 27064918016/, 'Latest result is the one shown');
};

subtest 'projection leaves a normal conversation alone' => sub {
    my @messages = (
        { role => 'user', content => 'read the file' },
        { role => 'assistant', content => 'Reading.',
          tool_calls => [ { id => 'call_1', type => 'function',
                            function => { name => 'file_operations',
                                          arguments => '{"path":"a.txt"}' } } ] },
        { role => 'tool', tool_call_id => 'call_1', content => 'aaa' },
        { role => 'user', content => 'read another' },
        { role => 'assistant', content => 'Reading.',
          tool_calls => [ { id => 'call_2', type => 'function',
                            function => { name => 'file_operations',
                                          arguments => '{"path":"b.txt"}' } } ] },
        { role => 'tool', tool_call_id => 'call_2', content => 'bbb' },
    );

    my $projection = build_projection(
        history    => \@messages,
        user_input => 'continue',
    );

    my @out;
    push @out, @{$projection->{anchor} || []};
    for my $turn (@{$projection->{turns} || []}) {
        push @out, @$turn;
    }

    my @tools = grep { ($_->{role} // '') eq 'tool' } @out;
    is(scalar(@tools), 2, 'Two distinct calls both survive');
    unlike($tools[0]{content}, qr/repeated call/, 'No note on a normal call');
    unlike($tools[1]{content}, qr/repeated call/, 'No note on a normal call');
};

done_testing();
