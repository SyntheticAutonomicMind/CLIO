# CLIO Dependencies

## Philosophy

CLIO is designed to work with **minimal dependencies** using standard Unix tools. We deliberately avoid:

- Heavy framework dependencies
- Node.js/npm/JavaScript ecosystems
- Python/pip dependencies
- CPAN modules (zero external Perl dependencies)
- Docker-only deployment

**Result:** CLIO works on a clean Unix system with Perl 5.32+ installed.

---

## Quick Verification

```bash
./check-deps
```

This checks Perl version, required system commands, and optional tools.

---

## Required Dependencies

### Perl 5.32 or Higher

CLIO uses **zero external CPAN modules**. Everything works with core modules included in Perl 5.32+.

```bash
perl -v
```

| Platform | Command |
|----------|---------|
| macOS | Pre-installed or `brew install perl` |
| Debian/Ubuntu | `sudo apt install perl` |
| RHEL/Fedora | `sudo dnf install perl` |
| Arch Linux | `sudo pacman -S perl` |

### System Commands

All typically pre-installed on Unix-like systems:

| Command | Purpose | Package |
|---------|---------|---------|
| `git` | Version control operations | git |
| `curl` | HTTP requests, API calls, updates | curl |
| `stty` | Terminal mode control | coreutils |
| `tput` | Terminal capability queries | ncurses-bin |
| `tar` | Archive extraction for updates | tar |

**Verify:**
```bash
which git curl stty tput tar
```

**Install if missing:**

```bash
# Debian/Ubuntu
sudo apt install git curl coreutils ncurses-bin tar

# RHEL/Fedora
sudo dnf install git curl coreutils ncurses tar

# Arch Linux
sudo pacman -S git curl coreutils ncurses tar

# macOS
xcode-select --install  # Includes git; others are pre-installed
```

---

## Perl Core Modules Used

No installation needed - these ship with Perl 5.32+:

| Module | Purpose |
|--------|---------|
| `JSON::PP` | JSON parsing (auto-upgraded to JSON::XS if available) |
| `File::*` | File operations (Spec, Path, Basename, Copy, Find, Temp) |
| `Time::HiRes`, `Time::Piece` | Time operations |
| `Digest::MD5` | Checksums |
| `Encode` | UTF-8 handling |
| `POSIX` | System interfaces, process groups |
| `Cwd` | Directory operations |
| `Getopt::Long` | Command-line parsing |
| `Term::ReadKey` | Terminal input (bundled with CLIO in `lib/`) |

---

## Optional Performance Enhancement

| Module | Purpose | Installation |
|--------|---------|-------------|
| `JSON::XS` | 10x faster JSON parsing | `cpan JSON::XS` |

CLIO's `CLIO::Util::JSON` module automatically detects and uses the fastest JSON encoder available (JSON::XS > Cpanel::JSON::XS > JSON::PP fallback).

---

## Optional Tools

### Terminal Multiplexers (Auto-Detected)

When running inside a multiplexer, CLIO executes terminal commands in a separate pane:

| Multiplexer | Detection |
|-------------|-----------|
| tmux | `$TMUX` environment variable |
| GNU Screen | `$STY` environment variable |
| Zellij | `$ZELLIJ_SESSION_NAME` environment variable |

### MCP (Model Context Protocol) Support

MCP connects CLIO to external tool servers. At least one runtime is needed:

| Command | Purpose | Installation |
|---------|---------|-------------|
| `npx` | Run MCP servers from npm | Comes with Node.js |
| `uvx` | Run Python-based MCP servers | `pip install uv` |
| `python3` | Run Python MCP servers | Usually pre-installed |

If none are found, MCP is silently disabled. See [MCP.md](MCP.md) for details.

### SSH (for Remote Execution)

| Command | Purpose |
|---------|---------|
| `ssh` | Remote system connectivity |
| `rsync` | Efficient file transfer to remotes |

Required only if using the `remote_execution` tool. See [REMOTE_EXECUTION.md](REMOTE_EXECUTION.md).

### Docker (for Container Sandbox)

Required only for `clio-container` sandboxed execution:

| Requirement | Purpose |
|-------------|---------|
| Docker Engine or Docker Desktop | Container runtime |
| `docker` CLI | Container management |

See [SANDBOX.md](SANDBOX.md).

---

## Troubleshooting

### "stty: command not found" or "tput: command not found"

Terminal input/output behaves incorrectly:
```bash
sudo apt install coreutils ncurses-bin  # Debian/Ubuntu
sudo dnf install coreutils ncurses      # RHEL/Fedora
```

### "curl: command not found"

Updates, web search, and API calls fail:
```bash
sudo apt install curl  # Debian/Ubuntu
sudo dnf install curl  # RHEL/Fedora
brew install curl      # macOS
```

### "git: command not found"

Version control operations fail:
```bash
sudo apt install git   # Debian/Ubuntu
sudo dnf install git   # RHEL/Fedora
xcode-select --install # macOS
```
