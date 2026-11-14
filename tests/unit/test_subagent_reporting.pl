#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

test_subagent_reporting.pl - Tests for sub-agent result delivery and reporting

=head1 DESCRIPTION

Covers the sub-agent reporting path:

- The agent's final answer reaches the manager. SimpleAIAgent stores the
  final text in 'final_response' and never populates 'content', so
  reading the wrong key silently dropped every agent's findings.
- Exited agents are detected. A child that has exited but not been
  reaped is a zombie, and zombies still answer kill(0) successfully.
- The user inbox and its history are bounded.
- The 'report' operation returns an agent's full report, and the inbox
  returns a bounded preview.
- Agent activity is coalesced so a busy agent does not flood the
  transcript.

=cut

use Test::More;
use File::Temp qw(tempdir);
use POSIX qw(WNOHANG);

BEGIN {
    use_ok('CLIO::Coordination::SubAgent') or BAIL_OUT("Cannot load SubAgent");
    use_ok('CLIO::Coordination::Broker') or BAIL_OUT("Cannot load Broker");
    use_ok('CLIO::Tools::SubAgentOperations') or BAIL_OUT("Cannot load SubAgentOperations");
    use_ok('CLIO::UI::Chat') or BAIL_OUT("Cannot load Chat");
}

my $temp_dir = tempdir(CLEANUP => 1);

# ============================================================================
# 1. Result extraction
# ============================================================================

subtest 'Agent result is read from the key SimpleAIAgent populates' => sub {
    my $agent = bless {}, 'CLIO::Coordination::SubAgent';

    my $report = $agent->_extract_report({
        final_response => "The findings are here.",
        ai_response    => "The findings are here.",
        content        => undef,
    });
    is($report, "The findings are here.", 'final_response is used');

    $report = $agent->_extract_report({
        ai_response => "Only ai_response.",
    });
    is($report, "Only ai_response.", 'ai_response is the fallback');

    $report = $agent->_extract_report({ content => 'only content' });
    is($report, '', 'content alone yields nothing, it is never populated');

    $report = $agent->_extract_report(undef);
    is($report, '', 'undef result yields nothing');
};

subtest 'Completion message carries the report' => sub {
    my $agent = bless {}, 'CLIO::Coordination::SubAgent';

    is($agent->_build_completion_message("real report", "the task"),
        "real report", 'the report is the completion message');

    is($agent->_build_completion_message('', "the task"),
        "Completed: the task", 'falls back to a restatement of the task');
};

# ============================================================================
# 2. Report file
# ============================================================================

subtest 'Report file is written and readable' => sub {
    my $agent = bless {}, 'CLIO::Coordination::SubAgent';
    my $agent_id = "test-report-$$";

    my $report_path = CLIO::Coordination::SubAgent->report_path_for($agent_id);
    my $log_path = CLIO::Coordination::SubAgent->log_path_for($agent_id);
    isnt($report_path, $log_path, 'report and log are separate files');

    my $written = $agent->_write_report($agent_id, "line one\nline two\n");
    ok($written, 'report written');
    ok(-f $report_path, 'report file exists');

    open my $fh, '<:encoding(UTF-8)', $report_path or die "Cannot read report: $!";
    my $content = do { local $/; <$fh> };
    close $fh;
    is($content, "line one\nline two\n", 'report content round trips');

    unlink $report_path;
};

# ============================================================================
# 3. Exit detection
# ============================================================================

subtest 'Exited agents are detected and reaped' => sub {
    my $manager = CLIO::Coordination::SubAgent->new(session_id => "test-exit-$$");

    # Fork a child that exits straight away, then leave it unreaped.
    my $pid = fork();
    die "Cannot fork: $!" unless defined $pid;
    if ($pid == 0) {
        exit 0;
    }
    sleep 1;

    $manager->{agents}{'agent-test'} = {
        pid    => $pid,
        task   => 'test task',
        status => 'running',
        mode   => 'oneshot',
        started => time(),
    };

    # The zombie still answers kill(0) successfully, so the old check
    # reported the agent as running forever.
    is(kill(0, $pid), 1, 'unreaped child still answers kill(0)');

    my $agents = $manager->list_agents();
    is($agents->{'agent-test'}{status}, 'exited',
        'agent is reported as exited once the child is reaped');
    ok(exists $agents->{'agent-test'}{exit_code}, 'exit code recorded');

    # A second call must not try to reap the same pid again.
    my $again = $manager->list_agents();
    is($again->{'agent-test'}{status}, 'exited', 'second call is stable');
};

subtest 'Running agents are not reported as exited' => sub {
    my $manager = CLIO::Coordination::SubAgent->new(session_id => "test-run-$$");

    my $pid = fork();
    die "Cannot fork: $!" unless defined $pid;
    if ($pid == 0) {
        sleep 30;
        exit 0;
    }

    $manager->{agents}{'agent-live'} = {
        pid     => $pid,
        task    => 'test task',
        status  => 'running',
        mode    => 'oneshot',
        started => time(),
    };

    my $agents = $manager->list_agents();
    is($agents->{'agent-live'}{status}, 'running', 'live agent stays running');

    kill 'TERM', $pid;
    waitpid($pid, 0);
};

# ============================================================================
# 4. Broker queue caps
# ============================================================================

{
    package MockSocket;
    sub new { bless { messages => [] }, shift }
    sub print { push @{$_[0]->{messages}}, $_[1]; 1 }
    sub blocking { 1 }
    sub syswrite { my ($s, $d, $l, $o) = @_; $o //= 0; $l //= length($d) - $o; push @{$s->{messages}}, substr($d, $o, $l); return $l }
    sub close { 1 }
}

{
    no warnings 'redefine';
    *CLIO::Coordination::Broker::send_message = sub {
        my ($self, $fd, $msg) = @_;
        return unless exists $self->{clients}{$fd};
        my $json = CLIO::Util::JSON::encode_json($msg);
        $self->{clients}{$fd}{socket}->print("$json\n");
    };
}

subtest 'User inbox and history are bounded' => sub {
    my $broker = CLIO::Coordination::Broker->new(
        session_id => "test-cap-$$",
        socket_dir => $temp_dir,
    );
    $broker->{select} = bless {}, 'MockSelect';

    my $fd = 10;
    $broker->{clients}{$fd} = {
        socket       => MockSocket->new(),
        type         => 'agent',
        id           => 'agent-1',
        last_activity => time(),
    };

    # Push far more messages than the caps allow.
    for my $i (1 .. 700) {
        $broker->handle_send_message($fd, {
            to           => 'user',
            message_type => 'complete',
            content      => "message $i",
        });
    }

    cmp_ok(scalar @{$broker->{user_inbox}}, '<=', 500,
        'user inbox is capped');
    cmp_ok(scalar @{$broker->{user_inbox_history}}, '<=', 2000,
        'user inbox history is capped');
    cmp_ok(scalar @{$broker->{user_inbox}}, '>', 0,
        'inbox still holds messages');

    # The newest messages survive; the oldest are dropped.
    my $last = $broker->{user_inbox}[-1]{content};
    is($last, 'message 700', 'newest message retained');
};

{
    package MockSelect;
    sub new { bless {}, shift }
    sub remove { 1 }
}

# ============================================================================
# 5. The report operation
# ============================================================================

subtest 'Report operation returns the full report' => sub {
    my $tool = CLIO::Tools::SubAgentOperations->new(debug => 0);
    my $agent_id = "test-op-$$";

    my $agent = bless {}, 'CLIO::Coordination::SubAgent';
    $agent->_write_report($agent_id, "Full report body.\nSecond line.\n");

    my $result = $tool->report({ agent_id => $agent_id }, bless {}, 'CLIO::UI::Commands::SubAgent');
    ok($result->{success}, 'report operation succeeded');
    like($result->{output}, qr/Full report body/, 'report body returned');
    like($result->{output}, qr/Second line/, 'full text returned, not a preview');
    is($result->{source}, 'report', 'source is the report file');

    unlink CLIO::Coordination::SubAgent->report_path_for($agent_id);
};

subtest 'Report operation falls back to the log tail' => sub {
    my $tool = CLIO::Tools::SubAgentOperations->new(debug => 0);
    my $agent_id = "test-fallback-$$";

    my $log_path = CLIO::Coordination::SubAgent->log_path_for($agent_id);
    open my $fh, '>:encoding(UTF-8)', $log_path or die "Cannot write log: $!";
    print $fh "log line one\nlog line two\n";
    close $fh;

    my $result = $tool->report({ agent_id => $agent_id }, bless {}, 'CLIO::UI::Commands::SubAgent');
    ok($result->{success}, 'fallback succeeded');
    like($result->{output}, qr/log line one/, 'log content returned');
    is($result->{source}, 'log tail', 'source is the log tail');

    unlink $log_path;
};

subtest 'Report operation requires an agent id' => sub {
    my $tool = CLIO::Tools::SubAgentOperations->new(debug => 0);
    my $result = $tool->report({}, bless {}, 'CLIO::UI::Commands::SubAgent');
    ok(!$result->{success}, 'missing agent id is an error');
};

# ============================================================================
# 6. Inbox preview is bounded
# ============================================================================

{
    package MockBrokerClient;
    sub new { my ($class, %args) = @_; return bless { messages => $args{messages} || [] }, $class }
    sub poll_user_inbox { return $_[0]{messages} }
    sub poll_status_updates { return [] }
    sub poll_activity { return [] }
    sub acknowledge_messages { return 1 }
    sub send_message { return 1 }
}

subtest 'Inbox truncates long messages and points at the report' => sub {
    my $tool = CLIO::Tools::SubAgentOperations->new(debug => 0);

    my $long = 'x' x 5000;
    my $handler = bless {
        broker_client => MockBrokerClient->new(messages => [ {
            id => 1,
            from => 'agent-1',
            type => 'complete',
            content => $long,
            timestamp => time(),
        } ]),
    }, 'CLIO::UI::Commands::SubAgent';

    my $result = $tool->inbox($handler, {});
    ok($result->{success}, 'inbox succeeded');
    cmp_ok(length($result->{output}), '<', 5000,
        'inbox output is bounded');
    like($result->{output}, qr/truncated/,
        'truncation is signposted');
    like($result->{output}, qr/agent_report\(agent_id: 'agent-1'\)/,
        'the pointer names the agent_report callable');
};

# ============================================================================
# 7. Agent activity coalescing and card rendering
# ============================================================================

{
    package TestChat;
    our @ISA = ('CLIO::UI::Chat');
    sub new { bless { use_color => 0, _agent_projects => {} }, shift }
    sub colorize { return $_[1] }
    sub get_agent_project {
        my ($self, $id) = @_;
        return ($self->{_agent_projects} || {})->{$id};
    }
}

subtest 'Repeated activity from one agent is coalesced' => sub {
    my $chat = TestChat->new();

    my $first = {
        type => 'activity', agent_id => 'agent-1',
        action => 'start', tool => 'file_operations', detail => 'read_file',
    };
    ok($chat->_track_agent_event($first), 'first tool call is shown');

    my $second = {
        type => 'activity', agent_id => 'agent-1',
        action => 'start', tool => 'file_operations', detail => 'read_file',
    };
    ok(!$chat->_track_agent_event($second), 'same tool again is suppressed');

    my $different = {
        type => 'activity', agent_id => 'agent-1',
        action => 'start', tool => 'terminal_operations', detail => 'exec',
    };
    ok($chat->_track_agent_event($different), 'a different tool is shown');

    my $end = {
        type => 'activity', agent_id => 'agent-1',
        action => 'end', tool => 'terminal_operations', detail => 'exec',
    };
    ok(!$chat->_track_agent_event($end), 'the end event is suppressed');
};

subtest 'Agent card is rendered' => sub {
    my $chat = TestChat->new();

    my $line = $chat->_render_agent_event({
        type => 'activity', agent_id => 'agent-1',
        action => 'start', tool => 'file_operations', detail => 'read_file',
    });
    like($line, qr/AGENT-1/, 'card names the agent');
    like($line, qr/file_operations/, 'card names the tool');
    like($line, qr/read_file/, 'card names the operation');
    like($line, qr/->/, 'card uses the inline arrow style');
};

subtest 'Agent state is tracked per agent' => sub {
    my $chat = TestChat->new();

    $chat->_track_agent_event({
        type => 'activity', agent_id => 'agent-1',
        action => 'start', tool => 'file_operations', detail => 'read_file',
    });
    $chat->_track_agent_event({
        type => 'activity', agent_id => 'agent-2',
        action => 'start', tool => 'terminal_operations', detail => 'exec',
    });

    my $states = $chat->agent_states();
    is(scalar keys %$states, 2, 'both agents tracked');
    is($states->{'agent-1'}{tool}, 'file_operations', 'agent-1 tool tracked');
    is($states->{'agent-2'}{tool}, 'terminal_operations', 'agent-2 tool tracked');
};

# ============================================================================
# 8. Idle wake
# ============================================================================

subtest 'Actionable messages raise an alert' => sub {
    my $chat = TestChat->new();

    $chat->_note_agent_alert({
        id => 10, from => 'agent-1', type => 'complete', content => 'done',
    });
    is(scalar @{ $chat->pending_agent_alerts() }, 1, 'complete raises an alert');

    $chat->_note_agent_alert({
        id => 11, from => 'agent-1', type => 'status', content => 'working',
    });
    is(scalar @{ $chat->pending_agent_alerts() }, 1,
        'a status message does not raise an alert');

    $chat->_note_agent_alert({
        id => 12, from => 'agent-2', type => 'question', content => 'which one?',
    });
    is(scalar @{ $chat->pending_agent_alerts() }, 2, 'question raises an alert');
};

subtest 'Alerts are consumed once the manager has them' => sub {
    my $chat = TestChat->new();

    $chat->_note_agent_alert({
        id => 20, from => 'agent-1', type => 'complete', content => 'done',
    });

    my $alerts = $chat->consume_agent_alerts();
    is(scalar @$alerts, 1, 'one alert consumed');
    is(scalar @{ $chat->pending_agent_alerts() }, 0, 'alerts are cleared');
};

subtest 'No alerts means no wake' => sub {
    my $chat = TestChat->new();

    # An empty arrayref is still true in Perl, so the wake check must
    # not test the reference directly.
    ok(!$chat->has_pending_agent_alerts(),
        'an empty alert list does not trigger a wake');

    $chat->_note_agent_alert({
        id => 21, from => 'agent-1', type => 'complete', content => 'done',
    });
    ok($chat->has_pending_agent_alerts(),
        'a pending alert triggers a wake');
};

subtest 'Wake pointer names the agent without carrying its content' => sub {
    my $chat = TestChat->new();

    my $pointer = $chat->_agent_event_pointer([
        { id => 30, agent_id => 'agent-1', kind => 'complete' },
        { id => 31, agent_id => 'agent-2', kind => 'question' },
    ]);
    like($pointer, qr/agent-1/, 'pointer names the first agent');
    like($pointer, qr/agent-2/, 'pointer names the second agent');
    like($pointer, qr/inbox/, 'pointer says where to read the message');
    unlike($pointer, qr/done/, 'pointer does not carry the agent content');

    is($chat->_agent_event_pointer([]), undef, 'no alerts means no pointer');
};

# ============================================================================
# 9. Display cursor stops repeat rendering
# ============================================================================

subtest 'Messages are only displayed once' => sub {
    my $chat = TestChat->new();

    my $messages = [ { id => 40, from => 'agent-1', type => 'complete' } ];
    my $first = $chat->_filter_undisplayed_messages($messages);
    is(scalar @$first, 1, 'first display passes the message');

    my $second = $chat->_filter_undisplayed_messages($messages);
    is(scalar @$second, 0, 'second display is suppressed');
};

# ============================================================================
# 10. Non-interactive rendering for children
# ============================================================================

subtest 'A child without a UI renders machine readable output' => sub {
    require CLIO::UI::ToolOutputFormatter;

    my $formatter = CLIO::UI::ToolOutputFormatter->new();
    ok($formatter->_is_non_interactive(),
        'no UI object means non-interactive output');

    my $forced = CLIO::UI::ToolOutputFormatter->new(
        ui => { non_interactive => 0 },
        non_interactive => 1,
    );
    ok($forced->_is_non_interactive(),
        'the non-interactive flag overrides an interactive UI');

    my $interactive = CLIO::UI::ToolOutputFormatter->new(
        ui => { non_interactive => 0 },
    );
    ok(!$interactive->_is_non_interactive(),
        'an interactive UI still renders interactively');
};

done_testing();
