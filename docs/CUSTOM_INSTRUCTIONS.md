# CLIO Custom Instructions

## Overview

CLIO supports **project-specific custom instructions** via `.clio/instructions.md`. This enables you to customize CLIO's behavior, coding standards, methodologies, and tool usage for each project.

When you start a CLIO session in a project directory, CLIO automatically:
1. Looks for `.clio/instructions.md` in your project
2. Reads the instructions if the file exists
3. **Injects them into the system prompt** before sending requests to the AI
4. Uses those instructions to guide all tool operations and code suggestions

This way, the same CLIO installation can adapt its behavior to match your project's specific needs.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Creating Custom Instructions

### 1. Create the `.clio` Directory

```bash
mkdir -p .clio
```

### 2. Create `instructions.md`

```bash
touch .clio/instructions.md
```

### 3. Write Your Instructions

Edit `.clio/instructions.md` with your project's custom instructions. Here are some common use cases:

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Examples

### Example 1: Project Methodology

**Project:** Internal tools team using The Unbroken Method

```markdown
# CLIO Custom Instructions for Internal Tools

## Methodology

This project follows The Unbroken Method for AI collaboration:
- Seven Pillars: Continuous Context, Complete Ownership, Investigation First, 
  Root Cause Focus, Complete Deliverables, Structured Handoffs, Learning from Failure
- See ai-assisted/THE_UNBROKEN_METHOD.md for complete details

When working on this project:
1. Always maintain continuous context (no breaking conversation threads)
2. Own all discovered problems (no "out of scope" - fix related bugs)
3. Investigate thoroughly before implementing (read code first)
4. Fix root causes, not symptoms
5. Complete all work before ending (no "TODO" comments)
6. Document decisions in handoff files

## Code Standards

- Use strict/warnings: `use strict; use warnings;`
- Use 4 spaces for indentation (never tabs)
- POD documentation for all public modules
- 80-character line limit for readability
- Guard debug statements: `print STDERR "..." if $self->{debug};`

## Tool Usage

- File operations: Always read files before editing
- Git: Meaningful commit messages with problem/solution/testing
- Terminal: Test locally before assuming commands work
- Session context: Use todo_operations for multi-step work

## Success Criteria

Every completed task should feel satisfying:
- Code is production-ready (not 80% done)
- Tests pass and edge cases are handled
- Documentation is complete and accurate
- All discovered issues are resolved
```

### Example 2: Language-Specific Project

**Project:** Python project with specific conventions

```markdown
# CLIO Custom Instructions for DataPipeline

## Language & Tools

- Language: Python 3.10+
- Testing: pytest with coverage >90%
- Linting: black, isort, flake8
- Type checking: mypy
- Dependencies: See requirements.txt (no pip install, discuss new deps)

## Code Style

- Follow PEP 8 strictly
- Use type hints for all functions: `def process(data: list[dict]) -> bool:`
- Docstrings: Google style
- Line length: 88 characters (black default)
- Import sorting: isort with black compatibility

## Before Creating/Modifying Files

1. Check existing patterns in similar files
2. Read relevant tests to understand expected behavior
3. Consider edge cases:
   - Empty inputs
   - None/null values
   - Large datasets
   - Unicode/encoding issues

## Testing

- Write tests in tests/ directory
- Use pytest fixtures for common setup
- Aim for >90% coverage
- Test both happy path and error cases
- Run: `pytest tests/ --cov=src`

## Documentation

- Update docstrings immediately
- Update README.md if user-facing changes
- Add examples for complex functions
- Document any new dependencies
```

### Example 3: Minimal Project

**Project:** Simple script with basic guidelines

```markdown
# CLIO Instructions

Keep it simple:
- Use Perl core modules only (no CPAN)
- Maintain backwards compatibility with Perl 5.16+
- Document complex sections
- Test on Linux and macOS before committing

When in doubt, follow the existing code patterns.
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## How CLIO Uses Your Instructions

### 1. Injection into System Prompt

Your custom instructions are automatically appended to CLIO's system prompt:

```
[CLIO System Prompt - defines CLIO's behavior]
...

<customInstructions>
[Your .clio/instructions.md content]
</customInstructions>
```

This means:
- Your instructions have the **highest priority** (come last in the prompt)
- They override default CLIO behavior where they conflict
- The AI reads them for every request in that project

### 2. Per-Session Application

The instructions apply **during the session**, not permanently:
- Start new session in project directory → instructions loaded automatically
- Start session in different directory → different instructions (or none)
- Resume session → instructions from when session was created

### 3. Opt-Out

To skip custom instructions (useful for testing or special cases):

```bash
clio --no-custom-instructions --new
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Best Practices

### ✓ DO:
- **Keep instructions focused** - 1-3 key points per section
- **Use examples** - Show what you want, not just describe it
- **Reference existing files** - "See lib/CLIO/Module.pm for patterns"
- **Include success criteria** - How do you know when code is good?
- **Update instructions** - As project evolves, keep instructions current
- **Make instructions searchable** - Use clear section headers

### ✗ DON'T:
- **Repeat system prompt** - CLIO already knows about file operations, git, etc.
- **Make instructions too long** - Keep under 1000 words if possible
- **Use unsupported syntax** - Plain markdown only, no special formats
- **Assume CLIO remembers** - State important points even if obvious
- **Lock instructions away** - Keep in version control, not .gitignore

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## What You Can Customize

### Project Methodology
- Development workflow
- Code review standards
- Commit message format
- PR/issue conventions
- Testing requirements

### Code Standards
- Language-specific style guides
- Naming conventions
- Documentation requirements
- Performance standards
- Security considerations

### Tool Behavior
- Which tools to use/avoid
- Tool-specific settings
- Deployment procedures
- Environment setup
- Build/test commands

### Domain Knowledge
- Project architecture
- Key modules/components
- Common patterns
- Known limitations
- Business context

### Decision-Making
- When to optimize vs ship
- Risk tolerance
- Dependencies approval
- Scope boundaries
- Priority guidelines

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Troubleshooting

### Instructions Not Loading?

1. **Check file path**: Must be `.clio/instructions.md` (not `.github/copilot-instructions.md`)
2. **Check file format**: Must be valid UTF-8 text
3. **Check file permissions**: File must be readable by your user
4. **Enable debug mode**: `clio --debug --new` to see loading details

Output will show:
```
[DEBUG][InstructionsReader] Checking for instructions at: /path/to/project/.clio/instructions.md
[DEBUG][InstructionsReader] Successfully loaded instructions (1234 bytes)
```

### Instructions Not Being Used?

1. **Session started in wrong directory?** CLIO looks in current working directory
2. **Using `--no-custom-instructions` flag?** Remove it
3. **Old session?** Start a new session to load new instructions
4. **Check system prompt**: Instructions appear in `<customInstructions>` tags

### Conflicts With VSCode Copilot?

CLIO uses `.clio/instructions.md` (separate from VSCode's `.github/copilot-instructions.md`):
- CLIO reads: `.clio/instructions.md`
- VSCode Copilot reads: `.github/copilot-instructions.md`
- No conflicts!

You can have both files with different instructions for each tool.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Real-World Example: CLIO Project Itself

CLIO uses custom instructions via `.clio/instructions.md` (when working on CLIO):

```markdown
# CLIO Development

## The Unbroken Method

Follow The Unbroken Method (see ai-assisted/THE_UNBROKEN_METHOD.md):
1. Continuous Context - Never break the conversation
2. Complete Ownership - Fix all discovered problems
3. Investigation First - Read code before changing it
4. Root Cause Focus - Fix problems, not symptoms
5. Complete Deliverables - Finish completely, no TODOs
6. Structured Handoffs - Pass context to next session
7. Learning from Failure - Document lessons learned

## Code Standards

- Perl 5.20+ (use strict, warnings, feature 'say')
- Pod documentation for all modules
- 4-space indentation, never tabs
- Guard debug: if $self->{debug}
- No CPAN modules (use core only)
- Commit before major changes

## Testing

- Syntax check: perl -c lib/CLIO/Module.pm
- Run tests: ./tests/run_all_tests.pl
- All must pass before committing
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Integration With CLIO Features

### With todo_operations

Use custom instructions to define todo workflow:

```markdown
## Todo Workflows

When using todo_operations:
1. CREATE todos FIRST before starting work
2. Mark current todo "in-progress"
3. DO the work
4. Mark complete IMMEDIATELY after finishing
5. Start next todo
6. NEVER have multiple todos "in-progress"
```

### With Collaboration Checkpoints

Define collaboration patterns:

```markdown
## Collaboration Checkpoints

Use user_collaboration tool at:
1. Session start - confirm direction
2. After investigation - get approval before implementing
3. After implementation - validate testing results
4. Before commit - final review
5. Session end - confirm completion
```

### With Memory System

Document memory best practices:

```markdown
## Memory System

Use memory_operations to:
- Store project context and decisions
- Retrieve context between sessions
- Document lessons learned
- Share knowledge with other agents
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Summary

Custom instructions let you:
- ✓ Enforce project-specific standards automatically
- ✓ Pass knowledge to AI without repeating it every session
- ✓ Adapt CLIO's behavior to your project's needs
- ✓ Enable team consistency when working with multiple agents
- ✓ Document methodology and best practices in one place

**Get started:** Create `.clio/instructions.md` in your project and start customizing!
