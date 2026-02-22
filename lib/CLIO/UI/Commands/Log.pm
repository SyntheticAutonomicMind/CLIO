package CLIO::UI::Commands::Log;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use JSON::PP;

=head1 NAME

CLIO::UI::Commands::Log - Tool operation log commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Log;
  
  my $log_cmd = CLIO::UI::Commands::Log->new(
      chat => $chat_instance,
      session => $session,
      debug => 0
  );
  
  # Handle /log commands
  $log_cmd->handle_log_command();
  $log_cmd->handle_log_command('filter', 'file_operations');
  $log_cmd->handle_log_command('search', 'create');

=head1 DESCRIPTION

Handles tool operation log commands including:
- /log [n] - Show last n tool operations (default 20)
- /log filter <tool> - Filter by tool name
- /log search <pattern> - Search operations
- /log session - Show current session operations

Extracted from Chat.pm to improve maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
        tool_logger => undef,
    };
    
    # Assign object references separately
    $self->{session} = $args{session};
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub colorize { shift->{chat}->colorize(@_) }
sub writeline { shift->{chat}->writeline(@_) }

=head2 _get_tool_logger()

Lazy initialize and return the tool logger.

=cut

sub _get_tool_logger {
    my ($self) = @_;
    
    unless ($self->{tool_logger}) {
        require CLIO::Logging::ToolLogger;
        my $session_id = $self->{session} ? $self->{session}->{session_id} : 'unknown';
        $self->{tool_logger} = CLIO::Logging::ToolLogger->new(
            session_id => $session_id,
            debug => $self->{debug}
        );
    }
    
    return $self->{tool_logger};
}

=head2 handle_log_command(@args)

Main handler for /log commands.

=cut

sub handle_log_command {
    my ($self, @args) = @_;
    
    my $subcommand = $args[0] || '';
    
    # /log filter <tool>
    if ($subcommand eq 'filter' && $args[1]) {
        $self->display_tool_log_filter($args[1]);
    }
    # /log search <pattern>
    elsif ($subcommand eq 'search' && $args[1]) {
        $self->display_tool_log_search(join(' ', @args[1..$#args]));
    }
    # /log session
    elsif ($subcommand eq 'session') {
        $self->display_tool_log_session();
    }
    # /log [n] - show last n operations
    else {
        my $count = 20;  # default
        if ($subcommand =~ /^\d+$/) {
            $count = $subcommand;
        }
        $self->display_tool_log_recent($count);
    }
}

=head2 display_tool_log_recent($count)

Display recent tool operations.

=cut

sub display_tool_log_recent {
    my ($self, $count) = @_;
    
    my $logger = $self->_get_tool_logger();
    my $entries = $logger->get_recent($count);
    
    unless ($entries && @$entries) {
        $self->display_system_message("No tool operations logged yet");
        return;
    }
    
    $self->writeline("", markdown => 0);
    $self->writeline("─" x 62, markdown => 0);
    $self->writeline($self->colorize("TOOL OPERATIONS (last $count)", 'DATA'), markdown => 0);
    $self->writeline("─" x 62, markdown => 0);
    
    for my $entry (@$entries) {
        $self->_display_tool_log_entry($entry);
    }
}

=head2 display_tool_log_filter($tool_name)

Display tool operations filtered by tool name.

=cut

sub display_tool_log_filter {
    my ($self, $tool_name) = @_;
    
    my $logger = $self->_get_tool_logger();
    my $entries = $logger->filter(tool => $tool_name);
    
    unless ($entries && @$entries) {
        $self->display_system_message("No operations found for tool: $tool_name");
        return;
    }
    
    $self->writeline("", markdown => 0);
    $self->writeline("─" x 62, markdown => 0);
    $self->writeline($self->colorize("TOOL OPERATIONS - $tool_name (" . scalar(@$entries) . " found)", 'DATA'), markdown => 0);
    $self->writeline("─" x 62, markdown => 0);
    
    for my $entry (reverse @$entries) {
        $self->_display_tool_log_entry($entry);
    }
}

=head2 display_tool_log_search($pattern)

Search tool operations.

=cut

sub display_tool_log_search {
    my ($self, $pattern) = @_;
    
    my $logger = $self->_get_tool_logger();
    my $entries = $logger->search($pattern);
    
    unless ($entries && @$entries) {
        $self->display_system_message("No operations found matching: $pattern");
        return;
    }
    
    $self->writeline("", markdown => 0);
    $self->writeline("─" x 62, markdown => 0);
    $self->writeline($self->colorize("TOOL OPERATIONS - search '$pattern' (" . scalar(@$entries) . " found)", 'DATA'), markdown => 0);
    $self->writeline("─" x 62, markdown => 0);
    
    for my $entry (reverse @$entries) {
        $self->_display_tool_log_entry($entry);
    }
}

=head2 display_tool_log_session()

Display tool operations for current session.

=cut

sub display_tool_log_session {
    my ($self) = @_;
    
    my $session_id = $self->{session} ? $self->{session}->{session_id} : 'unknown';
    my $logger = $self->_get_tool_logger();
    my $entries = $logger->filter(session => $session_id);
    
    unless ($entries && @$entries) {
        $self->display_system_message("No operations in current session");
        return;
    }
    
    $self->writeline("", markdown => 0);
    $self->writeline("─" x 62, markdown => 0);
    $self->writeline($self->colorize("TOOL OPERATIONS - session $session_id (" . scalar(@$entries) . " ops)", 'DATA'), markdown => 0);
    $self->writeline("─" x 62, markdown => 0);
    
    for my $entry (reverse @$entries) {
        $self->_display_tool_log_entry($entry);
    }
}

=head2 _display_tool_log_entry($entry)

Display a single tool log entry.

=cut

sub _display_tool_log_entry {
    my ($self, $entry) = @_;
    
    $self->writeline("", markdown => 0);
    
    # Header line with timestamp and tool
    my $status_icon = $entry->{success} ? 'OK' : 'FAIL';
    my $status_color = $entry->{success} ? 'SUCCESS' : 'ERROR';
    
    my $header = $self->colorize("[$entry->{timestamp}] ", 'DIM') .
                 $self->colorize("$status_icon ", $status_color) .
                 $self->colorize("$entry->{tool_name}", 'TOOL');
    if ($entry->{operation}) {
        $header .= $self->colorize("/$entry->{operation}", 'PROMPT');
    }
    $self->writeline($header, markdown => 0);
    
    # Action description
    if ($entry->{action_description}) {
        $self->writeline("  " . $self->colorize($entry->{action_description}, 'DATA'), markdown => 0);
    }
    
    # Parameters (compact JSON)
    if ($entry->{parameters} && ref($entry->{parameters}) eq 'HASH') {
        my $params_json = JSON::PP->new->canonical->encode($entry->{parameters});
        # Truncate if too long
        if (length($params_json) > 100) {
            $params_json = substr($params_json, 0, 97) . "...";
        }
        $self->writeline("  " . $self->colorize("Params: ", 'DIM') . $params_json, markdown => 0);
    }
    
    # Execution time
    if ($entry->{execution_time_ms}) {
        $self->writeline("  " . $self->colorize("Time: ", 'DIM') . "$entry->{execution_time_ms}ms", markdown => 0);
    }
    
    # Error message if failed
    if (!$entry->{success} && $entry->{error}) {
        $self->writeline("  " . $self->colorize("Error: ", 'ERROR') . $entry->{error}, markdown => 0);
    }
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
