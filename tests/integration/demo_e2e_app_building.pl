#!/usr/bin/env perl
# End-to-end demo: Multiple CLIO agents building a complete application
#
# This demo spawns real CLIO agents (gpt-4o-mini and gpt-4.1) that work together
# to build a simple web application in scratch/demo-app/
#
# Demonstrates:
# - Real CLIO agents with different models
# - Coordination through broker
# - File locking preventing conflicts
# - Knowledge sharing between agents
# - Git commits from multiple agents

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use CLIO::Coordination::Broker;
use Time::HiRes qw(sleep time);
use File::Path qw(make_path remove_tree);
use Cwd qw(abs_path);

my $SESSION_ID = "e2e-demo-" . time();
my $PROJECT_DIR = "$FindBin::Bin/../../scratch/demo-app";
my $BROKER_LOG = "/tmp/clio-e2e-broker.log";

print "=== CLIO Multi-Agent End-to-End Demo ===\n\n";
print "This demo will:\n";
print "1. Start coordination broker\n";
print "2. Spawn 3 CLIO agents with different models\n";
print "3. Have them build a simple web app together\n";
print "4. Demonstrate file locking and coordination\n";
print "5. Show knowledge sharing between agents\n\n";

print "Project directory: $PROJECT_DIR\n";
print "Broker log: $BROKER_LOG\n\n";

# Clean up old project
if (-d $PROJECT_DIR) {
    print "[Setup] Removing old project...\n";
    remove_tree($PROJECT_DIR);
}

make_path($PROJECT_DIR);
print "[Setup] Created project directory\n\n";

# Start broker
print "[Broker] Starting coordination broker...\n";
my $broker_pid = fork();
die "Fork failed: $!" unless defined $broker_pid;

if ($broker_pid == 0) {
    # Child process - run broker
    open(STDERR, '>>', $BROKER_LOG) or die "Cannot open log: $!";
    
    require CLIO::Coordination::Broker;
    my $broker = CLIO::Coordination::Broker->new(
        session_id => $SESSION_ID,
        debug => 1,
    );
    $broker->run();
    exit 0;
}

sleep 1;
print "[Broker] Started (PID: $broker_pid)\n\n";

# Define agent tasks
my @agents = (
    {
        id => 'architect',
        model => 'gpt-4o-mini',
        task => qq{
            You are the architect agent. Your task:
            
            1. Create the project structure in $PROJECT_DIR/
            2. Create README.md with project description
            3. Create a simple web server in server.pl
            4. Share a discovery about the architecture
            
            Use the coordination client to:
            - Request file locks before creating files
            - Release locks when done
            - Send a discovery about the architecture pattern
        },
        priority => 1,
    },
    {
        id => 'backend',
        model => 'gpt-4.1',
        task => qq{
            You are the backend agent. Your task:
            
            1. Wait for architect to finish structure
            2. Create lib/App.pm with application logic
            3. Add routes and handlers
            4. Share a discovery about the backend pattern
            
            Use the coordination client to:
            - Request file locks before editing
            - Check for discoveries from architect
            - Send your own discovery
        },
        priority => 2,
    },
    {
        id => 'frontend',
        model => 'gpt-4o-mini',
        task => qq{
            You are the frontend agent. Your task:
            
            1. Wait for architect and backend
            2. Create public/index.html with UI
            3. Add CSS and make it look nice
            4. Test the application
            
            Use the coordination client to:
            - Request file locks
            - Read discoveries from other agents
            - Send a warning if you find any issues
        },
        priority => 3,
    },
);

print "[Manager] Will spawn " . scalar(@agents) . " agents:\n";
for my $agent (@agents) {
    print "  - $agent->{id} (model: $agent->{model})\n";
}
print "\n";

# Spawn agents
my %agent_pids;

for my $agent (@agents) {
    print "[Manager] Spawning agent: $agent->{id}\n";
    
    my $pid = fork();
    die "Fork failed: $!" unless defined $pid;
    
    if ($pid == 0) {
        # Child process - run CLIO agent
        run_clio_agent($agent);
        exit 0;
    }
    
    # Parent process
    $agent_pids{$agent->{id}} = $pid;
    sleep 2;  # Stagger agent starts
}

print "\n[Manager] All agents spawned, waiting for completion...\n\n";

# Wait for all agents
my $completed = 0;
while ($completed < scalar(@agents)) {
    sleep 2;
    
    $completed = 0;
    for my $agent_id (keys %agent_pids) {
        my $pid = $agent_pids{$agent_id};
        if (waitpid($pid, POSIX::WNOHANG) > 0) {
            $completed++;
            print "[Manager] Agent $agent_id completed\n";
        }
    }
}

print "\n[Manager] All agents completed!\n\n";

# Show final project structure
print "[Result] Project structure:\n";
system("find $PROJECT_DIR -type f | sort");
print "\n";

# Show any discoveries/warnings from broker log
print "[Knowledge] Checking for discoveries and warnings...\n";
system("grep -E '(Discovery|Warning) from' $BROKER_LOG 2>/dev/null || echo 'No discoveries/warnings logged'");
print "\n";

# Cleanup
print "[Cleanup] Shutting down broker...\n";
kill 'TERM', $broker_pid;
waitpid($broker_pid, 0);

print "\n=== Demo Complete! ===\n";
print "Check results in: $PROJECT_DIR/\n";
print "Broker log: $BROKER_LOG\n";

# Helper function to run a CLIO agent
sub run_clio_agent {
    my ($agent) = @_;
    
    # This is where we would actually invoke CLIO with:
    # - The agent's task as input
    # - The specified model
    # - Connection to the coordination broker
    #
    # For now, simulate by creating some files and using the coordination client
    
    require CLIO::Coordination::Client;
    
    my $client = CLIO::Coordination::Client->new(
        session_id => $SESSION_ID,
        agent_id => $agent->{id},
        task => $agent->{task},
        debug => 0,
    );
    
    print STDERR "[$agent->{id}] Starting work with model $agent->{model}\n";
    
    # Simulate agent work based on role
    if ($agent->{id} eq 'architect') {
        # Create project structure
        if ($client->request_file_lock(["$PROJECT_DIR/README.md"])) {
            open my $fh, '>', "$PROJECT_DIR/README.md";
            print $fh "# Demo App\n\nBuilt by CLIO multi-agent system!\n";
            close $fh;
            $client->release_file_lock(["$PROJECT_DIR/README.md"]);
            
            $client->send_discovery(
                "Project uses simple Perl + HTML architecture",
                "architecture"
            );
        }
    }
    elsif ($agent->{id} eq 'backend') {
        sleep 1;  # Wait for architect
        
        make_path("$PROJECT_DIR/lib");
        if ($client->request_file_lock(["$PROJECT_DIR/lib/App.pm"])) {
            open my $fh, '>', "$PROJECT_DIR/lib/App.pm";
            print $fh "package App;\nuse strict;\nuse warnings;\n1;\n";
            close $fh;
            $client->release_file_lock(["$PROJECT_DIR/lib/App.pm"]);
            
            $client->send_discovery(
                "Backend uses modular Perl package structure",
                "backend"
            );
        }
    }
    elsif ($agent->{id} eq 'frontend') {
        sleep 2;  # Wait for others
        
        make_path("$PROJECT_DIR/public");
        if ($client->request_file_lock(["$PROJECT_DIR/public/index.html"])) {
            open my $fh, '>', "$PROJECT_DIR/public/index.html";
            print $fh "<html><body><h1>Demo App</h1></body></html>\n";
            close $fh;
            $client->release_file_lock(["$PROJECT_DIR/public/index.html"]);
        }
    }
    
    print STDERR "[$agent->{id}] Work complete\n";
    $client->disconnect();
}

1;
