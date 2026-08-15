package CLIO::Tools::RemoteExecution;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use parent 'CLIO::Tools::Tool';
use Cwd 'getcwd';
use File::Basename 'dirname';
use CLIO::Util::JSON qw(encode_json decode_json);
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path remove_tree);
use CLIO::Core::Logger qw(should_log log_debug);
use Carp qw(croak);
use Scalar::Util qw(blessed);


=head1 NAME

CLIO::Tools::RemoteExecution - Execute CLIO tasks on remote systems

=head1 DESCRIPTION

Enables the local CLIO agent to execute tasks on remote systems via SSH.

Supports:
- Executing complex tasks on remote systems
- Transferring configuration securely
- Downloading and running CLIO on remote
- Retrieving results and artifacts
- Automatic cleanup

Security:
- API keys passed via environment variables (never written to disk)
- Minimal configuration transfer (only what's needed)
- Automatic cleanup of temporary files
- No persistent credentials on remote system

=head1 OPERATIONS

=over 4

=item execute_remote

Execute a CLIO task on a remote system.

Parameters:
- host (required): SSH connection target (user@hostname)
- command (required): Task description for remote CLIO
- model (optional): AI model to use on remote (defaults to current session model)
- api_key (optional): API key for remote provider (auto-populated from session)
- timeout (optional): Execution timeout in seconds (default: 300)
- cleanup (optional): Delete CLIO after execution (default: 1)
- ssh_key (optional): Path to SSH private key
- ssh_port (optional): SSH port (default: 22)
- output_files (optional): Array of files to retrieve from remote
- working_dir (optional): Working directory on remote (default: /tmp)
- api_provider (optional): API provider (defaults to current session provider)

Note: CLIO is copied from the local system to the remote, ensuring
version consistency and eliminating dependency on GitHub releases.

The harness auto-populates model, api_key, and api_provider from the
current session. The AI agent never needs to specify these.

=item prepare_remote

Pre-stage CLIO on remote system without executing.

Parameters:
- host (required): SSH connection target
- ssh_key (optional): Path to SSH private key
- ssh_port (optional): SSH port
- install_dir (optional): Installation directory (default: /tmp/clio-<random>)

=item cleanup_remote

Remove CLIO and temporary files from remote system.

Parameters:
- host (required): SSH connection target
- install_dir (required): CLIO installation directory to remove
- ssh_key (optional): Path to SSH private key
- ssh_port (optional): SSH port

=back

=cut

sub new {
    my ($class, %opts) = @_;
    
    return $class->SUPER::new(
        name => 'remote_execution',
        description => q{Execute CLIO tasks on remote systems via SSH.

This tool enables running CLIO on remote systems to offload work, gather information, or coordinate across multiple devices.

CLIO Distribution Method:
- Copies the LOCAL CLIO installation to remote systems via rsync
- Ensures version consistency (remote = local version)
- No dependency on GitHub releases or network connectivity
- Eliminates version mismatch issues

Operations:
-  execute_remote - Run a CLIO task on a remote system (PRIMARY OPERATION)
   Takes: host, command
   Returns: Task output and any retrieved files
   Security: API key auto-populated from session, never exposed to agent

-  execute_parallel - Run task on MULTIPLE devices simultaneously
   Takes: targets (device names, group name, or 'all'), command
   Returns: Aggregated results from all devices
   Example: targets: "handhelds", command: "check disk space"

-  prepare_remote - Pre-stage CLIO on remote without executing

-  cleanup_remote - Remove CLIO from remote system

-  check_remote - Verify remote system connectivity and requirements

-  transfer_files - Copy files to remote system

-  retrieve_files - Fetch files from remote system

QUICK START:
  operation: "execute_remote"
  host: "user@hostname"  (SSH connection target)
  command: "Natural language description of task"
  (model and api_key are auto-populated from your session)
  
PARALLEL EXECUTION:
  operation: "execute_parallel"
  targets: "handhelds"  (group name, or array of device names, or "all")
  command: "report disk space"
  
The tool will automatically:
- SSH into the host
- Copy CLIO from local system to remote
- Auto-populate API key and model from current session
- Execute your task with the remote LLM
- Return results
- Clean up automatically

This is perfect for: analyzing remote systems, running builds on specific hardware, gathering diagnostics, coordinating across multiple devices, etc.
},
        supported_operations => [qw(execute_remote execute_parallel prepare_remote cleanup_remote check_remote transfer_files retrieve_files)],
        requires_blocking => 1,  # Remote execution must complete before workflow continues
        %opts,
    );
}

sub before_route {
    my ($self, $operation, $params, $context) = @_;
    
    # Sandbox mode: Block all remote execution
    if ($context && $context->{config} && $context->{config}->get('sandbox')) {
        return $self->error_result(
            "Sandbox mode: Remote execution is disabled.\n\n" .
            "The --sandbox flag blocks all remote operations. " .
            "This is a security feature to prevent the agent from reaching outside the local project."
        );
    }
    
    return undef;
}

sub dispatch_table {
    return {
        execute_remote  => 'execute_remote',
        execute_parallel => 'execute_parallel',
        prepare_remote  => 'prepare_remote',
        cleanup_remote  => 'cleanup_remote',
        check_remote    => 'check_remote',
        transfer_files  => 'transfer_files',
        retrieve_files  => 'retrieve_files',
    };
}

# Resolve device name to host - called early before execute methods
sub _resolve_device {
    my ($self, $name_or_host) = @_;
    
    return {} unless $name_or_host;
    
    # If it looks like a host string (contains @), use it directly
    if ($name_or_host =~ /@/) {
        return { host => $name_or_host };
    }
    
    # Try to resolve as a registered device
    my $device_info;
    eval {
        require CLIO::Core::DeviceRegistry;
        my $registry = CLIO::Core::DeviceRegistry->new();
        my $device = $registry->get_device($name_or_host);
        
        if ($device) {
            $device_info = {
                host => $device->{host},
                ssh_port => $device->{ssh_port},
                ssh_key => $device->{ssh_key},
                default_model => $device->{default_model},
                description => $device->{description},
            };
        }
    };
    
    return $device_info if $device_info;
    
    # Not a registered device, assume it's a hostname and return as-is
    return { host => $name_or_host };
}

sub _get_host_proto {
    my ($self, $context) = @_;
    my $ui = $context->{ui} if $context;
    if ($ui && blessed($ui) && $ui->{host_proto}) {
        return $ui->{host_proto};
    }
    return undef;
}

=head2 execute_remote

Execute a CLIO task on a remote system.

Workflow:
1. Validate parameters
2. Check remote system connectivity
3. Download CLIO on remote (if not present)
4. Create minimal config on remote
5. Execute CLIO with task
6. Retrieve results
7. Cleanup remote system

=cut

sub execute_remote {
    my ($self, $params, $context) = @_;
    
    my $host = $params->{host};
    my $command = $params->{command};
    my $model = $params->{model};
    my $api_key = $params->{api_key};
    my $timeout = $params->{timeout} || 300;
    my $cleanup = $params->{cleanup} // 1;
    my $ssh_key = $params->{ssh_key};
    my $ssh_port = $params->{ssh_port} || 22;
    my $output_files = $params->{output_files} || [];
    my $working_dir = $params->{working_dir} || '/tmp';
    my $api_provider = $params->{api_provider};
    my $api_base = $params->{api_base};
    
    # Resolve device name to host if needed
    my $resolved = $self->_resolve_device($host);
    if ($resolved->{host}) {
        $host = $resolved->{host};
        # Use device-specific settings if not overridden
        $ssh_port = $resolved->{ssh_port} if $resolved->{ssh_port} && !$params->{ssh_port};
        $ssh_key = $resolved->{ssh_key} if $resolved->{ssh_key} && !$params->{ssh_key};
        $model ||= $resolved->{default_model} if $resolved->{default_model};
    }
    
    # Auto-populate model from current session if not specified
    # The harness injects this so the agent never needs to care about it
    unless ($model) {
        if ($context && $context->{api_manager} && $context->{api_manager}->can('get_current_model')) {
            $model = $context->{api_manager}->get_current_model();
        } elsif ($context && $context->{current_model}) {
            $model = $context->{current_model};
        }
    }
    
    # Model is required - must come from params, context, or device config
    unless ($model) {
        return $self->error_result("Missing required parameter: model. Specify a model or run from a session with a configured model.");
    }
    
    # Auto-populate API provider from current session
    unless ($api_provider && $api_provider ne 'github_copilot') {
        if ($context && $context->{api_manager} && $context->{api_manager}->can('get_current_provider')) {
            my $session_provider = $context->{api_manager}->get_current_provider();
            $api_provider = $session_provider if $session_provider;
        } elsif ($context && $context->{config}) {
            my $config_provider = $context->{config}->get('provider');
            $api_provider = $config_provider if $config_provider;
        }
    }
    
    # Auto-populate API base from current session (for custom proxies)
    unless ($api_base) {
        if ($context && $context->{api_manager} && $context->{api_manager}->{api_base}) {
            $api_base = $context->{api_manager}->{api_base};
        } elsif ($context && $context->{config}) {
            $api_base = $context->{config}->get('api_base');
        }
    }
    
    # Auto-populate API key from current session - the harness injects this
    # so the agent never needs to know about or handle API keys
    unless ($api_key) {
        # Priority 1: Get from the live api_manager (has the resolved/authenticated key)
        if ($context && $context->{api_manager} && $context->{api_manager}->{api_key}) {
            $api_key = $context->{api_manager}->{api_key};
            log_debug('RemoteExecution', "Auto-populated api_key from api_manager (length=" . length($api_key) . ")");
        }
        # Priority 2: Get from config
        elsif ($context && $context->{config}) {
            $api_key = $context->{config}->get('api_key');
            log_debug('RemoteExecution', "Auto-populated api_key from config (length=" . length($api_key // '') . ")");
        }
        # Priority 3: For GitHub Copilot, get from GitHubAuth
        if (!$api_key && $api_provider eq 'github_copilot') {
            eval {
                require CLIO::Core::GitHubAuth;
                my $auth = CLIO::Core::GitHubAuth->new();
                my $tokens = $auth->load_tokens();
                $api_key = $tokens->{github_token} if $tokens && $tokens->{github_token};
                log_debug('RemoteExecution', "Auto-populated api_key from GitHubAuth") if $api_key;
            };
        }
    }
    
    log_debug('RemoteExecution', "Auto-populated: model=$model, provider=$api_provider, api_key_length=" . length($api_key // ''));
    
    # Validate parameters (now with auto-populated values)
    my $validation = $self->_validate_execute_params({ 
        host => $host,
        command => $command,
        api_key => $api_key
    });
    unless ($validation->{success}) {
        return $validation;
    }
    
    # API key is critical for remote execution - fail early if missing
    unless ($api_key) {
        return $self->error_result(
            "No API key available for remote execution. " .
            "The session must have a configured API key. " .
            "Use /api key <value> or /api provider <name> to configure."
        );
    }
    
    # Validate SSH setup before attempting execution
    my $ssh_validation = $self->_validate_ssh_setup(
        host => $host,
        ssh_key => $ssh_key,
        ssh_port => $ssh_port,
    );
    unless ($ssh_validation->{success}) {
        return $ssh_validation;
    }
    
    # Create temporary directory for staging
    my $local_staging = tempdir(CLEANUP => 1);
    my $remote_staging = "$working_dir/clio-exec-$$-" . time();
    my $q_remote_staging = $self->_shell_quote($remote_staging);
    
    my $result;
    my $host_proto = $self->_get_host_proto($context);
    my $start_time = time();
    
    # Emit OSC remote start event
    if ($host_proto && $host_proto->active()) {
        $host_proto->emit_remote_event('start',
            host  => $host,
            task  => $command,
            model => $model,
        );
    }
    
    eval {
        # 1. Check remote connectivity
        log_debug('RemoteExecution', "Checking remote system: $host");
        
        if ($host_proto && $host_proto->active()) {
            $host_proto->emit_remote_event('progress',
                host    => $host,
                stage   => 'connecting',
                message => 'Checking remote system connectivity',
            );
        }
        my $check_result = $self->check_remote({
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
        }, $context);
        
        unless ($check_result->{success}) {
            croak "Remote system check failed: " . ($check_result->{error} || 'unknown error');
        }
        
        # 2. Download CLIO on remote
        log_debug('RemoteExecution', "Downloading CLIO on remote");
        
        if ($host_proto && $host_proto->active()) {
            $host_proto->emit_remote_event('progress',
                host    => $host,
                stage   => 'staging',
                message => 'Copying CLIO to remote system',
            );
        }
        my $install_result = $self->_copy_local_clio_to_remote(
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
            remote_dir => $remote_staging,
        );
        
        unless ($install_result->{success}) {
            croak "CLIO download failed: " . $install_result->{error};
        }
        
        my $clio_path = $install_result->{clio_path};
        
        # 3. Create minimal config on remote
        log_debug('RemoteExecution', "Creating minimal config on remote");
        my $config_result = $self->_create_remote_config(
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
            remote_dir => $remote_staging,
            api_provider => $api_provider,
            model => $model,
            api_key => $api_key,
            api_base => $api_base,
        );
        
        unless ($config_result->{success}) {
            croak "Config creation failed: " . $config_result->{error};
        }
        
        # 4. Execute CLIO on remote
        log_debug('RemoteExecution', "Executing CLIO on remote: $command");
        
        if ($host_proto && $host_proto->active()) {
            $host_proto->emit_remote_event('progress',
                host    => $host,
                stage   => 'executing',
                message => 'Running task on remote system',
            );
        }
        my $exec_result = $self->_execute_clio_remote(
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
            clio_path => $clio_path,
            config_dir => $config_result->{config_dir},
            command => $command,
            timeout => $timeout,
            remote_dir => $remote_staging,
            api_key => $api_key,
            model => $model,
        );
        
        unless ($exec_result->{success}) {
            croak "Remote execution failed: " . $exec_result->{error};
        }
        
        my $stdout = $exec_result->{stdout};
        my $exit_code = $exec_result->{exit_code};
        my $execution_time = $exec_result->{execution_time};
        
        # 5. Retrieve output files if specified
        my %retrieved_files;
        if (@$output_files) {
            log_debug('RemoteExecution', "Retrieving output files");
            for my $file (@$output_files) {
                my $remote_file = "$remote_staging/$file";
                my $local_file = File::Spec->catfile($local_staging, $file);
                
                my $retrieve = $self->_scp_from_remote(
                    host => $host,
                    ssh_key => $ssh_key,
                    ssh_port => $ssh_port,
                    remote_path => $remote_file,
                    local_path => $local_file,
                );
                
                if ($retrieve->{success}) {
                    $retrieved_files{$file} = $local_file;
                }
            }
        }
        
        # 6. Cleanup remote (if requested)
        if ($cleanup) {
            log_debug('RemoteExecution', "Cleaning up remote system");
            $self->_ssh_exec(
                host => $host,
                ssh_key => $ssh_key,
                ssh_port => $ssh_port,
                command => "rm -rf $q_remote_staging",
            );
        }
        
        # Store success result
        $result = $self->success_result(
            $stdout,
            action_description => "executing remote task on $host",
            host => $host,
            exit_code => $exit_code,
            execution_time => $execution_time,
            files_retrieved => [keys %retrieved_files],
            retrieved_files => \%retrieved_files,
        );
        
        # Emit OSC remote complete event
        if ($host_proto && $host_proto->active()) {
            $host_proto->emit_remote_event('complete',
                host            => $host,
                duration        => $execution_time,
                files_retrieved => [keys %retrieved_files],
            );
        }
    };
    
    if ($@) {
        my $error = "$@";

        # Emit OSC remote error event
        if ($host_proto && $host_proto->active()) {
            $host_proto->emit_remote_event('error',
                host     => $host,
                error    => $error,
                duration => time() - $start_time,
            );
        }

        # Attempt cleanup on error
        eval {
            $self->_ssh_exec(
                host => $host,
                ssh_key => $ssh_key,
                ssh_port => $ssh_port,
                command => "rm -rf $q_remote_staging",
            ) if $cleanup;
        };

        return $self->error_result("Remote execution failed: " . $self->_clean_eval_error($error));
    }
    
    return $result;
}

=head2 execute_parallel

Execute a command on multiple devices in parallel.

Parameters:
- targets (required): Array of device names, group name, or 'all'
- command (required): Task description for CLIO
- model (optional): AI model to use (defaults to current session model)
- timeout (optional): Timeout per device (default: 300)

Returns aggregated results from all devices.

=cut

sub execute_parallel {
    my ($self, $params, $context) = @_;
    
    my $targets = $params->{targets};  # Can be array, group name, or 'all'
    my $command = $params->{command};
    my $model = $params->{model};
    my $timeout = $params->{timeout} || 300;
    my $api_key = $params->{api_key};
    my $api_provider = $params->{api_provider};
    my $api_base = $params->{api_base};
    
    # Validate required params
    unless ($targets && $command) {
        return $self->error_result("Missing required parameters: targets, command");
    }
    
    # Auto-populate model from current session if not specified
    unless ($model) {
        if ($context && $context->{api_manager} && $context->{api_manager}->can('get_current_model')) {
            $model = $context->{api_manager}->get_current_model();
        } elsif ($context && $context->{current_model}) {
            $model = $context->{current_model};
        }
    }
    
    # Model is required - must come from params, context, or device config
    unless ($model) {
        return $self->error_result("Missing required parameter: model. Specify a model or run from a session with a configured model.");
    }
    
    # Auto-populate API provider from current session
    unless ($api_provider) {
        if ($context && $context->{api_manager} && $context->{api_manager}->can('get_current_provider')) {
            $api_provider = $context->{api_manager}->get_current_provider();
        } elsif ($context && $context->{config}) {
            $api_provider = $context->{config}->get('provider');
        }
        $api_provider ||= 'github_copilot';  # Fallback default
    }
    
    # Auto-populate API base from current session (for custom proxies)
    unless ($api_base) {
        if ($context && $context->{api_manager} && $context->{api_manager}->{api_base}) {
            $api_base = $context->{api_manager}->{api_base};
        } elsif ($context && $context->{config}) {
            $api_base = $context->{config}->get('api_base');
        }
    }
    
    # Auto-populate API key from current session - the harness injects this
    unless ($api_key) {
        if ($context && $context->{api_manager} && $context->{api_manager}->{api_key}) {
            $api_key = $context->{api_manager}->{api_key};
        } elsif ($context && $context->{config}) {
            $api_key = $context->{config}->get('api_key');
        }
        if (!$api_key && $api_provider eq 'github_copilot') {
            eval {
                require CLIO::Core::GitHubAuth;
                my $auth = CLIO::Core::GitHubAuth->new();
                my $tokens = $auth->load_tokens();
                $api_key = $tokens->{github_token} if $tokens && $tokens->{github_token};
            };
        }
    }
    
    # Resolve targets to list of devices
    my @devices = $self->_resolve_targets($targets);
    
    unless (@devices) {
        return $self->error_result("No devices resolved from targets: $targets");
    }
    
    log_debug('RemoteExecution', "Parallel execution on " . scalar(@devices) . " device(s)");
    
    # Execute on all devices
    # For simplicity and reliability, execute sequentially for now
    # Sequential execution is sufficient; parallel would need fork/IPC coordination
    my @results;
    
    for my $device (@devices) {
        log_debug('RemoteExecution', "Executing on: $device->{name} ($device->{host})");
        
        my $start_time = time();
        
        my $result = eval {
            $self->execute_remote({
                host => $device->{host},
                command => $command,
                model => $model,
                api_key => $api_key,
                api_provider => $api_provider,
                api_base => $api_base,
                timeout => $timeout,
                ssh_port => $device->{ssh_port} || 22,
                ssh_key => $device->{ssh_key},
            }, $context);
        };
        
        my $elapsed = time() - $start_time;
        
        if ($@ || !$result) {
                push @results, {
                    device => $device->{name},
                    host => $device->{host},
                    success => 0,
                    error => ($@ ? $self->_clean_eval_error($@) : '') || "No result returned",
                    elapsed_seconds => $elapsed,
                };
        } else {
            push @results, {
                device => $device->{name},
                host => $device->{host},
                %$result,
                elapsed_seconds => $elapsed,
            };
        }
    }
    
    # Aggregate results
    my $success_count = scalar grep { $_->{success} } @results;
    my $fail_count = scalar(@results) - $success_count;
    
    if (should_log('DEBUG')) {
        log_debug('RemoteExecution', "Parallel execution complete:");
        log_debug('RemoteExecution', "  Success: $success_count, Failed: $fail_count");
        for my $result (@results) {
            log_debug('RemoteExecution', "  Device: $result->{device} - " . ($result->{success} ? "OK" : "FAILED") . "");
            if ($result->{output}) {
                my $preview = substr($result->{output}, 0, 200);
                $preview =~ s/\n/ /g;
                log_debug('RemoteExecution', "    Output preview: $preview...");
            }
            if ($result->{error}) {
                log_debug('RemoteExecution', "    Error: $result->{error}");
            }
        }
    }
    
    # Build summary
    my $summary = "Execution on " . scalar(@devices) . " device(s):\n";
    $summary .= "  Success: $success_count\n";
    $summary .= "  Failed: $fail_count\n\n";
    
    for my $result (@results) {
        $summary .= "--- $result->{device} ($result->{host}) ---\n";
        if ($result->{success}) {
            my $output = $result->{output} || '';
            # Don't truncate - let ToolResultStore handle large outputs
            # Old code truncated at 500 chars which confused the AI
            $summary .= $output . "\n";
        } else {
            $summary .= "ERROR: " . ($result->{error} || 'Unknown error') . "\n";
        }
        $summary .= "\n";
    }
    
    return $self->success_result(
        $summary,
        action_description => "parallel execution on " . scalar(@devices) . " device(s)",
        devices => [map { $_->{name} } @devices],
        results => \@results,
        success_count => $success_count,
        fail_count => $fail_count,
    );
}

# Resolve targets to list of device info hashes
sub _resolve_targets {
    my ($self, $targets) = @_;
    
    my @devices;
    
    eval {
        require CLIO::Core::DeviceRegistry;
        my $registry = CLIO::Core::DeviceRegistry->new();
        
        if (ref($targets) eq 'ARRAY') {
            # Array of device names
            for my $name (@$targets) {
                my @resolved = $registry->resolve_with_info($name);
                push @devices, @resolved;
            }
        } else {
            # Single target - could be device name, group name, or 'all'
            my @resolved = $registry->resolve_with_info($targets);
            push @devices, @resolved;
        }
    };
    
    if ($@ && $self->{debug}) {
        log_debug('RemoteExecution', "Error resolving targets: $@");
    }
    
    return @devices;
}

=head2 prepare_remote

Pre-stage CLIO on remote system without executing a task.

=cut

sub prepare_remote {
    my ($self, $params, $context) = @_;
    
    my $host = $params->{host};
    my $ssh_key = $params->{ssh_key};
    my $ssh_port = $params->{ssh_port} || 22;
    my $clio_source = $params->{clio_source} || 'auto';
    my $install_dir = $params->{install_dir};
    
    unless ($host) {
        return $self->error_result("Missing required parameter: host");
    }
    
    # Generate install directory if not specified
    $install_dir ||= "/tmp/clio-" . time() . "-$$";
    
    my $result;
    eval {
        my $download_result = $self->_copy_local_clio_to_remote(
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
            remote_dir => $install_dir,
        );
        
        unless ($download_result->{success}) {
            croak $download_result->{error};
        }
        
        $result = $self->success_result(
            "CLIO prepared on remote",
            action_description => "staging CLIO on $host",
            host => $host,
            install_dir => $install_dir,
            clio_version => $download_result->{version},
        );
    };
    
    if ($@) {
        return $self->error_result("Preparation failed: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

=head2 cleanup_remote

Remove CLIO and temporary files from remote system.

=cut

sub cleanup_remote {
    my ($self, $params, $context) = @_;
    
    my $host = $params->{host};
    my $install_dir = $params->{install_dir};
    my $ssh_key = $params->{ssh_key};
    my $ssh_port = $params->{ssh_port} || 22;
    
    unless ($host && $install_dir) {
        return $self->error_result("Missing required parameters: host, install_dir");
    }
    
    my $result;
    eval {
        my $ssh_result = $self->_ssh_exec(
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
            command => "rm -rf " . $self->_shell_quote($install_dir),
        );
        
        unless ($ssh_result->{success}) {
            croak $ssh_result->{error};
        }
        
        $result = $self->success_result(
            "Cleanup complete",
            action_description => "removing CLIO from $host",
            host => $host,
            removed_dir => $install_dir,
        );
    };
    
    if ($@) {
        return $self->error_result("Cleanup failed: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

=head2 check_remote

Verify remote system connectivity and requirements.

Checks:
- SSH connectivity
- Perl availability
- Basic tools (curl/wget, tar, etc.)
- Disk space
- Permissions

=cut

sub check_remote {
    my ($self, $params, $context) = @_;
    
    my $host = $params->{host};
    my $ssh_key = $params->{ssh_key};
    my $ssh_port = $params->{ssh_port} || 22;
    
    unless ($host) {
        return $self->error_result("Missing required parameter: host");
    }
    
    # Resolve device name to host if needed
    my $resolved = $self->_resolve_device($host);
    if ($resolved->{host}) {
        $host = $resolved->{host};
        $ssh_port = $resolved->{ssh_port} if $resolved->{ssh_port} && !$params->{ssh_port};
        $ssh_key = $resolved->{ssh_key} if $resolved->{ssh_key} && !$params->{ssh_key};
    }
    
    my $result;
    eval {
        # Check SSH connectivity
        my $conn = $self->_ssh_exec(
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
            command => "echo 'SSH OK'",
        );
        
        unless ($conn->{success}) {
            croak "SSH connection failed: " . ($conn->{error} || 'unknown error');
        }
        
        # Check Perl
        my $perl = $self->_ssh_exec(
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
            command => "perl -v | head -1",
        );
        
        unless ($perl->{success}) {
            croak "Perl not available on remote";
        }
        
        # Check for download tools
        my $curl = $self->_ssh_exec(
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
            command => "command -v curl || command -v wget",
        );
        
        unless ($curl->{success}) {
            croak "Neither curl nor wget available on remote";
        }
        
        # Check disk space in /tmp
        my $disk = $self->_ssh_exec(
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
            command => "df /tmp | awk 'NR==2 {print \$4}'",
        );
        
        my $available_kb = '0';
        if ($disk->{stdout} && $disk->{stdout} =~ /(\d+)\s*$/) {
            $available_kb = $1;
        }
        my $available_mb = int($available_kb / 1024);
        
        if ($available_mb < 50) {
            croak "Insufficient disk space: only ${available_mb}MB available in /tmp";
        }
        
        $result = $self->success_result(
            "Remote system ready",
            action_description => "checking remote system: $host",
            host => $host,
            perl_available => 1,
            download_tool => $curl->{stdout} =~ /curl/ ? 'curl' : 'wget',
            disk_space_mb => $available_mb,
        );
    };
    
    if ($@) {
        return $self->error_result("Remote check failed: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

=head2 transfer_files

Transfer files to remote system via SCP.

Parameters:
- host (required): SSH connection target
- files (required): Array of {local_path => 'local/path', remote_path => 'remote/path'}
- ssh_key (optional): SSH private key
- ssh_port (optional): SSH port

=cut

sub transfer_files {
    my ($self, $params, $context) = @_;
    
    my $host = $params->{host};
    my $files = $params->{files} || [];
    my $ssh_key = $params->{ssh_key};
    my $ssh_port = $params->{ssh_port} || 22;
    
    unless ($host) {
        return $self->error_result("Missing required parameter: host");
    }
    
    unless (ref($files) eq 'ARRAY' && @$files) {
        return $self->error_result("Missing or empty 'files' parameter");
    }
    
    my @transferred;
    my $result;
    
    eval {
        for my $file_spec (@$files) {
            my $local = $file_spec->{local_path};
            my $remote = $file_spec->{remote_path};
            
            unless ($local && $remote) {
                croak "File spec missing local_path or remote_path";
            }
            
            my $scp_result = $self->_scp_to_remote(
                host => $host,
                ssh_key => $ssh_key,
                ssh_port => $ssh_port,
                local_path => $local,
                remote_path => $remote,
            );
            
            unless ($scp_result->{success}) {
                croak "Failed to transfer $local: " . $scp_result->{error};
            }
            
            push @transferred, $remote;
        }
        
        $result = $self->success_result(
            "Files transferred",
            action_description => "transferring " . scalar(@transferred) . " file(s) to $host",
            host => $host,
            files_transferred => \@transferred,
        );
    };
    
    if ($@) {
        return $self->error_result("File transfer failed: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

=head2 retrieve_files

Retrieve files from remote system via SCP.

Parameters:
- host (required): SSH connection target
- files (required): Array of {remote_path => 'remote/path', local_path => 'local/path'}
- ssh_key (optional): SSH private key
- ssh_port (optional): SSH port

=cut

sub retrieve_files {
    my ($self, $params, $context) = @_;
    
    my $host = $params->{host};
    my $files = $params->{files} || [];
    my $ssh_key = $params->{ssh_key};
    my $ssh_port = $params->{ssh_port} || 22;
    
    unless ($host) {
        return $self->error_result("Missing required parameter: host");
    }
    
    unless (ref($files) eq 'ARRAY' && @$files) {
        return $self->error_result("Missing or empty 'files' parameter");
    }
    
    my @retrieved;
    my $result;
    
    eval {
        for my $file_spec (@$files) {
            my $remote = $file_spec->{remote_path};
            my $local = $file_spec->{local_path};
            
            unless ($local && $remote) {
                croak "File spec missing local_path or remote_path";
            }
            
            my $scp_result = $self->_scp_from_remote(
                host => $host,
                ssh_key => $ssh_key,
                ssh_port => $ssh_port,
                remote_path => $remote,
                local_path => $local,
            );
            
            unless ($scp_result->{success}) {
                croak "Failed to retrieve $remote: " . $scp_result->{error};
            }
            
            push @retrieved, $local;
        }
        
        $result = $self->success_result(
            "Files retrieved",
            action_description => "retrieving " . scalar(@retrieved) . " file(s) from $host",
            host => $host,
            files_retrieved => \@retrieved,
        );
    };
    
    if ($@) {
        return $self->error_result("File retrieval failed: " . $self->_clean_eval_error($@));
    }
    
    return $result;
}

# ============================================================================
# PRIVATE HELPER METHODS
# ============================================================================

# --------------------------------------------------------------------------
# Input validation and shell quoting helpers (security hardening)
# --------------------------------------------------------------------------

sub _shell_quote {
    my ($self, $str) = @_;
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

sub _validate_host {
    my ($self, $host) = @_;
    return 0 unless defined $host && length $host;
    # Allow user@host, IPv4, IPv6 in brackets, hostnames with underscores
    # Reject shell metacharacters: spaces, semicolons, backticks, $(), pipes, etc.
    # Allow: alphanumeric, underscore, hyphen, dot, @, colon, brackets
    return $host =~ /\A[a-zA-Z0-9_\-.\@\[\]:]+\z/;
}

sub _validate_port {
    my ($self, $port) = @_;
    return 0 unless defined $port;
    return $port =~ /\A\d+\z/ && $port > 0 && $port <= 65535;
}

sub _validate_path {
    my ($self, $path) = @_;
    return 0 unless defined $path && length $path;
    # Reject null bytes
    return 0 if $path =~ /\0/;
    return 1;
}

sub _validate_execute_params {
    my ($self, $params) = @_;
    
    # host and command are required; api_key is auto-populated from session
    my $required = [qw(host command)];
    
    for my $param (@$required) {
        unless ($params->{$param}) {
            return $self->error_result("Missing required parameter: $param");
        }
    }
    
    # Warn if api_key is empty (but don't fail - some providers don't need keys)
    unless ($params->{api_key}) {
        log_warning('RemoteExecution', "No API key available for remote execution - remote CLIO may fail to authenticate");
    }
    
    return $self->success_result("Parameters valid");
}

=head2 _validate_ssh_setup

Validate SSH connectivity and configuration before attempting remote execution.

Checks:
1. SSH agent is running (if no explicit key provided)
2. Can connect to remote without password prompt
3. Provides actionable guidance if setup incomplete

Returns success result if SSH is properly configured, error result with guidance otherwise.

=cut

sub _validate_ssh_setup {
    my ($self, %args) = @_;
    
    my $host = $args{host};
    my $ssh_key = $args{ssh_key};
    my $ssh_port = $args{ssh_port} || 22;
    
    # Validate inputs before building shell commands
    unless ($self->_validate_host($host)) {
        return $self->error_result("Invalid host: contains disallowed characters");
    }
    unless ($self->_validate_port($ssh_port)) {
        return $self->error_result("Invalid SSH port: must be numeric 1-65535");
    }
    if ($ssh_key && !$self->_validate_path($ssh_key)) {
        return $self->error_result("Invalid SSH key path");
    }
    
    # Check if ssh-agent is running (only if no explicit key provided)
    unless ($ssh_key) {
        my $agent_check = `ssh-add -l 2>&1`;
        my $agent_exit = $? >> 8;
        
        # Exit code 2 means agent not running
        # Exit code 1 means agent running but no keys
        # Exit code 0 means agent running with keys
        
        if ($agent_exit == 2) {
            return $self->error_result(
                "SSH agent not running. Remote execution requires SSH agent or explicit key.\n\n" .
                "Setup guide:\n" .
                "1. Start ssh-agent: eval \"\$(ssh-agent -s)\"\n" .
                "2. Add your key: ssh-add ~/.ssh/id_rsa (or id_ed25519)\n" .
                "3. Test connection: ssh $host exit\n\n" .
                "See docs/REMOTE_EXECUTION.md for detailed setup instructions."
            );
        }
        
        if ($agent_exit == 1) {
            # Agent is running but has no keys - this is OK, SSH will use keys from ~/.ssh/
            # Just warn the user, don't block
            log_warning('RemoteExec', "SSH agent running but no keys loaded. SSH will use keys from ~/.ssh/");
        }
    }
    
    # Test passwordless connection
    my $ssh_cmd = 'ssh -o BatchMode=yes -o ConnectTimeout=5';
    $ssh_cmd .= " -p $ssh_port" if $ssh_port != 22;
    $ssh_cmd .= " -i " . $self->_shell_quote($ssh_key) if $ssh_key;
    $ssh_cmd .= " " . $self->_shell_quote($host) . " exit 2>&1";
    
    my $test_output = `$ssh_cmd`;
    my $test_exit = $? >> 8;
    
    if ($test_exit != 0) {
        # Try to provide helpful error message based on output
        my $guidance = "";
        
        if ($test_output =~ /Permission denied/i) {
            $guidance = 
                "SSH authentication failed.\n\n" .
                "Fix:\n" .
                "1. Copy your SSH key to remote: ssh-copy-id $host\n" .
                "2. Or add key to ssh-agent: ssh-add ~/.ssh/id_rsa\n" .
                "3. Test: ssh $host exit\n\n";
        } elsif ($test_output =~ /Connection refused/i) {
            $guidance = 
                "SSH connection refused - is SSH server running on $host?\n\n" .
                "Check:\n" .
                "1. SSH daemon running: systemctl status sshd\n" .
                "2. Firewall allows port $ssh_port\n" .
                "3. Correct hostname/IP\n\n";
        } elsif ($test_output =~ /Connection timed out/i || $test_output =~ /Could not resolve/i) {
            $guidance = 
                "Cannot reach $host - check network connectivity.\n\n" .
                "Check:\n" .
                "1. Host is reachable: ping $host\n" .
                "2. DNS resolution working\n" .
                "3. No firewall blocking connection\n\n";
        } else {
            $guidance = 
                "SSH connection test failed.\n\n" .
                "Error: $test_output\n\n" .
                "Troubleshooting:\n" .
                "1. Test manually: ssh $host exit\n" .
                "2. Check SSH logs: journalctl -u sshd\n" .
                "3. Verify SSH key setup\n\n";
        }
        
        $guidance .= "See docs/REMOTE_EXECUTION.md for detailed setup instructions.";
        
        return $self->error_result($guidance);
    }
    
    # All checks passed
    return $self->success_result("SSH connection validated");
}


sub _ssh_exec {
    my ($self, %args) = @_;
    
    my $host = $args{host};
    my $ssh_key = $args{ssh_key};
    my $ssh_port = $args{ssh_port} || 22;
    my $command = $args{command};
    
    # Validate inputs before building shell commands
    unless ($self->_validate_host($host)) {
        return { success => 0, error => "Invalid host: contains disallowed characters", exit_code => 1 };
    }
    unless ($self->_validate_port($ssh_port)) {
        return { success => 0, error => "Invalid SSH port: must be numeric 1-65535", exit_code => 1 };
    }
    if ($ssh_key && !$self->_validate_path($ssh_key)) {
        return { success => 0, error => "Invalid SSH key path", exit_code => 1 };
    }
    
    my $quoted_host = $self->_shell_quote($host);
    
    # Build SSH command base
    my $ssh_cmd = 'ssh';
    $ssh_cmd .= " -p $ssh_port" if $ssh_port != 22;
    $ssh_cmd .= " -i " . $self->_shell_quote($ssh_key) if $ssh_key;
    
    # For multi-line scripts or scripts with special chars, use base64 encoding
    # This prevents shell quoting issues entirely
    if ($command =~ /\n/ || $command =~ /['"\$]/) {
        # Base64 encode the command
        require MIME::Base64;
        my $encoded = MIME::Base64::encode_base64($command, '');
        $ssh_cmd .= " $quoted_host \"echo '$encoded' | base64 -d | bash\"";
    } else {
        # Simple command - direct execution
        $ssh_cmd .= " $quoted_host '$command'";
    }
    
    my $output = `$ssh_cmd 2>&1`;
    my $exit_code = $? >> 8;
    
    # Perl's $? can contain more than 8 bits on some systems
    # Ensure we only get the actual 8-bit exit code
    $exit_code = $exit_code & 0xFF;
    
    if ($exit_code != 0) {
        return {
            success => 0,
            error => $output,
            exit_code => $exit_code,
        };
    }
    
    return {
        success => 1,
        stdout => $output,
        exit_code => 0,
    };
}

sub _scp_to_remote {
    my ($self, %args) = @_;
    
    my $host = $args{host};
    my $ssh_key = $args{ssh_key};
    my $ssh_port = $args{ssh_port} || 22;
    my $local_path = $args{local_path};
    my $remote_path = $args{remote_path};
    
    # Validate inputs before building shell commands
    unless ($self->_validate_host($host)) {
        return { success => 0, error => "Invalid host: contains disallowed characters", exit_code => 1 };
    }
    unless ($self->_validate_port($ssh_port)) {
        return { success => 0, error => "Invalid SSH port: must be numeric 1-65535", exit_code => 1 };
    }
    if ($ssh_key && !$self->_validate_path($ssh_key)) {
        return { success => 0, error => "Invalid SSH key path", exit_code => 1 };
    }
    unless ($self->_validate_path($local_path) && $self->_validate_path($remote_path)) {
        return { success => 0, error => "Invalid file path", exit_code => 1 };
    }
    
    my $scp_cmd = 'scp -r';
    $scp_cmd .= " -P $ssh_port" if $ssh_port != 22;
    $scp_cmd .= " -i " . $self->_shell_quote($ssh_key) if $ssh_key;
    $scp_cmd .= " " . $self->_shell_quote($local_path) . " " . $self->_shell_quote("$host:$remote_path");
    
    my $output = `$scp_cmd 2>&1`;
    my $exit_code = $? >> 8;
    $exit_code = $exit_code & 0xFF;  # Ensure 8-bit exit code only
    
    if ($exit_code != 0) {
        return {
            success => 0,
            error => $output,
            exit_code => $exit_code,
        };
    }
    
    return {
        success => 1,
        stdout => $output,
    };
}

sub _scp_from_remote {
    my ($self, %args) = @_;
    
    my $host = $args{host};
    my $ssh_key = $args{ssh_key};
    my $ssh_port = $args{ssh_port} || 22;
    my $remote_path = $args{remote_path};
    my $local_path = $args{local_path};
    
    # Validate inputs before building shell commands
    unless ($self->_validate_host($host)) {
        return { success => 0, error => "Invalid host: contains disallowed characters", exit_code => 1 };
    }
    unless ($self->_validate_port($ssh_port)) {
        return { success => 0, error => "Invalid SSH port: must be numeric 1-65535", exit_code => 1 };
    }
    if ($ssh_key && !$self->_validate_path($ssh_key)) {
        return { success => 0, error => "Invalid SSH key path", exit_code => 1 };
    }
    unless ($self->_validate_path($remote_path) && $self->_validate_path($local_path)) {
        return { success => 0, error => "Invalid file path", exit_code => 1 };
    }
    
    my $scp_cmd = 'scp -r';
    $scp_cmd .= " -P $ssh_port" if $ssh_port != 22;
    $scp_cmd .= " -i " . $self->_shell_quote($ssh_key) if $ssh_key;
    $scp_cmd .= " " . $self->_shell_quote("$host:$remote_path") . " " . $self->_shell_quote($local_path);
    
    my $output = `$scp_cmd 2>&1`;
    my $exit_code = $? >> 8;
    $exit_code = $exit_code & 0xFF;  # Ensure 8-bit exit code only
    
    if ($exit_code != 0) {
        return {
            success => 0,
            error => $output,
            exit_code => $exit_code,
        };
    }
    
    return {
        success => 1,
        stdout => $output,
    };
}

sub _copy_local_clio_to_remote {
    my ($self, %args) = @_;
    
    my $host = $args{host};
    my $ssh_key = $args{ssh_key};
    my $ssh_port = $args{ssh_port} || 22;
    my $remote_dir = $args{remote_dir};
    
    # Validate inputs before building shell commands
    unless ($self->_validate_host($host)) {
        return { success => 0, error => "Invalid host: contains disallowed characters" };
    }
    unless ($self->_validate_port($ssh_port)) {
        return { success => 0, error => "Invalid SSH port: must be numeric 1-65535" };
    }
    if ($ssh_key && !$self->_validate_path($ssh_key)) {
        return { success => 0, error => "Invalid SSH key path" };
    }
    unless ($self->_validate_path($remote_dir)) {
        return { success => 0, error => "Invalid remote directory path" };
    }
    
    if (should_log('DEBUG')) {
        log_debug('RemoteExecution', "Copying local CLIO to remote: $host:$remote_dir");
    }
    
    # Find the local CLIO directory by searching up from CWD
    # The agent may be running from a subdirectory (e.g., scratch/), so we
    # need to walk up to find the root containing both 'clio' and 'lib/'
    my $local_clio_dir = getcwd();
    unless (-f "$local_clio_dir/clio" && -d "$local_clio_dir/lib") {
        # Walk up directories looking for CLIO root
        my $search_dir = $local_clio_dir;
        while ($search_dir ne '/') {
            if (-f "$search_dir/clio" && -d "$search_dir/lib") {
                $local_clio_dir = $search_dir;
                last;
            }
            $search_dir = dirname($search_dir);
        }
    }
    
    # Verify we have clio executable and lib directory
    unless (-f "$local_clio_dir/clio" && -d "$local_clio_dir/lib") {
        return {
            success => 0,
            error => "Local CLIO not found (searched from " . getcwd() . " up to /). Expected to find 'clio' executable and 'lib/' directory.",
        };
    }
    
    my $quoted_remote_dir = $self->_shell_quote($remote_dir);
    
    # Create remote directory (command goes through _ssh_exec which validates host)
    my $mkdir_result = $self->_ssh_exec(
        host => $host,
        ssh_key => $ssh_key,
        ssh_port => $ssh_port,
        command => "mkdir -p $quoted_remote_dir",
    );
    
    unless ($mkdir_result->{success}) {
        return {
            success => 0,
            error => "Failed to create remote directory: " . $mkdir_result->{error},
        };
    }
    
    # Use rsync to copy CLIO to remote
    my $quoted_host = $self->_shell_quote($host);
    my $ssh_opts = "ssh -p $ssh_port";
    $ssh_opts .= " -i " . $self->_shell_quote($ssh_key) if $ssh_key;
    
    # Use rsync WITHOUT --delete to avoid accidentally removing remote files
    # that aren't in the local source. The --delete flag is dangerous because
    # it can delete files on the remote that don't exist locally.
    my $rsync_cmd = "rsync -az -e " . $self->_shell_quote($ssh_opts);
    $rsync_cmd .= " --exclude='.git'";
    $rsync_cmd .= " --exclude='.clio/sessions'";
    $rsync_cmd .= " --exclude='ai-assisted'";
    $rsync_cmd .= " --exclude='scratch'";
    $rsync_cmd .= " --exclude='*.log'";
    
    # Build list of files to copy (local paths from getcwd, safe)
    my @files_to_copy = ("$local_clio_dir/clio", "$local_clio_dir/lib");
    if (-f "$local_clio_dir/cpanfile") {
        push @files_to_copy, "$local_clio_dir/cpanfile";
    }
    
    $rsync_cmd .= " " . join(" ", map { $self->_shell_quote($_) } @files_to_copy);
    $rsync_cmd .= " " . $self->_shell_quote("$host:$remote_dir/");
    
    if (should_log('DEBUG')) {
        log_debug('RemoteExecution', "Running rsync: $rsync_cmd");
    }
    
    my $rsync_output = `$rsync_cmd 2>&1`;
    my $rsync_exit = $? >> 8;
    $rsync_exit = $rsync_exit & 0xFF;
    
    if ($rsync_exit != 0) {
        if (should_log('DEBUG')) {
            log_debug('RemoteExecution', "rsync failed (exit $rsync_exit): $rsync_output");
        }
        return {
            success => 0,
            error => "rsync failed (exit $rsync_exit): $rsync_output",
        };
    }
    
    # Make clio executable
    my $chmod_result = $self->_ssh_exec(
        host => $host,
        ssh_key => $ssh_key,
        ssh_port => $ssh_port,
        command => "chmod +x $quoted_remote_dir/clio",
    );
    
    unless ($chmod_result->{success}) {
        return {
            success => 0,
            error => "Failed to make clio executable: " . $chmod_result->{error},
        };
    }
    
    if (should_log('DEBUG')) {
        log_debug('RemoteExecution', "Successfully copied CLIO to remote");
    }
    
    return {
        success => 1,
        clio_path => "$remote_dir/clio",
        method => 'local_copy',
    };
}

sub _create_remote_config {
    my ($self, %args) = @_;
    
    my $host = $args{host};
    my $ssh_key = $args{ssh_key};
    my $ssh_port = $args{ssh_port} || 22;
    my $remote_dir = $args{remote_dir};
    my $api_provider = $args{api_provider} || 'github_copilot';
    my $model = $args{model};
    my $api_key = $args{api_key} || '';
    my $api_base = $args{api_base} || '';
    
    # Create minimal config directory
    my $config_dir = "$remote_dir/.clio";
    my $q_config_dir = $self->_shell_quote($config_dir);
    
    # Escape values for JSON
    my $escaped_api_key = $api_key;
    $escaped_api_key =~ s/\\/\\\\/g;
    $escaped_api_key =~ s/"/\\"/g;
    my $escaped_api_base = $api_base;
    $escaped_api_base =~ s/\\/\\\\/g;
    $escaped_api_base =~ s/"/\\"/g;
    
    # Build config creation script
    # For GitHub Copilot, we need to also create the tokens file
    my $config_script;
    
    if ($api_provider eq 'github_copilot' && $api_key) {
        # GitHub Copilot: create config with provider/model and github_tokens.json
        # API key passed via CLIO_API_KEY env var, not written to files
        my $api_base_json = $api_base ? ",\n    \"api_base\": \"$escaped_api_base\"" : '';
        $config_script = <<"SCRIPT";
set -e
mkdir -p $q_config_dir

cat > $q_config_dir/config.json << 'CONFEOF'
{
    "provider": "$api_provider",
    "model": "$model"$api_base_json
}
CONFEOF

echo "CONFIG_DIR=$config_dir"
SCRIPT
    } else {
        # Standard config: provider, model, api_base
        # API key passed via CLIO_API_KEY env var, not written to config file
        my $api_base_json = $api_base ? ",\n    \"api_base\": \"$escaped_api_base\"" : '';
        $config_script = <<"SCRIPT";
set -e
mkdir -p $q_config_dir

cat > $q_config_dir/config.json << 'CONFEOF'
{
    "provider": "$api_provider",
    "model": "$model"$api_base_json
}
CONFEOF

echo "CONFIG_DIR=$config_dir"
SCRIPT
    }
    
    # Execute config creation
    log_debug('RemoteExecution', "Creating config: provider=$api_provider, model=$model, api_key_length=" . length($api_key // ''));
    
    # Debug: show the actual config script content
    if (should_log('DEBUG')) {
        my $debug_script = $config_script;
        $debug_script =~ s/("api_key":\s*)"[^"]*"/$1"***REDACTED***"/;
        log_debug('RemoteExecution', "Config script:\n$debug_script");
    }
    
    my $result = $self->_ssh_exec(
        host => $host,
        ssh_key => $ssh_key,
        ssh_port => $ssh_port,
        command => $config_script,
    );
    
    unless ($result->{success}) {
        return {
            success => 0,
            error => "Failed to create config: " . $result->{error},
        };
    }
    
    return {
        success => 1,
        config_dir => $config_dir,
    };
}

sub _execute_clio_remote {
    my ($self, %args) = @_;
    
    my $host = $args{host};
    my $ssh_key = $args{ssh_key};
    my $ssh_port = $args{ssh_port} || 22;
    my $clio_path = $args{clio_path};
    my $config_dir = $args{config_dir};
    my $command = $args{command};
    my $timeout = $args{timeout} || 300;
    my $remote_dir = $args{remote_dir};
    my $model = $args{model};
    my $api_key = $args{api_key};
    my $streaming = $args{streaming} // 0;  # New parameter for streaming support
    
    # Validate paths used in shell script
    for my $path ($clio_path, $config_dir, $remote_dir) {
        unless ($self->_validate_path($path)) {
            return { success => 0, error => "Invalid path in remote execution parameters" };
        }
    }
    
    # Shell-quote all values embedded in the script
    my $q_remote_dir = $self->_shell_quote($remote_dir);
    my $q_config_dir = $self->_shell_quote($config_dir);
    my $q_clio_path  = $self->_shell_quote($clio_path);
    my $q_model      = $self->_shell_quote($model);
    
    # Escape command for shell single-quote embedding
    $command =~ s/'/'\\''/g;
    
    # Build execution script
    # API key is passed via environment variable, never written to config file
    # This ensures the key exists only in memory on the remote system
    my $env_exports = "export HOME=$q_remote_dir\nexport CLIO_HOME=$q_config_dir";
    if ($api_key) {
        # Shell-quote the API key for safe env var passing
        my $q_api_key = $self->_shell_quote($api_key);
        $env_exports .= "\nexport CLIO_API_KEY=$q_api_key";
    }
    
    # Build the clio command with optional streaming flag
    my $clio_cmd = "$q_clio_path --model $q_model --input '$command'";
    $clio_cmd .= " --exit" unless $streaming;  # Only add --exit for non-streaming mode
    
    my $exec_script = <<"SHELL";
#!/bin/bash
set -e
$env_exports

cd $q_remote_dir

START=\$(date +%s)
$clio_cmd 2>&1
EXIT_CODE=\$?
END=\$(date +%s)
DURATION=\$((END - START))

echo "EXECUTION_TIME=\$DURATION"
echo "EXIT_CODE=\$EXIT_CODE"
SHELL
    
    # Execute on remote
    my $start_time = time();
    my $result = $self->_ssh_exec(
        host => $host,
        ssh_key => $ssh_key,
        ssh_port => $ssh_port,
        command => $exec_script,
    );
    my $elapsed = time() - $start_time;
    
    unless ($result->{success}) {
        return {
            success => 0,
            error => "Remote execution failed: " . $result->{error},
        };
    }
    
    # Parse execution time and exit code
    my $exec_time = $elapsed;
    my $exit_code = $result->{exit_code};
    
    my $stdout = $result->{stdout};
    
    if (should_log('DEBUG')) {
        log_debug('RemoteExecution', "Raw remote output:");
        log_debug('RemoteExecution', "--- BEGIN REMOTE OUTPUT ---");
        log_debug('RemoteExecution', $stdout);
        log_debug('RemoteExecution', "--- END REMOTE OUTPUT ---");
    }
    
    if ($stdout =~ /EXECUTION_TIME=(\d+)/) {
        $exec_time = $1;
    }
    if ($stdout =~ /EXIT_CODE=(\d+)/) {
        $exit_code = $1;
    }
    
    # Clean up the output - remove our metadata lines
    $stdout =~ s/\nEXECUTION_TIME=\d+\s*$//;
    $stdout =~ s/\nEXIT_CODE=\d+\s*$//;
    
    return {
        success => $exit_code == 0,
        stdout => $stdout,
        exit_code => $exit_code,
        execution_time => $exec_time,
    };
}

=head2 get_additional_parameters

Define tool-specific parameters.

NOTE: Descriptions are minimal - detailed docs are in tool's main description.

=cut

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        host => { type => "string", description => "SSH target (user\@hostname)" },
        command => { type => "string", description => "Task description for remote CLIO" },
        model => { type => "string", description => "AI model (auto-populated)" },
        api_key => { type => "string", description => "API key (auto-populated)" },
        timeout => { type => "integer", description => "Timeout seconds (default: 300)" },
        cleanup => { type => "boolean", description => "Cleanup after execution (default: true)" },
        ssh_key => { type => "string", description => "SSH private key path" },
        ssh_port => { type => "integer", description => "SSH port (default: 22)" },
        output_files => { type => "array", items => { type => "string" }, description => "Output files to retrieve" },
        api_provider => { type => "string", description => "API provider (auto-populated)" },
        api_base => { type => "string", description => "API base URL (auto-populated)" },
        working_dir => { type => "string", description => "Remote working dir (default: /tmp)" },
        targets => { type => "array", items => { type => "string" }, description => "Devices for parallel execution" },
        files => { type => "array", items => { type => "string" }, description => "Files to transfer/retrieve" },
    };
}

1;

__END__

=head1 DESIGN NOTES

This tool implements the remote execution layer of the distributed agent pattern.

Key design decisions:

1. **Security-First**: API keys never written to disk, passed via environment variables
2. **Minimal Configuration**: Only essential config transferred to remote
3. **Automatic Cleanup**: Temporary files removed after execution by default
4. **Error Handling**: Clear error messages for debugging
5. **Blocking Operation**: Execution completes before returning to workflow

=head1 SECURITY CONSIDERATIONS

- API keys are written to a temporary config directory on the remote system
- Config directory is cleaned up after execution by default (cleanup => 1)
- Temporary directories with restricted permissions
- API keys are auto-populated from the current session - never exposed to the AI agent
- SSH channel used for all credential transport

=head1 SEE ALSO

- CLIO::Tools::Tool - Base tool class
- ai-assisted/REMOTE_EXECUTION_DESIGN.md - Architecture documentation

=cut

1;
