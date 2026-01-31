#!/usr/bin/env perl

=head1 NAME

benchmark.pl - Performance benchmarks for CLIO

=head1 SYNOPSIS

    perl tests/benchmark.pl
    perl tests/benchmark.pl --verbose
    perl tests/benchmark.pl --iterations 100

=head1 DESCRIPTION

Measures and reports performance metrics for CLIO:
- Module loading time (startup performance)
- Tool execution latency
- Session save/load performance
- Memory usage

=cut

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Time::HiRes qw(time);
use Getopt::Long;

my $verbose = 0;
my $iterations = 10;

GetOptions(
    'verbose|v' => \$verbose,
    'iterations|n=i' => \$iterations,
) or die "Usage: $0 [--verbose] [--iterations N]\n";

print "=" x 60 . "\n";
print "CLIO Performance Benchmarks\n";
print "=" x 60 . "\n\n";

my %results;

#-----------------------------------------------------------------------------
# Benchmark: Module Loading Time
#-----------------------------------------------------------------------------
print "Benchmark: Module Loading Time\n";
print "-" x 40 . "\n";

{
    my $start = time();
    
    # Core modules
    require CLIO::Core::Config;
    require CLIO::Core::Logger;
    require CLIO::Core::ToolExecutor;
    require CLIO::Core::WorkflowOrchestrator;
    require CLIO::Core::APIManager;
    
    # Tools
    require CLIO::Tools::Registry;
    require CLIO::Tools::FileOperations;
    require CLIO::Tools::VersionControl;
    require CLIO::Tools::TerminalOperations;
    require CLIO::Tools::MemoryOperations;
    require CLIO::Tools::WebOperations;
    require CLIO::Tools::TodoList;
    require CLIO::Tools::CodeIntelligence;
    require CLIO::Tools::UserCollaboration;
    
    # Session
    require CLIO::Session::Manager;
    require CLIO::Session::State;
    
    # Memory
    require CLIO::Memory::ShortTerm;
    require CLIO::Memory::LongTerm;
    require CLIO::Memory::YaRN;
    
    # UI (optional - heavy modules)
    require CLIO::UI::Chat;
    
    my $elapsed = time() - $start;
    $results{module_load} = $elapsed;
    
    printf "  All modules loaded in: %.3fs\n", $elapsed;
}

#-----------------------------------------------------------------------------
# Benchmark: Tool Execution
#-----------------------------------------------------------------------------
print "\nBenchmark: Tool Execution ($iterations iterations)\n";
print "-" x 40 . "\n";

{
    use File::Temp qw(tempdir);
    use JSON::PP qw(encode_json);
    
    my $test_dir = tempdir(CLEANUP => 1);
    chdir $test_dir;
    mkdir '.clio';
    mkdir '.clio/sessions';
    
    my $session = CLIO::Session::Manager->create(working_directory => $test_dir, debug => 0);
    my $registry = CLIO::Tools::Registry->new(debug => 0);
    $registry->register_tool(CLIO::Tools::FileOperations->new());
    
    my $executor = CLIO::Core::ToolExecutor->new(
        session => $session,
        tool_registry => $registry,
        debug => 0,
    );
    
    # Create file benchmark
    my @create_times;
    for my $i (1..$iterations) {
        my $tool_call = {
            function => {
                name => 'file_operations',
                arguments => encode_json({
                    operation => 'create_file',
                    path => "bench_$i.txt",
                    content => "Benchmark content $i\n" x 100,
                })
            }
        };
        
        my $start = time();
        $executor->execute_tool($tool_call, "call_create_$i");
        push @create_times, time() - $start;
    }
    
    my $create_avg = avg(@create_times);
    $results{tool_create_file} = $create_avg;
    printf "  create_file avg: %.3fms (min: %.3f, max: %.3f)\n", 
        $create_avg * 1000, min(@create_times) * 1000, max(@create_times) * 1000;
    
    # Read file benchmark
    my @read_times;
    for my $i (1..$iterations) {
        my $tool_call = {
            function => {
                name => 'file_operations',
                arguments => encode_json({
                    operation => 'read_file',
                    path => "bench_$i.txt",
                })
            }
        };
        
        my $start = time();
        $executor->execute_tool($tool_call, "call_read_$i");
        push @read_times, time() - $start;
    }
    
    my $read_avg = avg(@read_times);
    $results{tool_read_file} = $read_avg;
    printf "  read_file avg: %.3fms (min: %.3f, max: %.3f)\n",
        $read_avg * 1000, min(@read_times) * 1000, max(@read_times) * 1000;
    
    # List directory benchmark
    my @list_times;
    for my $i (1..$iterations) {
        my $tool_call = {
            function => {
                name => 'file_operations',
                arguments => encode_json({
                    operation => 'list_dir',
                    path => '.',
                })
            }
        };
        
        my $start = time();
        $executor->execute_tool($tool_call, "call_list_$i");
        push @list_times, time() - $start;
    }
    
    my $list_avg = avg(@list_times);
    $results{tool_list_dir} = $list_avg;
    printf "  list_dir avg: %.3fms (min: %.3f, max: %.3f)\n",
        $list_avg * 1000, min(@list_times) * 1000, max(@list_times) * 1000;
    
    chdir '/';
}

#-----------------------------------------------------------------------------
# Benchmark: Session Save/Load
#-----------------------------------------------------------------------------
print "\nBenchmark: Session Operations ($iterations iterations)\n";
print "-" x 40 . "\n";

{
    use File::Temp qw(tempdir);
    
    my $test_dir = tempdir(CLEANUP => 1);
    chdir $test_dir;
    mkdir '.clio';
    mkdir '.clio/sessions';
    
    # Create session with some history
    my $session = CLIO::Session::Manager->create(working_directory => $test_dir, debug => 0);
    my $state = $session->state();
    
    # Add sample messages
    for my $i (1..20) {
        $state->add_message('user', "Test message $i from user with some content " x 10);
        $state->add_message('assistant', "Test response $i from assistant with detailed content " x 20);
    }
    
    # Save benchmark
    my @save_times;
    for my $i (1..$iterations) {
        my $start = time();
        $state->save();
        push @save_times, time() - $start;
    }
    
    my $save_avg = avg(@save_times);
    $results{session_save} = $save_avg;
    printf "  session save avg: %.3fms (min: %.3f, max: %.3f)\n",
        $save_avg * 1000, min(@save_times) * 1000, max(@save_times) * 1000;
    
    # Load benchmark
    my $session_id = $session->{session_id};
    undef $session;  # Release lock
    
    my @load_times;
    for my $i (1..$iterations) {
        my $start = time();
        my $loaded = CLIO::Session::Manager->load($session_id, debug => 0);
        push @load_times, time() - $start;
        undef $loaded;  # Release lock
    }
    
    my $load_avg = avg(@load_times);
    $results{session_load} = $load_avg;
    printf "  session load avg: %.3fms (min: %.3f, max: %.3f)\n",
        $load_avg * 1000, min(@load_times) * 1000, max(@load_times) * 1000;
    
    chdir '/';
}

#-----------------------------------------------------------------------------
# Summary
#-----------------------------------------------------------------------------
print "\n" . "=" x 60 . "\n";
print "Summary\n";
print "=" x 60 . "\n";

printf "Module load time:     %.3fs\n", $results{module_load};
printf "Tool create_file:     %.3fms avg\n", $results{tool_create_file} * 1000;
printf "Tool read_file:       %.3fms avg\n", $results{tool_read_file} * 1000;
printf "Tool list_dir:        %.3fms avg\n", $results{tool_list_dir} * 1000;
printf "Session save:         %.3fms avg\n", $results{session_save} * 1000;
printf "Session load:         %.3fms avg\n", $results{session_load} * 1000;

# Performance targets
print "\nPerformance Targets:\n";
print "  Module load: < 2.0s (OK)\n" if $results{module_load} < 2.0;
print "  Module load: >= 2.0s (SLOW)\n" if $results{module_load} >= 2.0;
print "  Tool execution: < 50ms (OK)\n" if $results{tool_create_file} * 1000 < 50;
print "  Tool execution: >= 50ms (SLOW)\n" if $results{tool_create_file} * 1000 >= 50;
print "  Session save: < 100ms (OK)\n" if $results{session_save} * 1000 < 100;
print "  Session save: >= 100ms (SLOW)\n" if $results{session_save} * 1000 >= 100;

print "\nBenchmark complete.\n";

# Helper functions
sub avg { my @a = @_; return 0 unless @a; my $sum = 0; $sum += $_ for @a; return $sum / @a; }
sub min { my @a = @_; return 0 unless @a; my $min = $a[0]; $_ < $min && ($min = $_) for @a; return $min; }
sub max { my @a = @_; return 0 unless @a; my $max = $a[0]; $_ > $max && ($max = $_) for @a; return $max; }
