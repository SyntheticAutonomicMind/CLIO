#!/usr/bin/env perl

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_trim_purity.pl - The proactive trim must not modify the array it is given

=head1 DESCRIPTION

C<messages> passed to validate_and_truncate is the orchestrator's live working
array, and its entries are shared hash references. The walk must read that array
and return a new one. When it instead wrote through the shared references, two
defects followed:

=over 4

=item * The walk became a function of its own previous output. Folding the
C<< <thread_summary> >> into the last user message in place meant a second call
saw a summary that was not in the input, pinned that message by the summary rule
as well as the last-user rule, and cut at a different point. Measured on a
3603-message array: 2009 messages kept on the first call, 1947 on the second.
Two validations of one request must agree, or the provider's cached prefix
drifts.

=item * The caller's message was edited under it. C<add_message> had already
stored the user's text as a string, so history was not corrupted, but any other
holder of the reference saw framework narration prepended to user input.

=back

The one message that receives the summary is copied; every other kept message
keeps its identity so the KV cache stays warm for the unchanged prefix. That
property is asserted here too, because "copy everything" would silently undo it.

=cut

use strict;
use warnings;
use utf8;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../../lib";

use CLIO::Core::API::MessageValidator
    qw(validate_and_truncate remove_existing_thread_summaries);

my $CAPS = {
    max_context_window_tokens => 262144,
    context_window            => 262144,
    max_prompt_tokens         => 262144,
    max_output_tokens         => 16384,
};

my %BASE = (
    model_capabilities => $CAPS,
    tools              => [],
    token_ratio        => 4.0,
    debug              => 0,
    model              => 'test-model',
    active_task        => 'anchor task ' . ('A' x 200),
    active_todos       => [],
    unresolved         => [],
    ltm_entries        => [],
);

# A conversation big enough to trip the trim, with tool-call/result pairs so the
# atomic-batch logic is exercised too.
sub build_messages {
    my ($turns, $chars) = @_;
    my @m;
    push @m, { role => 'system', content => 'S' x 4000 };
    push @m, { role => 'user',   content => 'anchor task ' . ('A' x 200) };
    for my $t (1 .. $turns) {
        push @m, { role => 'user', content => "turn $t " . ('u' x $chars) };
        push @m, {
            role       => 'assistant',
            content    => '',
            tool_calls => [ {
                id       => "call_$t",
                type     => 'function',
                function => { name => 'read_file', arguments => '{"path":"x"}' },
            } ],
        };
        push @m, { role => 'tool', tool_call_id => "call_$t", content => ('r' x $chars) };
    }
    push @m, { role => 'user', content => 'CURRENT input ' . ('c' x 120) };
    return \@m;
}

sub content_of {
    my ($msg) = @_;
    my $c = $msg->{content} // '';
    return $c unless ref $c eq 'ARRAY';
    return join '', map { ref($_) eq 'HASH' ? ($_->{text} // '') : '' } @$c;
}

# ---------------------------------------------------------------------------
# 1. The caller's array and hashes survive untouched
# ---------------------------------------------------------------------------

subtest 'trim does not modify the caller array' => sub {
    my $messages = build_messages(1200, 400);
    my $count_before = scalar @$messages;
    my @content_before = map { content_of($_) } @$messages;

    my $out = validate_and_truncate(messages => $messages, %BASE);

    is(scalar @$messages, $count_before,
        'caller array length unchanged');
    ok(!grep({ /<thread_summary>/ } @content_before),
        'fixture: no summary present before the trim');
    my @changed = grep { content_of($messages->[$_]) ne $content_before[$_] }
                  0 .. $#$messages;
    is(scalar @changed, 0,
        'no message content modified in place');
    ok(!grep({ content_of($_) =~ /<thread_summary>/ } @$messages),
        'the summary was not folded into the caller\'s last user message');
    ok((scalar @$out) < $count_before, 'the trim actually dropped messages');
};

# ---------------------------------------------------------------------------
# 2. Two calls on the same array agree
# ---------------------------------------------------------------------------

subtest 'the walk is a pure function of its input' => sub {
    my $messages = build_messages(1200, 400);

    my $first  = validate_and_truncate(messages => $messages, %BASE);
    my $second = validate_and_truncate(messages => $messages, %BASE);

    is(scalar @$second, scalar @$first,
        'second call keeps the same number of messages');

    my @diff;
    for my $i (0 .. $#$first) {
        push @diff, $i
            if content_of($first->[$i]) ne content_of($second->[$i])
            || ($first->[$i]{role} // '') ne ($second->[$i]{role} // '');
    }
    is(scalar @diff, 0,
        'identical message sequence on the second call')
        or diag('differing indices: ' . join ',', @diff[0 .. ($#diff > 9 ? 9 : $#diff)]);
};

# ---------------------------------------------------------------------------
# 3. Cache property: only the summary carrier is a new hash
# ---------------------------------------------------------------------------

subtest 'kept messages keep their identity' => sub {
    my $messages = build_messages(1200, 400);
    my %is_input = map { $_ => 1 } @$messages;

    my $out = validate_and_truncate(messages => $messages, %BASE);

    my @copied = grep { !$is_input{$_} } @$out;
    is(scalar @copied, 1,
        'exactly one kept message is a copy (the summary carrier)');
    like(content_of($copied[0]), qr/<thread_summary>/,
        'the copied message is the one carrying the summary');
    is(scalar(grep { $is_input{$_} } @$out), scalar(@$out) - 1,
        'every other kept message is the original reference');
};

# ---------------------------------------------------------------------------
# 4. remove_existing_thread_summaries is also read-only
# ---------------------------------------------------------------------------

subtest 'remove_existing_thread_summaries does not modify its input' => sub {
    my $carrier = {
        role    => 'user',
        content => '<thread_summary>old state</thread_summary>' . "\n\nactual input",
    };
    my $plain = { role => 'user', content => 'untouched' };
    my $messages = [ $carrier, $plain ];

    my $out = remove_existing_thread_summaries($messages);

    is(scalar @$out, 2, 'both messages survive');
    like($carrier->{content}, qr/<thread_summary>/,
        'the input carrier still carries the summary');
    is($carrier->{content},
        '<thread_summary>old state</thread_summary>' . "\n\nactual input",
        'input content byte-identical to before');
    unlike($out->[0]{content}, qr/<thread_summary>/,
        'the returned carrier has the summary stripped');
    like($out->[0]{content}, qr/actual input/,
        'the user input survives the strip');
    isnt($out->[0], $carrier, 'the returned carrier is a different hash');
    is($out->[1], $plain, 'messages without a summary keep their identity');
};

# ---------------------------------------------------------------------------
# 5. Multimodal content: the arrayref is not shared either
# ---------------------------------------------------------------------------

subtest 'multimodal last user message is copied, not mutated' => sub {
    my $messages = build_messages(1200, 400);
    $messages->[-1] = {
        role    => 'user',
        content => [
            { type => 'text',  text => 'CURRENT input ' . ('c' x 120) },
            { type => 'image', source => { type => 'base64', data => 'AAAA' } },
        ],
    };
    my $parts_before = scalar @{ $messages->[-1]{content} };

    my $out = validate_and_truncate(messages => $messages, %BASE);

    is(scalar @{ $messages->[-1]{content} }, $parts_before,
        'caller content array not extended in place');
    my ($carrier) = grep { content_of($_) =~ /<thread_summary>/ } @$out;
    ok($carrier, 'a kept message carries the summary');
    ok(ref $carrier->{content} eq 'ARRAY',
        'multimodal content stayed an arrayref');
    is(scalar @{ $carrier->{content} }, $parts_before + 1,
        'the copy carries the prepended summary part');
    ok(!defined $carrier->{content}[0]{type} || $carrier->{content}[0]{type} eq 'text',
        'the prepended part is a text part');
};

done_testing();
