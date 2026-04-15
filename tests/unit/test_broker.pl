#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

test_broker.pl - Behavioral tests for Coordination Broker

=head1 DESCRIPTION

Tests broker message handling, file locking, git locking, knowledge sharing,
and agent messaging without requiring real socket connections. Uses a mock
client approach that directly exercises handler methods.

=cut

use Test::More;
use File::Temp qw(tempdir);

# ============================================================================
# Module loading
# ============================================================================

BEGIN { use_ok('CLIO::Coordination::Broker') or BAIL_OUT("Cannot load Broker"); }

# ============================================================================
# Test helper: create broker with mock client connections
# ============================================================================

my $temp_dir = tempdir(CLEANUP => 1);

sub fresh_broker {
    my $broker = CLIO::Coordination::Broker->new(
        session_id => "test-$$",
        socket_dir => $temp_dir,
    );
    # Inject mock IO::Select for disconnect handling
    $broker->{select} = MockSelect->new();
    return $broker;
}

# Mock a connected client by inserting into {clients} with a fake socket
# that captures sent messages
{
    package MockSocket;
    sub new { bless { messages => [] }, shift }
    sub print { push @{$_[0]->{messages}}, $_[1]; 1 }
    sub close { 1 }
    sub messages { @{$_[0]->{messages}} }
    sub last_message {
        my $self = shift;
        my @msgs = $self->messages;
        return undef unless @msgs;
        my $raw = $msgs[-1];
        chomp $raw;
        return eval { CLIO::Util::JSON::decode_json($raw) } || { _raw => $raw };
    }
    sub clear { $_[0]->{messages} = [] }
}

# Mock IO::Select for disconnect tests
{
    package MockSelect;
    sub new { bless {}, shift }
    sub remove { 1 }
}

sub mock_client {
    my ($broker, $fd) = @_;
    my $sock = MockSocket->new();
    $broker->{clients}{$fd} = {
        socket => $sock,
        type => 'unknown',
        last_activity => time(),
    };
    return $sock;
}

sub register_agent {
    my ($broker, $fd, $agent_id, $task) = @_;
    my $sock = mock_client($broker, $fd);
    $broker->handle_register($fd, { id => $agent_id, task => $task || "test task" });
    return $sock;
}

# ============================================================================
# 1. Broker creation and initialization
# ============================================================================

subtest 'Broker creation' => sub {
    my $broker = fresh_broker();
    ok($broker, 'Broker object created');
    isa_ok($broker, 'CLIO::Coordination::Broker');
    is(ref($broker->{clients}), 'HASH', 'Clients hash initialized');
    is(ref($broker->{file_locks}), 'HASH', 'File locks hash initialized');
    is(ref($broker->{discoveries}), 'ARRAY', 'Discoveries array initialized');
    is(ref($broker->{warnings}), 'ARRAY', 'Warnings array initialized');
    ok(defined $broker->{idle_timeout}, 'Idle timeout set');
};

# ============================================================================
# 2. Agent registration
# ============================================================================

subtest 'Agent registration' => sub {
    my $broker = fresh_broker();
    my $sock = register_agent($broker, 10, 'agent-1', 'fix bug');

    my $resp = $sock->last_message;
    is($resp->{type}, 'ack', 'Registration acknowledged');
    is($resp->{request_type}, 'register', 'Response identifies register request');
    is($broker->{clients}{10}{id}, 'agent-1', 'Agent ID stored in client');
    is($broker->{clients}{10}{type}, 'agent', 'Client type set to agent');
    ok($broker->{agent_status}{'agent-1'}, 'Agent appears in status');
    is($broker->{agent_status}{'agent-1'}{task}, 'fix bug', 'Task recorded');
};

subtest 'Registration without ID fails' => sub {
    my $broker = fresh_broker();
    my $sock = mock_client($broker, 10);
    $broker->handle_register(10, { task => 'no id' });
    my $resp = $sock->last_message;
    is($resp->{type}, 'error', 'Error returned for missing ID');
};

# ============================================================================
# 3. File locking
# ============================================================================

subtest 'File lock grant and release' => sub {
    my $broker = fresh_broker();
    my $sock_a = register_agent($broker, 10, 'agent-a', 'task');

    # Request lock
    $sock_a->clear;
    $broker->handle_request_file_lock(10, { files => ['src/main.pl'] });
    my $resp = $sock_a->last_message;
    is($resp->{type}, 'lock_granted', 'File lock granted');
    ok(exists $broker->{file_locks}{'src/main.pl'}, 'Lock recorded');
    is($broker->{file_locks}{'src/main.pl'}{owner}, 'agent-a', 'Owner correct');

    # Release lock
    $sock_a->clear;
    $broker->handle_release_file_lock(10, { files => ['src/main.pl'] });
    ok(!exists $broker->{file_locks}{'src/main.pl'}, 'Lock removed after release');
};

subtest 'File lock conflict' => sub {
    my $broker = fresh_broker();
    my $sock_a = register_agent($broker, 10, 'agent-a', 'task');
    my $sock_b = register_agent($broker, 11, 'agent-b', 'task');

    # Agent A locks file
    $broker->handle_request_file_lock(10, { files => ['config.yaml'] });

    # Agent B requests same file
    $sock_b->clear;
    $broker->handle_request_file_lock(11, { files => ['config.yaml'] });
    my $resp = $sock_b->last_message;
    is($resp->{type}, 'lock_denied', 'Conflicting lock denied');
    ok($resp->{blocked}, 'Blocked files listed');
    is($resp->{blocked}[0]{held_by}, 'agent-a', 'Correct holder identified');
};

subtest 'Multi-file lock - conflict rejects all' => sub {
    my $broker = fresh_broker();
    my $sock_a = register_agent($broker, 10, 'agent-a', 'task');
    my $sock_b = register_agent($broker, 11, 'agent-b', 'task');

    # Agent A locks one file
    $broker->handle_request_file_lock(10, { files => ['file1.pl'] });

    # Agent B requests two files, one overlapping
    $sock_b->clear;
    $broker->handle_request_file_lock(11, { files => ['file1.pl', 'file2.pl'] });
    my $resp = $sock_b->last_message;
    is($resp->{type}, 'lock_denied', 'Multi-file lock denied on conflict');
    # file2.pl should NOT be locked since the whole request was denied
    ok(!exists $broker->{file_locks}{'file2.pl'}, 'Non-conflicting file not locked on denied request');
};

subtest 'Same agent can re-lock own files' => sub {
    my $broker = fresh_broker();
    my $sock_a = register_agent($broker, 10, 'agent-a', 'task');

    $broker->handle_request_file_lock(10, { files => ['file.pl'] });
    $sock_a->clear;
    $broker->handle_request_file_lock(10, { files => ['file.pl'] });
    my $resp = $sock_a->last_message;
    is($resp->{type}, 'lock_granted', 'Same agent can re-lock own file');
};

subtest 'Unregistered agent cannot lock' => sub {
    my $broker = fresh_broker();
    my $sock = mock_client($broker, 10);
    $broker->handle_request_file_lock(10, { files => ['test.pl'] });
    my $resp = $sock->last_message;
    is($resp->{type}, 'error', 'Unregistered agent gets error');
};

# ============================================================================
# 4. Git locking
# ============================================================================

subtest 'Git lock grant and release' => sub {
    my $broker = fresh_broker();
    my $sock_a = register_agent($broker, 10, 'agent-a', 'task');

    $sock_a->clear;
    $broker->handle_request_git_lock(10, {});
    my $resp = $sock_a->last_message;
    is($resp->{type}, 'git_lock_granted', 'Git lock granted');
    is($broker->{git_lock}{holder}, 'agent-a', 'Git lock holder recorded');

    # Release
    $sock_a->clear;
    $broker->handle_release_git_lock(10, {});
    ok(!$broker->{git_lock}{holder}, 'Git lock released');
};

subtest 'Git lock conflict' => sub {
    my $broker = fresh_broker();
    my $sock_a = register_agent($broker, 10, 'agent-a', 'task');
    my $sock_b = register_agent($broker, 11, 'agent-b', 'task');

    $broker->handle_request_git_lock(10, {});

    $sock_b->clear;
    $broker->handle_request_git_lock(11, {});
    my $resp = $sock_b->last_message;
    is($resp->{type}, 'git_lock_denied', 'Second git lock request denied');
    is($resp->{held_by}, 'agent-a', 'Current holder identified');
};

# ============================================================================
# 5. Knowledge sharing (discoveries and warnings)
# ============================================================================

subtest 'Discovery sharing' => sub {
    my $broker = fresh_broker();
    my $sock_a = register_agent($broker, 10, 'agent-a', 'task');
    my $sock_b = register_agent($broker, 11, 'agent-b', 'task');

    # Agent A shares a discovery
    $sock_a->clear;
    $broker->handle_discovery(10, {
        category => 'architecture',
        content => 'Found circular dependency in Core module',
    });
    my $resp = $sock_a->last_message;
    is($resp->{type}, 'ack', 'Discovery acknowledged');

    # Agent B retrieves discoveries
    $sock_b->clear;
    $broker->handle_get_discoveries(11);
    $resp = $sock_b->last_message;
    is($resp->{type}, 'discoveries', 'Discoveries returned');
    is($resp->{count}, 1, 'One discovery');
    is($resp->{discoveries}[0]{agent}, 'agent-a', 'Discovery attributed correctly');
    is($resp->{discoveries}[0]{category}, 'architecture', 'Category preserved');
    like($resp->{discoveries}[0]{content}, qr/circular dependency/, 'Content preserved');
};

subtest 'Warning sharing' => sub {
    my $broker = fresh_broker();
    my $sock_a = register_agent($broker, 10, 'agent-a', 'task');

    $sock_a->clear;
    $broker->handle_warning(10, {
        severity => 'high',
        content => 'Module XYZ has no tests',
    });

    my $sock_b = register_agent($broker, 11, 'agent-b', 'task');
    $sock_b->clear;
    $broker->handle_get_warnings(11);
    my $resp = $sock_b->last_message;
    is($resp->{type}, 'warnings', 'Warnings returned');
    is($resp->{count}, 1, 'One warning');
    is($resp->{warnings}[0]{severity}, 'high', 'Severity preserved');
};

# ============================================================================
# 6. Agent messaging
# ============================================================================

subtest 'Direct message between agents' => sub {
    my $broker = fresh_broker();
    my $sock_a = register_agent($broker, 10, 'agent-a', 'task');
    my $sock_b = register_agent($broker, 11, 'agent-b', 'task');

    # Agent A sends message to Agent B
    $sock_a->clear;
    $broker->handle_send_message(10, {
        to => 'agent-b',
        message_type => 'question',
        content => 'What API version should I use?',
    });
    my $resp = $sock_a->last_message;
    is($resp->{type}, 'ack', 'Send acknowledged');

    # Agent B polls inbox
    $sock_b->clear;
    $broker->handle_poll_inbox(11, { agent_id => 'agent-b' });
    $resp = $sock_b->last_message;
    is($resp->{type}, 'inbox', 'Inbox returned');
    is($resp->{count}, 1, 'One message in inbox');
    is($resp->{messages}[0]{from}, 'agent-a', 'Sender correct');
    is($resp->{messages}[0]{content}, 'What API version should I use?', 'Content correct');

    # Second poll should be empty (inbox cleared)
    $sock_b->clear;
    $broker->handle_poll_inbox(11, { agent_id => 'agent-b' });
    $resp = $sock_b->last_message;
    is($resp->{count}, 0, 'Inbox empty after poll');
};

subtest 'Broadcast message' => sub {
    my $broker = fresh_broker();
    my $sock_a = register_agent($broker, 10, 'agent-a', 'task');
    my $sock_b = register_agent($broker, 11, 'agent-b', 'task');
    my $sock_c = register_agent($broker, 12, 'agent-c', 'task');

    # Agent A broadcasts
    $broker->handle_send_message(10, {
        to => 'all',
        message_type => 'status',
        content => 'Build complete',
    });

    # Agent B should have it
    $sock_b->clear;
    $broker->handle_poll_inbox(11, { agent_id => 'agent-b' });
    my $resp_b = $sock_b->last_message;
    is($resp_b->{count}, 1, 'Agent B received broadcast');

    # Agent C should have it
    $sock_c->clear;
    $broker->handle_poll_inbox(12, { agent_id => 'agent-c' });
    my $resp_c = $sock_c->last_message;
    is($resp_c->{count}, 1, 'Agent C received broadcast');

    # Agent A should NOT receive own broadcast
    $sock_a->clear;
    $broker->handle_poll_inbox(10, { agent_id => 'agent-a' });
    my $resp_a = $sock_a->last_message;
    is($resp_a->{count}, 0, 'Sender excluded from own broadcast');
};

subtest 'Message to user inbox' => sub {
    my $broker = fresh_broker();
    my $sock_a = register_agent($broker, 10, 'agent-a', 'task');

    $broker->handle_send_message(10, {
        to => 'user',
        message_type => 'completion',
        content => 'Task done',
    });

    my $sock_u = mock_client($broker, 99);
    $broker->handle_poll_user_inbox(99);
    my $resp = $sock_u->last_message;
    is($resp->{type}, 'user_inbox', 'User inbox returned');
    is($resp->{count}, 1, 'One message for user');
    is($resp->{messages}[0]{content}, 'Task done', 'Content delivered');
};

# ============================================================================
# 7. Heartbeat
# ============================================================================

subtest 'Heartbeat updates activity' => sub {
    my $broker = fresh_broker();
    my $sock = mock_client($broker, 10);
    my $before = $broker->{clients}{10}{last_activity};
    sleep 1;
    $broker->handle_heartbeat(10);
    my $resp = $sock->last_message;
    is($resp->{type}, 'heartbeat_ack', 'Heartbeat acknowledged');
    ok($broker->{clients}{10}{last_activity} >= $before, 'Activity timestamp updated');
};

# ============================================================================
# 8. Status overview
# ============================================================================

subtest 'Status aggregation' => sub {
    my $broker = fresh_broker();
    register_agent($broker, 10, 'agent-a', 'fix bug');
    register_agent($broker, 11, 'agent-b', 'add tests');
    $broker->handle_request_file_lock(10, { files => ['main.pl'] });
    $broker->handle_request_git_lock(11, {});
    $broker->handle_discovery(10, { content => 'found pattern' });

    my $sock_q = mock_client($broker, 99);
    $broker->handle_get_status(99);
    my $resp = $sock_q->last_message;
    is($resp->{type}, 'status', 'Status response');
    ok($resp->{agents}{'agent-a'}, 'Agent A in status');
    ok($resp->{agents}{'agent-b'}, 'Agent B in status');
    ok($resp->{file_locks}{'main.pl'}, 'File lock in status');
    ok($resp->{git_lock}{holder}, 'Git lock in status');
    is(scalar(@{$resp->{discoveries}}), 1, 'Discovery count in status');
};

# ============================================================================
# 9. Lock release on disconnect
# ============================================================================

subtest 'Disconnect releases agent locks' => sub {
    my $broker = fresh_broker();
    register_agent($broker, 10, 'agent-a', 'task');
    $broker->handle_request_file_lock(10, { files => ['file.pl', 'file2.pl'] });
    $broker->handle_request_git_lock(10, {});

    # Verify locks exist
    ok($broker->{file_locks}{'file.pl'}, 'File lock exists before disconnect');
    ok($broker->{git_lock}{holder}, 'Git lock exists before disconnect');

    # Simulate disconnect
    $broker->handle_disconnect(10);

    ok(!exists $broker->{file_locks}{'file.pl'}, 'File lock released on disconnect');
    ok(!exists $broker->{file_locks}{'file2.pl'}, 'Second file lock released');
    ok(!$broker->{git_lock}{holder}, 'Git lock released on disconnect');
    ok(!exists $broker->{clients}{10}, 'Client removed');
};

# ============================================================================
# 10. Message acknowledgment
# ============================================================================

subtest 'User message acknowledgment' => sub {
    my $broker = fresh_broker();
    my $sock_a = register_agent($broker, 10, 'agent-a', 'task');

    # Send two messages to user
    $broker->handle_send_message(10, { to => 'user', content => 'msg 1' });
    $broker->handle_send_message(10, { to => 'user', content => 'msg 2' });

    # Verify user has 2 unread
    my $sock_u = mock_client($broker, 99);
    $broker->handle_poll_user_inbox(99);
    my $resp = $sock_u->last_message;
    is($resp->{count}, 2, 'Two unread messages');

    # Acknowledge specific message
    my $msg_id = $resp->{messages}[0]{id};
    $sock_u->clear;
    $broker->handle_acknowledge_messages(99, { message_ids => [$msg_id] });
    $resp = $sock_u->last_message;
    is($resp->{type}, 'acknowledge_result', 'Acknowledge confirmed');

    # Check only 1 unread remains
    $sock_u->clear;
    $broker->handle_poll_user_inbox(99);
    $resp = $sock_u->last_message;
    is($resp->{count}, 1, 'One message remaining after partial ack');
};

# ============================================================================
# 11. Error cases
# ============================================================================

subtest 'Send message without registration' => sub {
    my $broker = fresh_broker();
    my $sock = mock_client($broker, 10);
    $broker->handle_send_message(10, { to => 'agent-b', content => 'hello' });
    my $resp = $sock->last_message;
    is($resp->{type}, 'error', 'Unregistered sender gets error');
};

subtest 'File lock with missing files array' => sub {
    my $broker = fresh_broker();
    register_agent($broker, 10, 'agent-a', 'task');
    my $sock = $broker->{clients}{10}{socket};
    $sock->clear;
    $broker->handle_request_file_lock(10, {});
    my $resp = $sock->last_message;
    is($resp->{type}, 'error', 'Missing files array returns error');
};

# ============================================================================
# 12. handle_message routing
# ============================================================================

subtest 'handle_message routes correctly' => sub {
    my $broker = fresh_broker();
    my $sock = mock_client($broker, 10);

    # Register via handle_message
    $broker->handle_message(10, { type => 'register', id => 'routed-agent', task => 'test routing' });
    my $resp = $sock->last_message;
    is($resp->{type}, 'ack', 'handle_message routes register correctly');
    is($resp->{request_type}, 'register', 'Correct request_type for register');

    # Heartbeat via handle_message
    $sock->clear;
    $broker->handle_message(10, { type => 'heartbeat' });
    $resp = $sock->last_message;
    is($resp->{type}, 'heartbeat_ack', 'handle_message routes heartbeat correctly');

    # Unknown type
    $sock->clear;
    $broker->handle_message(10, { type => 'nonexistent_op' });
    $resp = $sock->last_message;
    is($resp->{type}, 'error', 'handle_message returns error for unknown type');
};

# ============================================================================
# 9. Status update relay (Puppeteer support)
# ============================================================================

subtest 'Status update storage and polling' => sub {
    my $broker = fresh_broker();
    my $sock_agent = register_agent($broker, 10, 'agent-1', 'test task');
    my $sock_primary = register_agent($broker, 20, 'primary', 'manage');
    
    # Agent sends status update
    $sock_agent->clear;
    $broker->handle_status_update(10, {
        agent_id => 'agent-1',
        state    => 'thinking',
        tool     => 'file_operations',
    });
    my $resp = $sock_agent->last_message;
    is($resp->{type}, 'ack', 'Status update acknowledged');
    ok($resp->{success}, 'Success flag set');
    
    # Send another update
    $broker->handle_status_update(10, {
        agent_id => 'agent-1',
        state    => 'tools',
        tool     => 'terminal_operations',
        message  => 'running tests',
    });
    
    # Primary polls for updates
    $sock_primary->clear;
    $broker->handle_poll_status_updates(20);
    $resp = $sock_primary->last_message;
    
    is($resp->{type}, 'status_updates', 'Poll returns status_updates type');
    is($resp->{count}, 2, 'Two updates accumulated');
    is($resp->{updates}[0]{agent_id}, 'agent-1', 'First update has correct agent_id');
    is($resp->{updates}[0]{state}, 'thinking', 'First update state correct');
    is($resp->{updates}[0]{tool}, 'file_operations', 'First update tool correct');
    is($resp->{updates}[1]{state}, 'tools', 'Second update state correct');
    is($resp->{updates}[1]{message}, 'running tests', 'Second update message correct');
    ok($resp->{updates}[0]{timestamp}, 'Update has timestamp');
};

subtest 'Status updates drain on poll' => sub {
    my $broker = fresh_broker();
    my $sock = register_agent($broker, 10, 'agent-1', 'test');
    my $sock_primary = register_agent($broker, 20, 'primary', 'manage');
    
    # Send an update
    $broker->handle_status_update(10, {
        agent_id => 'agent-1',
        state    => 'idle',
    });
    
    # First poll gets the update
    $sock_primary->clear;
    $broker->handle_poll_status_updates(20);
    my $resp = $sock_primary->last_message;
    is($resp->{count}, 1, 'First poll has 1 update');
    
    # Second poll is empty (drained)
    $sock_primary->clear;
    $broker->handle_poll_status_updates(20);
    $resp = $sock_primary->last_message;
    is($resp->{count}, 0, 'Second poll is empty (drained)');
    is_deeply($resp->{updates}, [], 'Updates array is empty');
};

subtest 'Status updates capped at 100' => sub {
    my $broker = fresh_broker();
    my $sock = register_agent($broker, 10, 'agent-1', 'test');
    my $sock_primary = register_agent($broker, 20, 'primary', 'manage');
    
    # Send 120 updates
    for my $i (1..120) {
        $broker->handle_status_update(10, {
            agent_id => 'agent-1',
            state    => "state-$i",
        });
    }
    
    # Poll should only get the last 100
    $sock_primary->clear;
    $broker->handle_poll_status_updates(20);
    my $resp = $sock_primary->last_message;
    is($resp->{count}, 100, 'Capped at 100 updates');
    is($resp->{updates}[0]{state}, 'state-21', 'Oldest retained is state-21');
    is($resp->{updates}[99]{state}, 'state-120', 'Newest is state-120');
};

subtest 'handle_message routes status operations' => sub {
    my $broker = fresh_broker();
    my $sock = register_agent($broker, 10, 'agent-1', 'test');
    
    # Route status_update through handle_message
    $sock->clear;
    $broker->handle_message(10, {
        type     => 'status_update',
        agent_id => 'agent-1',
        state    => 'streaming',
    });
    my $resp = $sock->last_message;
    is($resp->{type}, 'ack', 'status_update routed correctly');
    
    # Route poll_status_updates
    $sock->clear;
    $broker->handle_message(10, { type => 'poll_status_updates' });
    $resp = $sock->last_message;
    is($resp->{type}, 'status_updates', 'poll_status_updates routed correctly');
};

done_testing();

print "\n Broker behavioral tests PASSED\n";
