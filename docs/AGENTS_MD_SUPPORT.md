# AGENTS.md Support in CLIO

## Overview

CLIO now supports the **AGENTS.md open standard** in addition to `.clio/instructions.md`.

**AGENTS.md** is an emerging open format for providing instructions to AI coding agents, supported by 60,000+ open-source projects and 20+ AI tools including Cursor, Aider, Jules, GitHub Copilot, and more.

## Why Support AGENTS.md?

- **Standards-compliant:** Works across the AI coding tool ecosystem
- **Universal instructions:** Write once, works with multiple AI tools  
- **Monorepo-friendly:** Supports nested AGENTS.md files for package-specific guidance
- **Community-driven:** Stewarded by the Agentic AI Foundation under the Linux Foundation

## How It Works

CLIO merges TWO instruction sources:

1. **`.clio/instructions.md`** - CLIO-specific operational behavior
   - The Unbroken Method and CLIO methodologies
   - CLIO tool usage patterns
   - Session handoff procedures
   - Collaboration checkpoint discipline

2. **`AGENTS.md`** - Project-level context (open standard)
   - Build and test commands
   - Code style and conventions
   - Project architecture
   - Domain knowledge

Both files are optional. If both exist, they are merged in this order:
1. `.clio/instructions.md` (CLIO operational identity)
2. `AGENTS.md` (project domain knowledge)

## Quick Start

### Option 1: Use AGENTS.md Only (Recommended for Most Projects)

Create `AGENTS.md` at your project root:

```markdown
# AGENTS.md

## Setup Commands

- Install deps: `npm install`
- Start dev server: `npm run dev`
- Run tests: `npm test`

## Code Style

- TypeScript strict mode
- Single quotes, no semicolons
- Use functional patterns where possible

## Testing Instructions

- Run full test suite before committing
- Aim for 80%+ coverage on new code
```

### Option 2: Use Both (Recommended for CLIO Power Users)

**AGENTS.md** for universal guidance:
```markdown
# AGENTS.md

## Setup Commands
- Install: `pip install -r requirements.txt`
- Test: `pytest tests/`

## Code Style
- Python 3.10+
- Follow PEP 8
```

**.clio/instructions.md** for CLIO-specific behavior:
```markdown
# CLIO Instructions

## Methodology
This project uses The Unbroken Method.
Use collaboration checkpoints before implementation.

## CLIO Tool Usage
- Always read files before editing
- Use todo_operations for multi-step work
```

### Option 3: Use .clio/instructions.md Only

If you only use CLIO (not other AI tools):

```bash
mkdir -p .clio
cat > .clio/instructions.md << 'EOF'
# CLIO Instructions

[Your CLIO-specific instructions here]
EOF
```

## Monorepo Support

CLIO walks up the directory tree to find `AGENTS.md`, allowing package-specific instructions:

```
/workspace/
├── AGENTS.md              <- General workspace guidance
├── packages/
│   ├── frontend/
│   │   ├── AGENTS.md     <- Frontend-specific guidance (wins when in frontend/)
│   │   └── src/
│   └── backend/
│       ├── AGENTS.md     <- Backend-specific guidance (wins when in backend/)
│       └── src/
```

**The closest AGENTS.md wins.** This allows each package to override or extend the workspace-level instructions.

## How CLIO Uses Your Instructions

When you start a CLIO session:

1. CLIO searches for `.clio/instructions.md` in the current directory
2. CLIO searches for `AGENTS.md` (walks up directory tree until found)
3. Both sources are merged (if found)
4. The combined instructions are injected into the system prompt:

```
[CLIO System Prompt]
...
<customInstructions>
[.clio/instructions.md content (if exists)]

---

[AGENTS.md content (if exists)]
</customInstructions>
```

5. The AI reads these instructions for every request in that session

## Skipping Custom Instructions

To skip both instruction sources (useful for testing or auditing):

```bash
clio --no-custom-instructions --new
```

This skips BOTH `.clio/instructions.md` AND `AGENTS.md`.

## Debug Mode

To see which instruction files were loaded:

```bash
clio --debug --new
```

Output will show:
```
[DEBUG][InstructionsReader] Checking for .clio/instructions.md at: /path/to/project/.clio/instructions.md
[DEBUG][InstructionsReader] Loaded .clio/instructions.md (1234 bytes)
[DEBUG][InstructionsReader] Checking for AGENTS.md at: /path/to/project/AGENTS.md
[DEBUG][InstructionsReader] Found AGENTS.md at: /path/to/project/AGENTS.md
[DEBUG][InstructionsReader] Loaded AGENTS.md (567 bytes)
[DEBUG][InstructionsReader] Combined instructions: 1801 bytes total
[DEBUG][PromptManager] Appending custom instructions (1801 bytes)
```

## AGENTS.md Specification

For more information about the AGENTS.md standard, see:
- **Website:** https://agents.md/
- **Examples:** 60,000+ repos on GitHub using AGENTS.md
- **Supported tools:** Cursor, Aider, Jules, GitHub Copilot, Devin, and 15+ more

## Backward Compatibility

Existing CLIO projects using `.clio/instructions.md` continue to work unchanged. No migration needed.

## Best Practices

**Use AGENTS.md for:**
- Build/test commands that any AI tool needs to know
- Code style that applies to all contributors
- Project architecture and conventions
- General domain knowledge

**Use .clio/instructions.md for:**
- CLIO-specific methodologies (e.g., The Unbroken Method)
- CLIO collaboration checkpoint requirements
- CLIO tool usage preferences
- Session handoff procedures

**Use both when:**
- You want instructions that work across multiple AI tools (AGENTS.md)
- AND you want CLIO-specific enhancements (.clio/instructions.md)

## Future Enhancements

Potential future improvements:
- Support for AGENTS.md variables and templating
- Caching instructions per session (avoid re-reading every message)
- Validation and linting of instruction syntax
- Support for `.clio/instructions/` directory with multiple files
