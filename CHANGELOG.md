# CHANGELOG

All notable changes to CLIO (Command Line Intelligence Orchestrator) are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added
- Session auto-pruning configuration (`session_auto_prune`, `session_prune_days`)
- `/session trim [days]` command to manually prune old sessions
- `/memory stats` and `/memory prune [days]` commands for LTM management
- `prune_ltm` and `ltm_stats` operations for agent self-grooming
- `CLIO::UI::TerminalGuard` module for RAII-style terminal state protection
- `CLIO::Test::MockAPI` module for testing without API keys
- Secure directory permissions (0700) for sessions and config directories
- Performance benchmark suite (`tests/benchmark.pl`)
- Comprehensive end-to-end test suite (`tests/e2e/e2e_comprehensive_test.pl`)
- PERFORMANCE.md documentation with metrics and optimization tips

### Fixed
- All 14 integration tests now pass (previously 6 failing)
- Test suite module path issues when tests change working directory
- Session continuity test now properly releases locks between operations
- ToolExecutor now includes `success: 1` in successful tool results

### Changed
- Disabled test for unimplemented AutoCapture feature (test_ltm_autocapture.pl.disabled)

## [20260129.6] - 2026-01-29

### Added
- `--no-ltm` and `--incognito` CLI flags for privacy mode (no long-term memory storage)
- Built-in skills system with `/design` and `/init` as first skills
- Agent Client Protocol (ACP) - JSON-RPC 2.0 over stdio for programmatic control
- Context window compression using YaRN algorithm
- LM Studio support for local models

### Changed
- Major UI refactoring: extracted 16 command modules from Chat.pm
- Commands now organized in `lib/CLIO/UI/Commands/` directory
- Default GitHub Copilot model changed to `claude-haiku-4.5`
- Improved token budget calculation with actual tool schema token counting

### Fixed
- `/multiline` command broken by refactoring
- Spinner interference with user input
- Tool_calls stripped from assistant messages when provider doesn't support role=tool
- Context loss on malformed tool JSON
- Infinite loop on malformed JSON tool parameters

## [20260128] - 2026-01-28

### Added
- `/design` command for PRD (Product Requirements Document) creation
- `/init` command for project initialization with PRD integration
- Markdown rendering for user messages
- Intelligent error-specific retry strategies
- Comprehensive busy spinner coverage
- 4 memory integration points for LTM

### Changed
- Enhanced system prompt with mandatory collaboration checkpoints
- Improved user_collaboration protocol enforcement

### Fixed
- Duplicate CLIO: prompts in busy indicator flow
- Automatic session learnings prompt removed on exit
- First user message preserved during context trimming
- Debug output properly guarded with logging checks

## [20260127] - 2026-01-27

### Added
- Session-level API configuration with `--session` flag
- Premium request tracking for GitHub Copilot billing
- YaRN context window management
- Long-term memory (LTM) with discoveries, solutions, and patterns

### Changed
- API key storage moved to user config directory
- Provider defaults now come from CLIO::Providers module

### Fixed
- API manager streaming response handling
- Token estimation accuracy improvements

## [20260126] - 2026-01-26

### Added
- Multi-provider support (OpenAI, GitHub Copilot, DeepSeek, llama.cpp, SAM)
- `/api` command suite for API configuration
- `/billing` command for usage tracking
- Session locking to prevent concurrent access

### Changed
- Complete rewrite of API layer with provider abstraction
- Improved error handling with exponential backoff

### Fixed
- Terminal corruption on interrupt signals
- UTF-8 encoding issues in streaming responses

## [20260125] - 2026-01-25

### Added
- Tool-calling AI agent architecture
- 17 file operations (read, write, search, etc.)
- Version control integration (git operations)
- Terminal operations with command execution
- Memory operations (store, retrieve, search)
- Web operations (fetch URL, search)
- Todo list management for task tracking
- Code intelligence (symbol search, usages)
- User collaboration tool for checkpoints

### Changed
- Initial architecture established
- Core workflow orchestration implemented

---

## Version Numbering

CLIO uses date-based versioning: `YYYYMMDD.revision`

Example: `20260129.6` = January 29, 2026, revision 6

## Links

- [Repository](https://github.com/fewtarius/clio)
- [Documentation](docs/)
- [Issue Tracker](https://github.com/fewtarius/clio/issues)
