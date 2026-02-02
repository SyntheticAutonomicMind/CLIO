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

List all LTM patterns with proper formatting and pagination.

=cut

sub _list_patterns {
    my ($self, $ltm, $filter_type) = @_;
    
    # Gather all patterns by type
    my %by_type = (
        discovery => eval { $ltm->query_discoveries() } || [],
        solution  => eval { $ltm->query_solutions() } || [],
        pattern   => eval { $ltm->query_patterns() } || [],
        workflow  => eval { $ltm->query_workflows() } || [],
        failure   => eval { $ltm->query_failures() } || [],
        rule      => eval { $ltm->query_context_rules() } || [],
    );
    
    # Filter by type if specified
    if ($filter_type) {
        my %filtered;
        $filtered{$filter_type} = $by_type{$filter_type} if exists $by_type{$filter_type};
        %by_type = %filtered;
    }
    
    # Count total items
    my $total = 0;
    for my $type (keys %by_type) {
        $total += scalar(@{$by_type{$type}});
    }
    
    $self->display_command_header("LONG-TERM MEMORY");
    
    if ($total == 0) {
        $self->display_info_message("No patterns stored");
        $self->writeline("", markdown => 0);
        $self->writeline("Use " . $self->colorize("/memory store <type>", 'help_command') . " to add patterns:", markdown => 0);
        $self->display_list_item("Types: discovery, solution, pattern, workflow, failure, rule");
        $self->writeline("", markdown => 0);
        return;
    }
    
    # Build summary line
    my @counts;
    for my $type (qw(discovery solution pattern workflow failure rule)) {
        my $count = scalar(@{$by_type{$type} || []});
        push @counts, "$count $type" . ($count == 1 ? '' : 's') if $count > 0;
    }
    
    $self->writeline($self->colorize("Total: ", 'LABEL') . $self->colorize($total, 'DATA') . " entries (" . join(", ", @counts) . ")", markdown => 0);
    $self->writeline("", markdown => 0);
    
    # Display each type as a section
    my %type_labels = (
        discovery => 'DISCOVERIES',
        solution  => 'SOLUTIONS',
        pattern   => 'PATTERNS',
        workflow  => 'WORKFLOWS',
        failure   => 'FAILURES',
        rule      => 'CONTEXT RULES',
    );
    
    for my $type (qw(discovery solution pattern workflow failure rule)) {
        my $items = $by_type{$type} || [];
        next unless @$items;
        
        $self->{chat}->display_section_header($type_labels{$type});
        
        for my $i (0 .. $#$items) {
            my $item = $items->[$i];
            $self->_display_pattern_compact($type, $item, $i + 1);
        }
        
        $self->writeline("", markdown => 0);
    }
}

=head2 _display_pattern_compact($type, $data, $index)

Display a single pattern entry in compact format.

=cut

sub _display_pattern_compact {
    my ($self, $type, $data, $index) = @_;
    
    # Format index
    my $idx = $self->colorize(sprintf("%2d)", $index), 'DIM');
    
    if ($type eq 'discovery') {
        # Discovery: show the fact, truncated
        my $fact = $data->{fact} || $data->{content} || '(no content)';
        $fact =~ s/\n.*//s;  # First line only
        $fact = substr($fact, 0, 70) . '...' if length($fact) > 70;
        
        my $confidence = $data->{confidence} ? sprintf(" [%.0f%%]", $data->{confidence} * 100) : "";
        $self->writeline("$idx " . $self->colorize($fact, 'command_value') . $self->colorize($confidence, 'DIM'), markdown => 0);
    }
    elsif ($type eq 'solution') {
        # Solution: show problem/solution pair
        my $problem = $data->{error} || $data->{problem} || '(no problem specified)';
        $problem =~ s/\n.*//s;
        $problem = substr($problem, 0, 60) . '...' if length($problem) > 60;
        
        my $solution = $data->{solution} || '(no solution)';
        $solution =~ s/\n.*//s;
        $solution = substr($solution, 0, 50) . '...' if length($solution) > 50;
        
        $self->writeline("$idx " . $self->colorize("Problem: ", 'LABEL') . $problem, markdown => 0);
        $self->writeline("    " . $self->colorize("Fix: ", 'SUCCESS') . $solution, markdown => 0);
    }
    elsif ($type eq 'pattern') {
        # Pattern: show the pattern description
        my $pattern = $data->{pattern} || '(no pattern)';
        $pattern =~ s/\n.*//s;
        $pattern = substr($pattern, 0, 70) . '...' if length($pattern) > 70;
        
        my $confidence = $data->{confidence} ? sprintf(" [%.0f%%]", $data->{confidence} * 100) : "";
        $self->writeline("$idx " . $self->colorize($pattern, 'command_value') . $self->colorize($confidence, 'DIM'), markdown => 0);
    }
    elsif ($type eq 'workflow') {
        # Workflow: show title and step count
        my $title = $data->{title} || $data->{name} || '(untitled workflow)';
        my $steps = $data->{steps} || [];
        my $step_count = ref($steps) eq 'ARRAY' ? scalar(@$steps) : 0;
        
        $self->writeline("$idx " . $self->colorize($title, 'command_value') . 
                         $self->colorize(" ($step_count steps)", 'DIM'), markdown => 0);
    }
    elsif ($type eq 'failure') {
        # Failure: show mistake and lesson
        my $mistake = $data->{mistake} || '(no mistake)';
        $mistake =~ s/\n.*//s;
        $mistake = substr($mistake, 0, 50) . '...' if length($mistake) > 50;
        
        my $lesson = $data->{lesson} || '(no lesson)';
        $lesson =~ s/\n.*//s;
        $lesson = substr($lesson, 0, 50) . '...' if length($lesson) > 50;
        
        $self->writeline("$idx " . $self->colorize("Mistake: ", 'ERROR') . $mistake, markdown => 0);
        $self->writeline("    " . $self->colorize("Lesson: ", 'SUCCESS') . $lesson, markdown => 0);
    }
    elsif ($type eq 'rule') {
        # Rule: show condition and action
        my $condition = $data->{condition} || '(no condition)';
        $condition =~ s/\n.*//s;
        $condition = substr($condition, 0, 50) . '...' if length($condition) > 50;
        
        my $action = $data->{action} || '(no action)';
        $action =~ s/\n.*//s;
        $action = substr($action, 0, 50) . '...' if length($action) > 50;
        
        $self->writeline("$idx " . $self->colorize("When: ", 'LABEL') . $condition, markdown => 0);
        $self->writeline("    " . $self->colorize("Then: ", 'SUCCESS') . $action, markdown => 0);
    }
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
    
    # Display confirmation prompt using theme
    my ($header, $input_line) = @{$self->{chat}{theme_mgr}->get_confirmation_prompt(
        "Clear all patterns?",
        "yes/no",
        "cancel"
    )};
    
    print $header, "\n";
    print $input_line;
    
    my $response = <STDIN>;
    chomp $response if defined $response;
    
    if ($response && $response =~ /^y(es)?$/i) {
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
