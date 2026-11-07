#!/usr/bin/env perl
# test_interact_user_framing.pl - Verify interact tool wraps user replies
# in an attribution envelope (question echo + reply + framing note) so the
# model binds the reply to its pending question instead of interpreting a
# bare string (which weak models misread as a system directive when the
# wording collides with framework vocabulary, e.g. "memory" in an LTM
# context). metadata.user_response carries the raw text; session storage
# is NOT done here (the caller handles it atomically).

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use CLIO::Tools::Interact;

# Minimal mock UI. request_collaboration returns a hashref matching the
# shape used in production (source, input, events) or a plain scalar for
# the standard (non-listen_broker) path.
package MockUI;
sub new {
    my ($class, %args) = @_;
    return bless {
        next_input  => $args{next_input}  // 'test user reply',
        next_result => $args{next_result} // undef,
        cancel      => $args{cancel}      // 0,  # When set, request_collaboration returns undef
        spinner     => undef,
        theme_mgr   => undef,
    }, $class;
}
sub request_collaboration {
    my ($self, $message, $context, $options) = @_;
    return undef if $self->{cancel};
    if ($options && $options->{listen_broker}) {
        return $self->{next_result} if defined $self->{next_result};
        return {
            source => 'user',
            input  => $self->{next_input},
            events => [],
        };
    }
    return $self->{next_input};
}
sub can             { 1 }
sub colorize        { $_[1] }
sub spinner         { undef }
sub theme_mgr       { undef }
sub get_tool_display_format { 'inline' }

package MockBrokerClient;
sub new {
    my ($class, %args) = @_;
    return bless { response => $args{response}, poll_count => 0 }, $class;
}
sub send_question   { return 'msg-123' }
sub poll_my_inbox {
    my ($self) = @_;
    return [] if $self->{poll_count}++;
    return [
        {
            type    => 'clarification',
            from    => 'user',
            content => $self->{response},
        },
    ];
}

package main;

package FakeSession;
sub new { return bless { messages => [] }, shift; }
sub add_message {
    my ($self, $role, $content, $opts) = @_;
    push @{$self->{messages}}, { role => $role, content => $content, opts => $opts || {} };
    return scalar(@{$self->{messages}});
}

package main;

sub make_session { return FakeSession->new; }

# === Test 1: standard mode wraps the reply in the attribution envelope ===
{
    my $ui    = MockUI->new(next_input => 'yeah, lets proceed');
    my $sess  = make_session;
    my $tool  = CLIO::Tools::Interact->new(debug => 0);
    my $result = $tool->execute(
        { operation => 'request_input', message => 'Where should I edit?' },
        { ui => $ui, session => $sess }
    );
    ok($result->{success}, 'standard mode: success=1');
    like($result->{output}, qr/^\[USER REPLY to your question above\]\n/, 'standard mode: output starts with envelope header');
    like($result->{output}, qr/Your question: "Where should I edit\?"/, 'standard mode: output echoes the question');
    like($result->{output}, qr/User's answer: "yeah, lets proceed"/, 'standard mode: output carries the raw reply');
    like($result->{output}, qr/not a system directive/, 'standard mode: framing note disambiguates from system directives');
    is(
        $result->{metadata}{user_response},
        'yeah, lets proceed',
        'standard mode: metadata.user_response carries the raw text'
    );
    is(
        scalar(@{$sess->{messages}}),
        0,
        'standard mode: NO redundant session messages (caller handles storage)'
    );
}

# === Test 2: listen_broker mode (user source) wraps the reply too ===
{
    my $ui   = MockUI->new(next_input => 'quick question before I start');
    my $sess = make_session;
    my $tool = CLIO::Tools::Interact->new(debug => 0);
    my $result = $tool->execute(
        {
            operation     => 'request_input',
            message       => 'Continue?',
            listen_broker => 1,
        },
        { ui => $ui, session => $sess }
    );
    ok($result->{success}, 'listen_broker user source: success=1');
    like($result->{output}, qr/^\[USER REPLY to your question above\]\n/, 'listen_broker user source: output starts with envelope header');
    like($result->{output}, qr/"Continue\?"/, 'listen_broker user source: output echoes the question');
    like($result->{output}, qr/User's answer: "quick question before I start"/, 'listen_broker user source: output carries the raw reply');
    is(
        $result->{metadata}{source},
        'user',
        'listen_broker user source: metadata.source is "user"'
    );
    is(
        $result->{metadata}{user_response},
        'quick question before I start',
        'listen_broker user source: metadata.user_response carries the raw text'
    );
}

# === Test 3: listen_broker mode (agent_event source) does NOT envelope ===
# When the request_collaboration returns an agent_event, the output is
# purely agent messages - no user reply text, so no envelope.
{
    my $ui = MockUI->new(
        next_input  => undef,
        next_result => {
            source   => 'agent_event',
            input    => undef,
            events   => [
                { type => 'agent_message', agent_id => 'agent-1',
                  message_type => 'message', content => 'subagent finished' },
            ],
        },
    );
    my $sess = make_session;
    my $tool = CLIO::Tools::Interact->new(debug => 0);
    my $result = $tool->execute(
        {
            operation     => 'request_input',
            message       => 'Continue?',
            listen_broker => 1,
        },
        { ui => $ui, session => $sess }
    );
    ok($result->{success}, 'listen_broker agent_event: success=1');
    unlike(
        $result->{output},
        qr/USER REPLY/,
        'listen_broker agent_event: output is NOT enveloped (no user reply)'
    );
    like(
        $result->{output},
        qr/Agent message received:/,
        'listen_broker agent_event: output contains agent message header'
    );
}

# === Test 4: listen_broker mode (user reply + agent events while waiting) ===
# User reply is enveloped, then the agent-events section follows it.
{
    my $ui = MockUI->new(
        next_input => 'keep both, drop the other one',
        next_result => {
            source => 'user',
            input  => 'keep both, drop the other one',
            events => [
                { type => 'agent_message', agent_id => 'agent-7',
                  message_type => 'status', content => 'build finished' },
            ],
        },
    );
    my $sess = make_session;
    my $tool = CLIO::Tools::Interact->new(debug => 0);
    my $result = $tool->execute(
        {
            operation     => 'request_input',
            message       => 'Keep or evict?',
            listen_broker => 1,
        },
        { ui => $ui, session => $sess }
    );
    ok($result->{success}, 'listen_broker user+events: success=1');
    like($result->{output}, qr/^\[USER REPLY to your question above\]\n/, 'listen_broker user+events: envelope before agent events');
    like($result->{output}, qr/"Keep or evict\?"/, 'listen_broker user+events: question echoed');
    like(
        $result->{output},
        qr/Agent messages received while waiting:\n\[agent-7\] \(status\): build finished/,
        'listen_broker user+events: agent events appended after envelope'
    );
}

# === Test 5: long questions are truncated in the envelope ===
{
    my $long_question = 'x' x 600;
    my $ui    = MockUI->new(next_input => 'ok');
    my $sess  = make_session;
    my $tool  = CLIO::Tools::Interact->new(debug => 0);
    my $result = $tool->execute(
        { operation => 'request_input', message => $long_question },
        { ui => $ui, session => $sess }
    );
    ok($result->{success}, 'truncation: success=1');
    like($result->{output}, qr/\.\.\. \[truncated\]/, 'truncation: marker present for >400 char question');
    unlike($result->{output}, qr/x{401}/, 'truncation: full 600-char question not echoed');
    is(
        $result->{metadata}{user_response},
        'ok',
        'truncation: metadata.user_response unaffected by truncation'
    );
}

# === Test 6: cancellation (UI returns undef) produces error, no envelope ===
{
    my $ui = MockUI->new(next_input => 'cancel_signal', cancel => 1);
    my $sess = make_session;
    my $tool = CLIO::Tools::Interact->new(debug => 0);
    my $result = $tool->execute(
        { operation => 'request_input', message => 'Continue?' },
        { ui => $ui, session => $sess }
    );
    ok(!$result->{success}, 'cancel: success=0');
    like($result->{error}, qr/cancel/, 'cancel: error mentions cancellation');
    is(scalar(@{$sess->{messages}}), 0, 'cancel: no session messages stored');
}

# === Test 7: broker sub-agent mode wraps the response too ===
{
    my $broker = MockBrokerClient->new(response => 'go with the envelope');
    my $sess   = make_session;
    my $tool   = CLIO::Tools::Interact->new(debug => 0);
    my $result = $tool->execute(
        { operation => 'request_input', message => 'Which option: A or B?' },
        { session => $sess, broker_client => $broker }
    );
    ok($result->{success}, 'broker mode: success=1');
    like($result->{output}, qr/^\[USER REPLY to your question above\]\n/, 'broker mode: output starts with envelope header');
    like($result->{output}, qr/"Which option: A or B\?"/, 'broker mode: question echoed');
    like($result->{output}, qr/User's answer: "go with the envelope"/, 'broker mode: raw reply carried');
    is(
        $result->{metadata}{user_response},
        'go with the envelope',
        'broker mode: metadata.user_response carries the raw text'
    );
    is($result->{metadata}{via_broker}, 1, 'broker mode: metadata.via_broker set');
}

done_testing();
