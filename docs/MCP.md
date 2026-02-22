# MCP (Model Context Protocol) Support

**Version:** 1.0  
**Last Updated:** 2026-02-22

---

## Overview

CLIO supports the [Model Context Protocol](https://modelcontextprotocol.io) (MCP),
an open standard that lets AI applications connect to external tool servers. With MCP,
you can extend CLIO's capabilities by connecting to third-party tools - databases,
APIs, file systems, and more - without modifying CLIO itself.

MCP servers provide tools that the AI can discover and call just like CLIO's built-in
tools. The protocol uses JSON-RPC 2.0 over stdio for communication.

---

## Requirements

MCP servers are typically distributed as npm packages or Python packages. You need
**at least one** of the following runtimes installed:

| Runtime | Used For | Install |
|---------|----------|---------|
| `npx` (Node.js) | npm-based MCP servers | `brew install node` / `apt install nodejs npm` |
| `node` | Local JS MCP servers | Comes with Node.js |
| `uvx` | Python MCP servers (uv) | `pip install uv` |
| `python3` | Python MCP servers | Usually pre-installed |

If no compatible runtime is found, MCP is **silently disabled** and CLIO works
normally without it.

---

## Configuration

MCP servers are configured in `~/.clio/config.json` under the `mcp` key:

```json
{
  "mcp": {
    "filesystem": {
      "command": ["npx", "-y", "@modelcontextprotocol/server-filesystem", "/path/to/dir"],
      "enabled": true
    },
    "sqlite": {
      "command": ["npx", "-y", "@modelcontextprotocol/server-sqlite", "path/to/database.db"],
      "enabled": true
    },
    "memory": {
      "command": ["npx", "-y", "@modelcontextprotocol/server-memory"],
      "enabled": true
    }
  }
}
```

### Server Config Options

| Key | Type | Description |
|-----|------|-------------|
| `command` | Array | Command and arguments to launch the MCP server |
| `enabled` | Boolean | Set to `false` to disable without removing config |
| `environment` | Object | Extra environment variables for the server process |
| `timeout` | Number | Connection/request timeout in seconds (default: 30) |

### Example: Custom Environment

```json
{
  "mcp": {
    "github": {
      "command": ["npx", "-y", "@modelcontextprotocol/server-github"],
      "environment": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "ghp_xxxxx"
      }
    }
  }
}
```

---

## Commands

### `/mcp` or `/mcp status`

Show connection status of all configured MCP servers:

```
✓ filesystem (MCP Filesystem Server) - 11 tool(s)
✗ broken-server (failed: Connection refused)
− disabled-server (disabled)
```

### `/mcp list`

List all tools from all connected MCP servers:

```
MCP Tools (14 total):

  [filesystem]
    mcp_filesystem_read_file: Read the complete contents of a file...
    mcp_filesystem_write_file: Create a new file or overwrite...
    mcp_filesystem_list_directory: Get a detailed listing...
    ...

  [sqlite]
    mcp_sqlite_read_query: Execute a SELECT query...
    mcp_sqlite_write_query: Execute an INSERT, UPDATE, or DELETE...
    mcp_sqlite_list_tables: List all tables in the database
```

### `/mcp add <name> <command...>`

Add and connect to a new MCP server:

```
/mcp add filesystem npx -y @modelcontextprotocol/server-filesystem /tmp
```

This also saves the server to your config for persistence across sessions.

### `/mcp remove <name>`

Disconnect and remove an MCP server:

```
/mcp remove filesystem
```

---

## How It Works

1. **Startup:** CLIO reads MCP config and spawns each enabled server as a subprocess
2. **Handshake:** Sends `initialize` request (MCP 2025-11-25 protocol), receives capabilities
3. **Discovery:** Calls `tools/list` to discover what tools the server provides
4. **Registration:** Each MCP tool is registered as a CLIO tool with the `mcp_` prefix
5. **Execution:** When the AI calls an MCP tool, CLIO sends `tools/call` via JSON-RPC
6. **Shutdown:** On exit, CLIO closes stdin to each server and waits for clean exit

### Tool Naming

MCP tools are namespaced to prevent collisions:

```
mcp_<servername>_<toolname>
```

For example, a `read_file` tool from the `filesystem` server becomes:
`mcp_filesystem_read_file`

The AI sees these as regular tools and can call them alongside built-in tools.

---

## Popular MCP Servers

| Server | Package | Description |
|--------|---------|-------------|
| Filesystem | `@modelcontextprotocol/server-filesystem` | Read/write files in specified directories |
| SQLite | `@modelcontextprotocol/server-sqlite` | Query SQLite databases |
| PostgreSQL | `@modelcontextprotocol/server-postgres` | Query PostgreSQL databases |
| Memory | `@modelcontextprotocol/server-memory` | Knowledge graph memory |
| GitHub | `@modelcontextprotocol/server-github` | GitHub API operations |
| Git | `@modelcontextprotocol/server-git` | Git repository operations |
| Fetch | `@modelcontextprotocol/server-fetch` | HTTP fetch with readability |
| Puppeteer | `@modelcontextprotocol/server-puppeteer` | Browser automation |
| Brave Search | `@modelcontextprotocol/server-brave-search` | Web search via Brave |

Browse more at: [github.com/modelcontextprotocol/servers](https://github.com/modelcontextprotocol/servers)

---

## Troubleshooting

### "MCP not initialized"

MCP couldn't find any compatible runtime (npx, node, uvx, python). Install Node.js:

```bash
brew install node          # macOS
sudo apt install nodejs npm  # Debian/Ubuntu
```

### Server shows "failed" status

Run the server command manually to check for errors:

```bash
npx -y @modelcontextprotocol/server-filesystem /tmp
```

Common issues:
- Package not found (check spelling)
- Missing API keys (check environment config)
- Permission denied (check file/directory permissions)

### Server connects but tools don't work

Enable debug mode to see MCP JSON-RPC traffic:

```bash
./clio --debug --new
/mcp status
```

Debug output shows all JSON-RPC messages between CLIO and the MCP server.

---

## Limitations (v1)

- **Stdio transport only** - HTTP/SSE transport not yet supported
- **No MCP resources** - Only tools are bridged (resources and prompts planned)
- **No OAuth** - Remote MCP servers requiring OAuth not yet supported
- **No sampling** - Server-initiated LLM requests not supported
- **No progress notifications** - Long-running tools show no progress

These will be addressed in future versions.

---

## Protocol Reference

CLIO implements the MCP 2025-11-25 specification:
- [Specification](https://modelcontextprotocol.io/specification/2025-11-25)
- [Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
- [Transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [Lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
