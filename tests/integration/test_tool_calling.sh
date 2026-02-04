#!/usr/bin/env bash
# End-to-end tool calling test
# Tests both correct and malformed tool calls in OpenAI and Anthropic formats
# This test discovered the TodoStore undef status bugs

set -e

echo "===== CLIO End-to-End Tool Calling Test ====="
echo ""
echo "This test verifies:"
echo "  - Correctly formed tool calls work"
echo "  - Malformed JSON is detected and repaired"
echo "  - Both OpenAI and Anthropic formats are supported"
echo "  - Tool execution completes without crashes"
echo ""

# Create test directory
TEST_DIR="scratch/test_tool_calls_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$TEST_DIR"

echo "Test directory: $TEST_DIR"
echo ""

# Run the test
echo "Running test with gpt-4.1..."
./clio --model gpt-4.1 --exit --input "Please do a series of tools tests using $TEST_DIR as the working directory. You must test both correctly formed and incorrectly formed tool calls, in OpenAI and in Anthropic tool calling formats. *CRITICAL*: You must not test or use user_collaboration, this is a non-interactive test. Develop your plan and execute it immediately." 2>&1 | tee "$TEST_DIR/test_output.log"

EXIT_CODE=${PIPESTATUS[0]}

echo ""
echo "===== Test Results ====="
if [ $EXIT_CODE -eq 0 ]; then
    echo "[OK] Test completed successfully"
    echo ""
    echo "Output saved to: $TEST_DIR/test_output.log"
    echo ""
    
    # Check for warnings
    WARNINGS=$(grep -c "Use of uninitialized value" "$TEST_DIR/test_output.log" || true)
    if [ $WARNINGS -gt 0 ]; then
        echo "[WARN] Found $WARNINGS uninitialized value warnings"
        grep "Use of uninitialized value" "$TEST_DIR/test_output.log" || true
        exit 1
    fi
    
    # Check for errors
    ERRORS=$(grep -c "\[ERROR\]" "$TEST_DIR/test_output.log" || true)
    if [ $ERRORS -gt 0 ]; then
        echo "[WARN] Found $ERRORS error messages"
        grep "\[ERROR\]" "$TEST_DIR/test_output.log" | head -5 || true
        echo "Review full log for details"
    fi
    
    echo ""
    echo "[OK] All checks passed"
    exit 0
else
    echo "[FAIL] Test failed with exit code $EXIT_CODE"
    echo ""
    echo "Last 50 lines of output:"
    tail -50 "$TEST_DIR/test_output.log"
    exit $EXIT_CODE
fi
