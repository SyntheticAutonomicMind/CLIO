# CLIO GitHub Actions Integration

This document explains how to use CLIO as a GitHub Action for automated issue triage and PR review.

## Overview

CLIO can be integrated into your GitHub workflows to:

1. **Issue Triage** - Automatically analyze new issues for completeness, classify them, and attempt reproduction
2. **PR Review** - Analyze pull requests for security, style compliance, and code quality (coming soon)

## Authentication Setup

CLIO uses GitHub Copilot for AI analysis, which requires proper authentication.

### Creating the `CLIO_ACCESS` Secret

1. Create a GitHub Personal Access Token (PAT) with the following scopes:
   - `repo` - For reading repository code
   - `workflow` - For workflow operations
   - `copilot` - For accessing GitHub Copilot

2. Add the token as an organization secret (or repository secret):
   - Go to **Settings** > **Secrets and variables** > **Actions**
   - Click **New organization secret** (or **New repository secret**)
   - Name: `CLIO_ACCESS`
   - Value: Your PAT

**Important Security Notes:**
- The workflow uses `set +x` to prevent logging the token
- The token is written to a file mounted into the container, not passed as an environment variable to CLIO
- The token file is set with `chmod 600` permissions

## Quick Start

### For CLIO Repository

The issue triage workflow is already configured in `.github/workflows/issue-triage.yml`. It triggers automatically when issues are opened or edited.

### For Other Repositories

You can use the reusable CLIO triage action in your own workflows:

```yaml
name: Issue Triage

on:
  issues:
    types: [opened, edited]

jobs:
  triage:
    runs-on: ubuntu-latest
    # Skip bot-created issues
    if: github.event.issue.user.type != 'Bot'
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Triage Issue
        uses: SyntheticAutonomicMind/CLIO/.github/actions/clio-triage@main
        with:
          clio-token: ${{ secrets.CLIO_ACCESS }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
          issue-number: ${{ github.event.issue.number }}
          issue-title: ${{ github.event.issue.title }}
          issue-body: ${{ github.event.issue.body }}
          issue-author: ${{ github.event.issue.user.login }}
```

## Configuration

### Required Secrets

| Secret | Description |
|--------|-------------|
| `CLIO_ACCESS` | GitHub PAT with `repo`, `workflow`, and `copilot` scopes. Used for Copilot API access. |
| `GITHUB_TOKEN` | (Automatic) Built-in token for issue/label operations. No setup needed. |

### Action Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `clio-token` | Yes | - | GitHub PAT for Copilot authentication |
| `github-token` | No | `${{ github.token }}` | Token for GitHub API operations |
| `model` | No | `gpt-5-mini` | AI model to use |
| `issue-number` | Yes | - | Issue number to analyze |
| `issue-title` | Yes | - | Issue title |
| `issue-body` | Yes | - | Issue body content |
| `issue-author` | Yes | - | Issue author username |
| `prompt-file` | No | `.github/clio-prompts/issue-triage.md` | Path to custom prompt |
| `run-reproduction` | No | `true` | Run reproduction tests |
| `apply-labels` | No | `true` | Apply suggested labels |
| `post-comment` | No | `true` | Post triage comment |

### Action Outputs

| Output | Description |
|--------|-------------|
| `classification` | Issue type (bug, enhancement, etc.) |
| `severity` | Severity level (critical, high, medium, low) |
| `recommendation` | Next action (ready-for-review, needs-info, duplicate) |
| `completeness-score` | Completeness score (0-100) |
| `summary` | Brief analysis summary |
| `suggested-labels` | Comma-separated suggested labels |
| `analysis-json` | Full JSON analysis response |

## Customizing the Triage Prompt

Create a custom prompt file at `.github/clio-prompts/issue-triage.md`:

```markdown
# Custom Triage Prompt

Your project-specific instructions here...

## Response Format

Always respond with JSON:
\`\`\`json
{
  "completeness": {"score": 0-100, ...},
  "classification": "bug|enhancement|...",
  "severity": "critical|high|medium|low|none",
  "recommendation": "ready-for-review|needs-info|duplicate",
  "missing_info": [...],
  "affected_areas": [...],
  "suggested_labels": [...],
  "reproduction_test": "code or null",
  "summary": "brief summary"
}
\`\`\`
```

## How It Works

### Issue Triage Flow

```
1. New issue opened
         |
         v
2. Workflow triggered
         |
         v
3. Auth configured (github_tokens.json created)
         |
         v
4. CLIO container pulled
         |
         v
5. Issue analyzed with gpt-5-mini
   - Completeness check
   - Classification
   - Severity assessment
   - Affected areas identified
         |
         v
6. Reproduction test (if applicable)
   - CLIO writes a Perl test
   - Test runs in sandbox
   - Results reported
         |
         v
7. Labels applied
         |
         v
8. Comment posted
```

### The Analysis

CLIO evaluates issues on several dimensions:

**Completeness (0-100 score)**
- Does it have a clear description?
- Are reproduction steps provided?
- Is expected behavior stated?
- Environment details included?
- Error logs attached?

**Classification**
- `bug` - Something is broken
- `enhancement` - Feature request
- `documentation` - Docs need updating
- `question` - User needs help
- `invalid` - Spam or off-topic

**Severity**
- `critical` - Security, data loss, crashes
- `high` - Major functionality broken
- `medium` - Partially broken, workaround exists
- `low` - Minor or cosmetic

**Recommendation**
- `ready-for-review` - Issue is complete and actionable
- `needs-info` - More information required
- `duplicate` - Appears to duplicate another issue

## Labels

The workflow will suggest labels based on analysis. For these to be applied, the labels must already exist in your repository:

**Recommended Labels to Create:**
- `bug`, `enhancement`, `documentation`, `question`
- `priority:critical`, `priority:high`, `priority:medium`, `priority:low`
- `needs-info`, `needs-triage`
- `good first issue`, `help wanted`
- `area:core`, `area:tools`, `area:ui`, `area:session`, `area:memory`

## Security Considerations

1. **Token Handling**: The CLIO token is written to a file with `set +x` to prevent logging
2. **Sandbox Mode**: CLIO runs with `--sandbox` flag, restricting file access to the repository
3. **Read-Only Mount**: Repository is mounted read-only in the container
4. **Bot Detection**: Issues from bots are skipped to prevent loops
5. **Timeout**: Reproduction tests have a 30-second timeout

## Debugging

Analysis artifacts are uploaded for each run and retained for 7 days:
- `full_response.txt` - Complete CLIO output
- `analysis.json` - Parsed JSON analysis
- `reproduction_test.pl` - Generated test (if any)
- `issue_body.md` - Issue content as processed

Check the workflow run artifacts if you need to debug unexpected results.

## Limitations

1. **AI Limitations**: Analysis quality depends on the AI model and prompt
2. **Language Support**: Reproduction tests are currently Perl-specific (for CLIO project)
3. **Label Creation**: Labels must exist before they can be applied
4. **Rate Limits**: Subject to GitHub API and Copilot rate limits

## Coming Soon

- **PR Review**: Security analysis, style checking, and code review
- **Issue Linking**: Automatic duplicate detection
- **Test Suite Integration**: Run full test suite for reproduction
- **Multi-Language Support**: Generate tests for Python, JavaScript, etc.
