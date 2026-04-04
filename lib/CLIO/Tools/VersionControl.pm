package CLIO::Tools::VersionControl;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2025 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_info log_warning);
use Carp qw(croak confess);
use parent 'CLIO::Tools::Tool';
use Cwd 'getcwd';
use CLIO::Util::PathResolver qw(expand_tilde);
use CLIO::Util::JSON qw(decode_json encode_json);
use feature 'say';

=head1 NAME

CLIO::Tools::VersionControl - Git version control operations tool

=head1 DESCRIPTION

Provides 11 git operations for repository management, history, and collaboration.

Operations:
  status, log, diff, branch, commit, push, pull, blame, stash, tag, worktree

=cut

sub new {
    my ($class, %opts) = @_;
    
    return $class->SUPER::new(
        name => 'version_control',
        description => q{Git version control operations for repository management.

━━━━━━━━━━━━━━━━━━━━━ QUERY (3 operations) ━━━━━━━━━━━━━━━━━━━━━
-  status - Repository status and changes
-  log - Git commit history
-  diff - Show differences between commits/branches

━━━━━━━━━━━━━━━━━━━━━ BRANCH (2 operations) ━━━━━━━━━━━━━━━━━━━━━
-  branch - Branch operations (list, create, switch, delete)
-  commit - Create commits

━━━━━━━━━━━━━━━━━━━━━ REMOTE (2 operations) ━━━━━━━━━━━━━━━━━━━━━
-  push - Push changes to remote
-  pull - Pull changes from remote

━━━━━━━━━━━━━━━━━━━━━ HISTORY (3 operations) ━━━━━━━━━━━━━━━━━━━━━
-  blame - Show file annotation/blame
-  stash - Stash operations (save, list, apply, drop)
-  tag - Tag operations (list, create, delete)

━━━━━━━━━━━━━━━━━━━━━ WORKTREE (1 operation) ━━━━━━━━━━━━━━━━━━━━━
-  worktree - Worktree operations (list, add, remove, prune, merge, pr)

[CRITICAL WARNING] ⚠️  NEVER USE INTERACTIVE OPERATIONS:
-  git rebase -i / --interactive (BREAKS TERMINAL UI - FORBIDDEN)
-  git mergetool (BREAKS TERMINAL UI - FORBIDDEN)
-  git add -i / --patch / --interactive (BREAKS TERMINAL UI - FORBIDDEN)
-  git commit --patch (BREAKS TERMINAL UI - FORBIDDEN)
Use non-interactive flags or report what needs to be done instead.
},
        supported_operations => [qw(
            status log diff branch commit push pull blame stash tag worktree
        )],
        %opts,
    );
}

sub route_operation {
    my ($self, $operation, $params, $context) = @_;
    
    # Verify git repository
    my $repo_path = $params->{repository_path} || '.';
    
    # Sandbox mode: Check if repository_path is within project directory
    if ($context && $context->{config} && $context->{config}->get('sandbox')) {
        my $sandbox_check = $self->_check_sandbox_path($repo_path, $context);
        return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};
    }
    
    unless ($self->_is_git_repo($repo_path)) {
        return $self->error_result("Not a Git repository: $repo_path");
    }
    
    if ($operation eq 'status') {
        return $self->status($params, $context);
    } elsif ($operation eq 'log') {
        return $self->log($params, $context);
    } elsif ($operation eq 'diff') {
        return $self->diff($params, $context);
    } elsif ($operation eq 'branch') {
        return $self->branch($params, $context);
    } elsif ($operation eq 'commit') {
        return $self->commit($params, $context);
    } elsif ($operation eq 'push') {
        return $self->push($params, $context);
    } elsif ($operation eq 'pull') {
        return $self->pull($params, $context);
    } elsif ($operation eq 'blame') {
        return $self->blame($params, $context);
    } elsif ($operation eq 'stash') {
        return $self->stash($params, $context);
    } elsif ($operation eq 'tag') {
        return $self->tag($params, $context);
    } elsif ($operation eq 'worktree') {
        return $self->worktree($params, $context);
    }
    
    return $self->error_result("Operation not implemented: $operation");
}

sub status {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    my $result;
    
    eval {
        my $original_cwd = getcwd();
        chdir $repo_path if $repo_path ne '.';
        
        my $status = `git status --porcelain -b 2>&1`;
        my $branch = `git branch --show-current 2>&1`;
        chomp($branch);
        
        chdir $original_cwd if $repo_path ne '.';
        
        my @files;
        foreach my $line (split /\n/, $status) {
            next if $line =~ /^##/;  # Skip branch line
            if ($line =~ /^(.{2})\s+(.+)$/) {
                my ($status_code, $file) = ($1, $2);
                push @files, {
                    status => $status_code,
                    file => $file,
                };
            }
        }
        
        my $file_summary = scalar(@files) > 0 ? scalar(@files) . " changes" : "clean";
        my $action_desc = "checking status of $repo_path ($branch: $file_summary)";
        
        $result = $self->success_result(
            {
                branch => $branch,
                files => \@files,
                clean => scalar(@files) == 0,
            },
            action_description => $action_desc,
            repository_path => $repo_path,
        );
    };
    
    if ($@) {
        return $self->error_result("Git status failed: $@");
    }
    
    return $result;
}

sub log {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    my $limit = $params->{limit} || 10;
    my $result;
    
    eval {
        my $original_cwd = getcwd();
        chdir $repo_path if $repo_path ne '.';
        
        my $log_output = `git log --pretty=format:'%H|%an|%ae|%ad|%s' --date=iso -n $limit 2>&1`;
        
        chdir $original_cwd if $repo_path ne '.';
        
        my @commits;
        foreach my $line (split /\n/, $log_output) {
            my ($hash, $author, $email, $date, $subject) = split /\|/, $line, 5;
            push @commits, {
                hash => $hash,
                author => $author,
                email => $email,
                date => $date,
                subject => $subject,
            };
        }
        
        my $action_desc = "viewing git log of $repo_path (" . scalar(@commits) . " commits)";
        
        $result = $self->success_result(
            \@commits,
            action_description => $action_desc,
            repository_path => $repo_path,
            count => scalar(@commits),
        );
    };
    
    if ($@) {
        return $self->error_result("Git log failed: $@");
    }
    
    return $result;
}

sub diff {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    my $ref1 = $params->{ref1} || 'HEAD';
    my $ref2 = $params->{ref2} || '';
    my $file = $params->{file} || '';
    my $result;
    
    eval {
        my $original_cwd = getcwd();
        chdir $repo_path if $repo_path ne '.';
        
        my $cmd = "git diff $ref1";
        $cmd .= " $ref2" if $ref2;
        $cmd .= " -- $file" if $file;
        $cmd .= " 2>&1";
        
        my $diff_output = `$cmd`;
        
        chdir $original_cwd if $repo_path ne '.';
        
        my $target = $file ? "file $file" : "repository";
        my $comparison = $ref2 ? "$ref1..$ref2" : "$ref1 vs working tree";
        my $action_desc = "comparing $comparison in $target";
        
        $result = $self->success_result(
            $diff_output,
            action_description => $action_desc,
            repository_path => $repo_path,
            ref1 => $ref1,
            ref2 => $ref2 || 'working tree',
        );
    };
    
    if ($@) {
        return $self->error_result("Git diff failed: $@");
    }
    
    return $result;
}

sub branch {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    my $action = $params->{action} || 'list';  # list, create, delete, switch
    my $name = $params->{name} || '';
    my $result;
    
    eval {
        my $original_cwd = getcwd();
        chdir $repo_path if $repo_path ne '.';
        
        my $output;
        if ($action eq 'list') {
            $output = `git branch -a 2>&1`;
        } elsif ($action eq 'create' && $name) {
            $output = `git branch $name 2>&1`;
        } elsif ($action eq 'delete' && $name) {
            $output = `git branch -d $name 2>&1`;
        } elsif ($action eq 'switch' && $name) {
            $output = `git checkout $name 2>&1`;
        } else {
            croak "Invalid branch action or missing name";
        }
        
        chdir $original_cwd if $repo_path ne '.';
        
        my $action_desc = $action eq 'list' 
            ? "listing branches"
            : "$action branch" . ($name ? " '$name'" : "");
        
        $result = $self->success_result(
            $output,
            action_description => $action_desc,
            action => $action,
            branch_name => $name,
        );
    };
    
    if ($@) {
        return $self->error_result("Git branch failed: $@");
    }
    
    return $result;
}

sub commit {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    my $message = $params->{message};
    my $result;
    
    return $self->error_result("Missing 'message' parameter") unless $message;
    
    # Multi-agent coordination: Request git lock via broker
    my $lock_acquired = 0;
    if ($context->{broker_client}) {
        log_info('VersionControl', "Requesting git lock via broker");
        eval {
            my $lock_result = $context->{broker_client}->request_git_lock();
            if ($lock_result) {
                $lock_acquired = 1;
                log_info('VersionControl', "Git lock acquired");
            } else {
                return $self->error_result(
                    "Git is locked by another agent.\n" .
                    "Wait for the other agent's commit to complete."
                );
            }
        };
        if ($@) {
            log_warning('VersionControl', "Failed to acquire git lock: $@");
            log_warning('VersionControl', "Continuing without lock");
        }
    }
    
    eval {
        my $original_cwd = getcwd();
        chdir $repo_path if $repo_path ne '.';
        
        # Auto-stage all tracked changes before commit
        # This matches typical agent workflow: make changes, then commit
        my $add_output = `git add -A 2>&1`;
        my $add_exit = $? >> 8;
        if ($add_exit != 0) {
            chdir $original_cwd if $repo_path ne '.';
            $result = $self->error_result("git add failed (exit $add_exit): $add_output");
            return;
        }
        
        # Check if there's anything to commit after staging
        my $status = `git status --porcelain 2>&1`;
        if (!$status || $status =~ /^\s*$/) {
            chdir $original_cwd if $repo_path ne '.';
            $result = $self->error_result(
                "Nothing to commit - working tree clean.\n" .
                "No modified, added, or deleted files detected."
            );
            return;
        }
        
        # Properly escape message for shell - use single quotes and escape embedded single quotes
        my $escaped_message = $message;
        $escaped_message =~ s/'/'\\''/g;  # Replace ' with '\''
        
        my $output = `git commit -m '$escaped_message' 2>&1`;
        my $exit_code = $? >> 8;
        
        chdir $original_cwd if $repo_path ne '.';
        
        if ($exit_code != 0) {
            $result = $self->error_result("git commit failed (exit $exit_code): $output");
            return;
        }
        
        my $action_desc = "committing changes";
        
        $result = $self->success_result(
            $output,
            action_description => $action_desc,
            message => $message,
        );
    };
    
    # Release git lock if acquired
    if ($lock_acquired && $context->{broker_client}) {
        eval {
            $context->{broker_client}->release_git_lock();
            log_info('VersionControl', "Git lock released");
        };
        if ($@) {
            log_warning('VersionControl', "Failed to release git lock: $@");
        }
    }
    
    if ($@) {
        return $self->error_result("Git commit failed: $@");
    }
    
    return $result;
}

sub push {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    my $remote = $params->{remote} || 'origin';
    my $branch = $params->{branch} || '';
    my $result;
    
    eval {
        my $original_cwd = getcwd();
        chdir $repo_path if $repo_path ne '.';
        
        my $cmd = "git push $remote";
        $cmd .= " $branch" if $branch;
        $cmd .= " 2>&1";
        
        my $output = `$cmd`;
        
        chdir $original_cwd if $repo_path ne '.';
        
        my $target = $branch ? "$remote/$branch" : $remote;
        my $action_desc = "pushing to $target";
        
        $result = $self->success_result(
            $output,
            action_description => $action_desc,
            remote => $remote,
            branch => $branch || 'current',
        );
    };
    
    if ($@) {
        return $self->error_result("Git push failed: $@");
    }
    
    return $result;
}

sub pull {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    my $remote = $params->{remote} || 'origin';
    my $branch = $params->{branch} || '';
    my $result;
    
    eval {
        my $original_cwd = getcwd();
        chdir $repo_path if $repo_path ne '.';
        
        my $cmd = "git pull $remote";
        $cmd .= " $branch" if $branch;
        $cmd .= " 2>&1";
        
        my $output = `$cmd`;
        
        chdir $original_cwd if $repo_path ne '.';
        
        my $target = $branch ? "$remote/$branch" : $remote;
        my $action_desc = "pulling from $target";
        
        $result = $self->success_result(
            $output,
            action_description => $action_desc,
            remote => $remote,
            branch => $branch || 'current',
        );
    };
    
    if ($@) {
        return $self->error_result("Git pull failed: $@");
    }
    
    return $result;
}

sub blame {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    my $file = $params->{file};
    my $result;
    
    return $self->error_result("Missing 'file' parameter") unless $file;
    
    eval {
        my $original_cwd = getcwd();
        chdir $repo_path if $repo_path ne '.';
        
        my $output = `git blame $file 2>&1`;
        
        chdir $original_cwd if $repo_path ne '.';
        
        my $action_desc = "viewing blame for $file";
        
        $result = $self->success_result(
            $output,
            action_description => $action_desc,
            file => $file,
        );
    };
    
    if ($@) {
        return $self->error_result("Git blame failed: $@");
    }
    
    return $result;
}

sub stash {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    my $action = $params->{action} || 'list';  # save, list, apply, drop, clear
    my $result;
    
    eval {
        my $original_cwd = getcwd();
        chdir $repo_path if $repo_path ne '.';
        
        my $output;
        if ($action eq 'save') {
            my $message = $params->{message} || 'stash';
            $output = `git stash save "$message" 2>&1`;
        } elsif ($action eq 'list') {
            $output = `git stash list 2>&1`;
        } elsif ($action eq 'apply') {
            my $index = $params->{index} // 0;
            $output = `git stash apply stash\@{$index} 2>&1`;
        } elsif ($action eq 'drop') {
            my $index = $params->{index} // 0;
            $output = `git stash drop stash\@{$index} 2>&1`;
        } elsif ($action eq 'clear') {
            $output = `git stash clear 2>&1`;
        } else {
            croak "Invalid stash action: $action";
        }
        
        chdir $original_cwd if $repo_path ne '.';
        
        my $action_desc = $action eq 'save' 
            ? "saving stash"
            : $action eq 'list'
            ? "listing stashes"
            : "$action stash";
        
        $result = $self->success_result(
            $output,
            action_description => $action_desc,
            action => $action,
        );
    };
    
    if ($@) {
        return $self->error_result("Git stash failed: $@");
    }
    
    return $result;
}

sub tag {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    my $action = $params->{action} || 'list';  # list, create, delete
    my $name = $params->{name} || '';
    my $result;
    
    eval {
        my $original_cwd = getcwd();
        chdir $repo_path if $repo_path ne '.';
        
        my $output;
        if ($action eq 'list') {
            $output = `git tag 2>&1`;
        } elsif ($action eq 'create' && $name) {
            my $message = $params->{message} || '';
            if ($message) {
                $output = `git tag -a $name -m "$message" 2>&1`;
            } else {
                $output = `git tag $name 2>&1`;
            }
        } elsif ($action eq 'delete' && $name) {
            $output = `git tag -d $name 2>&1`;
        } else {
            croak "Invalid tag action or missing name";
        }
        
        chdir $original_cwd if $repo_path ne '.';
        
        my $action_desc = $action eq 'list'
            ? "listing tags"
            : "$action tag" . ($name ? " '$name'" : "");
        
        $result = $self->success_result(
            $output,
            action_description => $action_desc,
            action => $action,
            tag_name => $name,
        );
    };
    
    if ($@) {
        return $self->error_result("Git tag failed: $@");
    }
    
    return $result;
}

sub worktree {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    my $action = $params->{action} || 'list';  # list, add, remove, prune, merge, pr
    my $worktree_path = $params->{worktree_path} || '';
    my $result;
    
    # Validate worktree_path for sandbox mode (add/remove create/delete dirs)
    if ($worktree_path && $context && $context->{config} && $context->{config}->get('sandbox')) {
        my $sandbox_check = $self->_check_sandbox_path($worktree_path, $context);
        return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};
    }
    
    # Acquire git lock for mutating operations (add, remove, prune)
    my $lock_acquired = 0;
    if ($action ne 'list' && $context->{broker_client}) {
        log_info('VersionControl', "Requesting git lock for worktree $action");
        my $lock_denied = 0;
        eval {
            my $lock_result = $context->{broker_client}->request_git_lock();
            if ($lock_result) {
                $lock_acquired = 1;
                log_info('VersionControl', "Git lock acquired for worktree $action");
            } else {
                $lock_denied = 1;
            }
        };
        if ($lock_denied) {
            return $self->error_result(
                "Git is locked by another agent.\n" .
                "Wait for the other agent's operation to complete."
            );
        }
        if ($@) {
            log_warning('VersionControl', "Failed to acquire git lock: $@");
            log_warning('VersionControl', "Continuing without lock");
        }
    }
    
    my $original_cwd = getcwd();
    chdir $repo_path if $repo_path ne '.';

    eval {
        my $output;
        if ($action eq 'list') {
            $output = `git worktree list 2>&1`;
            my $exit = $? >> 8;
            croak "git worktree list failed (exit $exit):\n$output" if $exit != 0;
        } elsif ($action eq 'add' && $worktree_path) {
            my $branch = $params->{branch} || '';
            my $create_branch = $params->{create_branch} || 0;
            my $cmd = "git worktree add";
            if ($create_branch && $branch) {
                $cmd .= " -b '$branch'";
            }
            $cmd .= " '$worktree_path'";
            $cmd .= " '$branch'" if $branch && !$create_branch;
            $cmd .= " 2>&1";
            $output = `$cmd`;
            my $exit = $? >> 8;
            croak "git worktree add failed (exit $exit):\n$output" if $exit != 0;
        } elsif ($action eq 'remove' && $worktree_path) {
            my $force = $params->{force} || 0;
            my $cmd = "git worktree remove";
            $cmd .= " --force" if $force;
            $cmd .= " '$worktree_path' 2>&1";
            $output = `$cmd`;
            my $exit = $? >> 8;
            croak "git worktree remove failed (exit $exit):\n$output" if $exit != 0;
        } elsif ($action eq 'prune') {
            $output = `git worktree prune 2>&1`;
            my $exit = $? >> 8;
            croak "git worktree prune failed (exit $exit):\n$output" if $exit != 0;
        } elsif (($action eq 'merge' || $action eq 'pr') && $worktree_path) {
            # Resolve the branch name from the worktree
            my $wt_list = `git worktree list --porcelain 2>&1`;
            my $wt_branch = $self->_resolve_worktree_branch($wt_list, $worktree_path);
            croak "Could not find worktree '$worktree_path' in worktree list. Use action 'list' to see available worktrees." unless $wt_branch;

            if ($action eq 'merge') {
                $output = `git merge '$wt_branch' 2>&1`;
                my $exit = $? >> 8;
                croak "git merge failed (exit $exit):\n$output" if $exit != 0;
            } else {
                # pr: push branch to remote, then provide PR info
                my $remote = $params->{remote} || 'origin';
                my $push_output = `git push '$remote' '$wt_branch' 2>&1`;
                my $push_exit = $? >> 8;
                my $current_branch = `git rev-parse --abbrev-ref HEAD 2>&1`;
                chomp $current_branch;
                if ($push_exit == 0) {
                    $output = $push_output . "\n" .
                        "Branch '$wt_branch' pushed to $remote.\n" .
                        "Create a pull request to merge '$wt_branch' into '$current_branch'.";
                } else {
                    $output = "Push failed (exit $push_exit):\n" . $push_output . "\n" .
                        "Fix the push issue, then create a pull request to merge '$wt_branch' into '$current_branch'.";
                }
            }
        } elsif ($action eq 'merge' || $action eq 'pr') {
            croak "worktree_path is required for '$action' action. Use action 'list' to see available worktrees.";
        } else {
            croak "Invalid worktree action or missing worktree_path for add/remove";
        }

        my $action_desc = $action eq 'list'
            ? "listing worktrees"
            : $action eq 'prune'
            ? "pruning stale worktrees"
            : "$action worktree" . ($worktree_path ? " '$worktree_path'" : "");

        $result = $self->success_result(
            $output,
            action_description => $action_desc,
            action => $action,
            worktree_path => $worktree_path,
        );
    };
    my $main_error = $@;

    chdir $original_cwd if $repo_path ne '.';

    # Release git lock if acquired
    if ($lock_acquired && $context->{broker_client}) {
        eval {
            $context->{broker_client}->release_git_lock();
            log_info('VersionControl', "Git lock released after worktree $action");
        };
        if ($@) {
            log_warning('VersionControl', "Failed to release git lock: $@");
        }
    }
    
    if ($main_error) {
        return $self->error_result("Git worktree failed: $main_error");
    }
    
    return $result;
}

sub _resolve_worktree_branch {
    my ($self, $porcelain_output, $worktree_name) = @_;
    
    # Parse porcelain output to find the branch for a given worktree path/name.
    # Porcelain format has blocks separated by blank lines:
    #   worktree /abs/path
    #   HEAD <sha>
    #   branch refs/heads/<name>
    my $found_path = 0;
    my $branch;
    
    for my $line (split /\n/, $porcelain_output) {
        if ($line =~ /^worktree\s+(.+)/) {
            my $wt_path = $1;
            # Match if the worktree path ends with the provided name as a directory component, or is an exact match
            $found_path = ($wt_path eq $worktree_name || $wt_path =~ m{/\Q$worktree_name\E$});
        } elsif ($found_path && $line =~ /^branch\s+refs\/heads\/(.+)/) {
            $branch = $1;
            last;
        } elsif ($line eq '') {
            $found_path = 0;
        }
    }
    
    return $branch;
}

sub _check_sandbox_path {
    my ($self, $path, $context) = @_;
    
    use Cwd qw(abs_path getcwd realpath);
    use File::Spec;
    
    # Get project directory
    my $project_dir = getcwd();
    if ($context->{session} && $context->{session}->{state}) {
        my $session_wd = $context->{session}->{state}->{working_directory};
        $project_dir = $session_wd if $session_wd;
    }
    $project_dir = realpath($project_dir) || abs_path($project_dir) || $project_dir;
    
    # Expand tilde
    $path = expand_tilde($path);
    
    # Resolve path
    my $resolved_path;
    if ($path =~ m{^/}) {
        $resolved_path = realpath($path) || $path;
    } else {
        my $full_path = File::Spec->rel2abs($path, $project_dir);
        $resolved_path = realpath($full_path) || $full_path;
    }
    
    # Normalize paths
    $project_dir =~ s{/+$}{};
    $resolved_path =~ s{/+$}{};
    
    # Check containment
    my $is_inside = ($resolved_path eq $project_dir) ||
                    ($resolved_path =~ /^\Q$project_dir\E\//);
    
    if ($is_inside) {
        return { allowed => 1 };
    }
    
    return {
        allowed => 0,
        error => "Sandbox mode: Access denied to '$path' - path is outside project directory '$project_dir'",
    };
}

sub _is_git_repo {
    my ($self, $path) = @_;
    
    $path ||= '.';
    
    my $original_cwd = getcwd();
    chdir $path if $path ne '.';
    
    my $nulldev = $^O eq 'MSWin32' ? 'nul' : '/dev/null';
    my $is_repo = -d '.git' || `git rev-parse --git-dir 2>$nulldev`;
    
    chdir $original_cwd if $path ne '.';
    
    return $is_repo ? 1 : 0;
}

=head2 get_additional_parameters

Define parameters specific to version_control tool.

Returns: Hashref of parameter definitions

=cut

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        repository_path => {
            type => "string",
            description => "Path to git repository (default: '.')",
        },
        message => {
            type => "string",
            description => "Commit message (required for commit operation)",
        },
        ref1 => {
            type => "string",
            description => "First ref for diff (default: 'HEAD')",
        },
        ref2 => {
            type => "string",
            description => "Second ref for diff (optional)",
        },
        file => {
            type => "string",
            description => "File path for diff or blame",
        },
        action => {
            type => "string",
            description => "Action for branch/stash/tag/worktree operations (list, create, delete, switch, save, apply, drop, clear, add, remove, prune, merge, pr)",
        },
        name => {
            type => "string",
            description => "Branch, tag, or stash name",
        },
        remote => {
            type => "string",
            description => "Remote name (default: 'origin')",
        },
        branch => {
            type => "string",
            description => "Branch name for push/pull",
        },
        limit => {
            type => "integer",
            description => "Limit for log entries (default: 10)",
        },
        index => {
            type => "integer",
            description => "Stash index for apply/drop",
        },
        worktree_path => {
            type => "string",
            description => "Path for worktree add/remove operations",
        },
        create_branch => {
            type => "boolean",
            description => "Create a new branch when adding a worktree (use with branch parameter)",
        },
        force => {
            type => "boolean",
            description => "Force removal of a worktree even if it has modifications",
        },
    };
}

1;

__END__

=head1 MIGRATION FROM CLIO::Protocols::Git

Replaces CLIO::Protocols::Git with cleaner operation-based API.

Old: [GIT:action=status:params=<base64>]
New: { "tool": "version_control", "operation": "status" }

=head1 AUTHOR

CLIO Project

=cut

1;
