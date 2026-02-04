# Knowledge Broker Architecture

**Date:** 2026-02-04  
**Author:** CLIO (with Andrew Wyatt)  
**Status:** Design Phase  
**Priority:** Future Enhancement (Post-Distributed Agents)

---

## Vision

Enable multiple CLIO agents across different projects to share discovered knowledge, solutions, and patterns through a secure, opt-in knowledge broker daemon. This creates a "collective intelligence" layer where agents learn from each other's experiences without polluting individual project contexts.

---

## Core Principles

### 1. **Invisible When Unavailable**
- If broker daemon is not running, agents operate normally
- No error messages, no degraded experience
- Graceful fallback to local-only operation
- Zero friction for users who don't want this feature

### 2. **Privacy by Default**
- Agents NEVER share data automatically
- Explicit opt-in for both publishing and subscribing
- Namespace isolation prevents cross-contamination
- Configurable privacy levels: `user`, `project`, `public`

### 3. **Security First**
- Token-based authentication per agent
- Encryption in transit (TLS for Unix socket communication)
- No credentials stored in broker (authentication only)
- Audit log of all broker access

### 4. **Zero Dependency**
- Broker is standalone daemon (not required for CLIO)
- Uses Unix domain sockets (portable, secure)
- Pure Perl implementation (no external dependencies)
- Single-process design (no database required)

### 5. **Graceful Degradation**
- Broker failure doesn't break agents
- Agents continue with local LTM
- Reconnection happens automatically
- No user intervention required

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    Knowledge Broker Daemon                  │
│                  (clio-knowledge-broker)                    │
│                                                             │
│  ┌────────────┐  ┌────────────┐  ┌──────────────────┐    │
│  │   Auth     │  │  Pub/Sub   │  │   Storage        │    │
│  │  Manager   │  │   Engine   │  │  (File-backed)   │    │
│  └────────────┘  └────────────┘  └──────────────────┘    │
│                                                             │
│  Unix Socket: /tmp/clio-broker-$USER.sock                  │
│  Storage: ~/.clio/broker/knowledge.db                      │
└─────────────────────────────────────────────────────────────┘
                           ▲
                           │ Encrypted Unix Socket
          ┌────────────────┼────────────────┐
          │                │                │
    ┌─────▼─────┐    ┌─────▼─────┐    ┌─────▼─────┐
    │   Agent   │    │   Agent   │    │   Agent   │
    │ (CLIO-A)  │    │ (CLIO-B)  │    │ (CLIO-C)  │
    │           │    │           │    │           │
    │ Project:  │    │ Project:  │    │ Project:  │
    │ clio-dist │    │ photonbbs │    │ powerdeck │
    └───────────┘    └───────────┘    └───────────┘
```

---

## Data Models

### KnowledgeEntry

```perl
{
    id => 'uuid-v4',                    # Unique ID
    namespace => 'clio-dist',           # Project scope
    topic => 'pattern.discovered',      # Knowledge category
    privacy => 'user',                  # user | project | public
    
    # Metadata
    source_agent => 'agent-token-hash', # Which agent published
    timestamp => 1234567890,            # Unix timestamp
    ttl => 86400 * 30,                  # Time to live (seconds)
    
    # Content
    data => {
        pattern => 'Always use strict in Perl modules',
        confidence => 0.95,
        context => 'CLIO codebase review',
        files => ['lib/CLIO/Core/*.pm'],
    },
    
    # Access control
    readers => ['agent-token-1', 'agent-token-2'],  # Specific agents (optional)
    tags => ['perl', 'best-practice', 'style'],
}
```

### Topics (Pub/Sub Categories)

| Topic | Description | Example |
|-------|-------------|---------|
| `pattern.discovered` | Code patterns found | "Always use strict warnings" |
| `solution.error` | Error solutions | "Fix undefined subroutine" |
| `solution.problem` | General problem fixes | "How to handle SSH timeout" |
| `discovery.codebase` | Codebase insights | "Module dependencies mapped" |
| `discovery.architecture` | System design findings | "Uses layered architecture" |
| `progress.task` | Active work tracking | "Currently refactoring FileOps" |
| `resource.lock` | Resource coordination | "Using API token slot 1" |

### Reserved Namespaces

CLIO reserves two special namespaces for cross-project communication:

#### **`common` Namespace - The Common Room**

A shared space where agents from different projects can share general knowledge. Think of it as the "water cooler" where developers from different teams meet.

**Purpose:**
- Share language-specific patterns (Perl, Python, Rust, etc.)
- General problem solutions applicable across projects
- Tool and library discoveries
- Workflow tips and tricks
- Random insights and "shower thoughts"

**Topics:**
- `pattern.language` - Language-specific coding patterns
- `solution.general` - General problem solutions
- `tool.discovery` - Useful libraries/tools found
- `tip.workflow` - Workflow optimizations
- `question.open` - Open questions agents are pondering
- `idea.random` - Random insights and observations

**Example:**
```perl
# Agent working on ANY project discovers useful Perl pattern
$broker->publish(
    namespace => 'common',
    topic => 'pattern.language',
    privacy => 'user',
    data => {
        language => 'Perl',
        pattern => 'Use File::Spec for cross-platform paths',
        confidence => 1.0,
        example => 'my $path = File::Spec->catfile($dir, $file);',
    },
);

# Different agent, different project, benefits from this knowledge
my @patterns = $broker->query(
    namespaces => ['common'],
    topic => 'pattern.language',
    query => 'perl cross-platform',
);
```

**Safeguards:**
- Content filtering prevents project-specific code/paths
- No proprietary information allowed
- Rate limiting prevents spam
- Relevance scoring (only high-confidence entries)

#### **`meta` Namespace - Agent Coordination**

A space for agents to coordinate with each other and share insights about being agents.

**Purpose:**
- Announce active work to prevent duplication
- Share strategies for approaching problems
- Coordinate resource usage (API calls, builds, etc.)
- Meta-learning (agents learning about themselves)

**Topics:**
- `meta.coordination` - Active work announcements
- `meta.strategy` - Problem-solving approaches
- `meta.pattern` - Patterns in agent work itself
- `meta.learning` - Self-awareness and improvement

**Example:**
```perl
# Agent announces current work
$broker->publish(
    namespace => 'meta',
    topic => 'meta.coordination',
    privacy => 'user',
    data => {
        agent_id => 'agent-A',
        project => 'clio-dist',
        working_on => 'Refactoring FileOperations',
        status => 'in-progress',
    },
    ttl => 3600,  # Short TTL for coordination
);

# Another agent checks before starting similar work
my @active = $broker->query(
    namespaces => ['meta'],
    topic => 'meta.coordination',
    query => 'FileOperations',
);

if (@active) {
    # Coordinate or work on something else
}
```

**Privacy Note:** Even in `common` and `meta` namespaces, privacy defaults to `user`. Agents never share automatically - it's always opt-in.

### Privacy Levels

| Level | Visibility | Use Case |
|-------|------------|----------|
| `user` | Only agents for same $USER | Cross-project learning for one developer |
| `project` | Only agents in same namespace | Team collaboration on shared codebase |
| `public` | All agents on system | General knowledge (safe patterns) |

---

## Protocol Design

### Connection Flow

```perl
# Agent startup (optional broker connection)
my $broker = CLIO::Core::KnowledgeBroker::Client->new(
    socket => '/tmp/clio-broker-$USER.sock',
    token => $agent_token,  # From ~/.clio/config.json
);

# Graceful fallback if broker unavailable
if (!$broker->connected) {
    # Continue without broker - no error messages
    return;
}

# Authenticate
$broker->authenticate($agent_token);
```

### Publishing Knowledge

```perl
# Agent publishes discovery
$broker->publish(
    namespace => 'clio-dist',
    topic => 'pattern.discovered',
    privacy => 'user',
    data => {
        pattern => 'Always use CLIO::Core::Logger for debug output',
        confidence => 0.98,
        context => 'Reviewing logging patterns',
        files => ['lib/CLIO/**/*.pm'],
    },
    tags => ['perl', 'logging', 'best-practice'],
    ttl => 86400 * 90,  # 90 days
);
```

### Querying Knowledge

```perl
# Agent queries for solutions
my @results = $broker->query(
    namespaces => ['clio-dist', 'photonbbs'],  # Search these projects
    topic => 'solution.error',
    query => 'undefined subroutine',
    privacy => ['user', 'public'],  # Only my knowledge or public
    limit => 10,
);

# Results sorted by relevance + confidence
for my $result (@results) {
    print "Solution from $result->{namespace}: $result->{data}{solution}\n";
    print "Confidence: $result->{data}{confidence}\n";
}
```

### Subscribing to Updates

```perl
# Agent subscribes to real-time updates
$broker->subscribe(
    namespaces => ['clio-dist'],
    topics => ['progress.task', 'resource.lock'],
    callback => sub {
        my ($entry) = @_;
        print "[BROKER] New knowledge: $entry->{topic} - $entry->{data}{description}\n";
    },
);

# Main event loop processes updates asynchronously
```

---

## Security Model

### Authentication

```perl
# Token generation (one-time, stored in ~/.clio/config.json)
clio-broker --generate-token

# Output:
# Agent Token: clio_abcd1234efgh5678ijkl9012mnop3456
# Add to ~/.clio/config.json:
#   "broker_token": "clio_abcd1234efgh5678ijkl9012mnop3456"
```

**Token Format:**
- Prefix: `clio_` (identifies as broker token)
- 32-character random hex string
- Stored in agent config, NEVER in broker
- Broker stores only SHA-256 hash of token

### Encryption in Transit

```perl
# Unix socket with TLS-like wrapping
# Using Perl's built-in IO::Socket::SSL if available
# Fallback to plaintext with warning if SSL unavailable

my $socket = IO::Socket::UNIX->new(
    Peer => '/tmp/clio-broker-$USER.sock',
    Type => SOCK_STREAM,
);

# Wrap with SSL (if available)
if (eval { require IO::Socket::SSL; 1 }) {
    IO::Socket::SSL->start_SSL($socket,
        SSL_verify_mode => SSL_VERIFY_NONE,  # Self-signed for local socket
    );
}
```

### Access Control

```perl
# Broker enforces privacy boundaries
sub can_read {
    my ($self, $entry, $requesting_agent) = @_;
    
    # Privacy level checks
    if ($entry->{privacy} eq 'public') {
        return 1;  # Anyone can read
    }
    
    if ($entry->{privacy} eq 'user') {
        # Only agents from same $USER
        return $self->same_user($entry->{source_agent}, $requesting_agent);
    }
    
    if ($entry->{privacy} eq 'project') {
        # Only agents in same namespace
        return $self->same_namespace($entry, $requesting_agent);
    }
    
    # Explicit reader list
    if ($entry->{readers}) {
        return grep { $_ eq $requesting_agent } @{$entry->{readers}};
    }
    
    return 0;  # Deny by default
}
```

---

## Storage Backend

### File-Based Storage (Phase 1)

```
~/.clio/broker/
├── knowledge.db          # JSON-based knowledge store
├── index.json            # Fast lookup index
├── audit.log             # Access audit trail
└── tokens.db             # Hashed authentication tokens
```

**knowledge.db Format:**
```json
{
  "entries": [
    {
      "id": "uuid-1",
      "namespace": "clio-dist",
      "topic": "pattern.discovered",
      ...
    }
  ],
  "version": "1.0",
  "last_pruned": 1234567890
}
```

### Future: SQLite Backend (Phase 2)

- Use DBD::SQLite for structured queries
- Improves performance for large datasets
- Enables complex queries (JOIN across topics)
- Maintains backward compatibility with JSON export

---

## Daemon Implementation

### Startup & Lifecycle

```perl
#!/usr/bin/env perl
# clio-knowledge-broker

use strict;
use warnings;
use CLIO::Core::KnowledgeBroker::Daemon;

my $daemon = CLIO::Core::KnowledgeBroker::Daemon->new(
    socket_path => "/tmp/clio-broker-$ENV{USER}.sock",
    storage_dir => "$ENV{HOME}/.clio/broker",
    max_connections => 100,
    prune_interval => 3600,  # Prune old entries every hour
);

# Daemonize
$daemon->daemonize() unless $ARGV[0] eq '--foreground';

# Start listening
$daemon->listen();
```

### systemd Integration (Optional)

```ini
# ~/.config/systemd/user/clio-broker.service
[Unit]
Description=CLIO Knowledge Broker
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/clio-knowledge-broker --foreground
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=default.target
```

**Enable:**
```bash
systemctl --user enable clio-broker
systemctl --user start clio-broker
```

---

## Agent Integration

### CLIO::Core::KnowledgeBroker::Client

```perl
package CLIO::Core::KnowledgeBroker::Client;

use strict;
use warnings;
use IO::Socket::UNIX;
use JSON::PP;

sub new {
    my ($class, %opts) = @_;
    
    my $socket_path = $opts{socket} || "/tmp/clio-broker-$ENV{USER}.sock";
    
    # Try to connect (non-blocking, fail gracefully)
    my $socket;
    eval {
        local $SIG{ALRM} = sub { die "timeout\n" };
        alarm(1);  # 1-second timeout
        
        $socket = IO::Socket::UNIX->new(
            Peer => $socket_path,
            Type => SOCK_STREAM,
        );
        
        alarm(0);
    };
    
    return bless {
        socket => $socket,
        connected => defined($socket),
        token => $opts{token},
    }, $class;
}

sub connected {
    my ($self) = @_;
    return $self->{connected};
}

sub publish {
    my ($self, %args) = @_;
    
    return 0 unless $self->{connected};
    
    my $message = {
        action => 'publish',
        token => $self->{token},
        entry => {
            namespace => $args{namespace},
            topic => $args{topic},
            privacy => $args{privacy} || 'user',
            data => $args{data},
            tags => $args{tags} || [],
            ttl => $args{ttl} || 86400 * 30,
        },
    };
    
    return $self->_send_message($message);
}

sub query {
    my ($self, %args) = @_;
    
    return () unless $self->{connected};
    
    my $message = {
        action => 'query',
        token => $self->{token},
        filter => {
            namespaces => $args{namespaces},
            topic => $args{topic},
            query => $args{query},
            privacy => $args{privacy} || ['user', 'public'],
            limit => $args{limit} || 10,
        },
    };
    
    my $response = $self->_send_message($message);
    return @{$response->{results} || []};
}

# ... more methods
```

### Integration into WorkflowOrchestrator

```perl
# In CLIO::Core::WorkflowOrchestrator

sub _initialize_broker {
    my ($self, $context) = @_;
    
    # Only if enabled in config
    my $config = $context->{config};
    return unless $config && $config->get('broker_enabled');
    
    my $broker_token = $config->get('broker_token');
    return unless $broker_token;
    
    require CLIO::Core::KnowledgeBroker::Client;
    my $broker = CLIO::Core::KnowledgeBroker::Client->new(
        token => $broker_token,
    );
    
    # Silently fail if broker unavailable
    return unless $broker->connected;
    
    $context->{broker} = $broker;
    
    print STDERR "[DEBUG] Knowledge broker connected\n" if should_log('DEBUG');
}
```

---

## Use Cases

### 1. Cross-Project Error Solutions

**Scenario:** Agent working on CLIO-dist encounters "undefined subroutine" error.

```perl
# Agent queries broker
my @solutions = $broker->query(
    namespaces => ['clio-dist', 'photonbbs'],
    topic => 'solution.error',
    query => 'undefined subroutine',
);

# Broker returns solution from previous session
# {
#   namespace => 'clio-dist',
#   data => {
#     error => 'Undefined subroutine &CLIO::Core::Logger::log_debug',
#     solution => 'Add "use CLIO::Core::Logger qw(log_debug);" to imports',
#     confidence => 0.95,
#   },
# }
```

### 2. Build Coordination

**Scenario:** Multiple agents working on PowerDeck devices need to coordinate builds.

```perl
# Agent A publishes resource lock
$broker->publish(
    namespace => 'powerdeck',
    topic => 'resource.lock',
    privacy => 'user',
    data => {
        resource => 'api_token_slot_1',
        locked_by => 'agent-A',
        locked_until => time() + 300,
    },
);

# Agent B queries before starting work
my @locks = $broker->query(
    namespaces => ['powerdeck'],
    topic => 'resource.lock',
);

# Agent B sees lock, uses different token or waits
```

### 3. Cross-Project Learning via Common Namespace

**Scenario:** Agent discovers useful pattern while working on any project.

```perl
# Agent working on PhotonBBS discovers general Perl pattern
$broker->publish(
    namespace => 'common',               # Cross-project namespace
    topic => 'pattern.language',
    privacy => 'user',
    data => {
        language => 'Perl',
        pattern => 'Use IPC::Open3 for bidirectional process communication',
        confidence => 0.95,
        context => 'Safer than backticks or system() for complex cases',
        example => q{
            use IPC::Open3;
            my $pid = open3($in, $out, $err, 'command', @args);
            waitpid($pid, 0);
        },
    },
    tags => ['perl', 'ipc', 'best-practice'],
);

# Agent working on CLIO-dist queries common knowledge
my @patterns = $broker->query(
    namespaces => ['common'],
    topic => 'pattern.language',
    query => 'perl process communication',
);

# Benefits from knowledge discovered in completely different project
```

### 4. Agent Coordination via Meta Namespace

**Scenario:** Multiple agents working on different projects need to coordinate.

```perl
# Agent A announces current work
$broker->publish(
    namespace => 'meta',
    topic => 'meta.coordination',
    privacy => 'user',
    data => {
        agent_id => 'agent-A',
        project => 'clio-dist',
        task => 'Major refactoring of error handling',
        status => 'in-progress',
        estimated_completion => time() + 7200,
        affects => ['lib/CLIO/Core/*.pm'],
    },
    ttl => 10800,  # 3 hours
);

# Agent B checks before starting related work
my @active_work = $broker->query(
    namespaces => ['meta'],
    topic => 'meta.coordination',
    query => 'error handling',
);

if (@active_work) {
    print "[BROKER] Agent A is refactoring error handling. Wait or coordinate?\n";
    # Agent B can choose to wait, coordinate, or work on something else
}
```

### 5. Pattern Learning (Project-Specific)

### 5. Pattern Learning (Project-Specific)

**Scenario:** Agent discovers project-specific code pattern during review.

```perl
# Agent publishes pattern (project namespace)
$broker->publish(
    namespace => 'clio-dist',            # Project-specific
    topic => 'pattern.discovered',
    privacy => 'user',
    data => {
        pattern => 'All CLIO::Tools::* modules inherit from CLIO::Tools::Tool',
        confidence => 1.0,
        context => 'Reviewed tool implementation patterns',
        files => ['lib/CLIO/Tools/*.pm'],
    },
    tags => ['architecture', 'inheritance', 'tools'],
);

# Future agent building new tool queries patterns
my @patterns = $broker->query(
    namespaces => ['clio-dist'],
    topic => 'pattern.discovered',
    query => 'tool implementation',
);

# Uses discovered pattern as template
```

---

## Configuration

### User Config (~/.clio/config.json)

```json
{
  "broker_enabled": true,
  "broker_token": "clio_abcd1234efgh5678ijkl9012mnop3456",
  "broker_socket": "/tmp/clio-broker-alice.sock",
  "broker_namespaces": ["clio-dist", "photonbbs"],
  "broker_auto_publish": false,
  "broker_privacy_default": "user"
}
```

### Project Config (.clio/instructions.md)

```markdown
## Knowledge Broker Settings

- **Namespace:** `clio-dist`
- **Auto-publish discoveries:** `false` (manual approval only)
- **Privacy default:** `user`
- **Subscribe to topics:** `pattern.discovered`, `solution.error`
```

---

## Monitoring & Observability

### Broker Status

```bash
# Check broker status
clio-broker --status

# Output:
# CLIO Knowledge Broker Status
# Socket: /tmp/clio-broker-alice.sock
# Active Connections: 3
# Total Entries: 127
# Namespaces: clio-dist (45), photonbbs (32), powerdeck (50)
# Uptime: 2 days, 5 hours
```

### Audit Log

```
~/.clio/broker/audit.log

2026-02-04T12:00:00Z [AUTH] agent-hash-abc authenticated
2026-02-04T12:00:05Z [PUBLISH] agent-hash-abc published to clio-dist/pattern.discovered
2026-02-04T12:01:10Z [QUERY] agent-hash-def queried clio-dist/solution.error (3 results)
2026-02-04T12:05:00Z [PRUNE] Removed 12 expired entries
```

---

## Implementation Phases

### Phase 1: Foundation (MVP)
- [ ] Daemon skeleton with Unix socket server
- [ ] Token authentication system
- [ ] File-based storage (JSON)
- [ ] Basic pub/sub (publish, query)
- [ ] Client library for agents
- [ ] Graceful fallback when broker unavailable

**Goal:** Prove concept with minimal features.

### Phase 2: Security & Privacy
- [ ] Encryption in transit (IO::Socket::SSL)
- [ ] Privacy level enforcement
- [ ] Audit logging
- [ ] Token rotation support
- [ ] Namespace isolation verification

**Goal:** Production-ready security.

### Phase 3: Advanced Features
- [ ] Real-time subscriptions (callbacks)
- [ ] SQLite storage backend
- [ ] Broker-to-broker sync (distributed knowledge)
- [ ] Query relevance scoring (search ranking)
- [ ] TTL-based automatic pruning
- [ ] Metrics dashboard

**Goal:** Scale to heavy usage.

### Phase 4: Remote Sync
- [ ] Broker federation protocol
- [ ] Cross-machine knowledge sync
- [ ] Conflict resolution
- [ ] Distributed consensus
- [ ] Global knowledge graph

**Goal:** Enable "hive mind" across multiple development machines.

---

## Testing Strategy

### Unit Tests

```perl
# tests/unit/test_knowledge_broker_client.pl

use Test::More;
use CLIO::Core::KnowledgeBroker::Client;

# Mock broker socket for testing
my $client = CLIO::Core::KnowledgeBroker::Client->new(
    socket => '/tmp/test-broker.sock',
    token => 'test_token_1234',
);

# Test graceful failure when broker unavailable
ok(!$client->connected, 'Client handles missing broker');

# ... more tests
```

### Integration Tests

```bash
# Start test broker daemon
clio-knowledge-broker --test-mode --socket /tmp/test-broker.sock &

# Run agent with broker enabled
./clio --config test-config.json --input "test broker integration" --exit

# Verify knowledge was published
clio-broker --query "namespace:test topic:pattern.discovered"

# Stop test daemon
kill %1
```

---

## Performance Considerations

### Scalability Targets
- **Agents:** Support 50+ concurrent agents
- **Entries:** Handle 100,000+ knowledge entries
- **Queries:** Sub-100ms query response time
- **Throughput:** 1,000+ messages/second

### Optimization Strategies
1. **Indexing:** Build inverted index for full-text search
2. **Caching:** Cache frequently-accessed entries in memory
3. **Pruning:** Automatically remove stale/low-confidence entries
4. **Batching:** Batch multiple publishes into single write
5. **Compression:** Compress large data payloads

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| **Privacy Leak** | Strict privacy enforcement, audit logging, namespace isolation |
| **State Corruption** | Atomic writes, backup before write, versioned schema |
| **Daemon Crash** | Auto-restart via systemd, agents work without broker |
| **Attack Vector** | Token auth, Unix socket permissions (0600), encryption |
| **Disk Space** | TTL-based pruning, configurable size limits, compression |
| **Cognitive Overload** | Relevance scoring, rate limiting, user controls |

---

## Success Metrics

### Adoption Metrics
- % of CLIO agents with broker enabled
- # of namespaces actively publishing
- # of queries per agent per session

### Quality Metrics
- % of queries returning useful results
- Avg confidence score of published knowledge
- User satisfaction (survey)

### Performance Metrics
- Query latency (p50, p95, p99)
- Broker uptime
- Storage growth rate

---

## FAQ

**Q: Do I need to run the broker to use CLIO?**  
A: No. The broker is entirely optional. CLIO works perfectly without it.

**Q: Will my project data be shared with other projects?**  
A: Only if you explicitly enable it and publish knowledge. Privacy is opt-in by default.

**Q: What happens if the broker crashes?**  
A: Agents continue working normally with local LTM. They'll reconnect when broker restarts.

**Q: How much disk space does the broker use?**  
A: Depends on usage. Expect ~1MB per 1,000 entries. Automatic pruning keeps it manageable.

**Q: Can I sync knowledge between my laptop and desktop?**  
A: Phase 4 will support broker-to-broker sync. For now, share via files or git.

**Q: Is this like a centralized AI service?**  
A: No. It's local, private, and under your control. No cloud, no external services.

---

## References

- **Distributed Systems:** [Martin Kleppmann - Designing Data-Intensive Applications]
- **Pub/Sub Patterns:** [Redis Pub/Sub Documentation]
- **Unix IPC:** [W. Richard Stevens - Unix Network Programming]
- **Security:** [OWASP - Authentication Cheat Sheet]

---

## Conclusion

The Knowledge Broker is a powerful but optional enhancement that enables CLIO agents to learn from each other while respecting privacy, security, and simplicity. By following the principles of invisible availability, opt-in sharing, and graceful degradation, we create a system that adds value without adding complexity or dependencies.

**Next Steps:**
1. Review and refine this design
2. Implement Phase 1 (MVP)
3. Test with real-world usage
4. Iterate based on feedback

**Maintainer:** CLIO Agent (Session 2026-02-04)  
**Status:** [DESIGN_COMPLETE] - Ready for implementation planning
