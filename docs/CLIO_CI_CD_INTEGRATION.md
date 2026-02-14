# Using CLIO for Automated Issue Triage and PR Review

This guide explains how to add CLIO-powered automation to your GitHub repository for:
- **Issue Triage:** Automatic classification, prioritization, and routing of new issues
- **PR Review:** Automated code review against your project's style guide

## Prerequisites

1. **CLIO Docker image available** at `ghcr.io/syntheticautonomicmind/clio:latest`
2. **GitHub repository secret** `CLIO_ACCESS` with a GitHub OAuth token that has Copilot access

### Obtaining CLIO_ACCESS Token

1. Run `clio --auth` locally to authenticate with GitHub Copilot
2. The token is saved at `~/.clio/github_tokens.json`
3. Copy the `github_token` value
4. Add it as a repository secret named `CLIO_ACCESS`

```bash
# Get your token
cat ~/.clio/github_tokens.json | jq -r '.github_token'
```

## Quick Start

Copy these files to your repository:

```
.github/
├── workflows/
│   ├── issue-triage.yml
│   └── pr-review.yml
└── clio-prompts/
    ├── issue-triage.md
    └── pr-review.md
```

## File Structure Explained

### Workflow Files

**`.github/workflows/issue-triage.yml`** - Triggers on:
- `issues: opened, edited, reopened`
- `issue_comment: created` (for follow-up when user responds)

**`.github/workflows/pr-review.yml`** - Triggers on:
- `pull_request: opened, synchronize, reopened, review_requested`

### Prompt Files

**`.github/clio-prompts/issue-triage.md`** - Instructions for the issue triage agent
**`.github/clio-prompts/pr-review.md`** - Instructions for the PR review agent

## How It Works

### Architecture

```
1. GitHub Event (issue/PR created)
        ↓
2. Workflow starts, prepares workspace with project files
        ↓
3. Workflow writes issue/PR info to files (ISSUE_INFO.md, PR_DIFF.txt, etc.)
        ↓
4. CLIO container runs with task instruction via --input
        ↓
5. CLIO agent reads files, analyzes, writes JSON result to file
        ↓
6. Workflow reads JSON and takes actions (labels, comments, assignments)
```

### Key Design Principles

1. **File-based communication:** Agent writes JSON to `/workspace/triage.json` or `/workspace/review.json` using `file_operations`. No stdout parsing.

2. **Headless mode:** Agent is clearly told it's in CI/CD mode with no human present. Using `user_collaboration` will hang the workflow.

3. **Minimal logs:** `CLIO_LOG_LEVEL=WARNING` reduces API streaming noise.

4. **Fallback handling:** If agent fails to produce valid JSON, workflows use sensible defaults.

## Customization

### Issue Triage Prompt

Edit `.github/clio-prompts/issue-triage.md` to customize:
- Classification categories
- Priority definitions
- Area labels
- Default assignee

### PR Review Prompt

Edit `.github/clio-prompts/pr-review.md` to customize:
- Style requirements for your project
- Security patterns to flag
- Documentation requirements

### Adding Project Context

The workflows copy your repository to `/tmp/clio-workspace`, so the agent can read:
- `AGENTS.md` - AI agent guidelines
- `docs/STYLE_GUIDE.md` - Coding standards
- Any other documentation

Reference these in your prompts so the agent benchmarks against your standards.

## Example Issue Triage Output

```json
{
  "completeness": 85,
  "classification": "bug",
  "severity": "medium",
  "priority": "medium",
  "recommendation": "ready-for-review",
  "labels": ["bug", "area:core", "priority:medium"],
  "assign_to": "maintainer",
  "summary": "Clear bug report with reproduction steps. Affects session persistence."
}
```

## Example PR Review Output

```json
{
  "recommendation": "needs-changes",
  "security_concerns": [],
  "style_issues": [
    "Missing 'use strict' in new module (required per docs/STYLE_GUIDE.md)"
  ],
  "documentation_issues": [],
  "test_coverage": "adequate",
  "breaking_changes": false,
  "suggested_labels": ["needs-changes", "style-issues"],
  "summary": "Good implementation but missing required pragma.",
  "detailed_feedback": [
    "Add 'use strict; use warnings; use utf8;' at top of lib/NewModule.pm"
  ]
}
```

## Troubleshooting

### Agent uses user_collaboration anyway

The agent's system prompt has strong checkpointing instructions. Ensure your prompt clearly states:
- "HEADLESS CI/CD MODE"
- "DO NOT use user_collaboration - it will hang forever"
- "NO HUMAN IS PRESENT"

### JSON not found

Check the workflow artifacts for:
- `full_response.txt` - Raw CLIO output
- `triage.json` / `review.json` - The expected output file

If the JSON file is missing, the agent may not have understood the instruction to write to file.

### Workflow hangs

If the agent calls `user_collaboration`, the workflow will wait forever for input. Check logs for "Requesting your input" messages.

Kill the workflow and update your prompt to be more explicit about headless mode.

## Complete Example Files

See the CLIO repository for reference implementations:
- https://github.com/SyntheticAutonomicMind/CLIO/tree/main/.github/workflows
- https://github.com/SyntheticAutonomicMind/CLIO/tree/main/.github/clio-prompts
