#!/usr/bin/env perl

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

test_subagent_commands.pl - Tests for /subagent command parsing and project resolution

=head1 DESCRIPTION

Tests the --project flag parsing, --dir flag, and /subagent projects output
by mocking the coordination layer.

=cut

use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;

# ============================================================================
# 1. Module loading
# ============================================================================

BEGIN {
    use_ok('CLIO::Protocols::Puppeteer') or BAIL_OUT("Cannot load Puppeteer");
    use_ok('CLIO::UI::Commands::SubAgent') or BAIL_OUT("Cannot load SubAgent command");
}

# ============================================================================
# 2. SubAgent command option parsing (--dir, --project, --model)
# ============================================================================

# We test the parsing logic by examining the regex behavior used in cmd_spawn.
# Since cmd_spawn requires a full Chat/coordination setup, we test the
# option extraction patterns directly.

subtest 'Option extraction: --model' => sub {
    my $task = 'fix the bug --model gpt-4.1 in module X';
    if ($task =~ s/\s*--model\s+(\S+)\s*/ /) {
        is($1, 'gpt-4.1', 'Extracted model name');
        $task =~ s/^\s+|\s+$//g;
        like($task, qr/fix the bug in module X/, 'Task cleaned after model extraction');
    } else {
        fail('--model not matched');
    }
};

subtest 'Option extraction: --dir' => sub {
    my $task = 'analyze code --dir /tmp/myproject carefully';
    if ($task =~ s/\s*--dir\s+"([^"]+)"\s*/ / || $task =~ s/\s*--dir\s+(\S+)\s*/ /) {
        is($1, '/tmp/myproject', 'Extracted dir path');
    } else {
        fail('--dir not matched');
    }
};

subtest 'Option extraction: --dir with quotes' => sub {
    my $task = 'analyze code --dir "/path/with spaces" carefully';
    if ($task =~ s/\s*--dir\s+"([^"]+)"\s*/ / || $task =~ s/\s*--dir\s+(\S+)\s*/ /) {
        is($1, '/path/with spaces', 'Extracted quoted dir path');
    } else {
        fail('--dir with quotes not matched');
    }
};

subtest 'Option extraction: --project' => sub {
    my $task = 'fix tests --project SAM now';
    if ($task =~ s/\s*--project\s+"([^"]+)"\s*/ / || $task =~ s/\s*--project\s+(\S+)\s*/ /) {
        is($1, 'SAM', 'Extracted project name');
        $task =~ s/^\s+|\s+$//g;
        like($task, qr/fix tests now/, 'Task cleaned after project extraction');
    } else {
        fail('--project not matched');
    }
};

subtest 'Option extraction: --project with quotes' => sub {
    my $task = 'refactor --project "my project" thoroughly';
    if ($task =~ s/\s*--project\s+"([^"]+)"\s*/ / || $task =~ s/\s*--project\s+(\S+)\s*/ /) {
        is($1, 'my project', 'Extracted quoted project name');
    } else {
        fail('--project with quotes not matched');
    }
};

subtest 'Option extraction: --persistent flag' => sub {
    my $task = 'monitor logs --persistent in the background';
    my $persistent = 0;
    if ($task =~ s/\s*--persistent\s*/ /) {
        $persistent = 1;
    }
    ok($persistent, '--persistent flag detected');
    $task =~ s/^\s+|\s+$//g;
    like($task, qr/monitor logs in the background/, 'Task cleaned');
};

# ============================================================================
# 3. Puppeteer project resolution (used by --project flag)
# ============================================================================

subtest 'Project resolution via Puppeteer' => sub {
    my $root = tempdir(CLEANUP => 1);
    
    # Create child project
    my $child = File::Spec->catdir($root, 'SAM');
    make_path(File::Spec->catdir($child, '.clio'));
    
    my $pup = CLIO::Protocols::Puppeteer->new(root => $root);
    
    my $project = $pup->get_project('SAM');
    ok($project, 'Found SAM project');
    like($project->{path}, qr/SAM/, 'Path contains project name');
    ok($project->{abs_path}, 'Has absolute path');
    
    my $missing = $pup->get_project('NONEXISTENT');
    ok(!$missing, 'Returns undef for unknown project');
};

subtest 'Project list for /subagent projects' => sub {
    my $root = tempdir(CLEANUP => 1);
    
    for my $name (qw(CLIO SAM ALICE)) {
        my $dir = File::Spec->catdir($root, $name);
        make_path(File::Spec->catdir($dir, '.clio'));
    }
    
    my $pup = CLIO::Protocols::Puppeteer->new(root => $root);
    my @projects = $pup->list_projects();
    
    is(scalar(@projects), 3, '3 projects listed');
    is_deeply(\@projects, [qw(ALICE CLIO SAM)], 'Projects sorted alphabetically');
};

subtest 'Project summary for prompt injection' => sub {
    my $root = tempdir(CLEANUP => 1);
    
    my $sam = File::Spec->catdir($root, 'SAM');
    make_path(File::Spec->catdir($sam, '.clio'));
    
    # Write LTM
    open my $fh, '>', File::Spec->catfile($sam, '.clio', 'ltm.json') or die;
    print $fh '{"discoveries":[{"fact":"SAM uses Python"}]}';
    close $fh;
    
    my $pup = CLIO::Protocols::Puppeteer->new(root => $root);
    my $summary = $pup->project_summary();
    
    ok(defined $summary, 'Summary generated');
    like($summary, qr/SAM/, 'Contains project name');
    like($summary, qr/LTM/, 'Mentions LTM capability');
    like($summary, qr/working_dir/, 'Contains delegation instructions');
};

done_testing();
