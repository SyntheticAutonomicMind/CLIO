# CLIO Developer Guide

**Complete guide to extending and contributing to CLIO**

---------------------------------------------------

## Table of Contents

1. [Introduction](#introduction)
2. [Architecture Overview](#architecture-overview)
3. [Code Organization](#code-organization)
4. [Development Setup](#development-setup)
5. [Adding New Tools](#adding-new-tools)
6. [Adding New Protocols](#adding-new-protocols)
7. [Adding New AI Providers](#adding-new-ai-providers)
8. [Testing](#testing)
9. [Code Standards](#code-standards)
10. [Contribution Workflow](#contribution-workflow)

---------------------------------------------------

## Introduction

### Welcome!

CLIO is built with extensibility in mind. Whether you want to add new tools, integrate additional AI providers, or enhance existing features, this guide will help you contribute effectively.

### Prerequisites

Before contributing, you should be familiar with:

- **Perl**: Object-oriented Perl, modules, references
- **Terminal UI**: ANSI escape codes, terminal interaction
- **AI APIs**: REST APIs, JSON, streaming responses
- **Git**: Branching, commits, pull requests

### Development Philosophy

CLIO follows these principles:

1. **No CPAN Dependencies**: Use core Perl modules only
2. **Tool-Powered**: AI interacts through well-defined tools
3. **Action Transparency**: Every operation shows what it's doing
4. **Session Persistence**: State survives across restarts
5. **Professional UX**: Terminal UI should be polished and usable

---------------------------------------------------

## Architecture Overview

### High-Level Design

```mermaid
flowchart TD
    UI[User Interface<br/>SimpleChat, Markdown, ANSI]
    Agent[Core AI Agent<br/>SimpleAIAgent, APIManager]
    Registry[Tool Registry<br/>Tool Executor]
    Session[Session Manager<br/>Persistence]
    Tools[Tools Layer<br/>FileOps | VersionControl | Terminal | Memory | etc.]
    
    UI --> Agent
    Agent --> Registry
    Agent --> Session
    Registry --> Tools
    
    style UI fill:#e1f5ff
    style Agent fill:#fff4e1
    style Registry fill:#e8f5e9
    style Session fill:#e8f5e9
    style Tools fill:#f3e5f5
```

### Core Components

**1. SimpleAIAgent** (`lib/CLIO/Core/SimpleAIAgent.pm`)
- Manages conversation flow
- Orchestrates tool execution
- Handles streaming responses
- Coordinates with API manager

**2. APIManager** (`lib/CLIO/Core/APIManager.pm`)
- Abstracts AI provider APIs
- Handles authentication
- Manages streaming responses
- Error handling and retries

**3. Tool Registry** (`lib/CLIO/Tools/Registry.pm`)
- Registers all available tools
- Routes operations to appropriate tools
- Manages tool definitions for AI

**4. Session Manager** (`lib/CLIO/Session/*.pm`)
- Persists conversation history
- Manages session state
- Handles session resumption

**5. UI Components** (`lib/CLIO/UI/*.pm`)
- SimpleChat: Chat interface
- Markdown: Markdown rendering
- ANSI: ANSI escape code management
- Theme: Color schemes and templates

### Data Flow

**User Input Flow:**
```
User Input → SimpleChat → SimpleAIAgent → APIManager → AI Provider
                                     ↓
                              Tool Selection
                                     ↓
                             Tool Execution
                                     ↓
                            Result Collection
                                     ↓
                          AI Response Generation
                                     ↓
                            Markdown Rendering
                                     ↓
                              User Output
```

**Tool Execution Flow:**
```
AI Request → Tool Registry → Route to Tool → Execute Operation
                                                    ↓
                                              Return Result
                                                    ↓
                                           Action Description
                                                    ↓
                                            Back to AI Agent
```

---------------------------------------------------

## Code Organization

### Directory Structure

```
clio/
  clio                      # Main executable
  install.sh / uninstall.sh # Installation scripts
  lib/CLIO/                 # Core library
      Core/                 # Core components
          SimpleAIAgent.pm  # AI agent
          APIManager.pm     # API abstraction
          Logger.pm         # Logging utilities
      Tools/                # Tool implementations
          Tool.pm           # Base tool class
          Registry.pm       # Tool registry
          FileOperations.pm # File tools
          VersionControl.pm # Git tools
          TerminalOperations.pm
          MemoryOperations.pm
          TodoList.pm
          WebOperations.pm
      UI/                   # User interface
          Chat.pm           # Chat interface (deprecated)
          SimpleChat.pm     # Current chat (deprecated)
          Markdown.pm       # Markdown renderer
          ANSI.pm           # ANSI codes
          Theme.pm          # Theming system
      Session/              # Session management
          Manager.pm        # Session manager
          TodoStore.pm      # Todo persistence
  docs/                     # User documentation
      USER_GUIDE.md
      INSTALLATION.md
      SPECS/
          ARCHITECTURE.md
          TOOLS.md
          PROTOCOLS.md
  docs-internal/            # Development specs
  sessions/                 # Saved sessions
  scripts/                  # Utility scripts
```

### Module Naming Conventions

- **Core modules**: `CLIO::Core::*` - System components
- **Tools**: `CLIO::Tools::*` - Tool implementations
- **UI**: `CLIO::UI::*` - User interface components
- **Session**: `CLIO::Session::*` - Session management

### File Naming

- Perl modules: `CamelCase.pm` (e.g., `FileOperations.pm`)
- Scripts: `lowercase_underscore.sh`
- Documentation: `UPPERCASE.md` or `CamelCase.md`

---------------------------------------------------

## Development Setup

### Clone and Install

```bash
# Clone repository
git clone https://github.com/fewtarius/clio.git
cd clio

# Install for development (user mode, no sudo)
./install.sh --user

# Or install system-wide
sudo ./install.sh
```

### Running from Source

**Without installing:**

```bash
# Run directly from source
perl -I lib clio --new

# With debug output
perl -I lib clio --debug --new
```

**With installed version:**

```bash
clio --debug
```

### Development Tools

**Syntax checking:**

```bash
# Check specific module
perl -I lib -c lib/CLIO/Tools/MyNewTool.pm

# Check all modules
find lib -name "*.pm" -exec perl -I lib -c {} \;
```

**Testing:**

```bash
# Run test suite (when implemented)
prove -I lib t/

# Manual testing
./clio --new
```

---------------------------------------------------

## Adding New Tools

### Tool Structure

Every tool inherits from `CLIO::Tools::Tool` and implements a standard interface.

### Step-by-Step: Create a New Tool

**1. Create the Tool Module**

Create `lib/CLIO/Tools/MyNewTool.pm`:

```perl
package CLIO::Tools::MyNewTool;

use strict;
use warnings;
use feature 'say';
use parent 'CLIO::Tools::Tool';

=head1 NAME

CLIO::Tools::MyNewTool - Brief description

=head1 DESCRIPTION

Detailed description of what this tool does and when to use it.

=cut

sub new {
    my ($class, %opts) = @_;
    
    return $class->SUPER::new(
        name => 'my_new_tool',
        description => 'What this tool does and when to use it',
        supported_operations => [qw(operation1 operation2)],
        debug => $opts{debug} || 0,
    );
}

sub route_operation {
    my ($self, $operation, $params, $context) = @_;
    
    if ($operation eq 'operation1') {
        return $self->handle_operation1($params, $context);
    }
    elsif ($operation eq 'operation2') {
        return $self->handle_operation2($params, $context);
    }
    else {
        return $self->operation_error("Unknown operation: $operation");
    }
}

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        param1 => {
            type => "string",
            description => "Description of parameter 1",
        },
        param2 => {
            type => "integer",
            description => "Description of parameter 2",
        },
    };
}

sub handle_operation1 {
    my ($self, $params, $context) = @_;
    
    # Extract parameters
    my $param1 = $params->{param1};
    
    # Validate
    unless ($param1) {
        return $self->operation_error("Missing required parameter: param1");
    }
    
    # Set action description (CRITICAL for UX)
    $self->set_action_description("Brief description of what this operation is doing");
    
    # Do the work
    my $result = "Result of operation1";
    
    # Return success
    return $self->operation_success($result);
}

sub handle_operation2 {
    my ($self, $params, $context) = @_;
    
    # Similar structure...
    $self->set_action_description("Operation 2 description");
    
    my $result = "Result of operation2";
    return $self->operation_success($result);
}

1;  # End of module MUST return true
```

**2. Register the Tool**

Edit `lib/CLIO/Tools/Registry.pm`:

```perl
use CLIO::Tools::MyNewTool;

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        tools => {},
        debug => $opts{debug} || 0,
    };
    bless $self, $class;
    
    # Register existing tools...
    $self->register_tool(CLIO::Tools::FileOperations->new(debug => $self->{debug}));
    $self->register_tool(CLIO::Tools::VersionControl->new(debug => $self->{debug}));
    # ... other tools ...
    
    # Register your new tool
    $self->register_tool(CLIO::Tools::MyNewTool->new(debug => $self->{debug}));
    
    return $self;
}
```

**3. Test Your Tool**

```bash
# Syntax check
perl -I lib -c lib/CLIO/Tools/MyNewTool.pm

# Test in CLIO
./clio --new

# In conversation:
YOU: Use my_new_tool with operation1 and param1="test value"
```

### Tool Best Practices

**Action Descriptions:**

Always set clear action descriptions:

```perl
$self->set_action_description("reading ./config.yaml (45 lines)");
$self->set_action_description("executing git status in ./");
$self->set_action_description("searching ./lib for pattern 'TODO'");
```

Format: `<verb>ing <target> (<additional context>)`

**Error Handling:**

```perl
eval {
    # Operation that might fail
};
if ($@) {
    my $error = $@;
    print STDERR "[ERROR][MyNewTool] $error\n";
    return $self->operation_error($error);
}
```

**Parameter Validation:**

```perl
# Check required parameters
unless ($params->{required_param}) {
    return $self->operation_error("Missing required parameter: required_param");
}

# Validate types
unless ($params->{count} =~ /^\d+$/) {
    return $self->operation_error("Parameter 'count' must be an integer");
}

# Validate paths (for file operations)
use File::Spec;
my $safe_path = File::Spec->canonpath($params->{path});
```

**Return Values:**

```perl
# Success with result
return $self->operation_success($result_data);

# Success with message
return $self->operation_success($result_data, "Custom success message");

# Error
return $self->operation_error("Error message explaining what went wrong");
```

---------------------------------------------------

## Adding New Protocols

### Protocol Pattern

Protocols are a higher-level abstraction over tools, providing semantic grouping of related operations.

**Example: Database Protocol**

Create `lib/CLIO/Protocols/Database.pm`:

```perl
package CLIO::Protocols::Database;

use strict;
use warnings;
use DBI;  # If we added CPAN support (we don't currently)

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        debug => $opts{debug} || 0,
        connection => undef,
    };
    
    return bless $self, $class;
}

sub execute {
    my ($self, $command, $session) = @_;
    
    # Parse protocol command format
    if ($command =~ /^\[DATABASE:(.+)\]$/) {
        my $params_str = $1;
        my %params = $self->parse_params($params_str);
        
        my $action = $params{action};
        
        if ($action eq 'query') {
            return $self->handle_query(\%params);
        }
        elsif ($action eq 'execute') {
            return $self->handle_execute(\%params);
        }
    }
    
    return { success => 0, error => "Invalid DATABASE protocol format" };
}

sub handle_query {
    my ($self, $params) = @_;
    
    my $sql = $params->{sql};
    
    # Execute query
    # Return results
    
    return {
        success => 1,
        data => \@results,
    };
}

1;
```

**Note:** Current CLIO architecture focuses on tools rather than protocols. Protocol support may be added in future versions.

---------------------------------------------------

## Adding New AI Providers

### Provider Interface

AI providers implement a standard interface for API communication.

**Create `lib/CLIO/Core/Providers/MyProvider.pm`:**

```perl
package CLIO::Core::Providers::MyProvider;

use strict;
use warnings;
use HTTP::Tiny;
use JSON;

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        api_key => $ENV{MY_PROVIDER_API_KEY} || $opts{api_key},
        base_url => 'https://api.myprovider.com/v1',
        debug => $opts{debug} || 0,
    };
    
    return bless $self, $class;
}

sub send_request {
    my ($self, $messages, $tools) = @_;
    
    my $http = HTTP::Tiny->new(
        timeout => 30,
        default_headers => {
            'Authorization' => "Bearer $self->{api_key}",
            'Content-Type' => 'application/json',
        },
    );
    
    my $payload = {
        model => 'myprovider-model',
        messages => $messages,
        tools => $tools,
        stream => JSON::true,
    };
    
    my $response = $http->post(
        "$self->{base_url}/chat/completions",
        {
            content => encode_json($payload),
        }
    );
    
    if ($response->{success}) {
        return $self->parse_response($response->{content});
    }
    else {
        die "API request failed: $response->{reason}\n";
    }
}

sub parse_response {
    my ($self, $content) = @_;
    
    # Parse streaming response
    # Extract messages and tool calls
    
    return {
        message => $message,
        tool_calls => \@tool_calls,
    };
}

1;
```

**Integrate in APIManager:**

Edit `lib/CLIO/Core/APIManager.pm`:

```perl
use CLIO::Core::Providers::MyProvider;

sub new {
    my ($class, %opts) = @_;
    
    # ... existing code ...
    
    # Auto-detect provider
    if ($ENV{MY_PROVIDER_API_KEY}) {
        $provider = CLIO::Core::Providers::MyProvider->new(debug => $debug);
    }
    
    # ... rest of code ...
}
```

---------------------------------------------------

## Testing

### Manual Testing

**Basic functionality:**

```bash
# Test tool execution
echo "list files in current directory" | ./clio --new --exit

# Test session persistence
./clio --new
# Have a conversation
# Exit and resume
./clio --resume
```

**Edge cases:**

```bash
# Large files
echo "read a 10MB file" | ./clio --new --exit

# Invalid input
echo "read a file that doesn't exist" | ./clio --new --exit

# Complex operations
echo "search for TODO in all Perl files, create a summary" | ./clio --new --exit
```

### Automated Testing (Future)

**Unit tests** (`t/unit/`):

```perl
# t/unit/tools/file_operations.t
use Test::More tests => 5;
use CLIO::Tools::FileOperations;

my $tool = CLIO::Tools::FileOperations->new();

# Test read_file operation
my $result = $tool->route_operation('read_file', {
    path => 'test_file.txt',
    start_line => 1,
    end_line => 10,
}, {});

ok($result->{success}, 'read_file succeeds');
like($result->{data}, qr/content/, 'read_file returns content');

done_testing();
```

**Integration tests** (`t/integration/`):

```perl
# t/integration/session_persistence.t
use Test::More;
use CLIO::Session::Manager;

# Create session
my $mgr = CLIO::Session::Manager->new();
my $session = $mgr->create();

# Add conversation
$session->add_message({ role => 'user', content => 'test' });

# Save
$mgr->save($session);

# Load
my $loaded = $mgr->load($session->id());

is($loaded->id(), $session->id(), 'Session ID preserved');

done_testing();
```

---------------------------------------------------

## Code Standards

> **See Also:** [Developer Documentation Guide](DEVELOPER_DOCUMENTATION_GUIDE.md) for complete POD documentation standards, code commenting guidelines, and technical writing best practices.

### Perl Best Practices

**Module Structure:**

```perl
package CLIO::Module::Name;

use strict;
use warnings;
use feature 'say';

# POD documentation
=head1 NAME

CLIO::Module::Name - Brief description

=head1 DESCRIPTION

Detailed description.

=cut

# Code here

1;  # Module MUST return true
```

**Naming:**

```perl
# Variables: snake_case
my $file_path = "/path/to/file";
my $line_count = 0;

# Subroutines: snake_case
sub read_file { ... }
sub parse_response { ... }

# Packages: CamelCase
package CLIO::Core::AIAgent;

# Constants: UPPERCASE
use constant MAX_RETRIES => 3;
```

**Error Handling:**

```perl
# Use eval for exception handling
eval {
    # Code that might die
};
if ($@) {
    my $error = $@;
    print STDERR "[ERROR] $error\n";
    # Handle error
}
```

**Logging:**

```perl
use CLIO::Core::Logger qw(should_log);

# Debug logging
print STDERR "[DEBUG][Module] Message\n" if should_log('DEBUG');

# Error logging
print STDERR "[ERROR][Module] Error message\n";

# Trace logging (automatic when --debug is used)
print STDERR "[TRACE][Module] Detail\n" if should_log('DEBUG');
```

**No CPAN Dependencies:**

```perl
# ✅ Use core modules
use JSON;          # Core since 5.14
use HTTP::Tiny;    # Core since 5.14
use File::Spec;    # Core

# ❌ Don't use CPAN modules
use Moo;           # Not core
use LWP::UserAgent # Not core
```

### Documentation Standards

**POD for modules:**

```perl
=head1 NAME

CLIO::Tools::MyTool - Brief description

=head1 SYNOPSIS

    use CLIO::Tools::MyTool;
    
    my $tool = CLIO::Tools::MyTool->new();
    my $result = $tool->route_operation('op', $params, $context);

=head1 DESCRIPTION

Detailed description of the module.

=head2 method_name

Description of what this method does.

Arguments:
- $arg1: Description
- $arg2: Description

Returns: Description of return value

=cut
```

**Inline comments:**

```perl
# Explain WHY, not WHAT
# Bad:
my $count = 0;  # Initialize count to zero

# Good:
my $count = 0;  # Track number of failed retries for exponential backoff
```

---------------------------------------------------

## Contribution Workflow

### Before Contributing

1. **Read The Unbroken Method**: `cat ai-assisted/THE_UNBROKEN_METHOD.md`
2. **Check existing issues**: Search for related work
3. **Discuss major changes**: Open an issue first for large features
4. **Consider using CLIO**: CLIO is developed using CLIO itself. Using CLIO for your contributions helps you understand the tool from a user's perspective and ensures your changes work well in practice.

### Development Workflow

**1. Fork and Clone:**

```bash
# Fork on GitHub, then:
git clone https://github.com/YOUR_USERNAME/clio.git
cd clio
git remote add upstream https://github.com/fewtarius/clio.git
```

**2. Create Feature Branch:**

```bash
git checkout -b feature/my-new-feature
```

**3. Make Changes:**

```bash
# Edit code
# Test changes
perl -I lib -c lib/CLIO/Tools/MyNewTool.pm
./clio --debug
```

**4. Commit:**

```bash
git add -A
git commit -m "feat(tools): add MyNewTool for X functionality

**Problem:**
[what was missing or broken]

**Solution:**
[how you fixed or built it]

**Testing:**
✅ Syntax: PASS (perl -c)
✅ Manual: [what you tested]
✅ Edge cases: [what you verified]"
```

**Commit message format:**
```
type(scope): brief description

**Problem:**
What was broken or missing

**Solution:**
How you fixed it

**Testing:**
What you tested
```

**Types:** feat, fix, refactor, docs, test, chore

**5. Push and PR:**

```bash
git push origin feature/my-new-feature
```

Then open a Pull Request on GitHub.

### Code Review

**Expect reviewers to check:**
- Code quality and style
- Test coverage
- Documentation completeness
- No CPAN dependencies
- Action descriptions present
- Error handling

**Be prepared to:**
- Answer questions about design decisions
- Make requested changes
- Add tests if missing
- Update documentation

---------------------------------------------------

## Resources

**Internal Documentation:**
- `docs-internal/` - Development specifications
- `SYSTEM_DESIGN.md` - Architecture overview
- `PROJECT_PLAN.md` - Implementation roadmap

**Code Examples:**
- `lib/CLIO/Tools/FileOperations.pm` - Comprehensive tool example
- `lib/CLIO/Tools/TodoList.pm` - State management example
- `lib/CLIO/UI/Markdown.pm` - UI component example

**Community:**
- [GitHub Issues](https://github.com/fewtarius/clio/issues)
- [GitHub Discussions](https://github.com/fewtarius/clio/discussions)

---------------------------------------------------

## Next Steps

1. **Set up your development environment**
2. **Read existing code** - Understand patterns
3. **Pick a small task** - Start with documentation or minor feature
4. **Ask questions** - Use GitHub Discussions
5. **Submit your first PR!**

**Welcome to CLIO development!**
