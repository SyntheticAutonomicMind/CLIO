package CLIO::Security::Auth;

use strict;
use warnings;
use Digest::SHA qw(sha256_hex);
use Time::HiRes qw(time);
use POSIX qw(strftime);

=head1 NAME

CLIO::Security::Auth - Authentication system for CLIO

=head1 SYNOPSIS

    use CLIO::Security::Auth;
    
    my $auth = CLIO::Security::Auth->new(debug => 1);
    my $token = $auth->authenticate($user_id, $credentials);
    my $is_valid = $auth->validate_token($token);

=head1 DESCRIPTION

This module provides a comprehensive authentication system for CLIO,
including token-based authentication, session management, and access validation.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        debug => $args{debug} || 0,
        token_expiry => $args{token_expiry} || 3600, # 1 hour default
        secret_key => $args{secret_key} || _generate_secret(),
        active_tokens => {},
        failed_attempts => {},
        max_attempts => $args{max_attempts} || 5,
        lockout_time => $args{lockout_time} || 300, # 5 minutes
        audit_log => []
    };
    
    return bless $self, $class;
}

=head2 authenticate($user_id, $credentials)

Authenticate a user and return a token if successful.

=cut

sub authenticate {
    my ($self, $user_id, $credentials) = @_;
    
    $self->_log("Authentication attempt for user: $user_id");
    
    # Check for lockout
    if ($self->_is_locked_out($user_id)) {
        $self->_log("User $user_id is locked out");
        $self->_audit('auth_failed', $user_id, 'account_locked');
        return undef;
    }
    
    # Validate credentials (simplified for demo - would integrate with real auth)
    unless ($self->_validate_credentials($user_id, $credentials)) {
        $self->_record_failed_attempt($user_id);
        $self->_audit('auth_failed', $user_id, 'invalid_credentials');
        return undef;
    }
    
    # Generate and store token
    my $token = $self->_generate_token($user_id);
    $self->{active_tokens}->{$token} = {
        user_id => $user_id,
        created => time(),
        expires => time() + $self->{token_expiry},
        last_used => time()
    };
    
    # Clear failed attempts on successful auth
    delete $self->{failed_attempts}->{$user_id};
    
    $self->_audit('auth_success', $user_id, "token_generated");
    $self->_log("Authentication successful for user: $user_id");
    
    return $token;
}

=head2 validate_token($token)

Validate a token and return user information if valid.

=cut

sub validate_token {
    my ($self, $token) = @_;
    
    return undef unless $token;
    
    my $token_data = $self->{active_tokens}->{$token};
    return undef unless $token_data;
    
    # Check expiry
    if (time() > $token_data->{expires}) {
        $self->_log("Token expired for user: $token_data->{user_id}");
        delete $self->{active_tokens}->{$token};
        $self->_audit('token_expired', $token_data->{user_id}, $token);
        return undef;
    }
    
    # Update last used time
    $token_data->{last_used} = time();
    
    $self->_log("Token validated for user: $token_data->{user_id}");
    return $token_data;
}

=head2 logout($token)

Invalidate a token (logout).

=cut

sub logout {
    my ($self, $token) = @_;
    
    my $token_data = $self->{active_tokens}->{$token};
    if ($token_data) {
        my $user_id = $token_data->{user_id};
        delete $self->{active_tokens}->{$token};
        $self->_audit('logout', $user_id, $token);
        $self->_log("User logged out: $user_id");
        return 1;
    }
    
    return 0;
}

=head2 refresh_token($old_token)

Refresh an existing token.

=cut

sub refresh_token {
    my ($self, $old_token) = @_;
    
    my $token_data = $self->validate_token($old_token);
    return undef unless $token_data;
    
    my $user_id = $token_data->{user_id};
    
    # Generate new token
    my $new_token = $self->_generate_token($user_id);
    
    # Remove old token
    delete $self->{active_tokens}->{$old_token};
    
    # Add new token
    $self->{active_tokens}->{$new_token} = {
        user_id => $user_id,
        created => time(),
        expires => time() + $self->{token_expiry},
        last_used => time()
    };
    
    $self->_audit('token_refresh', $user_id, $new_token);
    $self->_log("Token refreshed for user: $user_id");
    
    return $new_token;
}

=head2 get_user_tokens($user_id)

Get all active tokens for a user.

=cut

sub get_user_tokens {
    my ($self, $user_id) = @_;
    
    my @user_tokens;
    for my $token (keys %{$self->{active_tokens}}) {
        my $data = $self->{active_tokens}->{$token};
        if ($data->{user_id} eq $user_id) {
            push @user_tokens, {
                token => $token,
                created => $data->{created},
                expires => $data->{expires},
                last_used => $data->{last_used}
            };
        }
    }
    
    return \@user_tokens;
}

=head2 cleanup_expired_tokens()

Remove expired tokens from memory.

=cut

sub cleanup_expired_tokens {
    my ($self) = @_;
    
    my $now = time();
    my $cleaned = 0;
    
    for my $token (keys %{$self->{active_tokens}}) {
        my $data = $self->{active_tokens}->{$token};
        if ($now > $data->{expires}) {
            delete $self->{active_tokens}->{$token};
            $cleaned++;
        }
    }
    
    $self->_log("Cleaned up $cleaned expired tokens");
    return $cleaned;
}

=head2 get_statistics()

Get authentication statistics.

=cut

sub get_statistics {
    my ($self) = @_;
    
    my $now = time();
    my $active_count = 0;
    my $expired_count = 0;
    
    for my $token (keys %{$self->{active_tokens}}) {
        my $data = $self->{active_tokens}->{$token};
        if ($now > $data->{expires}) {
            $expired_count++;
        } else {
            $active_count++;
        }
    }
    
    return {
        active_tokens => $active_count,
        expired_tokens => $expired_count,
        total_tokens => scalar(keys %{$self->{active_tokens}}),
        failed_attempts => scalar(keys %{$self->{failed_attempts}}),
        audit_entries => scalar(@{$self->{audit_log}})
    };
}

=head2 get_audit_log()

Get the audit log.

=cut

sub get_audit_log {
    my ($self, $limit) = @_;
    
    my @log = @{$self->{audit_log}};
    
    if ($limit && $limit > 0) {
        @log = splice(@log, -$limit);
    }
    
    return \@log;
}

# Private methods

sub _generate_secret {
    return sha256_hex(time() . rand() . $$);
}

sub _validate_credentials {
    my ($self, $user_id, $credentials) = @_;
    
    # Simplified validation - in real implementation would check against
    # a user database or external authentication service
    
    # For demo purposes, accept any non-empty credentials
    return defined $credentials && length($credentials) > 0;
}

sub _generate_token {
    my ($self, $user_id) = @_;
    
    my $payload = join(':', $user_id, time(), rand(), $$);
    my $token = sha256_hex($payload . $self->{secret_key});
    
    return $token;
}

sub _is_locked_out {
    my ($self, $user_id) = @_;
    
    my $attempts = $self->{failed_attempts}->{$user_id};
    return 0 unless $attempts;
    
    return $attempts->{count} >= $self->{max_attempts} &&
           (time() - $attempts->{last_attempt}) < $self->{lockout_time};
}

sub _record_failed_attempt {
    my ($self, $user_id) = @_;
    
    my $attempts = $self->{failed_attempts}->{$user_id} ||= {
        count => 0,
        first_attempt => time(),
        last_attempt => 0
    };
    
    $attempts->{count}++;
    $attempts->{last_attempt} = time();
    
    $self->_log("Failed attempt #$attempts->{count} for user: $user_id");
}

sub _audit {
    my ($self, $action, $user_id, $details) = @_;
    
    push @{$self->{audit_log}}, {
        timestamp => time(),
        action => $action,
        user_id => $user_id,
        details => $details,
        formatted_time => strftime("%Y-%m-%d %H:%M:%S", localtime())
    };
    
    $self->_log("AUDIT: $action for $user_id - $details");
}

sub _log {
    my ($self, $message) = @_;
    
    return unless $self->{debug};
    
    my $timestamp = strftime("%H:%M:%S", localtime());
    warn "[DEBUG Auth $timestamp] $message\n";
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 COPYRIGHT

Copyright (c) 2025 CLIO Project. All rights reserved.

=cut
