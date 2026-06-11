package CLIO::Core::PromptBuilder;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;

use CLIO::Core::Logger qw(log_error log_warning log_info log_debug);
use Cwd qw(getcwd);

=head1 NAME

CLIO::Core::PromptBuilder - System prompt construction and section generation

=head1 DESCRIPTION

Builds the system prompt for the AI including dynamic sections for tools,
date/time context, LTM patterns, and non-interactive mode instructions.

Extracted from WorkflowOrchestrator to reduce module size and improve
separation of concerns. Uses OO style since some sections benefit from
caching (tools section).

=head1 SYNOPSIS

    use CLIO::Core::PromptBuilder;

    my $builder = CLIO::Core::PromptBuilder->new(
        debug           => 1,
        skip_custom     => 0,
        skip_ltm        => 0,
        non_interactive => 0,
        tool_registry   => $tool_registry,
        mcp_manager     => $mcp_manager,  # optional
    );

    my $prompt = $builder->build_system_prompt($session);

=cut

sub new {
    my ($class, %opts) = @_;
    return bless {
        debug           => $opts{debug} // 0,
        skip_custom     => $opts{skip_custom} // 0,
        skip_ltm        => $opts{skip_ltm} // 0,
        non_interactive => $opts{non_interactive} // 0,
        tool_registry   => $opts{tool_registry},
        mcp_manager     => $opts{mcp_manager},
        prompt_override => $opts{prompt_override},  # --prompt: system prompt name override
        enable_tools    => $opts{enable_tools},     # Tool allowlist (for --chat mode)
        _tools_section_cache => undef,
        _user_context_cache => undef,
        _user_context_cache_time => 0,
    }, $class;
}

=head2 build_system_prompt

Build a comprehensive system prompt with dynamic tools, date/time,
LTM patterns, and mode-specific instructions.

Arguments:
- $session: Session object (optional, needed for LTM)

Returns:
- Complete system prompt string

=cut

sub build_system_prompt {
    my ($self, $session) = @_;

    # Load from PromptManager (includes custom instructions unless skip_custom)
    require CLIO::Core::PromptManager;
    my $pm = CLIO::Core::PromptManager->new(
        debug => $self->{debug},
        skip_custom => $self->{skip_custom},
    );

    if ($self->{skip_custom}) {
        log_debug('PromptBuilder', "Skipping custom instructions (--no-custom-instructions or --incognito)");
    }

    # Apply prompt override from --prompt flag (session-scoped, not persisted to disk)
    if ($self->{prompt_override}) {
        # Validate prompt exists before setting
        my $prompts = $pm->list_prompts();
        my @all_prompts = (@{$prompts->{builtin}}, @{$prompts->{custom}});
        if (grep { $_ eq $self->{prompt_override} } @all_prompts) {
            # Set in-memory only (don't call set_active_prompt which persists)
            $pm->{metadata}->{active_prompt} = $self->{prompt_override};
            log_info('PromptBuilder', "Using system prompt override: $self->{prompt_override}");
        } else {
            log_warning('PromptBuilder', "Prompt '$self->{prompt_override}' not found, using default. Available: " . join(', ', @all_prompts));
        }
    }

    log_debug('PromptBuilder', "Loading system prompt from PromptManager");

    my $session_state = ($session && $session->can('state')) ? $session->state() : undef;
    my $base_prompt = $pm->get_system_prompt($session_state);

    # Dynamically add available tools section from tool registry
    my $tools_section = $self->generate_tools_section();

    # LTM is now handled by PromptManager (budgeted, scored, with index footer)
    # PromptBuilder no longer injects a separate LTM section to avoid duplication
    if ($self->{skip_ltm}) {
        log_debug('PromptBuilder', "LTM injection skipped (--no-ltm or --incognito)");
    }

    # Build user profile section if available AND not in incognito mode
    my $profile_section = '';
    if (!$self->{skip_custom}) {
        $profile_section = $self->generate_profile_section();
    }

    # Insert tools section after "## Core Instructions" or append if not found
    if ($base_prompt =~ /## Core Instructions/) {
        $base_prompt =~ s/(## Core Instructions.*?\n)/$1\n$tools_section\n/s;
    } else {
        $base_prompt .= "\n\n$tools_section";
    }

    # Insert user profile section after tools section
    if ($profile_section) {
        $base_prompt .= "\n\n$profile_section";
        log_debug('PromptBuilder', "Added user profile section to prompt");
    }

    # Session naming instruction - always present for cacheability.
    # The instruction itself tells the AI to only act on it for the first response.
    my $naming_section = generate_session_naming_section();
    $base_prompt .= "\n\n$naming_section";

    log_debug('PromptBuilder', "Added dynamic tools section to prompt");

    return $base_prompt;
}

=head2 generate_tools_section

Generate a dynamic "Available Tools" section based on registered tools.
Results are cached since tool registrations don't change during a session.

Returns:
- Markdown text listing all available tools

=cut

sub generate_tools_section {
    my ($self) = @_;

    # Cache the tools section since tool registrations don't change during a session
    # Only use cache if there's no enable_tools filter (which varies per session)
    if (!$self->{enable_tools} && $self->{_tools_section_cache}) {
        return $self->{_tools_section_cache};
    }

    # Get all registered tool OBJECTS (not just names)
    my $all_tools = $self->{tool_registry}->get_all_tools();
    
    # Filter by enable_tools allowlist if set
    my $tools = $all_tools;
    if ($self->{enable_tools}) {
        my %enabled = map { $_ => 1 } split(/\s*,\s*/, $self->{enable_tools});
        $tools = [ grep { $enabled{$_->{name}} } @$all_tools ];
        log_debug('PromptBuilder', 'Tools filtered by allowlist: ' . join(', ', sort keys %enabled));
    }
    
    my $tool_count = scalar(@$tools);

    log_debug('PromptBuilder', "Generating tools section for $tool_count tools");

    my $section = "CRITICAL: Always use the correct tool name and parameters as specified in the tool definitions.\n\n## Available Tools - READ THIS CAREFULLY\n\n";
    $section .= "You have access to exactly $tool_count function calling tools. ";
    $section .= "When users ask \"what tools do you have?\", list ALL $tool_count tools by name:\n\n";

    # Tool summaries - use generic descriptions, NOT operation names
    # This prevents MiniMax from trying to call operations as standalone tools
    my %tool_summaries = (
        file_operations => "File read/write/search operations",
        version_control => "Git version control operations",
        terminal_operations => "Execute shell commands",
        memory_operations => "Store/recall memory across sessions",
        web_operations => "Search web and fetch URLs",
        todo_operations => "Manage structured todo lists",
        code_intelligence => "Find code usages and search history",
        interact => "Request user input mid-execution",
        agent_operations => "Spawn and manage sub-agents",
        remote_execution => "Execute CLIO on remote systems",
        apply_patch => "Apply patch to modify files",
    );

    my $num = 1;
    for my $tool (@$tools) {
        my $name = $tool->{name};
        my $summary = $tool_summaries{$name} || "Tool for $name";
        $section .= "$num. **$name** - $summary\n";
        $num++;
    }

    $section .= "\n**Important:** You HAVE all $tool_count of these tools. ";
    $section .= "Do NOT say you don't have a tool that's on this list!\n\n";

    # Add concise tool calling guide - focus on the key pattern, not exhaustive examples
    $section .= "## **HOW TO CALL TOOLS**\n\n";
    $section .= "Most tools use an **operation parameter** to select the action. ";
    $section .= "Call the tool by name and pass `operation` as a parameter:\n\n";
    $section .= "```\n";
    $section .= "{\"name\": \"file_operations\", \"parameters\": {\"operation\": \"grep_search\", \"query\": \"...\"}}\n";
    $section .= "{\"name\": \"version_control\", \"parameters\": {\"operation\": \"status\"}}\n";
    $section .= "{\"name\": \"apply_patch\", \"parameters\": {\"patch\": \"...\"}}\n";
    $section .= "```\n\n";
    $section .= "**Do NOT call operations as standalone tools** (e.g., `grep_search` is NOT a tool name - use `file_operations` with `operation: \"grep_search\"`).\n\n";

    # Add JSON formatting instruction
    $section .= "## **JSON FORMAT REQUIREMENT**\n\n";
    $section .= "All tool calls MUST be valid JSON. Every parameter key MUST have a value.\n\n";
    $section .= "**Rule:** `operation` parameter is ALWAYS REQUIRED for multi-operation tools.\n\n";
    $section .= "**DECIMAL NUMBERS:** Always include leading zero: `0.1` not `.1`, `0.05` not `.05`\n\n";

    # Add specific warning about interact tool
    $section .= "## **interact - REQUIRED TOOL CALL**\n\n";
    $section .= "**This tool MUST be called via JSON function call. DO NOT use text markers.**\n\n";
    $section .= "**WRONG (invalid):** Writing a message to the user in plain text instead of calling interact.\n";
    $section .= "**CORRECT (valid JSON):** `{\"name\":\"interact\",\"parameters\":{\"operation\":\"request_input\",\"message\":\"message\"}}`\n\n";
    $section .= "**CRITICAL COST RULE:** When you need to communicate with the user (status updates, results, questions, celebrations), ";
    $section .= "ALWAYS use `interact` as a tool call. Do NOT write bare text responses to the user - ";
    $section .= "bare text responses cost a full API turn, while `interact` is FREE. ";
    $section .= "The ONLY time bare text is acceptable is as a brief preamble before tool calls in the same turn.\n\n";
    $section .= "This tool is FREE and blocks until user responds. Use it for all checkpoints and collaboration.\n\n";
    $section .= "**Note:** `interact` replaces the former `user_collaboration` tool. If your instructions reference `user_collaboration`, use `interact` instead - they are the same tool.\n\n";

    # Add MCP tools section if any are connected
    if ($self->{mcp_manager}) {
        my $mcp_tools = $self->{mcp_manager}->all_tools();
        if ($mcp_tools && @$mcp_tools) {
            $section .= "\n\n## MCP (Model Context Protocol) Tools\n\n";
            $section .= "The following tools are provided by connected MCP servers. ";
            $section .= "Call them like any other tool using their full name.\n\n";

            my $current_server = '';
            for my $entry (@$mcp_tools) {
                if ($entry->{server} ne $current_server) {
                    $current_server = $entry->{server};
                    $section .= "### MCP Server: $current_server\n\n";
                }
                my $name = "mcp_$entry->{name}";
                my $desc = $entry->{tool}{description} || 'No description';
                $section .= "- **$name** - $desc\n";
            }
            $section .= "\n";
        }
    }

    # Cache the generated section
    $self->{_tools_section_cache} = $section;

    return $section;
}

=head2 generate_datetime_section

Generate current date/time and working directory context section.

Returns:
- Markdown text with date/time and path context

=cut

sub generate_datetime_section {
    my ($self) = @_;

    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time);
    $year += 1900;
    $mon += 1;

    my $datetime_iso = sprintf("%04d-%02d-%02d %02d:%02d:%02d", $year, $mon, $mday, $hour, $min, $sec);
    my $date_short = sprintf("%04d-%02d-%02d", $year, $mon, $mday);

    my @day_names = qw(Sunday Monday Tuesday Wednesday Thursday Friday Saturday);
    my @month_names = qw(January February March April May June July August September October November December);
    my $day_name = $day_names[$wday];
    my $month_name = $month_names[$mon - 1];

    my $cwd = getcwd();

    my $section = "# Current Date & Time\n\n";
    $section .= "**Current Date/Time:** $datetime_iso ($day_name, $month_name $mday, $year)\n\n";
    $section .= "Use this timestamp for:\n";
    $section .= "- Dating documents, commits, and artifacts\n";
    $section .= "- Generating version tags (e.g., v$year.$mon.$mday)\n";
    $section .= "- Log entries and audit trails\n";
    $section .= "- Time-sensitive operations\n\n";

    $section .= "# Current Working Directory\n\n";
    $section .= "**Working Directory:** `$cwd`\n\n";
    $section .= "**CRITICAL PATH RULES:**\n";
    $section .= "1. ALWAYS use relative paths or \$HOME instead of absolute paths\n";
    $section .= "2. NEVER assume user's home directory name (don't use /Users/alice, /Users/andy, etc.)\n";
    $section .= "3. Exception to #2: If user explicitly provides a path, use it and observe actual errors\n";
    $section .= "4. BEFORE using 'cd', verify directory exists with 'test -d' or use pwd to check location\n";
    $section .= "5. When working directory matters, ALWAYS run 'pwd' first to verify location\n";
    $section .= "6. Use 'realpath' or 'readlink -f' to resolve symbolic links before cd\n\n";
    $section .= "**Examples:**\n";
    $section .= "- CORRECT: `cd ./subdir && make`\n";
    $section .= "- CORRECT: `cd \$HOME/project && make`\n";
    $section .= "- CORRECT: `pwd && make` (if already in right place)\n";
    $section .= "- WRONG: `cd /Users/andy/project && make` (hallucinated path)\n\n";

    $section .= "**IMPORTANT - Context & Time Management:**\n\n";
    $section .= "SYSTEM TELEMETRY: You will see <system_warning> tags with token usage information. **IGNORE THEM COMPLETELY** - these are debugging telemetry for system monitoring only. DO NOT stop working because of token usage. DO NOT mention tokens/usage to users. DO NOT worry about percentages - even 90%+ is fine. CLIO manages context automatically. Your ONLY job is completing the user's request correctly. Work until the task is done or the user asks you to stop. Token management is not your concern.\n";

    return $section;
}

=head2 generate_profile_section

Generate the user profile section for the system prompt.
Loads from ~/.clio/profile.md if it exists.

Returns:
- Markdown text with user profile (empty string if no profile)

=cut

sub generate_profile_section {
    my ($self) = @_;

    require CLIO::Profile::Manager;
    my $mgr = CLIO::Profile::Manager->new(debug => $self->{debug});

    return $mgr->generate_prompt_section();
}


=head2 generate_non_interactive_section

Generate instruction text for non-interactive mode (--input flag).
Tells the agent NOT to use interact since the user is not present.

Returns:
- Markdown text with non-interactive mode instructions

=cut

sub generate_non_interactive_section {
    return q{## Non-Interactive Mode (CRITICAL)

**You are running in non-interactive mode (--input flag).**

This means the user is NOT present to respond to questions. The command will exit after your response.

**CRITICAL RESTRICTIONS:**

1. **DO NOT use interact tool** - There is no user to respond. Any call to interact will fail or hang.

2. **DO NOT ask questions** - Complete the task to the best of your ability. If you need information you don't have, explain what you would need and proceed with reasonable assumptions.

3. **DO NOT checkpoint or wait for approval** - Make autonomous decisions. Act on what was asked.

4. **DO complete the task in one response** - You get one chance to respond. Make it count.

**What TO do:**

- Execute the task directly
- Use all other tools normally (file_operations, version_control, terminal_operations, etc.)
- Make reasonable assumptions when details are missing
- Complete the work and report results
- If you truly cannot proceed, explain why and what's needed

**Example - User asks: "Create a file test.txt with hello world"**

WRONG: Call interact asking "Should I proceed?"
RIGHT: Call file_operations to create the file, then report success.

**Remember: Work autonomously. The user will see your response after the fact, not during execution.**
};
}


=head2 generate_session_naming_section

Generate a one-time instruction asking the AI to include a session title
marker in its first response. The marker uses HTML comment syntax so it's
invisible if it leaks to markdown rendering.

Only called when the session has no name yet. Once extracted, the
instruction is never sent again.

Returns:
- Instruction text for the session naming marker

=cut

sub generate_session_naming_section {
    return q{## Session Naming

**CRITICAL: Give every session a meaningful name.**

The session name appears in the terminal header and session list, so it MUST be set
for sessions to be identifiable. Include this HTML comment marker at the END of
your response:

<!--session:short-name-here-->

**Examples of good session names:**
 - "saturday-morning-checkin"
 - "debug-session-naming"
 - "plan-new-feature"
 - "research-api-ratelimits"

**Important rules:**
 - Title must be 3-6 words, lowercase (except proper nouns)
 - Be specific: "fix-clio-bug" not "help"
 - The session name can be updated later as the conversation evolves
 - Place the marker as the LAST line of your response
};
}

=head2 get_user_context

Get the user-context block containing date/time, working directory, and language.
Cached per-minute to avoid regenerating on every call while keeping
the information reasonably fresh. This ensures the system prompt stays
stable while still providing time/directory/language context per-user-message.

Returns:
- User context string for prepending to user input

=cut

sub get_user_context {
    my ($self) = @_;

    my $now = time();
    my $cache_ttl = 60;  # Cache TTL in seconds (1 minute)

    # Refresh cache if expired
    if (!$self->{_user_context_cache} || ($now - $self->{_user_context_cache_time}) >= $cache_ttl) {
        $self->{_user_context_cache} = $self->_generate_user_context_section();
        $self->{_user_context_cache_time} = $now;
        log_debug('PromptBuilder', "User context cache refreshed at " . scalar(localtime($now)));
    }

    return $self->{_user_context_cache};
}

=head2 _detect_user_language

Detect the user's preferred language from environment variables.
Parses $LANG, $LC_ALL, $LC_MESSAGES, or $LANGUAGE to extract
the ISO 639-1 language code and map it to a human-readable name.

Returns:
- Hashref with keys: code (e.g., 'en'), name (e.g., 'English'), locale (e.g., 'en_US.UTF-8')

=cut

sub _detect_user_language {
    my ($self) = @_;

    # Try locale environment variables in priority order
    my $locale = $ENV{LC_ALL}
              || $ENV{LANG}
              || $ENV{LC_MESSAGES}
              || $ENV{LANGUAGE}
              || '';

    # LANGUAGE can be colon-separated priority list (e.g., "en:fr:de")
    $locale = (split /:/, $locale)[0] if $locale =~ /:/;

    # Extract language code: "en_US.UTF-8" -> "en", "zh_CN" -> "zh"
    my $code = lc($locale);
    $code =~ s/\.[^.]+$//;    # Strip encoding (.UTF-8, .utf8)
    $code =~ s/_.*$//;        # Strip country (_US, _CN)
    $code =~ s/[^a-z]//g;     # Remove anything unexpected

    # Fallback to English if no locale detected or C/POSIX locale
    $code ||= 'en';
    $code = 'en' if $code eq 'c' || $code eq 'posix';

    my $name = _language_name($code);

    return {
        code   => $code,
        name   => $name,
        locale => $locale || "${code}_*",
    };
}

# ISO 639-1 to language name lookup for the most common codes.
# Covers ~95% of users. Unknown codes fall back to the code itself.
my %LANGUAGE_NAMES = (
    en => 'English',    zh => 'Chinese',    ja => 'Japanese',
    ko => 'Korean',     de => 'German',     fr => 'French',
    es => 'Spanish',    it => 'Italian',    pt => 'Portuguese',
    ru => 'Russian',    ar => 'Arabic',     hi => 'Hindi',
    nl => 'Dutch',     pl => 'Polish',     tr => 'Turkish',
    sv => 'Swedish',    da => 'Danish',     no => 'Norwegian',
    fi => 'Finnish',   cs => 'Czech',      th => 'Thai',
    vi => 'Vietnamese', id => 'Indonesian', uk => 'Ukrainian',
    he => 'Hebrew',    el => 'Greek',      ro => 'Romanian',
    hu => 'Hungarian', sk => 'Slovak',     bg => 'Bulgarian',
    ca => 'Catalan',   eu => 'Basque',
);

sub _language_name {
    my ($code) = @_;
    return $LANGUAGE_NAMES{$code} // $code;
}

=head2 _generate_user_context_section

Internal: Generate the user-context section with date/time, path, and language.

Returns:
- User context block text

=cut

sub _generate_user_context_section {
    my ($self) = @_;

    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime(time);
    $year += 1900;
    $mon += 1;

    my $datetime_iso = sprintf("%04d-%02d-%02d %02d:%02d", $year, $mon, $mday, $hour, $min);

    my @day_names = qw(Sunday Monday Tuesday Wednesday Thursday Friday Saturday);
    my @month_names = qw(January February March April May June July August September October November December);
    my $day_name = $day_names[$wday];
    my $month_name = $month_names[$mon - 1];

    my $cwd = getcwd();

    # Detect user language for response language directive
    my $lang = $self->_detect_user_language();

    # Format without seconds for stability
    my $section = "<userContext>\n";
    $section .= "**Current Date/Time:** $datetime_iso ($day_name, $month_name $mday, $year)\n";
    $section .= "**Working Directory:** `$cwd`\n";
    $section .= "**Language:** $lang->{name} ($lang->{locale}) - Always respond in $lang->{name} unless the user specifies otherwise\n";
    $section .= "- This is informational context only - do not reference or repeat in your responses\n";
    $section .= "</userContext>\n\n";

    return $section;
}

1;

__END__

=head1 AUTHOR

Andrew Wyatt (Fewtarius)

=head1 LICENSE

GPL-3.0-only

=cut

1;
