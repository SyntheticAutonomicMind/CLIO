# CLIO Installation Guide

## Quick Install

```bash
cd CLIO-dist
./scripts/install.sh
```

The installer will:
1. Check for Perl
2. Create config directory (`~/.clio`)
3. Set file permissions
4. Create default configuration
5. Test CLIO execution

## Manual Installation

If the automatic installer doesn't work for your system:

### 1. Check Perl Version

```bash
perl -v
```

CLIO requires Perl 5.16 or later. Most macOS and Linux systems have this pre-installed.

### 2. Create Config Directory

```bash
mkdir -p ~/.clio
```

### 3. Set Executable Permissions

```bash
chmod +x clio
```

### 4. Create Default Config

Create `~/.clio/config.json`:

```json
{
    "provider": "github_copilot",
    "model": "gpt-4",
    "style": "default",
    "theme": "default",
    "loglevel": "WARNING"
}
```

### 5. Test CLIO

```bash
./clio --help
```

## Configuration

### API Setup

CLIO requires an AI provider. GitHub Copilot is recommended:

```bash
./clio
/api key YOUR_GITHUB_COPILOT_KEY
/config save
```

To get a GitHub Copilot key:
1. Have an active GitHub Copilot subscription
2. CLIO will guide you through authentication

### Customize Appearance

```bash
# List available styles
./clio
/style list

# Set retro BBS style
/style photon

# Set compact output theme
/theme compact

# Save preferences
/config save
```

## Adding to PATH (Optional)

To run `clio` from anywhere:

### Bash/Zsh

Add to `~/.bashrc` or `~/.zshrc`:

```bash
export PATH="/path/to/CLIO-dist:$PATH"
```

Then:
```bash
source ~/.bashrc  # or ~/.zshrc
```

### Fish

```fish
set -U fish_user_paths /path/to/CLIO-dist $fish_user_paths
```

## Troubleshooting

### "Can't locate CLIO/UI/Chat.pm"

**Cause:** Perl can't find the library modules.

**Solutions:**
1. Run `clio` from the CLIO-dist directory
2. OR set `PERL5LIB`:
   ```bash
   export PERL5LIB=/path/to/CLIO-dist/lib:$PERL5LIB
   ```

### "API key not set"

**Cause:** No API credentials configured.

**Solution:**
```bash
./clio
/api key YOUR_KEY
/config save
```

### Terminal encoding issues

**Cause:** UTF-8 not enabled.

**Solution:**
```bash
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
```

Add these to your shell profile to make permanent.

### Colors not working

**Causes:**
- Terminal doesn't support ANSI colors
- TERM variable not set correctly

**Solutions:**
1. Check TERM: `echo $TERM`
2. Should be something like `xterm-256color` or `screen-256color`
3. If not, set it: `export TERM=xterm-256color`

### Performance issues

**Slow markdown rendering:**
- Already optimized in latest version
- Should be <100ms for typical responses

**Slow AI responses:**
- This is network/API latency, not CLIO
- Check your internet connection
- Try different model (may be faster/slower)

## Platform-Specific Notes

### macOS

Works out of the box on macOS 10.9 or later (Perl 5.16+ included).

### Linux

Most distributions include Perl. If not:

**Debian/Ubuntu:**
```bash
sudo apt-get install perl
```

**Fedora/RHEL:**
```bash
sudo dnf install perl
```

**Arch:**
```bash
sudo pacman -S perl
```

### Windows (WSL)

CLIO works great in Windows Subsystem for Linux (WSL):

1. Install WSL2
2. Install a Linux distribution (Ubuntu recommended)
3. Follow Linux instructions above

### Windows (Native)

Native Windows support is experimental. Use WSL for best experience.

## Verification

After installation, verify everything works:

```bash
# Check help
./clio --help

# Start new session
./clio --new

# Test AI response
/api key YOUR_KEY
say hello

# Test hashtag system
explain #file:clio

# Exit
/exit
```

## Getting Help

If you encounter issues:

1. Check this troubleshooting guide
2. Check `docs/` for technical documentation
3. Review `SYSTEM_DESIGN.md` for architecture details
4. Check the repository issues/discussions

## Next Steps

- Read [README.md](README.md) for feature overview
- Explore [docs/HASHTAG_SYSTEM_SPEC.md](docs/HASHTAG_SYSTEM_SPEC.md) for context injection
- Review [styles/](styles/) and [themes/](themes/) for customization
- Check [docs/PROTOCOL_SPECIFICATION.md](docs/PROTOCOL_SPECIFICATION.md) for protocol details

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Welcome to CLIO! 🎉
