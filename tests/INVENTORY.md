# Test Inventory - January 19, 2026

## Summary
- **Total Files Analyzed:** 38
- **Kept + Moved:** 19
- **Kept + Refactored:** 11
- **Discarded:** 8

## Organization Plan
```
tests/
├── unit/           # Individual module/function tests
│   ├── ansi_parser_test.pl
│   ├── markdown_renderer_test.pl
│   ├── text_sanitizer_test.pl
│   ├── json_encoding_test.pl
│   └── token_estimator_test.pl
├── integration/    # Multi-module workflow tests
│   ├── file_operations_test.pl
│   ├── version_control_test.pl
│   ├── terminal_operations_test.pl
│   ├── memory_operations_test.pl
│   ├── web_operations_test.pl
│   ├── todo_list_test.pl
│   ├── code_intelligence_test.pl
│   ├── result_storage_test.pl
│   ├── tool_executor_test.pl
│   ├── workflow_orchestrator_test.pl
│   └── encoding_matrix_test.pl      # NEW: Character encoding comprehensive
└── e2e/            # Full CLIO execution tests
    ├── cli_switches_test.sh
    ├── session_continuity_test.pl
    ├── multi_turn_test.sh
    ├── full_workflow_test.pl
    └── performance_test.sh
```

---

## Detailed Inventory

### 1. Integration Tests (Keep + Move)

#### test_file_operations.pl
- **Tests:** FileOperations tool - basic operations (read, write, list, etc.)
- **Type:** Integration
- **Decision:** ✅ KEEP + REFACTOR
- **Reasoning:** Core functionality test, well-structured with test framework
- **New Location:** `tests/integration/file_operations_test.pl`
- **Refactor Needed:**
  - Add Unicode/emoji tests for all operations
  - Add wide character tests (CJK, Arabic, etc.)
  - Add ANSI escape sequence tests
  - Add edge cases: empty files, large files (>1MB), long paths
  - Add special characters in filenames tests
  - Expand from current basic tests to comprehensive encoding matrix

#### test_tools_e2e.pl
- **Tests:** All tools through full stack (registry → executor → implementation)
- **Type:** Integration/E2E hybrid
- **Decision:** ✅ KEEP + REFACTOR
- **Reasoning:** Comprehensive end-to-end test of tool architecture
- **New Location:** `tests/integration/tool_executor_test.pl`
- **Refactor Needed:**
  - Add character encoding tests for all tool arguments
  - Test tool result storage with Unicode content
  - Add error handling edge cases
  - Expand to test EVERY tool operation

#### test_tools_e2e_natural.pl
- **Tests:** Natural language tool invocation patterns
- **Type:** E2E
- **Decision:** ✅ KEEP + MOVE
- **Reasoning:** Tests realistic user interaction patterns
- **New Location:** `tests/e2e/natural_language_test.pl`
- **Refactor Needed:** None - already well-designed

#### test_all_tools.pl
- **Tests:** Comprehensive test of ALL tool operations end-to-end
- **Type:** E2E
- **Decision:** ✅ KEEP + REFACTOR
- **Reasoning:** Most comprehensive existing test - lists all 18 file_operations, 10 version_control, etc.
- **New Location:** `tests/e2e/all_tools_test.pl`
- **Refactor Needed:**
  - Add character encoding tests for each tool operation
  - Currently tests existence, needs to test functionality with various inputs
  - Expand to cover edge cases

#### test_tool_calling.pl
- **Tests:** WorkflowOrchestrator tool calling mechanism
- **Type:** Integration
- **Decision:** ✅ KEEP + MOVE
- **Reasoning:** Tests core orchestration logic
- **New Location:** `tests/integration/workflow_orchestrator_test.pl`
- **Refactor Needed:** Add encoding tests to tool call arguments

#### test_direct_tools.pl
- **Tests:** Explicit tool invocation (forces AI to use specific tools)
- **Type:** E2E
- **Decision:** ✅ KEEP + MOVE
- **Reasoning:** Validates tool detection and execution
- **New Location:** `tests/e2e/direct_tool_invocation_test.pl`
- **Refactor Needed:** Expand to all tools, add encoding tests

#### test_tool_result_storage.pl
- **Tests:** ResultStorage tool persistence
- **Type:** Integration
- **Decision:** ✅ KEEP + REFACTOR
- **Reasoning:** Important for result persistence verification
- **New Location:** `tests/integration/result_storage_test.pl`
- **Refactor Needed:**
  - Add Unicode content storage tests
  - Test large results (>1MB)
  - Test binary data if applicable

---

### 2. Unit Tests (Keep + Move/Refactor)

#### test_ansi_parse.pl
- **Tests:** ANSI parser @-code to ANSI conversion
- **Type:** Unit
- **Decision:** ✅ KEEP + REFACTOR
- **Reasoning:** Core UI functionality - critical for terminal output
- **New Location:** `tests/unit/ansi_parser_test.pl`
- **Refactor Needed:**
  - Add comprehensive test suite (not just one example)
  - Test all @-codes: @BOLD@, @RESET@, colors, bright colors, backgrounds
  - Test malformed @-codes
  - Test nested @-codes
  - Test @-codes with Unicode content
  - Test edge cases (missing @RESET@, invalid codes, etc.)

#### test_ansi.pl
- **Tests:** ANSI parser - minimal test
- **Type:** Unit
- **Decision:** 🔄 MERGE into test_ansi_parse.pl
- **Reasoning:** Duplicate functionality - combine with test_ansi_parse.pl
- **Action:** Extract any unique tests, merge into ansi_parser_test.pl, delete original

#### test_markdown.pl
- **Tests:** Markdown renderer - basic rendering and stripping
- **Type:** Unit
- **Decision:** ✅ KEEP + REFACTOR
- **Reasoning:** Core UI functionality for markdown display
- **New Location:** `tests/unit/markdown_renderer_test.pl`
- **Refactor Needed:**
  - Add Unicode markdown tests (headings, lists with emoji)
  - Test CJK characters in markdown
  - Test ANSI codes within markdown
  - Test performance with large documents
  - Test edge cases (malformed markdown, deeply nested structures)

#### test_markdown_large.pl
- **Tests:** Markdown rendering performance with large documents
- **Type:** Unit/Performance
- **Decision:** 🔄 MERGE into test_markdown.pl
- **Reasoning:** Performance testing should be part of main markdown tests
- **Action:** Merge into markdown_renderer_test.pl as performance section

#### test_markdown_performance.pl
- **Tests:** Markdown rendering performance comparison
- **Type:** Unit/Performance
- **Decision:** 🔄 MERGE into test_markdown.pl
- **Reasoning:** Same as test_markdown_large.pl
- **Action:** Merge into markdown_renderer_test.pl

#### test_rendering_comparison.pl
- **Tests:** Performance comparison of line-by-line vs batched rendering
- **Type:** Unit/Performance
- **Decision:** 🔄 MERGE into test_markdown.pl OR move to performance suite
- **Reasoning:** Benchmark test - useful but specialized
- **New Location:** `tests/performance/markdown_rendering_benchmark.pl` (if performance/ created) OR merge into unit test
- **Action:** Merge performance section into unit test for now

#### test_number_sanitization.pl
- **Tests:** TextSanitizer number preservation (don't convert numbers to strings)
- **Type:** Unit
- **Decision:** ✅ KEEP + REFACTOR
- **Reasoning:** Critical for API compatibility - numbers must stay numbers
- **New Location:** `tests/unit/text_sanitizer_test.pl`
- **Refactor Needed:**
  - Combine with test_sanitizer.pl
  - Add comprehensive sanitization tests
  - Test all edge cases: 0, negative, floats, very large numbers
  - Test emoji replacement
  - Test Unicode handling

#### test_sanitizer.pl
- **Tests:** TextSanitizer emoji handling
- **Type:** Unit
- **Decision:** 🔄 MERGE into test_number_sanitization.pl
- **Reasoning:** Both test TextSanitizer - combine into single comprehensive test
- **Action:** Merge into text_sanitizer_test.pl

#### test_token_budget.pl
- **Tests:** HashtagParser token budget enforcement and truncation
- **Type:** Unit
- **Decision:** ✅ KEEP + REFACTOR
- **Reasoning:** Important for context management
- **New Location:** `tests/unit/hashtag_parser_test.pl`
- **Refactor Needed:**
  - Add Unicode content token estimation tests
  - Test with files containing emojis, wide characters
  - Verify truncation doesn't break UTF-8 sequences

#### test_token_simple.pl
- **Tests:** Simple token estimation test
- **Type:** Unit
- **Decision:** 🔄 MERGE into test_token_budget.pl OR create dedicated token_estimator_test.pl
- **Reasoning:** Token estimation is core functionality
- **New Location:** `tests/unit/token_estimator_test.pl`
- **Action:** Create comprehensive token estimator test with both simple and budget tests

#### test_todo_list.pl
- **Tests:** TodoStore and TodoList tool operations
- **Type:** Integration
- **Decision:** ✅ KEEP + REFACTOR
- **Reasoning:** Tests todo list functionality comprehensively
- **New Location:** `tests/integration/todo_list_test.pl`
- **Refactor Needed:**
  - Add Unicode in todo descriptions
  - Test emoji in todo titles
  - Test very long todo lists (100+ items)
  - Test edge cases (empty todos, duplicate IDs, invalid status)

#### test_path_authorizer.pl
- **Tests:** Path authorization/security
- **Type:** Unit
- **Decision:** ✅ KEEP + MOVE
- **Reasoning:** Security-critical functionality
- **New Location:** `tests/unit/path_authorizer_test.pl`
- **Refactor Needed:**
  - Add tests for paths with Unicode characters
  - Test path traversal attacks (../, etc.)
  - Test special characters in paths

#### test_hashtag_parser.pl
- **Tests:** Hashtag parsing for context inclusion
- **Type:** Unit
- **Decision:** ✅ KEEP + MOVE
- **Reasoning:** Core feature for context management
- **New Location:** `tests/unit/hashtag_parser_test.pl`
- **Refactor Needed:**
  - Add tests for hashtags with Unicode filenames
  - Test malformed hashtags
  - Test edge cases

---

### 3. End-to-End Tests (Keep + Move)

#### test_multi_turn.sh
- **Tests:** Multi-turn conversation with session resume
- **Type:** E2E
- **Decision:** ✅ KEEP + REFACTOR
- **Reasoning:** Critical for session continuity verification
- **New Location:** `tests/e2e/multi_turn_test.sh`
- **Refactor Needed:**
  - Add more turns (10+ instead of 2)
  - Test tool call history preservation
  - Test session persistence across restarts
  - Add Unicode content in messages

#### test_comprehensive.sh
- **Tests:** Comprehensive real-world usage patterns (large files, codebase analysis)
- **Type:** E2E
- **Decision:** ✅ KEEP + REFACTOR
- **Reasoning:** Tests realistic development workflows
- **New Location:** `tests/e2e/full_workflow_test.sh`
- **Refactor Needed:**
  - Add character encoding scenarios
  - Expand to cover all major workflows
  - Add error recovery tests

#### test_clio_performance.sh
- **Tests:** Performance benchmarking
- **Type:** E2E/Performance
- **Decision:** ✅ KEEP + MOVE
- **Reasoning:** Performance regression detection
- **New Location:** `tests/e2e/performance_test.sh`
- **Refactor Needed:** Add memory usage, token usage, response time metrics

#### test_github_copilot.pl
- **Tests:** GitHub Copilot API integration
- **Type:** Integration
- **Decision:** ✅ KEEP + MOVE
- **Reasoning:** Tests API provider integration
- **New Location:** `tests/integration/api_provider_test.pl`
- **Refactor Needed:**
  - Add tests for other providers (OpenAI, Anthropic, etc.)
  - Test API error handling
  - Test rate limiting

---

### 4. Debug/Investigation Tests (Discard or Archive)

#### test_atcode_debug.pl
- **Tests:** @-code debugging/investigation
- **Type:** Debug
- **Decision:** ❌ DISCARD
- **Reasoning:** Temporary debugging script - functionality covered by test_ansi_parse.pl
- **Alternative:** Core functionality tested in ansi_parser_test.pl

#### test_config_debug.pl
- **Tests:** Configuration debugging
- **Type:** Debug
- **Decision:** ❌ DISCARD
- **Reasoning:** Temporary debugging - not a permanent test
- **Alternative:** Configuration should be tested in integration tests

#### test_api_key_flow.pl
- **Tests:** API key flow debugging
- **Type:** Debug
- **Decision:** 🔄 REFACTOR → api_manager_test.pl
- **Reasoning:** API key handling is important, but this is a debug script
- **Action:** Extract useful assertions into proper API manager test

#### test_billing.pl
- **Tests:** API billing/usage debugging
- **Type:** Debug
- **Decision:** ❌ DISCARD
- **Reasoning:** Debugging script - billing info is provider-specific
- **Alternative:** Not needed for core testing

#### test_quota_debug.sh
- **Tests:** Rate limit/quota debugging
- **Type:** Debug
- **Decision:** ❌ DISCARD
- **Reasoning:** Temporary debugging
- **Alternative:** Rate limiting tested in api_provider_test.pl

#### test_editor.pl
- **Tests:** Text editor functionality (appears to be experimental)
- **Type:** Feature test
- **Decision:** ❌ DISCARD
- **Reasoning:** If editor feature doesn't exist in current CLIO, discard. If it does, keep.
- **Action:** Verify if editor feature exists, if not discard

---

### 5. Shell Script Tests (Analyze individually)

#### test_fixes.sh
- **Tests:** Bug fixes verification (appears to test specific fixes)
- **Type:** Regression
- **Decision:** ⚠️ ANALYZE
- **Action:** Read file to determine what fixes are tested
- **Likely:** Extract specific test cases into proper tests, discard script

#### test_provider_fix.sh
- **Tests:** Provider-specific fix
- **Type:** Regression
- **Decision:** ⚠️ ANALYZE
- **Action:** Read file, extract test case if still relevant
- **Likely:** Discard if fix is verified working

#### test_tool_conversation_bug.sh
- **Tests:** Specific tool conversation bug
- **Type:** Regression
- **Decision:** ⚠️ ANALYZE
- **Action:** Read file to determine bug
- **Likely:** Extract test case into tool_executor_test.pl, discard script

#### test_hashtag_integration.sh
- **Tests:** Hashtag system integration
- **Type:** Integration
- **Decision:** ✅ KEEP + REFACTOR
- **Reasoning:** Hashtag system is a core feature
- **New Location:** `tests/integration/hashtag_integration_test.pl`
- **Refactor Needed:** Convert from shell script to Perl test with proper framework

---

### 6. Text Files (Documentation, not tests)

#### test.txt
- **Type:** Manual test log / error documentation
- **Decision:** ⚠️ KEEP AS DOCUMENTATION
- **Reasoning:** Contains real error examples (wide character error) - valuable reference
- **New Location:** `tests/documentation/error_examples.txt` OR keep in project root as reference
- **Action:** Use errors in this file to create comprehensive regression tests

#### test2.txt, test3.txt
- **Type:** Unknown - need to read
- **Decision:** ⚠️ ANALYZE
- **Action:** Read files to determine content

#### test_897d8d5_working_commit.txt
- **Type:** Manual test notes for specific commit
- **Decision:** ❌ DISCARD
- **Reasoning:** Obsolete commit reference
- **Alternative:** Information in git history

#### test_after_corruption_fix.txt
- **Type:** Manual test notes
- **Decision:** ⚠️ ANALYZE → Extract test case
- **Action:** Read file, create regression test if relevant

#### test_after_sanitization_removal.txt
- **Type:** Manual test notes
- **Decision:** ⚠️ ANALYZE → Extract test case
- **Action:** Read file, create regression test if relevant

#### test_current_state.txt
- **Type:** Manual test notes
- **Decision:** ❌ DISCARD
- **Reasoning:** "Current state" is now obsolete
- **Alternative:** Current state is in git

#### test_no_custom_instructions.txt
- **Type:** Manual test notes
- **Decision:** ⚠️ ANALYZE → Extract test case
- **Action:** Read file to determine if test case needed

---

## Missing Tests (Must Create)

### Critical Character Encoding Tests
**NEW:** `tests/integration/encoding_matrix_test.pl`
- Test EVERY tool operation with EVERY character encoding
- Encoding types: ASCII, extended ASCII, UTF-8, emoji, CJK, Arabic, ANSI, special chars
- This is THE test that will catch the wide character bug and prevent regression
- Must test: FileOperations, VersionControl, TerminalOperations, MemoryOperations, WebOperations, TodoList, CodeIntelligence, ResultStorage

### Unit Tests to Create
- `tests/unit/json_encoding_test.pl` - JSON encoding with Unicode, wide chars, edge cases
- `tests/unit/session_persistence_test.pl` - Session save/load with Unicode content
- `tests/unit/message_history_test.pl` - Message history with tool calls, Unicode content

### Integration Tests to Create
- `tests/integration/terminal_operations_test.pl` - All terminal operations with encoding tests
- `tests/integration/memory_operations_test.pl` - All memory operations with encoding tests
- `tests/integration/web_operations_test.pl` - All web operations with encoding tests
- `tests/integration/code_intelligence_test.pl` - All code intelligence operations

### E2E Tests to Create
- `tests/e2e/cli_switches_test.sh` - Every CLI switch individually and in combinations
- `tests/e2e/session_continuity_test.pl` - Create, save, resume, multi-turn (10+ turns)

---

## Action Items

### Phase 1: Organization (CURRENT)
1. ✅ Create this INVENTORY.md
2. Move files from project root to tests/ subdirectories
3. Delete obsolete/debug files
4. Merge duplicate tests

### Phase 2: Refactoring
1. Refactor moved tests to add character encoding coverage
2. Create test framework (TestHelpers.pm, TestData.pm)
3. Create test runner (run_all_tests.pl)

### Phase 3: New Tests
1. Create encoding_matrix_test.pl (CRITICAL - will catch wide character bug)
2. Create missing unit tests
3. Create missing integration tests
4. Create missing e2e tests

### Phase 4: Bug Fixes
1. Fix wide character bug in ToolExecutor.pm (revealed by encoding tests)
2. Fix any other bugs discovered during comprehensive testing

### Phase 5: Documentation
1. Create tests/README.md
2. Create tests/TESTING_GUIDE.md
3. Update main documentation with testing info

---

## Next Steps

**Immediate:**
1. Get user approval for this inventory (collaboration checkpoint)
2. Begin Phase 1: Move/merge/delete files
3. Create test framework infrastructure
4. Start building encoding_matrix_test.pl

**The encoding_matrix_test.pl is the HIGHEST PRIORITY** - it will:
- Test ALL tools with ALL character encodings
- Reproduce the wide character bug
- Verify the fix works
- Prevent regression

---

END OF INVENTORY
