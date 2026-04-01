# Contributing to CLIO

Thank you for your interest in contributing to CLIO (Command Line Intelligence Orchestrator)!

## Quick Start

```bash
# Clone the repository
git clone https://github.com/fewtarius/clio.git
cd clio

# Check dependencies (pure Perl, minimal requirements)
./check-deps

# Install (optional - creates ~/.local/bin/clio symlink)
./install.sh

# Run CLIO
./clio --new
```

## Project Structure

```
lib/CLIO/Core/       # System core (APIs, workflow, config)
lib/CLIO/Tools/      # AI-callable tools
lib/CLIO/UI/         # Terminal UI (Chat, Markdown, Theme, Commands/)
lib/CLIO/Session/    # Session management
lib/CLIO/Memory/     # Context/memory system (YaRN, TokenEstimator)
lib/CLIO/Security/   # Auth, sandbox, secret redaction
lib/CLIO/Util/       # Utilities (JSON, PathResolver, YAML)
lib/CLIO/Coordination/ # Multi-agent broker/client
tests/unit/          # Unit tests (~88 tests)
tests/integration/   # Integration tests (~32 tests)
tests/e2e/           # End-to-end tests (~6 tests)
```

## Development Workflow

### The Unbroken Method

CLIO follows **The Unbroken Method** for human-AI collaboration. Key principles:

1. **Continuous Context** - Maintain momentum through collaboration checkpoints
2. **Complete Ownership** - If you find a bug, fix it
3. **Investigation First** - Read code before changing it
4. **Root Cause Focus** - Fix problems, not symptoms
5. **Complete Deliverables** - Finish what you start
6. **Structured Handoffs** - Document everything
7. **Learning from Failure** - Document mistakes to prevent repeats

### Before Making Changes

1. Read the relevant code in `lib/CLIO/`
2. Check existing tests in `tests/unit/` and `tests/integration/`
3. Run syntax checks: `perl -I./lib -c lib/CLIO/Your/Module.pm`

### Code Style

- **Perl 5.32+** with `use strict; use warnings; use utf8;`
- **4 spaces** indentation (never tabs)
- **UTF-8 encoding** for all files with `binmode(STDOUT, ':encoding(UTF-8)')`
- **POD documentation** for all modules
- **Minimal CPAN dependencies** - prefer core Perl modules
- **CLIO::Util::JSON** instead of `JSON::PP` or `JSON::XS` directly
- **CLIO::Core::Logger** for debug output (never bare `print STDERR`)
- **Carp `croak`** for errors (never bare `die`)

### Commit Messages

Follow conventional commit format:

```
type(scope): brief description

Problem: What was broken/incomplete
Solution: How you fixed it
Testing: How you verified the fix
```

Types: `feat`, `fix`, `refactor`, `docs`, `test`, `chore`

### Testing

Before committing:

```bash
# Syntax check all modules
find lib -name "*.pm" -exec perl -I./lib -c {} \;

# Run all tests
perl tests/run_all_tests.pl --all

# Run specific unit test
perl -I./lib tests/unit/test_your_feature.pl

# Integration test
./clio --debug --input "test query" --exit
```

The test suite has ~126 tests across unit, integration, and e2e categories. All must pass before merging.

## Adding New Features

### New Tool

1. Create `lib/CLIO/Tools/YourTool.pm` extending `CLIO::Tools::Tool`
2. Implement `get_tool_definition()` (flat format: `{name, description, parameters}`)
3. Implement `route_operation()` returning hashrefs (not JSON strings)
4. Register in `lib/CLIO/Tools/Registry.pm`
5. Add tests in `tests/unit/test_yourtool.pl`

### New Slash Command

1. Create `lib/CLIO/UI/Commands/YourCommand.pm` extending `Commands::Base`
2. Use display helpers (`display_command_header`, `display_key_value`, etc.)
3. Register in the command registry
4. See [COMMAND_OUTPUT_STANDARDS.md](docs/COMMAND_OUTPUT_STANDARDS.md) for formatting

### New Provider

1. Add provider configuration in `lib/CLIO/Core/Providers.pm`
2. Handle API differences in `lib/CLIO/Core/APIManager.pm`
3. Add model capabilities
4. Add tests

## Pull Request Process

1. Fork the repository
2. Create a feature branch
3. Make your changes with tests
4. Ensure all tests pass (`perl tests/run_all_tests.pl --all`)
5. Submit a PR with clear description

## Getting Help

- `AGENTS.md` - Technical reference for the codebase
- `docs/ARCHITECTURE.md` - System architecture overview
- `docs/DEVELOPER_GUIDE.md` - Detailed development guidance
- `docs/STYLE_GUIDE.md` - UI formatting standards

## License

By contributing, you agree that your contributions will be licensed under the GPL-3.0 License.
