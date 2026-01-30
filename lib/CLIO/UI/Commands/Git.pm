package CLIO::UI::Commands::Git;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::Commands::Git - Git commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Git;
  
  my $git_cmd = CLIO::UI::Commands::Git->new(
      chat => $chat_instance,
      session => $session,
      debug => 0
  );
  
  # Handle /git commands
  $git_cmd->handle_git_command('status');
  $git_cmd->handle_git_command('diff', 'lib/CLIO/UI/Chat.pm');
  $git_cmd->handle_commit_command('fix: resolve bug');

=head1 DESCRIPTION

Handles all git-related commands including:
- /git status - Show git status
- /git diff [file] - Show git diff
- /git log [n] - Show recent commits
- /git commit [message] - Stage and commit changes

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
sub display_section_header { shift->{chat}->display_section_header(@_) }
sub display_list_item { shift->{chat}->display_list_item(@_) }
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub display_success_message { shift->{chat}->display_success_message(@_) }
sub colorize { shift->{chat}->colorize(@_) }

=head2 handle_git_command($action, @args)

Main dispatcher for /git commands.

=cut

sub handle_git_command {
    my ($self, $action, @args) = @_;
    
    $action ||= '';
    $action = lc($action);
    
    # /git (no args) - show help
    if ($action eq '' || $action eq 'help') {
        $self->_display_git_help();
        return;
    }
    
    # /git status
    if ($action eq 'status' || $action eq 'st') {
        $self->handle_status_command(@args);
        return;
    }
    
    # /git diff [file]
    if ($action eq 'diff') {
        $self->handle_diff_command(@args);
        return;
    }
    
    # /git log [n]
    if ($action eq 'log') {
        $self->handle_gitlog_command(@args);
        return;
    }
    
    # /git commit [message]
    if ($action eq 'commit') {
        $self->handle_commit_command(@args);
        return;
    }
    
    # Unknown action
    $self->display_error_message("Unknown action: /git $action");
    $self->_display_git_help();
}

=head2 _display_git_help

Display help for /git commands

=cut

sub _display_git_help {
    my ($self) = @_;
    
    $self->display_command_header("GIT COMMANDS");
    
    $self->display_list_item("/git status - Show git status");
    $self->display_list_item("/git diff [file] - Show git diff");
    $self->display_list_item("/git log [n] - Show recent commits (default: 10)");
    $self->display_list_item("/git commit [msg] - Stage and commit changes");
    
    print "\n";
    $self->display_section_header("EXAMPLES");
    print "  /git status                          # See changes\n";
    print "  /git diff lib/CLIO/UI/Chat.pm        # Diff specific file\n";
    print "  /git log 5                           # Last 5 commits\n";
    print "  /git commit \"fix: resolve bug\"       # Commit with message\n";
    print "\n";
}

=head2 handle_status_command

Show git status

=cut

sub handle_status_command {
    my ($self, @args) = @_;
    
    my $output = `git status 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Git error: $output");
        return;
    }
    
    $self->display_command_header("GIT STATUS");
    print $output;
    print "\n";
}

=head2 handle_diff_command

Show git diff

=cut

sub handle_diff_command {
    my ($self, @args) = @_;
    
    my $file = join(' ', @args) || '';
    my $cmd = $file ? "git diff -- '$file'" : "git diff";
    
    my $output = `$cmd 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Git error: $output");
        return;
    }
    
    unless ($output) {
        $self->display_system_message("No changes to display");
        return;
    }
    
    print "\n";
    print "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", "\n";
    my $header = "GIT DIFF" . ($file ? " - $file" : "");
    $self->display_command_header($header);
    print $output;
    print "\n";
}

=head2 handle_gitlog_command

Show recent git commits

=cut

sub handle_gitlog_command {
    my ($self, @args) = @_;
    
    my $count = $args[0] || 10;
    
    # Validate count is a number
    unless ($count =~ /^\d+$/) {
        $self->display_error_message("Invalid count: $count (must be a number)");
        return;
    }
    
    my $output = `git log --oneline -$count 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Git error: $output");
        return;
    }
    
    $self->display_command_header("GIT LOG (last $count commits)");
    print $output;
    print "\n";
}

=head2 handle_commit_command

Stage and commit changes

=cut

sub handle_commit_command {
    my ($self, @args) = @_;
    
    # Check if there are changes to commit
    my $status = `git status --porcelain 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Git error: $status");
        return;
    }
    
    unless ($status) {
        $self->display_system_message("No changes to commit");
        return;
    }
    
    my $message = join(' ', @args);
    
    # If no message provided, prompt for one
    unless ($message) {
        print "\n";
        print $self->colorize("Enter commit message (empty to cancel):", 'PROMPT'), "\n";
        print "> ";
        $message = <STDIN>;
        chomp $message if defined $message;
        
        unless ($message && length($message) > 0) {
            $self->display_system_message("Commit cancelled");
            return;
        }
    }
    
    # Stage all changes
    my $add_output = `git add -A 2>&1`;
    $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Failed to stage changes: $add_output");
        return;
    }
    
    # Commit - escape single quotes in message
    $message =~ s/'/'\\''/g;
    my $commit_output = `git commit -m '$message' 2>&1`;
    $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Commit failed: $commit_output");
        return;
    }
    
    $self->display_command_header("GIT COMMIT");
    print $commit_output;
    print "\n";
    
    $self->display_success_message("Changes committed successfully");
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
