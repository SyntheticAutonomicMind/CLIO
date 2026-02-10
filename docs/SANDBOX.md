# CLIO Sandbox Mode

CLIO provides two levels of isolation to help protect your system:

| Mode | Method | Protection Level |
|------|--------|------------------|
| **Soft Sandbox** | `--sandbox` flag | Prevents accidental file access |
| **Container Sandbox** | `clio-container` script | True OS-level isolation |

---

## Soft Sandbox (`--sandbox` flag)

The `--sandbox` flag restricts file access to your project directory, helping prevent accidental changes outside your workspace.

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

### Limitations

**Important:** The soft sandbox does NOT restrict terminal operations.

The agent can still execute arbitrary shell commands, which means:
- It can read files outside the project via `cat`, `head`, etc.
- It can write files outside the project via `echo`, `>`, etc.
- It can access network via `curl`, `wget`, etc.
- It can execute any program on your system

**The soft sandbox prevents accidental access, not malicious behavior.**

For true isolation, use the `clio-container` script.

---

## Container Sandbox (`clio-container`)

For complete filesystem isolation, use the `clio-container` wrapper script. It runs CLIO inside a Docker container that can only access your project directory.

### Requirements

- Docker installed and running
- macOS: Docker Desktop or [Colima](https://github.com/abiosoft/colima)
- Linux: Docker Engine

### Usage

```bash
# Run CLIO sandboxed in current directory
./clio-container

# Run in a specific project
./clio-container ~/projects/myapp

# Resume a session
./clio-container ~/projects/myapp --resume

# Pass any CLIO flags
./clio-container ~/projects/myapp --debug --new
```

### What It Does

1. **Checks Docker** - Errors if Docker isn't installed or running
2. **Creates auth volume** - Persists your API authentication between runs
3. **Pulls latest image** - Updates to newest CLIO version
4. **Starts container** - With security restrictions and `--sandbox` enabled
5. **Cleans up** - Container destroyed on exit, auth preserved

### Security Properties

| Property | Status |
|----------|--------|
| Filesystem access | [OK] Limited to mounted project directory only |
| Sandbox mode | [OK] Automatically enabled |
| Container capabilities | [OK] All dropped |
| Privilege escalation | [OK] Blocked |
| Auth persistence | [OK] Via Docker volume |
| Network access | [WARN] Unrestricted |

### Container Image

```
ghcr.io/syntheticautonomicmind/clio:latest
```

Supports: `linux/amd64` (Intel/AMD) and `linux/arm64` (Apple Silicon, ARM)

### Manual Docker Usage

If you prefer to run Docker directly:

```bash
# Create auth volume (once)
docker volume create clio-auth

# Run CLIO
docker run -it --rm \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    -v "$(pwd)":/workspace \
    -v clio-auth:/root/.clio \
    -w /workspace \
    ghcr.io/syntheticautonomicmind/clio:latest \
    --sandbox --new
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `CLIO_IMAGE` | Override container image | `ghcr.io/syntheticautonomicmind/clio:latest` |

Example: `CLIO_IMAGE=clio:dev ./clio-container`

---

## Technical Implementation

### Soft Sandbox Path Resolution

The soft sandbox resolves all paths to absolute form and checks containment:

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

---

## When to Use Each Mode

| Scenario | Recommendation |
|----------|----------------|
| Trusted local environment | No sandbox needed |
| Exploring unfamiliar codebase | `--sandbox` flag |
| Working on sensitive project | `--sandbox` flag |
| Maximum security required | `clio-container` |
| CI/CD pipelines | Container image directly |

## Security Best Practices

1. **Review changes before committing** - Use `git diff` before `git commit`
2. **Use sandbox for unfamiliar projects** - Extra protection when exploring new codebases
3. **Don't rely solely on soft sandbox** - It prevents accidents, not attacks
4. **Use containers for sensitive work** - When mistakes could be costly
5. **Consider network isolation** - Container doesn't restrict network by default

## See Also

- [USER_GUIDE.md](USER_GUIDE.md) - General usage guide
- [REMOTE_EXECUTION.md](REMOTE_EXECUTION.md) - Remote execution (blocked in sandbox)
