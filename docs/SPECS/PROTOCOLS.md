# CLIO Protocols Specification

**Protocol system for CLIO (future architecture)**

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Overview

**Current Status:** The protocol layer is **implemented and active**. CLIO uses protocols for higher-level AI-driven workflows including architecture analysis, code editing, validation, and repository mapping.

**What Are Protocols?**

Protocols are higher-level abstractions over tools, providing semantic grouping and simplified interfaces for related operations. They enable the AI to perform complex multi-step operations through structured commands.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

## Protocol Format

### General Structure

```
[PROTOCOL_NAME:param1=value1:param2=value2:...]
```

**Parameters are base64-encoded for safety:**
```
path=ZmlsZS50eHQ=  # "file.txt" encoded
```

### Example Protocols

**FILE_OP Protocol:**
```
[FILE_OP:action=read:path=Li9zcmMvbWFpbi5j]
[FILE_OP:action=write:path=Y29uZmlnLnlhbWw=:content=...]
```

**GIT Protocol:**
```
[GIT:action=status]
[GIT:action=commit:message=Rml4IGJ1Zw==]
```

**RAG Protocol:**
```
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

```
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

**As of January 2026:**

CLIO uses **tool-based architecture exclusively**. The protocol layer is not yet implemented.

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

**Note:** Protocol layer is planned future architecture. Current CLIO uses tool-based approach which works excellently for all current use cases. Protocols will be added when advanced features require them.
