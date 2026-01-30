package CLIO::UI::Commands::Context;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use Cwd;
use CLIO::Core::Logger qw(should_log);

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
        session => $args{session},
        api_manager => $args{api_manager},
        debug => $args{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub colorize { shift->{chat}->colorize(@_) }

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
        print "\n";
        print "Usage:\n";
        print "  /context add <file>      - Add file to context\n";
        print "  /context list            - List all context files\n";
        print "  /context remove <file|#> - Remove file from context\n";
        print "  /context clear           - Clear all context files\n";
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
        print "\nNo files in context\n";
        print "\n";
        return;
    }
    
    print "\n";
    
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
        
        printf "%2d. %-60s %s\n",
            $i + 1,
            $file,
            $self->colorize($self->_format_tokens($tokens), 'THEME');
    }
    
    print "\n";
    print "-" x 55, "\n";
    printf "Total: %d files, ~%s\n",
        scalar(@files),
        $self->_format_tokens($total_tokens);
    print "\n";
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
    
    # Get actual model max_tokens from APIManager
    my $max_tokens = 128000;  # Default fallback
    if ($self->{api_manager}) {
        my $model = $self->{api_manager}->get_current_model();
        my $caps = $self->{api_manager}->get_model_capabilities($model);
        if ($caps && $caps->{max_prompt_tokens}) {
            $max_tokens = $caps->{max_prompt_tokens};
        }
    }
    
    my $threshold = $state->{summarize_threshold} || int($max_tokens * 0.8);
    my $usage_pct = sprintf("%.1f%%", ($active_tokens / $max_tokens) * 100);
    
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
    
    # Determine status
    my $status;
    if ($active_tokens > $threshold) {
        $status = $self->colorize("TRIMMING ACTIVE (over 80%)", 'WARN');
    } elsif ($active_tokens > $threshold * 0.6) {
        $status = $self->colorize("Approaching limit (60-80%)", 'THEME');
    } else {
        $status = $self->colorize("Healthy (below 60%)", 'SUCCESS');
    }
    
    printf "\n%-24s %d messages (~%s)\n",
        "Active Messages:",
        $active_messages,
        $self->_format_tokens($active_tokens);
    
    if ($archived_messages > 0) {
        printf "%-24s %d messages (~%s)\n",
            "Archived (YaRN):",
            $archived_messages,
            $self->_format_tokens($archived_tokens);
    }
    
    printf "%-24s %s / %s (%s)\n",
        "Context Usage:",
        $self->_format_tokens($active_tokens),
        $self->_format_tokens($max_tokens),
        $usage_pct;
    
    printf "%-24s %s\n", "Status:", $status;
    
    if ($archived_messages > 0) {
        print "\n";
        print $self->colorize("YaRN Recall Available", 'DATA'), 
              " - Use [RECALL:query=<search>] to search archived history\n";
    }
    
    print "\n";
    print "-" x 55, "\n";
    print $self->colorize("CONTEXT FILES", 'DATA'), "\n";
    print "-" x 55, "\n";
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
