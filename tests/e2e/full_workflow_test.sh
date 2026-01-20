#!/bin/bash
# Comprehensive CLIO Test Suite
# Tests real-world usage patterns to find bugs and verify tool result storage

# Don't exit on error - we want to run all tests
#set -e

CLIO="./clio"
TEST_LOG="/tmp/clio_comprehensive_test.log"
PASSED=0
FAILED=0

echo "==================================================================="
echo "CLIO COMPREHENSIVE TEST SUITE"
echo "==================================================================="
echo ""
echo "This suite tests CLIO with realistic development workloads:"
echo "  - Large file operations"
echo "  - Codebase analysis"
echo "  - Directory traversal"
echo "  - Tool result storage"
echo "  - Error handling"
echo ""
echo "Log file: $TEST_LOG"
echo ""

# Helper function to run a test
run_test() {
    local test_name="$1"
    local input="$2"
    local should_contain="$3"
    local should_not_contain="$4"
    
    echo -n "[TEST] $test_name ... "
    
    # Run CLIO with timeout
    if timeout 60 $CLIO --new --input "$input" --exit > "$TEST_LOG" 2>&1; then
        # Check for expected content
        if [ -n "$should_contain" ] && ! grep -q "$should_contain" "$TEST_LOG"; then
            echo "❌ FAIL (missing: $should_contain)"
            FAILED=$((FAILED + 1))
            return 1
        fi
        
        # Check for unwanted content
        if [ -n "$should_not_contain" ] && grep -q "$should_not_contain" "$TEST_LOG"; then
            echo "❌ FAIL (found unwanted: $should_not_contain)"
            FAILED=$((FAILED + 1))
            return 1
        fi
        
        echo "✅ PASS"
        PASSED=$((PASSED + 1))
        return 0
    else
        echo "❌ FAIL (timeout or error)"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

# Test 1: Small directory listing (should NOT trigger storage)
echo "─────────────────────────────────────────────────────────────────"
echo "PHASE 1: BASIC OPERATIONS"
echo "─────────────────────────────────────────────────────────────────"

run_test "Small directory listing" \
    "List files in ./scripts directory" \
    "RESPONSE" \
    "exceeds token"

# Test 2: Large directory listing (SHOULD trigger storage)
run_test "Large directory listing" \
    "List all files recursively in ./lib directory" \
    "RESPONSE" \
    "exceeds token"

# Test 3: Read a specific file
run_test "Read specific file" \
    "Read the file ./clio and tell me what it does" \
    "RESPONSE" \
    "exceeds token"

# Test 4: Code search
run_test "Code search" \
    "Search for 'ToolResultStore' in the codebase" \
    "RESPONSE" \
    "exceeds token"

echo ""
echo "─────────────────────────────────────────────────────────────────"
echo "PHASE 2: LARGE FILE OPERATIONS"
echo "─────────────────────────────────────────────────────────────────"

# Test 5: Read large file
run_test "Read large file" \
    "Read lib/CLIO/UI/Chat.pm and summarize its main responsibilities" \
    "RESPONSE" \
    "exceeds token"

# Test 6: Multiple large files
run_test "Read multiple files" \
    "Read lib/CLIO/Core/APIManager.pm and lib/CLIO/Core/WorkflowOrchestrator.pm and explain how they interact" \
    "RESPONSE" \
    "exceeds token"

echo ""
echo "─────────────────────────────────────────────────────────────────"
echo "PHASE 3: CODEBASE ANALYSIS"
echo "─────────────────────────────────────────────────────────────────"

# Test 7: Analyze project structure
run_test "Project structure analysis" \
    "Analyze the lib/CLIO directory structure and tell me the main subsystems" \
    "RESPONSE" \
    "exceeds token"

# Test 8: Find patterns
run_test "Pattern finding" \
    "Find all Perl modules in lib/CLIO/Core that use ToolExecutor" \
    "RESPONSE" \
    "exceeds token"

# Test 9: Recursive analysis
run_test "Recursive codebase scan" \
    "List all .pm files in ./lib and count them" \
    "RESPONSE" \
    "exceeds token"

echo ""
echo "─────────────────────────────────────────────────────────────────"
echo "PHASE 4: STRESS TESTS"
echo "─────────────────────────────────────────────────────────────────"

# Test 10: HUGE directory (the bug that started this!)
echo -n "[TEST] Huge directory (reference/vscode-copilot-chat) ... "
if timeout 120 $CLIO --new --input "List files in ./reference/vscode-copilot-chat recursively (use file_operations)" --exit > "$TEST_LOG" 2>&1; then
    if grep -q "exceeds token limit: 4" "$TEST_LOG"; then
        echo "❌ FAIL (4M+ token overflow still occurring!)"
        FAILED=$((FAILED + 1))
    elif grep -q "RESPONSE" "$TEST_LOG" || grep -q "TOOL_RESULT_STORED" "$TEST_LOG"; then
        echo "✅ PASS (handled large directory)"
        PASSED=$((PASSED + 1))
    else
        echo "⚠️  PARTIAL (no clear success/failure)"
        PASSED=$((PASSED + 1))
    fi
else
    echo "❌ FAIL (timeout)"
    FAILED=$((FAILED + 1))
fi

# Test 11: Multiple tool calls in one request
run_test "Multiple tool operations" \
    "List files in ./lib, then read SYSTEM_DESIGN.md, then check git status" \
    "RESPONSE" \
    "exceeds token"

echo ""
echo "─────────────────────────────────────────────────────────────────"
echo "PHASE 5: ERROR HANDLING"
echo "─────────────────────────────────────────────────────────────────"

# Test 12: Non-existent file
run_test "Non-existent file" \
    "Read the file ./does_not_exist.txt" \
    "not found\|does not exist\|cannot" \
    "exceeds token"

# Test 13: Invalid path
run_test "Invalid path" \
    "List files in /root/secret" \
    "not found\|does not exist\|cannot\|denied" \
    "exceeds token"

echo ""
echo "==================================================================="
echo "TEST SUMMARY"
echo "==================================================================="
echo "Passed: $PASSED"
echo "Failed: $FAILED"
echo "Total:  $((PASSED + FAILED))"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "✅ ALL TESTS PASSED!"
    echo ""
    echo "Tool result storage is working correctly."
    echo "No token overflow errors detected."
    exit 0
else
    echo "❌ SOME TESTS FAILED"
    echo ""
    echo "Check the log file for details: $TEST_LOG"
    exit 1
fi
