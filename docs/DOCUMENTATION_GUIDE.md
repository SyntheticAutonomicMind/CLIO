# CLIO Documentation Style Guide

**For user-facing documentation: USER_GUIDE.md, INSTALLATION.md, README.md, tutorials**

---

## Purpose

This guide defines writing standards for CLIO's user-facing documentation. Consistent style, tone, and formatting make documentation easier to read, understand, and maintain.

---

## Tone & Voice

### Be Direct and Concise

- **Don't:** "It might be helpful if you could potentially try running the command with the debug flag to see if that provides any additional information that could help diagnose the issue."
- **Do:** "Run the command with `--debug` to see diagnostic output."

### Be Professional but Friendly

- **Don't:** "OMG! CLIO is super awesome at reading files!"
- **Do:** "CLIO reads files directly from your filesystem, ensuring accurate content analysis."

### Avoid Jargon (Unless Explaining It)

- **Don't:** "CLIO uses MCP-compliant protocol handlers for IPC."
- **Do:** "CLIO uses protocol handlers (standardized message formats) to communicate with AI providers."

### Write in Active Voice

- **Don't:** "The file will be read by CLIO when the command is executed."
- **Do:** "CLIO reads the file when you run the command."

### Address the User Directly

- **Don't:** "Users should configure their API key before starting."
- **Do:** "Configure your API key before starting."

---

## Formatting Standards

### Headers

Use descriptive headers that form a clear outline:

```markdown
# Main Title (H1 - ONE per document)

## Major Section (H2)

### Subsection (H3)

#### Detail (H4 - use sparingly)
```

**Guidelines:**
- ONE H1 per document (the title)
- H2 for major sections (Installation, Configuration, Usage, etc.)
- H3 for subsections under major sections
- H4 for fine details (use only when necessary)
- Headers should be descriptive: "Installing on Linux" not just "Installation"

### Code Blocks

Always specify the language for syntax highlighting:

````markdown
```bash
./clio --new
```

```perl
my $config = CLIO::Core::Config->new();
```

```json
{
  "provider": "github_copilot",
  "model": "gpt-5"
}
```
````

**When to use code blocks:**
- Commands the user should run: `bash`
- Code examples: `perl`, `python`, `javascript`, etc.
- Configuration files: `json`, `yaml`, `toml`, etc.
- Output examples: `plaintext` or no language

**Inline code:**
- File paths: `` `~/.clio/config.json` ``
- Command names: `` `/config`, `/api`, `/models` ``
- Variable names: `` `api_key` ``
- Short values: `` `true`, `false` ``

### Lists

**Unordered lists** for items without sequence:

```markdown
- Terminal-native interface
- Tool-powered operations
- Session persistence
```

**Ordered lists** for steps or sequences:

```markdown
1. Install CLIO
2. Configure API provider
3. Start a new session
```

**Guidelines:**
- Use `-` for unordered lists (not `*` or `+`)
- Use `1.` for all ordered list items (Markdown auto-numbers)
- Add blank lines between complex list items
- Indent sub-items with 2 spaces

### Tables

Use tables for structured comparison or reference data:

```markdown
| Command | Description | Example |
|---------|-------------|---------|
| `/models` | List available models | `/models` |
| `/config show` | Display configuration | `/config show` |
| `/help` | Show help | `/help tools` |
```

**Guidelines:**
- Always include header row with separators
- Left-align text columns
- Keep tables readable in source (align columns)

### Admonitions

Use blockquotes with emphasis for important notes:

```markdown
> **Note:** This feature requires API key configuration.

> **Warning:** This command modifies files. Review changes before committing.

> **Tip:** Use `/debug on` to see detailed operation logs.
```

**When to use:**
- **Note:** General information, clarification
- **Warning:** Potential issues, destructive operations
- **Tip:** Helpful advice, pro tips, optimization

### Links

**Internal links** (within documentation):

```markdown
See [Installation](INSTALLATION.md) for setup instructions.

See the [Configuration](#configuration) section below.
```

**External links:**

```markdown
Learn more about [Markdown](https://www.markdownguide.org/).
```

**Guidelines:**
- Use descriptive link text (not "click here")
- Link to official sources when available
- Check links periodically for rot

---

## Content Structure

### Start with an Overview

Every document should begin with a brief overview explaining what it covers:

```markdown
# CLIO User Guide

**Complete guide to using CLIO (Command Line Intelligence Orchestrator)**

---

CLIO is a terminal-based AI coding assistant that integrates directly with your
filesystem, version control, and command-line workflow.
```

### Include a Table of Contents

For documents longer than 5 sections, include a linked table of contents:

```markdown
## Table of Contents

1. [Introduction](#introduction)
2. [Installation](#installation)
3. [Configuration](#configuration)
4. [Usage Examples](#usage-examples)
5. [Troubleshooting](#troubleshooting)
```

### Provide Examples

Every feature should include at least one example:

- **Don't:** "Use `/api provider` to set your provider."
- **Do:**

```markdown
Set your provider:

```bash
/api provider github_copilot
/api login
```

CLIO will authenticate via device flow and store your token.
```

### Show Both Command and Output

When demonstrating commands, show both input and expected output:

```markdown
Check your current configuration:

```bash
/config show
```

Output:
```
API Configuration:
  Provider: github_copilot
  Model: gpt-5
```
```

---

## Terminology

### Use Consistent Terms

| Use This | Not This |
|----------|----------|
| API key | api key, API-key, api_key |
| API provider | provider, api provider, API Provider |
| slash command | command, CLIO command |
| configuration | config, settings |
| file path | filepath, file-path, path |
| session | conversation, chat |
| terminal | console, command line, shell |

### Define Terms on First Use

When introducing technical terms, define them:

- **Don't:** "CLIO uses MCP tools to interact with your system."
- **Do:** "CLIO uses MCP tools (Model Context Protocol - standardized AI tool formats) to interact with your system."

### Avoid Ambiguous Pronouns

- **Don't:** "When you configure the provider, it will use the default model."
- **Do:** "When you configure the provider, CLIO will use the provider's default model."

---

## Command Documentation

### Command Format

Document commands with this structure:

```markdown
### `/command [args]`

**Description:** Brief explanation of what the command does.

**Arguments:**
- `arg1` - Description of argument (required)
- `arg2` - Description of argument (optional)

**Example:**
```bash
/command arg1 arg2
```

**Output:**
```
Example output here
```
```

### Use Placeholders Correctly

Indicate placeholders clearly:

```markdown
`/api provider <provider_name>`
`/session resume <session_id>`
`/model <model_name>`
```

**Guidelines:**
- Use `<placeholder>` for required arguments
- Use `[optional]` for optional arguments
- Use `...` for variable number of arguments

---

## Examples Best Practices

### Use Realistic Examples

- **Don't:**
```bash
/read foo.txt
```

- **Do:**
```bash
Read lib/CLIO/Core/Config.pm and explain how provider configuration works.
```

### Show Complete Workflows

Don't just show isolated commands - show complete workflows:

```markdown
## Setting Up GitHub Copilot

1. **Start CLIO:**
   ```bash
   ./clio --new
   ```

2. **Log in:**
   ```bash
   /api login
   ```

3. **Follow the device flow:**
   - Open the URL shown in your browser
   - Enter the code displayed
   - Authorize the application

4. **Verify the connection:**
   ```bash
   /models
   ```

5. **Test it:**
   ```
   What is 2+2?
   ```
```

### Include Expected Output

Always show what users should expect to see:

```markdown
Run CLIO in debug mode:

```bash
./clio --debug --new
```

You should see detailed logs:
```
[DEBUG][Config] Loading configuration from ~/.clio/config.json
[DEBUG][Config] Provider: github_copilot
[DEBUG][APIManager] Initializing with model gpt-5
```
```

---

## Error Messages & Troubleshooting

### Document Common Errors

Create a troubleshooting section with common errors:

```markdown
## Troubleshooting

### "401 Unauthorized" Error

**Problem:** CLIO cannot authenticate with the API.

**Cause:** Invalid or expired token.

**Solution:**
1. Log out: `/api logout`
2. Log back in: `/api login`
3. Follow the device flow to re-authenticate
```

### Use Clear Problem/Solution Format

```markdown
**Problem:** [What the user experiences]

**Cause:** [Why it's happening]

**Solution:** [Step-by-step fix]
```

---

## File Paths & Locations

### Use Tilde for Home Directory

- **Don't:** `/Users/username/.clio/config.json`
- **Do:** `~/.clio/config.json`

### Show Platform-Specific Paths When Necessary

```markdown
**Configuration location:**
- macOS/Linux: `~/.clio/config.json`
```

### Use Relative Paths in Examples

When showing project files:

- **Don't:** `/Users/you/projects/myapp/lib/module.pm`
- **Do:** `lib/module.pm`

---

## Version-Specific Documentation

CLIO uses date-based versioning (e.g., `20260331.5`).

### Clearly Mark Version Requirements

```markdown
> **Note:** This feature requires CLIO version 20260301 or later.
```

### Document Breaking Changes

```markdown
> **Warning:** As of version 20260322, the `/config provider` command has been
> replaced with `/api provider`. Update your workflows accordingly.
```

### Avoid Volatile External Information

Don't document information that changes frequently and where CLIO isn't the source of truth:

- **Model versions** - Models change constantly. Tell users to run `/api models` instead of listing specific model names and versions. When a concrete name is needed in an example, use a current model family name.
- **Pricing and subscriptions** - Never include dollar amounts, subscription tiers, or billing details. Link to the provider's website instead.
- **Provider feature comparisons** - Capabilities change. Keep comparisons to stable attributes (cloud vs. local, auth type).

---

## Maintenance

### Keep Documentation Current

- Update docs when features change
- Remove outdated information promptly
- Mark deprecated features clearly
- Link to migration guides for breaking changes

### Review for Clarity

Periodically review documentation for:
- Broken links
- Outdated examples
- Unclear explanations
- Missing information

---

## Checklist

Before publishing documentation, verify:

- [ ] Clear, descriptive title
- [ ] Overview/introduction paragraph
- [ ] Table of contents (if >5 sections)
- [ ] Consistent terminology
- [ ] Code blocks have language specified
- [ ] Commands shown with expected output
- [ ] Examples are realistic and complete
- [ ] Links are working
- [ ] No spelling or grammar errors
- [ ] Formatted for readability (headers, lists, spacing)
- [ ] Troubleshooting section (if applicable)

---

## Quick Reference

### Formatting Cheat Sheet

```markdown
# H1 Title
## H2 Section
### H3 Subsection

**Bold text**
*Italic text*
`Inline code`

```bash
Code block
```

- Unordered list item
1. Ordered list item

[Link text](URL)

| Table | Header |
|-------|--------|
| Cell  | Cell   |

> **Note:** Important information
```

---

**Remember:** Good documentation is clear, concise, and user-focused. When in doubt, ask: "Would this help someone new to CLIO?"
