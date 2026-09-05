#!/usr/bin/env perl
# test_interact_user_framing.pl - Verify interact tool frames user replies
# in the tool result so the model unambiguously treats the content as a
# fresh user turn rather than the bare content of a role='tool' message.

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More tests => 9;
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

# === Test 1: standard mode frames user reply ===
{
    my $ui    = MockUI->new(next_input => 'yeah, lets proceed');
    my $sess  = make_session;
    my $tool  = CLIO::Tools::Interact->new(debug => 0);
    my $result = $tool->execute(
        { operation => 'request_input', message => 'Where should I edit?' },
        { ui => $ui, session => $sess }
    );
    ok($result->{success}, 'standard mode: success=1');
    like(
        $result->{output},
        qr/^\[USER REPLY\]\nyeah, lets proceed\n\[END USER REPLY\]$/,
        'standard mode: output is framed as [USER REPLY]...[/USER REPLY]'
    );
    is(
        $result->{metadata}{user_response},
        'yeah, lets proceed',
        'standard mode: metadata.user_response carries the unframed text'
    );
}

# === Test 2: listen_broker mode (user source) frames the user portion ===
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
    like(
        $result->{output},
        qr/^\[USER REPLY\]\nquick question before I start\n\[END USER REPLY\]$/,
        'listen_broker user source: output is framed'
    );
    is(
        $result->{metadata}{source},
        'user',
        'listen_broker user source: metadata.source is "user"'
    );
}

# === Test 3: listen_broker mode (agent_event source) does NOT frame ===
# When the request_collaboration returns an agent_event, the user-input
# framing should be skipped - the output is purely agent messages.
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
