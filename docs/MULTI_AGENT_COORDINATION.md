# Multi-Agent Coordination System

## Overview

CLIO's multi-agent coordination system allows multiple independent CLIO processes to work in parallel on the same codebase without conflicts.

## Architecture

```
Main CLIO Process (Manager)
    |
    +-- Coordination Broker (background daemon)
    |   - Unix socket: /dev/shm/clio/broker-SESSION_ID.sock
    |   - Manages file locks, git locks, knowledge sharing
    |
    +-- Sub-Agent 1 (forked CLIO process)
    |   - Connects to broker
    |   - Works on Task A
    |   - Shares discoveries/warnings
    |
    +-- Sub-Agent 2 (forked CLIO process)
    |   - Connects to broker
    |   - Works on Task B
    |   - Coordinates with Agent 1
    |
    +-- Sub-Agent 3 (forked CLIO process)
        - Connects to broker
        - Works on Task C
```

## Components

### 1. Coordination Broker (`lib/CLIO/Coordination/Broker.pm`)

**Purpose:** Central coordination server using Unix domain sockets.

**Features:**
- File locking (prevent concurrent edits)
- Git locking (serialize commits)
- Agent registration and tracking
- Knowledge sharing (discoveries/warnings)
- Automatic cleanup on agent disconnect

**Message Protocol:** Newline-delimited JSON over Unix socket

**Key Methods:**
```perl
$broker = CLIO::Coordination::Broker->new(session_id => $id);
$broker->run();  # Starts event loop
```

### 2. Client Library (`lib/CLIO/Coordination/Client.pm`)

**Purpose:** Simple API for agents to connect and coordinate.

**Key Methods:**
```perl
# Connect to broker
$client = CLIO::Coordination::Client->new(
    session_id => $session_id,
    agent_id => 'agent-1',
    task => 'Fix bug in Module::A',
);

# File locking
$client->request_file_lock(['lib/Module.pm']);
$client->release_file_lock(['lib/Module.pm']);

# Git locking
$client->request_git_lock();
$client->release_git_lock();

# Knowledge sharing
$client->send_discovery("Pattern: All configs use Config::IniFiles", "pattern");
$client->send_warning("Don't edit lib/Core/API.pm", "high");
$discoveries = $client->get_discoveries();
$warnings = $client->get_warnings();

# Status
$status = $client->get_status();
```

### 3. Sub-Agent Manager (`lib/CLIO/Coordination/SubAgent.pm`)

**Purpose:** Spawn and manage multiple sub-agents.

**Key Methods:**
```perl
# Create manager
$manager = CLIO::Coordination::SubAgent->new(session_id => $id);

# Spawn agents
$agent_id = $manager->spawn_agent("Fix bug in Module::A");

# Monitor
$agents = $manager->list_agents();

# Control
$manager->kill_agent($agent_id);
$manager->wait_all();
```

## Usage Examples

### Example 1: Simple File Locking

```perl
use CLIO::Coordination::Client;

my $client = CLIO::Coordination::Client->new(
    session_id => $session_id,
    agent_id => 'agent-1',
    task => 'Edit Module.pm',
);

if ($client->request_file_lock(['lib/Module.pm'])) {
    # Edit file
    # ...
    $client->release_file_lock(['lib/Module.pm']);
}
```

### Example 2: Knowledge Sharing

```perl
# Agent 1 discovers something
$agent1->send_discovery("All tests use Test::More", "pattern");

# Agent 2 retrieves and uses it
my $discoveries = $agent2->get_discoveries();
for my $d (@$discoveries) {
    print "[$d->{agent}] $d->{content}\n";
}
```

### Example 3: Multi-Agent Workflow

```perl
# Start broker
my $broker_pid = fork();
if ($broker_pid == 0) {
    my $broker = CLIO::Coordination::Broker->new(session_id => $id);
    $broker->run();
    exit 0;
}

# Create manager
my $manager = CLIO::Coordination::SubAgent->new(session_id => $id);

# Spawn agents for parallel work
$manager->spawn_agent("Analyze lib/CLIO/Core/");
$manager->spawn_agent("Fix bugs in tests/");
$manager->spawn_agent("Update documentation");

# Wait for completion
$manager->wait_all();
```

## Testing

### Run Integration Tests
```bash
perl tests/integration/test_multi_agent_coordination.pl
```

**Tests:**
1. Single agent file locking
2. Two agents competing for same file
3. Git lock coordination
4. Status queries
5. Knowledge sharing

### Run Demo
```bash
perl tests/integration/demo_multi_agent_system.pl
```

Shows complete system with broker, manager, and 3 concurrent sub-agents.

## Implementation Details

### Unix Socket Location

- **Linux:** `/dev/shm/clio/broker-SESSION_ID.sock`
- **macOS:** `/tmp/clio/broker-SESSION_ID.sock`

### Message Format

All messages are newline-delimited JSON:

```json
{"type": "register", "id": "agent-1", "task": "Fix bug"}
{"type": "request_file_lock", "files": ["lib/Module.pm"], "mode": "write"}
{"type": "lock_granted", "files": ["lib/Module.pm"], "lock_id": 1}
{"type": "discovery", "content": "Pattern found", "category": "pattern"}
```

### Error Handling

- Broker wraps event loop in eval (continues on errors)
- Client timeouts prevent hanging on broker death
- Signal handlers (SIGPIPE, SIGCHLD) for robustness
- Automatic lock release on disconnect

### Dependencies

**100% Perl native** - no external CPAN modules:
- `IO::Socket::UNIX` - Unix domain sockets
- `IO::Select` - Non-blocking I/O
- `JSON::PP` - JSON encoding
- `Time::HiRes` - High-resolution timestamps
- `POSIX` - Process control

## Future Enhancements

### Planned for Main CLIO Integration:

1. **Manager Commands:**
   - `/spawn "task"` - Spawn sub-agent
   - `/agents` - List active agents
   - `/kill agent-id` - Terminate agent
   - `/locks` - Show current locks

2. **UI Integration:**
   - Real-time agent status in sidebar
   - Discovery/warning notifications
   - Progress indicators

3. **WorkflowOrchestrator Integration:**
   - Sub-agents run actual CLIO workflows
   - Inherit parent session/config
   - Results aggregated to parent

## Performance

- **Socket I/O:** <1ms latency (shared memory)
- **Lock requests:** <5ms (no blocking)
- **Broker overhead:** Minimal (<1% CPU)
- **Scalability:** Tested with 10 concurrent agents

## Security

- Unix sockets (local-only, no network exposure)
- File permissions (0777 - writable by same user)
- Process isolation (fork-based agents)
- No sensitive data in messages

## Troubleshooting

### Broker not starting
```bash
# Check if socket exists
ls -la /dev/shm/clio/  # or /tmp/clio on macOS

# Check broker log
tail -f /tmp/clio-broker-test.log
```

### Agent can't connect
```bash
# Verify broker is running
ps aux | grep broker

# Check socket permissions
ls -la /dev/shm/clio/broker-*.sock
```

### Lock not released
- Automatic on disconnect (agent crash)
- Timeout after 120 seconds (configurable)

## References

- **PhotonMUD Broker:** Proven architecture this is based on
- **SAM Sub-agents:** Session continuity pattern
- **VS Code LSP:** Inspiration for message protocol

## Authors

Fewtarius

## License

GPL-3.0 (see main CLIO LICENSE)
