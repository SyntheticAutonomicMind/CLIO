# Contributing to CLIO

Thank you for your interest in contributing to CLIO (Command Line Intelligence Orchestrator)!

## Quick Start

```bash
# Clone the repository
git clone https://github.com/fewtarius/clio.git
cd clio

# Check dependencies
./check-deps

# Run CLIO
./clio --new
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

1. Read the relevant code (`lib/CLIO/`)
2. Check existing tests in `tests/`
3. Run syntax checks: `perl -I./lib -c lib/CLIO/Your/Module.pm`

### Code Style

- **Perl 5.32+** with `use strict; use warnings; use utf8;`
- **4 spaces** indentation (never tabs)
- **UTF-8 encoding** for all files
- **POD documentation** for all modules
- **Minimal CPAN dependencies** (prefer core Perl)

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

# Run unit tests
perl -I./lib tests/unit/test_your_feature.pl

# Integration test
./clio --debug --input "test query" --exit
```

## Pull Request Process

1. Fork the repository
2. Create a feature branch
3. Make your changes with tests
4. Ensure all tests pass
5. Submit a PR with clear description

## Getting Help

- Read `AGENTS.md` for technical reference
- Read `.clio/instructions.md` for methodology
- Check `docs/DEVELOPER_GUIDE.md` for detailed guidance

## License

By contributing, you agree that your contributions will be licensed under the GPL-3.0 License.
