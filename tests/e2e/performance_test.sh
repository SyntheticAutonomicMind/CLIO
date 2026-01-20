#!/usr/bin/env bash

# Test interactive markdown rendering performance

echo "Testing CLIO markdown rendering performance..."
echo ""

# Create a test input that will generate lots of markdown
TEST_INPUT="explain markdown syntax with 5 code examples and 3 tables"

# Test with timing
echo "Running: $TEST_INPUT"
echo ""

time (echo "$TEST_INPUT" | ./clio --resume --exit 2>&1 > /tmp/clio_test_output.txt)

echo ""
echo "Output saved to /tmp/clio_test_output.txt"
echo "Lines in output: $(wc -l < /tmp/clio_test_output.txt)"
echo ""
echo "First 50 lines of output:"
head -50 /tmp/clio_test_output.txt
