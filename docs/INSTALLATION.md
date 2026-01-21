# CLIO Installation Guide

**Detailed installation instructions for CLIO (Command Line Intelligence Orchestrator)**

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Table of Contents

1. [System Requirements](#system-requirements)
2. [Quick Installation](#quick-installation)
3. [Installation Options](#installation-options)
4. [Configuration](#configuration)
5. [Verification](#verification)
6. [Uninstallation](#uninstallation)
7. [Troubleshooting](#troubleshooting)
8. [Platform-Specific Notes](#platform-specific-notes)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## System Requirements

### Operating System

**Supported:**
- **macOS**: 10.14 (Mojave) or later
- **Linux**: Any modern distribution (Ubuntu 18.04+, Debian 10+, Fedora 30+, Arch, etc.)

**Experimental:**
- **Windows**: Via WSL (Windows Subsystem for Linux) or Cygwin

### Required Software

**Perl:**
- Version 5.20 or higher
- Standard Perl installation (usually pre-installed on macOS and Linux)

**Check your Perl version:**
```bash
perl --version
```

You should see output like:
```
This is perl 5, version 34, subversion 0 (v5.34.0) built for darwin-thread-multi-2level
...
```

**Git:**
- Required for version control operations
- Any recent version (2.0+)

**Check Git installation:**
```bash
git --version
```

### Required Perl Modules

CLIO uses only **core Perl modules** (no CPAN dependencies required):

- `JSON` - JSON parsing (core since 5.14)
- `HTTP::Tiny` - HTTP client (core since 5.14)
- `MIME::Base64` - Base64 encoding (core)
- `File::Spec` - Path manipulation (core)
- `File::Path` - Directory operations (core)
- `Time::HiRes` - High-resolution timers (core)

These are included in all modern Perl installations.

### AI Provider Account

You need **one of the following**:

**GitHub Copilot** (Default & Recommended)
- GitHub Copilot subscription (Individual ~$10/month or Business ~$19/month)
- API token from GitHub Copilot settings
- Provides access to: GPT-4o, Claude 3.5 Sonnet, o1 models

**OpenAI**
- OpenAI API account
- API key from OpenAI platform
- Pay-as-you-go pricing

**DeepSeek**
- DeepSeek API account
- API key from DeepSeek platform
- Cost-effective code-focused AI

**llama.cpp** (Local)
- llama.cpp server running locally
- No API key required
- Fully local inference

**SAM** (Local)
- SAM local installation
- No API key required
- Integrated with CLIO

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Quick Installation

**For most users (macOS and Linux):**

```bash
# 1. Clone the repository
git clone https://github.com/fewtarius/clio.git
cd clio

# 2. Run installer with sudo
sudo ./install.sh

# 3. Start CLIO and configure
./clio --new

# 4. Inside CLIO, configure your provider
: /api provider github_copilot
: /api key YOUR_GITHUB_COPILOT_TOKEN  
: /config save

# 4. Run CLIO
clio --new
```

That's it! CLIO is now installed to `/opt/clio` with a symlink at `/usr/local/bin/clio`.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Installation Options

The `install.sh` script provides several installation options:

### Standard Installation (System-wide)

**Default location: `/opt/clio`**

```bash
sudo ./install.sh
```

This installs:
- CLIO executable to `/opt/clio/clio`
- Library files to `/opt/clio/lib/`
- Sessions directory to `/opt/clio/sessions/`
- Symlink at `/usr/local/bin/clio`

### Custom Installation Directory

```bash
sudo ./install.sh /usr/local/clio
```

Installs to `/usr/local/clio` instead of `/opt/clio`.

### User Installation (No Sudo Required)

```bash
./install.sh --user
```

Installs to `~/.local/clio` with symlink at `~/.local/bin/clio`.

**Note:** Make sure `~/.local/bin` is in your `$PATH`:
```bash
# Add to ~/.bashrc or ~/.zshrc
export PATH="$HOME/.local/bin:$PATH"
```

### Installation Without Symlink

```bash
sudo ./install.sh --no-symlink
```

Installs files but doesn't create `/usr/local/bin/clio` symlink. Useful if you want to manage the PATH yourself.

To run CLIO:
```bash
/opt/clio/clio --new
```

### Custom Symlink Path

```bash
sudo ./install.sh --symlink /usr/bin/clio
```

Creates symlink at `/usr/bin/clio` instead of `/usr/local/bin/clio`.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Configuration

### First-Time Setup

After installation, start CLIO and configure your AI provider using the `/api` and `/config` commands:

```bash
# Start CLIO
./clio --new
```

#### Configuring GitHub Copilot

**1. Get your token:**
- Open VS Code or your GitHub Copilot-enabled editor  
- Go to Copilot settings
- Generate/copy API token

**2. Configure CLIO:**

```bash
# Inside CLIO:
: /api provider github_copilot
: /api key YOUR_GITHUB_COPILOT_TOKEN
: /config save

# CLIO will confirm:
# Provider set to: github_copilot
# API key configured
# Configuration saved to ~/.clio/config.json
```

#### Configuring SAM (Local Model Server)

If you're running SAM locally:

```bash
# Inside CLIO:
: /api provider sam
: /api base http://localhost:8080/v1/chat/completions
: /api key YOUR_SAM_API_TOKEN
: /config save
```

#### Configuring OpenAI

```bash
# Inside CLIO:
: /api provider openai
: /api key YOUR_OPENAI_API_KEY
: /config save
```

### Configuration File

CLIO saves your configuration to `~/.clio/config.json`:

```json
{
  "provider": "github_copilot",
  "api_key": "your_api_key_here"
}
```

**Note:** Only explicitly-set values are saved. Provider-specific defaults (api_base, model) are loaded automatically from the provider definition.

### Viewing Configuration

Check your current configuration:

```bash
: /config show

# Output:
# Current Configuration:
#   Provider: github_copilot
#   API Base URL: https://api.githubcopilot.com/chat/completions
#   Model: gpt-4o
#   Working Directory: /Users/you/projects
```

### Available Providers

List all available providers:

```bash
: /api providers

# Output shows all built-in providers:
# - github_copilot (GitHub Copilot API - default)
# - openai (OpenAI API)
# - deepseek (DeepSeek API)
# - llama.cpp (Local llama.cpp server)
# - sam (Local SAM server)
```

### Switching Providers

You can switch providers at any time:

```bash
: /api provider sam
: /api key NEW_API_KEY
: /config save
```

Your new configuration persists across sessions.

### Advanced Configuration

#### Debug Mode

Enable debug logging from CLIO:

```bash
: /debug on
```

Or via command-line flag:

```bash
./clio --debug
```

#### Custom Working Directory

Set the default working directory for file operations:

```bash
: /config working_directory /path/to/project
: /config save
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Verification

### Verify Installation

**1. Check CLIO is in PATH:**
```bash
which clio
```

Expected output:
```
/usr/local/bin/clio
```

**2. Check version/help:**
```bash
clio --help
```

Expected output:
```
CLIO - Command Line Intelligence Orchestrator
AI-Powered Development Assistant

USAGE:
    clio [OPTIONS]

OPTIONS:
    --new              Start a new session
    --resume [ID]      Resume a session (most recent if no ID provided)
    --debug            Enable debug output
    --input TEXT       Send input directly (for scripting)
    --exit             Exit after processing input
    --help             Show this help message
...
```

**3. Verify Perl modules:**
```bash
perl -MJSON -e 'print "JSON OK\n"'
perl -MHTTP::Tiny -e 'print "HTTP::Tiny OK\n"'
perl -MMIME::Base64 -e 'print "MIME::Base64 OK\n"'
```

All should print "OK".

**4. Test basic functionality:**
```bash
echo "hello from CLIO" | clio --new --input "What did I say?" --exit
```

If CLIO is configured correctly, it should respond based on your input.

### Verify Configuration

**Check environment variables:**
```bash
echo $GITHUB_COPILOT_TOKEN
# or for other providers:
echo $OPENAI_API_KEY
echo $DEEPSEEK_API_KEY
```

Should print your token/key (not empty).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Uninstallation

### Using Uninstall Script

```bash
sudo ./uninstall.sh
```

This removes:
- Installation directory (e.g., `/opt/clio`)
- Symlink at `/usr/local/bin/clio`
- Does NOT remove sessions or user data

### Manual Uninstallation

```bash
# Remove installation directory
sudo rm -rf /opt/clio

# Remove symlink
sudo rm /usr/local/bin/clio

# Optional: Remove user data
rm -rf ~/.clio
```

### Removing Configuration

```bash
# Remove environment variables from shell profile
# Edit ~/.bashrc or ~/.zshrc and remove lines like:
# export GITHUB_COPILOT_TOKEN="..."

# Remove config file
rm -rf ~/.clio/config.yaml

# Remove session data
rm -rf ~/.clio/sessions
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Troubleshooting

### Installation Issues

#### Problem: "Permission denied"

**Cause:** Installation requires sudo for system directories.

**Solution:**
```bash
sudo ./install.sh
```

Or use user installation:
```bash
./install.sh --user
```

#### Problem: "perl: command not found"

**Cause:** Perl is not installed or not in PATH.

**Solution:**

**macOS:**
Perl should be pre-installed. If not:
```bash
brew install perl
```

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get install perl
```

**Fedora/RHEL:**
```bash
sudo dnf install perl
```

**Arch Linux:**
```bash
sudo pacman -S perl
```

#### Problem: "git: command not found"

**Cause:** Git is not installed.

**Solution:**

**macOS:**
```bash
brew install git
# or use Xcode command line tools:
xcode-select --install
```

**Ubuntu/Debian:**
```bash
sudo apt-get install git
```

**Fedora/RHEL:**
```bash
sudo dnf install git
```

#### Problem: "Can't locate JSON.pm in @INC"

**Cause:** Perl core modules not installed (unusual but possible).

**Solution:**

**Ubuntu/Debian:**
```bash
sudo apt-get install perl-modules-5.* libjson-perl
```

**macOS:**
```bash
# JSON should be in core Perl
# If missing, install via cpanm:
cpan JSON
```

### Path Issues

#### Problem: "clio: command not found" after installation

**Cause:** Symlink not created or not in PATH.

**Solution:**

**Check if symlink exists:**
```bash
ls -l /usr/local/bin/clio
```

**If missing, create manually:**
```bash
sudo ln -s /opt/clio/clio /usr/local/bin/clio
```

**Check if /usr/local/bin is in PATH:**
```bash
echo $PATH | grep /usr/local/bin
```

**If not in PATH, add it:**
```bash
# Add to ~/.bashrc or ~/.zshrc
export PATH="/usr/local/bin:$PATH"
source ~/.bashrc
```

### Configuration Issues

#### Problem: "API authentication failed"

**Cause:** Token not set or invalid.

**Solution:**

**Verify token is set:**
```bash
echo $GITHUB_COPILOT_TOKEN
```

**If empty:**
```bash
export GITHUB_COPILOT_TOKEN="your_token_here"
```

**If still failing:**
- Verify token is correct (copy/paste carefully)
- Check if token has expired
- Generate new token from provider settings

#### Problem: "Session directory not writable"

**Cause:** Permission issues with session directory.

**Solution:**

**Check permissions:**
```bash
ls -ld /opt/clio/sessions
```

**Fix permissions:**
```bash
sudo chmod 755 /opt/clio/sessions
sudo chown $USER /opt/clio/sessions
```

**Or use custom directory:**
```bash
export CLIO_SESSION_DIR="$HOME/.clio/sessions"
mkdir -p $HOME/.clio/sessions
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Platform-Specific Notes

### macOS

**Gatekeeper:**
On first run, macOS may block CLIO as an unsigned application. This is not an issue for command-line tools, but if you encounter problems:

```bash
# Allow execution
chmod +x /opt/clio/clio
```

**Homebrew Perl:**
If you're using Homebrew's Perl instead of system Perl:
```bash
# Verify which Perl is used
which perl

# Should show /usr/bin/perl (system) or /usr/local/bin/perl (Homebrew)
```

Both work fine with CLIO.

### Linux

**SELinux:**
On RHEL/Fedora/CentOS with SELinux, you may need to set proper contexts:

```bash
# Check SELinux status
sestatus

# If enforcing, set contexts:
sudo chcon -R -t bin_t /opt/clio/clio
sudo chcon -R -t lib_t /opt/clio/lib
```

**AppArmor:**
On Ubuntu with AppArmor, CLIO should work without additional configuration. If you encounter issues:

```bash
# Check AppArmor status
sudo aa-status

# Disable for troubleshooting:
sudo systemctl stop apparmor
```

### Windows (WSL)

**WSL1 vs WSL2:**
CLIO works on both WSL1 and WSL2, but WSL2 is recommended for better performance.

**Installation:**
```bash
# In WSL terminal
git clone https://github.com/fewtarius/clio.git
cd clio
./install.sh --user
```

**Note:** Use `--user` installation to avoid permission issues with Windows filesystem.

**Path Configuration:**
Make sure `~/.local/bin` is in PATH:
```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Next Steps

After installation:

1. **Read the User Guide**: [docs/USER_GUIDE.md](USER_GUIDE.md)
2. **Try the Quick Start**: Run `clio --new` and explore
3. **Configure advanced settings**: Edit `~/.clio/config.yaml`
4. **Join the community**: [GitHub Discussions](https://github.com/fewtarius/clio/discussions)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Getting Help

**Issues during installation?**

1. Check this troubleshooting section
2. Run with debug mode: `clio --debug --new`
3. Search [GitHub Issues](https://github.com/fewtarius/clio/issues)
4. Create a new issue with:
   - Your OS and version
   - Perl version (`perl --version`)
   - Error messages
   - Output of `clio --debug`

**Installation successful? Start using CLIO:**

```bash
clio --new
```

Welcome to CLIO!
