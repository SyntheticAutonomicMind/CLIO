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
- **Portable & Minimal:** Works with standard Unix tools (git, curl, etc.) - no heavy frameworks or package managers required. See [docs/DEPENDENCIES.md](docs/DEPENDENCIES.md) for details.
- **Tool-Powered:** Real file, git, and terminal operations with real-time action descriptions
- **Privacy & Control:** Your code stays on your machine - only minimum context sent to AI providers
- **Persistent Sessions:** Pick up exactly where you left off with full conversation history
- **Scriptable & Extensible:** Fits into your workflow, not the other way around

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
| **AI Providers** | GitHub Copilot, OpenAI, DeepSeek, OpenRouter, llama.cpp, SAM |

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

**Manual**
```bash
git clone https://github.com/SyntheticAutonomicMind/CLIO.git
cd clio && sudo ./install.sh
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
- **Perl 5.20+** (included with most systems)
- **Git** (for version control operations)
- **ANSI-compatible terminal**

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Documentation

| Document | Description |
|----------|-------------|
| [User Guide](docs/USER_GUIDE.md) | Complete usage guide with examples |
| [Installation](docs/INSTALLATION.md) | Detailed installation instructions |
| [Sandbox Mode](docs/SANDBOX.md) | Security isolation options |
| [Architecture](docs/ARCHITECTURE.md) | System design and internals |
| [Developer Guide](docs/DEVELOPER_GUIDE.md) | Contributing and extending CLIO |
| [Remote Execution](docs/REMOTE_EXECUTION.md) | Distributed AI workflows |
| [Multi-Agent](docs/MULTI_AGENT_COORDINATION.md) | Parallel agent coordination |
| [Custom Instructions](docs/CUSTOM_INSTRUCTIONS.md) | Per-project AI customization |

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Design Philosophy

CLIO is built around these principles:

1. **Terminal Native**: Your terminal is your IDE
2. **Zero Dependencies**: Pure Perl - no CPAN, npm, or pip
3. **Tool Transparency**: See every action as it happens
4. **Local First**: Your code and data stay on your machine
5. **Session Continuity**: Never lose context

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Contributing

Contributions welcome! See [docs/DEVELOPER_GUIDE.md](docs/DEVELOPER_GUIDE.md) for guidelines.

```bash
# Fork and clone
git clone https://github.com/YOUR_USERNAME/CLIO.git
cd clio

# Run tests
find lib -name "*.pm" -exec perl -I./lib -c {} \;

# Submit PR
git push origin your-feature-branch
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## License

GPL-3.0 - See [LICENSE](LICENSE) for details.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Support

- **GitHub Issues**: [Report bugs or request features](https://github.com/SyntheticAutonomicMind/CLIO/issues)
- **Discussions**: [Join the community](https://github.com/SyntheticAutonomicMind/CLIO/discussions)
