#!/usr/bin/env bash
# CLIO Installer

set -e

echo "╔══════════════════════════════════════╗"
echo "║  CLIO Installation                   ║"
echo "╚══════════════════════════════════════╝"
echo

# Check Perl
echo "→ Checking Perl..."
if ! command -v perl &> /dev/null; then
    echo "✗ Perl not found. Please install Perl 5.16 or later."
    exit 1
fi
PERL_VERSION=$(perl -e 'print $^V')
echo "✓ Perl $PERL_VERSION found"

# Create config directory
echo "→ Creating config directory..."
CONFIG_DIR="$HOME/.clio"
mkdir -p "$CONFIG_DIR"
echo "✓ Config directory: $CONFIG_DIR"

# Set permissions
echo "→ Setting permissions..."
chmod +x clio
echo "✓ Permissions set"

# Create default config if it doesn't exist
if [ ! -f "$CONFIG_DIR/config.json" ]; then
    echo "→ Creating default configuration..."
    cat > "$CONFIG_DIR/config.json" << 'JSON'
{
    "provider": "github_copilot",
    "model": "gpt-4",
    "style": "default",
    "theme": "default",
    "loglevel": "WARNING"
}
JSON
    echo "✓ Default config created"
else
    echo "ℹ Config already exists, keeping current settings"
fi

# Test execution
echo "→ Testing CLIO..."
if ./clio --help > /dev/null 2>&1; then
    echo "✓ CLIO is working"
else
    echo "✗ CLIO test failed"
    echo "  Try running: perl -Ilib clio --help"
    exit 1
fi

echo
echo "╔══════════════════════════════════════╗"
echo "║  Installation Complete! ✓            ║"
echo "╚══════════════════════════════════════╝"
echo
echo "Next steps:"
echo "  1. Run: ./clio"
echo "  2. Set API key: /api key YOUR_KEY"
echo "  3. Save config: /config save"
echo
echo "For help, run: ./clio --help"
echo "Read INSTALL.md for detailed instructions"
