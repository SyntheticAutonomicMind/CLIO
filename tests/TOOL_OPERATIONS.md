# CLIO Tools Operation Reference

## Complete list of all tool operations for testing

### FileOperations (17 operations)

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

**WRITE (8):**
- `create_file` - path, content
- `write_file` - path, content
- `append_file` - path, content
- `replace_string` - path, old_string, new_string
- `multi_replace_string` - replacements (array)
- `insert_at_line` - path, line_number, content
- `delete_file` - path
- `rename_file` - source, destination
- `create_directory` - path

### TerminalOperations (3 operations)

- `execute` or `exec` - command, cwd (optional), isInteractive (optional)
- `validate` - command

### MemoryOperations (5 operations)

- `store` - key, value, metadata (optional)
- `retrieve` - key
- `search` - query
- `list` - (no params)
- `delete` - key

### TodoList (4 operations)

- `read` - (no params)
- `write` - todoList (array)
- `update` - todo (single item)
- `add` - todo (single item)

### VersionControl (operations via git commands)

- `status` - (no params)
- `diff` - path (optional)
- `log` - count (optional), path (optional)
- `add` - files (array or string)
- `commit` - message
- `branch` - action ('list'|'create'|'delete'), name (optional)
- `checkout` - branch or commit
- `show` - commit
- `remote` - action, url (optional)

### WebOperations

- `fetch` - url, method (optional), headers (optional)

### CodeIntelligence

- `analyze` - path or scope
- `find_symbol` - name, type (optional)
- `get_dependencies` - path

### ResultStorage (internal - not direct operations)

This is NOT a user-facing tool but internal infrastructure.
Operations handled via FileOperations.read_tool_result

## Notes for Testing

1. **FileOperations** - Most operations, most critical for encoding tests
2. **TerminalOperations** - Commands can output any encoding
3. **MemoryOperations** - Store/retrieve can contain any encoding
4. **TodoList** - Descriptions can contain any encoding
5. **VersionControl** - Commit messages, file content can be any encoding
6. **WebOperations** - URLs and responses can contain any encoding

## Test Priority

HIGH PRIORITY (test ALL encodings):
- FileOperations: create_file, write_file, read_file, append_file
- MemoryOperations: store, retrieve
- TodoList: write
- TerminalOperations: execute

MEDIUM PRIORITY:
- FileOperations: replace_string, grep_search
- VersionControl: commit, add

LOW PRIORITY:
- FileOperations: file_search, list_dir
- WebOperations: fetch (encoding depends on remote server)
