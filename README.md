# CLIO - Command Line Intelligence Orchestrator

**A terminal-native AI coding tool that reads your code, edits files, runs commands, uses git, and works through tasks with you.**

I built CLIO for myself. I spend more time in terminal sessions than I do using GUIs, and I wanted a terminal-first AI development tool that worked the way I work. It didn't really exist, so I built it. Starting with version 20260119.1, CLIO has been building itself - all development on SAM, CLIO, and ALICE is done through pair programming with AI agents using CLIO.

CLIO is part of [Synthetic Autonomic Mind](https://github.com/SyntheticAutonomicMind).

---

## How CLIO Works

1. **You describe the task**
2. **CLIO investigates** - reads code, searches files, checks git state
3. **CLIO proposes a plan** when your input matters
4. **After approval, CLIO does the work** - edits files, runs commands, verifies results
5. **CLIO reports back** and asks before committing significant changes

That makes CLIO closer to pair programming than prompt-and-response chat.

---

## What You Can Do With CLIO

- **Give it a task, it does the work** - CLIO investigates your codebase, proposes a plan, you approve, it implements. Edits files, runs tests, commits changes.
- **Work from anywhere** - Local shells, SSH sessions, tmux, Docker, headless servers. Anywhere Perl runs.
- **Zero dependencies** - Pure Perl with standard core modules. No CPAN, no npm, no pip. Install and run.
- **Pick up where you left off** - Persistent sessions with full history. Long-term memory carries across projects.
- **Coordinate parallel agents** - Spawn sub-agents with file locks, git locks, and rate limiting.
- **Run across your fleet** - SSH into any machine, deploy CLIO, run a task, get results.
- **Stay private** - Secret redaction catches API keys and tokens before they reach the AI. Your code stays on your machine.
- **Interrupt anytime** - Press any key to stop mid-task. CLIO pauses, asks what you need, and adapts.

---

## Core Features

| Category | Capabilities |
|----------|--------------|
| **Files** | Read, write, search, edit, manage files |
| **Git** | Status, diff, commit, branch, push, pull, stash, tag |
| **Terminal** | Execute commands and scripts directly |
| **Remote** | Run AI tasks on remote systems via SSH |
| **Multi-Agent** | Spawn parallel agents for complex work |
| **Multiplexer** | Live agent output panes via tmux, GNU Screen, or Zellij |
| **Memory** | Store and recall information across sessions |
| **Profile** | Learns your working style and personalizes collaboration |
| **Todos** | Manage tasks within your workflow |
| **Web** | Fetch and analyze web content |
| **MCP** | Connect to external tool servers via [Model Context Protocol](docs/MCP.md) |
| **AI Providers** | GitHub Copilot, Anthropic, OpenAI, Google Gemini, DeepSeek, OpenRouter, Ollama Cloud, MiniMax, Z.AI, llama.cpp, LM Studio, SAM |
| **Proxy Support** | HTTP and SOCKS proxy for corporate/restricted networks |

---

## Performance

CLIO is built to run for hours without issues:

```
Session 1 - Active development (1h, 244 turns):
  Baseline: 46 MB | RSS: 73 MB | Tool calls: 244

Session 2 - Heavy multi-hour session:
  Typical range: 50-100 MB depending on context size
```

Starts at ~50 MB, grows gradually as context accumulates. Multi-hour sessions with hundreds of tool calls typically stay under 100 MB. No memory leaks, no degradation, no restart needed.

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

See quota consumption, billing multipliers for premium models, per-request token counts, and reset dates. CLIO warns you when premium models cost extra so you can make informed choices.

---

## Screenshots

<table>
  <tr>
    <td width="50%">
      <h3>CLIO's Simple User Interface (1/2)</h3>
      <a href="https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/.images/clio1.png">
        <img src=".images/clio1.png"/>
      </a>
    </td>
    <td width="50%">
      <h3>CLIO's Simple User Interface (2/2)</h3>
      <a href="https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/.images/clio2.png">
        <img src=".images/clio2.png"/>
      </a>
    </td>
  </tr>
</table>

---

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

### First Prompt

Start with something grounded in a real repository:

```text
Read this project and tell me how configuration is loaded.
```

Or give CLIO a real bug to investigate:

```text
Find the bug causing the login endpoint to return 500 when the session is expired.
```

### Start Using CLIO

```bash
./clio --new          # New conversation
./clio --resume       # Resume last session
./clio --debug        # Debug mode
./clio --enable file_operations  # Restrict to specific tools
./clio --disable web_operations  # Block specific tools
```

---

## Slash Commands

| Command | Description |
|---------|-------------|
| `/help` | Show available commands |
| `/api` | Configure AI providers and models |
| `/config` | View/edit configuration |
| `/session` | Session management |
| `/file` | File operations |
| `/git` | Git operations |
| `/undo` | Revert AI changes from last turn |
| `/memory` | Long-term memory system |
| `/profile` | Build and manage user personality profile |
| `/todo` | Task management |
| `/agent` | Spawn and manage sub-agents |
| `/mux` | Terminal multiplexer panes (tmux/screen/Zellij) |
| `/mcp` | Model Context Protocol servers |
| `/skills` | Custom skill system and repositories |
| `/update` | Check for and install updates |
| `/usage` | API billing and quota tracking |
| `/stats` | Memory and performance stats |
| `/device` | Remote device management |
| `/theme` | Change color theme |
| `/clear` | Clear screen |
| `/exit` | Exit CLIO |

For complete command reference, see [docs/USER_GUIDE.md](docs/USER_GUIDE.md#slash-commands).

---

## Requirements

- **macOS 10.14+** or **Linux** (any modern distribution)
- **Perl 5.32+** (included with most systems)
- **Git** (for version control operations)
- **ANSI-compatible terminal**

---

## Documentation

| Document | What You'll Find |
|----------|-----------------|
| [User Guide](docs/USER_GUIDE.md) | Complete usage guide with examples |
| [Features](docs/FEATURES.md) | Every feature explained in detail |
| [Installation](docs/INSTALLATION.md) | Getting started with CLIO |
| [Providers](docs/PROVIDERS.md) | AI provider configuration guide |
| [Dependencies](docs/DEPENDENCIES.md) | System requirements and verification |
| [Sandbox Mode](docs/SANDBOX.md) | Security isolation options |
| [Architecture](docs/ARCHITECTURE.md) | System design and internals |
| [Memory](docs/MEMORY.md) | How CLIO remembers and learns across sessions |
| [Developer Guide](docs/DEVELOPER_GUIDE.md) | Contributing and extending CLIO |
| [Remote Execution](docs/REMOTE_EXECUTION.md) | Distributed AI workflows |
| [Multi-Agent](docs/MULTI_AGENT_COORDINATION.md) | Parallel agent coordination |
| [MCP Integration](docs/MCP.md) | Model Context Protocol support |
| [Custom Instructions](docs/CUSTOM_INSTRUCTIONS.md) | Per-project AI customization |
| [Security](docs/SECURITY.md) | Security model and secret redaction |
| [Performance](docs/PERFORMANCE.md) | Benchmarks and optimization |

---

## Part of the Ecosystem

CLIO is part of [Synthetic Autonomic Mind](https://github.com/SyntheticAutonomicMind) - a family of open source AI tools:

- **[SAM](https://github.com/SyntheticAutonomicMind/SAM)** - Native macOS AI assistant with voice control, document analysis, and image generation
- **[ALICE](https://github.com/SyntheticAutonomicMind/ALICE)** - Local Stable Diffusion server with web interface and OpenAI-compatible API
- **[SAM-Web](https://github.com/SyntheticAutonomicMind/SAM-web)** - Access SAM from iPad, iPhone, or any browser

---

## License

**GPL-3.0** - See [LICENSE](LICENSE) for details.

Created by Andrew Wyatt (Fewtarius) · [syntheticautonomicmind.org](https://www.syntheticautonomicmind.org) · [github.com/SyntheticAutonomicMind/CLIO](https://github.com/SyntheticAutonomicMind/CLIO)

---

## Support

- **Discussions:** [Join the conversation](https://github.com/orgs/SyntheticAutonomicMind/discussions)
- **Issues:** [Report bugs or request features](https://github.com/SyntheticAutonomicMind/CLIO/issues)