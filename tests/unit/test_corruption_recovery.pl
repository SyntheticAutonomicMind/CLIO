#!/usr/bin/env perl
=head1 NAME

test_corruption_recovery.pl - Regression tests for hash-ref content corruption

=head1 SYNOPSIS

  perl -I./lib tests/unit/test_corruption_recovery.pl

=head1 DESCRIPTION

Tests defense-in-depth recovery for the ReadLine control-signal leak that
caused hash/array ref content in user messages. Strict-schema providers
(e.g. NVIDIA NIM) reject these with "data did not match any variant of
untagged enum ChatCompletionRequestUserMessageContent". Permissive providers
(minimax) accept them silently, which is why the bug was invisible in some
sessions and fatal in others.

Three layers of defense:

1. State::load migration - coerces ref content to a string marker on load
   AND persists the fix to disk (so subsequent loads don't re-migrate)
2. ConversationManager JIT coercion - belt-and-suspenders coercion of any
   ref content that leaks through State::load
3. repair_session.pl --auto - explicit tool for offline recovery, default
   is to replace content (not drop messages) to preserve conversation flow

These tests verify all three layers.

=cut

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use JSON::PP qw(decode_json encode_json);
use Cwd;

# Pre-load modules before chdir
use CLIO::Session::Manager;
use CLIO::Session::State;
use CLIO::Core::ConversationManager;

# Setup
my $test_dir = tempdir(CLEANUP => 1);
chdir $test_dir or die "Cannot chdir to $test_dir: $!";
mkdir '.clio' or die "Cannot mkdir .clio: $!";
mkdir '.clio/sessions' or die "Cannot mkdir .clio/sessions: $!";

# =============================================================================
# Helper: write a corrupted session JSON to disk
# =============================================================================
sub write_corrupted_session {
    my ($session_id, $history) = @_;
    my $data = {
        history => $history,
        stm     => [],
        yarn    => {},
        created_at => time(),
    };
    my $path = ".clio/sessions/$session_id.json";
    open my $fh, '>:raw', $path or die "Cannot write $path: $!";
    print $fh encode_json($data);
    close $fh;
    return $path;
}

# =============================================================================
# Layer 1: State::load migration coerces ref content and persists to disk
# =============================================================================

# 1a. Hash-ref content is coerced to string marker
{
    my $sid = 'corrupt-hash';
    write_corrupted_session($sid, [
        { role => 'user',      content => 'Hi there' },
        { role => 'user',      content => { type => '__TIMEOUT__' } },  # corrupted
        { role => 'assistant', content => 'Hello' },
    ]);

    my $state = CLIO::Session::State->load($sid, debug => 0);
    ok($state, 'State::load succeeded on hash-ref corrupted session');

    my @history = @{$state->{history}};
    is(scalar @history, 3, 'message count preserved (no drops)');

    is($history[0]{content}, 'Hi there', 'first msg content unchanged');
    ok(!ref($history[1]{content}), 'second msg content is now a string (not ref)');
    like($history[1]{content}, qr/\[CORRUPTED INPUT: HASH type='__TIMEOUT__' - migrated by session loader\]/,
        'second msg has [CORRUPTED INPUT: ...] marker');
    is($history[2]{content}, 'Hello', 'third msg content unchanged');
}

# 1b. Array-ref content is coerced to string marker
{
    my $sid = 'corrupt-array';
    write_corrupted_session($sid, [
        { role => 'user', content => ['nested', 'array'] },
    ]);

    my $state = CLIO::Session::State->load($sid, debug => 0);
    my @history = @{$state->{history}};
    ok(!ref($history[0]{content}), 'array-ref content coerced to string');
    like($history[0]{content}, qr/\[CORRUPTED INPUT: ARRAY/,
        'array-ref marker mentions ARRAY');
}

# 1c. Mixed: multiple corrupted messages + real messages, no real messages lost
{
    my $sid = 'corrupt-mixed';
    write_corrupted_session($sid, [
        { role => 'user',      content => 'First question' },
        { role => 'assistant', content => 'First answer' },
        { role => 'user',      content => { type => '__AGENT_EVENT__' } },
        { role => 'assistant', content => { type => 'unexpected' } },
        { role => 'user',      content => 'Second question' },
        { role => 'assistant', content => 'Second answer' },
    ]);

    my $state = CLIO::Session::State->load($sid, debug => 0);
    my @history = @{$state->{history}};
    is(scalar @history, 6, 'all 6 messages preserved (none dropped)');

    is($history[0]{content}, 'First question', 'msg 0 unchanged');
    is($history[1]{content}, 'First answer',   'msg 1 unchanged');
    like($history[2]{content}, qr/__AGENT_EVENT__/, 'msg 2 user ref -> marker (preserves type)');
    like($history[3]{content}, qr/__TIMEOUT__|unexpected/, 'msg 3 assistant ref -> marker');
    is($history[4]{content}, 'Second question', 'msg 4 unchanged');
    is($history[5]{content}, 'Second answer',   'msg 5 unchanged');
}

# 1d. Re-loading after migration does NOT re-migrate (file was re-saved)
{
    my $sid = 'corrupt-persist';
    write_corrupted_session($sid, [
        { role => 'user', content => { type => '__TIMEOUT__' } },
    ]);

    # First load: migration runs and saves back
    my $state1 = CLIO::Session::State->load($sid, debug => 0);
    ok($state1, 'first load succeeded');

    # Verify file on disk has the marker (not raw hash ref)
    open my $fh, '<:raw', ".clio/sessions/$sid.json" or die;
    my $disk = do { local $/; <$fh> };
    close $fh;
    like($disk, qr/\[CORRUPTED INPUT: HASH type='__TIMEOUT__' - migrated by session loader\]/,
        'on-disk file shows migrated marker after first load');
    unlike($disk, qr/"type":"__TIMEOUT__"/,
        'on-disk file no longer contains raw hash ref');

    # Second load: should NOT trigger migration (data is already clean)
    my $state2 = CLIO::Session::State->load($sid, debug => 0);
    my $content2 = $state2->{history}[0]{content};
    ok(!ref($content2), 'second load: content is still string (no double-coercion)');
    like($content2, qr/\[CORRUPTED INPUT: HASH type='__TIMEOUT__' - migrated by session loader\]/,
        'second load: marker preserved verbatim (no double-wrap)');
}

# 1e. Healthy sessions are not touched
{
    my $sid = 'healthy';
    write_corrupted_session($sid, [
        { role => 'user',      content => 'What is 2+2?' },
        { role => 'assistant', content => 'Four' },
    ]);

    my $state = CLIO::Session::State->load($sid, debug => 0);
    my @history = @{$state->{history}};
    is($history[0]{content}, 'What is 2+2?', 'healthy msg 0 unchanged');
    is($history[1]{content}, 'Four',          'healthy msg 1 unchanged');
}

# =============================================================================
# Layer 2: ConversationManager JIT coercion (belt-and-suspenders)
# =============================================================================

# 2a. JIT coerces ref content even if State::load was bypassed
{
    # Simulate a hash-ref content slipping past State::load by calling
    # load_conversation_history with a fake session hash directly.
    # load_conversation_history checks for $session->{conversation_history}
    # first when $session is a hashref.
    my $fake_session = {
        conversation_history => [
            { role => 'user',      content => 'Hi' },
            { role => 'user',      content => { type => '__TIMEOUT__' } },
            { role => 'assistant', content => 'Hello' },
        ],
    };

    my $valid = CLIO::Core::ConversationManager::load_conversation_history(
        $fake_session, debug => 0
    );

    ok($valid && ref($valid) eq 'ARRAY', 'JIT returned an arrayref');
    is(scalar @$valid, 3, 'JIT preserved all 3 messages');

    ok(!ref($valid->[1]{content}), 'JIT coerced hash-ref content to string');
    like($valid->[1]{content}, qr/\[CORRUPTED INPUT: HASH type='__TIMEOUT__' - repaired at JIT\]/,
        'JIT marker indicates repair-at-JIT origin');
}

# 2b. JIT handles array-ref content too
{
    my $fake_session = {
        conversation_history => [
            { role => 'user', content => ['list', 'of', 'items'] },
        ],
    };

    my $valid = CLIO::Core::ConversationManager::load_conversation_history(
        $fake_session, debug => 0
    );
    is(scalar @$valid, 1, 'array-ref session: 1 message');
    ok(!ref($valid->[0]{content}), 'JIT coerced array-ref to string');
    like($valid->[0]{content}, qr/\[CORRUPTED INPUT: ARRAY/, 'JIT array marker');
}

# =============================================================================
# Layer 3: repair_session.pl integration
# =============================================================================

# 3a. Default repair (--auto) replaces content (preserves message count)
{
    use File::Path qw(make_path rmtree);
    use File::Copy qw(copy);

    my $repair_dir = "$test_dir/repair_test_$$";
    make_path($repair_dir);

    my $session_file = "$repair_dir/test1.json";
    open my $fh, '>:raw', $session_file or die;
    print $fh encode_json({
        history => [
            { role => 'user',      content => 'real' },
            { role => 'user',      content => { type => '__TIMEOUT__' } },
            { role => 'assistant', content => 'response' },
        ],
    });
    close $fh;

    local $ENV{CLIO_SESSIONS_DIR} = $repair_dir;
    my $output = `perl -I$FindBin::Bin/../../lib $FindBin::Bin/../../scripts/repair_session.pl --auto 2>&1`;
    my $rc = $? >> 8;
    is($rc, 0, "repair_session.pl --auto exited 0: $output");

    open my $rfh, '<:raw', $session_file or die;
    my $fixed = do { local $/; <$rfh> };
    close $rfh;
    my $data = decode_json($fixed);
    is(scalar @{$data->{history}}, 3, 'all 3 messages preserved by repair');
    like($data->{history}[1]{content}, qr/\[CORRUPTED INPUT: HASH type='__TIMEOUT__' - repaired by repair_session\.pl\]/,
        'repair replaced with marker');
    is($data->{history}[0]{content}, 'real', 'preceding real msg preserved');
    is($data->{history}[2]{content}, 'response', 'following real msg preserved');

    rmtree($repair_dir);
}

# 3b. --drop-messages opt-in still drops (legacy behavior)
{
    use File::Path qw(make_path rmtree);

    my $repair_dir = "$test_dir/repair_test_drop_$$";
    make_path($repair_dir);

    my $session_file = "$repair_dir/test2.json";
    open my $fh, '>:raw', $session_file or die;
    print $fh encode_json({
        history => [
            { role => 'user',      content => 'real' },
            { role => 'user',      content => { type => '__TIMEOUT__' } },
            { role => 'assistant', content => 'response' },
        ],
    });
    close $fh;

    local $ENV{CLIO_SESSIONS_DIR} = $repair_dir;
    my $output = `perl -I$FindBin::Bin/../../lib $FindBin::Bin/../../scripts/repair_session.pl --auto --drop-messages 2>&1`;
    my $rc = $? >> 8;
    is($rc, 0, "repair_session.pl --auto --drop-messages exited 0: $output");

    open my $rfh, '<:raw', $session_file or die;
    my $fixed = do { local $/; <$rfh> };
    close $rfh;
    my $data = decode_json($fixed);
    is(scalar @{$data->{history}}, 2, 'corrupted message dropped (legacy behavior)');
    is($data->{history}[0]{content}, 'real', 'first real msg preserved');
    is($data->{history}[1]{content}, 'response', 'second real msg preserved');

    rmtree($repair_dir);
}

done_testing();