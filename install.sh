#!/bin/bash
# CLIO Installer - Flexible installation script
#
# Usage:
#   ./install.sh [OPTIONS] [INSTALL_DIR]
#
# Options:
#   --no-symlink    Skip creating /usr/local/bin/clio symlink
#   --symlink PATH  Create symlink at custom path instead of /usr/local/bin/clio
#   --user          Install to user home directory (~/.local/clio)
#   --help          Show this help message
#
# Examples:
#   sudo ./install.sh                     # Install to /opt/clio
#   sudo ./install.sh /usr/clio           # Install to /usr/clio
#   ./install.sh --user                   # Install to ~/.local/clio (no sudo needed)
#   sudo ./install.sh --no-symlink        # Install without symlink
#   sudo ./install.sh --symlink /usr/bin/clio  # Custom symlink path

set -e  # Exit on error

# Default values
DEFAULT_INSTALL_DIR="/opt/clio"
DEFAULT_SYMLINK="/usr/local/bin/clio"
CREATE_SYMLINK=1
INSTALL_DIR=""
SYMLINK_PATH=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help)
            echo "CLIO Installer"
            echo ""
            echo "Usage: $0 [OPTIONS] [INSTALL_DIR]"
            echo ""
            echo "Options:"
            echo "  --no-symlink        Skip creating symlink"
            echo "  --symlink PATH      Create symlink at custom path"
            echo "  --user              Install to ~/.local/clio (no sudo needed)"
            echo "  --help              Show this help"
            echo ""
            echo "Examples:"
            echo "  sudo $0                     # Install to /opt/clio"
            echo "  sudo $0 /usr/clio           # Install to /usr/clio"
            echo "  $0 --user                   # Install to ~/.local/clio"
            echo "  sudo $0 --no-symlink        # Install without symlink"
            echo "  sudo $0 --symlink /usr/bin/clio  # Custom symlink"
            exit 0
            ;;
        --no-symlink)
            CREATE_SYMLINK=0
            shift
            ;;
        --symlink)
            SYMLINK_PATH="$2"
            shift 2
            ;;
        --user)
            INSTALL_DIR="$HOME/.local/clio"
            SYMLINK_PATH="$HOME/.local/bin/clio"
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            echo "Run '$0 --help' for usage information"
            exit 1
            ;;
        *)
            INSTALL_DIR="$1"
            shift
            ;;
    esac
done

# Set defaults if not specified
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
SYMLINK_PATH="${SYMLINK_PATH:-$DEFAULT_SYMLINK}"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CLIO Installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Installing CLIO to: $INSTALL_DIR"
if [ $CREATE_SYMLINK -eq 1 ]; then
    echo "Creating symlink:   $SYMLINK_PATH"
else
    echo "Symlink:            (skipped)"
fi
echo ""

# Check root privileges for system directories
# Skip check for user home installations
if [[ "$INSTALL_DIR" == "$HOME"* ]]; then
    echo "Installing to user directory (no root required)"
elif [[ "$INSTALL_DIR" == /opt/* ]] || [[ "$INSTALL_DIR" == /usr/* ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Installing to $INSTALL_DIR requires root privileges"
        echo "Run: sudo $0 $*"
        exit 1
    fi
fi

# Verify we're in the source directory
if [[ ! -f "clio" ]] || [[ ! -d "lib/CLIO" ]]; then
    echo "ERROR: Must run installer from CLIO source directory"
    echo "Current directory: $(pwd)"
    exit 1
fi

# Create installation directory
echo "Creating installation directory..."
mkdir -p "$INSTALL_DIR" || { echo "Failed to create $INSTALL_DIR"; exit 1; }

# Copy files
echo "Copying files..."
cp clio "$INSTALL_DIR/" || exit 1
cp VERSION "$INSTALL_DIR/" || exit 1
cp -r lib "$INSTALL_DIR/" || exit 1
cp -r styles "$INSTALL_DIR/" || exit 1
cp -r themes "$INSTALL_DIR/" || exit 1
cp README.md "$INSTALL_DIR/" 2>/dev/null || echo "  (README.md not found, skipping)"
[ -d docs ] && cp -r docs "$INSTALL_DIR/" || echo "  (docs/ not found, skipping)"

# Set permissions
echo "Setting permissions..."
chmod 755 "$INSTALL_DIR/clio"
find "$INSTALL_DIR/lib" -type f -name "*.pm" -exec chmod 644 {} \;
find "$INSTALL_DIR/lib" -type d -exec chmod 755 {} \;
find "$INSTALL_DIR/styles" -type f -name "*.style" -exec chmod 644 {} \;
find "$INSTALL_DIR/styles" -type d -exec chmod 755 {} \;
find "$INSTALL_DIR/themes" -type f -name "*.theme" -exec chmod 644 {} \;
find "$INSTALL_DIR/themes" -type d -exec chmod 755 {} \;
[ -f "$INSTALL_DIR/README.md" ] && chmod 644 "$INSTALL_DIR/README.md"

# Create symlink
if [ $CREATE_SYMLINK -eq 1 ]; then
    echo "Creating symlink..."
    
    # Create symlink directory if needed (for user installs)
    SYMLINK_DIR=$(dirname "$SYMLINK_PATH")
    if [[ ! -d "$SYMLINK_DIR" ]]; then
        mkdir -p "$SYMLINK_DIR" || echo "Warning: Could not create symlink directory $SYMLINK_DIR"
    fi
    
    ln -sf "$INSTALL_DIR/clio" "$SYMLINK_PATH" || echo "Warning: Could not create symlink"
    
    # For user installs, remind about PATH
    if [[ "$SYMLINK_PATH" == "$HOME"* ]]; then
        echo ""
        echo "NOTE: Symlink created at $SYMLINK_PATH"
        echo "      Make sure $SYMLINK_DIR is in your PATH"
        echo "      Add to ~/.bashrc or ~/.zshrc:"
        echo "      export PATH=\"\$PATH:$SYMLINK_DIR\""
    fi
else
    echo "Skipping symlink creation (--no-symlink specified)"
fi

# Verify installation
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if command -v clio &> /dev/null; then
    echo "✅ CLIO installed successfully!"
    echo ""
    echo "   Location: $INSTALL_DIR"
    if [ $CREATE_SYMLINK -eq 1 ]; then
        echo "   Symlink:  $SYMLINK_PATH"
    fi
    echo ""
    echo "Usage:"
    echo "   clio --new             # Start new conversation"
    echo "   clio --resume <id>     # Resume session"
    echo "   clio --help            # Show help"
elif [ $CREATE_SYMLINK -eq 1 ]; then
    echo "⚠️  Installation complete but 'clio' command not found in PATH"
    echo ""
    echo "   Installation: $INSTALL_DIR"
    echo "   Symlink:      $SYMLINK_PATH"
    echo ""
    if [[ "$SYMLINK_PATH" == "$HOME"* ]]; then
        echo "   Add to your PATH:"
        SYMLINK_DIR=$(dirname "$SYMLINK_PATH")
        echo "   export PATH=\"\$PATH:$SYMLINK_DIR\""
    else
        echo "   You may need to start a new shell."
    fi
else
    echo "✅ CLIO installed successfully!"
    echo ""
    echo "   Location: $INSTALL_DIR"
    echo ""
    echo "   To use CLIO, run: $INSTALL_DIR/clio"
    echo "   Or create your own symlink/alias"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
