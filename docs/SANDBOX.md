# CLIO Sandbox Mode

CLIO provides two levels of sandbox isolation to help protect your system from unintended changes.

## Overview

| Mode | Flag | Protection | Use Case |
|------|------|------------|----------|
| **Soft Sandbox** | `--sandbox` | Application-level | Prevent accidental file access outside project |
| **Docker Sandbox** | `scripts/clio-sandbox.sh` | OS-level | True isolation for maximum security |

## Soft Sandbox (`--sandbox` flag)

The `--sandbox` flag enables application-level restrictions that prevent CLIO from accessing files outside your project directory.

### Usage

```bash
# Start new session with sandbox enabled
clio --sandbox --new

# Resume session with sandbox enabled  
clio --sandbox --resume
```

### What Gets Restricted

| Tool | Restriction |
|------|-------------|
| **file_operations** | All paths must be within project directory |
| **remote_execution** | Completely blocked |
| **version_control** | Repository path must be within project |
| **terminal_operations** | **NOT restricted** (see Limitations) |

### Limitations

**Important:** The soft sandbox does NOT restrict terminal operations.

The agent can still execute arbitrary shell commands, which means:
- It can read files outside the project via `cat`, `head`, etc.
- It can write files outside the project via `echo`, `>`, etc.
- It can access network via `curl`, `wget`, etc.
- It can execute any program on your system

**The soft sandbox prevents accidental access, not malicious behavior.**

For true isolation, use the Docker sandbox (see below).

### Error Messages

When the agent tries to access a path outside the project:

```
Sandbox mode: Access denied to '/etc/passwd' - path is outside project directory '/home/user/myproject'
```

When remote execution is attempted:

```
Sandbox mode: Remote execution is disabled.

The --sandbox flag blocks all remote operations. This is a security feature to prevent the agent from reaching outside the local project.
```

## Docker Sandbox (True Isolation)

For complete isolation, run CLIO inside a Docker container that only has access to your project directory.

### Prerequisites

- Docker or rootless Docker installed
- CLIO Docker image built

### Building the Image

```bash
# From CLIO project root
docker build -t clio-sandbox:latest -f scripts/Dockerfile.sandbox .
```

### Usage

```bash
# Run CLIO sandboxed in a specific project
./scripts/clio-sandbox.sh ~/projects/myapp --new

# Run in current directory
./scripts/clio-sandbox.sh --new

# Resume a session
./scripts/clio-sandbox.sh ~/projects/myapp --resume
```

### Security Properties

| Property | Status |
|----------|--------|
| Filesystem access | ✅ Limited to project directory only |
| Network access | ⚠️ Unrestricted (data exfiltration possible) |
| Container capabilities | ✅ All dropped |
| Privilege escalation | ✅ Blocked |
| Auth persistence | ✅ Stored in named Docker volume |

### How It Works

The Docker sandbox:

1. Mounts your project directory as `/workspace` in the container
2. Drops all Linux capabilities
3. Prevents privilege escalation
4. Persists CLIO config/auth in a named volume (`clio-sandbox-auth`)
5. Destroys the container on exit (ephemeral)

### Rootless Docker (Recommended)

For additional security on Linux, use [rootless Docker](https://docs.docker.com/engine/security/rootless/):

```bash
# Install prerequisites
sudo apt-get install uidmap dbus-user-session

# Install rootless Docker
dockerd-rootless-setuptool.sh install

# Configure shell
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
```

### Network Isolation

The Docker sandbox does NOT restrict network access by default. The agent can:
- Make HTTP requests to external servers
- Download files from the internet
- Potentially exfiltrate data

For network isolation, consider:
- Running on an isolated VM
- Using Docker network restrictions
- Firewall rules to block container traffic

## Choosing the Right Mode

| If you need... | Use... |
|----------------|--------|
| Quick protection against accidents | `--sandbox` flag |
| True filesystem isolation | Docker sandbox |
| Complete isolation (incl. network) | Docker on isolated VM |
| Zero restrictions (trusted environment) | No sandbox (default) |

## Security Best Practices

1. **Don't run untrusted code** - Even in a sandbox, AI agents can make mistakes
2. **Review changes before committing** - Use `git diff` before `git commit`
3. **Use sandbox for unfamiliar projects** - Extra protection when exploring new codebases
4. **Consider Docker for sensitive work** - When mistakes could be costly
5. **Back up important data** - Sandboxes reduce but don't eliminate risk

## Technical Implementation

### Soft Sandbox Path Resolution

The soft sandbox resolves all paths to absolute form and checks if they start with the project directory:

```perl
# Path must be exactly project_dir or start with project_dir/
my $is_inside = ($resolved_path eq $project_dir) ||
                ($resolved_path =~ /^\Q$project_dir\E\//);
```

This handles:
- Relative paths (`./file`, `subdir/file`)
- Absolute paths (`/home/user/project/file`)
- Tilde expansion (`~/project/file`)
- Symlink resolution

### Docker Sandbox Container Security

The container runs with:

```bash
docker run --rm -it \
    --cap-drop ALL \                    # Drop all capabilities
    --security-opt no-new-privileges \  # Prevent privilege escalation
    -v "$PROJECT_PATH":/workspace:rw \  # Only project is mounted
    -v "$AUTH_VOLUME":/root/.clio \     # Persist auth
    -w /workspace \
    clio-sandbox:latest \
    clio "$@"
```

## See Also

- [INSTALLATION.md](INSTALLATION.md) - Installing CLIO
- [USER_GUIDE.md](USER_GUIDE.md) - General usage guide
- [REMOTE_EXECUTION.md](REMOTE_EXECUTION.md) - Remote execution (blocked in sandbox)
