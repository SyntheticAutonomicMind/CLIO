#!/usr/bin/env perl

use strict;
use warnings;
use lib 'lib';
use CLIO::Session::TodoStore;
use File::Temp qw(tempdir);
use File::Path qw(remove_tree);

# Test suite for TodoStore and TodoList tool

my $test_count = 0;
my $passed = 0;

sub test {
    my ($name, $code) = @_;
    $test_count++;
    print "\nTest $test_count: $name\n";
    eval { $code->() };
    if ($@) {
        print "❌ FAIL: $@\n";
    } else {
        print "✅ PASS\n";
        $passed++;
    }
}

# Create temp directory for test sessions
my $temp_dir = tempdir(CLEANUP => 1);
print "Using temp directory: $temp_dir\n";

# TEST 1: Create TodoStore and read empty list
test("Create TodoStore and read empty list", sub {
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'test_session_1',
        sessions_dir => $temp_dir,
    );
    
    my $todos = $store->read();
    
    die "Expected arrayref" unless ref $todos eq 'ARRAY';
    die "Expected empty array" unless @$todos == 0;
});

# TEST 2: Write todo list
test("Write todo list with 3 items", sub {
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'test_session_2',
        sessions_dir => $temp_dir,
    );
    
    my $todos = [
        {
            id => 1,
            title => "First task",
            description => "Do something important",
            status => "not-started",
        },
        {
            id => 2,
            title => "Second task",
            description => "Do another thing",
            status => "not-started",
        },
        {
            id => 3,
            title => "Third task",
            description => "Finish up",
            status => "not-started",
        },
    ];
    
    my ($success, $error) = $store->write($todos);
    
    die "Write failed: $error" unless $success;
    
    my $read_todos = $store->read();
    die "Expected 3 todos" unless @$read_todos == 3;
    die "Wrong first title" unless $read_todos->[0]{title} eq "First task";
});

# TEST 3: Update todo status
test("Update todo status: not-started -> in-progress -> completed", sub {
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'test_session_3',
        sessions_dir => $temp_dir,
    );
    
    # Create initial list
    my $todos = [
        { id => 1, title => "Task 1", description => "Work", status => "not-started" },
        { id => 2, title => "Task 2", description => "More work", status => "not-started" },
    ];
    
    $store->write($todos);
    
    # Update to in-progress
    my ($success, $result) = $store->update([{ id => 1, status => "in-progress" }]);
    die "Update failed: $result" unless $success;
    
    my $updated = $store->read();
    die "Expected in-progress" unless $updated->[0]{status} eq "in-progress";
    
    # Update to completed
    ($success, $result) = $store->update([{ id => 1, status => "completed" }]);
    die "Update failed: $result" unless $success;
    
    $updated = $store->read();
    die "Expected completed" unless $updated->[0]{status} eq "completed";
});

# TEST 4: Add new todos
test("Add new todos to existing list", sub {
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'test_session_4',
        sessions_dir => $temp_dir,
    );
    
    # Create initial list
    my $todos = [
        { id => 1, title => "Task 1", description => "Work", status => "not-started" },
        { id => 2, title => "Task 2", description => "More work", status => "not-started" },
    ];
    
    $store->write($todos);
    
    # Add new todos (without IDs - should be auto-assigned)
    my $new_todos = [
        { title => "Task 3", description => "New work", status => "not-started" },
        { title => "Task 4", description => "More new work", status => "not-started" },
    ];
    
    my ($success, $error) = $store->add($new_todos);
    die "Add failed: $error" unless $success;
    
    my $all_todos = $store->read();
    die "Expected 4 todos, got " . scalar(@$all_todos) unless @$all_todos == 4;
    die "Expected ID 3" unless $all_todos->[2]{id} == 3;
    die "Expected ID 4" unless $all_todos->[3]{id} == 4;
    die "Wrong title" unless $all_todos->[2]{title} eq "Task 3";
});

# TEST 5: Validation - multiple in-progress
test("Validation fails with multiple in-progress todos", sub {
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'test_session_5',
        sessions_dir => $temp_dir,
    );
    
    my $todos = [
        { id => 1, title => "Task 1", description => "Work", status => "in-progress" },
        { id => 2, title => "Task 2", description => "More work", status => "in-progress" },
    ];
    
    my ($success, $error) = $store->write($todos);
    die "Expected validation to fail" if $success;
    die "Expected error about multiple in-progress" unless $error =~ /Multiple todos marked as in-progress/;
});

# TEST 6: Validation - blocked without reason
test("Validation fails for blocked without blockedReason", sub {
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'test_session_6',
        sessions_dir => $temp_dir,
    );
    
    my $todos = [
        { id => 1, title => "Task 1", description => "Work", status => "blocked" },
    ];
    
    my ($success, $error) = $store->write($todos);
    die "Expected validation to fail" if $success;
    die "Expected error about blocked reason" unless $error =~ /blocked but has no blockedReason/;
});

# TEST 7: Validation - invalid progress range
test("Validation fails for progress outside 0.0-1.0", sub {
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'test_session_7',
        sessions_dir => $temp_dir,
    );
    
    my $todos = [
        { id => 1, title => "Task 1", description => "Work", status => "not-started", progress => 1.5 },
    ];
    
    my ($success, $error) = $store->write($todos);
    die "Expected validation to fail" if $success;
    die "Expected error about invalid progress" unless $error =~ /invalid progress/;
});

# TEST 8: Validation - non-existent dependency
test("Validation fails for non-existent dependency", sub {
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'test_session_8',
        sessions_dir => $temp_dir,
    );
    
    my $todos = [
        { id => 1, title => "Task 1", description => "Work", status => "not-started", dependencies => [99] },
    ];
    
    my ($success, $error) = $store->write($todos);
    die "Expected validation to fail" if $success;
    die "Expected error about non-existent dependency" unless $error =~ /depends on non-existent todo/;
});

# TEST 9: Validation - circular dependency
test("Validation fails for circular dependency", sub {
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'test_session_9',
        sessions_dir => $temp_dir,
    );
    
    my $todos = [
        { id => 1, title => "Task 1", description => "Work", status => "not-started", dependencies => [2] },
        { id => 2, title => "Task 2", description => "More work", status => "not-started", dependencies => [1] },
    ];
    
    my ($success, $error) = $store->write($todos);
    die "Expected validation to fail" if $success;
    die "Expected error about circular dependency" unless $error =~ /circular dependency/;
});

# TEST 10: Persistence across sessions
test("Todos persist across TodoStore instances", sub {
    my $session_id = 'test_session_10';
    
    # Create first store and write todos
    {
        my $store = CLIO::Session::TodoStore->new(
            session_id => $session_id,
            sessions_dir => $temp_dir,
        );
        
        my $todos = [
            { id => 1, title => "Persistent task", description => "Should survive", status => "not-started" },
        ];
        
        my ($success, $error) = $store->write($todos);
        die "Write failed: $error" unless $success;
    }
    
    # Create new store and read
    {
        my $store2 = CLIO::Session::TodoStore->new(
            session_id => $session_id,
            sessions_dir => $temp_dir,
        );
        
        my $todos = $store2->read();
        die "Expected 1 todo" unless @$todos == 1;
        die "Wrong title" unless $todos->[0]{title} eq "Persistent task";
    }
});

# TEST 11: Valid dependency chain
test("Valid dependency chain works", sub {
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'test_session_11',
        sessions_dir => $temp_dir,
    );
    
    my $todos = [
        { id => 1, title => "Foundation", description => "Base work", status => "not-started" },
        { id => 2, title => "Middle layer", description => "Depends on 1", status => "not-started", dependencies => [1] },
        { id => 3, title => "Top layer", description => "Depends on 2", status => "not-started", dependencies => [2] },
    ];
    
    my ($success, $error) = $store->write($todos);
    die "Write failed: $error" unless $success;
    
    my $read_todos = $store->read();
    die "Expected 3 todos" unless @$read_todos == 3;
});

# TEST 12: Blocked status with reason works
test("Blocked status with blockedReason is valid", sub {
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'test_session_12',
        sessions_dir => $temp_dir,
    );
    
    my $todos = [
        { 
            id => 1, 
            title => "Blocked task", 
            description => "Cannot proceed", 
            status => "blocked",
            blockedReason => "Waiting for external API",
        },
    ];
    
    my ($success, $error) = $store->write($todos);
    die "Write failed: $error" unless $success;
    
    my $read_todos = $store->read();
    die "Expected blocked status" unless $read_todos->[0]{status} eq "blocked";
    die "Expected blocked reason" unless $read_todos->[0]{blockedReason} eq "Waiting for external API";
});

# TEST 13: Priority field works
test("Priority field is stored and retrieved", sub {
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'test_session_13',
        sessions_dir => $temp_dir,
    );
    
    my $todos = [
        { id => 1, title => "Low priority", description => "Can wait", status => "not-started", priority => "low" },
        { id => 2, title => "High priority", description => "Do now", status => "not-started", priority => "high" },
    ];
    
    my ($success, $error) = $store->write($todos);
    die "Write failed: $error" unless $success;
    
    my $read_todos = $store->read();
    die "Expected low priority" unless $read_todos->[0]{priority} eq "low";
    die "Expected high priority" unless $read_todos->[1]{priority} eq "high";
});

# TEST 14: Progress field works
test("Progress field is stored and validated", sub {
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'test_session_14',
        sessions_dir => $temp_dir,
    );
    
    my $todos = [
        { id => 1, title => "Half done", description => "In progress", status => "in-progress", progress => 0.5 },
    ];
    
    my ($success, $error) = $store->write($todos);
    die "Write failed: $error" unless $success;
    
    my $read_todos = $store->read();
    die "Expected progress 0.5" unless $read_todos->[0]{progress} == 0.5;
});

# TEST 15: Update multiple fields at once
test("Update multiple fields in one operation", sub {
    my $store = CLIO::Session::TodoStore->new(
        session_id => 'test_session_15',
        sessions_dir => $temp_dir,
    );
    
    # Create initial todo
    my $todos = [
        { id => 1, title => "Original title", description => "Original description", status => "not-started" },
    ];
    
    $store->write($todos);
    
    # Update multiple fields
    my ($success, $result) = $store->update([{
        id => 1,
        title => "Updated title",
        description => "Updated description",
        status => "in-progress",
        progress => 0.3,
    }]);
    
    die "Update failed: $result" unless $success;
    
    my $updated = $store->read();
    die "Expected updated title" unless $updated->[0]{title} eq "Updated title";
    die "Expected updated description" unless $updated->[0]{description} eq "Updated description";
    die "Expected in-progress status" unless $updated->[0]{status} eq "in-progress";
    die "Expected progress 0.3" unless $updated->[0]{progress} == 0.3;
});

# Summary
print "\n" . "="x60 . "\n";
print "SUMMARY: $passed/$test_count tests passed\n";

if ($passed == $test_count) {
    print "✅ ALL TESTS PASSED\n";
    exit 0;
} else {
    print "❌ SOME TESTS FAILED\n";
    exit 1;
}
