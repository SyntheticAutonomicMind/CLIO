#!/usr/bin/env perl

=head1 NAME

test_multiagent_project.pl - Comprehensive multi-agent project build test

=head1 DESCRIPTION

Spawns 3 autonomous agents to build a complete Perl project:
- Agent 1: Creates project structure (dirs, README, .gitignore)
- Agent 2: Implements Calculator.pm module
- Agent 3: Creates comprehensive test suite

Then validates:
- All files exist and have content
- Module syntax is valid
- Tests pass when run

This proves multi-agent coordination works for real projects.

=cut

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../../lib";
use File::Temp qw(tempdir);
use Time::HiRes qw(sleep);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

print "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
print "  Multi-Agent Project Build Test\n";
print "  Building a complete Perl project with 3 autonomous agents\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";

# Setup test project directory in scratch/ (accessible to agents)
my $project_name = "test-multiagent-project-$$";
my $project_dir = "scratch/$project_name";
system("mkdir -p $project_dir") == 0 or die "Cannot create $project_dir: $!";
print " Project directory: $project_dir\n";
print " (Directory will be cleaned up at end)\n\n";

# Define agent tasks - use simpler, more explicit instructions
my @agents = (
    {
        id => 'structure',
        model => 'gpt-5-mini',
        task => "In directory $project_dir: create subdirectory named 'lib', create subdirectory named 't', create file 'README.md' with text 'MathUtils - Basic math utilities', create file '.gitignore' with text 'blib/'",
    },
    {
        id => 'module',
        model => 'gpt-5-mini',
        task => "Create directory $project_dir/lib/MathUtils then create file $project_dir/lib/MathUtils/Calculator.pm with this exact content: package MathUtils::Calculator; use strict; use warnings; sub new { bless {}, shift } sub add { my (\$self, \$a, \$b) = \@_; \$a + \$b } sub multiply { my (\$self, \$a, \$b) = \@_; \$a * \$b } 1;",
    },
    {
        id => 'tests',
        model => 'gpt-5-mini',
        task => "Create file $project_dir/t/calculator.t with this content: use Test::More tests => 3; use lib '../lib'; use_ok('MathUtils::Calculator'); my \$calc = MathUtils::Calculator->new(); is(\$calc->add(2,3), 5, 'add'); is(\$calc->multiply(4,5), 20, 'multiply');",
    },
);

my %spawned_agents;

# Phase 1: Spawn all agents
print " [PHASE 1] Spawning agents...\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";

for my $agent (@agents) {
    print "\n   Agent: $agent->{id}\n";
    print "   Task: " . substr($agent->{task}, 0, 80) . "...\n";
    
    my $cmd = qq{$RealBin/../../clio --input '/subagent spawn "$agent->{task}" --model $agent->{model}' --exit 2>&1};
    my $output = `$cmd`;
    
    if ($output =~ /Spawned sub-agent: (agent-\d+)/m) {
        my $agent_id = $1;
        $spawned_agents{$agent->{id}} = $agent_id;
        print "   ✓ Spawned: $agent_id\n";
    } else {
        print "   ✗ FAILED to spawn agent\n";
        print "Output: $output\n";
        exit 1;
    }
}

# Phase 2: Wait for completion
print "\n [PHASE 2] Waiting for agents to complete (max 60s)...\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";

my $max_wait = 60;
my $wait_time = 0;
my %completed;

while ($wait_time < $max_wait && keys(%completed) < keys(%spawned_agents)) {
    sleep(2);
    $wait_time += 2;
    
    for my $role (keys %spawned_agents) {
        next if $completed{$role};
        
        my $agent_id = $spawned_agents{$role};
        my $log_file = "/tmp/clio-agent-$agent_id.log";
        
        if (-f $log_file) {
            my $log_size = -s $log_file;
            my $log_content = do {
                open(my $fh, '<', $log_file) or next;
                local $/;
                <$fh>;
            };
            
            # Check for completion or exit
            if ($log_content =~ /exit|created|completed/i || $log_size > 5000) {
                $completed{$role} = 1;
                print "   ✓ $role ($agent_id) completed after ${wait_time}s\n";
            }
        }
    }
    
    if ($wait_time % 10 == 0 && $wait_time > 0) {
        my $done = scalar(keys %completed);
        my $total = scalar(keys %spawned_agents);
        print "   ... ${wait_time}s elapsed ($done/$total agents done)\n";
    }
}

my $all_done = (keys(%completed) == keys(%spawned_agents));
if (!$all_done) {
    print "\n   ⚠ Not all agents completed within ${max_wait}s\n";
    print "   Completed: " . join(", ", keys %completed) . "\n";
}

# Phase 3: Validate results
print "\n [PHASE 3] Validating project files...\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";

my @validations = (
    {
        name => "Directory: lib/",
        test => sub { -d "$project_dir/lib" },
    },
    {
        name => "Directory: t/",
        test => sub { -d "$project_dir/t" },
    },
    {
        name => "File: README.md",
        test => sub { -f "$project_dir/README.md" && -s _ > 10 },
    },
    {
        name => "File: .gitignore",
        test => sub { -f "$project_dir/.gitignore" && -s _ > 5 },
    },
    {
        name => "File: lib/MathUtils/Calculator.pm",
        test => sub { -f "$project_dir/lib/MathUtils/Calculator.pm" && -s _ > 50 },
    },
    {
        name => "File: t/calculator.t",
        test => sub { -f "$project_dir/t/calculator.t" && -s _ > 50 },
    },
);

my $validation_pass = 1;
for my $val (@validations) {
    my $result = $val->{test}->();
    my $status = $result ? "✓" : "✗";
    print "   $status $val->{name}\n";
    $validation_pass = 0 unless $result;
}

# Phase 4: Syntax check module
print "\n [PHASE 4] Syntax validation...\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";

my $module_file = "$project_dir/lib/MathUtils/Calculator.pm";
if (-f $module_file) {
    my $syntax_check = `perl -I$project_dir/lib -c $module_file 2>&1`;
    if ($syntax_check =~ /syntax OK/) {
        print "   ✓ Module syntax valid\n";
    } else {
        print "   ✗ Module syntax FAILED\n";
        print "   Error: $syntax_check\n";
        $validation_pass = 0;
    }
} else {
    print "   ✗ Module file not found\n";
    $validation_pass = 0;
}

# Phase 5: Run tests
print "\n [PHASE 5] Running test suite...\n";
print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";

my $test_file = "$project_dir/t/calculator.t";
if (-f $test_file) {
    my $test_output = `cd $project_dir && perl -Ilib t/calculator.t 2>&1`;
    my $test_exit = $? >> 8;
    
    if ($test_exit == 0 && $test_output !~ /not ok/i) {
        print "   ✓ All tests passed\n";
        print "   Output: $test_output\n";
    } else {
        print "   ✗ Tests FAILED (exit: $test_exit)\n";
        print "   Output: $test_output\n";
        $validation_pass = 0;
    }
} else {
    print "   ✗ Test file not found\n";
    $validation_pass = 0;
}

# Final summary
print "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n";
if ($validation_pass && $all_done) {
    print "   ✓✓✓ ALL TESTS PASSED ✓✓✓\n";
    print "   Multi-agent project build SUCCESSFUL\n";
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";
    exit 0;
} else {
    print "   ✗✗✗ TESTS FAILED ✗✗✗\n";
    print "   Validation pass: " . ($validation_pass ? "YES" : "NO") . "\n";
    print "   All agents done: " . ($all_done ? "YES" : "NO") . "\n";
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n";
    exit 1;
}
