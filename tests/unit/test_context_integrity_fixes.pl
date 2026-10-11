#!/usr/bin/perl
# SPDX-License-Identifier: GPL-3.0-only
use strict;
use warnings;
use utf8;
use Test::More;

# Tests for the adversarial context-integrity fixes:
# 1. Separator delimiter between dynamic-UC and user input in user message
# 2. thread_summary folding into user message for local-inference providers
# 3. remove_existing_thread_summaries scans ALL roles (not just system)
# 4. _extract_thread_summary_from_messages scans ALL roles

use CLIO::Core::API::MessageValidator qw(validate_and_truncate remove_existing_thread_summaries);
use CLIO::Providers;

# ---- Test 1: remove_existing_thread_summaries handles all roles correctly ----

subtest 'remove_existing_thread_summaries scans all roles' => sub {
    # System message with thread_summary (cloud provider layout)
    # Cloud: entire message removed (including system thread_summary)
    my $msgs_cloud = [
        { role => 'system', content => 'system prompt' },
        { role => 'system', content => '<thread_summary>old summary</thread_summary>' },
        { role => 'user',    content => 'hello' },
    ];
    my $result = remove_existing_thread_summaries($msgs_cloud);
    is(scalar(@$result), 2, 'Cloud: removes system thread_summary');
    ok($result->[0]{content} eq 'system prompt', 'Cloud: system prompt preserved');
    ok($result->[1]{content} eq 'hello', 'Cloud: user message preserved');

    # User message with embedded thread_summary (local inference provider layout)
    # Cloud: entire user message removed (old behavior, backward-compatible)
    my $msgs_local = [
        { role => 'system', content => 'system prompt' },
        { role => 'user',    content => '<thread_summary>old summary</thread_summary>CWD: /tmp\n---\n\nactual user input' },
        { role => 'assistant', content => 'response' },
    ];
    my $result_cloud = remove_existing_thread_summaries($msgs_local);
    is(scalar(@$result_cloud), 2, 'Cloud: removes user-embedded thread_summary entirely');
    ok($result_cloud->[0]{content} eq 'system prompt', 'Cloud: system prompt preserved after user-embedded removal');
    ok($result_cloud->[1]{content} eq 'response', 'Cloud: assistant message preserved after user-embedded removal');

    # Local inference: strip thread_summary from user message, preserve user input
    my $result_local = remove_existing_thread_summaries($msgs_local, 1);
    is(scalar(@$result_local), 3, 'Local: preserves user message (strips thread_summary, keeps content)');
    ok($result_local->[0]{content} eq 'system prompt', 'Local: system prompt preserved');
    ok(index($result_local->[1]{content}, 'CWD: /tmp') == 0, 'Local: user message content starts with user content after stripping');
    ok($result_local->[1]{content} !~ /old summary/, 'Local: old summary text stripped from user message');
    ok($result_local->[2]{content} eq 'response', 'Local: assistant message preserved');
    ok($result_local->[1]{content} !~ /<thread_summary>/, 'Local: thread_summary stripped from user message');
    ok($result_local->[1]{content} =~ /actual user input/, 'Local: actual user input preserved');
    done_testing();
};

# ---- Test 1b: remove_existing_thread_summaries with empty/undefined input ----

subtest 'remove_existing_thread_summaries edge cases' => sub {
    is(scalar(@{ remove_existing_thread_summaries([]) }), 0, 'Empty array returns empty');
    is(scalar(@{ remove_existing_thread_summaries(undef) }), 0, 'Undef returns empty');
    is(scalar(@{ remove_existing_thread_summaries(undef, 1) }), 0, 'Undef with local_inference returns empty');
    done_testing();
};

# ---- Test 2: _extract_thread_summary_from_messages scans all roles ----

subtest '_extract_thread_summary_from_messages scans all roles' => sub {
    require CLIO::Memory::YaRN;
    my $yarn = CLIO::Memory::YaRN->new();

    # System message (cloud layout)
    my $found_system = $yarn->_extract_thread_summary_from_messages([
        { role => 'system', content => '<thread_summary>summary here</thread_summary>' },
        { role => 'user',   content => 'hello' },
    ]);
    ok($found_system =~ /<thread_summary>.*summary here.*<\/thread_summary>/s,
       'Extracts from system message');

    # User message (local inference layout)
    my $found_user = $yarn->_extract_thread_summary_from_messages([
        { role => 'system', content => 'system prompt' },
        { role => 'user',   content => '<thread_summary>user-embedded summary</thread_summary>CWD: /tmp\n---\n\nactual input' },
    ]);
    ok($found_user =~ /<thread_summary>.*user-embedded summary.*<\/thread_summary>/s,
       'Extracts from user message for local inference');

    # Returns empty string when no thread_summary
    my $found_empty = $yarn->_extract_thread_summary_from_messages([
        { role => 'system', content => 'system prompt' },
        { role => 'user',   content => 'hello' },
    ]);
    is($found_empty, '', 'Returns empty string when no thread_summary found');

    done_testing();
};

# ---- Test 3: is_local_inference returns true for sam/llama.cpp/lmstudio ----

subtest 'is_local_inference' => sub {
    ok(CLIO::Providers::is_local_inference('sam'),           'SAM is local inference');
    ok(CLIO::Providers::is_local_inference('llama.cpp'),     'llama.cpp is local inference');
    ok(CLIO::Providers::is_local_inference('lmstudio'),      'LM Studio is local inference');
    ok(!CLIO::Providers::is_local_inference('openai'),       'OpenAI is NOT local inference');
    ok(!CLIO::Providers::is_local_inference('anthropic'),    'Anthropic is NOT local inference');
    ok(!CLIO::Providers::is_local_inference('github_copilot'),'Copilot is NOT local inference');
    done_testing();
};

# ---- Test 4: Separator is deterministic and present only when dynamic_uc is non-empty ----

subtest 'separator logic' => sub {
    # Simulate the logic from _build_turn_context:
    # If dynamic_uc has content, append "---\n\n" after it.
    my $user_context = "CWD: /tmp | Date: 2026-10-09 07:07 | Respond in English\n";

    # Case 1: No dynamic_uc -> no separator -> user input follows directly
    my $msg_no_uc = $user_context . 'actual user input';
    ok(index($msg_no_uc, '---') == -1, 'No separator when dynamic_uc is empty');

    # Case 2: With dynamic_uc -> separator present
    my $dynamic_uc = "Active todos:\n- [in-progress] Fix bug\n\n";
    my $msg_with_uc = $user_context;
    $msg_with_uc .= $dynamic_uc;
    $msg_with_uc .= "---\n\n";
    $msg_with_uc .= 'actual user input';
    ok(index($msg_with_uc, "---\n\n") > 0, 'Separator present when dynamic_uc is non-empty');
    ok($msg_with_uc =~ /---\n\nactual user input$/, 'User input follows separator');

    # Case 3: Separator is byte-stable when dynamic_uc content is the same
    my $msg_with_uc_2 = $user_context . $dynamic_uc . "---\n\n" . 'actual user input';
    is($msg_with_uc, $msg_with_uc_2, 'Separator produces byte-identical output for same dynamic_uc');
    done_testing();
};

# ---- Test 5: Thread summary folding logic (simulated) ----

subtest 'thread_summary folding for local inference' => sub {
    # Simulate the logic from _build_turn_context:
    # For local inference: fold into user message
    # For cloud: push as system message
    my $tail = '<thread_summary>Compressed summary of dropped turns</thread_summary>';
    my $dynamic_uc = "Active todos:\n- [in-progress] Task\n\n";
    my $user_context = "CWD: /tmp | Date: ...\n";

    # Local inference path: thread_summary + user_context + dynamic_uc + separator + user_input
    my $user_message_local = $tail . "\n\n" . $user_context . $dynamic_uc . "---\n\n" . 'user input';
    ok($user_message_local =~ /^<thread_summary>/, 'Thread summary at start of user message for local inference');
    ok($user_message_local =~ /user input$/, 'User input at end of user message for local inference');

    # Cloud path: thread_summary as separate system message
    my @messages_cloud = (
        { role => 'system', content => 'main system prompt' },
        { role => 'system', content => $tail },
        { role => 'user',    content => $user_context . $dynamic_uc . "---\n\n" . 'user input' },
    );
    ok($messages_cloud[1]{role} eq 'system', 'Thread summary is system message for cloud providers');
    ok($messages_cloud[1]{content} eq $tail, 'Thread summary content preserved for cloud providers');

    done_testing();
};

# ---- Test 6: validate_and_truncate folds thread_summary into user message
#        for local-inference providers (no mid-conversation system message) ----

subtest 'validate_and_truncate: local inference thread_summary folding' => sub {
    require CLIO::Memory::TokenEstimator;

    # Build a message array that exceeds the token budget so the proactive
    # trim path is exercised. The array has a system prompt + many user/
    # assistant messages, ending with a user message carrying the current
    # task. We use a tiny context window to force trimming.
    my @messages = (
        { role => 'system', content => 'System prompt' },
    );
    for my $i (1..20) {
        push @messages, { role => 'user',     content => "User request $i: " . ('x' x 200) };
        push @messages, { role => 'assistant', content => "Assistant response $i: " . ('y' x 200) };
    }

    my $caps = {
        max_context_window_tokens => 2048,
        max_output_tokens         => 256,
        max_prompt_tokens         => 1792,
    };

    # Cloud provider: thread_summary injected as a system message
    # (positioned after history, before last user)
    my $result_cloud = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => 'Build a widget system',
        debug              => 0,
    );
    # Verify NO system message appears after index 0
    my $cloud_has_mid_system = 0;
    for my $i (1 .. $#{$result_cloud}) {
        if (ref($result_cloud->[$i]) eq 'HASH'
            && ($result_cloud->[$i]{role} // '') eq 'system') {
            $cloud_has_mid_system = 1;
            last;
        }
    }
    ok($cloud_has_mid_system, 'Cloud provider: thread_summary injected as mid-conversation system message');

    # Local inference: thread_summary folded into user message, no
    # mid-conversation system message
    # Use longer active_task (>= 50 chars so compress_messages uses it
    # directly as "Current task:" instead of scanning messages)
    my $result_local = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => $caps,
        tools              => [],
        token_ratio        => 2.5,
        active_task        => 'Build a widget system with advanced features and a clean API',
        config             => _make_local_config(),
        api_base           => 'http://localhost:9090/v1/chat/completions',
        debug              => 0,
    );
    my $local_has_mid_system = 0;
    for my $i (1 .. $#{$result_local}) {
        if (ref($result_local->[$i]) eq 'HASH'
            && ($result_local->[$i]{role} // '') eq 'system') {
            $local_has_mid_system = 1;
            last;
        }
    }
    ok(!$local_has_mid_system, 'Local inference: NO mid-conversation system message (thread_summary folded into user message)');

    # Verify the last user message contains the thread_summary
    my $last_user = undef;
    for my $i (reverse 0 .. $#{$result_local}) {
        if (ref($result_local->[$i]) eq 'HASH'
            && ($result_local->[$i]{role} // '') eq 'user') {
            $last_user = $result_local->[$i];
            last;
        }
    }
    ok($last_user, 'Local inference: last user message exists');
    if ($last_user) {
        my $content = $last_user->{content} // '';
        ok($content =~ /<thread_summary>/, 'Local inference: thread_summary folded into last user message');
    }

    # Verify the user input is preserved (not stripped with the summary)
    if ($last_user) {
        my $content = $last_user->{content} // '';
        ok($content =~ /Build a widget system/, 'Local inference: user task text preserved in user message');
    }

    done_testing();
};

# Helper: create a mock Config that returns 'llama.cpp' as the provider
sub _make_local_config {
    return _MockConfig->new();
}

{
    package _MockConfig;
    sub new { bless {}, shift }
    sub get {
        my ($self, $key) = @_;
        if ($key eq 'provider') { return 'llama.cpp' }
        return undef;
    }
}

# ---- Test 7: _inject_summary_before_last_user folds for local inference ----

subtest '_inject_summary_before_last_user: local inference folding' => sub {
    require CLIO::Core::API::ErrorHandler;
    my $summary = { role => 'system', content => '<thread_summary>compressed</thread_summary>' };

    # Use full path since _inject_summary_before_last_user is a private function
    # Cloud: creates system message before last user
    my @cloud_msgs = (
        { role => 'assistant', content => 'assistant msg' },
        { role => 'user',      content => 'actual user input' },
    );
    CLIO::Core::API::ErrorHandler::_inject_summary_before_last_user(\@cloud_msgs, $summary, 0);
    is(scalar(@cloud_msgs), 3, 'Cloud: system message injected before user');
    is($cloud_msgs[1]{role}, 'system', 'Cloud: injected message is system role');
    is($cloud_msgs[2]{role}, 'user', 'Cloud: user message preserved');

    # Local inference: folds into user message
    my @local_msgs = (
        { role => 'assistant', content => 'assistant msg' },
        { role => 'user',      content => 'actual user input' },
    );
    CLIO::Core::API::ErrorHandler::_inject_summary_before_last_user(\@local_msgs, $summary, 1);
    is(scalar(@local_msgs), 2, 'Local: no new message added (folded into user)');
    ok($local_msgs[1]{content} =~ /^<thread_summary>compressed<\/thread_summary>\n\nactual user input/, 'Local: summary folded at start of user message, input preserved');

    done_testing();
};

done_testing();
