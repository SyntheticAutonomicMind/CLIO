package CLIO::Protocols::RemoteDistribution;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use Carp qw(croak);
use feature 'say';

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::Protocols::RemoteDistribution - Multi-stage distributed agent workflows

=head1 DESCRIPTION

Orchestrates complex multi-stage workflows across multiple remote systems.

This protocol enables:
- Sequential or parallel execution of stages
- File transfer and dependency management
- Result aggregation across devices
- Error handling and retry logic
- Progress tracking and reporting

Uses the RemoteExecution tool as its execution primitive.

=head1 SYNOPSIS

    use CLIO::Protocols::RemoteDistribution;
    use CLIO::Core::WorkflowOrchestrator;
    
    my $protocol = CLIO::Protocols::RemoteDistribution->new();
    
    my $workflow = {
        name => 'PowerDeck Build Pipeline',
        stages => [
            {
                name => 'Analyze',
                task => 'Analyze hardware for this device',
                target => 'all',
                devices => ['server1', 'server2', 'server3'],
                command => 'Analyze device hardware',
                model => 'gpt-4o-mini',
            },
            # ... more stages
        ],
    };
    
    my $result = $protocol->execute_workflow($workflow, $context);

=cut

sub new {
    my ($class, %opts) = @_;
    
    return bless {
        debug => $opts{debug} || 0,
        max_parallel => $opts{max_parallel} || 1,  # Number of devices to process in parallel
        default_timeout => $opts{default_timeout} || 300,
        default_retry_count => $opts{default_retry_count} || 2,
    }, $class;
}

=head2 execute_workflow

Execute a multi-stage workflow across remote systems.

Arguments:
- $workflow: Workflow definition hashref
- $context: Execution context (session, config, etc.)

Returns: Workflow result with stage results and aggregated output

=cut

sub execute_workflow {
    my ($self, $workflow, $context) = @_;
    
    print STDERR "[DEBUG][RemoteDistribution] Starting workflow: $workflow->{name}\n" if $self->{debug};
    
    # Validate workflow
    my $validation = $self->_validate_workflow($workflow);
    unless ($validation->{success}) {
        return {
            success => 0,
            error => $validation->{error},
            workflow_name => $workflow->{name},
        };
    }
    
    # Parse workflow structure
    my $stages = $workflow->{stages} || [];
    my @stage_results;
    
    my $result = eval {
        # Process each stage
        for my $i (0 .. $#$stages) {
            my $stage = $stages->[$i];
            
            print STDERR "[DEBUG][RemoteDistribution] Executing stage $i: $stage->{name}\n" if $self->{debug};
            
            my $stage_result = $self->_execute_stage(
                stage => $stage,
                stage_index => $i,
                workflow => $workflow,
                context => $context,
                previous_results => \@stage_results,
            );
            
            unless ($stage_result->{success}) {
                # Handle stage failure
                my $error_handling = $workflow->{error_handling} || {};
                my $fail_fast = $error_handling->{fail_fast};
                
                if ($fail_fast) {
                    die "Stage $i failed: $stage_result->{error}";
                } else {
                    print STDERR "[WARN][RemoteDistribution] Stage $i failed: $stage_result->{error}\n";
                }
            }
            
            push @stage_results, $stage_result;
        }
        
        # Aggregate results
        my $aggregated = $self->_aggregate_results(
            stages => $stages,
            stage_results => \@stage_results,
            workflow => $workflow,
        );
        
        return {
            success => 1,
            workflow_name => $workflow->{name},
            stages_completed => scalar(@stage_results),
            stage_results => \@stage_results,
            aggregated_output => $aggregated,
        };
    };
    
    if ($@) {
        return {
            success => 0,
            error => $@,
            workflow_name => $workflow->{name},
            stages_completed => scalar(@stage_results),
        };
    }
    
    return $result;
}

=head2 _execute_stage

Execute a single workflow stage across target devices.

=cut

sub _execute_stage {
    my ($self, %args) = @_;
    
    my $stage = $args{stage};
    my $stage_index = $args{stage_index};
    my $workflow = $args{workflow};
    my $context = $args{context};
    my $previous_results = $args{previous_results};
    
    my $stage_name = $stage->{name};
    my $command = $stage->{command};
    my $target = $stage->{target} || 'all';
    my $devices = $stage->{devices} || [];
    my $model = $stage->{model} || 'gpt-4.1';
    my $parallel = $stage->{parallel} // $self->{max_parallel};
    my $retry_count = $stage->{retry_count} // $self->{default_retry_count};
    
    # Determine target devices
    my @target_devices = $self->_resolve_target_devices($target, $devices, $context);
    
    print STDERR "[DEBUG][RemoteDistribution] Stage '$stage_name' targets: " . join(', ', @target_devices) . "\n" if $self->{debug};
    
    unless (@target_devices) {
        return {
            success => 0,
            error => "No target devices resolved for stage '$stage_name'",
            stage_name => $stage_name,
            stage_index => $stage_index,
        };
    }
    
    # Execute on devices (parallel or sequential)
    my @device_results;
    
    if ($parallel > 1 && scalar(@target_devices) > 1) {
        # Parallel execution
        @device_results = $self->_execute_parallel(
            devices => \@target_devices,
            stage => $stage,
            command => $command,
            model => $model,
            context => $context,
            max_parallel => $parallel,
            retry_count => $retry_count,
        );
    } else {
        # Sequential execution with retry logic
        for my $device (@target_devices) {
            my $device_result = $self->_execute_on_device_with_retry(
                stage => $stage,
                device => $device,
                command => $command,
                model => $model,
                context => $context,
                retry_count => $retry_count,
            );
            
            push @device_results, {
                device => $device,
                success => $device_result->{success},
                output => $device_result->{output},
                error => $device_result->{error},
                attempts => $device_result->{attempts},
                execution_time => $device_result->{execution_time},
            };
        }
    }
    
    my $succeeded = scalar(grep { $_->{success} } @device_results);
    my $failed = scalar(grep { !$_->{success} } @device_results);
    
    return {
        success => $succeeded > 0,  # Success if at least one device succeeded
        stage_name => $stage_name,
        stage_index => $stage_index,
        device_results => \@device_results,
        devices_succeeded => $succeeded,
        devices_failed => $failed,
        total_devices => scalar(@device_results),
    };
}

=head2 _execute_on_device_with_retry

Execute a stage command on a specific device with retry logic.

=cut

sub _execute_on_device_with_retry {
    my ($self, %args) = @_;
    
    my $stage = $args{stage};
    my $device = $args{device};
    my $command = $args{command};
    my $model = $args{model};
    my $context = $args{context};
    my $retry_count = $args{retry_count} || 0;
    
    my $attempts = 0;
    my $start_time = time();
    my $last_error;
    
    for my $attempt (1 .. ($retry_count + 1)) {
        $attempts = $attempt;
        
        print STDERR "[DEBUG][RemoteDistribution] Executing stage on device '$device' (attempt $attempt)\n" if $self->{debug};
        
        my $result = $self->_execute_on_device(
            stage => $stage,
            device => $device,
            command => $command,
            model => $model,
            context => $context,
        );
        
        if ($result->{success}) {
            my $execution_time = time() - $start_time;
            return {
                success => 1,
                output => $result->{output},
                attempts => $attempts,
                execution_time => $execution_time,
            };
        }
        
        $last_error = $result->{error};
        
        if ($attempt < ($retry_count + 1)) {
            print STDERR "[WARN][RemoteDistribution] Device '$device' attempt $attempt failed: $last_error (retrying...)\n";
            sleep(2 * $attempt);  # Exponential backoff
        }
    }
    
    my $execution_time = time() - $start_time;
    
    return {
        success => 0,
        error => $last_error,
        attempts => $attempts,
        execution_time => $execution_time,
    };
}

=head2 _execute_parallel

Execute stage on multiple devices in parallel using forking.

=cut

sub _execute_parallel {
    my ($self, %args) = @_;
    
    my $devices = $args{devices};
    my $stage = $args{stage};
    my $command = $args{command};
    my $model = $args{model};
    my $context = $args{context};
    my $max_parallel = $args{max_parallel} || 1;
    my $retry_count = $args{retry_count} || 0;
    
    my @device_results;
    my %child_pids;
    my $active_children = 0;
    
    require File::Temp;
    my $result_dir = File::Temp::tempdir(CLEANUP => 1);
    
    print STDERR "[DEBUG][RemoteDistribution] Parallel execution: " . scalar(@$devices) . " devices, max $max_parallel at a time\n" if $self->{debug};
    
    for my $i (0 .. $#$devices) {
        my $device = $devices->[$i];
        
        # Wait if we're at max parallelism
        while ($active_children >= $max_parallel) {
            my $pid = wait();
            if ($pid > 0 && exists $child_pids{$pid}) {
                delete $child_pids{$pid};
                $active_children--;
            }
        }
        
        # Fork for parallel execution
        my $pid = fork();
        
        if (!defined $pid) {
            warn "[ERROR][RemoteDistribution] Fork failed for device '$device': $!\n";
            push @device_results, {
                device => $device,
                success => 0,
                error => "Fork failed: $!",
                attempts => 0,
            };
            next;
        }
        
        if ($pid == 0) {
            # Child process - CRITICAL: Reset terminal state while connected to parent TTY
            # Use light reset - no ANSI codes needed since we're about to redirect output
            eval {
                require CLIO::Compat::Terminal;
                CLIO::Compat::Terminal::reset_terminal_light();  # ReadMode(0) only
            };
            
            # Detach from terminal
            close(STDIN);
            open(STDIN, '<', '/dev/null');
            
            my $result = $self->_execute_on_device_with_retry(
                stage => $stage,
                device => $device,
                command => $command,
                model => $model,
                context => $context,
                retry_count => $retry_count,
            );
            
            # Write result to temp file
            require JSON::PP;
            my $result_file = "$result_dir/device_${i}.json";
            open my $fh, '>:encoding(UTF-8)', $result_file or croak "Cannot write $result_file: $!";
            print $fh JSON::PP->new->utf8->pretty->encode({
                device => $device,
                %$result,
            });
            close $fh;
            
            exit(0);
        }
        
        # Parent process
        $child_pids{$pid} = $device;
        $active_children++;
    }
    
    # Wait for all remaining children
    while ($active_children > 0) {
        my $pid = wait();
        if ($pid > 0 && exists $child_pids{$pid}) {
            delete $child_pids{$pid};
            $active_children--;
        }
    }
    
    # Collect results from temp files
    require JSON::PP;
    for my $i (0 .. $#$devices) {
        my $result_file = "$result_dir/device_${i}.json";
        
        if (-f $result_file) {
            open my $fh, '<:encoding(UTF-8)', $result_file or warn "Cannot read $result_file: $!";
            my $content = do { local $/; <$fh> };
            close $fh;
            
            my $result = JSON::PP->new->utf8->decode($content);
            push @device_results, $result;
        } else {
            push @device_results, {
                device => $devices->[$i],
                success => 0,
                error => "Result file not found (process may have crashed)",
                attempts => 0,
            };
        }
    }
    
    return @device_results;
}

=head2 _execute_on_device

Execute a stage command on a specific device via RemoteExecution tool.

=cut

sub _execute_on_device {
    my ($self, %args) = @_;
    
    my $stage = $args{stage};
    my $device = $args{device};
    my $command = $args{command};
    my $model = $args{model};
    my $context = $args{context};
    
    # Get remote execution tool from context
    my $tool_executor = $context->{tool_executor};
    unless ($tool_executor) {
        return {
            success => 0,
            error => "No tool executor in context",
        };
    }
    
    my $tool_registry = $context->{tool_registry};
    my $remote_exec_tool = $tool_registry->get_tool('remote_execution');
    unless ($remote_exec_tool) {
        return {
            success => 0,
            error => "remote_execution tool not available",
        };
    }
    
    # Get API key from config
    my $config = $context->{config};
    my $api_key = $config ? $config->get('api_key') : undef;
    
    # If no API key in config, try GitHubAuth
    unless ($api_key) {
        eval {
            require CLIO::Core::GitHubAuth;
            my $auth = CLIO::Core::GitHubAuth->new();
            $api_key = $auth->get_copilot_token();
        };
        if ($@) {
            print STDERR "[WARN][RemoteDistribution] GitHubAuth failed: $@\n" if $self->{debug};
        }
    }
    
    unless ($api_key) {
        return {
            success => 0,
            error => "No API key configured and GitHubAuth unavailable",
        };
    }
    
    # Resolve device to SSH host via DeviceRegistry or use as-is
    my $ssh_host = $device;
    my $ssh_port;
    my $ssh_key;
    
    eval {
        require CLIO::Core::DeviceRegistry;
        my $registry = CLIO::Core::DeviceRegistry->new();
        my $device_info = $registry->get_device($device);
        
        if ($device_info) {
            $ssh_host = $device_info->{host};
            $ssh_port = $device_info->{ssh_port};
            $ssh_key = $device_info->{ssh_key};
        }
    };
    
    # If device looks like a plain name (no @), assume it needs a default user
    # This is a fallback for cases where DeviceRegistry isn't set up
    unless ($ssh_host =~ /@/) {
        $ssh_host = "deck\@$ssh_host";  # PowerDeck convention
    }
    
    # Execute via remote_execution tool
    my $result = $remote_exec_tool->execute(
        {
            operation => 'execute_remote',
            host => $ssh_host,
            command => $command,
            model => $model,
            api_key => $api_key,
            timeout => $stage->{timeout} || $self->{default_timeout},
            cleanup => $stage->{cleanup} // 1,
            ($ssh_port ? (ssh_port => $ssh_port) : ()),
            ($ssh_key ? (ssh_key => $ssh_key) : ()),
        },
        $context
    );
    
    return {
        success => $result->{success},
        output => $result->{output},
        error => $result->{error},
    };
}

=head2 _aggregate_results

Aggregate results from all stages and devices.

=cut

sub _aggregate_results {
    my ($self, %args) = @_;
    
    my $stages = $args{stages};
    my $stage_results = $args{stage_results};
    my $workflow = $args{workflow};
    
    my $aggregation_config = $workflow->{aggregation} || {};
    my $merge_outputs = $aggregation_config->{merge_outputs} // 1;
    my $create_summary = $aggregation_config->{create_summary} // 1;
    my $report_format = $aggregation_config->{report_format} || 'markdown';
    
    # Collect all device outputs across all stages
    my @all_outputs;
    my %device_stage_map;  # device => { stage_name => output }
    my $total_devices = 0;
    my $total_succeeded = 0;
    my $total_failed = 0;
    
    for my $stage_result (@$stage_results) {
        my $stage_name = $stage_result->{stage_name};
        my $device_results = $stage_result->{device_results} || [];
        
        for my $device_result (@$device_results) {
            my $device = $device_result->{device};
            
            $device_stage_map{$device} ||= {};
            $device_stage_map{$device}{$stage_name} = {
                success => $device_result->{success},
                output => $device_result->{output},
                error => $device_result->{error},
                attempts => $device_result->{attempts} || 1,
                execution_time => $device_result->{execution_time} || 0,
            };
            
            $total_devices++;
            $total_succeeded++ if $device_result->{success};
            $total_failed++ if !$device_result->{success};
            
            if ($device_result->{output}) {
                push @all_outputs, {
                    device => $device,
                    stage => $stage_name,
                    output => $device_result->{output},
                    success => $device_result->{success},
                };
            }
        }
    }
    
    # Build summary report
    my $summary = '';
    
    if ($create_summary && $report_format eq 'markdown') {
        $summary = $self->_build_markdown_summary(
            workflow => $workflow,
            stages => $stages,
            stage_results => $stage_results,
            device_stage_map => \%device_stage_map,
            total_devices => $total_devices,
            total_succeeded => $total_succeeded,
            total_failed => $total_failed,
        );
    }
    
    # Merge outputs if requested
    my $merged_output = '';
    if ($merge_outputs) {
        for my $output_entry (@all_outputs) {
            $merged_output .= "## Device: $output_entry->{device} (Stage: $output_entry->{stage})\n\n";
            $merged_output .= $output_entry->{output} . "\n\n";
        }
    }
    
    return {
        summary => $summary,
        merged_output => $merged_output,
        device_stage_map => \%device_stage_map,
        statistics => {
            total_stages => scalar(@$stages),
            total_device_executions => $total_devices,
            succeeded => $total_succeeded,
            failed => $total_failed,
            success_rate => $total_devices > 0 ? sprintf("%.1f%%", 100 * $total_succeeded / $total_devices) : '0%',
        },
    };
}

=head2 _build_markdown_summary

Build a Markdown summary report of workflow execution.

=cut

sub _build_markdown_summary {
    my ($self, %args) = @_;
    
    my $workflow = $args{workflow};
    my $stages = $args{stages};
    my $stage_results = $args{stage_results};
    my $device_stage_map = $args{device_stage_map};
    my $total_devices = $args{total_devices};
    my $total_succeeded = $args{total_succeeded};
    my $total_failed = $args{total_failed};
    
    my $summary = "# Workflow: $workflow->{name}\n\n";
    
    # Overall statistics
    $summary .= "## Overall Statistics\n\n";
    $summary .= "- **Total Stages:** " . scalar(@$stages) . "\n";
    $summary .= "- **Total Device Executions:** $total_devices\n";
    $summary .= "- **Succeeded:** $total_succeeded\n";
    $summary .= "- **Failed:** $total_failed\n";
    
    if ($total_devices > 0) {
        my $success_rate = sprintf("%.1f%%", 100 * $total_succeeded / $total_devices);
        $summary .= "- **Success Rate:** $success_rate\n";
    }
    
    $summary .= "\n";
    
    # Stage-by-stage breakdown
    $summary .= "## Stage Results\n\n";
    
    for my $stage_result (@$stage_results) {
        my $stage_name = $stage_result->{stage_name};
        my $succeeded = $stage_result->{devices_succeeded} || 0;
        my $failed = $stage_result->{devices_failed} || 0;
        my $total = $stage_result->{total_devices} || 0;
        
        my $status_icon = $succeeded > 0 ? '✓' : '✗';
        $summary .= "### $status_icon Stage: $stage_name\n\n";
        $summary .= "- Devices: $total ($succeeded succeeded, $failed failed)\n";
        
        # Device details
        my $device_results = $stage_result->{device_results} || [];
        if (@$device_results) {
            $summary .= "\n**Device Details:**\n\n";
            for my $device_result (@$device_results) {
                my $device = $device_result->{device};
                my $success = $device_result->{success} ? '✓' : '✗';
                my $attempts = $device_result->{attempts} || 1;
                my $exec_time = $device_result->{execution_time} || 0;
                
                $summary .= "- $success **$device**";
                $summary .= " (${attempts} attempt" . ($attempts > 1 ? 's' : '') . ", " . sprintf("%.1fs", $exec_time) . ")";
                
                if (!$device_result->{success} && $device_result->{error}) {
                    $summary .= "\n  - Error: `$device_result->{error}`";
                }
                
                $summary .= "\n";
            }
        }
        
        $summary .= "\n";
    }
    
    # Device-by-device view
    $summary .= "## Device Summary\n\n";
    
    my @devices = sort keys %$device_stage_map;
    
    for my $device (@devices) {
        my $stages_for_device = $device_stage_map->{$device};
        my $device_success_count = grep { $_->{success} } values %$stages_for_device;
        my $device_total_stages = scalar(keys %$stages_for_device);
        
        my $device_status = $device_success_count == $device_total_stages ? '✓' : 
                           $device_success_count > 0 ? '⚠' : '✗';
        
        $summary .= "### $device_status Device: $device\n\n";
        
        for my $stage_name (sort keys %$stages_for_device) {
            my $stage_data = $stages_for_device->{$stage_name};
            my $stage_status = $stage_data->{success} ? '✓' : '✗';
            
            $summary .= "- $stage_status $stage_name";
            
            if (!$stage_data->{success} && $stage_data->{error}) {
                $summary .= " - Error: `$stage_data->{error}`";
            }
            
            $summary .= "\n";
        }
        
        $summary .= "\n";
    }
    
    return $summary;
}

# ============================================================================
# PRIVATE HELPER METHODS
# ============================================================================

sub _validate_workflow {
    my ($self, $workflow) = @_;
    
    unless ($workflow->{name}) {
        return {
            success => 0,
            error => "Workflow missing 'name' field",
        };
    }
    
    unless ($workflow->{stages} && ref($workflow->{stages}) eq 'ARRAY') {
        return {
            success => 0,
            error => "Workflow missing or invalid 'stages' field",
        };
    }
    
    unless (scalar(@{$workflow->{stages}}) > 0) {
        return {
            success => 0,
            error => "Workflow has no stages",
        };
    }
    
    # Validate each stage
    for my $stage (@{$workflow->{stages}}) {
        unless ($stage->{name}) {
            return {
                success => 0,
                error => "Stage missing 'name' field",
            };
        }
        
        unless ($stage->{command}) {
            return {
                success => 0,
                error => "Stage '$stage->{name}' missing 'command' field",
            };
        }
    }
    
    return { success => 1 };
}

sub _resolve_target_devices {
    my ($self, $target, $devices, $context) = @_;
    
    my @resolved_devices;
    
    # Try to use DeviceRegistry if available
    my $registry;
    eval {
        require CLIO::Core::DeviceRegistry;
        $registry = CLIO::Core::DeviceRegistry->new();
    };
    
    if ($target eq 'all') {
        # Get all registered devices
        if ($registry) {
            my @all_devices = $registry->list_devices();
            @resolved_devices = map { $_->{name} } @all_devices;
        }
        
        # Fallback to explicit device list if no registry
        @resolved_devices = @$devices unless @resolved_devices;
    } elsif ($target eq 'per-device' || ref($target) eq 'ARRAY') {
        # Explicit device list
        my @device_list = ref($target) eq 'ARRAY' ? @$target : @$devices;
        @resolved_devices = @device_list;
    } elsif ($registry) {
        # Check if target is a group name
        my @group_devices = $registry->resolve_group($target);
        
        if (@group_devices) {
            @resolved_devices = @group_devices;
        } else {
            # Assume it's a single device name
            @resolved_devices = ($target);
        }
    } else {
        # No registry, treat as device name
        @resolved_devices = ($target);
    }
    
    print STDERR "[DEBUG][RemoteDistribution] Resolved target '$target' to: " . join(', ', @resolved_devices) . "\n" if $self->{debug};
    
    return @resolved_devices;
}

1;

__END__

=head1 PROTOCOL OVERVIEW

The RemoteDistribution protocol implements a staged execution model:

**Stage Model:**
Each stage defines work to be done on one or more remote devices.

**Device Resolution:**
The protocol resolves device names to SSH connection targets.
For example: 'laptop' -> 'user@laptop', 'server1' -> 'admin@server1', etc.

**Parallel Execution:**
Multiple stages or devices can be processed in parallel (configurable).

**Error Handling:**
Errors can be handled with fail-fast or continue strategies.

**Result Aggregation:**
Results from multiple devices are merged and aggregated into a final report.

=head1 WORKFLOW DEFINITION FORMAT

    {
        name => 'Workflow Name',
        stages => [
            {
                name => 'Stage Name',
                command => 'Task description for CLIO',
                model => 'gpt-4.1',      # Optional: override model
                target => 'all',          # all | per-device
                devices => [...],         # Specific devices
                timeout => 300,           # Optional: stage timeout
                files_to_transfer => [...], # Optional: files to copy
                expected_outputs => [...],  # Optional: files to retrieve
                cleanup => 1,            # Optional: auto-cleanup
            },
            # ... more stages
        ],
        error_handling => {
            fail_fast => 0,              # Stop on first error?
            max_retries => 2,            # Retry failed stages
            notification => 'summary',   # notify_user | summary | silent
        },
        aggregation => {
            merge_outputs => 1,          # Merge output files
            create_summary => 1,         # Generate summary report
            report_format => 'markdown', # Output format
        },
    }

=head1 FUTURE ENHANCEMENTS

1. **Parallel Stage Execution** - Run multiple stages concurrently
2. **Device-Specific Configuration** - Different commands per device type
3. **Conditional Logic** - Skip stages based on previous results
4. **File Staging** - Transfer files between stages on remote
5. **Progress Streaming** - Real-time progress updates to user
6. **Automatic Retry** - Retry failed device/stage combinations
7. **Caching** - Cache CLIO binary between executions
8. **Multi-Provider Support** - Use different AI providers per stage

=head1 SEE ALSO

- CLIO::Tools::RemoteExecution - Execution primitive
- ai-assisted/REMOTE_EXECUTION_DESIGN.md - Architecture documentation

=cut

1;
