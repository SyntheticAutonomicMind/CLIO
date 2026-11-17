# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Security::PathAuthorizer;

use strict;
use warnings;
use utf8;
use CLIO::Core::Logger qw(log_debug log_warning);
use File::Spec;
use Cwd qw(abs_path realpath);
use CLIO::Util::PathResolver qw(expand_tilde);

=head1 NAME

CLIO::Security::PathAuthorizer - Authorization guard for file path operations

=head1 SYNOPSIS

    use CLIO::Security::PathAuthorizer;

    my $pa = CLIO::Security::PathAuthorizer->new(%rules);
    if (!$pa->is_allowed('/some/path', 'read')) {
        die "Path access denied";
    }

=head1 DESCRIPTION

Implements path-based authorization for file operations.
Based on SAM's MCPAuthorizationGuard and AuthorizationManager patterns.

**AUTHORIZATION POLICY:**
- Operations INSIDE working directory (session dir): AUTO-APPROVED
- Operations OUTSIDE working directory: REQUIRE user authorization

This provides a secure sandbox model where agents have full control within
their designated workspace but must ask permission for operations outside that scope.

**Grant Types:**
- One-time: Authorization consumed after first use (default)
- Session: Valid for entire session (one_time_use => 0), and restored when the
  session is resumed

=cut

# Grants live in CLIO::Security::GrantStore under the 'path' scope. The store is
# process-wide on purpose: file_operations and apply_patch each build their own
# authorizer, so instance-local storage made a grant approved through one tool
# invisible to the other.
use CLIO::Security::GrantStore;
use CLIO::Security::Consent;

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        debug => $opts{debug} || 0,
    };
    
    return bless $self, $class;
}

=head2 checkPathAuthorization

Check if a file path operation requires user authorization.

Arguments:
- path: The file path to check (will be expanded and normalized)
- working_directory: The conversation's working directory (safe workspace)
- conversation_id: The conversation context
- operation: The operation key (e.g., "file_operations.create_file")
- is_user_initiated: If true, bypass authorization (user directly initiated)

Returns: Hashref with:
- status: 'allowed', 'denied', or 'requires_authorization'
- reason: Explanation of the decision

=cut

sub checkPathAuthorization {
    my ($self, %args) = @_;
    
    my $path = $args{path};
    my $working_directory = $args{working_directory};
    my $conversation_id = $args{conversation_id};
    my $operation = $args{operation};
    my $is_user_initiated = $args{is_user_initiated} || 0;
    
    # User-initiated operations always allowed
    if ($is_user_initiated) {
        log_debug('PathAuthorizer', "Operation allowed - user initiated");
        return {
            status => 'allowed',
            reason => 'User-initiated operation',
        };
    }
    
    # Resolve path against working directory (handles relative paths properly)
    my $normalized_path = $self->resolvePath($path, $working_directory);
    
    # If no working directory configured, require authorization
    unless ($working_directory) {
        log_debug('PathAuthorizer', "Authorization required - no working directory");
        return {
            status => 'requires_authorization',
            reason => 'No working directory configured for this conversation',
        };
    }
    
    # Expand and normalize working directory path
    my $working_dir_path = $self->resolvePath($working_directory, undef);
    
    # Proper subdirectory containment check: exact match OR prefix with
    # trailing slash.  This ensures "/workspace/conv-123" does NOT match
    # "/workspace/conv-123-other" (the directory-boundary bug that a naive
    # hasPrefix() check would introduce).
    my $is_inside_working_directory = ($normalized_path eq $working_dir_path) ||
                                       ($normalized_path =~ /^\Q$working_dir_path\E\//);
    
    log_debug('PathAuthorizer', "Authorization check: path=$normalized_path, workingDir=$working_dir_path, inside=$is_inside_working_directory");
    
    if ($is_inside_working_directory) {
        # Path is inside working directory - ALLOW unrestricted access
        log_debug('PathAuthorizer', "Operation allowed - inside working directory");
        return {
            status => 'allowed',
            reason => 'Path is inside working directory',
        };
    }
    
    # Path is outside working directory - check if authorized
    if ($conversation_id && $self->isAuthorized($conversation_id, $operation, $normalized_path)) {
        log_debug('PathAuthorizer', "Operation allowed - previously authorized");
        return {
            status => 'allowed',
            reason => 'User previously authorized this operation',
        };
    }
    
    # Require authorization for operations outside working directory
    log_debug('PathAuthorizer', "Authorization required - outside working directory");
    return {
        status => 'requires_authorization',
        reason => "Path '$normalized_path' is outside working directory '$working_dir_path'",
    };
}

=head2 resolvePath

Resolve a path (relative or absolute) against the working directory.

This is the CANONICAL path resolution function - all path checks should use this.

Arguments:
- path: The path to resolve (relative or absolute)
- working_directory: The working directory to use as base for relative paths (optional)

Returns: Fully resolved absolute path

=cut

sub resolvePath {
    my ($self, $path, $working_directory) = @_;

    # Expand tilde first
    $path = expand_tilde($path);

    # If relative path with working directory, resolve first
    if ($working_directory && $path !~ m{^/}) {
        $working_directory = expand_tilde($working_directory);
        $path = File::Spec->rel2abs($path, $working_directory);
    }

    # Collapse "." and ".." lexically before consulting the filesystem.
    # realpath() only succeeds on paths that exist, and the paths this guard
    # most needs to judge are create and write targets that do not exist yet.
    # Unnormalized, "<session>/tmp/../../etc/passwd" came back verbatim: still
    # carrying the session prefix, so the containment test passed, while the
    # operating system resolved the write outside the session.
    $path = _normalize_components($path);

    # Existing path: realpath resolves symlinks as well as the lexical form.
    my $resolved = realpath($path);
    return $resolved if $resolved;

    # Path does not exist yet: resolve the deepest existing ancestor and
    # re-attach the remaining components, which are already normalized so
    # none of them can be "..".
    my ($volume, $directories, undef) = File::Spec->splitpath($path, 1);
    my @components = grep { length } File::Spec->splitdir($directories);
    my $root = length $volume ? File::Spec->catdir($volume) : '/';

    my @tail;
    while (1) {
        my $candidate = @components
            ? File::Spec->catpath($volume, File::Spec->catdir(@components), '')
            : $root;
        if (-e $candidate) {
            my $base = realpath($candidate) || $candidate;
            return @tail ? File::Spec->catfile($base, @tail) : $base;
        }
        last unless @components;
        unshift @tail, pop @components;
    }

    # Nothing on the path exists, not even the root.
    return $path;
}

=head2 _normalize_components (Internal)

Collapse C{.} and C{..} in a path without touching the filesystem.

L<File::Spec/canonpath> declines to collapse C{..} because that is only sound
once symlinks are known. For a containment check the lexical reading is the
correct one: C{..} is resolved against the directory tree, and a path that
walks above the session directory has to be judged by where it lands rather
than by the string that was typed. A C{..} with nothing left to cancel stays
at the root, matching POSIX.

Do not call directly.

=cut

sub _normalize_components {
    my ($path) = @_;
    return $path unless defined $path && length $path;

    my ($volume, $directories, undef) = File::Spec->splitpath($path, 1);
    my @parts = grep { length } File::Spec->splitdir($directories);
    my $absolute = ($path =~ m{^/}) || length($volume) > 1;

    my @out;
    for my $part (@parts) {
        next if $part eq '.';
        if ($part eq '..') {
            if (@out && $out[-1] ne '..') {
                pop @out;
            }
            push @out, $part unless $absolute;
            next;
        }
        push @out, $part;
    }

    return @out
        ? File::Spec->catpath($volume, File::Spec->catdir(@out), '')
        : (length $volume ? File::Spec->catdir($volume) : '/');
}

=head2 grantAuthorization

Grant temporary authorization for a specific operation within a conversation.

Arguments:
- conversation_id: The conversation where authorization was granted
- operation: The operation to authorize (e.g., "file_operations.create_file")
- one_time_use: If true, authorization is consumed after first use (default: true)

=cut

sub grantAuthorization {
    my ($self, $conversation_id, $operation, $one_time_use, $path, %opts) = @_;
    
    return unless $conversation_id && $operation;
    
    $one_time_use //= 1;  # Default to one-time use
    
    CLIO::Security::GrantStore::grant(
        'path',
        $self->_grant_key($conversation_id, $operation, $path),
        data => {
            conversation_id => $conversation_id,
            operation       => $operation,
            path            => $path,
            one_time_use    => $one_time_use,
            consumed        => 0,
            prefix          => $opts{prefix} ? 1 : 0,
        },
    );
    
    log_debug('PathAuthorizer', "Authorization granted: conversation=$conversation_id, operation=$operation, path=" . ($path // '*') . ", oneTime=$one_time_use");
}

=head2 _grant_key (Internal)

Build the storage key for one grant.

A grant is scoped to a conversation, an operation, and - when a path is
supplied - to that path. Approving one write outside the session directory
must not unlock every other path for the rest of the conversation.

A grant recorded without a path matches any path; it is only created by
explicit bulk approval. A grant recorded with C<prefix> set matches the
directory and everything below it, which is what C<(a)llow this path> means:
approving a write into a directory opens that directory, not the filesystem.

Do not call directly.

=cut

sub _grant_key {
    my ($self, $conversation_id, $operation, $path) = @_;
    return ($conversation_id // '') . '|' . $operation . '|'
        . ((defined $path && length $path) ? $path : '*');
}

=head2 isAuthorized

Check if an operation is authorized and consume the authorization if one-time use.

Arguments:
- conversation_id: The conversation context
- operation: The operation to check

Returns: True if authorized, false otherwise

=cut

sub isAuthorized {
    my ($self, $conversation_id, $operation, $path) = @_;
    
    return 0 unless $conversation_id;
    
    # Most specific first: the exact path, then any approved parent directory
    # (closest first), then a wildcard grant. An exact-path grant is consumed
    # before a wildcard grant for the same operation is considered.
    my @candidates;
    if (defined $path && length $path) {
        push @candidates, { path => $path, prefix => 0 };
        push @candidates, map { { path => $_, prefix => 1 } } $self->_ancestor_dirs($path);
    }
    push @candidates, { path => undef, prefix => 0 };
    
    for my $candidate (@candidates) {
        my $key = $self->_grant_key($conversation_id, $operation, $candidate->{path});
        next unless CLIO::Security::GrantStore::is_granted('path', $key);

        my $data = (CLIO::Security::GrantStore::get('path', $key) || {})->{data} || {};
        next if $data->{consumed};
        # Only a grant recorded as a directory approval covers a directory
        # other than the one it names; an exact-path grant never widens.
        next if $candidate->{prefix} && !$data->{prefix};
        
        # Consume if one-time use
        if ($data->{one_time_use}) {
            $data->{consumed} = 1;
            CLIO::Security::GrantStore::grant('path', $key, data => $data);
            log_debug('PathAuthorizer', "Authorization consumed: conversation=$conversation_id, operation=$operation, path=" . ($candidate->{path} // '*'));
        }
        
        return 1;
    }
    
    return 0;
}

=head2 _ancestor_dirs (Internal)

Return the directories containing C<$path>, nearest first, excluding the
filesystem root.

The root is excluded on purpose: approving a write into C</tmp> must not
produce a grant that matches everything on the system.

Do not call directly.

=cut

sub _ancestor_dirs {
    my ($self, $path) = @_;

    require File::Basename;
    my @dirs;
    my $dir = File::Basename::dirname($path);

    while (defined $dir && length $dir && $dir ne '/' && $dir ne '.' && $dir ne $path) {
        push @dirs, $dir;
        my $parent = File::Basename::dirname($dir);
        last if !defined $parent || $parent eq $dir;
        $dir = $parent;
    }

    return @dirs;
}

=head2 revokeAuthorization

Revoke a specific authorization.

Arguments:
- conversation_id: The conversation context
- operation: The operation to revoke

=cut

sub revokeAuthorization {
    my ($self, $conversation_id, $operation, $path) = @_;
    
    return unless $conversation_id;
    
    if (defined $path && length $path) {
        # Revoke only the grant for this exact path.
        CLIO::Security::GrantStore::revoke('path', $self->_grant_key($conversation_id, $operation, $path));
    }
    else {
        # No path given: revoke the operation outright, whichever paths it was
        # granted for. Grants are keyed "<conversation>|<operation>|<path>", so the prefix
        # identifies every variant of this operation.
        my $prefix = $conversation_id . '|' . $operation . '|';
        for my $key (CLIO::Security::GrantStore::keys_for('path')) {
            CLIO::Security::GrantStore::revoke('path', $key)
                if index($key, $prefix) == 0;
        }
    }
    
    log_debug('PathAuthorizer', "Authorization revoked: conversation=$conversation_id, operation=$operation, path=" . ($path // '*'));
}

=head2 revokeAllForConversation

Revoke all authorizations for a conversation.

Arguments:
- conversation_id: The conversation context

=cut

sub revokeAllForConversation {
    my ($self, $conversation_id) = @_;
    
    return unless $conversation_id;
    
    my $prefix = $conversation_id . '|';
    my $count = 0;
    for my $key (CLIO::Security::GrantStore::keys_for('path')) {
        next unless index($key, $prefix) == 0;
        $count++ if CLIO::Security::GrantStore::revoke('path', $key);
    }
    
    log_debug('PathAuthorizer', "All authorizations revoked: conversation=$conversation_id, count=$count");
}

=head2 authorize_or_prompt

Check authorization, and when a path needs approval, offer the user the chance
to grant it before reporting a failure.

Without this the guard was a dead end: every denial told the caller to obtain
authorization through a mechanism that never granted paths, so writes outside
the session directory could not be approved at all.

Arguments: the same as checkPathAuthorization, plus
- prompt: coderef invoked as C<$prompt->(%details)> when approval is needed.
  It must return 'once', 'all', or 'deny'. Omit it to get the plain
  checkPathAuthorization behaviour.

Returns: the checkPathAuthorization status hashref, with C<granted> set to
'once' or 'all' when the user approved this call.

=cut

sub authorize_or_prompt {
    my ($self, %args) = @_;
    
    my $prompt = $args{prompt};
    
    my $result = $self->checkPathAuthorization(%args);
    return $result unless $result->{status} eq 'requires_authorization';
    return $result unless $prompt;
    
    my $normalized_path = $self->resolvePath($args{path}, $args{working_directory});
    my $conversation_id = $args{conversation_id};
    my $operation       = $args{operation};
    
    my $decision = eval {
        $prompt->(
            path      => $normalized_path,
            operation => $operation,
            reason    => $result->{reason},
        );
    } || 'deny';
    
    if ($decision eq 'all') {
        # Approval covers the directory the approved path lives in, not every
        # path this operation will ever touch. Approving one file in a
        # directory should not open the rest of the filesystem, and scoping to
        # the directory keeps the common case - writing several files into one
        # directory - prompt-free.
        require File::Basename;
        my $scope_dir = File::Basename::dirname($normalized_path);
        $self->grantAuthorization($conversation_id, $operation, 0, $scope_dir, prefix => 1);
        log_debug('PathAuthorizer', "User approved directory: operation=$operation, dir=$scope_dir");
        return {
            status  => 'allowed',
            reason  => "User approved this operation in '$scope_dir' for the rest of the session",
            granted => 'all',
            scope   => $scope_dir,
        };
    }
    
    if ($decision eq 'once') {
        # Nothing is stored: this approval covers only the write in flight.
        # Recording a one-time grant here would leave it available for the
        # next write, so "once" would quietly authorise two operations.
        log_debug('PathAuthorizer', "User approved once: operation=$operation, path=$normalized_path");
        return {
            status  => 'allowed',
            reason  => 'User approved this operation once',
            granted => 'once',
        };
    }
    
    return {
        status => 'denied',
        reason => "User denied access to '$normalized_path'",
    };
}

=head2 prompt_for_path_authorization(%args)

Ask the user to approve writing outside the session directory.

Arguments:
- path: resolved path awaiting approval
- reason: why approval is required
- ui: interactive UI object (optional)
- broker_client: broker client for headless sub-agents (optional)

Returns: 'once', 'session', or 'deny'.

This lives here rather than in the calling tools because both file_operations
and apply_patch need the identical prompt, and duplicating it is how the two
drifted apart in the first place.

=cut

sub prompt_for_path_authorization {
    my (%args) = @_;
    
    my $path          = $args{path} || '(unknown path)';
    my $reason        = $args{reason} || 'Path is outside the session directory';
    my $ui            = $args{ui};
    my $broker_client = $args{broker_client};
    
    # Interactive prompt
    if ($ui && $ui->can('colorize')) {
        my $spinner = $args{spinner};

        my $theme_mgr = $ui->{theme_mgr};
        my $options   = CLIO::Security::Consent::options_text(allow_label => 'this directory');

        return CLIO::Security::Consent::read_answer(
            caller  => 'PathAuthorizer',
            spinner => $spinner,
            prompt  => sub {
                if ($theme_mgr && $theme_mgr->can('get_security_prompt')) {
                    my ($prompt_line, $input_line) = $theme_mgr->get_security_prompt(
                        $path,
                        [{ category => 'path_access', severity => 'standard', description => $reason }],
                        $options,
                    );
                    print "\n$prompt_line\n$input_line";
                } else {
                    print "\n* Security | $path\n  $reason\n  $options: ";
                }
            },
        );
    }
    
    # No TTY: relay the request through the broker for headless sub-agents.
    if ($broker_client) {
        log_debug('PathAuthorizer', "No TTY - relaying path authorization through broker");
        require CLIO::Security::AuthorizationRelay;
        my $relay = CLIO::Security::AuthorizationRelay->new(broker_client => $broker_client);
        if ($relay->available()) {
            my $result = $relay->request_path_authorization($path, { reason => $reason });
            return 'deny' unless $result->{approved};
            return $result->{grant_type} eq 'all' ? 'all' : 'once';
        }
    }
    
    log_debug('PathAuthorizer', "No interactive channel - denying path authorization for $path");
    return 'deny';
}

=head2 list_path_grants

Return every active grant, for display.

Returns: arrayref of hashrefs with conversation_id, operation, path, session.

=cut

sub list_path_grants {
    my @grants;
    
    for my $grant (CLIO::Security::GrantStore::list_grants()) {
        next unless $grant->{scope} eq 'path';
        my $data = $grant->{data} || {};
        next if $data->{consumed};
        push @grants, {
            conversation_id => $data->{conversation_id},
            operation       => $data->{operation},
            path            => (defined $data->{path} && length $data->{path}) ? $data->{path} : undef,
            session         => $data->{one_time_use} ? 0 : 1,
            granted_at      => $grant->{granted_at},
        };
    }
    
    return \@grants;
}

=head2 reset_path_grants

Clear every path grant and every auto-approve flag.

Called by C</security reset> alongside the other grant resets so one command
restores interactive prompting for all categories.

Returns: number of grants cleared.

=cut

sub reset_path_grants {
    my $count = CLIO::Security::GrantStore::reset_scope('path');
    
    log_debug('PathAuthorizer', "All path grants reset, count=$count");
    
    return $count;
}

1;
