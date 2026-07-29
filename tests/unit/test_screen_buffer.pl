#!/usr/bin/env perl
# Test: Chat.pm screen buffer (add_to_buffer / repaint_screen)
# Covers:
#   - add_to_buffer stores typed messages
#   - buffer FIFO eviction at max_buffer_size
#   - buffer content structure (type, content, timestamp)
#   - user and assistant message types
#   - max_buffer_size defaults to 100

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');

use lib '../../lib';

BEGIN {
    no warnings 'redefine';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (80, 24); };
}

use CLIO::UI::Chat;

my ($pass, $fail) = (0, 0);

sub ok_int {
    my ($got, $expected, $label) = @_;
    if (defined $got && $got == $expected) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (got=" . (defined $got ? $got : 'undef') . ", expected=$expected)\n";
        $fail++;
    }
}

sub ok_str {
    my ($got, $expected, $label) = @_;
    if (defined $got && $got eq $expected) {
        print "PASS: $label\n";
        $pass++;
    } else {
        print "FAIL: $label (got='$got', expected='$expected')\n";
        $fail++;
    }
}

# Build a minimal Chat instance. We don't need a full session - just
# enough to test the buffer methods.
my $chat = CLIO::UI::Chat->new(
    debug       => 0,
    config      => undef,
    session     => undef,
    no_color    => 1,
);

# --- Default buffer size ---
ok_int($chat->{max_buffer_size}, 100, 'default max_buffer_size is 100');

# --- add_to_buffer stores messages ---
{
    $chat->{screen_buffer} = [];
    $chat->add_to_buffer('user', 'hello world');
    ok_int(scalar(@{$chat->{screen_buffer}}), 1, 'add_to_buffer stores 1 message');
    ok_str($chat->{screen_buffer}->[0]->{type}, 'user', 'message type is user');
    ok_str($chat->{screen_buffer}->[0]->{content}, 'hello world', 'message content preserved');
}

# --- Multiple messages accumulate ---
{
    $chat->{screen_buffer} = [];
    $chat->add_to_buffer('assistant', 'msg1');
    $chat->add_to_buffer('assistant', 'msg2');
    $chat->add_to_buffer('user', 'msg3');
    ok_int(scalar(@{$chat->{screen_buffer}}), 3, '3 messages accumulated');
}

# --- Buffer respects max_buffer_size (FIFO eviction) ---
{
    $chat->{screen_buffer} = [];
    $chat->{max_buffer_size} = 5;

    for (my $i = 1; $i <= 10; $i++) {
        $chat->add_to_buffer('assistant', "msg$i");
    }

    ok_int(scalar(@{$chat->{screen_buffer}}), 5, 'buffer capped at 5 when max_buffer_size=5');
    ok_str($chat->{screen_buffer}->[0]->{content}, 'msg6', 'oldest kept is msg6 (FIFO eviction)');
    ok_str($chat->{screen_buffer}->[-1]->{content}, 'msg10', 'newest is msg10');
}

# --- Timestamps are set ---
{
    $chat->{screen_buffer} = [];
    my $before = time();
    $chat->add_to_buffer('assistant', 'ts check');
    my $after = time();

    my $ts = $chat->{screen_buffer}->[0]->{timestamp};
    ok_int(($ts >= $before && $ts <= $after) ? 1 : 0, 1, 'timestamp set within expected range');
}

# --- Different message types ---
{
    $chat->{screen_buffer} = [];
    my %types = (
        user      => 'user message',
        assistant => 'assistant reply',
        error     => 'error text',
        success   => 'ok text',
    );

    for my $type (keys %types) {
        $chat->add_to_buffer($type, $types{$type});
    }

    my %seen;
    for my $msg (@{$chat->{screen_buffer}}) {
        $seen{$msg->{type}} = $msg->{content};
    }

    for my $type (keys %types) {
        ok_str($seen{$type}, $types{$type}, "message type '$type' stored with correct content");
    }
}

# --- Zero messages is legal ---
{
    $chat->{screen_buffer} = [];
    ok_int(scalar(@{$chat->{screen_buffer}}), 0, 'empty buffer has 0 messages');
}

# --- Buffer survives max_buffer_size boundary exactly ---
{
    $chat->{screen_buffer} = [];
    $chat->{max_buffer_size} = 3;

    $chat->add_to_buffer('assistant', '1');
    $chat->add_to_buffer('assistant', '2');
    $chat->add_to_buffer('assistant', '3');
    ok_int(scalar(@{$chat->{screen_buffer}}), 3, 'buffered 3 with max=3');
    ok_str($chat->{screen_buffer}->[0]->{content}, '1', 'first still present at exact boundary');

    # One more causes eviction
    $chat->add_to_buffer('assistant', '4');
    ok_int(scalar(@{$chat->{screen_buffer}}), 3, 'still 3 after overflow');
    ok_str($chat->{screen_buffer}->[0]->{content}, '2', 'oldest evicted (1 gone, 2 now oldest)');
}

print "\n$pass passed, $fail failed\n";
exit($fail > 0 ? 1 : 0);