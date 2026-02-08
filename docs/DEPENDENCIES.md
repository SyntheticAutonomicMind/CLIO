# CLIO Dependencies

**Version:** 1.0  
**Last Updated:** 2026-02-08

---

## Philosophy

CLIO is designed to work with **minimal dependencies** using standard Unix tools that have been stable for decades. We deliberately avoid:

- Heavy framework dependencies
- Node.js/npm/JavaScript ecosystems  
- Python/pip dependencies
- CPAN modules (zero external Perl dependencies)
- Docker-only deployment

**Result:** CLIO works on a clean Unix system with Perl 5.32+ installed. No package managers, no complex setup.

---

## Quick Verification

Check if your system has everything needed:

```bash
./check-deps
```

This automated script verifies:
- Perl version (>= 5.32 required)
- All required system commands
- Optional tools with fallback notes

---

## Required Dependencies

### Perl 5.32 or Higher

**Why:** CLIO is written in Perl and requires modern Perl core modules.

**Verify:**
```bash
perl -v
```

**Installation:**

| Platform | Command |
|----------|---------|
| macOS | Pre-installed (usually 5.30+) or `brew install perl` |
| Debian/Ubuntu | `sudo apt install perl` |
| RHEL/Fedora | `sudo dnf install perl` |
| Arch Linux | `sudo pacman -S perl` |

**Important:** CLIO uses **zero external CPAN modules**. Everything works with Perl core modules included in 5.32+.

---

### System Commands

All of these are typically pre-installed on Unix-like systems.

| Command | Purpose | Package |
|---------|---------|---------|
| `git` | Version control operations | git |
| `curl` | HTTP requests, API calls, updates | curl |
| `stty` | Terminal mode control | coreutils |
| `tput` | Terminal capability queries | ncurses-bin |
| `script` | Terminal session recording for hybrid passthrough | util-linux (Linux), BSD base (macOS) |
| `tar` | Archive extraction for updates | tar |

**Verify all commands:**
```bash
which git curl stty tput script tar
```

**Install if missing:**

**Debian/Ubuntu:**
```bash
sudo apt install git curl coreutils ncurses-bin util-linux tar
```

**RHEL/Fedora:**
```bash
sudo dnf install git curl coreutils ncurses tar util-linux
```

**Arch Linux:**
```bash
sudo pacman -S git curl coreutils ncurses tar util-linux
```

**macOS:**
```bash
# Install Xcode Command Line Tools (includes git)
xcode-select --install

# Other tools (curl, stty, tput, script, tar) are pre-installed
```

---

## Perl Core Modules

CLIO uses **zero external CPAN modules**. All functionality is implemented with Perl core modules included in Perl 5.32+:

| Module | Purpose |
|--------|---------|
| `JSON::PP` | JSON parsing and generation |
| `File::*` | File operations (Spec, Path, Basename, Copy, Find, Temp) |
| `Time::HiRes`, `Time::Piece` | Time operations |
| `Digest::MD5` | Checksums |
| `Encode` | UTF-8 handling |
| `POSIX` | System interfaces |
| `Cwd` | Directory operations |
| `Getopt::Long` | Command-line parsing |

**No installation needed** - these ship with Perl.

---

## Optional Tools

These commands are **not required** but enable additional features when present:

### File System Utilities

| Command | Purpose | Fallback |
|---------|---------|----------|
| `readlink` | Resolve symbolic links | Perl's own link resolution |
| `which` | Find executables in PATH | Perl can work around it |

### Interactive Tools (Auto-Detected)

When you use these tools via CLIO's terminal operations, CLIO automatically enables hybrid passthrough mode - you get full interactivity AND CLIO sees the output:

| Tool Category | Commands | Feature Enabled |
|---------------|----------|-----------------|
| Editors | vim, vi, nvim, nano, emacs | Interactive editing with output capture |
| GPG | gpg | Passphrase prompts for git commit -S |
| SSH | ssh | Interactive shell sessions |
| Pagers | less, more, man | Paginated viewing |
| Shells | bash, sh, zsh | Interactive shells |
| REPLs | python, ruby, irb, node | Programming language REPLs |

**These are not dependencies** - CLIO detects them and adapts behavior accordingly.

---

## Troubleshooting

### "script: command not found"

**Symptom:** Interactive commands (GPG, vim) fail when using hybrid passthrough mode.

**Solution:**
```bash
# Linux
sudo apt install util-linux    # Debian/Ubuntu
sudo dnf install util-linux    # RHEL/Fedora

# macOS - reinstall Command Line Tools if missing
xcode-select --install
```

---

### "stty: command not found" or "tput: command not found"

**Symptom:** Terminal input/output behaves incorrectly, readline doesn't work properly.

**Solution:**
```bash
sudo apt install coreutils ncurses-bin  # Debian/Ubuntu
sudo dnf install coreutils ncurses      # RHEL/Fedora
```

---

### "curl: command not found"

**Symptom:** Updates, web search, and API calls fail.

**Solution:**
```bash
sudo apt install curl  # Debian/Ubuntu
sudo dnf install curl  # RHEL/Fedora
brew install curl      # macOS (Homebrew)
```

---

### "git: command not found"

**Symptom:** Version control operations fail, /git commands don't work.

**Solution:**
```bash
sudo apt install git   # Debian/Ubuntu
sudo dnf install git   # RHEL/Fedora
xcode-select --install # macOS
```
