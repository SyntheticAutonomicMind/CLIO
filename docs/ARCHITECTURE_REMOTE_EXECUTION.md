# Remote Execution Architecture

Architecture reference for CLIO's distributed agent execution system.

For user-facing documentation, see [REMOTE_EXECUTION.md](REMOTE_EXECUTION.md).

---

## Overview

CLIO's remote execution system enables a local agent to execute tasks on remote systems via SSH. A local CLIO instance copies itself to the remote, runs a task, and retrieves results - all within a single tool call.

### Key Modules

| Module | Lines | Purpose |
|--------|-------|---------|
| `CLIO::Tools::RemoteExecution` | ~1670 | Tool implementation (7 operations) |
| `CLIO::Core::DeviceRegistry` | ~540 | Device/group management with ~/.clio/devices.json |

---

## Distribution Method

Remote execution uses **rsync** to copy the local CLIO installation to the remote system:

```
Local CLIO install --rsync--> /tmp/clio-<random>/ on remote
```

This ensures:
- Version consistency (remote always matches local)
- No dependency on GitHub releases or network connectivity from the remote
- Works on air-gapped networks (only needs SSH between local and remote)

Rsync excludes `.git/`, `.clio/sessions/`, and other non-essential files.

---

## Security Model

### Credential Handling

- **API key** is passed via environment variable (`SSH_CLIO_API_KEY`), never persisted on remote
- **GitHub Copilot tokens** are auto-populated from the local session's active token
- No `config.json` is written on the remote with credentials
- Cleanup removes the entire CLIO installation after execution (default behavior)

### SSH

- Standard SSH key authentication (uses system default or specified key)
- `StrictHostKeyChecking=accept-new` for first-time connections
- Port configurable (default 22)
- Host/port validation prevents injection attacks

---

## Operations

### execute_remote

Primary operation. Runs a single task on one remote system:

1. Validate SSH connectivity
2. Rsync CLIO to remote temp directory
3. Create minimal config with API credentials
4. Execute CLIO in non-interactive mode (`--input "task" --exit`)
5. Capture stdout/stderr
6. Retrieve specified output files
7. Cleanup (if enabled)

### execute_parallel

Runs the same task on multiple devices simultaneously:

1. Resolve targets (device names, group name, or `"all"`)
2. Fork one process per target
3. Each child runs `execute_remote` independently
4. Parent collects results from all children
5. Returns aggregated results

### Other Operations

| Operation | Purpose |
|-----------|---------|
| `prepare_remote` | Pre-stage CLIO without executing |
| `cleanup_remote` | Remove CLIO from remote |
| `check_remote` | Verify SSH connectivity and requirements |
| `transfer_files` | Copy files to remote |
| `retrieve_files` | Fetch files from remote |

---

## Device Registry

Devices and groups are stored in `~/.clio/devices.json`:

```json
{
    "devices": {
        "build-server": {
            "host": "user@build.local",
            "ssh_key": "~/.ssh/build_key",
            "description": "ARM build server"
        }
    },
    "groups": {
        "handhelds": ["steam-deck", "legion-go", "ally-x"]
    }
}
```

Managed via the `/device` command:
- `/device add <name> <host>` - Register a device
- `/device remove <name>` - Unregister
- `/device list` - Show all devices and groups
- `/device group create <name>` - Create a group
- `/device group add <group> <device>` - Add device to group

The `execute_parallel` operation accepts group names or device names as targets.

---

## Feature Toggle

Remote execution can be disabled via configuration:

```
/config set enable_remote off
```

When disabled, the `remote_execution` tool is not registered in the tool registry and is unavailable to the AI agent.

---

## Data Flow

```
User/Agent Request
    │
    ▼
RemoteExecution.route_operation()
    │
    ├─ execute_remote ──▶ _validate_execute_params()
    │                         │
    │                         ▼
    │                    _validate_ssh_setup()
    │                         │
    │                         ▼
    │                    rsync local CLIO to remote
    │                         │
    │                         ▼
    │                    _ssh_exec("clio --input 'task' --exit")
    │                         │
    │                         ▼
    │                    retrieve output files
    │                         │
    │                         ▼
    │                    cleanup (if enabled)
    │
    ├─ execute_parallel ──▶ _resolve_targets() via DeviceRegistry
    │                         │
    │                         ▼
    │                    fork() per target
    │                         │
    │                         ▼
    │                    each child: execute_remote()
    │                         │
    │                         ▼
    │                    collect & aggregate results
    │
    └─ check_remote ──▶ SSH connectivity test
```

---

## Limitations

- **No streaming:** Remote execution returns results after completion (no incremental output)
- **No interactive prompts:** Remote CLIO runs in `--input --exit` mode only
- **SSH required:** No support for other transport protocols
- **Single model per task:** Each remote execution uses one model (can differ per device in parallel)
