package CLIO::Session::Lock;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use Carp qw(croak);
use CLIO::Core::Logger qw(log_debug);
use CLIO::Util::PathResolver;
use File::Spec;
use Fcntl qw(:flock SEEK_SET);
use Time::HiRes qw(time);
use JSON::PP;

=head1 NAME

CLIO::Session::Lock - Session locking mechanism to prevent concurrent access

=head1 DESCRIPTION

Implements file-based locking to prevent multiple CLIO agents from resuming
the same session simultaneously. Uses flock() for cross-process locking.

=head1 SYNOPSIS

    use CLIO::Session::Lock;
    
    # Acquire lock when resuming session
    my $lock = CLIO::Session::Lock->acquire($session_id);
    croak "Session locked by another process" unless $lock;
    
    # Lock is automatically released when $lock goes out of scope
    # or explicitly:
    $lock->release();

=head1 METHODS

=head2 acquire

Attempt to acquire a lock on a session.

Arguments:
- $session_id: Session identifier to lock
- %options: Optional parameters
  - timeout: Maximum seconds to wait for lock (default: 0 = no wait)
  - force: Force remove stale locks (default: false)

Returns: Lock object on success, undef on failure

=cut

sub acquire {
    my ($class, $session_id, %options) = @_;
    
    croak "Session ID required for locking" unless $session_id;
    
    my $lock_file = _get_lock_file($session_id);
    my $timeout = $options{timeout} // 0;
    my $force = $options{force} // 0;
    
    log_debug('SessionLock', "Attempting to acquire lock: $lock_file");
    
    # Check for stale lock and force removal if requested
    if ($force && -f $lock_file) {
        if (_is_lock_stale($lock_file)) {
            log_debug('SessionLock', "Removing stale lock file");
            unlink $lock_file;
        }
    }
    
    # Try to acquire lock with timeout
    my $start_time = time();
    my $fh;
    
    while (1) {
        # Try to open lock file exclusively
        if (open $fh, '>', $lock_file) {
            # Try to get exclusive lock
            if (flock($fh, LOCK_EX | LOCK_NB)) {
                # Lock acquired successfully
                log_debug('SessionLock', "Lock acquired successfully");
                
                # Write lock metadata
                my $lock_info = {
                    pid => $$,
                    hostname => _get_hostname(),
                    timestamp => time(),
                    session_id => $session_id,
                };
                
                print $fh JSON::PP->new->pretty->encode($lock_info);
                $fh->flush();
                
                # Create lock object
                my $self = {
                    session_id => $session_id,
                    lock_file => $lock_file,
                    fh => $fh,
                    acquired_at => time(),
                };
                
                bless $self, $class;
                return $self;
            } else {
                # Lock held by another process
                close $fh;
            }
        }
        
        # Check timeout
        if (time() - $start_time >= $timeout) {
            log_debug('SessionLock', "Failed to acquire lock (timeout)");
            return undef;
        }
        
        # Wait a bit before retrying
        select(undef, undef, undef, 0.1);  # Sleep 100ms
    }
}

=head2 release

Explicitly release the lock.

Normally locks are released automatically when the object is destroyed,
but this can be called to release earlier.

=cut

sub release {
    my ($self) = @_;
    
    return unless $self->{fh};
    
    log_debug('SessionLock', "Releasing lock: $self->{lock_file}");
    
    # Release flock and close file handle
    flock($self->{fh}, LOCK_UN);
    close $self->{fh};
    delete $self->{fh};
    
    # Remove lock file
    unlink $self->{lock_file} if -f $self->{lock_file};
    
    log_debug('SessionLock', "Lock released");
}

=head2 is_locked

Check if a session is currently locked without trying to acquire.

Arguments:
- $session_id: Session identifier to check

Returns: true if locked, false otherwise

=cut

sub is_locked {
    my ($class, $session_id) = @_;
    
    my $lock_file = _get_lock_file($session_id);
    
    return 0 unless -f $lock_file;
    
    # Try to read lock file to check if it's valid
    if (open my $fh, '<', $lock_file) {
        # Try to get shared lock (will fail if exclusively locked)
        if (flock($fh, LOCK_SH | LOCK_NB)) {
            # Not exclusively locked
            flock($fh, LOCK_UN);
            close $fh;
            
            # Check if lock is stale
            return !_is_lock_stale($lock_file);
        } else {
            # Exclusively locked by another process
            close $fh;
            return 1;
        }
    }
    
    return 0;
}

=head2 get_lock_info

Get information about who holds the lock.

Arguments:
- $session_id: Session identifier

Returns: Hash ref with lock info (pid, hostname, timestamp), or undef

=cut

sub get_lock_info {
    my ($class, $session_id) = @_;
    
    my $lock_file = _get_lock_file($session_id);
    
    return undef unless -f $lock_file;
    
    if (open my $fh, '<', $lock_file) {
        local $/;
        my $content = <$fh>;
        close $fh;
        
        eval {
            return JSON::PP->new->decode($content);
        };
    }
    
    return undef;
}

# Private methods

sub _get_lock_file {
    my ($session_id) = @_;
    
    my $sessions_dir = CLIO::Util::PathResolver::get_sessions_dir();
    return File::Spec->catfile($sessions_dir, "$session_id.lock");
}

sub _is_lock_stale {
    my ($lock_file) = @_;
    
    # Read lock info
    my $info;
    if (open my $fh, '<', $lock_file) {
        local $/;
        my $content = <$fh>;
        close $fh;
        
        eval {
            $info = JSON::PP->new->decode($content);
        };
    }
    
    return 1 unless $info;  # Can't read lock info = stale
    
    # Check if process is still alive
    if ($info->{pid}) {
        # On Unix, kill(0, $pid) checks if process exists without sending signal
        unless (kill(0, $info->{pid})) {
            log_debug('SessionLock', "Lock is stale (process $info->{pid} not running)");
            return 1;
        }
    }
    
    # Check if lock is unreasonably old (> 24 hours)
    if ($info->{timestamp}) {
        my $age = time() - $info->{timestamp};
        if ($age > 86400) {  # 24 hours
            log_debug('SessionLock', "Lock is stale (age: ${age}s > 24h)");
            return 1;
        }
    }
    
    return 0;  # Lock is valid
}

sub _get_hostname {
    # Try to get hostname using various methods
    my $hostname = $ENV{HOSTNAME} || $ENV{HOST};
    
    unless ($hostname) {
        # Try using hostname command
        $hostname = `hostname 2>/dev/null`;
        chomp $hostname if $hostname;
    }
    
    return $hostname || 'unknown';
}

# Destructor - automatically release lock when object is destroyed
sub DESTROY {
    my ($self) = @_;
    $self->release() if $self->{fh};
}

1;

=head1 LOCK FILE FORMAT

Lock files are stored as <session_id>.lock in the sessions directory.

Format (JSON):
```json
{
    "pid": 12345,
    "hostname": "macbook.local",
    "timestamp": 1706300000.123,
    "session_id": "abc-123-def"
}
```

=head1 STALE LOCK DETECTION

A lock is considered stale if:
- The process ID no longer exists
- The lock is older than 24 hours
- The lock file cannot be read

=head1 NOTES

Uses flock() for advisory locking. Works across processes on the same machine.
Not suitable for distributed/network filesystems (NFS, etc).

=cut

1;
