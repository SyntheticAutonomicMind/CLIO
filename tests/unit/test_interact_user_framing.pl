#!/usr/bin/env perl
# test_interact_user_framing.pl - Verify interact tool returns raw user replies
# (no [USER REPLY] tagging) and stores interaction history in the session log.

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More tests => 12;
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
        spinner     => undef,
        theme_mgr   => undef,
    }, $class;
}
sub request_collaboration {
    my ($self, $message, $context, $options) = @_;
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

# === Test 1: standard mode returns raw (unframed) user reply ===
{
    my $ui    = MockUI->new(next_input => 'yeah, lets proceed');
    my $sess  = make_session;
    my $tool  = CLIO::Tools::Interact->new(debug => 0);
    my $result = $tool->execute(
        { operation => 'request_input', message => 'Where should I edit?' },
        { ui => $ui, session => $sess }
    );
    ok($result->{success}, 'standard mode: success=1');
    is(
        $result->{output},
        'yeah, lets proceed',
        'standard mode: output is raw (not framed)'
    );
    is(
        $result->{metadata}{user_response},
        'yeah, lets proceed',
        'standard mode: metadata.user_response carries the raw text'
    );
    is(
        scalar(@{$sess->{messages}}),
        2,
        'standard mode: interaction stored as 2 messages in session log'
    );
    is($sess->{messages}[0]{role}, 'assistant', 'standard mode: request stored as assistant message');
    is($sess->{messages}[1]{role}, 'user', 'standard mode: response stored as user message');
}

# === Test 2: listen_broker mode (user source) returns raw user reply ===
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
    is(
        $result->{output},
        'quick question before I start',
        'listen_broker user source: output is raw (not framed)'
    );
    is(
        $result->{metadata}{source},
        'user',
        'listen_broker user source: metadata.source is "user"'
    );
}

# === Test 3: listen_broker mode (agent_event source) does NOT include user reply ===
# When the request_collaboration returns an agent_event, the output is
# purely agent messages — no user reply text.
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
        qr/\[USER REPLY\]/,
        'listen_broker agent_event: output is NOT framed (no user reply)'
    );
    like(
        $result->{output},
        qr/Agent message received:/,
        'listen_broker agent_event: output contains agent message header'
    );
}