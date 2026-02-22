package CLIO::Security::PathAuthorizer;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(should_log log_debug log_warning);
use feature 'say';
use File::Spec;
use Cwd qw(abs_path realpath);

=head1 NAME

CLIO::Security::PathAuthorizer - Authorization guard for file path operations

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
- Session: Valid for entire session (one_time_use => 0)

**Note:** Permanent grants (persisting across sessions) are planned but not yet implemented.

=cut

sub new {
    my ($class, %opts) = @_;
    
    my $self = {
        debug => $opts{debug} || 0,
        # Grant storage: { conversation_id => { operation => grant } }
        grants => {},
        # Auto-approve conversations (bypasses all security)
        auto_approve_conversations => {},
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
    
    # Check auto-approve first (bypasses all security)
    if ($conversation_id && $self->{auto_approve_conversations}->{$conversation_id}) {
        log_debug('PathAuthorizer', "Auto-approve enabled - bypassing authorization");
        return {
            status => 'allowed',
            reason => 'Auto-approve enabled for conversation',
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
    
    # Proper subdirectory containment check
    # BUG: hasPrefix() alone is insufficient - "/workspace/conv-123" would match "/workspace/conv-123-other"
    # SOLUTION: Check for exact match OR prefix with trailing slash to ensure directory boundary
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
    if ($conversation_id && $self->isAuthorized($conversation_id, $operation)) {
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
    $path =~ s/^~/$ENV{HOME}/;
    
    # If relative path with working directory, resolve first
    if ($working_directory && $path !~ m{^/}) {
        $working_directory =~ s/^~/$ENV{HOME}/;
        $path = File::Spec->rel2abs($path, $working_directory);
    }
    
    # Now we have an absolute path - normalize it
    # For existing paths, use realpath to resolve symlinks
    my $resolved = realpath($path);
    if ($resolved) {
        return $resolved;
    }
    
    # Path doesn't exist yet - find the deepest existing parent
    # and normalize based on that
    my $current = $path;
    my @non_existent_parts;
    
    while (!-e $current) {
        my ($volume, $directories, $file) = File::Spec->splitpath($current, 1);  # 1 = is directory
        
        # If no file part, the last dir component becomes the file
        my @dirs = File::Spec->splitdir($directories);
        my $last_part = pop @dirs;
        unshift @non_existent_parts, $last_part if $last_part;
        
        # Reconstruct parent path
        $current = File::Spec->catpath($volume, File::Spec->catdir(@dirs), '');
        
        # Safety check - don't go above root
        last if $current eq '/' || $current eq '';
    }
    
    # Now $current is the deepest existing parent
    if (-e $current) {
        my $normalized_base = realpath($current);
        if ($normalized_base && @non_existent_parts) {
            # Reconstruct full path with normalized base
            return File::Spec->catfile($normalized_base, @non_existent_parts);
        } elsif ($normalized_base) {
            return $normalized_base;
        }
    }
    
    # Fallback - return original path
    return $path;
}

=head2 grantAuthorization

Grant temporary authorization for a specific operation within a conversation.

Arguments:
- conversation_id: The conversation where authorization was granted
- operation: The operation to authorize (e.g., "file_operations.create_file")
- one_time_use: If true, authorization is consumed after first use (default: true)

=cut

sub grantAuthorization {
    my ($self, $conversation_id, $operation, $one_time_use) = @_;
    
    $one_time_use //= 1;  # Default to one-time use
    
    $self->{grants}->{$conversation_id} ||= {};
    $self->{grants}->{$conversation_id}->{$operation} = {
        granted_at => time(),
        one_time_use => $one_time_use,
        consumed => 0,
    };
    
    log_debug('PathAuthorizer', "Authorization granted: conversation=$conversation_id, operation=$operation, oneTime=$one_time_use");
}

=head2 isAuthorized

Check if an operation is authorized and consume the authorization if one-time use.

Arguments:
- conversation_id: The conversation context
- operation: The operation to check

Returns: True if authorized, false otherwise

=cut

sub isAuthorized {
    my ($self, $conversation_id, $operation) = @_;
    
    return 0 unless $conversation_id;
    return 0 unless $self->{grants}->{$conversation_id};
    
    my $grant = $self->{grants}->{$conversation_id}->{$operation};
    return 0 unless $grant;
    return 0 if $grant->{consumed};
    
    # Consume if one-time use
    if ($grant->{one_time_use}) {
        $grant->{consumed} = 1;
        log_debug('PathAuthorizer', "Authorization consumed: conversation=$conversation_id, operation=$operation");
    }
    
    return 1;
}

=head2 revokeAuthorization

Revoke a specific authorization.

Arguments:
- conversation_id: The conversation context
- operation: The operation to revoke

=cut

sub revokeAuthorization {
    my ($self, $conversation_id, $operation) = @_;
    
    return unless $conversation_id;
    return unless $self->{grants}->{$conversation_id};
    
    delete $self->{grants}->{$conversation_id}->{$operation};
    
    log_debug('PathAuthorizer', "Authorization revoked: conversation=$conversation_id, operation=$operation");
}

=head2 revokeAllForConversation

Revoke all authorizations for a conversation.

Arguments:
- conversation_id: The conversation context

=cut

sub revokeAllForConversation {
    my ($self, $conversation_id) = @_;
    
    return unless $conversation_id;
    
    my $count = $self->{grants}->{$conversation_id} ? scalar(keys %{$self->{grants}->{$conversation_id}}) : 0;
    delete $self->{grants}->{$conversation_id};
    
    log_debug('PathAuthorizer', "All authorizations revoked: conversation=$conversation_id, count=$count");
}

=head2 setAutoApprove

Enable or disable auto-approve for a conversation (bypasses all security).

WARNING: This bypasses all authorization checks. Use with caution.

Arguments:
- enabled: If true, all operations are automatically authorized without prompts
- conversation_id: The conversation to enable/disable auto-approve for

=cut

sub setAutoApprove {
    my ($self, $enabled, $conversation_id) = @_;
    
    return unless $conversation_id;
    
    if ($enabled) {
        $self->{auto_approve_conversations}->{$conversation_id} = 1;
        log_warning('PathAuthorizer', "Auto-approve ENABLED - all operations authorized without user permission: conversation=$conversation_id");
    } else {
        delete $self->{auto_approve_conversations}->{$conversation_id};
        log_debug('PathAuthorizer', "Auto-approve disabled: conversation=$conversation_id");
    }
}

=head2 isAutoApproveEnabled

Check if auto-approve is enabled for a conversation.

Arguments:
- conversation_id: The conversation to check

Returns: True if auto-approve is enabled, false otherwise

=cut

sub isAutoApproveEnabled {
    my ($self, $conversation_id) = @_;
    
    return 0 unless $conversation_id;
    return $self->{auto_approve_conversations}->{$conversation_id} ? 1 : 0;
}

1;
