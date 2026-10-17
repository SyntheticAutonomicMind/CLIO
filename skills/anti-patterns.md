---
name: anti-patterns
description: "Common anti-patterns to avoid in CLIO development"
---

# Anti-Patterns (What NOT To Do)

| Anti-Pattern | What To Do |
|--------------|------------|
| Skip `perl -c` before commit | Run syntax check on all changed files |
| Use `print STDERR` for logging | Use `log_debug()` / `log_error()` etc. |
| Label bugs as "out of scope" | Fix bugs you find |
| Leave `TODO` comments in code | Finish implementation before committing |
| Assume code behavior | Read the code, investigate first |
| Create duplicate utility code | Search codebase for existing implementations first |
| Commit without testing | Test syntax, run integration tests |
| Use bare `die` in modules | Use `croak` from Carp with eval |
| Create giant modules (>1000 lines) | Split into focused modules |
| Create summary docs in root | Use `scratch/` for working documents |
| Skip collaboration checkpoints | Use interact at key decision points |
| Technical jargon in action_desc | Use user-focused descriptions |
| Negative framing in messages | State what IS true and what to do |
| Changelog-style comments in code | Write comments for current state |
| Surface warnings for handled conditions | If the code handles it, use `log_debug` |
| Log operational noise at INFO | Demote to `log_debug` |
| Provide useless stats to the model | Include only actionable work product |
| Leak framework narration to the model | Inject work product only |
