# CLIO Sandbox Mode

> **For the full security architecture overview, see [SECURITY.md](SECURITY.md).**
> This document covers technical details and container isolation.

CLIO provides two levels of isolation to help protect your system:

| Mode | Method | Protection Level |
|------|--------|------------------|
| **Soft Sandbox** | `--sandbox` flag | Prevents accidental file access |
| **Container Sandbox** | `clio-container` script | True OS-level isolation |

For details on soft sandbox restrictions and behavior, see [SECURITY.md Layer 6](SECURITY.md#layer-6-sandbox-mode).

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
| Conversational AI, quick questions | `--chat` flag |
| Trusted local environment | No sandbox needed |
| Exploring unfamiliar codebase | `--sandbox` flag |
| Working on sensitive project | `--sandbox` flag |
| Bot or automation deployment | `--disable` specific tools |
| Read-only analysis | `--enable file_operations,code_intelligence` |
| Maximum security required | `clio-container` |
| CI/CD pipelines | Container image directly |

## Additional Security Features

These features work independently of sandbox mode but complement it:

### Tool Filtering

CLIO can restrict which tools are available using `--enable` (allowlist) or `--disable` (blocklist):

```bash
# Only allow file operations in sandbox
clio --sandbox --enable file_operations,version_control --new

# Block remote and web access (similar to sandbox but without path restrictions)
clio --disable web_operations,remote_execution --new
```

Tool filtering is applied at registration time - disabled tools never load, so the AI agent cannot call them at all. This is a hard restriction, unlike sandbox mode which gates specific operations within tools.

For persistent configuration:
```
/config set disabled_tools web_operations,remote_execution
```

### Secret Redaction

CLIO automatically detects and redacts secrets (API keys, tokens, passwords) from AI context. Configure the level:

```
/config set redact_level standard   # Redacts PII, crypto, API keys, tokens
/config set redact_level pii        # Only PII (default)
/config set redact_level off        # Disable redaction
```

See `CLIO::Security::SecretRedactor` for details.

### Invisible Character Filtering

CLIO strips invisible Unicode characters (zero-width spaces, directional overrides, etc.) from user input to prevent prompt injection attacks via invisible character sequences.

See `CLIO::Security::InvisibleCharFilter` for details.

### Path Authorization

Outside sandbox mode, CLIO uses a session-level path authorization system (`CLIO::Security::PathAuthorizer`) to track which paths the agent has been granted access to, preventing accidental access to sensitive system directories.

---

## Security Best Practices

1. **Review changes before committing** - Use `git diff` before `git commit`
2. **Use sandbox for unfamiliar projects** - Extra protection when exploring new codebases
3. **Don't rely solely on soft sandbox** - It prevents accidents, not attacks
4. **Use containers for sensitive work** - When mistakes could be costly
5. **Consider network isolation** - Container doesn't restrict network by default
6. **Enable secret redaction** - Prevents accidental API key leakage to AI providers

## See Also

- [USER_GUIDE.md](USER_GUIDE.md) - General usage guide
- [REMOTE_EXECUTION.md](REMOTE_EXECUTION.md) - Remote execution (blocked in sandbox)
- [SECURITY.md](../SECURITY.md) - Security policy
