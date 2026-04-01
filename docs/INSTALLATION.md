# CLIO Installation Guide

**Getting CLIO up and running on your system**

---

## Table of Contents

1. [System Requirements](#system-requirements)
2. [Quick Installation](#quick-installation)
3. [Docker Installation](#docker-installation)
4. [Installation Options](#installation-options)
5. [First-Time Configuration](#first-time-configuration)
6. [Verification](#verification)
7. [Uninstallation](#uninstallation)
8. [Troubleshooting](#troubleshooting)
9. [Platform-Specific Notes](#platform-specific-notes)

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

You need at least one AI provider. See [PROVIDERS.md](PROVIDERS.md) for the complete list.

**Quick options:**
- **GitHub Copilot** - Recommended, access to multiple models
- **Local models** (free) - llama.cpp, LM Studio, or SAM
- **API providers** - OpenAI, Anthropic, Google, DeepSeek, OpenRouter, MiniMax

---

## Quick Installation

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

After installation, configure your AI provider:

```bash
clio --new
```

### GitHub Copilot (Recommended)

```bash
/api set provider github_copilot
/api login
# Browser opens -> authorize -> done!
```

### OpenAI / Anthropic / Other API Providers

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

**For detailed provider setup instructions, see [PROVIDERS.md](PROVIDERS.md).**

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

### "clio: command not found"

```bash
# Check symlink
ls -l /usr/local/bin/clio

# Create manually if missing
sudo ln -s /opt/clio/clio /usr/local/bin/clio

# Or add to PATH
export PATH="/opt/clio:$PATH"
```

### "API authentication failed"

- Verify API key is correct
- For GitHub Copilot: run `/api login` again
- Check provider subscription is active
- See [PROVIDERS.md](PROVIDERS.md) for provider-specific help

### "Session directory not writable"

```bash
sudo chmod 755 /opt/clio/sessions
sudo chown $USER /opt/clio/sessions
```

---

## Platform-Specific Notes

### macOS

Both system Perl (`/usr/bin/perl`) and Homebrew Perl work fine.

### Linux with SELinux

```bash
# Check status
getenforce

# If enabled, set context
sudo chcon -R -t bin_t /opt/clio/clio
```

### Windows (WSL)

1. Install WSL: `wsl --install`
2. Open Ubuntu terminal
3. Follow Linux installation steps

---

## Next Steps

- **[PROVIDERS.md](PROVIDERS.md)** - Complete provider configuration guide
- **[USER_GUIDE.md](USER_GUIDE.md)** - Learn to use CLIO effectively
- **[FEATURES.md](FEATURES.md)** - Explore all capabilities
