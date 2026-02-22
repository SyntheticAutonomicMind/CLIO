if ($ENV{CLIO_DEBUG}) {
    log_debug('SessionManager', "CLIO::Session::Manager loaded");
}
package CLIO::Session::Manager;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use Carp qw(croak);
use CLIO::Core::Logger qw(log_warning log_debug log_info);
use CLIO::Session::State;
use CLIO::Session::Lock;
use CLIO::Memory::ShortTerm;
use CLIO::Memory::LongTerm;
use CLIO::Memory::YaRN;
use File::Spec;
use File::Basename;
use Cwd;
use Digest::SHA qw(sha256_hex);
use Time::HiRes qw(gettimeofday);

=head1 NAME

CLIO::Session::Manager - Session lifecycle management for CLIO

=head1 SYNOPSIS

  use CLIO::Session::Manager;
  
  # Create new session
  my $session = CLIO::Session::Manager->create(
      debug => 1,
      working_directory => '/path/to/project'
  );
  
  # Load existing session
  my $session = CLIO::Session::Manager->load(
      $session_id,
      debug => 1
  );
  
  # Access memory systems
  my $stm = $session->stm;    # Short-term memory
  my $ltm = $session->ltm;    # Long-term memory
  my $yarn = $session->yarn;  # YaRN context manager
  
  # Manage conversation history
  $session->add_message('user', 'Hello CLIO');
  $session->add_message('assistant', 'Hello! How can I help?');
  my $history = $session->get_conversation_history();
  
  # Save and cleanup
  $session->save();
  $session->cleanup();  # Releases locks

=head1 DESCRIPTION

Session::Manager orchestrates the complete session lifecycle for CLIO,
including:

- Session creation with unique UUIDs
- Session loading and locking (prevents concurrent access)
- Memory system initialization (STM, LTM, YaRN)
- Conversation history management
- Billing/usage tracking
- Session persistence and cleanup

Each session has:
- Unique ID (UUID v4 format)
- State object (history, config, metadata)
- Three memory systems (STM, LTM, YaRN)
- Lock file (prevents multi-process conflicts)
- Working directory context

=head1 METHODS

=head2 new(%args)

Create new session manager instance.

Arguments:
- session_id: UUID (auto-generated if not provided)
- debug: Enable debug logging
- working_directory: Project path (default: cwd)

=head2 create(%args)

Create new session (alias for new).

=head2 load($session_id, %args)

Load existing session from disk.

Arguments:
- session_id: Session UUID to load
- debug: Enable debug logging

Returns: Session::Manager instance or undef if load fails

Throws: Dies if session is locked by another process

=head2 save()

Persist session state to disk.

=head2 cleanup()

Release session lock and cleanup resources.

=head2 stm()

Get short-term memory instance.

Returns: CLIO::Memory::ShortTerm object

=head2 ltm()

Get long-term memory instance.

Returns: CLIO::Memory::LongTerm object

=head2 yarn()

Get YaRN context manager instance.

Returns: CLIO::Memory::YaRN object

=head2 state()

Get session state object.

Returns: CLIO::Session::State object

=head2 add_message($role, $content, $opts)

Add message to conversation history and STM.

Arguments:
- role: 'user' or 'assistant'
- content: Message text
- opts: Optional metadata hash

=head2 get_conversation_history()

Get full conversation history.

Returns: ArrayRef of message hashes

=head2 record_api_usage($usage, $model, $provider)

Record API usage for billing tracking.

=head2 get_billing_summary()

Get session billing summary.

Returns: HashRef with usage statistics

=cut


sub new {
    my ($class, %args) = @_;
    if ($ENV{CLIO_DEBUG} || $args{debug}) {
        log_debug('SessionManager', "Entered Manager::new");
        log_debug('SessionManager', "Manager::new] called with args: " . join(", ", map { "$_=$args{$_}" } keys %args));
    }
    
    # Determine working directory for loading project LTM
    my $working_dir = $args{working_directory} || Cwd::getcwd();
    
    my $self = {
        session_id => $args{session_id} // _generate_id(),
        state      => undef,
        debug      => $args{debug} // 0,
        stm        => undef,
        ltm        => undef,
        yarn       => undef,
    };
    bless $self, $class;
    
    # Load project-level LTM from .clio/ltm.json (shared across all sessions in this project)
    my $ltm_file = File::Spec->catfile($working_dir, '.clio', 'ltm.json');
    my $ltm = CLIO::Memory::LongTerm->load($ltm_file, debug => $self->{debug});
    
    my $stm  = CLIO::Memory::ShortTerm->new(debug => $self->{debug});
    my $yarn = CLIO::Memory::YaRN->new(debug => $self->{debug});
    $self->{stm}  = $stm;
    $self->{ltm}  = $ltm;
    $self->{yarn} = $yarn;
    $self->{state} = CLIO::Session::State->new(
        session_id => $self->{session_id},
        debug      => $self->{debug},
        working_directory => $working_dir,
        stm        => $stm,
        ltm        => $ltm,
        yarn       => $yarn,
    );
    if ($ENV{CLIO_DEBUG} || $self->{debug}) {
        log_debug('SessionManager', "[MANAGER] yarn object ref: $self->{yarn}");
        log_debug('Manager::new', "returning self: $self");
    }
    return $self;
}

sub _generate_id {
    # Generate UUID v4-like identifier using available Perl core modules
    # Format: xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx
    # Uses Digest::SHA (core since 5.10) for randomness
    
    my ($s, $us) = gettimeofday();
    my $pid = $$;
    my $random = rand();
    
    # Create pseudo-random data using time, PID, and random
    my $data = "$s$us$pid$random" . join('', map { rand() } 1..16);
    my $hash = sha256_hex($data);
    
    # Extract parts from hash (32 hex chars)
    my $time_low = substr($hash, 0, 8);
    my $time_mid = substr($hash, 8, 4);
    my $time_hi_version = '4' . substr($hash, 13, 3);  # Version 4
    my $clk_seq = sprintf('%x', (hex(substr($hash, 16, 2)) & 0x3F) | 0x80);  # Variant bits
    my $clk_seq_low = substr($hash, 18, 2);
    my $node = substr($hash, 20, 12);
    
    return "$time_low-$time_mid-$time_hi_version-$clk_seq$clk_seq_low-$node";
}

sub create {
    my ($class, %args) = @_;
    if ($ENV{CLIO_DEBUG} || $args{debug}) {
        log_debug('SessionManager', "Entered Manager::create");
        log_debug('SessionManager', "Manager::create] called with args: " . join(", ", map { "$_=$args{$_}" } keys %args));
    }
    my $obj = $class->new(%args);
    if ($ENV{CLIO_DEBUG} || $obj->{debug}) {
        log_debug('Manager::create', "returning: $obj");
    }
    return $obj;
}

sub load {
    my ($class, $session_id, %args) = @_;
    
    # Try to acquire session lock
    my $lock = CLIO::Session::Lock->acquire($session_id, force => 1);
    
    unless ($lock) {
        # Session is locked by another process
        my $lock_info = CLIO::Session::Lock->get_lock_info($session_id);
        
        if ($lock_info) {
            croak "Session '$session_id' is locked by another process\n" .
                "  Process: $lock_info->{pid} on $lock_info->{hostname}\n" .
                "  Since: " . scalar(localtime($lock_info->{timestamp})) . "\n" .
                "  Use --force to override (not recommended)\n";
        } else {
            croak "Session '$session_id' is locked by another process";
        }
    }
    
    my $state = CLIO::Session::State->load($session_id, debug => $args{debug});
    
    unless ($state) {
        # Failed to load state, release lock
        $lock->release();
        return;
    }
    
    my $self = {
        session_id => $session_id,
        state      => $state,
        debug      => $args{debug} // 0,
        lock       => $lock,  # Store lock object
        stm        => undef,
        ltm        => undef,
        yarn       => undef,
    };
    bless $self, $class;
    
    # Load STM, LTM, YaRN from persistent storage
    my $stm  = $state->stm;
    my $ltm  = $state->ltm;
    my $yarn = $state->yarn;
    $self->{stm}  = $stm;
    $self->{ltm}  = $ltm;
    $self->{yarn} = $yarn;
    $state->{stm}  = $stm;
    $state->{ltm}  = $ltm;
    $state->{yarn} = $yarn;
    log_debug('SessionManager', "yarn object ref (load): $self->{yarn}");
    
    # Cleanup old tool results (older than 24 hours) to prevent disk bloat
    # This runs once when session is resumed - non-critical if it fails
    eval {
        require CLIO::Session::ToolResultStore;
        my $tool_store = CLIO::Session::ToolResultStore->new(debug => $self->{debug});
        my $cleanup_result = $tool_store->cleanupOldResults($session_id, 24);
        
        if ($cleanup_result->{deleted_count} > 0) {
            my $mb_reclaimed = sprintf("%.2f", $cleanup_result->{reclaimed_bytes} / 1_048_576);
            log_info('Manager', "Cleaned up $cleanup_result->{deleted_count} old tool results (${mb_reclaimed}MB reclaimed)");
        }
    };
    if ($@) {
        # Don't fail session load if cleanup fails - just log warning
        log_warning('Manager', "Tool result cleanup failed: $@");
    }
    
    return $self;
}

# Accessors for memory modules
sub stm  { $_[0]->{stm} }
sub ltm  { $_[0]->{ltm} }
sub yarn { $_[0]->{yarn} }
sub state { $_[0]->{state} }
sub working_directory { $_[0]->{state}->{working_directory} }

# Alias for consistency with Chat.pm
sub get_long_term_memory { $_[0]->{ltm} }

sub save {
    my ($self) = @_;
    $self->{state}->save();
}

sub cleanup {
    my ($self) = @_;
    
    # Release session lock if held
    if ($self->{lock}) {
        $self->{lock}->release();
        delete $self->{lock};
    }
    
    $self->{state}->cleanup();
}

sub get_history {
    my ($self) = @_;
    return $self->{stm}->get_context();
}

sub get_conversation_history {
    my ($self) = @_;
    log_debug('SessionManager', "Session::Manager] get_conversation_history called, count: " . scalar(@{$self->{state}->{history}}));
    return $self->{state}->{history} || [];
}

sub add_message {
    my ($self, $role, $content, $opts) = @_;
    log_debug('SessionManager', "add_message called: role=$role, content_len=" . length($content) .
        ", opts=" . (defined $opts ? "HASH" : "undef"));
    $self->{state}->add_message($role, $content, $opts);
    $self->{stm}->add_message($role, $content); # Keep STM in sync with session history
    log_debug('SessionManager', "Session::Manager] History count after add: " . scalar(@{$self->{state}->{history}}));
}

# Forward billing methods to State
sub record_api_usage {
    my ($self, $usage, $model, $provider) = @_;
    $self->{state}->record_api_usage($usage, $model, $provider);
}

sub get_billing_summary {
    my ($self) = @_;
    return $self->{state}->get_billing_summary();
}

1;
