#!/usr/bin/env perl
# Test: Session resume reconstructs <task_boundary> system messages
#
# When a session is saved and reloaded, any <task_boundary> messages
# must survive the round-trip. This is the persistence half of the
# task-aware compression story: boundaries written during the session
# must be readable after resume so YaRN can keep grouping by task.

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use File::Path qw(remove_tree);
use File::Spec;

my $TEST_DIR = '/tmp/clio_test_session_resume_tasks';
remove_tree($TEST_DIR) if -d $TEST_DIR;
mkdir $TEST_DIR or die "Cannot create $TEST_DIR: $!";

my $SESSION_ID = 'task-resume-test-1';

# Session 1: add some messages including task boundaries.
{
    require CLIO::Session::Manager;
    my $mgr = CLIO::Session::Manager->new(
        session_id => $SESSION_ID,
        sessions_dir => $TEST_DIR,
    );

    $mgr->add_message('system', '<task_boundary id="task-A" name="refactor" status="active" />');
    $mgr->add_message('user', 'Start refactor work');
    $mgr->add_message('assistant', 'Working on refactor');

    $mgr->add_message('system', '<task_boundary id="task-A" name="refactor" status="completed" />');
    $mgr->add_message('system', '<task_boundary id="task-B" name="implement" status="active" />');
    $mgr->add_message('user', 'Now implement new feature');

    # Force save.
    $mgr->{state}->save();
}

# Session 2: load and verify boundaries are present.
{
    require CLIO::Session::Manager;
    my $mgr = CLIO::Session::Manager->load($SESSION_ID, sessions_dir => $TEST_DIR);
    my $history = $mgr->get_conversation_history();

    my @boundaries = grep { $_->{role} eq 'system' && $_->{content} =~ /<task_boundary/ } @$history;
    is(scalar(@boundaries), 3, 'Three task boundary messages survived round-trip');

    like($boundaries[0]{content}, qr/id="task-A".*status="active"/, 'task-A active boundary');
    like($boundaries[1]{content}, qr/id="task-A".*status="completed"/, 'task-A completed boundary');
    like($boundaries[2]{content}, qr/id="task-B".*status="active"/, 'task-B active boundary');
}

# Session 3: verify YaRN can group by task from the resumed history.
{
    require CLIO::Session::Manager;
    require CLIO::Memory::YaRN;
    require CLIO::Memory::TokenEstimator;

    my $mgr = CLIO::Session::Manager->load($SESSION_ID, sessions_dir => $TEST_DIR);
    my $history = $mgr->get_conversation_history();

    # Add a fake tool call so the compression has files to capture
    push @$history, {
        role => 'assistant',
        content => 'Reading the file',
        tool_calls => [
            { id => 'tc1', function => { name => 'file_operations', arguments => '{"path":"lib/refactor.pl"}' } }
        ],
    };
    push @$history, {
        role => 'tool',
        tool_call_id => 'tc1',
        content => 'code',
    };

    my $yarn = CLIO::Memory::YaRN->new();
    my $result = $yarn->compress_messages($history,
        original_task => 'Start refactor work');

    # After resume, both task blocks should be present in the new summary.
    like($result->{content}, qr/<task\s+id="task-A"/, 'task-A present in post-resume summary');
    like($result->{content}, qr/<task\s+id="task-B"/, 'task-B present in post-resume summary');
}

# Cleanup.
remove_tree($TEST_DIR);

done_testing();