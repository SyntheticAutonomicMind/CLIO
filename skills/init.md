---
name: init
description: "Use this skill when initializing CLIO for a project that needs custom instructions"
---

I need you to initialize CLIO for this project. This is a comprehensive setup task that involves analyzing the codebase and creating custom project instructions.

## CRITICAL: Licensing

**Do NOT create LICENSE files, add license headers, or assume any license.**
If the project has no license, note it in your report but do not create one.
License selection requires an explicit conversation with the user - never default to MIT or any other license.

## Your Tasks:

### 1. Fetch CLIO's Template Documents

Fetch BOTH of these template files to use as schemas:

**A) Methodology template** - Prefer the local copy shipped with CLIO at `skills/templates/instructions.md.template` in the installation directory. If the local file is not found, fall back to:
https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/docs/templates/instructions.md.template

This defines HOW agents work - The Unbroken Method, collaboration checkpoints, workflow protocols.

**B) Technical reference template** - Prefer the local copy shipped with CLIO at `skills/templates/AGENTS.md.template` in the installation directory. If the local file is not found, fall back to:
https://raw.githubusercontent.com/SyntheticAutonomicMind/CLIO/main/docs/templates/AGENTS.md.template

This defines WHAT technical knowledge agents need - setup commands, code style, testing, architecture.
The template is a generic schema with [PLACEHOLDER] tokens ready to fill in.

**CRITICAL - Understand the Separation:**
- `.clio/instructions.md` = Process/methodology (HOW to work)
- `AGENTS.md` = Technical reference (WHAT to build)
- **NO overlap** - methodology in one, technical details in the other

### 2. Analyze This Codebase

Do a thorough analysis of this project:
- Programming language(s), frameworks, libraries
- Project structure and architecture  
- Existing tests, CI/CD, documentation
- Code style patterns and conventions
- Build and test commands
- Common development workflows
- Entry points and key modules

### 3. Create Project Instructions

**A) `.clio/instructions.md`** - Methodology (HOW to work)

**DO:** Use the fetched instructions.md.template as-is UNLESS this project has specific workflow requirements
**DO NOT:** Put technical details here (commands, file paths, stack info) - those go in AGENTS.md
**CUSTOMIZE ONLY IF:** This project needs methodology adjustments (rare!)

Most projects should use the template unchanged.

**B) `AGENTS.md`** - Technical Reference (WHAT to build)

**DO:** Use the fetched AGENTS.md.template as a fill-in-the-blank schema
**DO:** Replace all [PLACEHOLDER] tokens with this project's technical details
**DO NOT:** Include methodology, checkpoints, or workflow protocols (those are in .clio/instructions.md)
**DO NOT:** Include any CLIO-specific content (modules, packages, provider references) - the template already has it removed

**Anti-Duplication Rules:**

- If it's about HOW to work (checkpoints, workflow, error handling) -> `.clio/instructions.md`
- If it's about WHAT to build (commands, syntax, architecture) -> `AGENTS.md`
- When in doubt: Technical = AGENTS.md, Process = instructions.md

### 4. Verify .gitignore

CLIO automatically manages .gitignore for the .clio/ directory on startup.
Verify that .gitignore contains these entries (add them if missing):
```
.clio/*
!.clio/instructions.md
```
This ignores all CLIO internals while keeping the project instructions committed.
Do NOT add individual .clio/ subdirectories - the wildcard handles everything.

### 5. Initialize or Update Git

Initialize git if needed, or add/commit the .clio/ directory and AGENTS.md.

### 6. Report What You Did

Provide a summary of:
- Project analysis findings
- What you put in `.clio/instructions.md` (used template as-is or customized?)
- Key sections of `AGENTS.md` you created (from template, with [PLACEHOLDER] tokens filled in)
- Setup completed

Begin now - use your tools to complete all these tasks.
