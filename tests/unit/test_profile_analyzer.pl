#!/usr/bin/env perl
# Test CLIO::Profile::Analyzer - session history analysis for profile building
#
# Tests the Analyzer's ability to scan session files, extract communication
# patterns, and generate draft profiles.

use strict;
use warnings;
use utf8;
use lib './lib';
use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path);
use CLIO::Util::JSON qw(encode_json);

use CLIO::Profile::Analyzer;

# Create test environment
my $test_dir = tempdir(CLEANUP => 1);
my $project_a = File::Spec->catdir($test_dir, 'project-alpha');
my $project_b = File::Spec->catdir($test_dir, 'project-beta');

# Helper to create a fake session file
sub create_session {
    my ($project_dir, $filename, $messages) = @_;
    my $sessions_dir = File::Spec->catdir($project_dir, '.clio', 'sessions');
    make_path($sessions_dir);

    my $data = { history => $messages };
    my $json = encode_json($data);

    my $path = File::Spec->catfile($sessions_dir, $filename);
    open my $fh, '>:encoding(UTF-8)', $path or die "Cannot write $path: $!";
    print $fh $json;
    close $fh;
    return $path;
}

# Test 1: Constructor
subtest 'constructor' => sub {
    my $analyzer = CLIO::Profile::Analyzer->new();
    ok(defined $analyzer, 'Analyzer created');
    is($analyzer->{debug}, 0, 'Debug defaults to 0');
};

# Test 2: Empty analysis
subtest 'analyze_sessions - no sessions' => sub {
    my $analyzer = CLIO::Profile::Analyzer->new();
    my $empty_dir = tempdir(CLEANUP => 1);
    my $results = $analyzer->analyze_sessions([$empty_dir]);

    ok(defined $results, 'Results returned');
    is($results->{total_sessions}, 0, 'Zero sessions');
    is($results->{total_user_msgs}, 0, 'Zero messages');
};

# Test 3: Basic session analysis
subtest 'analyze_sessions - basic messages' => sub {
    my $analyzer = CLIO::Profile::Analyzer->new();

    create_session($project_a, 'session1.json', [
        { role => 'user', content => 'Let us work on the new authentication module together' },
        { role => 'assistant', content => 'Sure, I will help with that.' },
        { role => 'user', content => 'I want to use minimal dependencies for this' },
        { role => 'user', content => 'yes' },
        { role => 'user', content => 'Great work, that looks perfect!' },
    ]);

    my $results = $analyzer->analyze_sessions([$project_a]);

    is($results->{total_sessions}, 1, 'One session found');
    # "yes" (3 chars) is filtered by length < 5 check, so 3 messages counted
    is($results->{total_user_msgs}, 3, 'Three user messages (short "yes" filtered)');
};

# Test 4: Style detection
subtest 'style detection' => sub {
    my $analyzer = CLIO::Profile::Analyzer->new();

    create_session($project_a, 'session2.json', [
        { role => 'user', content => "Let's refactor this together, we need a cleaner approach" },
        { role => 'user', content => "I want the architecture to be clean and maintainable" },
        { role => 'user', content => "No, that's not what I need. Wrong approach entirely." },
        { role => 'user', content => "Good job, that looks great now" },
        { role => 'user', content => "proceed" },
        { role => 'user', content => "Also, while you're at it, add error handling" },
        { role => 'user', content => "I'd like to see the test results before we commit" },
        { role => 'user', content => "Here's the error: ```perl\ndie 'oops';\n```" },
        { role => 'user', content => "Check https://example.com/docs for reference" },
        { role => 'user', content => "The design pattern should follow the strategy approach" },
        { role => 'user', content => "Because we did this before in the last session, remember?" },
    ]);

    my $results = $analyzer->analyze_sessions([$project_a]);
    my $style = $results->{style};

    ok(($style->{collaborative_language} || 0) > 0, 'Detected collaborative language');
    ok(($style->{states_desires} || 0) > 0, 'Detected desire statements');
    ok(($style->{corrections_redirects} || 0) > 0, 'Detected corrections');
    ok(($style->{positive_feedback} || 0) > 0, 'Detected positive feedback');
    ok(($style->{concise_approvals} || 0) > 0, 'Detected concise approvals');
    ok(($style->{adds_requirements_iteratively} || 0) > 0, 'Detected iterative requirements');
    ok(($style->{includes_code} || 0) > 0, 'Detected code inclusion');
    ok(($style->{shares_urls} || 0) > 0, 'Detected URL sharing');
    ok(($style->{strategic_thinking} || 0) > 0, 'Detected strategic thinking');
    ok(($style->{references_past_work} || 0) > 0, 'Detected past work references');
};

# Test 5: Topic detection
subtest 'topic detection' => sub {
    my $analyzer = CLIO::Profile::Analyzer->new();

    create_session($project_b, 'session3.json', [
        { role => 'user', content => "Let's write a perl script that handles JSON parsing" },
        { role => 'user', content => "I need to deploy this with git and run the test suite" },
        { role => 'user', content => "The python version uses a different API approach" },
    ]);

    my $results = $analyzer->analyze_sessions([$project_b]);
    my $topics = $results->{topics};

    ok(($topics->{perl} || 0) > 0, 'Detected perl topic');
    ok(($topics->{json} || 0) > 0, 'Detected json topic');
    ok(($topics->{git} || 0) > 0, 'Detected git topic');
    ok(($topics->{test} || 0) > 0, 'Detected test topic');
    ok(($topics->{python} || 0) > 0, 'Detected python topic');
    ok(($topics->{API} || 0) > 0, 'Detected API topic');
};

# Test 6: Multi-project analysis
subtest 'multi-project analysis' => sub {
    my $analyzer = CLIO::Profile::Analyzer->new();
    my $results = $analyzer->analyze_sessions([$project_a, $project_b]);

    ok($results->{total_sessions} >= 2, 'Multiple sessions across projects');
    my $proj_count = scalar(keys %{$results->{projects}});
    ok($proj_count >= 2, "Found $proj_count projects (expected >= 2)");
};

# Test 7: Skips system messages
subtest 'skips non-user content' => sub {
    my $analyzer = CLIO::Profile::Analyzer->new();
    my $skip_dir = File::Spec->catdir($test_dir, 'project-skip');

    create_session($skip_dir, 'session_skip.json', [
        { role => 'system', content => 'You are a helpful assistant' },
        { role => 'assistant', content => 'How can I help?' },
        { role => 'user', content => '[TOOL_RESULT: something]' },
        { role => 'user', content => '<system>internal</system>' },
        { role => 'user', content => 'hi' },
        { role => 'user', content => 'This is a real user message that should count' },
    ]);

    my $results = $analyzer->analyze_sessions([$skip_dir]);
    is($results->{total_user_msgs}, 1, 'Only real user message counted');
};

# Test 8: generate_profile_draft
subtest 'generate_profile_draft' => sub {
    my $analyzer = CLIO::Profile::Analyzer->new();
    my $results = $analyzer->analyze_sessions([$project_a, $project_b]);

    my $draft = $analyzer->generate_profile_draft($results);
    ok(defined $draft, 'Draft generated');
    like($draft, qr/## User Profile/, 'Contains profile header');
    ok(length($draft) > 20, 'Draft has meaningful content');
};

# Test 9: get_session_count
subtest 'get_session_count' => sub {
    my $analyzer = CLIO::Profile::Analyzer->new();

    # Override default search paths to our test dir
    no warnings 'redefine';
    local *CLIO::Profile::Analyzer::_default_search_paths = sub {
        return [$project_a, $project_b];
    };

    my $count = $analyzer->get_session_count();
    ok($count >= 2, "Found $count sessions (expected >= 2)");
};

# Test 10: Handles malformed JSON gracefully
subtest 'handles malformed JSON' => sub {
    my $analyzer = CLIO::Profile::Analyzer->new();
    my $bad_dir = File::Spec->catdir($test_dir, 'project-bad');
    my $sessions_dir = File::Spec->catdir($bad_dir, '.clio', 'sessions');
    make_path($sessions_dir);

    # Write invalid JSON
    my $bad_path = File::Spec->catfile($sessions_dir, 'bad.json');
    open my $fh, '>', $bad_path or die;
    print $fh "not valid json {{{";
    close $fh;

    my $results = $analyzer->analyze_sessions([$bad_dir]);
    is($results->{total_sessions}, 0, 'Malformed JSON skipped gracefully');
};

# Test 11: Handles array content in messages
subtest 'handles array content' => sub {
    my $analyzer = CLIO::Profile::Analyzer->new();
    my $arr_dir = File::Spec->catdir($test_dir, 'project-array');

    create_session($arr_dir, 'session_array.json', [
        { role => 'user', content => [
            { type => 'text', text => "Let's work on this together as a team" }
        ]},
    ]);

    my $results = $analyzer->analyze_sessions([$arr_dir]);
    is($results->{total_user_msgs}, 1, 'Array content parsed correctly');
    ok(($results->{style}{collaborative_language} || 0) > 0, 'Style detected from array content');
};

# Test 12: Trait derivation
subtest 'trait derivation' => sub {
    my $analyzer = CLIO::Profile::Analyzer->new();
    my $trait_dir = File::Spec->catdir($test_dir, 'project-traits');

    # Create enough messages to trigger trait detection
    my @msgs;
    for my $i (1..20) {
        push @msgs, { role => 'user', content => "Please squash the commits before pushing" };
        push @msgs, { role => 'user', content => "Don't push without asking me first" };
        push @msgs, { role => 'user', content => "We need minimal dependencies for this" };
    }

    create_session($trait_dir, 'session_traits.json', \@msgs);

    my $results = $analyzer->analyze_sessions([$trait_dir]);
    my $traits = $results->{profile_traits};

    ok(defined $traits, 'Traits derived');
    is($traits->{prefers_squash_commits}, 1, 'Detected squash preference');
    is($traits->{dont_push_without_asking}, 1, 'Detected push preference');
    is($traits->{minimal_dependencies}, 1, 'Detected dependency preference');
};

# Test 13: Skips todos.json
subtest 'skips todos.json' => sub {
    my $analyzer = CLIO::Profile::Analyzer->new();
    my $todo_dir = File::Spec->catdir($test_dir, 'project-todo');
    my $sessions_dir = File::Spec->catdir($todo_dir, '.clio', 'sessions');
    make_path($sessions_dir);

    # Create a todos.json that should be ignored
    my $todo_path = File::Spec->catfile($sessions_dir, 'todos.json');
    open my $fh, '>', $todo_path or die;
    print $fh '{"todos":[]}';
    close $fh;

    # Create a real session
    create_session($todo_dir, 'real_session.json', [
        { role => 'user', content => 'This is a legitimate session message' },
    ]);

    my $results = $analyzer->analyze_sessions([$todo_dir]);
    is($results->{total_sessions}, 1, 'Only real session counted, todos.json skipped');
};

done_testing();
