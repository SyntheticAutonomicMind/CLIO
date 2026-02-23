# CLIO Tools Reference

**Complete reference for all CLIO tool operations**

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Overview

CLIO provides comprehensive tooling across multiple categories. Every tool operation displays an **action description** showing exactly what it's doing in real-time.

**Tool Categories:**
1. [File Operations](#file-operations) - 18 operations
2. [Version Control](#version-control) - 10 operations
3. [Terminal](#terminal-operations) - 2 operations
4. [Memory](#memory-operations) - 11 operations (session + LTM)
5. [Todo Lists](#todo-list-operations) - 4 operations (CRUD)
6. [Web](#web-operations) - 2 operations
7. Code Intelligence - 2 operations (list_usages, search_history)
8. User Collaboration - 1 operation (request_input)
9. Sub-Agent Operations - 10 operations (spawn, list, status, kill, etc.)
10. Remote Execution - 7 operations (execute_remote, execute_parallel, etc.)
11. Apply Patch - 1 operation (patch application)

> **Note:** This document covers the original core tools in detail. For complete tool schemas including newer tools (code intelligence, user collaboration, sub-agents, remote execution, apply patch, MCP bridge), see the system prompt or `docs/DEVELOPER_GUIDE.md`.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## File Operations

### read_file

**Description:** Read contents of a file with optional line range.

**Parameters:**
- `path` (string, required) - File path to read
- `start_line` (integer, optional) - Starting line number (1-indexed)
- `end_line` (integer, optional) - Ending line number (inclusive)

**Returns:** File contents as string

**Action Description:** `reading {path} ({line_count} lines)`

**Example:**
```
YOU: Show me the contents of src/main.c

SYSTEM: [file_operations] - reading ./src/main.c (247 lines)
```

**Error Conditions:**
- File not found
- Permission denied
- Invalid line range

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### write_file / create_file

**Description:** Create new file or overwrite existing file with content.

**Parameters:**
- `path` (string, required) - File path to write
- `content` (string, required) - Content to write

**Returns:** Success message with file path and size

**Action Description:** `writing {path} ({byte_count} bytes)`

**Example:**
```
YOU: Create a file called test.txt with content "Hello, world!"

SYSTEM: [file_operations] - writing ./test.txt (13 bytes)
```

**Error Conditions:**
- Permission denied
- Invalid path
- Disk full

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### list_dir

**Description:** List contents of a directory with file and directory counts.

**Parameters:**
- `path` (string, required) - Directory path to list

**Returns:** Array of entries with names and types

**Action Description:** `listing {path} ({file_count} files, {dir_count} directories)`

**Example:**
```
YOU: List the files in lib/CLIO/

SYSTEM: [file_operations] - listing ./lib/CLIO/ (5 files, 4 directories)
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### file_search

**Description:** Find files matching a glob pattern.

**Parameters:**
- `pattern` (string, required) - Glob pattern (e.g., `**/*.pm`, `src/**/*.c`)
- `base_path` (string, optional) - Base directory (default: current directory)

**Returns:** Array of matching file paths

**Action Description:** `searching {base_path} for pattern "{pattern}"`

**Example:**
```
YOU: Find all Perl modules in the project

SYSTEM: [file_operations] - searching ./ for pattern "**/*.pm" (42 files)
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### grep_search

**Description:** Search file contents for a pattern (text or regex).

**Parameters:**
- `pattern` (string, required) - Search pattern
- `path` (string, required) - File or directory to search
- `is_regex` (boolean, optional) - Whether pattern is regex (default: false)

**Returns:** Array of matches with file paths, line numbers, and content

**Action Description:** `searching {path} for pattern "{pattern}"`

**Example:**
```
YOU: Search for all TODO comments in lib/

SYSTEM: [file_operations] - searching ./lib for pattern "TODO" (18 files)
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### semantic_search

**Description:** Natural language code search (AI-powered).

**Parameters:**
- `query` (string, required) - Natural language search query
- `path` (string, optional) - Directory to search (default: current directory)

**Returns:** Relevant code snippets ranked by relevance

**Action Description:** `semantic search in {path} for "{query}"`

**Example:**
```
YOU: Find functions that handle authentication

SYSTEM: [file_operations] - semantic search in ./ for "authentication"
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### replace_string

**Description:** Find and replace string in file.

**Parameters:**
- `path` (string, required) - File to modify
- `old_string` (string, required) - String to find
- `new_string` (string, required) - Replacement string

**Returns:** Success message with number of replacements

**Action Description:** `replacing string in {path} ({count} replacements)`

**Example:**
```
YOU: In config.yaml, replace port 8080 with 9000

SYSTEM: [file_operations] - replacing string in ./config.yaml (1 replacement)
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### delete_file

**Description:** Delete a file or directory.

**Parameters:**
- `path` (string, required) - Path to delete

**Returns:** Success message

**Action Description:** `deleting {path}`

**Example:**
```
YOU: Delete the temp/ directory

SYSTEM: [file_operations] - deleting ./temp/
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### Other File Operations

**rename_file / move_file** - Rename or move files  
**file_exists** - Check if file exists  
**get_file_info** - Get file metadata (size, modified time)  
**get_errors** - Get compilation/lint errors  
**list_code_usages** - Find symbol references  
**read_tool_result** - Read previous tool output  

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Version Control

### git_status

**Description:** Show working tree status.

**Parameters:** None

**Returns:** Git status output

**Action Description:** `executing git status in {cwd}`

**Example:**
```
YOU: What's the current git status?

SYSTEM: [git] - executing git status in ./
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### git_diff

**Description:** Show changes in working directory or between commits.

**Parameters:**
- `commit1` (string, optional) - First commit (default: working directory)
- `commit2` (string, optional) - Second commit
- `path` (string, optional) - Specific file/directory

**Returns:** Diff output

**Action Description:** `executing git diff in {cwd}`

**Example:**
```
YOU: Show me what changed in the last commit

SYSTEM: [git] - executing git diff HEAD~1..HEAD in ./
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### git_commit

**Description:** Create a new commit.

**Parameters:**
- `message` (string, required) - Commit message
- `files` (array, optional) - Specific files to commit (default: all staged)

**Returns:** Commit SHA and message

**Action Description:** `committing changes in {cwd}`

**Example:**
```
YOU: Commit all changes with message "Fix authentication bug"

SYSTEM: [git] - staging all changes
SYSTEM: [git] - committing with message "Fix authentication bug"
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### Other Git Operations

**git_log** - Show commit history  
**git_push** - Push commits to remote  
**git_pull** - Pull changes from remote  
**git_branch** - List/create/delete branches  
**git_checkout** - Switch branches or restore files  
**git_merge** - Merge branches  
**git_reset** - Reset changes  

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Terminal Operations

### execute_command

**Description:** Execute a shell command.

**Parameters:**
- `command` (string, required) - Command to execute
- `timeout` (integer, optional) - Timeout in seconds (default: 30)

**Returns:** Command output (stdout + stderr)

**Action Description:** `executing: {command}`

**Example:**
```
YOU: Count the lines of code in all Perl files

SYSTEM: [terminal] - executing: find lib -name "*.pm" -exec wc -l {} + | tail -1
```

**Security Note:** Use with caution. Validates input but user is responsible for command safety.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### get_terminal_output

**Description:** Get output from a previously executed command.

**Parameters:**
- `command_id` (string, optional) - Specific command ID (default: last command)

**Returns:** Stored command output

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Memory Operations

### store

**Description:** Store information for later retrieval.

**Parameters:**
- `key` (string, required) - Memory key/identifier
- `value` (string, required) - Content to store
- `metadata` (object, optional) - Additional metadata

**Returns:** Success message with key

**Action Description:** `storing memory: {key}`

**Example:**
```
YOU: Remember that our API endpoint is https://api.example.com

SYSTEM: [memory] - storing memory: api_endpoint
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### retrieve

**Description:** Retrieve stored information by key.

**Parameters:**
- `key` (string, required) - Memory key

**Returns:** Stored value and metadata

**Action Description:** `retrieving memory: {key}`

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### search

**Description:** Search stored memories.

**Parameters:**
- `query` (string, required) - Search query

**Returns:** Matching memories with relevance scores

**Action Description:** `searching memories for "{query}"`

**Example:**
```
YOU: Find all information about database configuration

SYSTEM: [memory] - searching memories for "database configuration"
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### Other Memory Operations

**list_memories** - List all stored memories  
**delete** - Delete a memory by key  

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Todo List Operations

### manage_todo_list

**Description:** Manage structured todo lists for task tracking.

**Operations:** read, write, update, add

**Read Operation:**

**Parameters:** None  
**Returns:** Current todo list  
**Action Description:** `reading todo list`

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**Write Operation:**

**Parameters:**
- `todoList` (array, required) - Complete todo list

**Todo Item Format:**
```json
{
  "id": 1,
  "title": "Task title (3-7 words)",
  "description": "Detailed context and requirements",
  "status": "not-started|in-progress|completed|blocked",
  "priority": "low|medium|high|critical"
}
```

**Action Description:** `writing todo list ({count} items)`

**Example:**
```
YOU: Create a todo list for this refactoring:
1. Review current code
2. Design new structure
3. Implement changes
4. Test thoroughly

SYSTEM: [todo_operations] - writing todo list (4 items)
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**Update Operation:**

**Parameters:**
- `todoUpdates` (array, required) - Updates to apply

**Update Format:**
```json
{
  "id": 2,
  "status": "in-progress"
}
```

**Action Description:** `updating todo items ({count} updates)`

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**Add Operation:**

**Parameters:**
- `newTodos` (array, required) - New todos to append

**Action Description:** `adding {count} todos to list`

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Web Operations

### fetch_webpage

**Description:** Fetch and extract content from a webpage.

**Parameters:**
- `url` (string, required) - URL to fetch
- `extract_text` (boolean, optional) - Extract text only (default: true)

**Returns:** Page content

**Action Description:** `fetching {url}`

**Example:**
```
YOU: Fetch the documentation from https://docs.example.com/api

SYSTEM: [web] - fetching https://docs.example.com/api
```

**Note:** Respects robots.txt and rate limiting.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Tool Result Storage

All tool operations store their results for AI context. Results can be retrieved using `read_tool_result` operation.

**Storage Format:**
```json
{
  "tool": "file_operations",
  "operation": "read_file",
  "params": {...},
  "result": {...},
  "timestamp": "2026-01-18T14:30:52Z"
}
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Error Handling

All tools return structured error responses:

```json
{
  "success": false,
  "error": "Error message",
  "error_type": "permission_denied|not_found|invalid_input|timeout",
  "details": {...}
}
```

**Common Error Types:**
- `permission_denied` - Insufficient permissions
- `not_found` - File/resource not found
- `invalid_input` - Invalid parameters
- `timeout` - Operation timed out
- `external_error` - External command/API failed

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Adding Custom Tools

See [DEVELOPER_GUIDE.md](../DEVELOPER_GUIDE.md#adding-new-tools) for instructions on creating custom tools.

**Tool Interface:**
1. Extend `CLIO::Tools::Tool`
2. Implement `route_operation()`
3. Set action descriptions
4. Return structured results
5. Register in Registry

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**For more information:**
- [ARCHITECTURE.md](ARCHITECTURE.md) - System design
- [DEVELOPER_GUIDE.md](../DEVELOPER_GUIDE.md) - Extension guide
- [USER_GUIDE.md](../USER_GUIDE.md) - Usage examples
