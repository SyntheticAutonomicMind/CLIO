# Remote Execution & Distributed Agent Architecture

**Date:** 2026-02-01  
**Author:** CLIO (with Andrew Wyatt)  
**Status:** Design Phase

## Vision

Transform CLIO into a distributed orchestration platform where a local agent can:

1. **Remotely execute** complex tasks on specialized devices
2. **Delegate work** to systems optimized for specific tasks
3. **Offload processing** from resource-constrained environments
4. **Gather intelligence** from multiple networked systems
5. **Coordinate multi-stage workflows** across heterogeneous infrastructure

This enables powerful use cases where a single development machine can coordinate work across multiple remote systems with different hardware, operating systems, and network connectivity.

## Architecture Overview

### Layer 1: RemoteExecution Tool (Tactical)

**Purpose:** Direct, single-task remote execution  
**Complexity:** Low  
**Use Case:** One-off tasks, simple information gathering, straightforward builds, distributed compilation

**Responsibilities:**
- SSH connection management
- Config transfer (minimal set)
- CLIO download/installation
- Task execution
- Result retrieval
- Cleanup

**Key Design Decisions:**
1. **Minimal Config Transfer**: Only send necessary credentials
   - API provider URL (not in config, hardcoded)
   - API model (user-specified or default)
   - API key (via environment variable, never persisted on remote)

2. **Config Security**: Never persist full config on remote
   - After execution, immediately delete transferred credentials
   - Environment variables only for credential delivery
   - No `.clio/config.json` left on remote by default

3. **No Bi-directional Communication**: Remote CLIO runs autonomously
   - Execute remote command, wait for completion
   - Return results or error
   - No streaming, no interactive prompts to local agent

### Layer 2: RemoteDistribution Protocol (Strategic)

**Purpose:** Complex, multi-stage workflows across remote systems  
**Complexity:** High  
**Use Case:** Build pipelines, hardware analysis, staged deployments

**Responsibilities:**
- Analyze task suitability for remote execution
- Plan which files/data to transfer
- Prepare environment on remote
- Execute with monitoring
- Verify success/failure
- Decide on retry vs. error handling
- Coordinate multi-system workflows

**Phases:**

#### Phase 1: Planning
- Understand the task requirements
- Determine if remote execution is appropriate
- Identify data dependencies
- Estimate resource needs
- Validate remote system capabilities

#### Phase 2: Preparation
- Gather all required files for transfer
- Create minimal configuration package
- Prepare environment setup script (if needed)
- Validate connectivity and authentication

#### Phase 3: Execution
- Use RemoteExecution tool to run the task
- Monitor progress (if streaming support added later)
- Capture all output and artifacts

#### Phase 4: Verification
- Check success/failure status
- Validate output format/correctness
- Decide if retry is appropriate
- Log outcome for audit trail

#### Phase 5: Cleanup & Result Processing
- Delete temporary files on remote
- Transfer results back to local system
- Clean up local staging area
- Return structured result

## Data Models

### RemoteTask (used by RemoteExecution tool)

```perl
{
    # Connection info
    host => 'user@hostname',           # SSH connection target
    ssh_key => '/path/to/key',         # SSH key (optional, use ~/.ssh/default)
    ssh_port => 22,                    # SSH port (optional, default 22)
    
    # Execution
    command => 'Analyze hardware',     # Task description for CLIO
    model => 'gpt-4.1',                # Model to use on remote
    
    # Configuration (MINIMAL - only what's needed)
    api_provider => 'github_copilot',  # Provider (optional, default from config)
    # API key passed via SSH_CLIO_API_KEY environment variable
    # NO config.json transferred
    
    # Remote execution environment
    clio_install_dir => '/tmp/clio',   # Where to install CLIO (default: /tmp/clio-<random>)
    clio_source => 'github',           # github | local_tar | cached
    
    # Execution options
    timeout => 300,                    # Max execution time (seconds)
    cleanup => 1,                      # Delete CLIO after execution (default: yes)
    capture_output => 1,               # Capture stdout/stderr
    
    # Results handling
    output_file => 'report.md',        # Specific file to fetch back
    output_dir => 'results/',          # Directory to fetch back
}
```

### RemoteWorkflow (used by RemoteDistribution protocol)

```perl
{
    name => 'Multi-Device Analysis Pipeline',
    description => 'Analyze and build on multiple remote systems',
    
    # Task breakdown
    stages => [
        {
            name => 'Analyze',
            task => 'Gather system specs and environment info',
            target => 'all',                    # all | device_list
            devices => ['dev1', 'dev2', 'dev3'],   # Specific devices
            
            # What to transfer to this stage
            files_to_transfer => [
                '/path/to/project',
                '/path/to/analysis_script.sh',
            ],
            
            # How to execute
            command => 'Run system analysis and save to report.json',
            model => 'gpt-4o-mini',  # Can use different model per stage
            
            # What to bring back
            expected_outputs => ['report.json', 'system.log'],
        },
        {
            name => 'Build',
            task => 'Compile project for this system',
            target => 'per-device',
            
            # Continue with device results from Analyze stage
            depends_on => 'Analyze',
            use_stage_outputs => 1,
            
            command => 'Build with system-specific optimizations',
            timeout => 900,
        },
    ],
    
    # Error handling strategy
    error_handling => {
        retry_failed_devices => 1,
        max_retries => 2,
        fail_fast => 0,  # Continue with other devices even if one fails
        notification => 'send_summary',  # notify_user | send_summary | silent
    },
    
    # Aggregation strategy for multi-device
    aggregation => {
        merge_outputs => 1,
        create_summary => 1,
        report_format => 'markdown',
    },
}
```

### RemoteResult

```perl
{
    success => 1,
    host => 'user@remote-host',
    
    # Task info
    command => 'Analyze system',
    execution_time => 45.2,
    
    # Output
    stdout => '...',
    stderr => '...',
    exit_code => 0,
    
    # Retrieved files
    files => {
        'report.md' => '/local/path/to/report.md',
        'data.json' => '/local/path/to/data.json',
    },
    
    # Metadata for retry/debugging
    attempt => 1,
    retry_info => {
        should_retry => 0,
        reason => 'Success',
    },
}
```

## RemoteExecution Tool API

### Operation: execute_remote

**Description:** Execute a command on a remote system via CLIO

**Parameters:**
```json
{
    "operation": "execute_remote",
    "host": "user@remote-system",
    "command": "Analyze the system and environment",
    "model": "gpt-4.1",
    "api_key": "ghp_...",  // Via SSH_CLIO_API_KEY env var
    "timeout": 300,
    "cleanup": true
}
```

**Returns:**
```json
{
    "success": true,
    "output": "Analysis complete...",
    "host": "user@remote-system",
    "exit_code": 0,
    "execution_time": 45.2,
    "files_retrieved": ["report.md"]
}
```

### Operation: prepare_remote

**Description:** Pre-stage CLIO on a remote system without executing

**Parameters:**
```json
{
    "operation": "prepare_remote",
    "host": "user@remote-system",
    "api_key": "ghp_...",
    "clio_source": "github",
    "install_dir": "/tmp/clio"
}
```

**Returns:**
```json
{
    "success": true,
    "host": "user@remote-system",
    "clio_version": "20260201.1",
    "install_dir": "/tmp/clio"
}
```

### Operation: cleanup_remote

**Description:** Remove CLIO and cleanup temporary files

**Parameters:**
```json
{
    "operation": "cleanup_remote",
    "host": "user@remote-system",
    "install_dir": "/tmp/clio"
}
```

## RemoteDistribution Protocol

**Purpose:** Orchestrate complex multi-stage workflows

**Entry Point:**
```perl
my $remote_dist = CLIO::Protocols::RemoteDistribution->new();
my $result = $remote_dist->execute_workflow($workflow, $context);
```

**Workflow Execution:**
1. Parse workflow definition
2. Validate all stages
3. For each stage:
   a. Prepare remote environments
   b. Transfer files
   c. Execute via RemoteExecution tool
   d. Capture results
   e. Transfer back results
4. Aggregate results across devices
5. Return comprehensive summary

## Security Considerations

### 1. API Key Handling

**NEVER:**
- Write API key to remote filesystem
- Store in ~/.clio/config.json on remote
- Log API key in any output

**DO:**
- Pass API key via SSH_CLIO_API_KEY environment variable
- Delete environment variable immediately after use
- Use SSH's secure channel for credential transport

### 2. Configuration Transfer

**NEVER:**
- Transfer full ~/.clio/config.json
- Transfer ~/.clio/github_tokens.json
- Leave any sensitive config on remote after execution

**DO:**
- Construct minimal in-memory config on remote
- Only include API provider URL and model
- Pass credentials via secure channel
- Clean up immediately

### 3. File Transfer Security

- Use SCP/SFTP (over SSH) for all file transfers
- Verify file integrity with checksums
- Use temporary directories with restricted permissions
- Cleanup all temporary files after execution

### 4. Session Isolation

- Each remote execution in isolated temp directory
- No config persistence between executions
- No state sharing except explicit result files
- Clear session data after completion

## Implementation Roadmap

### Phase 1: Foundation (Today)
- [ ] Create RemoteExecution.pm tool
- [ ] Implement execute_remote operation
- [ ] Basic SSH connectivity
- [ ] Config transfer (secure)
- [ ] CLIO download and execute
- [ ] Result retrieval

### Phase 2: Enhancement
- [ ] prepare_remote operation (pre-stage)
- [ ] cleanup_remote operation (explicit cleanup)
- [ ] Error handling and retry logic
- [ ] Timeout management
- [ ] Comprehensive logging

### Phase 3: Protocol
- [ ] RemoteDistribution.pm protocol
- [ ] Multi-device workflows
- [ ] Result aggregation
- [ ] Workflow definition DSL
- [ ] Status reporting

### Phase 4: Skills
- [ ] Document as reusable skill
- [ ] PowerDeck integration
- [ ] Example workflows
- [ ] Best practices guide

## PowerDeck Integration Example

```
User: "Analyze all PowerDeck devices and create a unified report"

Local CLIO:
1. Plans: Need to gather hardware info from 5 devices
2. Prepares: Create minimal config, gather any needed files
3. Executes (via RemoteDistribution protocol):
   - For each device (laptop, desktop, server1, server2, workstation):
     a. SSH connect
     b. Transfer CLIO + minimal config
     c. Execute: "Analyze this device's hardware"
     d. Retrieve report_<device>.md
     e. Cleanup
4. Aggregates: Merge all reports into unified_report.md
5. Returns: Comprehensive analysis across all devices
```

## Testing Strategy

### Unit Tests
- SSH connection validation
- Config minimization logic
- File transfer simulation
- Error handling for each operation

### Integration Tests
- End-to-end execution with mock remote
- Multi-device workflow (using local as mock)
- Error recovery and retry logic
- File cleanup verification

### PowerDeck Validation
- Real execution on 1-2 actual devices
- Verify credential security
- Check file cleanup
- Measure performance

## Success Criteria

1. ✓ RemoteExecution tool works for single-task execution
2. ✓ No credentials persist on remote after execution
3. ✓ Multi-device workflows complete successfully
4. ✓ Results properly aggregated and returned
5. ✓ Performance reasonable for interactive use
6. ✓ Error handling graceful with clear feedback
7. ✓ Skill documented and reusable

## Open Questions

1. Should we support bi-directional streaming? (Phase 3.5)
2. How to handle offline devices? (Queue, retry schedule, etc.)
3. Should we cache CLIO binary on remote to avoid re-download?
4. How to handle version mismatches between local and remote CLIO?
5. Should we support different models per device?

## References

- PowerDeck project requirements
- CLIO tool architecture (Tool.pm, Registry.pm)
- Protocol architecture (ProtocolIntegration.pm)
- Session management patterns
