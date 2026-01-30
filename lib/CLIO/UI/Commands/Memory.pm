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
        session => $args{session},
        debug => $args{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_info_message { shift->{chat}->display_info_message(@_) }
sub display_warning_message { shift->{chat}->display_warning_message(@_) }
sub display_success_message { shift->{chat}->display_success_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
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
    else {
        $self->display_error_message("Unknown subcommand: $subcmd");
        print "Usage:\n";
        $self->display_list_item("/memory [list|ls] [type] - List patterns");
        $self->display_list_item("/memory store <type> [data] - Store pattern (requires AI)");
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
        print "\n";
        print "Use /memory store <type> to add patterns:\n";
        $self->display_list_item("Types: discovery, solution, pattern, workflow, failure, rule");
        print "\n";
    } else {
        printf "Total: %d pattern%s", scalar(@all_patterns), (@all_patterns == 1 ? '' : 's');
        print " (filtered by: $filter_type)" if $filter_type;
        print "\n\n";
        
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
    
    print $self->colorize("[$type] ", 'command_subheader');
    print $self->colorize($data->{title} || 'Untitled', 'command_value'), "\n";
    
    if ($entry->{type} eq 'discovery') {
        print "  " . ($data->{content} || 'No content') . "\n";
        print $self->colorize("  Context: " . ($data->{context} || 'None'), 'muted'), "\n" if $data->{context};
    }
    elsif ($entry->{type} eq 'solution') {
        print "  Problem: " . ($data->{problem} || 'Not specified') . "\n";
        print "  Solution: " . ($data->{solution} || 'Not specified') . "\n";
    }
    elsif ($entry->{type} eq 'pattern') {
        print "  " . ($data->{pattern} || 'No pattern') . "\n";
        print $self->colorize("  Usage: " . ($data->{usage} || 'None'), 'muted'), "\n" if $data->{usage};
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
        print "  Mistake: " . ($data->{mistake} || 'Not specified') . "\n";
        print "  Lesson: " . ($data->{lesson} || 'Not specified') . "\n";
    }
    elsif ($entry->{type} eq 'rule') {
        print "  Condition: " . ($data->{condition} || 'Not specified') . "\n";
        print "  Action: " . ($data->{action} || 'Not specified') . "\n";
    }
    
    print "\n";
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
    
    print "\n";
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

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
