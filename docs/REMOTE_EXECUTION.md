# Remote Execution Guide

**Distributed AI Agent Workflows with CLIO**

---

## Overview

CLIO's remote execution capability allows you to run AI-powered tasks on remote systems via SSH. This transforms CLIO from a local development assistant into a distributed orchestration platform.

### Key Capabilities

- **Execute AI tasks on remote systems** - Run CLIO with any task on any SSH-accessible machine
- **Auto-authentication** - GitHub Copilot tokens are securely forwarded (never written to disk)
- **Automatic setup** - CLIO downloads and configures itself on the remote system
- **Clean execution** - Temporary files are automatically cleaned up after execution
- **Result retrieval** - Capture output and optionally retrieve files from remote systems

### Use Cases

| Use Case | Description |
|----------|-------------|
| **System Analysis** | Gather diagnostics, hardware info, and logs from remote servers |
| **Distributed Builds** | Compile code on systems with specific hardware/architecture |
| **Multi-Environment Testing** | Run tests across different OS/hardware configurations |
| **Remote Debugging** | Investigate issues on production or staging systems |
| **Infrastructure Management** | Audit and analyze multiple systems from one location |
| **Hardware-Specific Tasks** | Utilize GPU, ARM, or specialized hardware on remote systems |

---

## Quick Start

### Basic Usage

The simplest way to execute a remote task:

```
Use remote_execution to check the disk space on myserver
```

CLIO will:
1. SSH into the server
2. Download and install CLIO temporarily
3. Execute the task using your configured model
4. Return the results
5. Clean up automatically

### Prerequisites

1. **SSH Access** - Password-less SSH key authentication to the remote system
2. **Remote Requirements**:
   - Perl 5.32+ installed
   - curl or wget available
   - ~50MB free disk space in /tmp
3. **GitHub Copilot** (or other API provider) - For AI model access

---

## Operations

### execute_remote (Primary Operation)

Execute an AI-powered task on a remote system.

**Parameters:**

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `host` | Yes | - | SSH target (user@hostname) |
| `command` | Yes | - | Natural language task description |
| `model` | Yes | - | AI model to use (e.g., gpt-4.1) |
| `api_key` | No | Auto | API key (auto-populated from GitHub token) |
| `timeout` | No | 300 | Max execution time in seconds |
| `cleanup` | No | true | Delete CLIO after execution |
| `ssh_key` | No | default | Path to SSH private key |
| `ssh_port` | No | 22 | SSH port |
| `output_files` | No | [] | Files to retrieve after execution |

**Example:**

```
Execute on user@mydevice with gpt-4.1: analyze the system hardware and create a detailed report
```

### check_remote

Verify a remote system is ready for CLIO execution.

**What it checks:**
- SSH connectivity
- Perl availability
- Download tools (curl/wget)
- Disk space (minimum 50MB)

**Example:**

```
Check if server@production is ready for remote execution
```

### prepare_remote

Pre-stage CLIO on a remote system without executing a task. Useful for:
- Reducing latency on repeated tasks
- Preparing multiple systems in advance
- Testing installation on a new system

### cleanup_remote

Manually remove CLIO from a remote system if automatic cleanup failed or was disabled.

### transfer_files / retrieve_files

Transfer files to/from remote systems before or after execution.

---

## Examples

### System Diagnostics

```
Use remote_execution on admin@webserver with gpt-4.1:
Create a system health report including CPU, memory, disk, and network status
```

### Code Analysis on Remote

```
Execute remotely on dev@buildserver with gpt-4.1:
Analyze the Python project in ~/myproject and identify potential security issues
```

### Multi-Step Remote Task

```
On user@handheld with gpt-4.1:
1. Check what games are installed in ~/Games
2. Report disk usage by game
3. Identify the largest game and when it was last played
```

### Hardware Inventory

```
Remote execution on admin@server1:
List all hardware including CPU model, RAM size, disk drives, and network adapters.
Format as a markdown table.
```

### Build on Specific Architecture

```
Execute on builder@arm-device with gpt-4.1:
Clone https://github.com/example/project, build for ARM64, and report any compilation errors
```

---

## Security Model

### Credential Handling

1. **API keys are never written to disk on remote systems**
   - For GitHub Copilot: Token is written to a temporary `github_tokens.json` file
   - File is deleted immediately after execution completes
   - Even on execution failure, cleanup attempts to remove credentials

2. **Minimal configuration transfer**
   - Only necessary settings are sent (provider, model)
   - No local history, context, or other sensitive data is transferred

3. **SSH-based security**
   - All communication uses your existing SSH infrastructure
   - No additional ports or services required
   - Leverages your SSH key authentication

### Best Practices

- Use dedicated SSH keys for remote execution if desired
- Ensure remote systems have appropriate access controls
- Review remote execution logs for sensitive data before sharing
- Use `cleanup: true` (default) to ensure temporary files are removed

---

## Troubleshooting

### Common Issues

**SSH Connection Failed**
```
Error: SSH connection failed
```
- Verify SSH key authentication works: `ssh user@host echo "test"`
- Check if the hostname is resolvable
- Verify SSH port if non-standard

**Perl Not Available**
```
Error: Perl not available on remote
```
- Install Perl 5.32+ on the remote system
- Check PATH includes Perl: `ssh user@host "which perl"`

**Insufficient Disk Space**
```
Error: Insufficient disk space: only XMB available in /tmp
```
- Clear space in /tmp on the remote system
- Use `working_dir` parameter to specify alternative directory

**Download Failed**
```
Error: Could not find CLIO release
```
- Verify internet connectivity on remote system
- Check if curl/wget is available
- GitHub API rate limits may apply

### Debug Mode

For detailed debugging, run CLIO with `--debug`:

```bash
./clio --debug
```

This shows:
- SSH commands being executed
- Remote script content
- Download progress
- Execution output

---

## Architecture

### How It Works

```
┌─────────────────┐         SSH          ┌──────────────────┐
│   Local CLIO    │ ───────────────────► │   Remote System  │
│                 │                       │                  │
│  1. Check host  │                       │  1. Verify reqs  │
│  2. Download    │ ──── Base64 ───────► │  2. Install CLIO │
│  3. Configure   │      Scripts          │  3. Create config│
│  4. Execute     │                       │  4. Run task     │
│  5. Get results │ ◄─────────────────── │  5. Return output│
│  6. Cleanup     │                       │  6. Delete files │
└─────────────────┘                       └──────────────────┘
```

### Key Design Decisions

1. **No persistent installation** - CLIO is downloaded fresh each time (ensures latest version)
2. **Base64 script encoding** - Prevents shell quoting issues with complex commands
3. **Automatic cleanup** - Leaves no trace on remote systems by default
4. **Token forwarding** - Credentials passed securely, never persisted

---

## Future Roadmap

### Planned Features

- **Multi-device workflows** - Execute tasks across multiple systems in parallel
- **Result aggregation** - Combine outputs from distributed executions
- **Persistent installations** - Option to keep CLIO installed for faster repeated tasks
- **Streaming output** - Real-time output from remote executions
- **Device groups** - Define named groups of systems for common workflows

### RemoteDistribution Protocol

A higher-level protocol for complex multi-stage workflows:

```
Workflow: "Build and Test Pipeline"
  Stage 1: Build (on build-server)
  Stage 2: Test (on test-servers, parallel)
  Stage 3: Deploy (on production, sequential)
```

---

## API Reference

### Tool: remote_execution

```json
{
  "name": "remote_execution",
  "operations": [
    "execute_remote",
    "prepare_remote", 
    "cleanup_remote",
    "check_remote",
    "transfer_files",
    "retrieve_files"
  ]
}
```

### Full Parameter Reference

```json
{
  "operation": "execute_remote",
  "host": "user@hostname",
  "command": "task description",
  "model": "gpt-4.1",
  "api_key": "auto-populated",
  "api_provider": "github_copilot",
  "timeout": 300,
  "cleanup": true,
  "ssh_key": "/path/to/key",
  "ssh_port": 22,
  "clio_source": "github",
  "output_files": ["report.md", "results/"],
  "working_dir": "/tmp"
}
```

---

## See Also

- [User Guide](USER_GUIDE.md) - Complete CLIO documentation
- [Architecture](ARCHITECTURE.md) - System design details
- [Developer Guide](DEVELOPER_GUIDE.md) - Extending CLIO
