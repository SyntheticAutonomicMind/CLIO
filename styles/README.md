# CLIO Styles

Styles define the color palette and visual appearance of CLIO's terminal output. Each style file uses the `@-code` format for ANSI colors and modifiers.

## Using Styles

```bash
./clio --style nord               # Use a style for this session
/config style monokai             # Set default style
./clio --list-styles              # Show all available styles
```

## Available Styles

| Style | Description |
|-------|-------------|
| `amber-terminal` | Warm amber on dark background |
| `apple-ii` | Classic Apple II green-on-black |
| `bbs-bright` | Bright BBS terminal colors |
| `commodore-64` | Commodore 64 blue-on-blue |
| `console` | Clean console defaults |
| `cyberpunk` | Neon cyberpunk aesthetic |
| `dark` | Dark theme with muted colors |
| `default` | Modern blues and grays |
| `dos-blue` | Classic DOS blue background |
| `dracula` | Dracula color palette |
| `forest` | Deep greens and earth tones |
| `green-screen` | Classic green phosphor CRT |
| `greyscale` | Monochrome grayscale |
| `light` | Light background theme |
| `matrix` | Black with green highlights |
| `monokai` | Monokai editor palette |
| `nord` | Nord color palette |
| `ocean` | Ocean blues and teals |
| `photon` | PhotonBBS-inspired theme |
| `retro-rainbow` | Colorful retro terminal |
| `slate` | Slate gray professional |
| `solarized-dark` | Solarized dark palette |
| `solarized-light` | Solarized light palette |
| `synthwave` | Synthwave neon aesthetic |
| `vt100` | Classic VT100 terminal |

## Style File Format

Each `.style` file contains key-value pairs using `@-code` color tokens:

```
# Required metadata
name=my-style

# Core hierarchy (5 levels)
primary=@BOLD@@BRIGHT_CYAN@
secondary=@BRIGHT_CYAN@
normal=@WHITE@
muted=@DIM@@WHITE@
subtle=@DIM@

# Conversational colors
user_prompt=@BRIGHT_GREEN@
user_text=@WHITE@
agent_label=@BRIGHT_CYAN@
agent_text=@WHITE@
system_message=@CYAN@

# ... more keys

## Spinner Style

Styles can select a built-in spinner animation via the `spinner_style` key:

```
spinner_style=dots        # default - ASCII dot cascade, works everywhere
spinner_style=rotator     # ASCII classic rotation (| / - \), works everywhere
spinner_style=braille     # 8-frame Unicode braille, falls back to dots on non-UTF-8 locales
```

For fully custom frame sequences, use the legacy `spinner_frames` key
(comma-separated):

```
spinner_frames=*,**,***,**,*, 
```

`spinner_style` and `spinner_frames` are mutually exclusive - if both are
present, `spinner_frames` wins.
```

See [docs/STYLE_QUICKREF.md](../docs/STYLE_QUICKREF.md) for the complete list of style keys and available color codes.