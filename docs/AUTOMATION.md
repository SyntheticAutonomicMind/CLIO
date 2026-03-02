# Automation and CI/CD Integration

CLIO can automate repository management and integrate into CI/CD pipelines in two ways:

1. **CLIO-helper** - A companion daemon for continuous GitHub monitoring (recommended)
2. **CLIO CLI** - Use CLIO's `--input --exit` mode in scripts and pipelines

---

## CLIO-helper (Recommended)

[CLIO-helper](https://github.com/SyntheticAutonomicMind/CLIO-helper) is a GitHub monitoring daemon that uses CLIO's AI capabilities to automate community support, issue triage, code review, stale management, and release notes.

### What It Does

| Monitor | Description |
|---------|-------------|
| **Discussions** | AI-powered community support with codebase-aware answers |
| **Issues** | Deep triage: classification, priority, root cause analysis, labeling, assignment |
| **Pull Requests** | Thorough code review: logic analysis, security scanning, style checks, file-level findings |
| **Stale** | Graduated warnings and auto-close for inactive issues and PRs |
| **Releases** | Auto-generated categorized release notes from commit history |

### Key Features

- **Near real-time** - Polls every 2 minutes (configurable)
- **Deep codebase analysis** - Clones repos locally and uses CLIO's tools for context-aware AI responses
- **Intelligent filtering** - Skips already-processed, bot-created, draft, and protected items
- **Persistent state** - SQLite database tracks processed items across restarts
- **Security-first** - Multi-layer prompt injection protection, social engineering detection
- **Dry-run mode** - Test the full pipeline without posting anything
- **Multi-repo** - Monitor all your organization's repos from one daemon
- **Auto-updating context** - Git pulls latest code before each analysis cycle

### Quick Start

```bash
# Install CLIO-helper
curl -sSL https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO-helper/main/install.sh | bash

# Configure
clio-helper --setup

# Run (foreground)
clio-helper

# Run as a systemd service
clio-helper --install-service
```

For complete documentation, see the [CLIO-helper repository](https://github.com/SyntheticAutonomicMind/CLIO-helper).

---

## CLIO CLI for CI/CD

CLIO's `--input --exit` mode enables integration into any CI/CD pipeline, shell script, or automation workflow.

### Basic Usage

```bash
# Run a single task and exit
clio --input "analyze this codebase for security issues" --exit

# With a specific model
clio --model gpt-4.1 --input "review the latest commit" --exit

# In sandbox mode (restricts file access)
clio --sandbox --input "check for broken tests" --exit

# Suppress color for log-friendly output
clio --no-color --input "summarize recent changes" --exit
```

### In GitHub Actions

```yaml
name: CLIO Analysis
on: push

jobs:
  analyze:
    runs-on: ubuntu-latest
    container:
      image: ghcr.io/syntheticautonomicmind/clio:latest
    steps:
      - uses: actions/checkout@v4
      - name: Run CLIO
        run: |
          clio --no-color --sandbox --input "review the changes in this commit" --exit
```

### In Shell Scripts

```bash
#!/bin/bash
# Example: Pre-commit analysis
clio --input "check lib/ for syntax errors and missing use strict" --exit
if [ $? -ne 0 ]; then
    echo "CLIO found issues, aborting commit"
    exit 1
fi
```

### Environment Variables

| Variable | Description |
|----------|-------------|
| `CLIO_HOME` | Override CLIO config directory |
| `NO_COLOR` | Disable color output (same as `--no-color`) |
| `CLIO_LOG_LEVEL` | Set log level (DEBUG, INFO, WARN, ERROR) |

---

## Docker

CLIO is available as a container image for CI/CD environments:

```bash
# Pull the latest image
docker pull ghcr.io/syntheticautonomicmind/clio:latest

# Run a task
docker run --rm -v $(pwd):/workspace -w /workspace \
    ghcr.io/syntheticautonomicmind/clio:latest \
    clio --no-color --sandbox --input "analyze this project" --exit
```

### Container Features

- Minimal Alpine-based image
- CLIO pre-installed with all dependencies
- Sandbox mode for security isolation
- Suitable for GitHub Actions, GitLab CI, Jenkins, etc.

---

## Migration from GitHub Actions Workflows

If you were previously using CLIO's GitHub Actions workflows (`.github/workflows/issue-triage.yml`), those have been replaced by CLIO-helper, which provides:

- **More monitors** - 5 monitors (discussions, issues, PRs, stale, releases) vs 1 (issues only)
- **Better analysis** - Deep codebase investigation with local repo clone
- **Continuous monitoring** - Daemon mode instead of event-triggered workflows
- **No workflow maintenance** - Single daemon vs per-repo workflow configuration
- **Lower latency** - Already running when events occur, no cold start

To migrate:
1. Remove old workflow files (`.github/workflows/issue-triage.yml`)
2. Install CLIO-helper: `curl -sSL https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO-helper/main/install.sh | bash`
3. Run `clio-helper --setup` and follow the prompts
4. Start the daemon: `clio-helper`

---

## See Also

- [CLIO-helper Repository](https://github.com/SyntheticAutonomicMind/CLIO-helper) - Full daemon documentation
- [Sandbox Mode](SANDBOX.md) - Security isolation for CI/CD
- [Remote Execution](REMOTE_EXECUTION.md) - Distributed AI workflows
