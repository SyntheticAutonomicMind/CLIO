package CLIO::UI::Commands::Memory;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::Commands::Memory - Long-term memory commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Memory;
  
  my $memory_cmd = CLIO::UI::Commands::Memory->new(
      chat => $chat_instance,
      session => $session,
      debug => 0
  );
  
  # Handle /memory commands
  $memory_cmd->handle_memory_command('list');
  $memory_cmd->handle_memory_command('list', 'discovery');
  $memory_cmd->handle_memory_command('clear');

=head1 DESCRIPTION

Handles long-term memory (LTM) management commands including:
- /memory [list|ls] [type] - List all patterns
- /memory store <type> [data] - Store a new pattern (via AI)
- /memory clear - Clear all LTM patterns

Types: discovery, solution, pattern, workflow, failure, rule

Extracted from Chat.pm to improve maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    # Assign object references separately (hash literal assignment bug workaround)
    $self->{session} = $args{session};
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_info_message { shift->{chat}->display_info_message(@_) }
sub display_warning_message { shift->{chat}->display_warning_message(@_) }
sub display_success_message { shift->{chat}->display_success_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub writeline { shift->{chat}->writeline(@_) }
sub display_list_item { shift->{chat}->display_list_item(@_) }
sub colorize { shift->{chat}->colorize(@_) }

=head2 handle_memory_command(@args)

Main handler for /memory commands.

=cut

sub handle_memory_command {
    my ($self, @args) = @_;
    
    unless ($self->{session}) {
        $self->display_error_message("No active session");
        return;
    }
    
    # Get LTM from session
    my $ltm = eval { $self->{session}->get_long_term_memory() };
    if ($@ || !$ltm) {
        $self->display_error_message("Long-term memory not available: $@");
        return;
    }
    
    # Parse subcommand
    my $subcmd = @args ? lc($args[0]) : 'list';
    
    if ($subcmd eq 'list' || $subcmd eq 'ls' || $subcmd eq '' || $subcmd eq 'help') {
        my $filter_type = $args[1] ? lc($args[1]) : undef;
        $self->_list_patterns($ltm, $filter_type);
    }
    elsif ($subcmd eq 'store') {
        return $self->_store_pattern(@args[1..$#args]);
    }
    elsif ($subcmd eq 'clear') {
        $self->_clear_patterns($ltm);
    }
    elsif ($subcmd eq 'prune') {
        $self->_prune_patterns($ltm, @args[1..$#args]);
    }
    elsif ($subcmd eq 'stats') {
        $self->_show_stats($ltm);
    }
    else {
        $self->display_error_message("Unknown subcommand: $subcmd");
        $self->writeline("Usage:", markdown => 0);
        $self->display_list_item("/memory [list|ls] [type] - List patterns");
        $self->display_list_item("/memory store <type> [data] - Store pattern (requires AI)");
        $self->display_list_item("/memory prune [max_age_days] - Prune old/low-confidence entries");
        $self->display_list_item("/memory stats - Show LTM statistics");
        $self->display_list_item("/memory clear - Clear all patterns");
    }
}

=head2 _list_patterns($ltm, $filter_type)

List all LTM patterns, optionally filtered by type.

=cut

sub _list_patterns {
    my ($self, $ltm, $filter_type) = @_;
    
    # Gather all patterns
    my @all_patterns;
    
    # Discoveries
    my $discoveries = eval { $ltm->query_discoveries() } || [];
    for my $item (@$discoveries) {
        push @all_patterns, { type => 'discovery', data => $item };
    }
    
    # Solutions
    my $solutions = eval { $ltm->query_solutions() } || [];
    for my $item (@$solutions) {
        push @all_patterns, { type => 'solution', data => $item };
    }
    
    # Patterns
    my $patterns = eval { $ltm->query_patterns() } || [];
    for my $item (@$patterns) {
        push @all_patterns, { type => 'pattern', data => $item };
    }
    
    # Workflows
    my $workflows = eval { $ltm->query_workflows() } || [];
    for my $item (@$workflows) {
        push @all_patterns, { type => 'workflow', data => $item };
    }
    
    # Failures
    my $failures = eval { $ltm->query_failures() } || [];
    for my $item (@$failures) {
        push @all_patterns, { type => 'failure', data => $item };
    }
    
    # Context rules
    my $rules = eval { $ltm->query_context_rules() } || [];
    for my $item (@$rules) {
        push @all_patterns, { type => 'rule', data => $item };
    }
    
    # Filter by type if specified
    if ($filter_type) {
        @all_patterns = grep { $_->{type} eq $filter_type } @all_patterns;
    }
    
    # Display
    $self->display_command_header("LONG-TERM MEMORY PATTERNS");
    
    if (@all_patterns == 0) {
        $self->display_info_message("No patterns stored yet");
        $self->writeline("", markdown => 0);
        $self->writeline("Use /memory store <type> to add patterns:", markdown => 0);
        $self->display_list_item("Types: discovery, solution, pattern, workflow, failure, rule");
        $self->writeline("", markdown => 0);
    } else {
        my $total_str = sprintf("Total: %d pattern%s", scalar(@all_patterns), (@all_patterns == 1 ? '' : 's'));
        $total_str .= " (filtered by: $filter_type)" if $filter_type;
        $self->writeline($total_str, markdown => 0);
        $self->writeline("", markdown => 0);
        
        for my $entry (@all_patterns) {
            $self->_display_pattern($entry);
        }
    }
}

=head2 _display_pattern($entry)

Display a single pattern entry.

=cut

sub _display_pattern {
    my ($self, $entry) = @_;
    
    my $type = uc($entry->{type});
    my $data = $entry->{data};
    
    my $header = $self->colorize("[$type] ", 'command_subheader') .
                 $self->colorize($data->{title} || 'Untitled', 'command_value');
    $self->writeline($header, markdown => 0);
    
    if ($entry->{type} eq 'discovery') {
        $self->writeline("  " . ($data->{content} || 'No content'), markdown => 0);
        $self->writeline($self->colorize("  Context: " . ($data->{context} || 'None'), 'muted'), markdown => 0) if $data->{context};
    }
    elsif ($entry->{type} eq 'solution') {
        $self->writeline("  Problem: " . ($data->{problem} || 'Not specified'), markdown => 0);
        $self->writeline("  Solution: " . ($data->{solution} || 'Not specified'), markdown => 0);
    }
    elsif ($entry->{type} eq 'pattern') {
        $self->writeline("  " . ($data->{pattern} || 'No pattern'), markdown => 0);
        $self->writeline($self->colorize("  Usage: " . ($data->{usage} || 'None'), 'muted'), markdown => 0) if $data->{usage};
    }
    elsif ($entry->{type} eq 'workflow') {
        my $steps = $data->{steps} || [];
        if (ref($steps) eq 'ARRAY' && @$steps) {
            my $num = 1;
            for my $step (@$steps) {
                $self->display_list_item($step, $num);
                $num++;
            }
        }
    }
    elsif ($entry->{type} eq 'failure') {
        $self->writeline("  Mistake: " . ($data->{mistake} || 'Not specified'), markdown => 0);
        $self->writeline("  Lesson: " . ($data->{lesson} || 'Not specified'), markdown => 0);
    }
    elsif ($entry->{type} eq 'rule') {
        $self->writeline("  Condition: " . ($data->{condition} || 'Not specified'), markdown => 0);
        $self->writeline("  Action: " . ($data->{action} || 'Not specified'), markdown => 0);
    }
    
    $self->writeline("", markdown => 0);
}

=head2 _store_pattern(@args)

Store a new pattern (returns prompt for AI).

=cut

sub _store_pattern {
    my ($self, @args) = @_;
    
    my $type = $args[0] || '';
    my $data_text = join(' ', @args[1..$#args]);
    
    my $prompt = "Please store this in long-term memory:\n";
    $prompt .= "Type: $type\n" if $type;
    $prompt .= "Data: $data_text\n" if $data_text;
    $prompt .= "\nUse the memory_operations tool to store this pattern.";
    
    $self->display_info_message("Requesting AI to store pattern in long-term memory...");
    return (1, $prompt);  # Return prompt to be sent to AI
}

=head2 _clear_patterns($ltm)

Clear all LTM patterns after confirmation.

=cut

sub _clear_patterns {
    my ($self, $ltm) = @_;
    
    $self->writeline("", markdown => 0);
    $self->display_warning_message("This will clear ALL long-term memory patterns for this project!");
    print "Are you sure? (yes/no): ";
    
    my $response = <STDIN>;
    chomp $response;
    
    if (lc($response) eq 'yes') {
        eval {
            require CLIO::Memory::LongTerm;
            my $new_ltm = CLIO::Memory::LongTerm->new(
                project_root => $ltm->{project_root},
                debug => $ltm->{debug}
            );
            $new_ltm->save();
            $self->{session}{ltm} = $new_ltm;
        };
        
        if ($@) {
            $self->display_error_message("Failed to clear LTM: $@");
        } else {
            $self->display_success_message("Long-term memory cleared successfully");
        }
    } else {
        $self->display_info_message("Cancelled - no changes made");
    }
}

=head2 _prune_patterns($ltm, @args)

Prune old and low-confidence LTM entries.

=cut

sub _prune_patterns {
    my ($self, $ltm, @args) = @_;
    
    # Parse optional max_age_days argument
    my $max_age_days = 90;
    if (@args && $args[0] =~ /^\d+$/) {
        $max_age_days = int($args[0]);
    }
    
    # Get stats before
    my $before = $ltm->get_stats();
    my $before_total = $before->{discoveries} + $before->{solutions} + 
                       $before->{patterns} + $before->{workflows} + $before->{failures};
    
    $self->display_command_header("LTM PRUNING");
    $self->writeline("Before: $before_total entries", markdown => 0);
    $self->writeline("Settings: max_age_days=$max_age_days, min_confidence=0.3", markdown => 0);
    $self->writeline("", markdown => 0);
    
    # Perform pruning
    my $removed = $ltm->prune(max_age_days => $max_age_days);
    
    # Get stats after
    my $after = $ltm->get_stats();
    my $after_total = $after->{discoveries} + $after->{solutions} + 
                      $after->{patterns} + $after->{workflows} + $after->{failures};
    
    # Display results
    $self->writeline("Removed:", markdown => 0);
    $self->writeline("  Discoveries: $removed->{discoveries}", markdown => 0) if $removed->{discoveries};
    $self->writeline("  Solutions:   $removed->{solutions}", markdown => 0) if $removed->{solutions};
    $self->writeline("  Patterns:    $removed->{patterns}", markdown => 0) if $removed->{patterns};
    $self->writeline("  Workflows:   $removed->{workflows}", markdown => 0) if $removed->{workflows};
    $self->writeline("  Failures:    $removed->{failures}", markdown => 0) if $removed->{failures};
    
    my $total_removed = $removed->{discoveries} + $removed->{solutions} + 
                        $removed->{patterns} + $removed->{workflows} + $removed->{failures};
    
    if ($total_removed == 0) {
        $self->display_info_message("No entries needed pruning");
    } else {
        # Save the pruned LTM
        eval {
            my $ltm_file = $ltm->{_file_path} || '.clio/ltm.json';
            $ltm->save($ltm_file);
        };
        
        if ($@) {
            $self->display_error_message("Pruned but failed to save: $@");
        } else {
            $self->display_success_message("Pruned $total_removed entries (now $after_total total)");
        }
    }
}

=head2 _show_stats($ltm)

Show LTM statistics.

=cut

sub _show_stats {
    my ($self, $ltm) = @_;
    
    my $stats = $ltm->get_stats();
    
    $self->display_command_header("LTM STATISTICS");
    
    $self->writeline("Entries:", markdown => 0);
    $self->writeline(sprintf("  Discoveries:    %3d", $stats->{discoveries}), markdown => 0);
    $self->writeline(sprintf("  Solutions:      %3d", $stats->{solutions}), markdown => 0);
    $self->writeline(sprintf("  Code Patterns:  %3d", $stats->{patterns}), markdown => 0);
    $self->writeline(sprintf("  Workflows:      %3d", $stats->{workflows}), markdown => 0);
    $self->writeline(sprintf("  Failures:       %3d", $stats->{failures}), markdown => 0);
    $self->writeline(sprintf("  Context Rules:  %3d", $stats->{context_rules}), markdown => 0);
    
    my $total = $stats->{discoveries} + $stats->{solutions} + $stats->{patterns} + 
                $stats->{workflows} + $stats->{failures};
    $self->writeline("  " . "-" x 20, markdown => 0);
    $self->writeline(sprintf("  Total:          %3d", $total), markdown => 0);
    $self->writeline("", markdown => 0);
    
    # Timestamps
    if ($stats->{created}) {
        my @t = localtime($stats->{created});
        printf "Created:      %04d-%02d-%02d %02d:%02d\n", 
            $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1];
    }
    if ($stats->{last_updated}) {
        my @t = localtime($stats->{last_updated});
        printf "Last updated: %04d-%02d-%02d %02d:%02d\n",
            $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1];
    }
    if ($stats->{last_pruned}) {
        my @t = localtime($stats->{last_pruned});
        printf "Last pruned:  %04d-%02d-%02d %02d:%02d\n",
            $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1];
    }
    
    $self->writeline("", markdown => 0);
    $self->display_info_message("Use '/memory prune [days]' to remove old entries");
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
