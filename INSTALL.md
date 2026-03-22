# CLIO Installation and Setup Guide

## Important: CLIO is Local-First

**CLIO runs completely on your local machine.** You can:

- [OK] Use CLIO entirely offline with local AI models (llama.cpp, LM Studio, SAM)
- [OK] Optionally connect to cloud AI providers (GitHub Copilot, OpenAI, Anthropic, etc.)
- [OK] Switch between local and cloud providers at any time

**You do NOT need the internet to use CLIO.** But if you want cloud AI, CLIO makes it easy to connect.

---

## Quick Start: 60 Seconds

```bash
# 1. Install
cd CLIO-dist
sudo ./install.sh

# 2. Start CLIO
clio --new

# 3. Discover available AI providers
: /api providers

# 4. Pick a provider and follow its setup instructions
: /api providers github_copilot    # (or llama.cpp, openai, etc.)

# 5. Start using CLIO!
: explain how to use CLIO
```

**That's it!** See sections below for detailed setup of each provider.

---

## Installation

### Quick Install (System-Wide)

```bash
cd CLIO-dist
sudo ./install.sh
```

This installs CLIO to `/opt/clio` with a symlink at `/usr/local/bin/clio`.

### Quick Install (User Directory - No Sudo)

```bash
cd CLIO-dist
./install.sh --user
```

This installs to `~/.local/clio` with symlink at `~/.local/bin/clio`.

### Installation Options

```bash
# Install to custom directory
sudo ./install.sh /usr/local/clio

# Install without creating symlink
sudo ./install.sh --no-symlink

# Create symlink at custom location
sudo ./install.sh --symlink /usr/bin/clio

# Show help
./install.sh --help
```

### Manual Installation

If the automatic installer doesn't work:

1. **Check Perl version** (5.16+ required):
   ```bash
   perl -v
   ```

2. **Create config directory:**
   ```bash
   mkdir -p ~/.clio
   ```

3. **Set executable permissions:**
   ```bash
   chmod +x clio
   ```

4. **Test CLIO:**
   ```bash
   ./clio --help
   ```

---

## Available AI Providers

Run this command to see all available providers:

```bash
clio --new
: /api providers
```

### Local Providers (No Internet Required)

| Provider | Setup | Notes |
|----------|-------|-------|
| **llama.cpp** | Run llama.cpp server, then `/api set provider llama.cpp` | Popular, many models available |
| **LM Studio** | Run LM Studio app, then `/api set provider lmstudio` | GUI-based, easy model management |
| **SAM** | Run SAM server locally, then `/api set provider sam` | Fast inference |

### Cloud Providers (Requires API Key/Account)

| Provider | Setup | Notes |
|----------|-------|-------|
| **GitHub Copilot** | `/api login` then authorize in browser | Recommended, integrated OAuth |
| **OpenAI** | `/api set provider openai` then `/api set key <key>` | Popular, many models |
| **Anthropic** | `/api set provider anthropic` then `/api set key <key>` | Claude models |
| **Google Gemini** | `/api set provider google` then `/api set key <key>` | Large context models |
| **DeepSeek** | `/api set provider deepseek` then `/api set key <key>` | Cost-effective |
| **OpenRouter** | `/api set provider openrouter` then `/api set key <key>` | Access to many models |

---

## Setting Up Each Provider

### Local: llama.cpp

**1. Install and run llama.cpp server:**
```bash
# Clone llama.cpp repo
git clone https://github.com/ggerganov/llama.cpp.git
cd llama.cpp

# Build it
make

# Download a model (e.g., Mistral 7B)
# See: https://huggingface.co/models?search=gguf

# Run server (default port 8080)
./server -m your-model.gguf
```

**2. Configure CLIO:**
```bash
clio --new
: /api set provider llama.cpp
: /api show
```

**Done!** CLIO now uses your local llama.cpp model.

### Local: LM Studio

**1. Install and run LM Studio:**
- Download from https://lmstudio.ai
- Launch the app
- Load a model (it will download automatically)
- Start the local server (default port 1234)

**2. Configure CLIO:**
```bash
clio --new
: /api set provider lmstudio
: /api show
```

**Done!** CLIO now uses LM Studio.

### Cloud: GitHub Copilot (Recommended)

**1. Get a GitHub Copilot subscription:**
- Visit https://github.com/copilot
- Subscribe ($10/month or $100/year individual, $19/month business)

**2. Configure CLIO:**
```bash
clio --new
: /api login
# Browser opens -> Authorize -> Done!
: /api show
```

**Done!** CLIO now uses GitHub Copilot.

### Cloud: OpenAI

**1. Get an OpenAI API key:**
- Visit https://platform.openai.com/account/api-keys
- Create new secret key
- Copy the key

**2. Configure CLIO:**
```bash
clio --new
: /api set provider openai
: /api set key sk-...  (paste your key)
: /config save
: /api show
```

**Done!** CLIO now uses OpenAI.

### Cloud: Anthropic

**1. Get an Anthropic API key:**
- Visit https://console.anthropic.com
- Create new API key
- Copy the key

**2. Configure CLIO:**
```bash
clio --new
: /api set provider anthropic
: /api set key sk-ant-...  (paste your key)
: /config save
: /api show
```

**Done!** CLIO now uses Anthropic.

---

## Verifying Your Setup

After setup, verify everything works:

```bash
clio --new
: /api show

# Test a simple question
: what is 2+2?

# If you get an AI response, you're all set!
: /exit
```

---

## Switching Between Providers

CLIO makes it easy to switch providers:

```bash
clio --new
: /api set provider llama.cpp       # Switch to local
: /api set provider openai          # Switch to cloud
: /api show                         # Verify current provider
```

Each provider keeps its own configuration (API keys, models, settings).

---

## Troubleshooting

### "Can't locate CLIO/UI/Chat.pm"

**Cause:** Perl can't find the library modules.

**Solution:**
```bash
# Option 1: Run from CLIO-dist directory
cd CLIO-dist && ./clio --new

# Option 2: Set PERL5LIB
export PERL5LIB=/path/to/CLIO-dist/lib:$PERL5LIB
clio --new
```

### "Permission denied" during install

**Cause:** Need sudo for system directories.

**Solution:**
```bash
sudo ./install.sh                # System-wide install
# OR
./install.sh --user              # User install (no sudo)
```

### "API connection failed"

**Cause:** Provider not properly configured or network issue.

**Solution:**
```bash
clio --new
: /api show                      # Check current config
: /api providers github_copilot  # Get setup instructions
```

### Local model (llama.cpp) not connecting

**Cause:** Server not running or wrong port.

**Solution:**
1. Verify llama.cpp server is running: `curl http://localhost:8080/health`
2. Check port number in CLIO: `/api show`
3. Restart llama.cpp server if needed

### "Terminal encoding issues"

**Cause:** UTF-8 not enabled.

**Solution:**
```bash
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
# Add these to ~/.bashrc or ~/.zshrc to make permanent
```

---

## Platform-Specific Notes

### macOS

Works out of the box. Perl 5.16+ is pre-installed.

### Linux

Install Perl if needed:
```bash
# Ubuntu/Debian
sudo apt-get install perl

# Fedora/RHEL
sudo dnf install perl

# Arch
sudo pacman -S perl
```

### Windows

Use **Windows Subsystem for Linux (WSL)**:
1. Install WSL2
2. Install Ubuntu 20.04 or later
3. Follow Linux instructions above

### Docker

Run CLIO in a container:
```bash
docker run -it --rm \
    -v "$(pwd)":/workspace \
    -v clio-auth:/root/.clio \
    -w /workspace \
    ghcr.io/syntheticautonomicmind/clio:latest \
    --new
```

---

## Next Steps

After installation:

1. **Read the User Guide:** See `docs/USER_GUIDE.md` for full feature documentation
2. **Try example commands:** Start with `/api show` and explore available commands
3. **Customize appearance:** Try `/style list` and `/theme list` to personalize CLIO
4. **Learn about tools:** Ask CLIO: "What tools do you have available?"

---

## Getting Help

**Issues during installation?**

1. Check the troubleshooting section above
2. Run with debug mode: `clio --debug --new`
3. Search [GitHub Issues](https://github.com/SyntheticAutonomicMind/CLIO/issues)
4. Create a new issue with:
   - Your OS and version
   - Perl version (`perl --version`)
   - Error messages
   - Output of `clio --debug`

---

**Welcome to CLIO! Start creating with AI today.**