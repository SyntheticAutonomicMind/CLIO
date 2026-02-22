package CLIO::UI::Commands::Git;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);

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

Handles all git-related commands:

Query Operations:
- /git status - Show git status
- /git diff [file] - Show git diff
- /git log [n] - Show recent commits

Branch Operations:
- /git branch - List branches
- /git branch <name> - Create new branch
- /git switch <name> - Switch to branch
- /git branch -d <name> - Delete branch

Remote Operations:
- /git push [remote] [branch] - Push changes
- /git pull [remote] [branch] - Pull changes

Commit Operations:
- /git commit [message] - Stage and commit changes

History/Utility:
- /git blame <file> - Show who changed each line
- /git stash - List stashes
- /git stash save [msg] - Stash changes
- /git stash apply [n] - Apply stash
- /git stash drop [n] - Delete stash
- /git tag - List tags
- /git tag <name> - Create tag
- /git tag -d <name> - Delete tag

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
    
    # /git branch [name|-d name]
    if ($action eq 'branch') {
        $self->handle_branch_command(@args);
        return;
    }
    
    # /git switch <name>
    if ($action eq 'switch') {
        $self->handle_switch_command(@args);
        return;
    }
    
    # /git push [remote] [branch]
    if ($action eq 'push') {
        $self->handle_push_command(@args);
        return;
    }
    
    # /git pull [remote] [branch]
    if ($action eq 'pull') {
        $self->handle_pull_command(@args);
        return;
    }
    
    # /git blame <file>
    if ($action eq 'blame') {
        $self->handle_blame_command(@args);
        return;
    }
    
    # /git stash [save|apply|drop|list] [args]
    if ($action eq 'stash') {
        $self->handle_stash_command(@args);
        return;
    }
    
    # /git tag [name|-d name]
    if ($action eq 'tag') {
        $self->handle_tag_command(@args);
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
    
    $self->display_section_header("QUERY OPERATIONS");
    $self->display_command_row("/git status", "Show git status", 30);
    $self->display_command_row("/git diff [file]", "Show git diff", 30);
    $self->display_command_row("/git log [n]", "Show recent commits (default: 10)", 30);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("BRANCH OPERATIONS");
    $self->display_command_row("/git branch", "List all branches", 30);
    $self->display_command_row("/git branch <name>", "Create new branch", 30);
    $self->display_command_row("/git switch <name>", "Switch to branch", 30);
    $self->display_command_row("/git branch -d <name>", "Delete branch", 30);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("REMOTE OPERATIONS");
    $self->display_command_row("/git push [remote] [branch]", "Push changes (default: origin, current)", 30);
    $self->display_command_row("/git pull [remote] [branch]", "Pull changes (default: origin, current)", 30);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("COMMIT OPERATIONS");
    $self->display_command_row("/git commit [msg]", "Stage and commit changes", 30);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("HISTORY/UTILITY");
    $self->display_command_row("/git blame <file>", "Show who changed each line", 30);
    $self->display_command_row("/git stash", "List stashes", 30);
    $self->display_command_row("/git stash save [msg]", "Stash changes", 30);
    $self->display_command_row("/git stash apply [n]", "Apply stash (default: latest)", 30);
    $self->display_command_row("/git stash drop [n]", "Delete stash (default: latest)", 30);
    $self->display_command_row("/git tag", "List tags", 30);
    $self->display_command_row("/git tag <name>", "Create tag", 30);
    $self->display_command_row("/git tag -d <name>", "Delete tag", 30);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("EXAMPLES");
    $self->display_command_row("/git status", "See changes", 35);
    $self->display_command_row("/git diff lib/CLIO.pm", "Diff specific file", 35);
    $self->display_command_row("/git log 5", "Last 5 commits", 35);
    $self->display_command_row("/git branch feature-x", "Create new branch", 35);
    $self->display_command_row("/git switch main", "Switch to main branch", 35);
    $self->display_command_row("/git push", "Push to origin/current branch", 35);
    $self->display_command_row("/git stash save \"WIP\"", "Stash with message", 35);
    $self->display_command_row("/git tag v1.0.0", "Create version tag", 35);
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
        $self->display_section_header("COMMIT MESSAGE");
        print $self->colorize("Enter message (Ctrl+C to cancel):\n", 'PROMPT');
        print $self->colorize("> ", 'PROMPT');
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

=head2 handle_branch_command

Branch operations: list, create, delete

=cut

sub handle_branch_command {
    my ($self, @args) = @_;
    
    # No args - list branches
    unless (@args) {
        my $output = `git branch -a 2>&1`;
        my $exit_code = $? >> 8;
        
        if ($exit_code != 0) {
            $self->display_error_message("Git error: $output");
            return;
        }
        
        $self->display_command_header("GIT BRANCHES");
        for my $line (split /\n/, $output) {
            $self->writeline($line, markdown => 0);
        }
        $self->writeline("", markdown => 0);
        return;
    }
    
    # -d flag - delete branch
    if ($args[0] eq '-d') {
        unless ($args[1]) {
            $self->display_error_message("Branch name required for deletion");
            return;
        }
        
        my $branch = $args[1];
        my $output = `git branch -d '$branch' 2>&1`;
        my $exit_code = $? >> 8;
        
        if ($exit_code != 0) {
            $self->display_error_message("Failed to delete branch: $output");
            return;
        }
        
        $self->display_success_message("Branch '$branch' deleted");
        return;
    }
    
    # Create new branch
    my $branch = join(' ', @args);
    my $output = `git branch '$branch' 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Failed to create branch: $output");
        return;
    }
    
    $self->display_success_message("Branch '$branch' created");
}

=head2 handle_switch_command

Switch to a different branch

=cut

sub handle_switch_command {
    my ($self, @args) = @_;
    
    unless (@args) {
        $self->display_error_message("Branch name required");
        return;
    }
    
    my $branch = join(' ', @args);
    my $output = `git checkout '$branch' 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Failed to switch branch: $output");
        return;
    }
    
    $self->display_command_header("GIT SWITCH");
    for my $line (split /\n/, $output) {
        $self->writeline($line, markdown => 0);
    }
    $self->writeline("", markdown => 0);
    
    $self->display_success_message("Switched to branch '$branch'");
}

=head2 handle_push_command

Push changes to remote

=cut

sub handle_push_command {
    my ($self, @args) = @_;
    
    my $remote = $args[0] || 'origin';
    my $branch = $args[1] || '';
    
    my $cmd = "git push $remote";
    $cmd .= " $branch" if $branch;
    $cmd .= " 2>&1";
    
    my $output = `$cmd`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Push failed: $output");
        return;
    }
    
    $self->display_command_header("GIT PUSH");
    for my $line (split /\n/, $output) {
        $self->writeline($line, markdown => 0);
    }
    $self->writeline("", markdown => 0);
    
    my $target = $branch ? "$remote/$branch" : "$remote (current branch)";
    $self->display_success_message("Pushed to $target");
}

=head2 handle_pull_command

Pull changes from remote

=cut

sub handle_pull_command {
    my ($self, @args) = @_;
    
    my $remote = $args[0] || 'origin';
    my $branch = $args[1] || '';
    
    my $cmd = "git pull $remote";
    $cmd .= " $branch" if $branch;
    $cmd .= " 2>&1";
    
    my $output = `$cmd`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Pull failed: $output");
        return;
    }
    
    $self->display_command_header("GIT PULL");
    for my $line (split /\n/, $output) {
        $self->writeline($line, markdown => 0);
    }
    $self->writeline("", markdown => 0);
    
    my $target = $branch ? "$remote/$branch" : "$remote (current branch)";
    $self->display_success_message("Pulled from $target");
}

=head2 handle_blame_command

Show file blame (who changed each line)

=cut

sub handle_blame_command {
    my ($self, @args) = @_;
    
    unless (@args) {
        $self->display_error_message("File path required for blame");
        return;
    }
    
    my $file = join(' ', @args);
    my $output = `git blame '$file' 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Blame failed: $output");
        return;
    }
    
    $self->display_command_header("GIT BLAME - $file");
    for my $line (split /\n/, $output) {
        $self->writeline($line, markdown => 0);
    }
    $self->writeline("", markdown => 0);
}

=head2 handle_stash_command

Stash operations: list, save, apply, drop

=cut

sub handle_stash_command {
    my ($self, @args) = @_;
    
    my $action = $args[0] || 'list';
    $action = lc($action);
    
    # /git stash (no args) - list stashes
    if ($action eq 'list' || !@args) {
        my $output = `git stash list 2>&1`;
        my $exit_code = $? >> 8;
        
        if ($exit_code != 0) {
            $self->display_error_message("Stash list failed: $output");
            return;
        }
        
        unless ($output) {
            $self->display_system_message("No stashes found");
            return;
        }
        
        $self->display_command_header("GIT STASH LIST");
        for my $line (split /\n/, $output) {
            $self->writeline($line, markdown => 0);
        }
        $self->writeline("", markdown => 0);
        return;
    }
    
    # /git stash save [message]
    if ($action eq 'save') {
        shift @args;  # Remove 'save'
        my $message = join(' ', @args) || 'WIP';
        
        $message =~ s/'/'\\''/g;
        my $output = `git stash save '$message' 2>&1`;
        my $exit_code = $? >> 8;
        
        if ($exit_code != 0) {
            $self->display_error_message("Stash save failed: $output");
            return;
        }
        
        $self->display_success_message("Changes stashed: $message");
        return;
    }
    
    # /git stash apply [n]
    if ($action eq 'apply') {
        my $index = $args[1] || '';
        my $cmd = $index ? "git stash apply stash@{$index}" : "git stash apply";
        $cmd .= " 2>&1";
        
        my $output = `$cmd`;
        my $exit_code = $? >> 8;
        
        if ($exit_code != 0) {
            $self->display_error_message("Stash apply failed: $output");
            return;
        }
        
        my $target = $index ? "stash@{$index}" : "latest stash";
        $self->display_success_message("Applied $target");
        return;
    }
    
    # /git stash drop [n]
    if ($action eq 'drop') {
        my $index = $args[1] || '';
        my $cmd = $index ? "git stash drop stash@{$index}" : "git stash drop";
        $cmd .= " 2>&1";
        
        my $output = `$cmd`;
        my $exit_code = $? >> 8;
        
        if ($exit_code != 0) {
            $self->display_error_message("Stash drop failed: $output");
            return;
        }
        
        my $target = $index ? "stash@{$index}" : "latest stash";
        $self->display_success_message("Dropped $target");
        return;
    }
    
    $self->display_error_message("Unknown stash action: $action (use: list, save, apply, drop)");
}

=head2 handle_tag_command

Tag operations: list, create, delete

=cut

sub handle_tag_command {
    my ($self, @args) = @_;
    
    # No args - list tags
    unless (@args) {
        my $output = `git tag 2>&1`;
        my $exit_code = $? >> 8;
        
        if ($exit_code != 0) {
            $self->display_error_message("Tag list failed: $output");
            return;
        }
        
        unless ($output) {
            $self->display_system_message("No tags found");
            return;
        }
        
        $self->display_command_header("GIT TAGS");
        for my $line (split /\n/, $output) {
            $self->writeline($line, markdown => 0);
        }
        $self->writeline("", markdown => 0);
        return;
    }
    
    # -d flag - delete tag
    if ($args[0] eq '-d') {
        unless ($args[1]) {
            $self->display_error_message("Tag name required for deletion");
            return;
        }
        
        my $tag = $args[1];
        my $output = `git tag -d '$tag' 2>&1`;
        my $exit_code = $? >> 8;
        
        if ($exit_code != 0) {
            $self->display_error_message("Failed to delete tag: $output");
            return;
        }
        
        $self->display_success_message("Tag '$tag' deleted");
        return;
    }
    
    # Create new tag
    my $tag = join(' ', @args);
    my $output = `git tag '$tag' 2>&1`;
    my $exit_code = $? >> 8;
    
    if ($exit_code != 0) {
        $self->display_error_message("Failed to create tag: $output");
        return;
    }
    
    $self->display_success_message("Tag '$tag' created");
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
