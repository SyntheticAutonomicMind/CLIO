#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

# user_collaboration.sh - Reliable collaboration checkpoint for AI agents
# Usage: scripts/user_collaboration.sh "Your message here"
#
# This script provides a fallback for read -p when it fails in tool execution contexts.
# It displays a message to the user and waits for Enter key press to continue.

# Colors for better visibility
BLUE='\033[0;34m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Get message from argument or stdin
MESSAGE="${1:-Press Enter to continue}"

# Display message with visual separator
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}🤝 COLLABORATION CHECKPOINT${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "$MESSAGE"
echo ""
echo -en "${GREEN}Enter your response: ${NC}"

# Read user input
read -r response

# Log collaboration point (optional, for debugging)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Collaboration checkpoint: User continued" >> /tmp/sam_collaboration.log 2>/dev/null

# Echo response for agent to capture
if [ -n "$response" ]; then
    echo ""
    echo "User response: $response"
fi

echo ""
echo "Continuing..."
exit 0
