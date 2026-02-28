# CLIO - Command Line Intelligence Orchestrator

**An AI code assistant for people who live in the terminal. Portable, privacy-first, and designed for real work.**

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Why I Built CLIO

I built CLIO for myself. As someone who prefers working in the terminal, I wanted an AI assistant that felt native to my workflow. One that respected my privacy, worked anywhere Perl runs, and gave me full control over my code and tools. I couldn't find anything that met those needs, so I created CLIO.

Starting with version 20260119.1, CLIO has been building itself. All of my development is now done through pair programming with AI agents using CLIO.

CLIO is part of the [Synthetic Autonomic Mind (SAM)](https://github.com/SyntheticAutonomicMind) organization, which is dedicated to building user-first, privacy-respecting AI tools. If you value transparency, portability, and the power of the command line, CLIO is for you.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## What Makes CLIO Different

- **Terminal-First Experience:** Runs entirely in your terminal with professional markdown rendering, color themes, and streaming output
- **Light & Nimble:** Uses ~50 MB of RAM. Works on everything from a ClockworkPi uConsole R01 to an M4-powered Mac.
- **Portable & Minimal:** Works with standard Unix tools (git, curl, etc.) - no heavy frameworks or package managers required. See [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) for details.
- **Actually Autonomous:** CLIO doesn't just suggest code - it reads, writes, tests, commits, and iterates. Give it a task and it works through it end-to-end.
- **Tool-Powered:** Real file, git, and terminal operations with real-time action descriptions
- **Privacy & Control:** Your code stays on your machine - only minimum context sent to AI providers. Built-in secret redaction catches API keys, tokens, PII, and credentials before they reach the AI.
- **Persistent Sessions:** Pick up exactly where you left off with full conversation history
- **Scriptable & Extensible:** Fits into your workflow, not the other way around
- **Remote Execution:** SSH into any machine, deploy CLIO, run an AI task, and get results back - across your entire fleet in parallel
- **Multi-Agent Coordination:** Spawn parallel agents with file locks, git locks, and coordinated API rate limiting for safe collaboration
- **Long-Term Memory:** Discoveries, solutions, and patterns persist across your project history and are automatically injected into every conversation
- **Interrupt Anytime:** Press Escape to stop the agent mid-task. CLIO pauses, asks what you need, and adapts - like tapping your pair programmer on the shoulder

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Core Features

| Category | Capabilities |
|----------|--------------|
| **Files** | Read, write, search, edit, manage files |
| **Git** | Status, diff, commit, branch, push, pull, stash, tag |
| **Terminal** | Execute commands and scripts directly |
| **Remote** | Run AI tasks on remote systems via SSH |
| **Multi-Agent** | Spawn parallel agents for complex work |
| **Memory** | Store and recall information across sessions |
| **Todos** | Manage tasks within your workflow |
| **Web** | Fetch and analyze web content |
| **MCP** | Connect to external tool servers via [Model Context Protocol](docs/MCP.md) |
| **AI Providers** | GitHub Copilot, OpenAI, Anthropic, Google Gemini, DeepSeek, OpenRouter, llama.cpp, LM Studio, SAM |

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Screenshots

<table>
  <tr>
    <td width="50%">
      <h3>CLIO's Simple Interface</h3>
      <img src=".images/clio1.png"/>
    </td>
    <td width="50%">
      <h3>Claude Haiku describing CLIO</h3>
      <img src=".images/clio2.png"/>
    </td>
  </tr>
</table>

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Real-World Performance

CLIO is built to run for hours without breaking a sweat. These are stats from real development sessions:

```
Session 1 - Game development (pair programming):
  Uptime: 29h 43m | RSS: 10.7 MB | Tool calls: 502

Session 2 - CLIO development (light use):
  Uptime: 27h 27m | RSS: 10.8 MB | Tool calls: 58

Session 3 - CLIO development (active):
  Uptime: 3h 5m  | RSS: 50.6 MB | Tool calls: 507
```

Long-running sessions settle to ~11 MB. Active sessions hover around the ~44 MB startup baseline. No memory leaks, no degradation, no restart needed.

### Billing Awareness

CLIO tracks your API usage in real time with `/usage`:

```
Premium Quota
──────────────────────────────────────────────────────────────
  Status:                   891 used of 1500 (59.3%)
  Resets:                   2026-03-01
Token Usage
──────────────────────────────────────────────────────────────
  Total Tokens:             13,428,981
    Prompt:                 13,422,054 tokens
    Completion:             6,927 tokens
```

No surprises at the end of the month. See your quota consumption, billing multipliers for premium models, per-request token counts, and reset dates. CLIO warns you when premium models cost extra (e.g., Claude Opus at 3x) so you can make informed choices.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Quick Start

### Check Dependencies

```bash
./check-deps  # Verify all required tools are installed
```

CLIO requires standard Unix tools (git, curl, perl 5.32+, etc.). See [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) for details.

### Install

**Homebrew (macOS)**
```bash
brew tap SyntheticAutonomicMind/homebrew-SAM
brew install clio
```

**Docker (Any Platform)**
```bash
docker run -it --rm \
    -v "$(pwd)":/workspace \
    -v clio-auth:/root/.clio \
    -w /workspace \
    ghcr.io/syntheticautonomicmind/clio:latest \
    --new
```

**Manual**
```bash
git clone https://github.com/SyntheticAutonomicMind/CLIO.git
cd CLIO && sudo ./install.sh
```

For detailed options, see [docs/INSTALLATION.md](docs/INSTALLATION.md).

### Configure AI Provider

**GitHub Copilot** (Recommended - no config needed)
```bash
./clio
: /api login
# Follow browser prompts to authorize
```

**Other Providers**
```bash
./clio
: /api set provider openai
: /api set key YOUR_API_KEY
: /config save
```

### Start Using CLIO

```bash
./clio --new          # New conversation
./clio --resume       # Resume last session
./clio --debug        # Debug mode
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Slash Commands (Quick Reference)

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/api` | Configure AI providers |
| `/config` | View/edit configuration |
| `/session` | Session management |
| `/file` | File operations |
| `/git` | Git operations |
| `/memory` | Memory system |
| `/todo` | Task management |
| `/skill` | Custom skill system |
| `/theme` | Change color theme |
| `/clear` | Clear screen |
| `/exit` | Exit CLIO |

For complete command reference, see [docs/USER_GUIDE.md](docs/USER_GUIDE.md#slash-commands).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Example Usage

```
You: Read the main config file and explain its structure

CLIO: [Reading lib/CLIO/Core/Config.pm]

The Config module handles CLIO's configuration system. Key sections:
- **Defaults**: Provider settings, model preferences
- **Persistence**: JSON-based storage in ~/.clio/config.json
- **Runtime overrides**: Environment variables and CLI flags

You: Fix the bug in the login function

CLIO: [Reading lib/CLIO/Security/Auth.pm]
      [Identified issue: token validation missing null check]
      [Writing fix to lib/CLIO/Security/Auth.pm]
      
Fixed the bug. The issue was...
```

For more examples, see [docs/USER_GUIDE.md](docs/USER_GUIDE.md#usage-examples).

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Requirements

- **macOS 10.14+** or **Linux** (any modern distribution)
- **Perl 5.32+** (included with most systems)
- **Git** (for version control operations)
- **ANSI-compatible terminal**

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Documentation

| Document | Description |
|----------|-------------|
| [User Guide](docs/USER_GUIDE.md) | Complete usage guide with examples |
| [Feature Guide](docs/FEATURES.md) | Every feature explained in detail |
| [Installation](docs/INSTALLATION.md) | Detailed installation instructions |
| [Dependencies](docs/DEPENDENCIES.md) | System requirements and verification |
| [Sandbox Mode](docs/SANDBOX.md) | Security isolation options |
| [Architecture](docs/ARCHITECTURE.md) | System design and internals |
| [Developer Guide](docs/DEVELOPER_GUIDE.md) | Contributing and extending CLIO |
| [Remote Execution](docs/REMOTE_EXECUTION.md) | Distributed AI workflows |
| [Multi-Agent](docs/MULTI_AGENT_COORDINATION.md) | Parallel agent coordination |
| [MCP Integration](docs/MCP.md) | Model Context Protocol support |
| [Custom Instructions](docs/CUSTOM_INSTRUCTIONS.md) | Per-project AI customization |
| [GitHub Actions](docs/GITHUB_ACTIONS.md) | CI/CD integration for issue triage and PR review |
| [Style Guide](docs/STYLE_GUIDE.md) | Color themes and customization |
| [Performance](docs/PERFORMANCE.md) | Benchmarks and optimization |

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Design Philosophy

CLIO is built around these principles:

1. **Terminal Native**: Your terminal is your IDE
2. **Zero Dependencies**: Pure Perl - no CPAN, npm, or pip
3. **Tool Transparency**: See every action as it happens
4. **Local First**: Your code and data stay on your machine
5. **Session Continuity**: Never lose context

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Part of the Ecosystem

CLIO is part of [Synthetic Autonomic Mind](https://github.com/SyntheticAutonomicMind) - a family of open source AI tools:

- **[SAM](https://github.com/SyntheticAutonomicMind/SAM)** - Native macOS AI assistant with voice control, document analysis, and image generation
- **[ALICE](https://github.com/SyntheticAutonomicMind/ALICE)** - Local Stable Diffusion server with web interface and OpenAI-compatible API
- **[SAM-Web](https://github.com/SyntheticAutonomicMind/SAM-web)** - Access SAM from iPad, iPhone, or any browser

CLIO can use SAM as an AI provider. All three tools share the same commitment to privacy and local-first operation.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Spread the Word

CLIO is a small open source project with no marketing budget. If it's been useful to you, the best way to help is to tell someone about it - a blog post, a tweet, a recommendation to a colleague, or a star on GitHub. Word of mouth is how projects like this grow.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Contributing

Contributions welcome! See [docs/DEVELOPER_GUIDE.md](docs/DEVELOPER_GUIDE.md) for guidelines.

```bash
# Fork and clone
git clone https://github.com/YOUR_USERNAME/CLIO.git
cd CLIO

# Run tests
find lib -name "*.pm" -exec perl -I./lib -c {} \;

# Submit PR
git push origin your-feature-branch
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## License

GPL-3.0 - See [LICENSE](LICENSE) for details.

**Created by:** Andrew Wyatt (Fewtarius)  
**Website:** [syntheticautonomicmind.org](https://www.syntheticautonomicmind.org)  
**Repository:** [github.com/SyntheticAutonomicMind/CLIO](https://github.com/SyntheticAutonomicMind/CLIO)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Support

- **Discussions**: [Join the conversation](https://github.com/orgs/SyntheticAutonomicMind/discussions)
- **GitHub Issues**: [Report bugs or request features](https://github.com/SyntheticAutonomicMind/CLIO/issues)

