# Contributing to CLIO

Thank you for your interest in contributing to CLIO (Command Line Intelligence Orchestrator)!

## Quick Start

```bash
# Clone the repository
git clone https://github.com/SyntheticAutonomicMind/CLIO.git
cd CLIO

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
tests/unit/          # Unit tests (~109 tests)
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

CLIO does not gatekeep providers. A user can already point CLIO at any
OpenAI-compatible endpoint today through a custom provider, so refusing a
registry entry does not stop anyone from using the service. It only removes the
discovery and the disclosure. What we do instead is hold every entry to the same
bar, and make sure users can see what they are choosing.

**Every provider is a data destination.** CLIO sends prompts, source code, and
tool results to whichever provider is selected. Treat adding one as adding a
data path, not as adding a row to a table.

#### What a maintainer checks before merging

1. **The endpoint works.** A maintainer hits `/v1/models` and one real
   `chat/completions` request themselves. PR-description claims are not evidence.
2. **Capability metadata is real.** The feed must report context and output
   limits in fields CLIO reads. A provider that publishes its context length in
   the output field produces a collapsed prompt budget, and a test that only
   checks `provider-defaults.json` will not catch it - assert against resolved
   capabilities, not the fallback file.
3. **Published retention policy.** The provider states what it keeps and for how
   long. If it cannot say, that goes in the docs so users can decide with their
   eyes open.
4. **Gateway classification is correct.** Set `third_party_gateway` explicitly.
   `tests/unit/test_provider_gateway_disclosure.pl` fails if it is missing, and
   fails if a gateway is classified as first-party.
5. **Longevity is noted, not required.** Domain age, a status page, and an
   operational track record are not merge blockers, but they belong in the review
   so the risk is on the record. A provider that disappears leaves a dead entry
   and broken configs behind.

**Affiliated contributions are welcome and expected.** If you work for the
provider you are adding, say so in the issue and the PR. Disclosed affiliation is
not a problem; undisclosed affiliation is a reason to close.

#### Mechanical checklist

The registry lives in `lib/CLIO/Providers.pm` (not `lib/CLIO/Core/Providers.pm`).

1. Add the entry to `%PROVIDERS` with `third_party_gateway` set explicitly
2. Add `reasoning_schema` and context/output limits to
   `lib/CLIO/Core/model-data/provider-defaults.json`
3. Add a `model_id_format` entry to `lib/CLIO/Core/model-data/provider-mapping.json`
4. Set `route_timeout => 1` if requests traverse an intermediate hop
5. Set `url_detection_patterns` so a pasted base URL auto-detects the provider
6. Update the provider count in README.md (2 places), AGENTS.md,
   `docs/ARCHITECTURE.md` (2 places), `docs/DEVELOPER_DOCUMENTATION_GUIDE.md`,
   `docs/FEATURES.md`, and `docs/USER_GUIDE.md`.
   `tests/unit/test_provider_doc_count.pl` enforces this.
7. Add the row and section to `docs/PROVIDERS.md`, including the **Routes** column
8. Extend the matrices in `test_providers_flags.pl`,
   `test_provider_timeout_tiers.pl`, `test_provider_from_url.pl`, and
   `test_openai_compatible_mcm_url.pl`
9. Add the provider to the gateway or first-party list in
   `test_provider_gateway_disclosure.pl`
10. Add `tests/unit/test_<provider>_provider.pl` modeled on
    `tests/unit/test_standardcompute_provider.pl`

Model ids of the form `vendor/model` collide with CLIO provider names:
`_parse_model_provider` reads the first path segment as a provider. If your
model ids start with a name that is also a CLIO provider, document that users
must keep the provider prefix on hand-typed ids. Standard Compute hit this and
fixed it in `197996b`.

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

By contributing, you agree that your contributions will be licensed under the GPL-3.0-only License.
