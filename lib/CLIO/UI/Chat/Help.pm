#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Chat::Help;

use strict;
use warnings;
use utf8;

use CLIO::UI::Terminal qw(box_char);

=head1 NAME

CLIO::UI::Chat::Help - Help command display extracted from Chat.pm

=head1 SYNOPSIS

    my $help = CLIO::UI::Chat::Help->new($chat);
    $help->display_help();

=head1 DESCRIPTION

Renders the full slash-command help listing with pagination.
Extracted from CLIO::UI::Chat.

=cut

sub new {
    my ($class, $chat) = @_;
    return bless { chat => $chat }, $class;
}

sub display_help {
    my ($self) = @_;
    my $chat = $self->{chat};

    $chat->refresh_terminal_size();
    $chat->{pager}->reset();
    $chat->{pager}->enable();

    my @help_lines;

    push @help_lines, "";
    push @help_lines, $chat->colorize(box_char("dhorizontal") x 62, 'command_header');
    push @help_lines, $chat->colorize($chat->agent_name() . " COMMANDS", 'command_header');
    push @help_lines, $chat->colorize(box_char("dhorizontal") x 62, 'command_header');
    push @help_lines, "";

    push @help_lines, $chat->colorize("BASICS", 'command_subheader');
    push @help_lines, $chat->colorize(box_char("horizontal") x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('/help, /h', 'help_command'), 'Display this help');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('/exit, /quit, /q', 'help_command'), 'Exit the chat');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('/clear', 'help_command'), 'Clear the screen');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('/reset', 'help_command'), 'Reset terminal and kill stale processes');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('/init', 'help_command'), 'Initialize ' . $chat->agent_name() . ' for this project');
    push @help_lines, "";

    push @help_lines, $chat->colorize("KEYBOARD SHORTCUTS", 'command_subheader');
    push @help_lines, $chat->colorize(box_char("horizontal") x 62, 'dim');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Left/Right', 'help_command'), 'Move cursor by character');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Shift+Left/Right', 'help_command'), 'Move cursor by word');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Option+Left/Right', 'help_command'), 'Move cursor by word (macOS)');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Ctrl+A / Home', 'help_command'), 'Move to start of line');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Ctrl+E / End', 'help_command'), 'Move to end of line');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Backspace', 'help_command'), 'Delete character before cursor');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Delete / Fn+Delete', 'help_command'), 'Delete character at cursor');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Ctrl+W', 'help_command'), 'Delete word before cursor');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Shift+Delete', 'help_command'), 'Delete word before cursor');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Option+Backspace', 'help_command'), 'Delete word before cursor (macOS)');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Alt+D', 'help_command'), 'Delete word after cursor');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Ctrl+Delete', 'help_command'), 'Delete word after cursor');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Option+D', 'help_command'), 'Delete word after cursor (macOS)');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Ctrl+K', 'help_command'), 'Delete to end of line');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Ctrl+U', 'help_command'), 'Delete to start of line');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Up/Down', 'help_command'), 'Navigate command history');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Tab', 'help_command'), 'Auto-complete commands/paths');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Any key', 'help_command'), 'Interrupt the agent');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Ctrl+C', 'help_command'), 'Cancel input or exit');
    push @help_lines, sprintf("  %-30s %s", $chat->colorize('Ctrl+D', 'help_command'), 'Exit (on empty line)');
    push @help_lines, "";

    # API, Session, File/Git, Plugins, Todo, Specs, Memory, Profile,
    # Updates, Developer, Skills, Devices, Multi-Agent, Other sections...
    my @sections = (
        ["API & CONFIG" => [
            '/api' => 'API settings (model, provider, login)',
            '/api set model <name>' => 'Set AI model',
            '/api models' => 'List available models',
            '/model <name>' => 'Quick model switch (alias-aware)',
            '/api alias <name> <model>' => 'Create model alias',
            '/api remove <provider>' => 'Remove provider credentials',
            '/config' => 'Global configuration',
        ]],
        ["SESSION" => [
            '/session' => 'Session management',
            '/session list' => 'List all sessions',
            '/session switch' => 'Switch sessions',
        ]],
        ["FILE & GIT" => [
            '/file' => 'File operations',
            '/file read <path>' => 'View file',
            '/git' => 'Git operations',
            '/git status' => 'Show git status',
            '/undo' => 'Revert AI changes from last turn',
            '/undo diff' => 'Show changes since last turn',
            '/undo list' => 'List recent turns with file changes',
            '/mcp' => 'MCP server status',
            '/mcp list' => 'List MCP tools',
            '/mcp add <name> <cmd>' => 'Add MCP server',
            '/mcp remove <name>' => 'Remove MCP server',
            '/mcp auth <name>' => 'Trigger OAuth authentication',
        ]],
        ["PLUGINS" => [
            '/plugin' => 'List installed plugins',
            '/plugin info <name>' => 'Show plugin details',
            '/plugin enable <name>' => 'Enable a plugin',
            '/plugin disable <name>' => 'Disable a plugin',
            '/plugin config <name> [k v]' => 'View/set plugin config',
        ]],
        ["TODO" => [
            '/todo' => "View agent's todo list",
            '/todo add <text>' => 'Add todo',
            '/todo done <id>' => 'Complete todo',
        ]],
        ["SPECS (OpenSpec)" => [
            '/spec' => 'Show spec overview',
            '/spec init' => 'Initialize openspec/ directory',
            '/spec list' => 'List specs and changes',
            '/spec new <name>' => 'Create a new change',
            '/spec propose <name>' => 'Create change + AI generates artifacts',
            '/spec status [name]' => 'Show artifact status',
            '/spec archive <name>' => 'Archive completed change',
        ]],
        ["MEMORY" => [
            '/memory' => 'View long-term memory patterns',
            '/memory list [type]' => 'List all or filtered patterns',
            '/memory store <type>' => 'Store pattern (via AI)',
            '/memory clear' => 'Clear all patterns',
        ]],
        ["PROFILE" => [
            '/profile' => 'View profile status',
            '/profile build' => 'Build profile from session history',
            '/profile show' => 'Display current profile',
            '/profile edit' => 'Open profile in editor',
            '/profile clear' => 'Remove profile',
        ]],
        ["UPDATES" => [
            '/update' => 'Show update status and help',
            '/update check' => 'Check for available updates',
            '/update list' => 'List all available versions',
            '/update install' => 'Install latest version',
            '/update switch <ver>' => 'Switch to a specific version',
        ]],
        ["DEVELOPER" => [
            '/explain [file]' => 'Explain code',
            '/review [file]' => 'Review code',
            '/test [file]' => 'Generate tests',
            '/fix <file>' => 'Propose fixes',
            '/doc <file>' => 'Generate docs',
            '/design' => 'Create/update project PRD',
        ]],
        ["SKILLS & PROMPTS" => [
            '/skills' => 'Manage custom skills',
            '/prompt' => 'Manage system prompts',
        ]],
        ["DEVICES & REMOTE" => [
            '/device' => 'List registered devices',
            '/device add <name> <host>' => 'Register device',
            '/device info <name>' => 'Device details',
            '/group' => 'List device groups',
            '/group add <name> <devs...>' => 'Create group',
        ]],
        ["MULTI-AGENT" => [
            '/agent spawn <task>' => 'Spawn a sub-agent',
            '/agent list' => 'List sub-agents',
            '/agent inbox' => 'Check messages from agents',
            '/mux status' => 'Multiplexer status (tmux/screen)',
            '/mux agent <id>' => 'Open agent output pane',
            '/mux close all' => 'Close all managed panes',
        ]],
        ["OTHER" => [
            '/billing' => 'API usage stats',
            '/stats' => 'Memory and performance stats',
            '/stats history' => 'Memory usage timeline',
            '/context' => 'Manage context files',
            '/exec <cmd>' => 'Run shell command',
            '/multi, /ml, //' => 'Open editor for multi-line input',
            '/style, /theme' => 'Appearance settings',
            '/debug' => 'Toggle debug mode',
        ]],
    );

    for my $section (@sections) {
        my ($title, $items) = @$section;
        push @help_lines, $chat->colorize($title, 'command_subheader');
        push @help_lines, $chat->colorize(box_char("horizontal") x 62, 'dim');
        for my $item (@$items) {
            my ($cmd, $desc) = @$item;
            push @help_lines, sprintf("  %-30s %s", $chat->colorize($cmd, 'help_command'), $desc);
        }
        push @help_lines, "";
    }

    for my $line (@help_lines) {
        last unless $chat->writeline($line, markdown => 0);
    }

    $chat->{pager}->reset();
}

1;