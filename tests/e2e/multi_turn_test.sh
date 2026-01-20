#!/bin/bash

# Test multi-turn conversation with tool usage
SESSION_ID=$(./clio --new --input "hello" --exit 2>&1 | grep "Session:" | awk '{print $2}')

echo "Session ID: $SESSION_ID"
echo "Turn 1: hello"
./clio --resume $SESSION_ID --input "hello" --exit 2>&1 | head -5

echo ""
echo "Turn 2: list files"
./clio --resume $SESSION_ID --input "list files in lib/CLIO/Tools" --exit 2>&1
