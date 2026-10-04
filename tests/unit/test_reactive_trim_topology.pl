#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)
#
# Regression test: reactive token-limit recovery topology.
#
# Verifies that trim_for_token_limit (the reactive path in ErrorHandler)
# produces a message topology consistent with the proactive path in
# MessageValidator::_role_based_tail_walk:
#
#   CANONICAL: SYSTEM(system_prompt) ... SYSTEM(thread_summary) USER(current)
#   NOT:       SYSTEM(system_prompt) ... USER(current) SYSTEM(thread_summary)
#
# Also verifies that the current user message is NEVER dropped and that
# the last message sent to the provider is always a USER message.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;

use CLIO::Core::API::ErrorHandler;
use CLIO::Core::API::MessageValidator qw(validate_and_truncate);

# ── Stand-in objects for trim_for_token_limit ────────────────────────
package FakeCaps {
    sub new { bless {}, shift }
    sub model_routing_active { 0 }
    sub get_current_model    { 'openai/gpt-4' }
    sub get_model_capabilities {
        return {
            context_window          => 10000,
            max_output_tokens       => 2048,
            max_prompt_tokens       => 8000,
            max_context_window_tokens => 10000,
        };
    }
}

package FakeWO {
    sub new {
        my ($class, %a) = @_;
        return bless {
            api_manager    => $a{api_manager},
            prompt_builder => undef,
            debug          => 0,
        }, $class;
    }
}

# Build a large message array: system + 40 user/assistant pairs + current user
sub _make_big_messages {
    my @m;
    push @m, { role => 'system', content => 'You are a helpful assistant.' };
    for my $i (1..40) {
        push @m,
            { role => 'user',     content => "user turn $i: do something important " . ('x' x 500) },
            { role => 'assistant', content => "assistant reply $i " . ('y' x 500) };
    }
    push @m, { role => 'user', content => 'Continue the current work on the project' };
    return @m;
}

sub _last_role { my ($msgs) = @_; return $msgs->[-1]{role} // 'undef' }

sub _last_user_present {
    my ($msgs, $expected_content) = @_;
    return unless @$msgs;
    my $last = $msgs->[-1];
    return 1 if defined $last && $last->{role} eq 'user'
        && ($expected_content // '') ne ''
        && ($last->{content} // '') eq $expected_content;
    # Also check if the user message is present anywhere (for non-last positions)
    for my $msg (@$msgs) {
        return 1 if ref($msg) eq 'HASH'
            && ($msg->{role} // '') eq 'user'
            && ($msg->{content} // '') eq $expected_content;
    }
    return 0;
}

sub _has_thread_summary {
    my ($msgs) = @_;
    for my $msg (@$msgs) {
        return 1 if ref($msg) eq 'HASH'
            && ($msg->{role} // '') eq 'system'
            && ($msg->{content} // '') =~ /<thread_summary>/;
    }
    return 0;
}

sub _system_after_last_user {
    my ($msgs) = @_;
    my $last_user_idx = -1;
    for my $i (reverse 0 .. $#$msgs) {
        if (ref($msgs->[$i]) eq 'HASH'
            && ($msgs->[$i]{role} // '') eq 'user') {
            $last_user_idx = $i;
            last;
        }
    }
    return 0 if $last_user_idx < 0;
    # Check if any system message appears AFTER the last user
    for my $i ($last_user_idx + 1 .. $#$msgs) {
        return 1 if ref($msgs->[$i]) eq 'HASH'
            && ($msgs->[$i]{role} // '') eq 'system';
    }
    return 0;
}

# ── Tests ────────────────────────────────────────────────────────────

subtest 'retry_count==1: reactive trim preserves current user as last message' => sub {
    my @messages = _make_big_messages();
    my $wo = FakeWO->new(api_manager => FakeCaps->new);
    my $rc = 1;
    my $ctx = {
        messages        => \@messages,
        retry_count     => \$rc,
        session         => undef,
        tool_calls_made => [],
        iteration       => 1,
        max_retries     => 3,
        max_server_retries => 0,
        error           => 'token limit',
    };

    my $result = CLIO::Core::API::ErrorHandler::trim_for_token_limit($wo, %$ctx);

    ok($result->{retried}, 'did not bail (retry_count=1)');

    # CRITICAL: last message must be USER (current user message)
    is(_last_role(\@messages), 'user',
        'last message is USER (current request preserved as final message)');

    # Current user message must be present
    ok(_last_user_present(\@messages, 'Continue the current work on the project'),
        'current user message content is present');

    # No system message after the last user
    ok(!_system_after_last_user(\@messages),
        'no SYSTEM message appears after the last USER message');

    # thread_summary should be present (before the last user)
    ok(_has_thread_summary(\@messages),
        'thread_summary is present in trimmed messages');

    # System prompt should be preserved
    is($messages[0]{role}, 'system', 'system_prompt preserved at index 0');
};

subtest 'retry_count==1: message count is reasonable (not collapsed to 2)' => sub {
    my @messages = _make_big_messages();
    my $wo = FakeWO->new(api_manager => FakeCaps->new);
    my $rc = 1;
    my $ctx = {
        messages        => \@messages,
        retry_count     => \$rc,
        session         => undef,
        tool_calls_made => [],
        iteration       => 1,
        max_retries     => 3,
        max_server_retries => 0,
        error           => 'token limit',
    };

    CLIO::Core::API::ErrorHandler::trim_for_token_limit($wo, %$ctx);

    # Before the fix, the Perl range bug (N..-1 = empty list) collapsed
    # @non_system to 0 elements, leaving only system_prompt + summary = 2.
    # After the fix, the walk keeps ~10 messages + summary = 11+ (plus system = 12+).
    ok(scalar(@messages) > 3,
        'more than 3 messages survive (got ' . scalar(@messages) . ')');
};

subtest 'retry_count==2: summary injected before last user, not after' => sub {
    my @messages = _make_big_messages();
    my $wo = FakeWO->new(api_manager => FakeCaps->new);
    my $rc = 2;
    my $ctx = {
        messages        => \@messages,
        retry_count     => \$rc,
        session         => undef,
        tool_calls_made => [],
        iteration       => 1,
        max_retries     => 3,
        max_server_retries => 0,
        error           => 'token limit',
    };

    my $result = CLIO::Core::API::ErrorHandler::trim_for_token_limit($wo, %$ctx);

    # retry_count==2 may bail if minimal context still overflows
    if (exists $result->{bail}) {
        ok(1, 'bailed (acceptable for retry_count=2)');
        return;
    }

    is(_last_role(\@messages), 'user',
        'last message is USER after retry_count==2 trim');
    ok(!_system_after_last_user(\@messages),
        'no SYSTEM after last USER (retry_count==2)');
    ok(_last_user_present(\@messages, 'Continue the current work on the project'),
        'current user message present (retry_count==2)');
};

subtest 'retry_count==3 (minimal): summary before last user if not bailed' => sub {
    my @messages = _make_big_messages();
    my $wo = FakeWO->new(api_manager => FakeCaps->new);
    my $rc = 3;
    my $ctx = {
        messages        => \@messages,
        retry_count     => \$rc,
        session         => undef,
        tool_calls_made => [],
        iteration       => 1,
        max_retries     => 3,
        max_server_retries => 0,
        error           => 'token limit',
    };

    my $result = CLIO::Core::API::ErrorHandler::trim_for_token_limit($wo, %$ctx);

    if (exists $result->{bail}) {
        ok(1, 'bailed (acceptable for retry_count=3 minimal trim)');
        return;
    }

    is(_last_role(\@messages), 'user',
        'last message is USER after retry_count==3 trim');
    ok(!_system_after_last_user(\@messages),
        'no SYSTEM after last USER (retry_count==3)');
};

subtest 'short current user input (e.g. "continue") still preserved as last message' => sub {
    my @messages = _make_big_messages();
    # Replace the last user message with a short one
    $messages[-1] = { role => 'user', content => 'continue' };

    my $wo = FakeWO->new(api_manager => FakeCaps->new);
    my $rc = 1;
    my $ctx = {
        messages        => \@messages,
        retry_count     => \$rc,
        session         => undef,
        tool_calls_made => [],
        iteration       => 1,
        max_retries     => 3,
        max_server_retries => 0,
        error           => 'token limit',
    };

    CLIO::Core::API::ErrorHandler::trim_for_token_limit($wo, %$ctx);

    is(_last_role(\@messages), 'user',
        'last message is USER even with short input');
    is($messages[-1]{content}, 'continue',
        'short user input preserved as-is');
    ok(!_system_after_last_user(\@messages),
        'no SYSTEM after last USER for short input');
};

subtest 'reactive trim then proactive validate_and_truncate keeps USER last' => sub {
    # Simulate the retry loop: reactive trim -> proactive validate_and_truncate
    my @messages = _make_big_messages();
    my $wo = FakeWO->new(api_manager => FakeCaps->new);
    my $rc = 1;
    my $ctx = {
        messages        => \@messages,
        retry_count     => \$rc,
        session         => undef,
        tool_calls_made => [],
        iteration       => 1,
        max_retries     => 3,
        max_server_retries => 0,
        error           => 'token limit',
    };

    CLIO::Core::API::ErrorHandler::trim_for_token_limit($wo, %$ctx);

    # Now apply proactive trim (simulates the next loop iteration)
    my $proactive = validate_and_truncate(
        messages           => \@messages,
        model_capabilities => FakeCaps->new->get_model_capabilities(),
        tools              => [],
        debug              => 0,
        model              => 'test',
        active_task        => 'Continue the current work on the project',
    );

    @messages = @$proactive;

    is(_last_role(\@messages), 'user',
        'after proactive trim following reactive: last message is USER');
    ok(!_system_after_last_user(\@messages),
        'after proactive+reactive: no SYSTEM after last USER');
};

subtest 'message_structure_error recovery finds last user (not messages[-1] assumption)' => sub {
    # assumption holds after reactive trim (so the recovery would work).
    my @messages = _make_big_messages();
    my $wo = FakeWO->new(api_manager => FakeCaps->new);
    my $rc = 1;
    my $ctx = {
        messages        => \@messages,
        retry_count     => \$rc,
        session         => undef,
        tool_calls_made => [],
        iteration       => 1,
        max_retries     => 3,
        max_server_retries => 0,
        error           => 'token limit',
    };

    CLIO::Core::API::ErrorHandler::trim_for_token_limit($wo, %$ctx);

    # After trim, the last message should be USER (current)
    # This means the message_structure_error recovery's assumption
    # ($messages->[-1]{role} eq 'user') holds true.
    is(_last_role(\@messages), 'user',
        'messages[-1] is USER - message_structure_error recovery assumption holds');
};

subtest 'message_structure_error recovery scans backward for last user' => sub {
    # Simulate a scenario where messages[-1] is a SYSTEM message
    # (e.g. from a buggy trim or provider quirk). The recovery
    # should still find and preserve the current user message.
    my @messages = (
        { role => 'system', content => 'System prompt' },
        { role => 'assistant', content => 'Some work done' },
        { role => 'user', content => 'Current request to do X' },
        { role => 'system', content => 'Some trailing system note' },
    );

    # Simulate the recovery logic: scan backward for last user
    my $current_user_msg = undef;
    for my $i (reverse 0 .. $#messages) {
        if (ref($messages[$i]) eq 'HASH'
            && ($messages[$i]{role} // '') eq 'user') {
            $current_user_msg = $messages[$i];
            last;
        }
    }

    ok($current_user_msg, 'found last user message even with trailing SYSTEM');
    is($current_user_msg->{content}, 'Current request to do X',
        'recovered user content is correct');
};

subtest 'repeated token-limit failures do not progressively destroy state' => sub {
    # Simulate: token overflow -> reactive trim (rc=1) -> proactive trim ->
    # token overflow again -> reactive trim (rc=2) -> proactive trim.
    # The task and current user message must survive each cycle.
    for my $rc (1..2) {
        my @messages = _make_big_messages();
        my $wo = FakeWO->new(api_manager => FakeCaps->new);
        my $retry = $rc;
        my $ctx = {
            messages        => \@messages,
            retry_count     => \$retry,
            session         => undef,
            tool_calls_made => [],
            iteration       => 1,
            max_retries     => 3,
            max_server_retries => 0,
            error           => 'token limit',
        };

        CLIO::Core::API::ErrorHandler::trim_for_token_limit($wo, %$ctx);

        # After reactive trim, apply proactive trim (simulates retry loop)
        my $proactive = validate_and_truncate(
            messages           => \@messages,
            model_capabilities => FakeCaps->new->get_model_capabilities(),
            tools              => [],
            debug              => 0,
            model              => 'test',
            active_task        => 'Continue the current work on the project',
        );
        @messages = @$proactive;

        is(_last_role(\@messages), 'user',
            "after rc=$rc + proactive: last message is USER");
        ok(!_system_after_last_user(\@messages),
            "after rc=$rc + proactive: no SYSTEM after last USER");
        ok(_last_user_present(\@messages, 'Continue the current work on the project'),
            "after rc=$rc + proactive: current user message preserved");
    }
};

subtest 'tiny task with large history: user message survives as last message' => sub {
    my @messages = _make_big_messages();
    $messages[-1] = { role => 'user', content => 'list' };

    my $wo = FakeWO->new(api_manager => FakeCaps->new);
    my $rc = 1;
    my $ctx = {
        messages        => \@messages,
        retry_count     => \$rc,
        session         => undef,
        tool_calls_made => [],
        iteration       => 1,
        max_retries     => 3,
        max_server_retries => 0,
        error           => 'token limit',
    };

    CLIO::Core::API::ErrorHandler::trim_for_token_limit($wo, %$ctx);

    is(_last_role(\@messages), 'user', 'last message is USER for tiny task');
    is($messages[-1]{content}, 'list', 'tiny task content preserved exactly');
    ok(!_system_after_last_user(\@messages),
        'no SYSTEM after USER for tiny task');
};

done_testing();
