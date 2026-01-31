# CLIO Style System Guide

## Table of Contents
1. [Overview](#overview)
2. [Quick Start](#quick-start)
3. [Style Schema v2.0](#style-schema-v20)
4. [Creating Custom Styles](#creating-custom-styles)
5. [Available Styles](#available-styles)
6. [Best Practices](#best-practices)
7. [Migration Guide](#migration-guide)

---

## Overview

CLIO's style system provides a flexible, semantic approach to terminal theming. Version 2.0 introduces a consolidated schema that prevents "screen vomit" while supporting complex, beautiful themes.

### Design Principles

1. **Semantic Hierarchy** - 5 clear levels from primary to subtle
2. **Consistency** - Same key always serves same purpose
3. **Flexibility** - Support both simple and complex themes
4. **Readability** - Visual clarity over decoration

---

## Quick Start

### Using a Style

```bash
# Try different styles
./clio --style nord
./clio --style dracula
./clio --style solarized-dark

# Set as default
/config style monokai
```

### Listing Available Styles

```bash
./clio --list-styles
```

Current available styles: **24 themes**

---

## Style Schema v2.0

### Core Semantic Hierarchy (Required)

Every style MUST define these 5 levels:

```
primary=@BOLD@@BRIGHT_CYAN@      # Highest emphasis (titles, critical)
secondary=@BRIGHT_CYAN@          # High emphasis (headers, important)
normal=@WHITE@                    # Standard text (body content)
muted=@DIM@@WHITE@               # Low emphasis (labels, hints)
subtle=@DIM@                     # Lowest emphasis (borders, separators)
```

**Visual Weight:**
```
primary     ████████████  (boldest, brightest)
secondary   ██████████
normal      ██████
muted       ███
subtle      █             (dimmest)
```

### Specialized Categories

#### Conversational
```
user_prompt=@BRIGHT_GREEN@       # "YOU:" label
user_text=@WHITE@                # User's input
agent_label=@BRIGHT_CYAN@        # "CLIO:" label
agent_text=@WHITE@               # Agent's response
system_message=@CYAN@            # System notifications
```

#### Feedback Messages
```
error=@BRIGHT_RED@               # Errors, failures
warning=@BRIGHT_YELLOW@          # Warnings, cautions
success=@BRIGHT_GREEN@           # Success, completions
info=@CYAN@                      # Informational messages
```

#### Data Display (Label/Value Pairs)
```
label=@DIM@@WHITE@               # Labels: "Session ID:", "Model:"
value=@BRIGHT_WHITE@             # Values: actual data
```

**Usage Example:**
```
{style.label}Session ID: {style.value}abc123-def456
```

Renders as: <dim>Session ID:</dim> <bright>abc123-def456</bright>

#### Actionable Elements
```
command=@BRIGHT_GREEN@           # Commands: /help, /exit
link=@BRIGHT_CYAN@@UNDERLINE@    # URLs, links
```

#### Prompt Components
```
prompt_model=@CYAN@              # Model name in prompt
prompt_directory=@BRIGHT_CYAN@   # Current directory
prompt_git_branch=@DIM@@CYAN@    # Git branch
prompt_indicator=@BRIGHT_GREEN@  # Prompt symbol (>)
```

#### Markdown Rendering
```
markdown_h1=@BOLD@@BRIGHT_CYAN@  # # Header 1
markdown_h2=@BRIGHT_CYAN@        # ## Header 2
markdown_h3=@WHITE@              # ### Header 3
markdown_bold=@BOLD@             # **bold**
markdown_italic=@DIM@            # *italic*
markdown_code=@CYAN@             # `code`
markdown_code_block=@CYAN@       # ```code blocks```
markdown_link=@BRIGHT_CYAN@@UNDERLINE@  # [links](url)
markdown_quote=@DIM@@CYAN@       # > quotes
markdown_list_bullet=@BRIGHT_GREEN@     # - bullets
```

#### Tables
```
table_header=@BOLD@@BRIGHT_CYAN@ # Column headers
table_border=@DIM@               # Border lines
```

#### UI Elements
```
spinner_frames=⠋,⠙,⠹,⠸,⠼,⠴,⠦,⠧,⠇,⠏  # Braille spinner
```

#### Metadata
```
name=my-theme                    # MUST match filename
```

### Complete Key List

**Total: 31 semantic keys** (+ 25 deprecated for backward compatibility)

---

## Creating Custom Styles

### Step 1: Copy Template

```bash
cp styles/default.style styles/my-theme.style
```

### Step 2: Update Metadata

```
name=my-theme
```

### Step 3: Define Core Hierarchy

Choose your color palette:

**Monochrome Theme Example:**
```
primary=@BOLD@@BRIGHT_WHITE@
secondary=@WHITE@
normal=@WHITE@
muted=@DIM@@WHITE@
subtle=@DIM@
```

**Colorful Theme Example:**
```
primary=@BOLD@@BRIGHT_MAGENTA@
secondary=@BRIGHT_CYAN@
normal=@WHITE@
muted=@DIM@@WHITE@
subtle=@DIM@
```

### Step 4: Set Specialized Colors

**Data Display** (most important for readability):
```
label=@DIM@@WHITE@      # Make labels subdued
value=@BRIGHT_CYAN@     # Make values stand out
```

**Actionable Elements:**
```
command=@BRIGHT_GREEN@  # Commands should pop
link=@BRIGHT_CYAN@@UNDERLINE@
```

**Feedback:**
```
error=@BRIGHT_RED@      # Keep these standard
warning=@BRIGHT_YELLOW@
success=@BRIGHT_GREEN@
info=@CYAN@
```

### Step 5: Test Your Theme

```bash
./clio --style my-theme --input "test markdown **bold** and `code`" --exit
```

### Step 6: Add Deprecated Keys

For backward compatibility, add these mappings:

```
# Deprecated keys point to new semantic keys
app_title=@BOLD@@BRIGHT_CYAN@    # -> primary
app_subtitle=@BRIGHT_CYAN@       # -> secondary
banner_label=@DIM@@WHITE@        # -> label
banner_value=@BRIGHT_WHITE@      # -> value
data=@BRIGHT_WHITE@              # -> value
# ... (see default.style for complete list)
```

---

## Available Styles

### Modern/Professional (9)

| Style | Description | Primary Color | Best For |
|-------|-------------|---------------|----------|
| **default** | Modern blues & grays | Bright Cyan | General use, professional |
| **greyscale** | Sophisticated monochrome | Bright White | Minimalist, focus |
| **light** | Light mode | Blue | Bright environments |
| **dark** | Dark mode | Cyan | Low light, night use |
| **slate** | Corporate clean | Bright Blue | Business, presentations |
| **solarized-dark** | Scientific balance | Bright Blue | Long coding sessions |
| **solarized-light** | Light Solarized | Blue | Bright rooms |
| **nord** | Arctic blues | Bright Cyan | Cool, professional |
| **dracula** | Purple/pink vibrant | Bright Magenta | Modern, energetic |

### Retro/Vintage (9)

| Style | Description | Primary Color | Inspiration |
|-------|-------------|---------------|-------------|
| **amber-terminal** | Warm amber CRT | Bright Yellow | Old CRT monitors |
| **apple-ii** | Classic green | Bright Green | Apple II computers |
| **bbs-bright** | Cyan BBS | Bright Cyan | Bulletin board systems |
| **commodore-64** | C64 blue | Bright Blue | Commodore 64 |
| **dos-blue** | MS-DOS classic | Bright White/Blue | MS-DOS era |
| **green-screen** | Monochrome terminal | Bright Green | Terminal phosphor |
| **photon** | Teal/pink combo | Bright Cyan/Magenta | 80s computing |
| **retro-rainbow** | Multi-color fun | Various | Early terminals |
| **vt100** | Classic terminal | Bright Green | VT100 terminals |

### Flair/Nature (6)

| Style | Description | Primary Color | Vibe |
|-------|-------------|---------------|------|
| **monokai** | Warm vibrant | Bright Magenta | Iconic editor theme |
| **synthwave** | 80s neon outrun | Bright Magenta | Retro-future |
| **cyberpunk** | Neon dystopia | Bright Green | Matrix/Blade Runner |
| **matrix** | Green code rain | Bright Green | The Matrix |
| **ocean** | Deep sea blues | Bright Cyan | Calming, aquatic |
| **forest** | Natural greens | Bright Green | Woodland, organic |

---

## Best Practices

### DO: Visual Hierarchy

✅ **Good - Clear Distinction:**
```
label=@DIM@@WHITE@       # Subdued
value=@BRIGHT_CYAN@      # Stands out
```

❌ **Bad - Same Color:**
```
label=@WHITE@
value=@WHITE@            # Can't tell them apart!
```

### DO: Consistent Accents

✅ **Good - Consistent Green for Actions:**
```
command=@BRIGHT_GREEN@
success=@BRIGHT_GREEN@
user_prompt=@BRIGHT_GREEN@
```

❌ **Bad - Random Colors:**
```
command=@BRIGHT_GREEN@
success=@BRIGHT_YELLOW@  # Why different?
user_prompt=@BRIGHT_MAGENTA@  # Chaotic!
```

### DO: Respect Semantic Purpose

✅ **Good - Use Keys as Intended:**
```
primary=@BOLD@@BRIGHT_CYAN@   # For titles
secondary=@BRIGHT_CYAN@       # For headers
muted=@DIM@@WHITE@           # For labels
```

❌ **Bad - Backwards Hierarchy:**
```
primary=@DIM@                # Too subtle for primary!
muted=@BOLD@@BRIGHT_CYAN@    # Too bold for muted!
```

### DON'T: Screen Vomit

❌ **Bad - Too Many Colors:**
```
primary=@BRIGHT_RED@
secondary=@BRIGHT_YELLOW@
normal=@BRIGHT_GREEN@
muted=@BRIGHT_CYAN@
# Every line a different rainbow color!
```

✅ **Good - Cohesive Palette:**
```
primary=@BOLD@@BRIGHT_CYAN@
secondary=@BRIGHT_CYAN@
normal=@CYAN@
muted=@DIM@@CYAN@
# Variations of same color family
```

### Color Palette Strategies

**Monochrome** (safe, professional):
```
All keys use variations of ONE color (brightness, dim, bold)
Example: greyscale, amber-terminal, matrix
```

**Duo-tone** (balanced, modern):
```
Primary color + accent color
Example: nord (cyan + blue), synthwave (magenta + cyan)
```

**Tri-tone** (complex, vibrant):
```
Base + two accent colors
Example: monokai (magenta + green + yellow)
```

**Rainbow** (playful, risky):
```
Different color for each element type
Example: retro-rainbow
⚠️  Easy to become "screen vomit" - use sparingly!
```

---

## Migration Guide

### From v1.0 to v2.0

**Old (v1.0) had 43 confusing keys:**
```
banner_label, banner_value, command_label, command_value, 
data, app_title, app_subtitle, ...
```

**New (v2.0) has 31 semantic keys:**
```
primary, secondary, normal, muted, subtle,
label, value, command, ...
```

### Mapping Old → New

| Old Key | New Key | Purpose |
|---------|---------|---------|
| `app_title` | `primary` | Main titles |
| `app_subtitle` | `secondary` | Subtitles |
| `banner_label` | `label` | All labels |
| `banner_value` | `value` | All values |
| `command_label` | `label` | Labels everywhere |
| `command_value` | `value` | Values everywhere |
| `data` | `value` | Generic data |
| `banner_help` | `muted` | Help text |
| `error_message` | `error` | Errors |
| `success_message` | `success` | Success |
| `warning_message` | `warning` | Warnings |
| `info_message` | `info` | Info |

### Updating Existing Themes

1. **Keep old keys** for backward compatibility
2. **Add new semantic keys** following hierarchy
3. **Map old to new** in deprecated section

**Example:**
```
# NEW KEYS (v2.0)
label=@DIM@@WHITE@
value=@BRIGHT_CYAN@

# DEPRECATED (v1.0 compatibility)
banner_label=@DIM@@WHITE@      # Maps to 'label'
banner_value=@BRIGHT_CYAN@     # Maps to 'value'
command_label=@DIM@@WHITE@     # Maps to 'label'
command_value=@BRIGHT_CYAN@    # Maps to 'value'
data=@BRIGHT_CYAN@             # Maps to 'value'
```

---

## Color Reference

### ANSI Color Codes

```
@BLACK@          @BRIGHT_BLACK@
@RED@            @BRIGHT_RED@
@GREEN@          @BRIGHT_GREEN@
@YELLOW@         @BRIGHT_YELLOW@
@BLUE@           @BRIGHT_BLUE@
@MAGENTA@        @BRIGHT_MAGENTA@
@CYAN@           @BRIGHT_CYAN@
@WHITE@          @BRIGHT_WHITE@
```

### Modifiers

```
@BOLD@           Bold text
@DIM@            Dimmed text
@UNDERLINE@      Underlined text
@RESET@          Reset all formatting
```

### Combining Codes

```
@BOLD@@BRIGHT_CYAN@      Bold bright cyan
@DIM@@WHITE@             Dim white
@BRIGHT_GREEN@@UNDERLINE@  Underlined bright green
```

---

## Examples

### Minimal Monochrome Theme

```
name=minimal
primary=@BOLD@@WHITE@
secondary=@WHITE@
normal=@WHITE@
muted=@DIM@@WHITE@
subtle=@DIM@
user_prompt=@WHITE@
user_text=@WHITE@
agent_label=@BOLD@@WHITE@
agent_text=@WHITE@
system_message=@DIM@@WHITE@
error=@BRIGHT_RED@
warning=@BRIGHT_YELLOW@
success=@WHITE@
info=@WHITE@
label=@DIM@@WHITE@
value=@WHITE@
command=@WHITE@
link=@WHITE@@UNDERLINE@
# ... (continue with all required keys)
```

### Vibrant Dual-Tone Theme

```
name=electric
primary=@BOLD@@BRIGHT_MAGENTA@
secondary=@BRIGHT_CYAN@
normal=@WHITE@
muted=@MAGENTA@
subtle=@DIM@
user_prompt=@BRIGHT_MAGENTA@
user_text=@WHITE@
agent_label=@BRIGHT_CYAN@
agent_text=@WHITE@
system_message=@CYAN@
error=@BRIGHT_RED@
warning=@BRIGHT_YELLOW@
success=@BRIGHT_GREEN@
info=@BRIGHT_CYAN@
label=@MAGENTA@
value=@BRIGHT_MAGENTA@
command=@BRIGHT_CYAN@
link=@BRIGHT_CYAN@@UNDERLINE@
# ... (continue with all required keys)
```

---

## Troubleshooting

### Colors Not Showing

**Problem:** Style doesn't apply colors

**Solutions:**
1. Check `name` matches filename
2. Verify terminal supports 256 colors
3. Test with simple theme first

### Too Many Colors (Screen Vomit)

**Problem:** Interface looks chaotic

**Solutions:**
1. Reduce palette to 2-3 colors
2. Use variations (bright/dim) of same color
3. Follow 5-level hierarchy strictly

### Labels and Values Look Same

**Problem:** Can't tell labels from values

**Solutions:**
1. Make labels `@DIM@` or muted color
2. Make values `@BRIGHT@` or accent color
3. Test with real data: `./clio --style mytheme`

---

## Contributing Styles

Want to share your theme?

1. Create theme following schema v2.0
2. Test thoroughly
3. Add to `styles/` directory
4. Submit pull request with:
   - Theme file
   - Description of aesthetic
   - Screenshot (optional)

---

## Resources

- Schema Reference: `scratch/style_schema_v2.txt`
- Example Themes: `styles/` directory
- ANSI Colors: https://en.wikipedia.org/wiki/ANSI_escape_code

---

*Style System v2.0 - Semantic, Flexible, Beautiful*


---

## Related Documentation

- [Command Output Guide](COMMAND_OUTPUT_GUIDE.md) - Standards for `/command` help text formatting
- [Style Quick Reference](STYLE_QUICKREF.md) - Condensed style creation guide
