# CLIO - Command Line Intelligence Orchestrator

**An AI code assistant for people who live in the terminal. Portable, privacy-first, and designed for real work.**

---

## Why I Built CLIO

I built CLIO for myself. As someone who prefers working in the terminal, I wanted an AI assistant that felt native to my workflow. One that respected my privacy, worked anywhere Perl runs, and gave me full control over my code and tools. I couldn’t find anything that met those needs, so I created CLIO.

Starting with version 20260119.1, CLIO has been building itself. All of my development is now done through pair programming with AI agents using CLIO.

CLIO is part of the [Synthetic Autonomic Mind (SAM)](https://github.com/SyntheticAutonomicMind) organization, which is dedicated to building user-first, privacy-respecting AI tools. If you value transparency, portability, and the power of the command line, CLIO is for you.

---

## What Makes CLIO Different

- **Terminal-First Experience:** CLIO runs entirely in your terminal, with professional markdown rendering, color themes, and streaming output. No browser, no GUI overlays, just a clean, native interface.
- **Portable & Minimal:** No CPAN, npm, or pip dependencies, just Perl core modules. Install and run CLIO on any modern macOS or Linux system in minutes.
- **Tool-Powered, Not Simulated:** All file, git, and terminal operations are performed using real system tools. Every action is described in real time, so you always know what’s happening.
- **Privacy & Control:** Your code and conversations stay on your machine. Only the minimum context needed for AI is sent to providers, and all sessions and memories are stored locally.
- **Persistent Sessions:** Pick up exactly where you left off, with full conversation and tool history.
- **Scriptable & Extensible:** Designed for users who prefer Vim to VSCode, tmux to tabs, and scripts to clicks. CLIO fits into your workflow, not the other way around.

---

## Who is CLIO For?

- Terminal-first developers, sysadmins, and power users
- Anyone who values privacy, transparency, and local control
- Users who want a professional, readable terminal UI (with real markdown rendering)
- People who prefer tools that work everywhere, without external dependencies

---

## Core Features

- **File Operations:** Read, write, search, edit, and manage files
- **Version Control:** Full Git integration (status, diff, commit, branch, merge)
- **Terminal Execution:** Run commands and scripts directly from conversation
- **Memory System:** Store and recall information across sessions
- **Todo Lists:** Manage tasks within your workflow
- **Web Operations:** Fetch and analyze web content
- **Custom Instructions:** Per-project AI behavior via `.clio/instructions.md` (enforce standards, pass methodology, adapt to your workflow)
- **Action Transparency:** See exactly what CLIO is doing in real-time, with clear, contextual descriptions for all tool operations
- **Persistent Session Management:** Conversations saved automatically with full history; resume any session exactly where you left off
- **Beautiful Terminal UI:** Professional markdown rendering with syntax highlighting, color-coded system messages, and streaming responses
- **Multiple AI Backend Support:** GitHub Copilot (default), OpenAI, DeepSeek, llama.cpp, SAM, and more

---

## Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/SyntheticAutonomicMind/CLIO.git
cd clio

# Run the installer
sudo ./install.sh
```

For detailed installation options and troubleshooting, see [docs/INSTALLATION.md](docs/INSTALLATION.md).

### Configure Your AI Provider

**GitHub Copilot** (Default - Recommended)

No configuration needed! Just start CLIO and run `/login`:

```bash
./clio
: /login
# Follow the browser prompts to authorize
```

**Alternative Providers**

Use `/api` commands within CLIO:

```bash
./clio
: /api provider openai
: /api key YOUR_OPENAI_API_KEY
: /config save
```

See [docs/USER_GUIDE.md](docs/USER_GUIDE.md) for full provider configuration details.

### Start Your First Session

```bash
# Start a new conversation
./clio --new

# Resume your last session
./clio --resume

# Enable debug mode
./clio --debug
```

---

## Example Usage

```
YOU: Please list the files in the current directory

SYSTEM: [file_operations] - listing ./ (15 files, 8 directories)

CLIO: I can see you have several files here:

**Directories:**
- lib/ (source code modules)
- docs/ (documentation)
- scripts/ (utility scripts)

**Files:**
- clio (main executable)
- README.md
- install.sh
...
```

---

## Session Management

CLIO automatically saves all conversations:

```bash
# Start a new session
./clio --new

# Resume last session
./clio --resume

# Resume specific session
./clio --resume sess_20260118_143052

# List all sessions
ls sessions/
```

Sessions include:
- Full conversation history
- Tool operations performed
- Memory context
- Timestamps

---

## Configuration

CLIO is configured **interactively** using slash commands:

```bash
# GitHub Copilot (default) - just login
: /login

# Other providers - use /api commands
: /api provider openai
: /api key YOUR_API_KEY
: /api model gpt-4o
: /config save

# View current configuration
: /config show
: /api provider
: /api model
```

**Optional: Environment variables** (advanced users)

```bash
# Session Directory
export CLIO_SESSION_DIR="$HOME/.clio/sessions"
```

**Note:** API keys and provider selection are configured with `/api` commands, not environment variables. Use `clio --debug` for debug output.

For advanced configuration options, see [docs/USER_GUIDE.md](docs/USER_GUIDE.md).

---

## Custom Instructions

CLIO supports **per-project custom instructions** via `.clio/instructions.md`. This lets you:
- Enforce project-specific coding standards automatically
- Pass methodology and best practices to CLIO
- Adapt CLIO's behavior to your workflow
- Share project context without repeating it every session

### Quick Example

Create `.clio/instructions.md` in your project:

```markdown
# CLIO Custom Instructions

This project follows The Unbroken Method for AI collaboration.
See ai-assisted/THE_UNBROKEN_METHOD.md for complete details.

## Standards

- Perl 5.20+ with strict/warnings
- 4-space indentation (never tabs)
- POD documentation for all modules
- Always investigate code before making changes
- Fix all discovered problems (complete ownership)
- No "TODO" comments in final code
```

When you start CLIO in that directory, it automatically:
1. Reads `.clio/instructions.md`
2. **Injects your instructions into the AI system prompt**
3. Uses them to guide all code suggestions and tool operations

The same CLIO installation adapts its behavior to match each project's needs!

For complete documentation and examples, see [docs/CUSTOM_INSTRUCTIONS.md](docs/CUSTOM_INSTRUCTIONS.md).

---

## Requirements

- **Operating System:** macOS 10.14+ or Linux (any modern distribution)
- **Perl:** Version 5.20 or higher (core modules only, no CPAN dependencies)
- **Git:** Required for version control operations
- **Terminal:** Any ANSI-compatible terminal emulator

---

## Documentation

- **[User Guide](docs/USER_GUIDE.md):** Complete usage guide with examples
- **[Architecture](docs/ARCHITECTURE.md):** System design and component overview
- **[Custom Instructions](docs/CUSTOM_INSTRUCTIONS.md):** Per-project AI behavior and standards enforcement
- **[Feature Completeness](docs/FEATURE_COMPLETENESS.md):** Status of all features (what's done, what's partial, what's planned)
- **[Installation Guide](docs/INSTALLATION.md):** Setup and installation instructions
- **[Developer Guide](docs/DEVELOPER_GUIDE.md):** Extending CLIO and contributing
- **[Technical Specs](docs-internal/):** Detailed specifications (protocols, UI, memory, etc.)

---

## Design Philosophy

- **Terminal-First:** Designed for developers who live in the terminal. No web browser required, no GUI overhead.
- **Action Transparency:** Every tool operation shows exactly what it's doing. You always know what CLIO is reading, writing, or executing.
- **Persistent Context:** Sessions persist across restarts. Your conversation history and context are never lost.
- **Professional Output:** Markdown rendering that's actually readable in the terminal, with syntax highlighting and proper formatting.
- **Tool-Powered:** The AI doesn't hallucinate file contents or command output, it uses real tools to interact with your system.
- **Privacy-Conscious:** Your code and conversations stay on your machine. API calls only send the context necessary for the current request.

---

## Architecture

CLIO uses a modular Perl-based architecture:

```
User Input -> SimpleChat UI -> SimpleAIAgent -> Tool Selection
                                                   v
                                             Tool Executor
                                                   v
                          ┌────────────────────────┼──────────────────────┐
                          v                        v                      v
                   File Operations         Version Control      Terminal Operations
                          v                        v                      v
                    Memory System            Todo Lists            Web Operations
                          v                        v                      v
                          └────────────────────────┴──────────────────────┘
                                                   v
                                            API Manager
                                                   v
                       GitHub Copilot / OpenAI / DeepSeek / llama.cpp / SAM
                                                   v
                                            Response Processing
                                                   v
                                        Markdown Renderer -> User
```

See [docs/SPECS/ARCHITECTURE.md](docs/SPECS/ARCHITECTURE.md) for detailed system design.

---

## Contributing

Contributions are welcome! Please see [docs/DEVELOPER_GUIDE.md](docs/DEVELOPER_GUIDE.md) for:
- Code organization and structure
- How to add new tools
- How to add new AI providers
- Testing guidelines
- Code standards

---

## License

CLIO is licensed under the GNU General Public License v3..

See [LICENSE](LICENSE) for full license text.

---

## Support

- **Issues:** [GitHub Issues](https://github.com/SyntheticAutonomicMind/CLIO/issues)
- **Discussions:** [GitHub Discussions](https://github.com/SyntheticAutonomicMind/CLIO/discussions)
