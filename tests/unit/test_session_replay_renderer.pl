#!/usr/bin/env perl
# Test that SessionReplay correctly renders history messages for replay

use strict;
use warnings;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use Test::More;
use File::Temp qw(tempdir);

# Use a temp dir
my $temp_dir = tempdir(CLEANUP => 1);
$ENV{HOME} = $temp_dir;
$ENV{CLIO_LOG_LEVEL} = "ERROR";

# Build a minimal mock Chat-like object that provides what SessionReplay needs
my $mock_chat = {
    non_interactive => 0,
    enable_markdown => 0,  # Disable to avoid needing full markdown pipeline
    debug => 0,
    theme_mgr => undef,
    ansi => undef,
    display => undef,
    _tools_invoked_this_request => 0,
};

# Add colorize method via a blessed package
{
    package MockChat;
    sub new { my $class = shift; return bless {}, $class; }
    sub colorize { my ($self, $text, $color) = @_; return $text; }
    sub agent_name { return "CLIO"; }
    sub writeline {
        my ($self, $text, %opts) = @_;
        # Capture output for testing
        push @{$self->{output}}, $text // '';
        push @{$self->{lines}}, $text // '' if $text;
    }
    sub render_markdown { my ($self, $text) = @_; return $text; }
    sub display_system_message {
        my ($self, $msg) = @_;
        push @{$self->{output}}, $msg;
    }
    sub display_info_message {
        my ($self, $msg) = @_;
        push @{$self->{output}}, $msg;
    }
    sub display_error_message {
        my ($self, $msg) = @_;
        push @{$self->{output}}, $msg;
    }
    sub display_success_message {
        my ($self, $msg) = @_;
        push @{$self->{output}}, $msg;
    }
    sub colorize { my ($self, $text, $color) = @_; return $text; }
};

# CfgMock: minimal config object for show_thinking tests
{
    package CfgMock;
    sub new { my $class = shift; return bless {}, $class; }
    sub get { return 1; }  # show_thinking = 1
}

# Test 1: SessionReplay module loads
require CLIO::UI::SessionReplay;
ok(defined &CLIO::UI::SessionReplay::render_history,
    "SessionReplay::render_history is defined");

# Test 2: SessionReplay rejects non-interactive mode
{
    my $chat = MockChat->new();
    $chat->{non_interactive} = 1;
    $chat->{enable_markdown} = 0;
    
    my $replay = CLIO::UI::SessionReplay->new(
        chat => $chat,
    );
    
    my @history = (
        { role => 'user', content => 'test' },
    );
    
    my $result = $replay->render_history(\@history);
    is($result, 0, "render_history returns 0 in non-interactive mode");
}

# Test 3: render_history returns 0 for empty history
{
    my $chat = MockChat->new();
    $chat->{non_interactive} = 0;
    $chat->{enable_markdown} = 0;
    
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat);
    my $result = $replay->render_history([]);
    is($result, 0, "render_history returns 0 for empty history");
}

# Test 4: render_history returns 0 for undef history
{
    my $chat = MockChat->new();
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat);
    my $result = $replay->render_history(undef);
    is($result, 0, "render_history returns 0 for undef history");
}

# Test 5: render_history renders user messages
{
    my $chat = MockChat->new();
    $chat->{non_interactive} = 0;
    $chat->{enable_markdown} = 0;
    
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat);
    my @history = (
        { role => 'user', content => 'Hello, how are you?' },
    );
    
    my $result = $replay->render_history(\@history);
    is($result, 1, "render_history renders 1 user message");
}

# Test 6: render_history renders assistant messages
{
    my $chat = MockChat->new();
    $chat->{non_interactive} = 0;
    $chat->{enable_markdown} = 0;
    
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat);
    my @history = (
        { role => 'assistant', content => 'I am doing well!' },
    );
    
    my $result = $replay->render_history(\@history);
    is($result, 1, "render_history renders 1 assistant message");
}

# Test 7: render_history renders user + assistant + tool result
{
    my $chat = MockChat->new();
    $chat->{non_interactive} = 0;
    $chat->{enable_markdown} = 0;
    
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat);
    my @history = (
        { role => 'user', content => 'What is the capital of France?' },
        {
            role => 'assistant',
            content => 'I\'ll look that up for you.',
            tool_calls => [
                {
                    id => 'tooluse_123',
                    type => 'function',
                    function => {
                        name => 'file_operations',
                        arguments => '{"operation":"read_file","path":"facts.txt"}'
                    }
                }
            ]
        },
        {
            role => 'tool',
            content => 'Paris is the capital of France.',
            tool_call_id => 'tooluse_123',
            tool_name => 'file_operations',
            action_description => 'read_file: facts.txt',
            expanded_content => ['Paris is the capital of France.'],
            suppressed_display => 0,
            is_error => 0,
        },
        { role => 'assistant', content => 'The capital of France is Paris.' },
    );
    
    my $result = $replay->render_history(\@history);
    # Tool result is rendered inline with the assistant message's tool_calls,
    # not as a separate message. So 3 (user + assistant-with-toolcall + assistant)
    is($result, 3, "render_history renders 3 messages (user, assistant+toolcall, assistant)");
}

# Test 8: render_history with max_messages cap
{
    my $chat = MockChat->new();
    $chat->{non_interactive} = 0;
    $chat->{enable_markdown} = 0;
    
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat, max_messages => 2);
    my @history = (
        { role => 'user', content => 'msg 1' },
        { role => 'user', content => 'msg 2' },
        { role => 'user', content => 'msg 3' },
        { role => 'user', content => 'msg 4' },
    );
    
    my $result = $replay->render_history(\@history, max_messages => 2);
    is($result, 2, "render_history respects max_messages cap");
}

# Test 9: _should_suppress uses stored metadata
{
    my $chat = MockChat->new();
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat);

    # With stored suppressed_display = 1
    is($replay->_should_suppress('terminal_operations', 'validate', { suppressed_display => 1 }),
        1, "suppress returns true when stored suppressed_display=1");

    # With stored suppressed_display = 0
    is($replay->_should_suppress('file_operations', 'read_file', { suppressed_display => 0 }),
        0, "suppress returns false when stored suppressed_display=0");

    # Fallback: interact tool is always suppressed
    is($replay->_should_suppress('interact', 'request_input', undef),
        1, "interact tool is suppressed by fallback");

    # Fallback: terminal_operations/validate is suppressed
    is($replay->_should_suppress('terminal_operations', 'validate', undef),
        1, "terminal_operations/validate is suppressed by fallback");

    # Fallback: other tools are not suppressed
    is($replay->_should_suppress('file_operations', 'read_file', undef),
        0, "file_operations/read_file is not suppressed by fallback");
}

# Test 10: render_history skips orphaned tool results (no matching tool_call)
{
    my $chat = MockChat->new();
    $chat->{non_interactive} = 0;
    $chat->{enable_markdown} = 0;
    
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat);
    my @history = (
        # Orphaned tool result (no preceding assistant with matching tool_call_id)
        {
            role => 'tool',
            content => 'orphaned result',
            tool_call_id => 'orphan_123',
        },
        { role => 'user', content => 'hello' },
    );
    
    my $result = $replay->render_history(\@history);
    # The orphaned tool result should be rendered as fallback
    is($result, 2, "orphaned tool result is rendered as fallback");
}

# Test 11: Suppressed tool result (interact) is not rendered as orphan
# Even when the tool_call IS matched to its result, the result should not
# be re-rendered as a standalone tool result.
{
    my $chat = MockChat->new();
    $chat->{non_interactive} = 0;
    $chat->{enable_markdown} = 0;
    
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat);
    my @history = (
        {
            role => 'assistant',
            content => 'Here is my QA review.',
            tool_calls => [
                {
                    id => 'call_1',
                    function => {
                        name => 'interact',
                        arguments => '{"message": "Ready to push?"}',
                    },
                },
            ],
        },
        # Tool result for the interact call — suppressed
        {
            role => 'tool',
            content => 'TOOL ERROR: interact\nUser cancelled',
            tool_call_id => 'call_1',
            tool_name => 'interact',
            suppressed_display => 1,
        },
    );
    
    my $result = $replay->render_history(\@history);
    # Both messages counted: assistant (1) + tool result is NOT rendered
    # (suppressed, and marked as rendered during assistant's tool_call
    # processing so orphan fallback doesn't fire)
    is($result, 1, "suppressed interact result not rendered as orphan");
}

# Test 12: render_history skips system messages without thread_summary
{
    my $chat = MockChat->new();
    $chat->{non_interactive} = 0;
    $chat->{enable_markdown} = 0;
    
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat);
    my @history = (
        { role => 'user', content => 'hello' },
        { role => 'system', content => 'Some internal message' },
        { role => 'system', content => '<thread_summary>Trimmed conversation</thread_summary>' },
    );
    
    my $result = $replay->render_history(\@history, show_system => 0);
    # With show_system=0, system messages are not rendered; only user (1)
    is($result, 1, "with show_system=0, system messages are not rendered");
}

# Test 12: file_operations content is NOT shown as expanded_content
# In the live session, file_operations content (raw JSON) is only shown
# via action_description, not as expanded content. The replay should
# match — content-to-expanded_content fallback only applies to
# terminal_operations exec.
{
    my $chat = MockChat->new();
    $chat->{non_interactive} = 0;
    $chat->{enable_markdown} = 0;
    
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat);
    
    my @history = (
        { role => 'user', content => 'list files' },
        {
            role => 'assistant',
            content => 'listing directory',
            tool_calls => [
                {
                    id => 'tc_1',
                    type => 'function',
                    function => {
                        name => 'file_operations',
                        arguments => '{"operation":"list_dir","path":"."}'
                    }
                }
            ]
        },
        {
            role => 'tool',
            content => '[{"name":"file.txt","size":42}]',
            tool_call_id => 'tc_1',
            tool_name => 'file_operations',
            action_description => 'listing . (1 files, 0 directories)',
            # NO expanded_content — content is raw JSON, not displayed
        },
    );
    
    open(my $oldout, '>&', \*STDOUT) or die;
    close(STDOUT);
    open(STDOUT, '>:encoding(UTF-8)', \my $cap) or die;
    
    my $result = $replay->render_history(\@history);
    
    open(STDOUT, '>&', $oldout) or die;
    
    is($result, 2, "renders user + assistant (tool result rendered inline)");
    ok($cap !~ /\Q[{"name":"file.txt"/, "file_operations raw JSON content not shown as expanded content");
}

# Test 13: terminal_operations content IS shown as expanded_content fallback
# For terminal_operations exec without stored expanded_content, the
# content string (command output) should be shown as expanded content.
{
    my $chat = MockChat->new();
    $chat->{non_interactive} = 0;
    $chat->{enable_markdown} = 0;
    
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat);
    
    my @history = (
        { role => 'user', content => 'run a command' },
        {
            role => 'assistant',
            content => 'running command',
            tool_calls => [
                {
                    id => 'tc_2',
                    type => 'function',
                    function => {
                        name => 'terminal_operations',
                        arguments => '{"operation":"exec","command":"echo hello"}'
                    }
                }
            ]
        },
        {
            role => 'tool',
            content => 'hello\n[exit:0 | 50ms]',
            tool_call_id => 'tc_2',
            tool_name => 'terminal_operations',
            pre_action_description => 'echo hello',
            # NO expanded_content stored — should fall back to content
        },
    );
    
    # Capture STDOUT since display_expanded_content uses print directly
    # Use UTF-8 encoding to avoid wide character warnings
    open(my $oldout, '>&', \*STDOUT) or die;
    close(STDOUT);
    open(STDOUT, '>:encoding(UTF-8)', \my $cap) or die;
    
    my $result = $replay->render_history(\@history);
    
    open(STDOUT, '>&', $oldout) or die;
    
    is($result, 2, "renders user + assistant (tool result rendered inline)");
    ok($cap =~ /hello/, "terminal_operations content shown as expanded content fallback");
}

# Test 14: thinking blocks have blank lines around bottom hrule
# Matches live session format: content, blank line, bottom hrule, blank line
{
    my $chat = MockChat->new();
    $chat->{non_interactive} = 0;
    $chat->{enable_markdown} = 0;
    $chat->{config} = CfgMock->new();
    
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat);
    
    my @history = (
        { role => 'user', content => 'test' },
        { role => 'assistant', content => 'response', reasoning_content => 'thinking here' },
    );
    
    open(my $oldout, '>&', \*STDOUT) or die;
    close(STDOUT);
    open(STDOUT, '>:encoding(UTF-8)', \my $cap) or die;
    
    $replay->render_history(\@history);
    
    open(STDOUT, '>&', $oldout) or die;
    
    ok($cap =~ /THINKING/, "thinking header present");
    ok($cap =~ /thinking here/, "thinking content present");
    my $blank_count = () = $cap =~ /\n\n/g;
    ok($blank_count >= 2, "thinking block has blank lines around hrules ($blank_count found)");
}

# Test 15: box_char/ui_char called as functions, not methods
# Regression test: $chat->box_char('horizontal') passes $chat as first
# arg, corrupting the lookup and producing '?' characters.
{
    my $chat = MockChat->new();
    $chat->{non_interactive} = 0;
    $chat->{enable_markdown} = 0;
    $chat->{config} = CfgMock->new();
    
    my $replay = CLIO::UI::SessionReplay->new(chat => $chat);
    
    my @history = (
        { role => 'user', content => 'test' },
        { role => 'assistant', content => 'response', reasoning_content => 'thinking' },
    );
    
    open(my $oldout, '>&', \*STDOUT) or die;
    close(STDOUT);
    open(STDOUT, '>:encoding(UTF-8)', \my $cap) or die;
    
    $replay->render_history(\@history);
    
    open(STDOUT, '>&', $oldout) or die;
    
    ok($cap !~ /\?/, "no '?' characters in thinking block rendering");
}

done_testing();
