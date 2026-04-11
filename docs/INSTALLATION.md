# CLIO Installation Guide

**Install CLIO and get to a working first session quickly.**

CLIO is a terminal-native AI coding tool. It runs in your shell, uses real tools to work with files and commands, and fits terminal-first workflows. This guide focuses on the fastest path from install to first use.

---

## Table of Contents

1. [Choose Your Install Path](#choose-your-install-path)
2. [System Requirements](#system-requirements)
3. [Quick Installation](#quick-installation)
4. [Docker Installation](#docker-installation)
5. [Installation Options](#installation-options)
6. [First-Time Configuration](#first-time-configuration)
7. [Verification](#verification)
8. [Uninstallation](#uninstallation)
9. [Troubleshooting](#troubleshooting)
10. [Platform-Specific Notes](#platform-specific-notes)
11. [Next Steps](#next-steps)

---

## Choose Your Install Path

Most people should use one of these:

- **Homebrew** - easiest on macOS and Linux with Homebrew installed
- **Standard install** - best if you want `clio` available system-wide
- **User install** - best if you do not want to use `sudo`
- **Docker** - best if you want to try CLIO without installing Perl locally

If you already have GitHub Copilot, the fastest path after installation is:

```bash
clio --new
/api login
```

Then open any repository and give CLIO a real task.

---

## System Requirements

### Operating System

| Platform | Status |
|----------|--------|
| **macOS** 10.14+ | Fully Supported |
| **Linux** (Ubuntu 18.04+, Debian 10+, Fedora 30+, Arch) | Fully Supported |
| **Windows** (WSL or Cygwin) | Experimental |

### Required Software

**Perl 5.32+** (usually pre-installed on macOS/Linux):
```bash
perl --version
```

**Git 2.0+:**
```bash
git --version
```

### Perl Modules

CLIO uses only **core Perl modules** - no CPAN dependencies:

- `JSON::PP` (core since 5.14)
- `HTTP::Tiny` (core since 5.14)
- `MIME::Base64` (core)
- `File::Spec`, `File::Path` (core)
- `Time::HiRes` (core)

### AI Provider

You need at least one AI provider. See [PROVIDERS.md](PROVIDERS.md) for the full list.

**Common choices:**
- **GitHub Copilot** - easiest starting point, access to multiple models
- **Local models** - llama.cpp, LM Studio, or SAM
- **API providers** - OpenAI, Google, DeepSeek, OpenRouter, MiniMax, DashScope

---

## Quick Installation

### Homebrew

```bash
brew tap SyntheticAutonomicMind/homebrew-SAM
brew install clio
```

### Standard Install (Recommended)

```bash
# Clone the repository
git clone https://github.com/SyntheticAutonomicMind/CLIO.git
cd CLIO

# Install system-wide
sudo ./install.sh

# Start CLIO
clio --new
```

CLIO installs to `/opt/clio` with a symlink at `/usr/local/bin/clio`.

### User Install (No Sudo)

```bash
./install.sh --user
```

Installs to `~/.local/clio`. Ensure `~/.local/bin` is in your PATH:
```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

---

## Docker Installation

**Run CLIO in a container - no local Perl required:**

```bash
docker run -it --rm \
    -v "$(pwd)":/workspace \
    -v clio-auth:/root/.clio \
    -w /workspace \
    ghcr.io/syntheticautonomicmind/clio:latest \
    --new
```

### Convenience Wrapper

```bash
git clone https://github.com/SyntheticAutonomicMind/CLIO.git
cd CLIO
./clio-container ~/projects/myapp
```

### Image Tags

| Tag | Description |
|-----|-------------|
| `:latest` | Most recent stable release |
| `:YYYYMMDD.N` | Specific version |
| `:sha-XXXXXX` | Specific Git commit |

See [SANDBOX.md](SANDBOX.md) for security details.

---

## Installation Options

| Option | Command | Location |
|--------|---------|----------|
| System-wide (default) | `sudo ./install.sh` | `/opt/clio` |
| Custom directory | `sudo ./install.sh /usr/local/clio` | `/usr/local/clio` |
| User install | `./install.sh --user` | `~/.local/clio` |
| No symlink | `sudo ./install.sh --no-symlink` | `/opt/clio` (no PATH) |
| Custom symlink | `sudo ./install.sh --symlink /usr/bin/clio` | Custom symlink path |

---

## First-Time Configuration

After installation, start CLIO:

```bash
clio --new
```

### GitHub Copilot (Recommended)

This is the easiest way to get started:

```bash
/api set provider github_copilot
/api login
# Browser opens -> authorize -> done
```

### OpenAI / Other API Providers

```bash
/api set provider openai
/api set key sk-...your-key...
/config save
```

### Local Models (llama.cpp, LM Studio)

```bash
# Ensure your local server is running first
/api set provider llama.cpp
# No key needed for local providers
```

### View Configuration

```bash
/api show
```

For detailed provider setup instructions, see [PROVIDERS.md](PROVIDERS.md).

---

## Verification

### Check Installation

```bash
# Verify CLIO is in PATH
which clio

# Check help
clio --help

# Verify Perl modules
perl -MJSON::PP -e 'print "OK\n"'
perl -MHTTP::Tiny -e 'print "OK\n"'
```

### Test CLIO

```bash
clio --new --input "Hello, what's 2+2?" --exit
```

### Test a real workflow

Inside a repository, try something like:

```text
Read this project and explain how configuration is loaded.
```

Or:

```text
Find the code path that handles authentication failures.
```

---

## Uninstallation

```bash
# Remove installation
sudo rm -rf /opt/clio
sudo rm /usr/local/bin/clio

# Remove user data (optional)
rm -rf ~/.clio
```

---

## Troubleshooting

### "Permission denied"

```bash
# Use sudo for system install
sudo ./install.sh

# Or use user install
./install.sh --user
```

### "perl: command not found"

| Platform | Install Command |
|----------|-----------------|
| macOS | `brew install perl` |
| Ubuntu/Debian | `sudo apt-get install perl` |
| Fedora/RHEL | `sudo dnf install perl` |
| Arch | `sudo pacman -S perl` |

### CLIO not found after `--user` install

Make sure `~/.local/bin` is in your PATH:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Add it to your shell profile if needed.

---

## Platform-Specific Notes

### macOS

Perl is usually preinstalled. Homebrew installation is the easiest path.

### Linux

Most distributions already include Perl and Git. Standard or user install both work well.

### Windows

Use WSL for the smoothest experience. Native Windows support is improving, but WSL remains the better option for now.

---

## Next Steps

- Read the [User Guide](USER_GUIDE.md) for day-to-day usage
- Check [PROVIDERS.md](PROVIDERS.md) to configure other AI providers
- Explore [FEATURES.md](FEATURES.md) for a full tour of CLIO's capabilities
- Review [SECURITY.md](SECURITY.md) and [SANDBOX.md](SANDBOX.md) if you want tighter controls
