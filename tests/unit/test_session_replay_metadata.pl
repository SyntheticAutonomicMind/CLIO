#!/usr/bin/env perl
# Test that tool result messages store display metadata for session replay

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More;
use File::Temp qw(tempdir);

# Use temp directory for config
my $temp_dir = tempdir(CLEANUP => 1);
$ENV{HOME} = $temp_dir;

my $clio_dir = "$temp_dir/.clio";
mkdir $clio_dir;
mkdir "$clio_dir/sessions";

# Test 1: State::add_message stores display metadata for tool results
{
    require CLIO::Session::Manager;
    require CLIO::Session::State;

    my $state_pm = "$RealBin/../../lib/CLIO/Session/State.pm";
    open my $fh, '<', $state_pm or die "Cannot read State.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    # Verify add_message accepts display metadata opts
    like($content, qr/\$opts->\{tool_name\}/,
        "State::add_message checks for tool_name in opts");
    like($content, qr/\$opts->\{action_description\}/,
        "State::add_message checks for action_description in opts");
    like($content, qr/\$opts->\{expanded_content\}/,
        "State::add_message checks for expanded_content in opts");
    like($content, qr/\$opts->\{suppressed_display\}/,
        "State::add_message checks for suppressed_display in opts");
    like($content, qr/\$opts->\{is_error\}/,
        "State::add_message checks for is_error in opts");
    like($content, qr/\$opts->\{pre_action_description\}/,
        "State::add_message checks for pre_action_description in opts");
    like($content, qr/\$opts->\{error_message\}/,
        "State::add_message checks for error_message in opts");

    # Verify the metadata is stored on the message hash
    like($content, qr/\$message->\{tool_name\}\s*=\s*\$opts->\{tool_name\}/,
        "tool_name is stored on message hash");
    like($content, qr/\$message->\{action_description\}\s*=\s*\$opts->\{action_description\}/,
        "action_description is stored on message hash");
    like($content, qr/\$message->\{expanded_content\}\s*=\s*\$opts->\{expanded_content\}/,
        "expanded_content is stored on message hash");
    like($content, qr/\$message->\{suppressed_display\}\s*=\s*\$opts->\{suppressed_display\}/,
        "suppressed_display is stored on message hash");
    like($content, qr/\$message->\{is_error\}\s*=\s*\$opts->\{is_error\}/,
        "is_error is stored on message hash");
    like($content, qr/\$message->\{pre_action_description\}\s*=\s*\$opts->\{pre_action_description\}/,
        "pre_action_description is stored on message hash");
    like($content, qr/\$message->\{error_message\}\s*=\s*\$opts->\{error_message\}/,
        "error_message is stored on message hash");
}

# Test 2: WorkflowOrchestrator passes display metadata when saving tool results
{
    my $orch_pm = "$RealBin/../../lib/CLIO/Core/WorkflowOrchestrator.pm";
    open my $fh, '<', $orch_pm or die "Cannot read WorkflowOrchestrator.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    # Verify the add_message call for tool results includes display metadata
    like($content, qr/tool_name\s*=>\s*\$tool_name,\s*action_description\s*=>/,
        "WorkflowOrchestrator passes tool_name and action_description to add_message");

    like($content, qr/pre_action_description\s*=>/,
        "WorkflowOrchestrator passes pre_action_description to add_message");

    like($content, qr/expanded_content.*\$result_data->\{expanded_content\}/s,
        "WorkflowOrchestrator passes expanded_content to add_message");

    like($content, qr/suppressed_display\s*=>\s*\$suppress_display/s,
        "WorkflowOrchestrator passes suppressed_display to add_message");

    like($content, qr/is_error\s*=>\s*\$is_error/,
        "WorkflowOrchestrator passes is_error to add_message");

    like($content, qr/error_message\s*=>\s*\$is_error\s*\?\s*\(\$result_data->\{error\}/,
        "WorkflowOrchestrator passes error_message to add_message");
}

# Test 3: Config has session_replay option
{
    my $config_pm = "$RealBin/../../lib/CLIO/Core/Config.pm";
    open my $fh, '<', $config_pm or die "Cannot read Config.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like($content, qr/session_replay\s*=>\s*1/,
        "Config.pm has session_replay => 1 in DEFAULT_CONFIG");
    like($content, qr/session_replay_max\s*=>\s*100/,
        "Config.pm has session_replay_max => 100 in DEFAULT_CONFIG");
}

# Test 4: Config.pm command handles session_replay
{
    my $cmd_config_pm = "$RealBin/../../lib/CLIO/UI/Commands/Config.pm";
    open my $fh, '<', $cmd_config_pm or die "Cannot read Config.pm commands: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like($content, qr/my %allowed.*session_replay\s*=>\s*1/s,
        "Config command allows session_replay key");
    like($content, qr/my %allowed.*session_replay_max\s*=>\s*1/s,
        "Config command allows session_replay_max key");
}

# Test 5: CLI has --no-session-replay flag
{
    my $clio = "$RealBin/../../clio";
    open my $fh, '<', $clio or die "Cannot read clio: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like($content, qr/--no-session-replay/,
        "clio script has --no-session-replay flag");
    like($content, qr/\$no_session_replay/,
        "clio script has no_session_replay variable");
    like($content, qr/\$config->set\('session_replay',\s*0,\s*0\)/,
        "clio script sets session_replay to 0 (transient) when --no-session-replay");
    like($content, qr/Auto-disabled session_replay: non-interactive mode/,
        "clio script auto-disables session_replay in non-interactive mode");
}

# Test 6: SessionReplay module exists and has required methods
{
    my $replay_pm = "$RealBin/../../lib/CLIO/UI/SessionReplay.pm";
    ok(-f $replay_pm, "SessionReplay.pm exists");

    open my $fh, '<', $replay_pm or die "Cannot read SessionReplay.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like($content, qr/sub render_history/,
        "SessionReplay has render_history method");
    like($content, qr/sub _render_assistant_message/,
        "SessionReplay has _render_assistant_message method");
    like($content, qr/sub _render_tool_call/,
        "SessionReplay has _render_tool_call method");
    like($content, qr/sub _render_user_message/,
        "SessionReplay has _render_user_message method");
    like($content, qr/sub _should_suppress/,
        "SessionReplay has _should_suppress method");
    like($content, qr/sub _render_system_message/,
        "SessionReplay has _render_system_message method");
    like($content, qr/sub _strip_session_markers/,
        "SessionReplay has _strip_session_markers method");
    like($content, qr/sub _render_thinking/,
        "SessionReplay has _render_thinking method");
    like($content, qr/my \$show_thinking\s*=\s*\$chat->\{config\}.*\$chat->\{config\}->get\('show_thinking'\)/s,
        "SessionReplay checks show_thinking config before rendering thinking");
    like($content, qr/sub _render_orphan_tool_result/,
        "SessionReplay has _render_orphan_tool_result method");
}

# Test 7: Session switch triggers replay
{
    my $session_pm = "$RealBin/../../lib/CLIO/UI/Commands/Session.pm";
    open my $fh, '<', $session_pm or die "Cannot read Session.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like($content, qr/_replay_session_history\(\)/,
        "handle_switch_command calls _replay_session_history");
    like($content, qr/sub _maybe_replay_session_history/,
        "Session.pm has _maybe_replay_session_history method");
    like($content, qr/return unless \$replay_enabled/,
        "Session.pm checks replay_enabled before replaying");
    like($content, qr/return if .*non_interactive/,
        "Session.pm auto-disables replay in non-interactive mode");
}

# Test 8: Chat.pm run() triggers replay on resume
{
    my $chat_pm = "$RealBin/../../lib/CLIO/UI/Chat.pm";
    open my $fh, '<', $chat_pm or die "Cannot read Chat.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like($content, qr/sub _replay_session_history/,
        "Chat.pm has _replay_session_history method");
    like($content, qr/\$self->_replay_session_history\(\)\s+if\s+\$self->\{session\}/,
        "Chat.pm run() calls _replay_session_history after session prepopulation");
    like($content, qr/return if .*non_interactive/,
        "Chat.pm _replay_session_history auto-disables in non-interactive mode");
}

# Test 9: SessionReplay module returns rendered count
{
    my $replay_pm = "$RealBin/../../lib/CLIO/UI/SessionReplay.pm";
    open my $fh, '<', $replay_pm or die "Cannot read SessionReplay.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like($content, qr/return \$rendered_count/,
        "SessionReplay render_history returns rendered count");
    like($content, qr/return 0 if .*non_interactive/,
        "SessionReplay auto-disables in non-interactive mode");
}

# Test 10: /session view command exists
{
    my $session_pm = "$RealBin/../../lib/CLIO/UI/Commands/Session.pm";
    open my $fh, '<', $session_pm or die "Cannot read Session.pm: $!";
    my $content = do { local $/; <$fh> };
    close $fh;

    like($content, qr/\$action eq 'view' \|\| \$action eq 'replay'/,
        "Session command dispatches /session view and /session replay");
    like($content, qr/sub _handle_view_command/,
        "Session.pm has _handle_view_command method");
    like($content, qr/session view \[N\|all\]/,
        "Session help lists /session view command");
}

done_testing();
