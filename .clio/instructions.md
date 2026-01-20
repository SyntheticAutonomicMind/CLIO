# CLIO Project Instructions

**Project:** CLIO - Command Line Intelligence Orchestrator  
**Language:** Perl 5.32+  
**Architecture:** Tool-calling AI assistant with terminal UI

---

## Quick Start

When working on CLIO, follow these patterns:

### Code Standards

```perl
# All modules must:
use strict;
use warnings;
use utf8;

# End every .pm file with:
1;
```

### Debug Logging

```perl
# Always guard debug statements:
print STDERR "[DEBUG][ModuleName] message\n" if should_log('DEBUG');

# Import logger:
use CLIO::Core::Logger qw(should_log);
```

### Syntax Check Before Commit

```bash
perl -I./lib -c lib/CLIO/Path/To/Module.pm
```

---

## Key Directories

| Purpose | Path |
|---------|------|
| Main script | `clio` |
| Core modules | `lib/CLIO/Core/` |
| Protocol handlers | `lib/CLIO/Protocols/` |
| Tool definitions | `lib/CLIO/Tools/` |
| UI components | `lib/CLIO/UI/` |
| Session data | `sessions/` |
| Documentation | `docs/` |

---

## The Unbroken Method (Core Principles)

This project follows the Unbroken Method for human-AI collaboration.

### The Seven Pillars

1. **Continuous Context** - Never break the conversation. Use collaboration checkpoints.
2. **Complete Ownership** - If you find a bug, fix it. No "out of scope."
3. **Investigation First** - Read code before changing it. Never assume.
4. **Root Cause Focus** - Fix problems, not symptoms.
5. **Complete Deliverables** - No partial solutions. Finish what you start.
6. **Structured Handoffs** - Document everything for the next session.
7. **Learning from Failure** - Document mistakes to prevent repeats.

### Collaboration Checkpoints

Use the collaboration tool at key moments:

Checkpoint at:
- Session start (mandatory)
- Before implementation (share plan)
- After testing (share results)
- Session end (summary)

---

## Testing

```bash
# Start new session
./clio --new

# Start with debug
CLIO_DEBUG=1 ./clio --debug --new

# Test with input and exit
./clio --input "test prompt" --exit
```

---

## Commit Workflow

Use file-based commits to preserve formatting:

```bash
# Write message to file
cat > scratch/commit-msg.txt << 'EOF'
type(scope): brief description

Problem: What was broken
Solution: How you fixed it
Testing: What you verified
EOF

# Commit using file
git add -A
git commit -F scratch/commit-msg.txt
```

**Commit types:** feat, fix, refactor, docs, test, chore

---

## Anti-Patterns to Avoid

❌ Skip syntax check before commit  
❌ Use `print()` for debugging (use STDERR)  
❌ Label bugs as "out of scope"  
❌ Create partial implementations with TODOs  
❌ Assume how code works without reading it  
❌ Commit without testing  

---

## Architecture Overview

```
User Input → UI/Chat.pm → WorkflowOrchestrator
                                ↓
                         API with tools array
                                ↓
                          AI uses tools
                                ↓
                    ToolExecutor → Protocols
                                ↓
                         Results to AI
                                ↓
                        Response to user
```

**Tool calling flow:**
1. User asks question/makes request
2. AI decides which tools to use
3. ToolExecutor routes to Protocols
4. Results returned to AI
5. AI formulates response

---

## Module Naming

- `CLIO::Core::*` - Core system components
- `CLIO::Tools::*` - Tool definitions (OpenAI format)
- `CLIO::Protocols::*` - Protocol handlers (file, git, memory)
- `CLIO::UI::*` - Terminal UI components
- `CLIO::Session::*` - Session management
- `CLIO::Util::*` - Utility modules

---

## Key Files to Know

| File | Purpose |
|------|---------|
| `lib/CLIO/Core/WorkflowOrchestrator.pm` | Tool calling loop |
| `lib/CLIO/Core/ToolExecutor.pm` | Routes tool calls |
| `lib/CLIO/Tools/Registry.pm` | All tool definitions |
| `lib/CLIO/UI/Chat.pm` | Main terminal interface |
| `lib/CLIO/Session/Manager.pm` | Session persistence |
| `lib/CLIO/Core/APIManager.pm` | API provider integration |

---

## Documentation

See `docs/` for:
- `ARCHITECTURE.md` - System design
- `USER_GUIDE.md` - End user documentation
- `DEVELOPER_GUIDE.md` - Development patterns
- `SPECS/` - Technical specifications

---

**Remember:** Read code before changing it. Test before committing. Own every bug you find.
