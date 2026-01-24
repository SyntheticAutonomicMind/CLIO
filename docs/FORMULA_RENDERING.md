# Formula Rendering in CLIO

**Added:** January 2026  
**Status:** @GREEN@Active@RESET@

## Overview

CLIO now renders LaTeX mathematical formulas with Unicode symbol conversion, making mathematical content readable in the terminal. Both inline and display-level formulas are supported.

## Features

### Inline Formulas

Use `$...$` for inline mathematical notation:

```
Einstein's famous equation is $E = mc^2$ relating energy and mass.

The quadratic formula: $x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}$
```

Inline formulas are rendered with:
- Symbol conversion (LaTeX -> Unicode)
- Color highlighting (@BRIGHT_MAGENTA@ by default)
- Dollar signs preserved for clarity

### Display-Level Formulas

Use `$$...$$` on its own line for prominent mathematical blocks:

```
$$\int_0^{\infty} e^{-x^2} dx = \frac{\sqrt{\pi}}{2}$$
```

Display formulas render with:
- Decorative border frame
- Symbol conversion
- Color highlighting
- Clear visual separation from surrounding text

## Supported Symbol Conversions

### Greek Letters

| LaTeX | Output | LaTeX | Output |
|-------|--------|-------|--------|
| `\alpha` | α | `\Alpha` | Α |
| `\beta` | β | `\Beta` | Β |
| `\pi` | π | `\Pi` | Π |
| `\sum` | ∑ | All 24 Greek letters supported | ... |

### Mathematical Operators

| LaTeX | Output | LaTeX | Output |
|-------|--------|-------|--------|
| `\sqrt` | √ | `\pm` | ± |
| `\int` | ∫ | `\infty` | ∞ |
| `\sum` | ∑ | `\prod` | ∏ |
| `\times` | × | `\div` | ÷ |

### Comparison Operators

| LaTeX | Output | LaTeX | Output |
|-------|--------|-------|--------|
| `\leq` | ≤ | `\geq` | ≥ |
| `\neq` | ≠ | `\approx` | ≈ |
| `\equiv` | ≡ | `\propto` | ∝ |

### Set Operators

| LaTeX | Output | LaTeX | Output |
|-------|--------|-------|--------|
| `\cup` | ∪ | `\cap` | ∩ |
| `\subset` | ⊂ | `\subseteq` | ⊆ |
| `\in` | ∈ | `\notin` | ∉ |

### Superscripts

| LaTeX | Output |
|-------|--------|
| `x^2` | x² |
| `x^3` | x³ |
| `x^n` | xⁿ |
| `x^-1` | x⁻¹ |

### Common Special Cases

| Input | Output |
|-------|--------|
| `E = mc^2` | E = mc² |
| `\ldots` or `\dots` | … |
| `\cdot` | · |

## Usage Examples

### Simple Physics

```
Newton's second law: $F = ma$

The gravitational force: $F = G\frac{m_1 m_2}{r^2}$
```

### Statistics

```
The standard normal distribution: $\phi(x) = \frac{1}{\sqrt{2\pi}} e^{-\frac{x^2}{2}}$
```

### Calculus

```
Integration by parts:
$$\int u \, dv = uv - \int v \, du$$
```

### Linear Algebra

```
Matrix multiplication: $(AB)_{ij} = \sum_{k} A_{ik} B_{kj}$
```

## Technical Details

### How It Works

1. **Detection**: The markdown renderer detects `$...$` and `$$...$$` patterns
2. **Processing**: LaTeX symbols are converted to Unicode equivalents
3. **Rendering**: 
   - Inline formulas get color codes (@BRIGHT_MAGENTA@ by default)
   - Display formulas get a decorative frame
4. **Preservation**: Original formula content is preserved for copying/reference

### Theme Customization

The formula color is customizable via the theme system:

```perl
my $theme_mgr = CLIO::UI::Theme->new();
# Formula color defaults to @BRIGHT_MAGENTA@
```

### Limitations

- Terminal rendering is limited to Unicode symbols (no graphical rendering)
- Complex expressions with fractions, subscripts remain as text
- The goal is readability, not perfect mathematical typesetting

## Implementation

### Files Modified

- `lib/CLIO/UI/Markdown.pm` - Added formula detection and rendering
- `lib/CLIO/UI/Theme.pm` - Added `markdown_formula` color theme
- `tests/unit/test_formula_rendering.pl` - Comprehensive test suite

### Key Functions

- `render_formula_block()` - Display-level formula rendering
- `render_formula_content()` - LaTeX to Unicode symbol conversion
- `process_inline_formatting()` - Inline formula processing

## Testing

Run the formula tests:

```bash
perl -I./lib tests/unit/test_formula_rendering.pl
```

19 tests covering:
- Inline formula detection
- Display formula framing
- Greek letter conversion
- Mathematical operators
- Comparison operators
- Superscript conversion
- Strip markdown preservation

## Future Enhancements

Possible improvements for future versions:
- Additional LaTeX symbols (more operators, set notation)
- Better subscript/superscript rendering
- Support for matrices and arrays (possibly using ASCII art)
- Cache rendered formulas for performance
- MathML or other formula format support

## Related Documentation

- @BOLD@Markdown Rendering@RESET@ - `docs/MARKDOWN_SUPPORT.md`
- @BOLD@Theme System@RESET@ - `lib/CLIO/UI/Theme.pm` POD
- @BOLD@Markdown Parser@RESET@ - `lib/CLIO/UI/Markdown.pm` POD
