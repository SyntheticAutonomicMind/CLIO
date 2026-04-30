# CLIO Tools Reference

**Complete reference for all CLIO tool operations**

---

## Overview

CLIO provides comprehensive tooling across multiple categories. Every tool operation displays an **action description** showing exactly what it's doing in real-time.

**Tool Categories:**
1. [file_operations](#file-operations) - 18 operations
2. [version_control](#version-control) - 11 operations
3. [terminal_operations](#terminal-operations) - 2 operations
4. [memory_operations](#memory-operations) - 11 operations (session + LTM)
5. [todo_operations](#todo-operations) - 4 operations (CRUD)
6. [web_operations](#web-operations) - 2 operations
7. [code_intelligence](#code-intelligence) - 2 operations
8. [interact](#user-collaboration) - 1 operation
9. [agent_operations](#sub-agent-operations) - 10 operations
10. [remote_execution](#remote-execution) - 7 operations
11. [apply_patch](#apply-patch) - 1 operation

> **CRITICAL:** All tools use a unified `operation` parameter. Do NOT call individual operation names as separate tools (e.g., `git_status` is NOT valid). Always use the parent tool with `operation: "action"`.

---

## file_operations

**Tool:** `file_operations`

**Required Parameter:** `operation` (string)

### Search Operations

#### grep_search

**Description:** Search file contents for a pattern (text or regex).

**Parameters:**
- `query` (string, **required**) - Search term to find in files
- `pattern` (string, optional) - Glob pattern to filter which files to search (e.g., `*.pm`, `**/*.pl`)
- `path` (string, optional) - Directory to search (default: current directory)
- `is_regex` (boolean, optional) - Whether `query` is a regex pattern (default: false)

**Example Call:**
```json
{"operation": "grep_search", "query": "TODO", "path": "lib", "pattern": "**/*.pm"}
```

#### file_search

**Description:** Find files matching a glob pattern.

**Parameters:**
- `pattern` (string, **required**) - Glob pattern (e.g., `**/*.pm`, `src/**/*.c`)
- `directory` (string, optional) - Base directory (default: current directory)

#### semantic_search

**Description:** Natural language code search (AI-powered).

**Parameters:**
- `query` (string, **required**) - Natural language search query
- `scope` (string, optional) - Directory to search (default: current directory)

#### read_tool_result

**Description:** Read persisted large tool results in chunks.

**Parameters:**
- `toolCallId` (string, **required**) - Tool call ID to retrieve stored result chunks
- `offset` (integer, optional) - Byte offset to start reading from (default: 0)
- `length` (integer, optional) - Number of bytes to read (default: 8192, max: 32768)

### Read Operations

#### read_file

**Description:** Read contents of a file with optional line range.

**Parameters:**
- `path` (string, **required**) - File path to read
- `start_line` (integer, optional) - Starting line number (1-indexed, inclusive)
- `end_line` (integer, optional) - Ending line number (inclusive)

#### list_dir

**Description:** List contents of a directory.

**Parameters:**
- `path` (string, **required**) - Directory path to list
- `recursive` (boolean, optional) - List recursively (default: false)

#### file_exists

**Description:** Check if file or directory exists.

**Parameters:** `path` (string, **required**)

#### get_file_info

**Description:** Get file metadata (size, type, modified time).

**Parameters:** `path` (string, **required**)

#### get_errors

**Description:** Get compilation/lint errors for file (Perl-specific).

**Parameters:** `path` (string, **required**) or `paths` (array of strings)

### Write Operations

#### create_file / write_file

**Description:** Create new file or overwrite existing file.

**Parameters:**
- `path` (string, **required**)
- `content` (string, **required**) - File content

#### append_file

**Description:** Append content to file.

**Parameters:**
- `path` (string, **required**)
- `content` (string, **required**)

#### replace_string

**Description:** Find and replace text in file.

**Parameters:**
- `path` (string, **required**)
- `old_string` (string, **required**)
- `new_string` (string, **required**)

#### multi_replace_string

**Description:** Batch replace operations across multiple files.

**Parameters:**
- `replacements` (array, **required**) - Array of {path, old_string, new_string}

#### insert_at_line

**Description:** Insert content at specific line number.

**Parameters:**
- `path` (string, **required**)
- `line` (integer, **required**)
- `content` (string, **required**)

#### delete_file

**Description:** Delete file or directory.

**Parameters:**
- `path` (string, **required**)
- `recursive` (boolean, optional) - Required for directories

#### rename_file

**Description:** Rename or move files.

**Parameters:**
- `old_path` (string, **required**)
- `new_path` (string, **required**)

#### create_directory

**Description:** Create directory (with parents).

**Parameters:**
- `path` (string, **required**)
- `recursive` (boolean, optional)

---

## version_control

**Tool:** `version_control`

**Required Parameter:** `operation` (string)

| Operation | Description | Required Parameters |
|-----------|-------------|---------------------|
| `status` | Show working tree status | None |
| `log` | Show commit history | `limit` (optional, default: 10) |
| `diff` | Show changes between commits | `ref1` (optional), `ref2` (optional), `file` (optional) |
| `branch` | List/create/delete/switch branches | `action` (optional): list, create, delete, switch |
| `commit` | Create a new commit | `message` (required) |
| `push` | Push commits to remote | `branch` (optional), `remote` (optional) |
| `pull` | Pull changes from remote | `branch` (optional), `remote` (optional) |
| `blame` | Show file annotation | `file` (required) |
| `stash` | Stash operations | `action` (optional): save, list, apply, drop; `index` (optional) |
| `tag` | Tag operations | `action` (optional): list, create, delete; `name` (optional) |
| `worktree` | Worktree operations | `action` (optional): list, add, remove, prune |

**Shared Parameters:**
- `repository_path` (string, optional) - Git repo path (default: `.`)

**Examples:**
```json
{"operation": "status"}
{"operation": "log", "limit": 10}
{"operation": "commit", "message": "fix: resolve bug"}
{"operation": "diff", "ref1": "HEAD~1", "ref2": "HEAD"}
```

---

## terminal_operations

**Tool:** `terminal_operations`

**Required Parameter:** `operation` (string)

| Operation | Description | Required Parameters |
|-----------|-------------|---------------------|
| `exec` | Execute a shell command | `command` |
| `validate` | Check command safety before execution | `command` |

**Parameters:**
- `command` (string, **required**) - Shell command to execute
- `timeout` (integer, optional) - Timeout in seconds (default: 60)
- `working_directory` (string, optional) - Working directory (default: `.`)
- `passthrough` (boolean, optional) - Force direct terminal access

**Examples:**
```json
{"operation": "exec", "command": "ls -la"}
{"operation": "exec", "command": "make test", "timeout": 120}
```

---

## memory_operations

**Tool:** `memory_operations`

**Required Parameter:** `operation` (string)

| Operation | Description | Required Parameters |
|-----------|-------------|---------------------|
| `store` | Store session memory | `key` (required), `content` (required) |
| `retrieve` | Retrieve session memory | `key` (required) |
| `search` | Search session memory | `query` (required) |
| `list` | List all session memory | None |
| `delete` | Delete session memory | `key` (required) |
| `recall_sessions` | Search previous sessions | `query` (required), `max_sessions` (optional), `max_results` (optional) |
| `add_discovery` | Store LTM discovery | `fact` (required), `confidence` (optional) |
| `add_solution` | Store LTM solution | `error` (required), `solution` (required) |
| `add_pattern` | Store LTM pattern | `pattern` (required), `confidence` (optional) |
| `update_ltm` | Update existing LTM entry | `search_text` (required), `replacement` (required) |
| `prune_ltm` | Clean old LTM entries | `max_age_days` (optional), `min_confidence` (optional) |

---

## todo_operations

**Tool:** `todo_operations`

**Required Parameter:** `operation` (string)

| Operation | Description | Required Parameters |
|-----------|-------------|---------------------|
| `read` | Get current todo list | None |
| `write` | Create/replace todo list | `todoList` (array, required; IDs auto-assigned if omitted) |
| `update` | Update todo status | `todoUpdates` (array, required) |
| `add` | Add new todos | `newTodos` (array, required; IDs auto-assigned) |

---

## web_operations

**Tool:** `web_operations`

**Required Parameter:** `operation` (string)

| Operation | Description | Required Parameters |
|-----------|-------------|---------------------|
| `fetch_url` | Fetch content from URL | `url` (required), `timeout` (optional) |
| `search_web` | Web search | `query` (required), `max_results` (optional) |

---

## code_intelligence

**Tool:** `code_intelligence`

**Required Parameter:** `operation` (string)

| Operation | Description | Required Parameters |
|-----------|-------------|---------------------|
| `list_usages` | Find all usages of a symbol | `symbol_name` (required), `file_paths` (optional) |
| `search_history` | Semantic search git history | `query` (required), `max_results` (optional), `since` (optional) |

---

## interact

**Tool:** `interact`

**Required Parameter:** `operation` (string)

| Operation | Description | Required Parameters |
|-----------|-------------|---------------------|
| `request_input` | Request user input | `message` (required), `listen_broker` (optional), `timeout` (optional) |

---

## agent_operations

**Tool:** `agent_operations`

**Required Parameter:** `operation` (string)

| Operation | Description | Required Parameters |
|-----------|-------------|---------------------|
| `spawn` | Create a new sub-agent | `task` (required), `model` (optional), `working_dir` (optional) |
| `list` | List all active agents | None |
| `status` | Get agent status | `agent_id` (required) |
| `wait` | Wait for agent activity | `timeout` (optional), `poll_interval` (optional) |
| `kill` | Terminate specific agent | `agent_id` (required) |
| `killall` | Terminate all agents | None |
| `inbox` | Check unread messages | None |
| `acknowledge` | Mark messages as read | `message_ids` (optional) |
| `history` | View all messages | None |
| `send` | Send message to agent | `agent_id` (required), `message` (required) |
| `broadcast` | Send message to all agents | `message` (required) |

---

## remote_execution

**Tool:** `remote_execution`

**Required Parameter:** `operation` (string)

| Operation | Description | Required Parameters |
|-----------|-------------|---------------------|
| `execute_remote` | Run task on remote system | `host` (required), `command` (required) |
| `execute_parallel` | Run task on multiple devices | `targets` (required), `command` (required) |
| `prepare_remote` | Pre-stage CLIO on remote | `host` (required) |
| `cleanup_remote` | Remove CLIO from remote | `host` (required) |
| `check_remote` | Verify remote connectivity | `host` (required) |
| `transfer_files` | Copy files to remote | `host` (required), `files` (required) |
| `retrieve_files` | Fetch files from remote | `host` (required), `files` (required) |

---

## apply_patch

**Tool:** `apply_patch`

**Required Parameter:** `operation` (string)

**Parameters:**
- `patch` (string, **required**) - Patch text in format:
  ```
  *** Begin Patch
  *** Add File: <path>
  +new line content
  *** Update File: <path>
  @@ context line
  -old line to remove
  +new line to add
   unchanged context line
  *** Delete File: <path>
  *** End Patch
  ```

---

**For more information:**
- [ARCHITECTURE.md](ARCHITECTURE.md) - System design
- [DEVELOPER_GUIDE.md](../DEVELOPER_GUIDE.md) - Extension guide
- [USER_GUIDE.md](../USER_GUIDE.md) - Usage examples