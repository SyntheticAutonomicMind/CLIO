# CLIO Protocols Specification

**Protocol system for CLIO (future architecture)**

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Overview

**Current Status:** CLIO does not have a protocol layer. Tools in `lib/CLIO/Tools/` are the primary interface the AI uses; `CLIO::Protocols::Puppeteer` exists as a multi-project topology helper called directly from `SubAgent.pm` and `PromptManager.pm`. The base64-encoded protocol format described below is a planned future extension that has not been implemented.

**Historical Note (for context only):**

The protocol layer was removed in June 2026. Earlier versions registered 14 protocol handlers (`FILE_OP`, `GIT`, `RAG`, `MEMORY`, `RECALL`, `SEARCH`, `URL_FETCH`, `WEB_SEARCH`, `CODE_ANALYSIS`, `VALIDATE`, `PATTERN`, `REFACTOR`, `SECURITY`, `AUDIT`) via `CLIO::Protocols::Manager->register()`, but the actual code was never exercised - 12 of the 14 handler classes were missing, and the 2 that existed (`Recall`, `Validate`) defined `process_request()` while the Manager dispatched `handle()`. The active architecture is the tool registry in `lib/CLIO/Tools/`.

Protocols are higher-level abstractions over tools, providing semantic grouping and simplified interfaces for related operations. They enable the AI to perform complex multi-step operations through structured commands.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Protocol Format

### General Structure

```text
[PROTOCOL_NAME:param1=value1:param2=value2:...]
```

**Parameters are base64-encoded for safety:**
```text
path=ZmlsZS50eHQ=  # "file.txt" encoded
```

### Example Protocols

**FILE_OP Protocol:**
```text
[FILE_OP:action=read:path=Li9zcmMvbWFpbi5j]
[FILE_OP:action=write:path=Y29uZmlnLnlhbWw=:content=...]
```

**GIT Protocol:**
```text
[GIT:action=status]
[GIT:action=commit:message=Rml4IGJ1Zw==]
```

**RAG Protocol:**
```text
[RAG:action=search:query=YXV0aGVudGljYXRpb24=]
[RAG:action=index:path=Li9saWI=]
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Planned Protocols

### FILE_OP Protocol

**Purpose:** File system operations

**Actions:**
- `read` - Read file contents
- `write` - Write/create file
- `list` - List directory
- `search` - Search files
- `delete` - Delete file/directory
- `move` - Move/rename file
- `copy` - Copy file

**Parameters:**
- `path` - File/directory path (base64)
- `content` - File content (base64)
- `pattern` - Search pattern (base64)
- `recursive` - Boolean flag

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### GIT Protocol

**Purpose:** Version control operations

**Actions:**
- `status` - Working tree status
- `diff` - Show changes
- `commit` - Create commit
- `push` - Push to remote
- `pull` - Pull from remote
- `branch` - Branch operations
- `checkout` - Switch branches
- `merge` - Merge branches

**Parameters:**
- `message` - Commit message (base64)
- `branch` - Branch name (base64)
- `remote` - Remote name (base64)
- `files` - File list (base64)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### RAG Protocol

**Purpose:** Retrieval-Augmented Generation (code search and analysis)

**Actions:**
- `index` - Index codebase
- `search` - Semantic search
- `analyze` - Code analysis
- `explain` - Explain code

**Parameters:**
- `query` - Search query (base64)
- `path` - Code path (base64)
- `language` - Programming language
- `context_size` - Context window size

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### MEMORY Protocol

**Purpose:** Long-term memory operations

**Actions:**
- `store` - Store information
- `retrieve` - Retrieve by key
- `search` - Search memories
- `forget` - Delete memory

**Parameters:**
- `key` - Memory key (base64)
- `value` - Memory value (base64)
- `query` - Search query (base64)
- `metadata` - JSON metadata (base64)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### EXEC Protocol

**Purpose:** Command execution

**Actions:**
- `run` - Execute command
- `script` - Run script
- `background` - Background process

**Parameters:**
- `command` - Command to execute (base64)
- `args` - Arguments array (base64)
- `timeout` - Timeout in seconds
- `cwd` - Working directory (base64)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### WEB Protocol

**Purpose:** Web operations

**Actions:**
- `fetch` - Fetch webpage
- `api` - API request
- `download` - Download file

**Parameters:**
- `url` - URL (base64)
- `method` - HTTP method
- `headers` - Headers (base64 JSON)
- `body` - Request body (base64)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Protocol Architecture (Planned)

### Protocol Handler Pattern

```perl
package CLIO::Protocols::FileOp;

use strict;
use warnings;
use MIME::Base64 qw(encode_base64 decode_base64);

sub new {
    my ($class, %opts) = @_;
    return bless {
        tool_registry => $opts{tool_registry},
    }, $class;
}

sub execute {
    my ($self, $command, $session) = @_;
    
    # Parse protocol format
    if ($command =~ /^\[FILE_OP:(.+)\]$/) {
        my $params_str = $1;
        my %params = $self->parse_params($params_str);
        
        # Decode base64 parameters
        my $action = $params{action};
        my $path = decode_base64($params{path});
        
        # Execute via tool registry
        return $self->{tool_registry}->execute(
            'file_operations',
            {
                operation => $action,
                path => $path,
                %params,
            }
        );
    }
    
    return { success => 0, error => "Invalid FILE_OP format" };
}

sub parse_params {
    my ($self, $params_str) = @_;
    
    my %params;
    for my $pair (split /:/, $params_str) {
        my ($key, $value) = split /=/, $pair, 2;
        $params{$key} = $value;
    }
    
    return %params;
}

1;
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Protocol Detection

AI automatically detects protocols in responses:

```text
User: Read the config file

AI generates:
[FILE_OP:action=read:path=Y29uZmlnLnlhbWw=]

Protocol Manager:
1. Detects [FILE_OP:...] pattern
2. Routes to FileOp protocol handler
3. Decodes parameters
4. Executes via tool registry
5. Returns result
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Benefits of Protocol Layer

**1. Simplified AI Interface:**
- Fewer tool definitions needed
- Clearer semantic grouping
- Easier for AI to reason about

**2. Parameter Safety:**
- Base64 encoding prevents injection
- Structured validation
- Type safety

**3. Extensibility:**
- Easy to add new protocols
- Backward compatible
- Plugin-friendly

**4. Abstraction:**
- Hide implementation details
- Consistent interface
- Easy to refactor tools

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Migration Path

**Phase 1:** Tool-based (current)
- Direct tool calls
- Simple architecture
- Proven approach

**Phase 2:** Hybrid (planned)
- Protocols as optional layer
- Tools remain primary
- Gradual migration

**Phase 3:** Protocol-first (future)
- Protocols as primary interface
- Tools as implementation detail
- Advanced features (caching, composition, etc.)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Current Implementation

**As of June 2026:**

CLIO uses a **tool-based architecture** exclusively. The protocol modules that previously shipped in `lib/CLIO/Protocols/` (Architect, Editor, Validate, Recall) have been removed. `CLIO::Protocols::Puppeteer` remains as a non-protocol helper class for multi-project coordination.
**What works today:**
- Direct tool calls via AI
- Tool registry
- Action descriptions
- Structured tool results

**What's planned:**
- Protocol handlers
- Base64 parameter encoding
- Protocol composition
- Protocol caching

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Adding Custom Protocols (Future)

**Steps to add a new protocol:**

1. **Create Protocol Handler**
   ```perl
   package CLIO::Protocols::MyProtocol;
   use parent 'CLIO::Protocols::Protocol';
   
   sub execute { ... }
   ```

2. **Register Protocol**
   ```perl
   $protocol_manager->register('MY_PROTOCOL', $handler);
   ```

3. **Define Actions**
   ```perl
   sub execute {
       my $action = $params{action};
       if ($action eq 'my_action') { ... }
   }
   ```

4. **Use in Conversation**
   ```
   [MY_PROTOCOL:action=my_action:param=value]
   ```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Related Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) - System architecture
- [TOOLS.md](TOOLS.md) - Current tool reference
- [DEVELOPER_GUIDE.md](../DEVELOPER_GUIDE.md) - Extension guide

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

**Note:** CLIO does not have a working protocol layer. Tool calls are the only mechanism for the AI to invoke functions. The base64-encoded protocol format described in this document has never been implemented.
