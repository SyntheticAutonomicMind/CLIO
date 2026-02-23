package CLIO::Core::PromptBuilder;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

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
        _tools_section_cache => undef,
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

    log_debug('PromptBuilder', "Loading system prompt from PromptManager");

    my $base_prompt = $pm->get_system_prompt();

    # Add current date/time and context management note at the beginning
    my $datetime_section = $self->generate_datetime_section();
    $base_prompt = $datetime_section . "\n\n" . $base_prompt;

    # Dynamically add available tools section from tool registry
    my $tools_section = $self->generate_tools_section();

    # Build LTM context section if session is available AND not skipping LTM
    my $ltm_section = '';
    if ($session && !$self->{skip_ltm}) {
        $ltm_section = $self->generate_ltm_section($session);
    } elsif ($self->{skip_ltm}) {
        log_debug('PromptBuilder', "Skipping LTM injection (--no-ltm or --incognito)");
    }

    # Insert tools section after "## Core Instructions" or append if not found
    if ($base_prompt =~ /## Core Instructions/) {
        $base_prompt =~ s/(## Core Instructions.*?\n)/$1\n$tools_section\n/s;
    } else {
        $base_prompt .= "\n\n$tools_section";
    }

    # Insert LTM section after tools section if available
    if ($ltm_section) {
        $base_prompt .= "\n\n$ltm_section";
        log_debug('PromptBuilder', "Added LTM context section to prompt");
    }

    # Add non-interactive mode instruction if running with --input flag
    if ($self->{non_interactive}) {
        my $non_interactive_section = generate_non_interactive_section();
        $base_prompt .= "\n\n$non_interactive_section";
        log_debug('PromptBuilder', "Added non-interactive mode section to prompt");
    }

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
    return $self->{_tools_section_cache} if $self->{_tools_section_cache};

    # Get all registered tool OBJECTS (not just names)
    my $tools = $self->{tool_registry}->get_all_tools();
    my $tool_count = scalar(@$tools);

    log_debug('PromptBuilder', "Generating tools section for $tool_count tools");

    my $section = "## Available Tools - READ THIS CAREFULLY\n\n";
    $section .= "You have access to exactly $tool_count function calling tools. ";
    $section .= "When users ask \"what tools do you have?\", list ALL of these by name:\n\n";

    my $num = 1;
    for my $tool (@$tools) {
        my $name = $tool->{name};
        my $description = $tool->{description};

        # Extract first line of description (summary)
        my ($summary) = split /\n/, $description;
        $summary =~ s/^\s+|\s+$//g;

        $section .= "$num. **$name** - $summary\n";
        $num++;
    }

    $section .= "\n**Important:** You HAVE all $tool_count of these tools. ";
    $section .= "Do NOT say you don't have a tool that's on this list!\n\n";

    # Add operation-based tool explanation
    $section .= "## **HOW TO USE OPERATION-BASED TOOLS**\n\n";
    $section .= "Most tools use an **operation-based pattern**: one tool with multiple operations.\n\n";
    $section .= "**Example:** `file_operations` has 17 operations (read_file, write_file, grep_search, etc.)\n\n";
    $section .= "**CORRECT way to call:**\n";
    $section .= "```\n";
    $section .= "file_operations(\n";
    $section .= "  operation: \"read_file\",\n";
    $section .= "  path: \"lib/Example.pm\"\n";
    $section .= ")\n";
    $section .= "```\n\n";
    $section .= "**The `operation` parameter is ALWAYS REQUIRED.** Every tool call must specify which operation to perform.\n\n";
    $section .= "**Each operation needs different parameters** - check the tool's schema to see what parameters each operation requires.\n\n";

    # Add JSON formatting instruction
    $section .= "## **CRITICAL - JSON FORMAT REQUIREMENT**\n\n";
    $section .= "When calling tools, you MUST generate valid JSON. This is NON-NEGOTIABLE.\n\n";
    $section .= "**FORBIDDEN:**  `{\"offset\":,\"length\":8192}`  <- Missing value = PARSER CRASH\n\n";
    $section .= "**CORRECT Options:**\n";
    $section .= "1. Omit optional param: `{\"operation\":\"read_tool_result\",\"length\":8192}`\n";
    $section .= "2. Include with value: `{\"operation\":\"read_tool_result\",\"offset\":0,\"length\":8192}`\n\n";
    $section .= "**Rule:** EVERY parameter key MUST have a value. No exceptions.\n\n";
    $section .= "**DECIMAL NUMBERS:** Always include leading zero: `0.1` not `.1`, `0.05` not `.05`\n";

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

=head2 generate_ltm_section

Build a section with relevant Long-Term Memory patterns from the session.

Arguments:
- $session: Session object with LTM access

Returns:
- Markdown text with relevant LTM patterns (empty string if no patterns)

=cut

sub generate_ltm_section {
    my ($self, $session) = @_;

    return '' unless $session;

    my $ltm = eval { $session->get_long_term_memory() };
    if ($@ || !$ltm) {
        log_debug('PromptBuilder', "No LTM available: $@");
        return '';
    }

    my $discoveries = eval { $ltm->query_discoveries(limit => 3) } || [];
    my $solutions = eval { $ltm->query_solutions(limit => 3) } || [];
    my $patterns = eval { $ltm->query_patterns(limit => 3) } || [];
    my $workflows = eval { $ltm->query_workflows(limit => 2) } || [];
    my $failures = eval { $ltm->query_failures(limit => 2) } || [];

    my $total = @$discoveries + @$solutions + @$patterns + @$workflows + @$failures;
    return '' if $total == 0;

    log_debug('PromptBuilder', "Found $total LTM patterns to inject");

    my $section = "## Long-Term Memory Patterns\n\n";
    $section .= "The following patterns have been learned from previous sessions in this project:\n\n";

    if (@$discoveries) {
        $section .= "### Key Discoveries\n\n";
        for my $item (@$discoveries) {
            my $fact = $item->{fact} || 'Unknown';
            my $confidence = $item->{confidence} || 0;
            my $verified = $item->{verified} ? 'Verified' : 'Unverified';
            $section .= "- **$fact** (Confidence: " . sprintf("%.0f%%", $confidence * 100) . ", $verified)\n";
        }
        $section .= "\n";
    }

    if (@$solutions) {
        $section .= "### Problem Solutions\n\n";
        for my $item (@$solutions) {
            my $error = $item->{error} || 'Unknown error';
            my $solution = $item->{solution} || 'No solution';
            my $solved_count = $item->{solved_count} || 0;
            $section .= "**Problem:** $error\n";
            $section .= "**Solution:** $solution\n";
            $section .= "_Applied successfully $solved_count time" . ($solved_count == 1 ? '' : 's') . "_\n\n";
        }
    }

    if (@$patterns) {
        $section .= "### Code Patterns\n\n";
        for my $item (@$patterns) {
            my $pattern = $item->{pattern} || 'Unknown pattern';
            my $confidence = $item->{confidence} || 0;
            my $examples = $item->{examples} || [];
            $section .= "- **$pattern** (Confidence: " . sprintf("%.0f%%", $confidence * 100) . ")\n";
            if (@$examples) {
                $section .= "  Examples: " . join(", ", @$examples) . "\n";
            }
        }
        $section .= "\n";
    }

    if (@$workflows) {
        $section .= "### Successful Workflows\n\n";
        for my $item (@$workflows) {
            my $sequence = $item->{sequence} || [];
            my $success_rate = $item->{success_rate} || 0;
            my $count = $item->{count} || 0;
            if (@$sequence) {
                $section .= "- " . join(" -> ", @$sequence) . "\n";
                $section .= "  _Success rate: " . sprintf("%.0f%%", $success_rate * 100) . " ($count attempts)_\n";
            }
        }
        $section .= "\n";
    }

    if (@$failures) {
        $section .= "### Known Failures (Avoid These)\n\n";
        for my $item (@$failures) {
            my $what_broke = $item->{what_broke} || 'Unknown failure';
            my $impact = $item->{impact} || 'Unknown impact';
            my $prevention = $item->{prevention} || 'No prevention documented';
            $section .= "**What broke:** $what_broke\n";
            $section .= "**Impact:** $impact\n";
            $section .= "**Prevention:** $prevention\n\n";
        }
    }

    $section .= "_These patterns are project-specific and should inform your approach to similar tasks._\n";

    return $section;
}

=head2 generate_non_interactive_section

Generate instruction text for non-interactive mode (--input flag).
Tells the agent NOT to use user_collaboration since the user is not present.

Returns:
- Markdown text with non-interactive mode instructions

=cut

sub generate_non_interactive_section {
    return q{## Non-Interactive Mode (CRITICAL)

**You are running in non-interactive mode (--input flag).**

This means the user is NOT present to respond to questions. The command will exit after your response.

**CRITICAL RESTRICTIONS:**

1. **DO NOT use user_collaboration tool** - There is no user to respond. Any call to user_collaboration will fail or hang.

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

WRONG: Call user_collaboration asking "Should I proceed?"
RIGHT: Call file_operations to create the file, then report success.

**Remember: Work autonomously. The user will see your response after the fact, not during execution.**
};
}

1;

__END__

=head1 AUTHOR

Andrew Wyatt (Fewtarius)

=head1 LICENSE

GPL-3.0-only

=cut
