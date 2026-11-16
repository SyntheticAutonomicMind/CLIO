# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::Context;

use strict;
use warnings;
use utf8;
use parent 'CLIO::UI::Commands::Base';

use Carp qw(croak);
use Cwd;
use CLIO::UI::Terminal qw(box_char);

=head1 NAME

CLIO::UI::Commands::Context - Context file management commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Context;
  
  my $context_cmd = CLIO::UI::Commands::Context->new(
      chat => $chat_instance,
      session => $session,
      api_manager => $api_manager,
      debug => 0
  );
  
  # Handle /context commands
  $context_cmd->handle_context_command('add', 'myfile.txt');
  $context_cmd->handle_context_command('list');
  $context_cmd->handle_context_command('clear');

=head1 DESCRIPTION

Handles context file management commands including:
- /context add <file> - Add file to conversation context
- /context list - List all context files with stats
- /context remove <file|#> - Remove file from context
- /context clear - Clear all context files

Extracted from Chat.pm to improve maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    # Assign object references separately
    $self->{session} = $args{session};
    $self->{api_manager} = $args{api_manager};
    
    bless $self, $class;
    return $self;
}


=head2 handle_context_command(@args)

Main handler for /context commands.

=cut

sub handle_context_command {
    my ($self, @args) = @_;
    
    my $action = shift @args || 'list';
    
    # Initialize context files in session if not present
    unless ($self->{session}{context_files}) {
        $self->{session}{context_files} = [];
    }
    
    if ($action eq 'add') {
        $self->_add_context_file(@args);
    }
    elsif ($action eq 'list' || $action eq 'ls') {
        $self->_list_context_files();
    }
    elsif ($action eq 'clear') {
        $self->_clear_context_files();
    }
    elsif ($action eq 'remove' || $action eq 'rm') {
        $self->_remove_context_file(@args);
    }
    else {
        $self->display_error_message("Unknown action: $action");
        $self->writeline("", markdown => 0);
        $self->writeline("Usage:", markdown => 0);
        $self->writeline("  /context add <file>      - Add file to context", markdown => 0);
        $self->writeline("  /context list            - List all context files", markdown => 0);
        $self->writeline("  /context remove <file|#> - Remove file from context", markdown => 0);
        $self->writeline("  /context clear           - Clear all context files", markdown => 0);
    }
}

=head2 _add_context_file(@args)

Add a file to the conversation context.

=cut

sub _add_context_file {
    my ($self, @args) = @_;
    
    my $file = join(' ', @args);
    unless ($file) {
        $self->display_error_message("Usage: /context add <file>");
        return;
    }
    
    # Resolve relative paths
    unless ($file =~ m{^/}) {
        my $cwd = Cwd::getcwd() || $ENV{PWD} || '.';
        $file = "$cwd/$file";
    }
    
    unless (-f $file) {
        $self->display_error_message("File not found: $file");
        return;
    }
    
    # Check if already in context
    if (grep { $_ eq $file } @{$self->{session}{context_files}}) {
        $self->display_system_message("File already in context: $file");
        return;
    }
    
    # Read file content to estimate tokens
    open my $fh, '<', $file or do {
        $self->display_error_message("Cannot read file: $!");
        return;
    };
    my $content = do { local $/; <$fh> };
    close $fh;
    
    my $tokens = int(length($content) / 4);
    
    # Add to context
    push @{$self->{session}{context_files}}, $file;
    
    # Save session to persist context
    if ($self->{session}) {
        $self->{session}->save();
    }
    
    $self->display_system_message(
        sprintf("Added to context: %s (~%s)",
            $file,
            $self->_format_tokens($tokens))
    );
}

=head2 _list_context_files()

List all context files with statistics.

=cut

sub _list_context_files {
    my ($self) = @_;
    
    my @files = @{$self->{session}{context_files}};
    
    $self->display_command_header("CONVERSATION MEMORY");
    
    # Show conversation memory stats
    if ($self->{session} && $self->{session}{state}) {
        $self->_display_memory_stats();
    }
    
    unless (@files) {
        $self->writeline("", markdown => 0);
        $self->writeline("No files in context", markdown => 0);
        $self->writeline("", markdown => 0);
        return;
    }
    
    $self->writeline("", markdown => 0);
    
    my $total_tokens = 0;
    for my $i (0 .. $#files) {
        my $file = $files[$i];
        my $tokens = 0;
        
        if (-f $file) {
            open my $fh, '<', $file;
            my $content = do { local $/; <$fh> };
            close $fh;
            $tokens = int(length($content) / 4);
            $total_tokens += $tokens;
        }
        
        $self->writeline(sprintf("%2d. %-60s %s",
            $i + 1, $file,
            $self->colorize($self->_format_tokens($tokens), 'THEME')), markdown => 0);
    }
    
    $self->writeline("", markdown => 0);
    $self->writeline(box_char('horizontal') x 62, markdown => 0);
    $self->writeline(sprintf("Total: %d files, ~%s",
        scalar(@files),
        $self->_format_tokens($total_tokens)), markdown => 0);
    $self->writeline("", markdown => 0);
}

=head2 _display_memory_stats()

Display conversation memory statistics.

=cut

sub _display_memory_stats {
    my ($self) = @_;

    my $state = $self->{session}{state};
    my $history = $state->get_history();
    my $yarn = $state->yarn();

    # Calculate stats
    my $active_messages = scalar(@$history);
    my $active_tokens = $state->get_conversation_size();

    # Get YaRN stats
    my $thread_id = $state->{session_id};
    my $yarn_thread = $yarn->get_thread($thread_id);
    my $yarn_messages = ref $yarn_thread eq 'ARRAY' ? scalar(@$yarn_thread) : 0;
    my $yarn_tokens = 0;
    if (ref $yarn_thread eq 'ARRAY') {
        require CLIO::Memory::TokenEstimator;
        for my $msg (@$yarn_thread) {
            $yarn_tokens += CLIO::Memory::TokenEstimator::estimate_tokens($msg->{content} // '');
        }
    }

    my $archived_messages = $yarn_messages > $active_messages ? $yarn_messages - $active_messages : 0;
    my $archived_tokens = $yarn_tokens > $active_tokens ? $yarn_tokens - $active_tokens : 0;

    # Last request's budget record. This is the authority: the numbers come
    # from the code that enforced the budget for that request.
    my $entries = $state->can('context_stats') ? $state->context_stats() : [];
    my $last = (@$entries) ? $entries->[-1] : undef;
    my $budget = ($last && ref($last->{budget}) eq 'HASH') ? $last->{budget} : {};
    my $breakdown = ref($budget->{breakdown}) eq 'HASH' ? $budget->{breakdown} : {};

    # Fall back to the model caps when no request has been recorded yet
    # (first turn of a session).
    my $context_window = $budget->{context_window};
    if (!defined $context_window && $self->{api_manager}) {
        my $caps = $self->{api_manager}->get_model_capabilities($self->{api_manager}->get_current_model());
        $context_window = $caps->{max_context_window_tokens} || $caps->{context_window} if $caps;
    }

    my $effective_limit = $budget->{effective_limit};
    my $trim_target = $budget->{trim_target};

    my $estimated = $budget->{estimated_after};
    $estimated = $active_tokens if !defined $estimated;

    my $status;
    if (defined $effective_limit && defined $estimated && $estimated > $effective_limit) {
        $status = $self->colorize("OVER BUDGET - next request will trim", 'ERROR');
    } elsif (defined $trim_target && defined $estimated && $estimated > $trim_target) {
        $status = $self->colorize("Within budget, above trim target", 'WARN');
    } elsif ($budget->{trimmed}) {
        $status = $self->colorize("Trimmed on the last request", 'WARN');
    } else {
        $status = $self->colorize("Healthy", 'SUCCESS');
    }

    $self->writeline("", markdown => 0);
    $self->writeline(sprintf("%-22s %d messages (~%s)",
        "Active Messages:",
        $active_messages,
        $self->_format_tokens($active_tokens)), markdown => 0);

    if ($archived_messages > 0) {
        $self->writeline(sprintf("%-22s %d messages (~%s)",
            "Archived (YaRN):",
            $archived_messages,
            $self->_format_tokens($archived_tokens)), markdown => 0);
    }

    $self->writeline("", markdown => 0);
    $self->writeline(sprintf("%-22s %s", "Model:", $last ? $last->{model} : ($self->{api_manager} ? $self->{api_manager}->get_current_model() : 'unknown')), markdown => 0);
    $self->writeline(sprintf("%-22s %s", "Context window:",
        $self->_format_tokens($context_window)), markdown => 0);

    if (%$budget) {
        $self->writeline(sprintf("%-22s %s", "Prompt budget:",
            $self->_format_tokens($budget->{prompt_budget})), markdown => 0);
        $self->writeline(sprintf("%-22s %s", "Tool schema:",
            $self->_format_tokens($budget->{tool_tokens})), markdown => 0);
        $self->writeline(sprintf("%-22s %s", "Effective limit:",
            $self->_format_tokens($budget->{effective_limit})), markdown => 0);
        $self->writeline(sprintf("%-22s %s",
            "Trim target:",
            $self->_format_tokens($budget->{trim_target})
            . sprintf(" (%d%% of the limit)", int(100 * ($budget->{trim_target} // 0) / ($budget->{effective_limit} || 1)))), markdown => 0);

        my $usage_line = $self->_format_tokens($estimated);
        $usage_line .= sprintf(" / %s", $self->_format_tokens($budget->{effective_limit}));
        if ($last && $last->{usage_prompt_tokens}) {
            $usage_line .= sprintf("  (provider reported %s",
                $self->_format_tokens($last->{usage_prompt_tokens}));
            $usage_line .= sprintf(", %s cached",
                $self->_format_tokens($last->{usage_cached_tokens}))
                if $last->{usage_cached_tokens};
            $usage_line .= ")";
        }
        $self->writeline(sprintf("%-22s %s", "Last request:", $usage_line), markdown => 0);

        if (%$breakdown) {
            my @parts;
            my $roles = ref($breakdown->{roles}) eq 'HASH' ? $breakdown->{roles} : {};
            for my $role (qw(system user assistant tool)) {
                my $slot = $roles->{$role} or next;
                push @parts, sprintf("%s %s", $role, $self->_format_tokens($slot->{total}));
            }
            $self->writeline(sprintf("%-22s %s", "Composition:", join("  |  ", @parts)), markdown => 0);

            my @field;
            push @field, sprintf("tool arguments %s", $self->_format_tokens($breakdown->{tool_call_tokens}))
                if $breakdown->{tool_call_tokens};
            push @field, sprintf("reasoning %s", $self->_format_tokens($breakdown->{reasoning_tokens}))
                if $breakdown->{reasoning_tokens};
            push @field, sprintf("tool schema %s", $self->_format_tokens($budget->{tool_tokens}))
                if $budget->{tool_tokens};
            $self->writeline(sprintf("%-22s %s", "Overhead:", join("  |  ", @field)), markdown => 0)
                if @field;
        }

        my $proj = ref($last->{projection}) eq 'HASH' ? $last->{projection} : {};
        if (%$proj) {
            my $line = sprintf("%d recent turn(s), %d message(s) kept",
                $proj->{recent_turns} // 0, $proj->{recent_messages} // 0);
            if ($proj->{dropped_messages}) {
                $line .= sprintf("; %d message(s) archived to %s",
                    $proj->{dropped_messages},
                    $self->_format_tokens(int(($proj->{compressed_tail_chars} // 0) / 4)));
            }
            $self->writeline(sprintf("%-22s %s", "Projection:", $line), markdown => 0);
        }

        if ($last && $last->{pre_api_trim}) {
            my $pre = $last->{pre_api_trim};
            $self->writeline(sprintf("%-22s dropped %d message(s) (~%s) before the call",
                "Pre-call trim:",
                $pre->{dropped_messages} // 0,
                $self->_format_tokens($pre->{dropped_estimated_tokens} // 0)), markdown => 0);
        }
    }

    $self->writeline(sprintf("%-22s %s", "Status:", $status), markdown => 0);

    if ($archived_messages > 0) {
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("YaRN Recall Available", 'DATA') . 
              " - Use [RECALL:query=<search>] to search archived history", markdown => 0);
    }
    
    $self->writeline("", markdown => 0);
    $self->writeline(box_char('horizontal') x 62, markdown => 0);
    $self->writeline($self->colorize("CONTEXT FILES", 'DATA'), markdown => 0);
    $self->writeline(box_char('horizontal') x 62, markdown => 0);
}

=head2 _clear_context_files()

Clear all context files.

=cut

sub _clear_context_files {
    my ($self) = @_;
    
    my $count = scalar(@{$self->{session}{context_files}});
    $self->{session}{context_files} = [];
    
    if ($self->{session}) {
        $self->{session}->save();
    }
    
    $self->display_system_message("Cleared $count file(s) from context");
}

=head2 _remove_context_file(@args)

Remove a file from context by name or index.

=cut

sub _remove_context_file {
    my ($self, @args) = @_;
    
    my $arg = join(' ', @args);
    
    unless ($arg) {
        $self->display_error_message("Usage: /context remove <file|index>");
        return;
    }
    
    my $removed = undef;
    
    # Check if it's a numeric index
    if ($arg =~ /^\d+$/) {
        my $index = $arg - 1;  # Convert to 0-based
        
        if ($index >= 0 && $index < @{$self->{session}{context_files}}) {
            $removed = splice(@{$self->{session}{context_files}}, $index, 1);
        } else {
            $self->display_error_message("Invalid index: $arg");
            return;
        }
    } else {
        # Try to match by filename
        my @new_files = ();
        for my $file (@{$self->{session}{context_files}}) {
            if ($file eq $arg || $file =~ /\Q$arg\E$/) {
                $removed = $file;
            } else {
                push @new_files, $file;
            }
        }
        $self->{session}{context_files} = \@new_files;
    }
    
    if ($removed) {
        if ($self->{session}) {
            $self->{session}->save();
        }
        $self->display_system_message("Removed from context: $removed");
    } else {
        $self->display_error_message("File not found in context: $arg");
    }
}

=head2 _format_tokens($count)

Format token count for display.

=cut

sub _format_tokens {
    my ($self, $count) = @_;
    
    return "Unknown" unless defined $count;
    
    if ($count >= 1000000) {
        return sprintf("%.1fM tokens", $count / 1000000);
    } elsif ($count >= 1000) {
        return sprintf("%.0fK tokens", $count / 1000);
    } else {
        return sprintf("%d tokens", $count);
    }
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut

1;
