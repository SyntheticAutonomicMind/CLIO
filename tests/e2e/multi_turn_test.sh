#!/bin/bash

# Requires a live API provider. The previous behaviour ran against whatever
# account the developer had configured and could hang for minutes.
if [ "${CLIO_LIVE_API_TESTS:-0}" != "1" ]; then
    echo "SKIP: requires a live API provider - set CLIO_LIVE_API_TESTS=1 to run"
    exit 0
fi

# Test multi-turn conversation with tool usage
SESSION_ID=$(./clio --new --input "hello" --exit 2>&1 | grep "Session:" | awk '{print $2}')

echo "Session ID: $SESSION_ID"
echo "Turn 1: hello"
./clio --resume $SESSION_ID --input "hello" --exit 2>&1 | head -5

echo ""
echo "Turn 2: list files"
./clio --resume $SESSION_ID --input "list files in lib/CLIO/Tools" --exit 2>&1
