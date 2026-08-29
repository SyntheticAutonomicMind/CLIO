package CLIO::Tools::VersionControl;

# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(log_info log_warning);
use Carp qw(croak confess);
use parent 'CLIO::Tools::Tool';
use Cwd qw(getcwd abs_path);
use File::Spec ();
use File::Temp qw(tempfile);
use CLIO::Util::PathResolver qw(expand_tilde);
use CLIO::Util::JSON qw(decode_json encode_json);
use POSIX qw(WNOHANG _exit);

# Shell-quote a string for safe interpolation into backtick commands.
# Uses single-quote wrapping with embedded single-quote escaping.
# This is a simplified version of String::ShellQuote for environments
# where that module may not be available.
sub _sq {
    my ($str) = @_;
    return "''" unless defined $str && length $str;
    $str =~ s/'/'\\''/g;
    return "'$str'";
}

# Run a code block with CWD set to $repo_path, restoring CWD on exit (even on die).
sub _in_repo {
    my ($repo_path, $code) = @_;
    if ($repo_path eq '.') {
        return $code->();
    }
    my $original_cwd = getcwd();
    # chdir failure is an EXPECTED user error (non-existent / hallucinated
    # repository_path), not an exceptional condition. croak() here used to
    # propagate all the way up through Tool::execute, bypassing the eval
    # blocks in every operation handler and the ToolErrorGuidance pipeline,
    # ultimately surfacing as SimpleAIAgent's generic "I'm experiencing
    # technical difficulties. Please try again." message.
    #
    # die() with a plain string (no Carp caller-location suffix) lets the
    # existing eval{} blocks in each operation handler catch it cleanly.
    # Those handlers wrap the message via _clean_eval_error() and forward
    # to error_result(), producing "Git status failed: Cannot chdir to
    # /Users/andrew/ALICE: No such file or directory" - which
    # ToolErrorGuidance then categorizes as file_not_found with proper
    # guidance.
    #
    # If a future caller of _in_repo is NOT wrapped in eval, Tool::execute's
    # new defense-in-depth eval catches the die and converts it to an
    # error_result anyway. Two layers of protection.
    unless (chdir $repo_path) {
        die "Cannot chdir to $repo_path: $!";
    }
    my $result = eval { $code->() };
    my $err = $@;
    chdir $original_cwd;
    die $err if $err;
    return $result;
}

# Run a shell command with ESC interrupt polling. Captures stdout+stderr to a
# temp file and returns the contents. If the user presses ESC while the command
# is running (network-push, network-pull, clone), the child process group is
# killed cleanly and an interrupted_result is returned for the caller to surface.
#
# Mirrors terminal_operations::_execute_captured fork+waitpid loop so a slow
# git network operation can be aborted without waiting for the remote server
# to time out.
sub _run_with_interrupt {
    my ($self, $cmd, $context) = @_;
    my $session = $context && $context->{session};

    my ($log_fh, $log_file) = tempfile(SUFFIX => '.clio_git.log', UNLINK => 1);
    close $log_fh;

    my $pid = fork();
    if (!defined $pid) {
        croak "Fork failed: $!";
    }
    if ($pid == 0) {
        # Child: detach from controlling terminal and run the command.
        POSIX::setpgid(0, 0);
        open(STDIN, '<', '/dev/null') or POSIX::_exit(126);
        my $escaped_log = _sq($log_file);
        exec("/bin/sh", "-c", "($cmd) > $escaped_log 2>&1")
            or POSIX::_exit(127);
    }

    # Parent: poll for completion, ESC interrupt, and timeouts.
    my $exit_code = -1;
    my $interrupted = 0;
    my $start = time();

    while (1) {
        my $waited = waitpid($pid, POSIX::WNOHANG());
        if ($waited > 0) {
            $exit_code = $? >> 8;
            last;
        }
        if ($self->check_interrupt($context)) {
            log_info('VersionControl', "User interrupt detected, killing git pid $pid");
            $interrupted = 1;
            kill '-KILL', -$pid;  # Kill process group
            waitpid($pid, 0);
            $exit_code = 130;
            last;
        }
        sleep 0.1;  # 100ms poll - matches ALRM interval for sub-second interrupt
    }

    my $output = '';
    if (open my $fh, '<:encoding(UTF-8)', $log_file) {
        local $/;
        $output = <$fh>;
        close $fh;
    }

    return ($exit_code, $output, $interrupted);
}

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
   Returns: {clean, branch, files[{file, status}]}
-  log - Git commit history
   Returns: {commits[{hash, date, author, subject, body}], count}
-  diff - Show differences between commits/branches
   Returns: diff output (unified format). Use ref1/ref2 to specify range.

━━━━━━━━━━━━━━━━━━━━━ BRANCH (2 operations) ━━━━━━━━━━━━━━━━━━━━━
-  branch - Branch operations (list, create, switch, delete)
   Returns: list [{name, current}] or operation confirmation
-  commit - Create commits (auto-stages all changes including untracked files; pass auto_stage=0 to commit only pre-staged files)
   Returns: {success, hash, message, staged_files} on success

━━━━━━━━━━━━━━━━━━━━━ REMOTE (2 operations) ━━━━━━━━━━━━━━━━━━━━━
-  push - Push changes to remote
   Returns: {success, output} with push details
-  pull - Pull changes from remote
   Returns: {success, output} with pull details

━━━━━━━━━━━━━━━━━━━━━ HISTORY (3 operations) ━━━━━━━━━━━━━━━━━━━━━
-  blame - Show file annotation/blame
   Returns: [{line, author, date, commit_hash, content}]
-  stash - Stash operations (save, list, apply, drop)
   Returns: list [{index, message, date}] or operation confirmation
-  tag - Tag operations (list, create, delete)
   Returns: list [{name, commit, date}] or operation confirmation

━━━━━━━━━━━━━━━━━━━━━ WORKTREE (1 operation) ━━━━━━━━━━━━━━━━━━━━━
-  worktree - Worktree operations (list, add, remove, prune, merge, pr)
   Returns: list [{path, branch}] or operation confirmation

[COMMIT BEHAVIOR] The commit operation runs `git add -A` before committing by default,
picking up ALL working-tree changes including untracked files. This means a stray
untracked file will land in your commit even if you didn't intend to add it.

To commit only specific files: (1) explicitly `git add <exact paths>` via
terminal_operations before commit, OR (2) pass auto_stage=0 to commit only what's
already staged. The commit result includes a `staged_files` list so you can see
exactly what got committed before moving on.

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

sub before_route {
    my ($self, $operation, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    
    # Sandbox mode: Check if repository_path is within project directory
    if ($context && $context->{config} && $context->{config}->get('sandbox')) {
        my $sandbox_check = $self->_check_sandbox_path($repo_path, $context);
        return $self->error_result($sandbox_check->{error}) unless $sandbox_check->{allowed};
    }
    
    unless ($self->_is_git_repo($repo_path)) {
        return $self->error_result("Not a Git repository: $repo_path");
    }
    
    return undef;
}

sub dispatch_table {
    return {
        status   => 'status',
        log      => 'log',
        diff     => 'diff',
        branch   => 'branch',
        commit   => 'commit',
        push     => 'push',
        pull     => 'pull',
        blame    => 'blame',
        stash    => 'stash',
        tag      => 'tag',
        worktree => 'worktree',
    };
}

sub status {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    my $result;
    
    eval {
        $result = _in_repo($repo_path, sub {
            my $status = `git status --porcelain -b 2>&1`;
            my $branch = `git branch --show-current 2>&1`;
            chomp($branch);
            
            my @files;
            foreach my $line (split /\n/, $status) {
                next if $line =~ /^##/;
                if ($line =~ /^(.{2})\s+(.+)$/) {
                    my ($status_code, $file) = ($1, $2);
                    push @files, { status => $status_code, file => $file };
                }
            }
            
            my $file_summary = scalar(@files) > 0 ? scalar(@files) . " changes" : "clean";
            my $action_desc = "checking status of $repo_path ($branch: $file_summary)";
            
            return $self->success_result(
                { branch => $branch, files => \@files, clean => scalar(@files) == 0 },
                action_description => $action_desc,
                repository_path => $repo_path,
            );
        });
    };

    if ($@) {
        return $self->error_result("Git status failed: " . $self->_clean_eval_error($@));
    }

    return $result;
}

sub log {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    # Validate limit: must be a positive integer.
    # Negative or zero values cause unbounded output; clamp to safe maximum.
    my $limit = $params->{limit};
    my $clamped = 0;
    if (!defined $limit) {
        $limit = 10;
    } elsif ($limit !~ /^\d+$/ || $limit == 0) {
        return $self->error_result(
            "Invalid 'limit' parameter: $params->{limit}. " .
            "Must be a positive integer (1-1000)."
        );
    } elsif ($limit > 1000) {
        $clamped = 1;
        $limit = 1000;
    }
    my $result;
    
    eval {
        $result = _in_repo($repo_path, sub {
            my $safe_limit = int($limit);
            my $log_output = `git log --pretty=format:'%H|%an|%ae|%ad|%s' --date=iso -n $safe_limit 2>&1`;
            
            my @commits;
            foreach my $line (split /\n/, $log_output) {
                my ($hash, $author, $email, $date, $subject) = split /\|/, $line, 5;
                push @commits, {
                    hash => $hash, author => $author, email => $email,
                    date => $date, subject => $subject,
                };
            }
            
            return $self->success_result(
                \@commits,
                action_description => "viewing git log of $repo_path (" . scalar(@commits) . " commits)",
                repository_path => $repo_path,
                count => scalar(@commits),
                ($clamped ? (limit_clamped => 1000) : ()),
            );
        });
    };

    if ($@) {
        return $self->error_result("Git log failed: " . $self->_clean_eval_error($@));
    }

    return $result;
}

sub diff {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    my $ref1 = $params->{ref1} || 'HEAD';
    my $ref2 = $params->{ref2} || '';
    my $file = $params->{file} || '';

    # When a file is specified, validate it exists. Git diff returns empty
    # output for missing paths, leaving callers with no clue why.
    if ($file && !-f $file) {
        return $self->error_result("File not found: $file");
    }
    my $result;
    
    eval {
        $result = _in_repo($repo_path, sub {
            my $cmd = "git diff " . _sq($ref1);
            $cmd .= " " . _sq($ref2) if $ref2;
            $cmd .= " -- " . _sq($file) if $file;
            $cmd .= " 2>&1";
            
            my $diff_output = `$cmd`;
            my $target = $file ? "file $file" : "repository";
            my $comparison = $ref2 ? "$ref1..$ref2" : "$ref1 vs working tree";
            
            return $self->success_result(
                $diff_output,
                action_description => "comparing $comparison in $target",
                repository_path => $repo_path,
                ref1 => $ref1,
                ref2 => $ref2 || 'working tree',
            );
        });
    };

    if ($@) {
        return $self->error_result("Git diff failed: " . $self->_clean_eval_error($@));
    }

    return $result;
}

sub branch {
    my ($self, $params, $context) = @_;

    my $repo_path = $params->{repository_path} || '.';
    my $action = $params->{sub_action} || $params->{action} || 'list';  # list, create, delete, switch
    my $name = $params->{name} || '';

    # Validate parameters upfront with messages that match ToolErrorGuidance
    # categories. Validation errors return error_result() directly so we don't
    # pollute the message with croak's caller-location suffix (e.g. "at
    # /Users/.../ToolExecutor.pm line N") and so the guidance system can
    # correctly classify the failure (missing_required vs invalid_value).
    my %valid_actions = map { $_ => 1 } qw(list create delete switch);
    unless ($valid_actions{$action}) {
        return $self->error_result(
            "Invalid action '$action'. Must be one of: list, create, delete, switch"
        );
    }
    unless ($action eq 'list' || $name) {
        return $self->error_result(
            "Missing required parameter: name (required for action '$action')"
        );
    }

    my $result;

    eval {
        $result = _in_repo($repo_path, sub {
            my $output;
            if ($action eq 'list') {
                $output = `git branch -a 2>&1`;
            } elsif ($action eq 'create' && $name) {
                $output = `git branch @{[_sq($name)]} 2>&1`;
            } elsif ($action eq 'delete' && $name) {
                $output = `git branch -d @{[_sq($name)]} 2>&1`;
            } elsif ($action eq 'switch' && $name) {
                $output = `git checkout @{[_sq($name)]} 2>&1`;
            } else {
                croak "Internal: unhandled branch action '$action' (validation should have caught this)";
            }
            
            my $action_desc = $action eq 'list' 
                ? "listing branches"
                : "$action branch" . ($name ? " '$name'" : "");
            
            return $self->success_result(
                $output,
                action_description => $action_desc,
                action => $action,
                branch_name => $name,
            );
        });
    };

    if ($@) {
        return $self->error_result("Git branch failed: " . $self->_clean_eval_error($@));
    }

    return $result;
}

sub commit {
    my ($self, $params, $context) = @_;

    my $repo_path = $params->{repository_path} || '.';
    my $message = $params->{message};
    my $auto_stage = $params->{auto_stage} // 1;  # Default to true for backward compat
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
        $result = _in_repo($repo_path, sub {
            # Capture pre-stage untracked files to warn if auto_stage
            # includes files the agent didn't intend to commit.
            my @pre_untracked = $auto_stage ? split /\n/, `git ls-files --others --exclude-standard 2>&1` : ();

            if ($auto_stage) {
                my $add_output = `git add -A 2>&1`;
                my $add_exit = $? >> 8;
                if ($add_exit != 0) {
                    $result = $self->error_result("git add failed (exit $add_exit): $add_output");
                    return $result;
                }
            }

            # Capture the list of files staged for this commit so the agent
            # (and any reviewers) can see exactly what landed. Use
            # `git diff --cached --name-only` which lists only files with
            # staged changes, regardless of whether auto_stage ran.
            my @staged_files = split /\n/, `git diff --cached --name-only 2>&1`;
            @staged_files = grep { length } @staged_files;

            if (!@staged_files) {
                $result = $self->error_result(
                    "Nothing to commit - working tree clean.\n" .
                    "No modified, added, or deleted files detected."
                );
                return $result;
            }

            # Identify which just-staged files were previously untracked.
            # These are the files auto_stage pulled in without an explicit add.
            my %pre_untracked = map { $_ => 1 } @pre_untracked;
            my @auto_staged_untracked = grep { $pre_untracked{$_} } @staged_files;

            # Properly escape message for shell
            my $escaped_message = $message;
            $escaped_message =~ s/'/'\\''/g;

            my $output = `git commit -m '$escaped_message' 2>&1`;
            my $exit_code = $? >> 8;

            if ($exit_code != 0) {
                $result = $self->error_result("git commit failed (exit $exit_code): $output");
                return $result;
            }

            return $self->success_result(
                $output,
                action_description => "committing changes",
                message => $message,
                staged_files => \@staged_files,
                # Tag any untracked files auto_stage pulled in so the agent
                # can see them in the result and decide whether to keep them.
                ($auto_stage && @auto_staged_untracked
                    ? (auto_staged_untracked => \@auto_staged_untracked)
                    : ()),
            );
        });
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
        return $self->error_result("Git commit failed: " . $self->_clean_eval_error($@));
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
        $result = _in_repo($repo_path, sub {
            my $cmd = "git push " . _sq($remote);
            $cmd .= " " . _sq($branch) if $branch;
            $cmd .= " 2>&1";

            my ($exit_code, $output, $interrupted) = $self->_run_with_interrupt($cmd, $context);
            my $target = $branch ? "$remote/$branch" : $remote;

            if ($interrupted) {
                return $self->success_result(
                    $output . "\n[Aborted by user]",
                    action_description => "push to $target aborted by user",
                    remote => $remote,
                    branch => $branch || 'current',
                    interrupted => 1,
                    exit_code => $exit_code,
                );
            }

            return $self->success_result(
                $output,
                action_description => "pushing to $target",
                remote => $remote,
                branch => $branch || 'current',
                exit_code => $exit_code,
            );
        });
    };

    if ($@) {
        return $self->error_result("Git push failed: " . $self->_clean_eval_error($@));
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
        $result = _in_repo($repo_path, sub {
            my $cmd = "git pull " . _sq($remote);
            $cmd .= " " . _sq($branch) if $branch;
            $cmd .= " 2>&1";

            my ($exit_code, $output, $interrupted) = $self->_run_with_interrupt($cmd, $context);
            my $target = $branch ? "$remote/$branch" : $remote;

            if ($interrupted) {
                return $self->success_result(
                    $output . "\n[Aborted by user]",
                    action_description => "pull from $target aborted by user",
                    remote => $remote,
                    branch => $branch || 'current',
                    interrupted => 1,
                    exit_code => $exit_code,
                );
            }

            return $self->success_result(
                $output,
                action_description => "pulling from $target",
                remote => $remote,
                branch => $branch || 'current',
                exit_code => $exit_code,
            );
        });
    };

    if ($@) {
        return $self->error_result("Git pull failed: " . $self->_clean_eval_error($@));
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
        $result = _in_repo($repo_path, sub {
            my $start_line = $params->{start_line};
            my $max_lines  = $params->{max_lines};

            # Scope blame output to avoid dumping entire large files
            # into the context window. git blame -L <start>,<end> limits
            # the annotated lines. Default to 200 lines starting from
            # line 1 (or the requested start_line).
            my $blame_args = _sq($file);
            if (defined $max_lines || defined $start_line) {
                my $start = defined $start_line ? $start_line : 1;
                my $end   = defined $max_lines  ? ($start + $max_lines - 1) : $start + 199;
                $blame_args = "-L $start,$end " . _sq($file);
            }
            my $output = `git blame $blame_args 2>&1`;
            return $self->success_result(
                $output,
                action_description => "viewing blame for $file",
                file => $file,
            );
        });
    };

    if ($@) {
        return $self->error_result("Git blame failed: " . $self->_clean_eval_error($@));
    }

    return $result;
}

sub stash {
    my ($self, $params, $context) = @_;

    my $repo_path = $params->{repository_path} || '.';
    my $action = $params->{sub_action} || $params->{action} || 'list';  # save, list, apply, drop, clear
    my $index = $params->{index} // 0;

    # Validate parameters upfront. See branch() for rationale.
    my %valid_actions = map { $_ => 1 } qw(save list apply drop clear);
    unless ($valid_actions{$action}) {
        return $self->error_result(
            "Invalid action '$action'. Must be one of: save, list, apply, drop, clear"
        );
    }

    my $result;

    eval {
        $result = _in_repo($repo_path, sub {
            my $output;
            if ($action eq 'save') {
                my $message = $params->{message} || 'stash';
                $output = `git stash save @{[_sq($message)]} 2>&1`;
            } elsif ($action eq 'list') {
                $output = `git stash list 2>&1`;
            } elsif ($action eq 'apply') {
                my $safe_idx = int($index);
                $output = `git stash apply stash\@{$safe_idx} 2>&1`;
            } elsif ($action eq 'drop') {
                my $safe_idx = int($index);
                $output = `git stash drop stash\@{$safe_idx} 2>&1`;
            } elsif ($action eq 'clear') {
                $output = `git stash clear 2>&1`;
            } else {
                croak "Internal: unhandled stash action '$action' (validation should have caught this)";
            }
            
            my $action_desc = $action eq 'save' 
                ? "saving stash"
                : $action eq 'list'
                ? "listing stashes"
                : "$action stash";
            
            return $self->success_result(
                $output,
                action_description => $action_desc,
                action => $action,
            );
        });
    };

    if ($@) {
        return $self->error_result("Git stash failed: " . $self->_clean_eval_error($@));
    }

    return $result;
}

sub tag {
    my ($self, $params, $context) = @_;

    my $repo_path = $params->{repository_path} || '.';
    my $action = $params->{sub_action} || $params->{action} || 'list';  # list, create, delete
    my $name = $params->{name} || '';

    # Validate parameters upfront. See branch() for rationale.
    my %valid_actions = map { $_ => 1 } qw(list create delete);
    unless ($valid_actions{$action}) {
        return $self->error_result(
            "Invalid action '$action'. Must be one of: list, create, delete"
        );
    }
    unless ($action eq 'list' || $name) {
        return $self->error_result(
            "Missing required parameter: name (required for action '$action')"
        );
    }

    my $result;

    eval {
        $result = _in_repo($repo_path, sub {
            my $output;
            if ($action eq 'list') {
                $output = `git tag 2>&1`;
            } elsif ($action eq 'create' && $name) {
                my $message = $params->{message} || '';
                if ($message) {
                    $output = `git tag -a @{[_sq($name)]} -m @{[_sq($message)]} 2>&1`;
                } else {
                    $output = `git tag @{[_sq($name)]} 2>&1`;
                }
            } elsif ($action eq 'delete' && $name) {
                $output = `git tag -d @{[_sq($name)]} 2>&1`;
            } else {
                croak "Internal: unhandled tag action '$action' (validation should have caught this)";
            }
            
            my $action_desc = $action eq 'list'
                ? "listing tags"
                : "$action tag" . ($name ? " '$name'" : "");
            
            return $self->success_result(
                $output,
                action_description => $action_desc,
                action => $action,
                tag_name => $name,
            );
        });
    };

    if ($@) {
        return $self->error_result("Git tag failed: " . $self->_clean_eval_error($@));
    }

    return $result;
}

sub worktree {
    my ($self, $params, $context) = @_;
    
    my $repo_path = $params->{repository_path} || '.';
    my $action = $params->{sub_action} || $params->{action} || 'list';  # list, add, remove, prune, merge, pr
    my $worktree_path = $params->{worktree_path} || '';
    my $branch = $params->{branch} || '';
    my $force = $params->{force} || 0;
    my $create_branch = $params->{create_branch} || 0;

    # Validate parameters upfront. See branch() for rationale.
    my %valid_actions = map { $_ => 1 } qw(list add remove prune merge pr);
    unless ($valid_actions{$action}) {
        return $self->error_result(
            "Invalid action '$action'. Must be one of: list, add, remove, prune, merge, pr"
        );
    }
    if (($action eq 'add' || $action eq 'remove') && !$worktree_path) {
        return $self->error_result(
            "Missing required parameter: worktree_path (required for action '$action')"
        );
    }
    if (($action eq 'merge' || $action eq 'pr') && !$worktree_path) {
        return $self->error_result(
            "Missing required parameter: worktree_path (required for action '$action')"
        );
    }

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
    
    my $main_error;
    _in_repo($repo_path, sub {
        eval {
        my $output;
        if ($action eq 'list') {
            $output = `git worktree list 2>&1`;
            my $exit = $? >> 8;
            croak "git worktree list failed (exit $exit):\n$output" if $exit != 0;
        } elsif ($action eq 'add') {
            my $cmd = "git worktree add";
            if ($create_branch && $branch) {
                $cmd .= " -b " . _sq($branch);
            }
            $cmd .= " " . _sq($worktree_path);
            $cmd .= " " . _sq($branch) if $branch && !$create_branch;
            $cmd .= " 2>&1";
            $output = `$cmd`;
            my $exit = $? >> 8;
            croak "git worktree add failed (exit $exit):\n$output" if $exit != 0;
        } elsif ($action eq 'remove') {
            my $cmd = "git worktree remove";
            $cmd .= " --force" if $force;
            $cmd .= " " . _sq($worktree_path) . " 2>&1";
            $output = `$cmd`;
            my $exit = $? >> 8;
            croak "git worktree remove failed (exit $exit):\n$output" if $exit != 0;
        } elsif ($action eq 'prune') {
            $output = `git worktree prune 2>&1`;
            my $exit = $? >> 8;
            croak "git worktree prune failed (exit $exit):\n$output" if $exit != 0;
        } elsif ($action eq 'merge' || $action eq 'pr') {
            # Resolve the branch name from the worktree
            my $wt_list = `git worktree list --porcelain 2>&1`;
            my $wt_branch = $self->_resolve_worktree_branch($wt_list, $worktree_path);
            croak "Could not find worktree '$worktree_path' in worktree list. Use action 'list' to see available worktrees." unless $wt_branch;

            if ($action eq 'merge') {
                $output = `git merge @{[_sq($wt_branch)]} 2>&1`;
                my $exit = $? >> 8;
                croak "git merge failed (exit $exit):\n$output" if $exit != 0;
            } else {
                # pr: push branch to remote, then provide PR info
                my $remote = $params->{remote} || 'origin';
                my $push_output = `git push @{[_sq($remote)]} @{[_sq($wt_branch)]} 2>&1`;
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
        } else {
            croak "Internal: unhandled worktree action '$action' (validation should have caught this)";
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
    $main_error = $@;
    }); # end _in_repo

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
        return $self->error_result("Git worktree failed: " . $self->_clean_eval_error($main_error));
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
    
    # Get project directory
    my $project_dir = getcwd();
    if ($context->{session} && $context->{session}->{state}) {
        my $session_wd = $context->{session}->{state}->{working_directory};
        $project_dir = $session_wd if $session_wd;
    }
    $project_dir = abs_path($project_dir) || $project_dir;
    
    # Expand tilde
    $path = expand_tilde($path);
    
    # Resolve path
    my $resolved_path;
    if ($path =~ m{^/}) {
        $resolved_path = abs_path($path) || $path;
    } else {
        my $full_path = File::Spec->rel2abs($path, $project_dir);
        $resolved_path = abs_path($full_path) || $full_path;
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
    return _in_repo($path, sub {
        my $nulldev = $^O eq 'MSWin32' ? 'nul' : '/dev/null';
        my $is_repo = -d '.git' || `git rev-parse --git-dir 2>$nulldev`;
        return $is_repo ? 1 : 0;
    });
}

=head2 get_additional_parameters

Define parameters specific to version_control tool.

NOTE: Descriptions are minimal - detailed docs are in tool's main description.

Returns: Hashref of parameter definitions

=cut

sub get_additional_parameters {
    my ($self) = @_;
    
    return {
        repository_path => {
            type => "string",
            description => "[OPTIONAL] Path to git repository. Default: current directory.",
        },
        message => {
            type => "string",
            description => "[REQUIRED for commit] Commit message describing the changes.",
        },
        auto_stage => {
            type => "boolean",
            description => "[OPTIONAL for commit] When true (default), runs 'git add -A' before committing, picking up all tracked AND untracked files in the working tree. Set to 0 to commit only what is already staged. To commit specific files, run `git add <paths>` via terminal_operations first, then pass auto_stage=0.",
        },
        ref1 => {
            type => "string",
            description => "[OPTIONAL] First ref for diff. Default: 'HEAD' (working directory).",
        },
        ref2 => {
            type => "string",
            description => "[OPTIONAL] Second ref for diff (e.g., 'HEAD~1').",
        },
        file => {
            type => "string",
            description => "[REQUIRED for blame, OPTIONAL for diff] File path to annotate or diff.",
        },
        start_line => {
            type => "integer",
            description => "[OPTIONAL for blame] Starting line number to annotate (1-indexed). Defaults to 1. Ignored for non-blame operations.",
        },
        max_lines => {
            type => "integer",
            description => "[OPTIONAL for blame] Maximum number of blame entries to return. Defaults to 200. Prevents full-file dumps for large files. Use start_line + max_lines to page through.",
        },
        sub_action => {
            type => "string",
            description => "[REQUIRED for branch|stash|tag|worktree] Sub-action: list, create, delete, switch, add, remove, save, apply, drop, prune, merge, pr.",
        },
        name => {
            type => "string",
            description => "[OPTIONAL] Branch, tag, or stash name. Required for create/delete operations.",
        },
        remote => {
            type => "string",
            description => "[OPTIONAL] Remote name for push/pull. Default: 'origin'.",
        },
        branch => {
            type => "string",
            description => "[OPTIONAL] Branch name for push/pull or worktree operations.",
        },
        limit => {
            type => "integer",
            description => "[OPTIONAL] Number of log entries to show. Default: 10.",
        },
        index => {
            type => "integer",
            description => "[OPTIONAL] Stash index for apply/drop operations (0 = most recent).",
        },
        worktree_path => {
            type => "string",
            description => "[REQUIRED for worktree add/remove, OPTIONAL for other worktree actions] Path for worktree operations.",
        },
        create_branch => {
            type => "boolean",
            description => "[OPTIONAL] Create a new branch when adding a worktree. Use with branch parameter.",
        },
        force => {
            type => "boolean",
            description => "[OPTIONAL] Force removal of a worktree even if it has modifications.",
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
