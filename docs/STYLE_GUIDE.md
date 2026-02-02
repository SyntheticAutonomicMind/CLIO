# CLIO UI/UX Style Guide

**Version:** 1.0  
**Date:** 2026-02-02  
**Purpose:** Definitive reference for all terminal UI formatting in CLIO

---

## Core Principles

1. **Consistency First** - All output follows the same formatting patterns
2. **Three-Color Format** - Box-drawing uses DIM for connectors, ASSISTANT for headers, DATA for content
3. **Colorize Real Content** - Always pass actual text to `colorize()`, never empty strings
4. **Box-Drawing for Structure** - Use Unicode box-drawing characters for visual hierarchy
5. **Minimal Noise** - Don't announce tool calls or internal operations unless they provide value

---

## Box-Drawing Characters

Use these Unicode characters for structured output:

```
┌  U+250C  BOX DRAWINGS LIGHT DOWN AND RIGHT
├  U+251C  BOX DRAWINGS LIGHT VERTICAL AND RIGHT  
└  U+2514  BOX DRAWINGS LIGHT UP AND RIGHT
─  U+2500  BOX DRAWINGS LIGHT HORIZONTAL
┤  U+2524  BOX DRAWINGS LIGHT VERTICAL AND LEFT
│  U+2502  BOX DRAWINGS LIGHT VERTICAL
```

---

## Tool Output Format

### Three-Color Format (Standard)

All box-drawing output uses this three-color pattern:

**Header:**
```
{DIM}┌──┤ {ASSISTANT}TOOL NAME{RESET}
```

**Action (single):**
```
{DIM}└─ {DATA}action description{RESET}
```

**Action (multiple):**
```
{DIM}├─ {DATA}first action{RESET}
{DIM}└─ {DATA}last action{RESET}
```

### Implementation Pattern

```perl
# Header
my $conn = $ui->colorize("┌──┤ ", 'DIM');
my $name = $ui->colorize("TOOL NAME", 'ASSISTANT');
print "$conn$name\n";

# Action
my $conn = $ui->colorize("└─ ", 'DIM');
my $action = $ui->colorize("action description", 'DATA');
print "$conn$action\n";
```

### Single-Line Tool Output

When a tool executes once with one action:

```
┌──┤ TOOL NAME
└─ action description here
```

**Example:**
```
┌──┤ FILE OPERATIONS
└─ reading lib/CLIO/Core/Config.pm (1247 bytes)
```

**Colors:**
- `┌──┤ ` = DIM (dim gray)
- `FILE OPERATIONS` = ASSISTANT (bright cyan)
- `└─ ` = DIM (dim gray)
- `reading lib/...` = DATA (white)

### Interactive Tool Output

Interactive tools (like USER COLLABORATION) display an action line before user interaction:

```
┌──┤ USER COLLABORATION
└─ Requesting your input...
CLIO: Here's my question for you...
Context: Some helpful context
[Your answer]: <user types response>
CLIO: <agent continues with response>
```

The action line (`└─ Requesting your input...`) closes the box-drawing header and indicates what's happening before the collaboration prompt appears.

### Multi-Line Tool Output

When a tool executes multiple times or has multiple actions:

```
┌──┤ TOOL NAME
├─ first action description
├─ second action description
└─ last action description
```

**Example:**
```
┌──┤ FILE OPERATIONS
├─ reading lib/CLIO/UI/Chat.pm (5832 bytes)
├─ writing lib/CLIO/UI/Chat.pm (5891 bytes)
└─ created backup at lib/CLIO/UI/Chat.pm.bak
```

**Colors:**
- Connectors (`┌──┤ `, `├─ `, `└─ `) = DIM
- Tool name (`FILE OPERATIONS`) = ASSISTANT
- Action descriptions = DATA

### Tool Group Transitions

When switching from one tool to another, add a blank line:

```
┌──┤ FILE OPERATIONS
└─ reading config file

┌──┤ VERSION CONTROL
└─ viewing git status
```

---

## Colorization Rules

### Theme Style Names

These are the canonical style names used in CLIO:

| Style Name | Purpose | Typical Color | Usage |
|-----------|---------|---------------|--------|
| `DIM` | Box-drawing connectors, metadata | Dim/Gray | Connectors: `┌──┤ `, `├─ `, `└─ ` |
| `ASSISTANT` | Tool names, headers, "CLIO:" prefix | Bright Cyan | Tool/system names |
| `DATA` | Action descriptions, file content | White | All content data |
| `USER` | User input, "YOU:" prefix | Default | User messages |
| `ERROR` | Error messages | Red/Bright Red | Errors |
| `SUCCESS` | Success indicators | Green/Bright Green | Checkmarks, success |
| `WARNING` | Warnings | Yellow/Bright Yellow | Warnings |
| `PROMPT_INDICATOR` | Interactive prompts | Bright Green | `>` prompt symbol |

### Correct Colorization Pattern

**CORRECT (Three-color format):**
```perl
# Header: connector + name
my $conn = $ui->colorize("┌──┤ ", 'DIM');
my $name = $ui->colorize("TOOL NAME", 'ASSISTANT');
print "$conn$name\n";

# Action: connector + description
my $conn = $ui->colorize("└─ ", 'DIM');
my $action = $ui->colorize("doing something", 'DATA');
print "$conn$action\n";
```

**WRONG (Single-color format):**
```perl
# Everything the same color - no visual hierarchy
my $line = "┌──┤ TOOL NAME";
print $ui->colorize($line, 'DATA') . "\n";
```

**WRONG (Empty string colorization):**
```perl
# Colorizing empty strings returns empty strings
my $color = $ui->colorize('', 'DATA');  # Returns ''!
print "$color$text\n";  # Uncolored output
```

**WRONG (Manual ANSI codes):**
```perl
# Don't build colors manually - use colorize()
my $dim = $ui->colorize('', 'DIM');
my $data = $ui->colorize('', 'DATA');
my $reset = "\e[0m";
print "$dim$connector $data$action_detail$reset\n";
```

---

## Pause Prompts (Pagination)

### Two-Part Structure

Pagination prompts have a two-part structure:

**Part 1: Hint (first time only)**
```
┌──┤ ^/v Pages - Q Quits - Any key for more
```

**Part 2: Progress Indicator (every subsequent page)**
```
└─┤ 1/13 │ ^v Q ▸
```

### Implementation

```perl
# First page
my $hint = $theme->get_pagination_hint();
print $hint;

# Subsequent pages
my $prompt = $theme->get_pagination_prompt($current, $total);
print $prompt;
```

---

## System Messages

### Command Headers

```
┌──┤ COMMAND NAME
```

**Example:**
```perl
print $chat->colorize("┌──┤ API CONFIGURATION", 'PROMPT_INDICATOR') . "\n";
```

### Section Headers

```
┌──┤ Section Title
```

### Key-Value Display

```
├─ Key: value
└─ Last Key: value
```

**Example:**
```
┌──┤ CURRENT SETTINGS
├─ Provider: github_copilot
├─ Model: claude-sonnet-4.5
└─ API Base: https://api.githubcopilot.com
```

---

## Error Messages

### Format

```
ERROR: descriptive error message here
```

**Colorization:** Use 'ERROR' style

**Example:**
```perl
$chat->display_error_message("Model 'gpt-5' not found");
# Outputs: ERROR: Model 'gpt-5' not found
```

### Multi-Line Errors

For errors with context:

```
ERROR: Primary error message
  Context line 1
  Context line 2
```

---

## Success Messages

### Format

```
✓ Action completed successfully
```

**Colorization:** Use 'SUCCESS' style (for checkmark) or 'DATA' (for description)

**Example:**
```perl
print $chat->colorize("✓", 'SUCCESS') . " File saved\n";
```

---

## Common Mistakes to Avoid

### ✗ Colorizing Empty Strings

```perl
# WRONG
my $color = $ui->colorize('', 'DATA');
print "$color$text\n";

# RIGHT
print $ui->colorize($text, 'DATA') . "\n";
```

### ✗ Missing Action Lines

When displaying tool output, always show the action:

```perl
# WRONG
print "┌──┤ FILE OPERATIONS\n";
print "┌──┤ FILE OPERATIONS\n";  # Header repeats, no action shown

# RIGHT
print "┌──┤ FILE OPERATIONS\n";
print "└─ reading file.txt\n";
```

### ✗ Tool Name Pollution

Don't announce tool calls in the conversation flow:

```perl
# WRONG
print "Using file_operations tool...\n";
print "Calling version_control...\n";

# RIGHT
# Tools display their own headers via the standard format
# Don't announce them separately
```

### ✗ Inconsistent Box Characters

Always use the correct Unicode characters:

```perl
# WRONG
print "|-- ACTION\n";  # ASCII approximation
print "└── ACTION\n";  # Wrong character (U+2500 vs U+2500)

# RIGHT
print "├─ ACTION\n";   # U+251C U+2500
print "└─ ACTION\n";   # U+2514 U+2500
```

---

## Implementation Checklist

When implementing new UI components:

- [ ] Use `colorize()` with actual content, not empty strings
- [ ] Follow box-drawing format for structure
- [ ] Use canonical style names from Theme.pm
- [ ] Test with both `default` and `compact` themes
- [ ] Verify colors display correctly
- [ ] Check that multi-line output uses ├─ and └─ correctly
- [ ] No tool name announcements (let the format speak for itself)
- [ ] UTF-8 output enabled (`binmode(STDOUT, ':encoding(UTF-8)')`)

---

## Testing

### Visual Test

Run this to see all formatting:

```bash
./clio --input "read lib/CLIO/Core/Config.pm and show the first 10 lines" --exit
```

Expected output should show:
- Clean "CLIO: " prefix
- Tool header: `┌──┤ FILE OPERATIONS`
- Action line: `└─ reading lib/CLIO/Core/Config.pm (1247 bytes)`
- Properly colored output

### Anti-Pattern Detection

Search for these patterns to find violations:

```bash
# Find colorize('', ...) calls
grep -rn "colorize(''" lib/

# Find potential tool announcements
grep -rn "Using.*tool\|Calling.*tool" lib/

# Find hardcoded ANSI codes (should use colorize instead)
grep -rn '\\e\[' lib/ | grep -v "ANSI reset code"
```

---

## References

- **Implementation:** `lib/CLIO/Core/WorkflowOrchestrator.pm` - Tool output formatting
- **Theme System:** `lib/CLIO/UI/Theme.pm` - Color definitions
- **Display Methods:** `lib/CLIO/UI/Chat.pm` - High-level display methods
- **Example Usage:** See any tool in `lib/CLIO/Tools/*.pm`

---

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-02-02 | Initial style guide creation after fixing colorization bugs |

---

**Remember:** When in doubt, colorize the full content, not empty strings. This is the #1 cause of formatting bugs.
