# CLIO ACP Agent Documentation

## Overview

CLIO implements the **Agent Client Protocol (ACP)** specification, allowing it to function as an AI coding agent that can be integrated with compatible code editors.

**Protocol Spec:** https://agentclientprotocol.com

## What is ACP?

The Agent Client Protocol standardizes communication between code editors/IDEs and AI coding agents. It enables:

- **Decoupled integration**: Editors don't need custom integration for each agent
- **Standardized communication**: JSON-RPC 2.0 over stdio
- **Rich interactions**: Streaming responses, tool calls, file operations

## Quick Start

### Running the ACP Agent

```bash
# Start CLIO as an ACP agent (reads from stdin, writes to stdout)
./clio-acp-agent

# With debug logging to stderr
./clio-acp-agent --debug
```

### Protocol Flow

```
Client (Editor)                     CLIO ACP Agent
---------------                     --------------
      |                                   |
      |  -- initialize -->                |
      |  <-- capabilities, version --     |
      |                                   |
      |  -- session/new -->               |
      |  <-- sessionId --                 |
      |                                   |
      |  -- session/prompt -->            |
      |  <-- session/update (stream) --   |
      |  <-- session/update (stream) --   |
      |  <-- prompt response --           |
      |                                   |
```

## Message Format

ACP uses **JSON-RPC 2.0** with newline-delimited messages:

### Request (Client -> Agent)
```json
{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/project"}}
```

### Response (Agent -> Client)
```json
{"jsonrpc":"2.0","id":1,"result":{"sessionId":"sess_abc123"}}
```

### Notification (Agent -> Client, no response expected)
```json
{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"sess_abc123","update":{...}}}
```

## API Reference

### Agent Methods (Client -> Agent)

#### `initialize` (Baseline)

Establish connection and negotiate capabilities.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 0,
  "method": "initialize",
  "params": {
    "protocolVersion": 1,
    "clientCapabilities": {
      "fs": { "readTextFile": true, "writeTextFile": true },
      "terminal": true
    },
    "clientInfo": {
      "name": "my-editor",
      "title": "My Code Editor",
      "version": "1.0.0"
    }
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 0,
  "result": {
    "protocolVersion": 1,
    "agentCapabilities": {
      "loadSession": true,
      "promptCapabilities": {
        "image": false,
        "audio": false,
        "embeddedContext": true
      }
    },
    "agentInfo": {
      "name": "clio",
      "title": "CLIO - Command Line Intelligence Orchestrator",
      "version": "1.0.0"
    },
    "authMethods": []
  }
}
```

#### `authenticate` (Baseline, Optional)

Authenticate with the agent if required.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "authenticate",
  "params": {}
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {}
}
```

#### `session/new` (Baseline)

Create a new conversation session.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "session/new",
  "params": {
    "cwd": "/path/to/project",
    "mcpServers": []
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "sessionId": "sess_abc123def456"
  }
}
```

#### `session/prompt` (Baseline)

Send a user message to the agent.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "session/prompt",
  "params": {
    "sessionId": "sess_abc123def456",
    "prompt": [
      { "type": "text", "text": "Please analyze this code" },
      {
        "type": "resource",
        "resource": {
          "uri": "file:///project/main.py",
          "mimeType": "text/x-python",
          "text": "def hello():\n    print('world')"
        }
      }
    ]
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 3,
  "result": {
    "stopReason": "end_turn"
  }
}
```

Stop reasons:
- `end_turn` - Agent completed its response
- `max_tokens` - Token limit reached
- `cancelled` - Client cancelled via `session/cancel`
- `refusal` - Agent refused to continue

#### `session/load` (Optional)

Resume an existing session. Requires `loadSession` capability.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "session/load",
  "params": {
    "sessionId": "sess_abc123def456",
    "cwd": "/path/to/project",
    "mcpServers": []
  }
}
```

**Response:** Agent replays conversation history via `session/update` notifications, then sends null result.

#### `session/set_mode` (Optional)

Switch between agent operating modes.

### Agent Notifications (Client -> Agent)

#### `session/cancel`

Cancel an ongoing prompt turn.

```json
{
  "jsonrpc": "2.0",
  "method": "session/cancel",
  "params": {
    "sessionId": "sess_abc123def456"
  }
}
```

### Agent Updates (Agent -> Client via `session/update`)

#### `agent_message_chunk`

Stream response text.

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "sess_abc123def456",
    "update": {
      "sessionUpdate": "agent_message_chunk",
      "content": { "type": "text", "text": "I'll analyze your code..." }
    }
  }
}
```

#### `thought_message_chunk`

Stream agent reasoning/thoughts.

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "sess_abc123def456",
    "update": {
      "sessionUpdate": "thought_message_chunk",
      "content": { "type": "text", "text": "Looking at the function structure..." }
    }
  }
}
```

#### `tool_call`

Announce start of a tool call.

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "sess_abc123def456",
    "update": {
      "sessionUpdate": "tool_call",
      "toolCallId": "call_001",
      "title": "Reading file",
      "kind": "file",
      "status": "pending"
    }
  }
}
```

#### `tool_call_update`

Update tool call status.

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "sess_abc123def456",
    "update": {
      "sessionUpdate": "tool_call_update",
      "toolCallId": "call_001",
      "status": "completed",
      "content": [{ "type": "content", "content": { "type": "text", "text": "..." }}]
    }
  }
}
```

#### `plan`

Send agent work plan.

```json
{
  "jsonrpc": "2.0",
  "method": "session/update",
  "params": {
    "sessionId": "sess_abc123def456",
    "update": {
      "sessionUpdate": "plan",
      "entries": [
        { "content": "Analyze code structure", "priority": "high", "status": "pending" },
        { "content": "Check for issues", "priority": "medium", "status": "pending" }
      ]
    }
  }
}
```

### Client Methods (Agent -> Client)

#### `session/request_permission` (Baseline)

Request user authorization for a tool call.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "method": "session/request_permission",
  "params": {
    "sessionId": "sess_abc123def456",
    "toolCallId": "call_001",
    "title": "Create file",
    "description": "Allow creating /project/new_file.txt?"
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 10,
  "result": { "permitted": true }
}
```

#### `fs/read_text_file` (Optional)

Read file contents. Requires `fs.readTextFile` client capability.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "method": "fs/read_text_file",
  "params": {
    "sessionId": "sess_abc123def456",
    "path": "/project/src/main.py",
    "line": 10,
    "limit": 50
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 11,
  "result": {
    "content": "def hello_world():\n    print('Hello, world!')\n"
  }
}
```

#### `fs/write_text_file` (Optional)

Write file contents. Requires `fs.writeTextFile` client capability.

**Request:**
```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "method": "fs/write_text_file",
  "params": {
    "sessionId": "sess_abc123def456",
    "path": "/project/config.json",
    "content": "{\n  \"debug\": true\n}"
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 12,
  "result": null
}
```

#### Terminal Methods (Optional)

All terminal methods require `terminal` client capability.

##### `terminal/create`

Create terminal and start command.

```json
{
  "jsonrpc": "2.0",
  "id": 13,
  "method": "terminal/create",
  "params": {
    "sessionId": "sess_abc123def456",
    "command": "npm",
    "args": ["test"],
    "cwd": "/project",
    "outputByteLimit": 1048576
  }
}
```

**Response:**
```json
{
  "jsonrpc": "2.0",
  "id": 13,
  "result": { "terminalId": "term_xyz789" }
}
```

##### `terminal/output`

Get current terminal output.

```json
{
  "jsonrpc": "2.0",
  "id": 14,
  "method": "terminal/output",
  "params": {
    "sessionId": "sess_abc123def456",
    "terminalId": "term_xyz789"
  }
}
```

##### `terminal/wait_for_exit`

Wait for command completion.

##### `terminal/kill`

Kill command without releasing terminal.

##### `terminal/release`

Release terminal and all resources. Agent MUST call this when done.

## Capabilities

### Agent Capabilities (CLIO supports)

| Capability | Value | Description |
|------------|-------|-------------|
| `loadSession` | `true` | Can resume previous sessions |
| `promptCapabilities.image` | `false` | No image input support (yet) |
| `promptCapabilities.audio` | `false` | No audio input support |
| `promptCapabilities.embeddedContext` | `true` | Supports embedded file resources |

### Client Capabilities (CLIO can use)

| Capability | Description |
|------------|-------------|
| `fs.readTextFile` | Agent can request file reads from client |
| `fs.writeTextFile` | Agent can request file writes via client |
| `terminal` | Agent can create/manage terminals via client |

## Implementation Coverage

CLIO implements **100% of the ACP specification**:

### Agent Methods (Baseline)
- [x] `initialize`
- [x] `authenticate`
- [x] `session/new`
- [x] `session/prompt`

### Agent Methods (Optional)
- [x] `session/load`
- [x] `session/set_mode`

### Agent Notifications
- [x] `session/cancel`

### Agent Updates (session/update)
- [x] `agent_message_chunk`
- [x] `thought_message_chunk`
- [x] `tool_call`
- [x] `tool_call_update`
- [x] `plan`

### Client Methods (Baseline)
- [x] `session/request_permission`

### Client Methods (Optional - Filesystem)
- [x] `fs/read_text_file`
- [x] `fs/write_text_file`

### Client Methods (Optional - Terminal)
- [x] `terminal/create`
- [x] `terminal/output`
- [x] `terminal/wait_for_exit`
- [x] `terminal/kill`
- [x] `terminal/release`

## Integration Example

### Python Client

```python
import subprocess
import json

# Start CLIO as subprocess
proc = subprocess.Popen(
    ['./clio-acp-agent'],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    text=True
)

def send(msg):
    proc.stdin.write(json.dumps(msg) + '\n')
    proc.stdin.flush()

def recv():
    line = proc.stdout.readline()
    return json.loads(line)

# Initialize
send({
    "jsonrpc": "2.0",
    "id": 0,
    "method": "initialize",
    "params": {
        "protocolVersion": 1,
        "clientCapabilities": {
            "fs": { "readTextFile": True, "writeTextFile": True },
            "terminal": True
        },
        "clientInfo": {"name": "test-client", "version": "1.0"}
    }
})
print(recv())  # Initialize response

# Create session
send({
    "jsonrpc": "2.0",
    "id": 1,
    "method": "session/new",
    "params": {"cwd": "/project", "mcpServers": []}
})
response = recv()
session_id = response["result"]["sessionId"]

# Send prompt
send({
    "jsonrpc": "2.0",
    "id": 2,
    "method": "session/prompt",
    "params": {
        "sessionId": session_id,
        "prompt": [{"type": "text", "text": "Hello!"}]
    }
})

# Read updates until prompt response
while True:
    msg = recv()
    if "id" in msg:  # Response to prompt
        print("Done:", msg)
        break
    else:  # Notification
        print("Update:", msg)
```

## Files

| File | Description |
|------|-------------|
| `clio-acp-agent` | Launcher script |
| `lib/CLIO/ACP/Agent.pm` | Main agent implementation |
| `lib/CLIO/ACP/JSONRPC.pm` | JSON-RPC 2.0 message handling |
| `lib/CLIO/ACP/Transport.pm` | stdio transport layer |
| `tests/acp/test_agent.pl` | Test harness (17 tests) |

## Troubleshooting

### Debug Mode

Run with `--debug` to see all messages:

```bash
./clio-acp-agent --debug 2>debug.log
```

### Common Issues

1. **"Agent not initialized"** - Call `initialize` before other methods
2. **"Session not found"** - Create session with `session/new` first
3. **Parse errors** - Ensure messages are valid JSON, newline-delimited
4. **"Client does not support X"** - Client didn't advertise required capability

## References

- [ACP Specification](https://agentclientprotocol.com)
- [JSON-RPC 2.0 Spec](https://www.jsonrpc.org/specification)
- [Zed Editor ACP Support](https://zed.dev)
