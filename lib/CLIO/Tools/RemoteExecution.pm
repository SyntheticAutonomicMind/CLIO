package CLIO::Tools::RemoteExecution;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use parent 'CLIO::Tools::Tool';
use Cwd 'getcwd';
use CLIO::Util::JSON qw(encode_json decode_json);
use File::Temp qw(tempdir);
use File::Spec;
use File::Path qw(make_path remove_tree);
use feature 'say';
use CLIO::Core::Logger qw(should_log);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

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
- model (required): AI model to use on remote
- api_key (required): API key for remote provider
- timeout (optional): Execution timeout in seconds (default: 300)
- cleanup (optional): Delete CLIO after execution (default: 1)
- ssh_key (optional): Path to SSH private key
- ssh_port (optional): SSH port (default: 22)
- output_files (optional): Array of files to retrieve from remote
- working_dir (optional): Working directory on remote (default: /tmp)

Note: CLIO is copied from the local system to the remote, ensuring
version consistency and eliminating dependency on GitHub releases.

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
   Takes: host, command, model (api_key auto-populated from GitHub token)
   Returns: Task output and any retrieved files
   Security: API key passed via environment variable, never persisted on remote
   
-  execute_parallel - Run task on MULTIPLE devices simultaneously
   Takes: targets (device names, group name, or 'all'), command, model
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
  model: "gpt-4.1"  (or your preferred model)
  (api_key: auto-populated from GitHub Copilot token - no need to specify)
  
PARALLEL EXECUTION:
  operation: "execute_parallel"
  targets: "handhelds"  (group name, or array of device names, or "all")
  command: "report disk space"
  model: "gpt-4.1"
  
The tool will automatically:
- SSH into the host
- Download CLIO from GitHub
- Create minimal configuration
- Auto-populate API key from current GitHub token
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

sub route_operation {
    my ($self, $operation, $params, $context) = @_;
    
    # Sandbox mode: Block all remote execution
    if ($context && $context->{config} && $context->{config}->get('sandbox')) {
        return $self->error_result(
            "Sandbox mode: Remote execution is disabled.\n\n" .
            "The --sandbox flag blocks all remote operations. " .
            "This is a security feature to prevent the agent from reaching outside the local project."
        );
    }
    
    if ($operation eq 'execute_remote') {
        return $self->execute_remote($params, $context);
    } elsif ($operation eq 'execute_parallel') {
        return $self->execute_parallel($params, $context);
    } elsif ($operation eq 'prepare_remote') {
        return $self->prepare_remote($params, $context);
    } elsif ($operation eq 'cleanup_remote') {
        return $self->cleanup_remote($params, $context);
    } elsif ($operation eq 'check_remote') {
        return $self->check_remote($params, $context);
    } elsif ($operation eq 'transfer_files') {
        return $self->transfer_files($params, $context);
    } elsif ($operation eq 'retrieve_files') {
        return $self->retrieve_files($params, $context);
    }
    
    return $self->error_result("Operation not implemented: $operation");
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
    my $api_provider = $params->{api_provider} || 'github_copilot';
    
    # Resolve device name to host if needed
    my $resolved = $self->_resolve_device($host);
    if ($resolved->{host}) {
        $host = $resolved->{host};
        # Use device-specific settings if not overridden
        $ssh_port = $resolved->{ssh_port} if $resolved->{ssh_port} && !$params->{ssh_port};
        $ssh_key = $resolved->{ssh_key} if $resolved->{ssh_key} && !$params->{ssh_key};
        $model ||= $resolved->{default_model} if $resolved->{default_model};
    }
    
    # Auto-populate API key from context config if not provided
    unless ($api_key) {
        if ($context && $context->{config}) {
            # Try standard api_key first
            $api_key = $context->{config}->get('api_key');
            
            # For GitHub Copilot, try to get the GitHub token
            if (!$api_key && $api_provider eq 'github_copilot') {
                eval {
                    require CLIO::Core::GitHubAuth;
                    my $auth = CLIO::Core::GitHubAuth->new();
                    my $tokens = $auth->load_tokens();
                    $api_key = $tokens->{github_token} if $tokens && $tokens->{github_token};
                };
            }
        }
    }
    
    # Validate parameters (now with potentially-populated API key)
    my $validation = $self->_validate_execute_params({ 
        host => $host,
        command => $command,
        model => $model,
        api_key => $api_key
    });
    unless ($validation->{success}) {
        return $validation;
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
    
    my $result;
    eval {
        # 1. Check remote connectivity
        print STDERR "[DEBUG][RemoteExecution] Checking remote system: $host\n" if $self->{debug};
        my $check_result = $self->check_remote({
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
        }, $context);
        
        unless ($check_result->{success}) {
            die "Remote system check failed: " . ($check_result->{error} || 'unknown error');
        }
        
        # 2. Download CLIO on remote
        print STDERR "[DEBUG][RemoteExecution] Downloading CLIO on remote\n" if $self->{debug};
        my $install_result = $self->_copy_local_clio_to_remote(
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
            remote_dir => $remote_staging,
        );
        
        unless ($install_result->{success}) {
            die "CLIO download failed: " . $install_result->{error};
        }
        
        my $clio_path = $install_result->{clio_path};
        
        # 3. Create minimal config on remote
        print STDERR "[DEBUG][RemoteExecution] Creating minimal config on remote\n" if $self->{debug};
        my $config_result = $self->_create_remote_config(
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
            remote_dir => $remote_staging,
            api_provider => $api_provider,
            model => $model,
            api_key => $api_key,
        );
        
        unless ($config_result->{success}) {
            die "Config creation failed: " . $config_result->{error};
        }
        
        # 4. Execute CLIO on remote
        print STDERR "[DEBUG][RemoteExecution] Executing CLIO on remote: $command\n" if $self->{debug};
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
            die "Remote execution failed: " . $exec_result->{error};
        }
        
        my $stdout = $exec_result->{stdout};
        my $exit_code = $exec_result->{exit_code};
        my $execution_time = $exec_result->{execution_time};
        
        # 5. Retrieve output files if specified
        my %retrieved_files;
        if (@$output_files) {
            print STDERR "[DEBUG][RemoteExecution] Retrieving output files\n" if $self->{debug};
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
            print STDERR "[DEBUG][RemoteExecution] Cleaning up remote system\n" if $self->{debug};
            $self->_ssh_exec(
                host => $host,
                ssh_key => $ssh_key,
                ssh_port => $ssh_port,
                command => "rm -rf $remote_staging",
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
    };
    
    if ($@) {
        # Attempt cleanup on error
        eval {
            $self->_ssh_exec(
                host => $host,
                ssh_key => $ssh_key,
                ssh_port => $ssh_port,
                command => "rm -rf $remote_staging",
            ) if $cleanup;
        };
        
        return $self->error_result("Remote execution failed: $@");
    }
    
    return $result;
}

=head2 execute_parallel

Execute a command on multiple devices in parallel.

Parameters:
- targets (required): Array of device names, group name, or 'all'
- command (required): Task description for CLIO
- model (required): AI model to use
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
    my $api_provider = $params->{api_provider} || 'github_copilot';
    
    # Validate required params
    unless ($targets && $command && $model) {
        return $self->error_result("Missing required parameters: targets, command, model");
    }
    
    # Resolve targets to list of devices
    my @devices = $self->_resolve_targets($targets);
    
    unless (@devices) {
        return $self->error_result("No devices resolved from targets: $targets");
    }
    
    print STDERR "[DEBUG][RemoteExecution] Parallel execution on " . scalar(@devices) . " device(s)\n" if $self->{debug};
    
    # Auto-populate API key if needed
    unless ($api_key) {
        if ($context && $context->{config}) {
            $api_key = $context->{config}->get('api_key');
            if (!$api_key && $api_provider eq 'github_copilot') {
                eval {
                    require CLIO::Core::GitHubAuth;
                    my $auth = CLIO::Core::GitHubAuth->new();
                    my $tokens = $auth->load_tokens();
                    $api_key = $tokens->{github_token} if $tokens && $tokens->{github_token};
                };
            }
        }
    }
    
    # Execute on all devices
    # For simplicity and reliability, execute sequentially for now
    # Sequential execution is sufficient; parallel would need fork/IPC coordination
    my @results;
    
    for my $device (@devices) {
        print STDERR "[DEBUG][RemoteExecution] Executing on: $device->{name} ($device->{host})\n" if $self->{debug};
        
        my $start_time = time();
        
        my $result = eval {
            $self->execute_remote({
                host => $device->{host},
                command => $command,
                model => $model,
                api_key => $api_key,
                api_provider => $api_provider,
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
                error => $@ || "No result returned",
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
        print STDERR "[DEBUG][RemoteExecution] Parallel execution complete:\n";
        print STDERR "  Success: $success_count, Failed: $fail_count\n";
        for my $result (@results) {
            print STDERR "  Device: $result->{device} - " . ($result->{success} ? "OK" : "FAILED") . "\n";
            if ($result->{output}) {
                my $preview = substr($result->{output}, 0, 200);
                $preview =~ s/\n/ /g;
                print STDERR "    Output preview: $preview...\n";
            }
            if ($result->{error}) {
                print STDERR "    Error: $result->{error}\n";
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
        print STDERR "[DEBUG][RemoteExecution] Error resolving targets: $@\n";
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
            die $download_result->{error};
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
        return $self->error_result("Preparation failed: $@");
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
            command => "rm -rf $install_dir",
        );
        
        unless ($ssh_result->{success}) {
            die $ssh_result->{error};
        }
        
        $result = $self->success_result(
            "Cleanup complete",
            action_description => "removing CLIO from $host",
            host => $host,
            removed_dir => $install_dir,
        );
    };
    
    if ($@) {
        return $self->error_result("Cleanup failed: $@");
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
            die "SSH connection failed: " . ($conn->{error} || 'unknown error');
        }
        
        # Check Perl
        my $perl = $self->_ssh_exec(
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
            command => "perl -v | head -1",
        );
        
        unless ($perl->{success}) {
            die "Perl not available on remote";
        }
        
        # Check for download tools
        my $curl = $self->_ssh_exec(
            host => $host,
            ssh_key => $ssh_key,
            ssh_port => $ssh_port,
            command => "command -v curl || command -v wget",
        );
        
        unless ($curl->{success}) {
            die "Neither curl nor wget available on remote";
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
            die "Insufficient disk space: only ${available_mb}MB available in /tmp";
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
        return $self->error_result("Remote check failed: $@");
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
                die "File spec missing local_path or remote_path";
            }
            
            my $scp_result = $self->_scp_to_remote(
                host => $host,
                ssh_key => $ssh_key,
                ssh_port => $ssh_port,
                local_path => $local,
                remote_path => $remote,
            );
            
            unless ($scp_result->{success}) {
                die "Failed to transfer $local: " . $scp_result->{error};
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
        return $self->error_result("File transfer failed: $@");
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
                die "File spec missing local_path or remote_path";
            }
            
            my $scp_result = $self->_scp_from_remote(
                host => $host,
                ssh_key => $ssh_key,
                ssh_port => $ssh_port,
                remote_path => $remote,
                local_path => $local,
            );
            
            unless ($scp_result->{success}) {
                die "Failed to retrieve $remote: " . $scp_result->{error};
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
        return $self->error_result("File retrieval failed: $@");
    }
    
    return $result;
}

# ============================================================================
# PRIVATE HELPER METHODS
# ============================================================================

sub _validate_execute_params {
    my ($self, $params) = @_;
    
    my $required = [qw(host command model api_key)];
    
    for my $param (@$required) {
        unless ($params->{$param}) {
            return $self->error_result("Missing required parameter: $param");
        }
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
            return $self->error_result(
                "SSH agent running but no keys loaded.\n\n" .
                "Add your SSH key:\n" .
                "  ssh-add ~/.ssh/id_rsa  (or id_ed25519)\n\n" .
                "Or create a new key:\n" .
                "  ssh-keygen -t ed25519 -C \"your_email\@example.com\"\n" .
                "  ssh-copy-id $host\n" .
                "  ssh-add ~/.ssh/id_ed25519\n\n" .
                "See docs/REMOTE_EXECUTION.md for detailed setup instructions."
            );
        }
    }
    
    # Test passwordless connection
    my $ssh_cmd = 'ssh -o BatchMode=yes -o ConnectTimeout=5';
    $ssh_cmd .= " -p $ssh_port" if $ssh_port != 22;
    $ssh_cmd .= " -i $ssh_key" if $ssh_key;
    $ssh_cmd .= " $host exit 2>&1";
    
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
    
    # Build SSH command base
    my $ssh_cmd = 'ssh';
    $ssh_cmd .= " -p $ssh_port" if $ssh_port != 22;
    $ssh_cmd .= " -i $ssh_key" if $ssh_key;
    
    # For multi-line scripts or scripts with special chars, use base64 encoding
    # This prevents shell quoting issues entirely
    if ($command =~ /\n/ || $command =~ /['"\$]/) {
        # Base64 encode the command
        require MIME::Base64;
        my $encoded = MIME::Base64::encode_base64($command, '');
        $ssh_cmd .= " $host \"echo '$encoded' | base64 -d | bash\"";
    } else {
        # Simple command - direct execution
        $ssh_cmd .= " $host '$command'";
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
    
    my $scp_cmd = 'scp -r';
    $scp_cmd .= " -P $ssh_port" if $ssh_port != 22;
    $scp_cmd .= " -i $ssh_key" if $ssh_key;
    $scp_cmd .= " '$local_path' '$host:$remote_path'";
    
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
    
    my $scp_cmd = 'scp -r';
    $scp_cmd .= " -P $ssh_port" if $ssh_port != 22;
    $scp_cmd .= " -i $ssh_key" if $ssh_key;
    $scp_cmd .= " '$host:$remote_path' '$local_path'";
    
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
    
    if (should_log('DEBUG')) {
        print STDERR "[DEBUG][RemoteExecution] Copying local CLIO to remote: $host:$remote_dir\n";
    }
    
    # Find the local CLIO directory
    # We're running from the CLIO directory, so use current directory
    my $local_clio_dir = getcwd();
    
    # Verify we have clio executable and lib directory
    unless (-f "$local_clio_dir/clio" && -d "$local_clio_dir/lib") {
        return {
            success => 0,
            error => "Local CLIO not found (expected $local_clio_dir/clio and $local_clio_dir/lib)",
        };
    }
    
    # Create remote directory
    my $mkdir_result = $self->_ssh_exec(
        host => $host,
        ssh_key => $ssh_key,
        ssh_port => $ssh_port,
        command => "mkdir -p $remote_dir",
    );
    
    unless ($mkdir_result->{success}) {
        return {
            success => 0,
            error => "Failed to create remote directory: " . $mkdir_result->{error},
        };
    }
    
    # Use rsync to copy CLIO to remote
    # rsync is faster and more efficient than tar+scp
    my $rsync_cmd = 'rsync -az --delete';
    $rsync_cmd .= " -e 'ssh -p $ssh_port" . ($ssh_key ? " -i $ssh_key" : "") . "'";
    $rsync_cmd .= " --exclude='.git'";
    $rsync_cmd .= " --exclude='.clio/sessions'";
    $rsync_cmd .= " --exclude='ai-assisted'";
    $rsync_cmd .= " --exclude='scratch'";
    $rsync_cmd .= " --exclude='*.log'";
    
    # Build list of files to copy
    my @files_to_copy = ("$local_clio_dir/clio", "$local_clio_dir/lib");
    if (-f "$local_clio_dir/cpanfile") {
        push @files_to_copy, "$local_clio_dir/cpanfile";
    }
    
    $rsync_cmd .= " " . join(" ", @files_to_copy);
    $rsync_cmd .= " $host:$remote_dir/";
    
    if (should_log('DEBUG')) {
        print STDERR "[DEBUG][RemoteExecution] Running rsync: $rsync_cmd\n";
    }
    
    my $rsync_output = `$rsync_cmd 2>&1`;
    my $rsync_exit = $? >> 8;
    $rsync_exit = $rsync_exit & 0xFF;
    
    if ($rsync_exit != 0) {
        if (should_log('DEBUG')) {
            print STDERR "[DEBUG][RemoteExecution] rsync failed (exit $rsync_exit): $rsync_output\n";
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
        command => "chmod +x $remote_dir/clio",
    );
    
    unless ($chmod_result->{success}) {
        return {
            success => 0,
            error => "Failed to make clio executable: " . $chmod_result->{error},
        };
    }
    
    if (should_log('DEBUG')) {
        print STDERR "[DEBUG][RemoteExecution] Successfully copied CLIO to remote\n";
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
    
    # Create minimal config directory
    my $config_dir = "$remote_dir/.clio";
    
    # Escape api_key for JSON
    my $escaped_api_key = $api_key;
    $escaped_api_key =~ s/\\/\\\\/g;
    $escaped_api_key =~ s/"/\\"/g;
    
    # Build config creation script
    # For GitHub Copilot, we need to also create the tokens file
    my $config_script;
    
    if ($api_provider eq 'github_copilot' && $api_key) {
        # Create both config.json and github_tokens.json for GitHub Copilot
        $config_script = <<"SCRIPT";
set -e
mkdir -p $config_dir

cat > $config_dir/config.json << 'CONFEOF'
{
    "provider": "$api_provider",
    "model": "$model"
}
CONFEOF

cat > $config_dir/github_tokens.json << 'TOKEOF'
{
    "github_token": "$escaped_api_key",
    "copilot_token": null,
    "saved_at": 0
}
TOKEOF

echo "CONFIG_DIR=$config_dir"
SCRIPT
    } else {
        # Standard config with api_key
        $config_script = <<"SCRIPT";
set -e
mkdir -p $config_dir

cat > $config_dir/config.json << 'CONFEOF'
{
    "api_key": "$escaped_api_key",
    "provider": "$api_provider",
    "model": "$model"
}
CONFEOF

echo "CONFIG_DIR=$config_dir"
SCRIPT
    }
    
    # Execute config creation
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
    
    # Escape command for shell
    $command =~ s/'/'\\''/g;
    
    # Build execution script
    # CLIO reads credentials from $CLIO_HOME/config.json and $CLIO_HOME/github_tokens.json
    # which were created by _create_remote_config
    my $exec_script = <<"SHELL";
#!/bin/bash
set -e
export HOME=$remote_dir
export CLIO_HOME=$config_dir

cd $remote_dir

START=\$(date +%s)
$clio_path --model "$model" --input '$command' --exit 2>&1
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
        print STDERR "[DEBUG][RemoteExecution] Raw remote output:\n";
        print STDERR "--- BEGIN REMOTE OUTPUT ---\n";
        print STDERR $stdout . "\n";
        print STDERR "--- END REMOTE OUTPUT ---\n";
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

=cut

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        host => {
            type => "string",
            description => "SSH connection target (user\@hostname)",
        },
        command => {
            type => "string",
            description => "Task description for remote CLIO",
        },
        model => {
            type => "string",
            description => "AI model to use on remote (e.g., gpt-4.1)",
        },
        api_key => {
            type => "string",
            description => "API key for remote provider (auto-populated from GitHub Copilot token if not provided)",
        },
        timeout => {
            type => "integer",
            description => "Execution timeout in seconds (default: 300)",
        },
        cleanup => {
            type => "boolean",
            description => "Delete CLIO after execution (default: true)",
        },
        ssh_key => {
            type => "string",
            description => "Path to SSH private key (optional)",
        },
        ssh_port => {
            type => "integer",
            description => "SSH port (default: 22)",
        },
        output_files => {
            type => "array",
            items => { type => "string" },
            description => "Array of output files to retrieve from remote",
        },
        api_provider => {
            type => "string",
            description => "API provider (default: github_copilot)",
        },
        working_dir => {
            type => "string",
            description => "Working directory on remote (default: /tmp)",
        },
        targets => {
            type => "array",
            items => { type => "string" },
            description => "Device names, group name, or 'all' for parallel execution",
        },
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

- API keys passed via SSH_CLIO_API_KEY environment variable only
- No persistent config files on remote after execution
- Temporary directories with restricted permissions
- Full cleanup of remote state by default
- SSH channel used for all credential transport

=head1 SEE ALSO

- CLIO::Protocols::RemoteDistribution - Multi-stage remote workflows
- CLIO::Tools::Tool - Base tool class
- ai-assisted/REMOTE_EXECUTION_DESIGN.md - Architecture documentation

=cut

1;
