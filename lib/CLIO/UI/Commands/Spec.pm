# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::Spec;

use strict;
use warnings;
use utf8;
use parent 'CLIO::UI::Commands::Base';
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use CLIO::Spec::Manager;

=head1 NAME

CLIO::UI::Commands::Spec - OpenSpec-compatible spec management commands

=head1 DESCRIPTION

Handles the /spec command family for managing OpenSpec-compatible specs
and changes. Lightweight approach: provides file management and context
without full OpenSpec ceremony.

=head1 COMMANDS

    /spec                  Show spec overview (specs + active changes)
    /spec init             Initialize openspec/ directory
    /spec list             List all specs and active changes
    /spec show <domain>    Show a spec's contents
    /spec new <name>       Create a new change
    /spec status [name]    Show artifact status for a change
    /spec tasks [name]     Show tasks from a change's tasks.md
    /spec archive <name>   Archive a completed change
    /spec help             Show help

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        chat    => $args{chat} || croak("chat instance required"),
        session => $args{session},
        debug   => $args{debug} // 0,
    };

    bless $self, $class;
    return $self;
}


=head2 handle_spec_command(@args)

Main dispatcher for /spec commands.

=cut

sub handle_spec_command {
    my ($self, @args) = @_;

    my $subcmd = shift @args || '';
    $subcmd = lc($subcmd);

    my $mgr = $self->_manager();

    if ($subcmd eq '' || $subcmd eq 'overview') {
        return $self->_cmd_overview($mgr);
    }
    elsif ($subcmd eq 'init') {
        return $self->_cmd_init($mgr, @args);
    }
    elsif ($subcmd eq 'list' || $subcmd eq 'ls') {
        return $self->_cmd_list($mgr);
    }
    elsif ($subcmd eq 'show' || $subcmd eq 'read') {
        return $self->_cmd_show($mgr, @args);
    }
    elsif ($subcmd eq 'new' || $subcmd eq 'create') {
        return $self->_cmd_new($mgr, @args);
    }
    elsif ($subcmd eq 'status' || $subcmd eq 'st') {
        return $self->_cmd_status($mgr, @args);
    }
    elsif ($subcmd eq 'tasks') {
        return $self->_cmd_tasks($mgr, @args);
    }
    elsif ($subcmd eq 'archive') {
        return $self->_cmd_archive($mgr, @args);
    }
    elsif ($subcmd eq 'propose') {
        return $self->_cmd_propose($mgr, @args);
    }
    elsif ($subcmd eq 'help' || $subcmd eq 'h') {
        return $self->_cmd_help();
    }
    else {
        $self->display_error_message("Unknown spec command: $subcmd (try /spec help)");
    }

    return;
}

# --- Command implementations ---

sub _cmd_overview {
    my ($self, $mgr) = @_;

    unless ($mgr->is_initialized()) {
        $self->display_system_message("No openspec/ directory found. Run /spec init to set up.");
        return;
    }

    my @specs = $mgr->list_specs();
    my @changes = $mgr->list_changes();
    my $config = $mgr->load_config();

    $self->writeline("");
    $self->writeline($self->colorize(" OpenSpec Overview", 'success'));
    $self->writeline("");

    $self->writeline("  Schema: " . $self->colorize($config->{schema} || 'spec-driven', 'info'));

    if (@specs) {
        $self->writeline("");
        $self->writeline("  " . $self->colorize("Specs (" . scalar(@specs) . ")", 'header'));
        for my $s (@specs) {
            $self->writeline("    - " . $self->colorize($s->{name}, 'info'));
        }
    } else {
        $self->writeline("");
        $self->writeline("  " . $self->colorize("No specs yet", 'dim'));
    }

    if (@changes) {
        $self->writeline("");
        $self->writeline("  " . $self->colorize("Active Changes (" . scalar(@changes) . ")", 'header'));
        for my $c (@changes) {
            my $status = $mgr->change_status($c->{name});
            my $arts = $status->{artifacts} || [];
            my $done = grep { $_->{status} eq 'done' } @$arts;
            my $total = scalar @$arts;
            my $progress = $total > 0 ? "$done/$total" : "0/0";
            my $ready = $status->{apply_ready} ? $self->colorize(" ready", 'success') : '';
            $self->writeline("    - " . $self->colorize($c->{name}, 'info') . " ($progress artifacts)$ready");
        }
    } else {
        $self->writeline("");
        $self->writeline("  " . $self->colorize("No active changes", 'dim'));
    }

    $self->writeline("");
}

sub _cmd_init {
    my ($self, $mgr, @args) = @_;

    my %opts;
    # Parse --context "..." if provided
    for (my $i = 0; $i < scalar @args; $i++) {
        if ($args[$i] eq '--context' && $i + 1 < scalar @args) {
            $opts{context} = $args[$i + 1];
            $i++;
        }
        elsif ($args[$i] eq '--force') {
            $opts{force} = 1;
        }
    }

    my $result = $mgr->init(%opts);
    if ($result->{success}) {
        $self->display_system_message("$result->{message}");
        $self->display_system_message("Created: openspec/specs/, openspec/changes/, openspec/config.yaml");
        $self->display_system_message("Use /spec new <name> to create your first change.");
    } else {
        $self->display_error_message($result->{message});
    }
}

sub _cmd_list {
    my ($self, $mgr) = @_;

    unless ($mgr->is_initialized()) {
        $self->display_system_message("No openspec/ directory. Run /spec init first.");
        return;
    }

    my @specs = $mgr->list_specs();
    my @changes = $mgr->list_changes();

    $self->writeline("");

    if (@specs) {
        $self->writeline("  " . $self->colorize("Specs", 'header'));
        for my $s (@specs) {
            $self->writeline("    " . $self->colorize($s->{name}, 'info') . "  $s->{path}");
        }
    } else {
        $self->writeline("  " . $self->colorize("No specs defined", 'dim'));
    }

    $self->writeline("");

    if (@changes) {
        $self->writeline("  " . $self->colorize("Active Changes", 'header'));
        for my $c (@changes) {
            $self->writeline("    " . $self->colorize($c->{name}, 'info') .
                "  (schema: $c->{schema}, created: $c->{created})");
        }
    } else {
        $self->writeline("  " . $self->colorize("No active changes", 'dim'));
    }

    $self->writeline("");
}

sub _cmd_show {
    my ($self, $mgr, @args) = @_;

    my $domain = $args[0];
    unless ($domain) {
        $self->display_error_message("Usage: /spec show <domain>");
        return;
    }

    my $result = $mgr->read_spec($domain);
    if ($result->{success}) {
        $self->writeline("");
        $self->writeline($self->colorize("Spec: $domain", 'header'));
        $self->writeline($self->colorize("Path: $result->{path}", 'dim'));
        $self->writeline("");
        $self->writeline($result->{content});
    } else {
        $self->display_error_message($result->{message});
    }
}

sub _cmd_new {
    my ($self, $mgr, @args) = @_;

    my $name = $args[0];
    unless ($name) {
        $self->display_error_message("Usage: /spec new <change-name>");
        $self->display_system_message("  Use kebab-case: /spec new add-dark-mode");
        return;
    }

    my $result = $mgr->create_change($name);
    if ($result->{success}) {
        $self->display_system_message($result->{message});
        $self->display_system_message("Schema: $result->{schema}");
        $self->display_system_message("Next: Ask the AI to create the proposal and other artifacts.");
    } else {
        $self->display_error_message($result->{message});
    }
}

sub _cmd_status {
    my ($self, $mgr, @args) = @_;

    my $name = $args[0];

    # If no name, try to pick the only active change or list them
    unless ($name) {
        my @changes = $mgr->list_changes();
        if (@changes == 0) {
            $self->display_system_message("No active changes.");
            return;
        }
        elsif (@changes == 1) {
            $name = $changes[0]{name};
        }
        else {
            $self->display_error_message("Multiple active changes. Specify one:");
            for my $c (@changes) {
                $self->writeline("  /spec status $c->{name}");
            }
            return;
        }
    }

    my $status = $mgr->change_status($name);
    unless ($status->{success}) {
        $self->display_error_message($status->{message});
        return;
    }

    $self->writeline("");
    $self->writeline($self->colorize("Change: $name", 'header'));
    $self->writeline("  Schema: $status->{schema}  Created: $status->{created}");
    $self->writeline("");

    for my $art (@{$status->{artifacts}}) {
        my $icon = $art->{status} eq 'done' ? $self->colorize('', 'success')
                 : $art->{status} eq 'ready' ? $self->colorize('◆', 'warning')
                 : $self->colorize('○', 'dim');
        my $deps = @{$art->{requires}} ? " (requires: " . join(', ', @{$art->{requires}}) . ")" : '';
        $self->writeline("  $icon $art->{id} - $art->{description}$deps");
    }

    $self->writeline("");
    if ($status->{apply_ready}) {
        $self->writeline("  " . $self->colorize(" Ready for implementation!", 'success'));
    } else {
        $self->writeline("  " . $self->colorize("Create remaining artifacts before implementation.", 'dim'));
    }
    $self->writeline("");
}

sub _cmd_tasks {
    my ($self, $mgr, @args) = @_;

    my $name = $args[0];
    unless ($name) {
        my @changes = $mgr->list_changes();
        if (@changes == 1) { $name = $changes[0]{name}; }
        else {
            $self->display_error_message("Specify change name: /spec tasks <name>");
            return;
        }
    }

    my @tasks = $mgr->parse_tasks($name);
    unless (@tasks) {
        $self->display_system_message("No tasks found for '$name'. Create tasks.md first.");
        return;
    }

    $self->writeline("");
    $self->writeline($self->colorize("Tasks: $name", 'header'));
    $self->writeline("");

    my $current_group = '';
    my $done_count = 0;
    for my $t (@tasks) {
        if ($t->{group} ne $current_group) {
            $self->writeline("  " . $self->colorize($t->{group}, 'info')) if $t->{group};
            $current_group = $t->{group};
        }
        my $check = $t->{completed}
            ? $self->colorize('[x]', 'success')
            : $self->colorize('[ ]', 'dim');
        $self->writeline("    $check $t->{title}");
        $done_count++ if $t->{completed};
    }

    my $total = scalar @tasks;
    $self->writeline("");
    $self->writeline("  Progress: $done_count/$total tasks complete");
    $self->writeline("");
}

sub _cmd_archive {
    my ($self, $mgr, @args) = @_;

    my $name = $args[0];
    unless ($name) {
        $self->display_error_message("Usage: /spec archive <change-name>");
        return;
    }

    my $result = $mgr->archive_change($name);
    if ($result->{success}) {
        $self->display_system_message($result->{message});
    } else {
        $self->display_error_message($result->{message});
    }
}

sub _cmd_propose {
    my ($self, $mgr, @args) = @_;

    my $name = $args[0];
    unless ($name) {
        $self->display_error_message("Usage: /spec propose <change-name>");
        $self->display_system_message("  Example: /spec propose add-dark-mode");
        return;
    }

    # Create the change
    my $result = $mgr->create_change($name);
    unless ($result->{success}) {
        $self->display_error_message($result->{message});
        return;
    }

    $self->display_system_message("Created change: $name");

    # Build a prompt for the AI to generate artifacts
    my $schema = $mgr->load_schema($result->{schema});
    my $config = $mgr->load_config();
    my $artifacts = $schema->{artifacts} || [];

    my @prompt_parts;
    push @prompt_parts, "I've created a new OpenSpec change called '$name'.";
    push @prompt_parts, "";
    push @prompt_parts, "Please create the planning artifacts for this change. The artifacts to create are:";

    for my $art (@$artifacts) {
        my $path = "openspec/changes/$name/$art->{generates}";
        push @prompt_parts, "- **$art->{id}** ($path): $art->{description}";
    }

    push @prompt_parts, "";
    push @prompt_parts, "Create them in dependency order. For each artifact:";
    push @prompt_parts, "1. Read any dependency artifacts that exist";
    push @prompt_parts, "2. Write the artifact following the instructions below";
    push @prompt_parts, "";

    for my $art (@$artifacts) {
        push @prompt_parts, "### $art->{id} instructions:";
        push @prompt_parts, $art->{instruction} if $art->{instruction};
        push @prompt_parts, "";
    }

    if ($config->{context}) {
        push @prompt_parts, "### Project context:";
        push @prompt_parts, $config->{context};
        push @prompt_parts, "";
    }

    # Return as an AI prompt
    return (1, join("\n", @prompt_parts));
}

sub _cmd_help {
    my ($self) = @_;

    $self->writeline("");
    $self->writeline($self->colorize("  Spec Commands (OpenSpec-compatible)", 'header'));
    $self->writeline("");
    $self->writeline(sprintf("  %-28s %s", $self->colorize('/spec', 'help_command'), 'Show spec overview'));
    $self->writeline(sprintf("  %-28s %s", $self->colorize('/spec init', 'help_command'), 'Initialize openspec/ directory'));
    $self->writeline(sprintf("  %-28s %s", $self->colorize('/spec list', 'help_command'), 'List specs and changes'));
    $self->writeline(sprintf("  %-28s %s", $self->colorize('/spec show <domain>', 'help_command'), 'Show a spec'));
    $self->writeline(sprintf("  %-28s %s", $self->colorize('/spec new <name>', 'help_command'), 'Create a new change'));
    $self->writeline(sprintf("  %-28s %s", $self->colorize('/spec propose <name>', 'help_command'), 'Create change + AI generates artifacts'));
    $self->writeline(sprintf("  %-28s %s", $self->colorize('/spec status [name]', 'help_command'), 'Show artifact status'));
    $self->writeline(sprintf("  %-28s %s", $self->colorize('/spec tasks [name]', 'help_command'), 'Show tasks from tasks.md'));
    $self->writeline(sprintf("  %-28s %s", $self->colorize('/spec archive <name>', 'help_command'), 'Archive completed change'));
    $self->writeline("");
}

# --- Helpers ---

sub _manager {
    my ($self) = @_;
    return CLIO::Spec::Manager->new(
        project_root => '.',
        debug        => $self->{debug},
    );
}

=head1 POD

=head2 Integration

The /spec propose command returns an AI prompt that instructs the AI to
generate all planning artifacts using file_operations. This leverages
CLIO's existing tool-calling workflow rather than requiring a separate CLI.

=cut

1;
