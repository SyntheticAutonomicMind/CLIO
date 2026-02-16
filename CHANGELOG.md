# Changelog

All notable changes to CLIO are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- CONTRIBUTING.md for contributor guidelines
- CHANGELOG.md for version history
- llms.txt for LLM-friendly project description
- check-ai integration for AI-readiness scoring

## [2026.2.15] - 2026-02-15

### Added
- GitHub Actions issue triage workflow
- Multi-agent coordination system (Broker, Client, SubAgent)
- Remote execution via SSH with CLIO distribution
- Device registry for managing remote systems
- Sub-agent operations tool for spawning parallel agents

### Changed
- Improved terminal handling for forked processes
- Enhanced LTM save with process ID for race condition prevention

### Fixed
- Terminal corruption when spawning sub-agents with fork()
- LTM concurrent save race conditions

## [2026.2.4] - 2026-02-04

### Added
- Long-term memory (LTM) system for persistent learning
- Session state persistence (todos, tool results)
- Semantic search via code embeddings
- Tool result storage for large outputs

### Changed
- Enhanced memory operations with recall_sessions
- Improved session handoff documentation

## [2026.1.29] - 2026-01-29

### Added
- Initial public release
- Core AI agent loop with tool calling
- File operations (17 operations)
- Version control integration
- Terminal operations with safety validation
- Memory operations (session and project level)
- Web operations (search, fetch)
- Todo operations for task management
- Code intelligence (symbol search)
- User collaboration checkpoints
- Markdown rendering with syntax highlighting
- Theme support (catppuccin, gruvbox, etc.)

### Documentation
- AGENTS.md for AI agent instructions
- docs/ARCHITECTURE.md for system design
- docs/DEVELOPER_GUIDE.md for contributors
- docs/USER_GUIDE.md for end users
