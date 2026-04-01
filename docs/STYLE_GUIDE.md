# CLIO UI/UX Style Guide

**Definitive reference for all terminal UI formatting in CLIO**

---

## Core Principles

1. **Consistency First** - All output follows the same formatting patterns
2. **Three-Color Format** - DIM for connectors/chrome, ASSISTANT for headers/names, DATA for content
3. **Colorize Real Content** - Always pass actual text to `colorize()`, never empty strings
4. **Capability-Aware** - Detect terminal capabilities and degrade gracefully (Unicode -> CP437 -> ASCII)
5. **Minimal Noise** - Don't announce tool calls or internal operations unless they provide value
6. **Inline by Default** - Tool output uses compact inline format; box-drawing available via theme

---

## Display Formats

CLIO supports two tool display formats, configured per-theme via `tool_display_format`:

### Inline Format (Default)

Compact, single-line tool output using bullet and arrow symbols:

```
∙ FILE OPERATIONS → reading lib/CLIO/Core/Config.pm (1247 bytes)
```

Multiple calls to the same tool collapse under one header:

```
∙ FILE OPERATIONS → reading lib/CLIO/UI/Chat.pm (5832 bytes)
                  → writing lib/CLIO/UI/Chat.pm (5891 bytes)
```

Expanded content (diffs, key-value data) is indented below with hrule separators:

```
∙ FILE OPERATIONS → replaced 1 occurrence in lib/CLIO/Core/Config.pm
    ────────────────────────────────────
    (expanded content here)
    ────────────────────────────────────
```

### Box Format

Traditional box-drawing structure:

```
┌──┤ FILE OPERATIONS
└─ reading lib/CLIO/Core/Config.pm (1247 bytes)
```

Multi-line:

```
┌──┤ FILE OPERATIONS
├─ reading lib/CLIO/UI/Chat.pm (5832 bytes)
├─ writing lib/CLIO/UI/Chat.pm (5891 bytes)
└─ created backup at lib/CLIO/UI/Chat.pm.bak
```

### Setting the Format

All shipped themes default to `inline`. To use box format, set in your theme file:

```
tool_display_format=box
```

---

## UI Symbols

CLIO uses `CLIO::UI::Terminal::ui_char()` for capability-aware symbol rendering with three fallback tiers:

| Symbol Name | Unicode | CP437 | ASCII | Usage |
|-------------|---------|-------|-------|-------|
| `bullet` | ∙ | ∙ | * | Tool header prefix |
| `separator` | → | → | > | Tool header separator |
| `footer_sep` | ─ | ─ | _ | Horizontal rules |
| `ellipsis` | … | ... | ... | Truncation |
| `arrow_right` | → | » | -> | Directional |
| `arrow_left` | ← | « | <- | Directional |
| `check` | ✓ | √ | + | Success |
| `cross_mark` | ✗ | x | x | Failure |
| `dot` | · | · | . | List items |
| `dash` | — | - | - | Separators |
| `pipe` | │ | │ | \| | Vertical lines |

Box-drawing characters use `CLIO::UI::Terminal::box_char()`:

| Name | Unicode | ASCII |
|------|---------|-------|
| `topleft` | ┌ | + |
| `tright` | ├ | + |
| `bottomleft` | └ | + |
| `horizontal` | ─ | - |
| `tleft` | ┤ | + |
| `vertical` | │ | \| |

---

## Colorization

### Theme Style Names

| Style Name | Purpose | Usage |
|-----------|---------|-------|
| `DIM` | Chrome, connectors, metadata | Bullets, arrows, hrules, box connectors |
| `ASSISTANT` | Names, headers, "CLIO:" prefix | Tool names, thinking header, system names |
| `DATA` | Content, values | Action descriptions, thinking content, file data |
| `USER` | User input, "YOU:" prefix | User messages |
| `ERROR` | Error messages | Errors, diff removed lines |
| `SUCCESS` | Success indicators | Checkmarks, diff added lines |
| `WARNING` | Warnings | Warnings |
| `PROMPT_INDICATOR` | Interactive prompts | `>` prompt symbol |

### Three-Color Pattern

All structured output follows: DIM for chrome, ASSISTANT for names, DATA for content.

**Inline tool header:**
```perl
my $b = $ui->colorize($bullet, 'DIM');
my $n = $ui->colorize(" $tool_name ", 'ASSISTANT');
my $s = $ui->colorize("$separator ", 'DIM');
print "$b$n$s";
# Action detail follows in DATA color
```

**Box tool header:**
```perl
my $connector = $ui->colorize("┌──┤ ", 'DIM');
my $name = $ui->colorize("TOOL NAME", 'ASSISTANT');
print "$connector$name\n";
```

### Correct Colorization

```perl
# CORRECT - colorize actual content
print $ui->colorize($text, 'DATA') . "\n";

# WRONG - colorizing empty string returns empty string
my $color = $ui->colorize('', 'DATA');
print "$color$text\n";  # Uncolored!

# WRONG - hardcoded ANSI codes
my $dim = "\e[2m";  # Use colorize() instead
```

---

## Agent Response Display

Agent responses are displayed with a `CLIO: ` prefix and 4-space indentation on continuation lines:

```
CLIO: First line of response
    Second line indented by 4 spaces
    Third line also indented
```

The prefix uses ASSISTANT color. Response text is rendered through the Markdown renderer if enabled.

---

## Thinking/Reasoning Display

When models provide reasoning content (toggle with `/api set thinking on`):

**Inline format:**
```
∙ THINKING
    reasoning content indented by 4 spaces
    continues here...

```

**Box format:**
```
┌──┤ THINKING
    reasoning content indented by 4 spaces
    continues here...

```

- Header: DIM bullet/connector + ASSISTANT for "THINKING" (inline) or DIM connector + ASSISTANT name (box)
- Content: DATA color, 4-space indent
- Ends with blank line separator before the response

---

## System Messages

System messages (errors, warnings, collaboration prompts) use box-drawing format regardless of the tool display format setting:

```
┌──┤ HEADER
└─ message content
```

---

## Pause Prompts (Pagination)

### Two-Part Structure

**Part 1: Hint (first time only)**
```
┌──┤ ^/v Pages - Q Quits - Any key for more
```

**Part 2: Progress Indicator (every subsequent page)**
```
└─┤ 1/13 │ ^v Q ▸
```

---

## Error Messages

```
ERROR: descriptive error message here
```

Use `ERROR` style. Multi-line:

```
ERROR: Primary error message
  Context line 1
  Context line 2
```

---

## Host Application Protocol

CLIO supports structured output for GUI host applications (via `CLIO::UI::HostProtocol`). When a host is detected, output is emitted as JSON events:

```json
{"type": "status", "data": "thinking"}
{"type": "tool_call", "name": "file_operations", "action": "reading file"}
{"type": "content", "text": "response text"}
```

---

## Terminal Capability Detection

`CLIO::UI::Terminal` detects capabilities at startup:

- **Unicode support** - Checks locale for UTF-8, falls back to CP437 then ASCII
- **Color depth** - Detects truecolor, 256-color, 16-color, or no color
- **Terminal dimensions** - Width/height for word wrapping and layout
- **Braille characters** - Spinner uses braille patterns or falls back to ASCII

Respects `NO_COLOR` environment variable and `--no-color` flag.

```perl
use CLIO::UI::Terminal qw(box_char ui_char supports_unicode);

my $bullet = ui_char('bullet');       # ∙ or * based on capability
my $corner = box_char('topleft');     # ┌ or + based on capability
```

---

## Documentation Guidelines

When writing docs that reference CLIO's interface:

- **Do not hardcode specific model names or versions** - models change frequently. Use `/api models` to discover available models. When a concrete name is needed in examples, use a current model family name without version suffix.
- **Do not include pricing or subscription costs** - these change and CLIO is not the source of truth.
- **Use `<model-name>` or `<provider-name>` as placeholders** in command examples.

---

## Implementation Checklist

When implementing new UI components:

- [ ] Use `colorize()` with actual content, not empty strings
- [ ] Follow three-color format (DIM/ASSISTANT/DATA)
- [ ] Use `ui_char()` and `box_char()` for symbols (never hardcode Unicode)
- [ ] Support both inline and box formats if displaying tool output
- [ ] Use `ToolOutputFormatter` for tool output display
- [ ] Use `CLIO::UI::Terminal` for capability detection
- [ ] Test with `--no-color` flag
- [ ] UTF-8 output enabled (`binmode(STDOUT, ':encoding(UTF-8)')`)
- [ ] No tool name announcements (let the format speak for itself)

---

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| `$ui->colorize('', 'DATA')` | Colorize actual text, not empty strings |
| `"\e[2m"` hardcoded ANSI | Use `$ui->colorize($text, 'DIM')` |
| `"\x{2219}"` hardcoded Unicode | Use `ui_char('bullet')` |
| `"┌──┤"` hardcoded box chars | Use `box_char('topleft')` etc. |
| `print "Using file_operations tool...\n"` | Let ToolOutputFormatter handle display |
| Repeated tool headers for same tool | Use continuation format (inline) or `├─`/`└─` (box) |
| Hardcoded model versions in docs | Use `/api models` or `<model-name>` placeholder |

---

## Testing

### Visual Test

```bash
./clio --input "read lib/CLIO/Core/Config.pm and show the first 10 lines" --exit
```

### Anti-Pattern Detection

```bash
# Find colorize('', ...) calls
grep -rn "colorize(''" lib/

# Find hardcoded ANSI codes
grep -rn '\\e\[' lib/ | grep -v Terminal.pm

# Find hardcoded Unicode symbols (should use ui_char/box_char)
grep -rn '\\x{25' lib/ | grep -v Terminal.pm
```

---

## References

- **ToolOutputFormatter:** `lib/CLIO/UI/ToolOutputFormatter.pm` - Tool output display (inline + box)
- **Terminal:** `lib/CLIO/UI/Terminal.pm` - Capability detection, `ui_char()`, `box_char()`
- **Theme System:** `lib/CLIO/UI/Theme.pm` - Two-layer theming (styles + themes)
- **Host Protocol:** `lib/CLIO/UI/HostProtocol.pm` - Structured output for GUI hosts
- **Display:** `lib/CLIO/UI/Display.pm` - High-level display methods
- **Chat:** `lib/CLIO/UI/Chat.pm` - Terminal interface, streaming, thinking callbacks
- **Spinner:** `lib/CLIO/UI/ProgressSpinner.pm` - Animated spinner with braille fallback
