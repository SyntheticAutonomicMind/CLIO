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
        debug => $args{debug} // 0,
    };
    
    # Assign object references separately (hash literal assignment bug workaround)
    $self->{session} = $args{session};
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_section_header { shift->{chat}->display_section_header(@_) }
sub display_command_row { shift->{chat}->display_command_row(@_) }
sub display_list_item { shift->{chat}->display_list_item(@_) }
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub writeline { shift->{chat}->writeline(@_) }
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

Display help for /git commands using unified style.

=cut

sub _display_git_help {
    my ($self) = @_;
    
    $self->display_command_header("GIT");
    
    $self->display_section_header("COMMANDS");
    $self->display_command_row("/git status", "Show git status", 25);
    $self->display_command_row("/git diff [file]", "Show git diff", 25);
    $self->display_command_row("/git log [n]", "Show recent commits (default: 10)", 25);
    $self->display_command_row("/git commit [msg]", "Stage and commit changes", 25);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("EXAMPLES");
    $self->display_command_row("/git status", "See changes", 30);
    $self->display_command_row("/git diff lib/CLIO.pm", "Diff specific file", 30);
    $self->display_command_row("/git log 5", "Last 5 commits", 30);
    $self->display_command_row("/git commit \"fix: bug\"", "Commit with message", 30);
    $self->writeline("", markdown => 0);
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
    for my $line (split /\n/, $output) {
        $self->writeline($line, markdown => 0);
    }
    $self->writeline("", markdown => 0);
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
    
    $self->writeline("", markdown => 0);
    $self->writeline("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", markdown => 0);
    my $header = "GIT DIFF" . ($file ? " - $file" : "");
    $self->display_command_header($header);
    for my $line (split /\n/, $output) {
        $self->writeline($line, markdown => 0);
    }
    $self->writeline("", markdown => 0);
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
    for my $line (split /\n/, $output) {
        $self->writeline($line, markdown => 0);
    }
    $self->writeline("", markdown => 0);
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
        $self->writeline("", markdown => 0);
        # Interactive prompt - use standardized input prompt
        print $self->{chat}{theme_mgr}->get_input_prompt("Enter commit message", "cancel") . "\n";
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
    for my $line (split /\n/, $commit_output) {
        $self->writeline($line, markdown => 0);
    }
    $self->writeline("", markdown => 0);
    
    $self->display_success_message("Changes committed successfully");
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
