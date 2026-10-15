# CLIO Tools Operation Reference

## Complete list of all tool operations for testing

### FileOperations (16 canonical operations)

**READ (5):**
- `read_file` - path, start_line (optional), end_line (optional)
- `list_dir` - path, recursive (optional)
- `file_exists` - path
- `get_file_info` - path
- `get_errors` - path

**SEARCH (4):**
- `file_search` - pattern, directory (optional)
- `grep_search` - query, pattern (optional), is_regex (optional)
- `semantic_search` - query, scope (optional)
- `read_tool_result` - toolCallId, offset (optional), length (optional)

**WRITE (7):**
- `write_file` - path, content, append (optional) (create_file and append_file are aliases)
- `replace_string` - path, old_string, new_string
- `multi_replace_string` - replacements (array)
- `insert_at_line` - path, line, content
- `delete_file` - path
- `rename_file` - old_path, new_path
- `create_directory` - path

### TerminalOperations (2 operations)

- `exec` - command, timeout (optional), working_directory (optional), passthrough (optional)
- `validate` - command

### MemoryOperations (13 operations)

- `store` - key, content
- `retrieve` - key
- `search` - query
- `list` - (no params)
- `delete` - key
- `recall_sessions` - query
- `add_discovery` - fact, confidence (optional)
- `add_solution` - error, solution, examples (optional)
- `add_pattern` - pattern, confidence (optional)
- `add_corroboration` - search_text
- `update_ltm` - search_text, replacement
- `prune_ltm` - (all optional)
- `ltm_stats` - (no params)

### TodoList (4 operations)

- `read` - (no params)
- `write` - todoList (array)
- `update` - todoUpdates (array)
- `add` - newTodos (array)

### VersionControl (11 operations)

- `status` - (no required params)
- `log` - count, limit (optional)
- `diff` - ref1, ref2, file (optional)
- `branch` - action, name (optional)
- `commit` - message
- `push` - branch, remote (optional)
- `pull` - branch, remote (optional)
- `blame` - file
- `stash` - action, index (optional)
- `tag` - action, name (optional)
- `worktree` - action, worktree_path (optional)

### WebOperations (2 operations)

- `fetch_url` - url
- `search_web` - query

### CodeIntelligence (2 operations)

- `list_usages` - symbol_name, file_paths (optional), context_lines (optional)
- `search_history` - query

## Notes for Testing

1. **FileOperations** - Most operations, most critical for encoding tests
2. **TerminalOperations** - Commands can output any encoding
3. **MemoryOperations** - Store/retrieve can contain any encoding
4. **TodoList** - Descriptions can contain any encoding
5. **VersionControl** - Commit messages, file content can be any encoding
6. **WebOperations** - URLs and responses can contain any encoding

## Test Priority

HIGH PRIORITY (test ALL encodings):
- FileOperations: write_file, read_file
- MemoryOperations: store, retrieve
- TodoList: write
- TerminalOperations: exec

MEDIUM PRIORITY:
- FileOperations: replace_string, grep_search
- VersionControl: commit, branch

LOW PRIORITY:
- FileOperations: file_search, list_dir
- WebOperations: fetch_url (encoding depends on remote server)
