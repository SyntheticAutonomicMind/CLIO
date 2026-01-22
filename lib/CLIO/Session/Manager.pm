if ($ENV{CLIO_DEBUG}) {
    print STDERR "[TRACE] CLIO::Session::Manager loaded\n";
}
package CLIO::Session::Manager;

use strict;
use warnings;
use CLIO::Core::Logger qw(should_log);
use CLIO::Session::State;
use CLIO::Memory::ShortTerm;
use CLIO::Memory::LongTerm;
use CLIO::Memory::YaRN;
use File::Spec;
use File::Basename;
use Cwd;
use Digest::SHA qw(sha256_hex);
use Time::HiRes qw(gettimeofday);

sub new {
    my ($class, %args) = @_;
    if ($ENV{CLIO_DEBUG} || $args{debug}) {
        print STDERR "[TRACE] Entered Manager::new\n";
        my $dbg = "[DEBUG][Manager::new] called with args: " . join(", ", map { "$_=$args{$_}" } keys %args) . "\n";
        print STDERR $dbg; print $dbg;
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
        print STDERR "[MANAGER] yarn object ref: $self->{yarn}\n"; print "[MANAGER] yarn object ref: $self->{yarn}\n";
        print STDERR "[DEBUG][Manager::new] returning self: $self\n"; print "[DEBUG][Manager::new] returning self: $self\n";
        print STDERR "[TRACE][Manager::new] About to return: ", (defined $self ? $self : '[undef]'), "\n"; print "[TRACE][Manager::new] About to return: ", (defined $self ? $self : '[undef]'), "\n";
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
        print STDERR "[TRACE] Entered Manager::create\n";
        my $dbg2 = "[DEBUG][Manager::create] called with args: " . join(", ", map { "$_=$args{$_}" } keys %args) . "\n";
        print STDERR $dbg2; print $dbg2;
    }
    my $obj = $class->new(%args);
    if ($ENV{CLIO_DEBUG} || $obj->{debug}) {
        print STDERR "[DEBUG][Manager::create] returning: $obj\n"; print "[DEBUG][Manager::create] returning: $obj\n";
        print STDERR "[TRACE][Manager::create] About to return: ", (defined $obj ? $obj : '[undef]'), "\n"; print "[TRACE][Manager::create] About to return: ", (defined $obj ? $obj : '[undef]'), "\n";
    }
    return $obj;
}

sub load {
    my ($class, $session_id, %args) = @_;
    my $state = CLIO::Session::State->load($session_id, debug => $args{debug});
    return unless $state;
    my $self = {
        session_id => $session_id,
        state      => $state,
        debug      => $args{debug} // 0,
        stm        => undef,
        ltm        => undef,
        yarn       => undef,
    };
    bless $self, $class;
    # TODO: Load STM, LTM, YaRN from persistent storage if available
    my $stm  = $state->stm;
    my $ltm  = $state->ltm;
    my $yarn = $state->yarn;
    $self->{stm}  = $stm;
    $self->{ltm}  = $ltm;
    $self->{yarn} = $yarn;
    $state->{stm}  = $stm;
    $state->{ltm}  = $ltm;
    $state->{yarn} = $yarn;
    print STDERR "[MANAGER] yarn object ref (load): $self->{yarn}\n" if $self->{debug} || $ENV{CLIO_DEBUG};
    return $self;
}

# Accessors for memory modules
sub stm  { $_[0]->{stm} }
sub ltm  { $_[0]->{ltm} }
sub yarn { $_[0]->{yarn} }
sub state { $_[0]->{state} }

# Alias for consistency with Chat.pm
sub get_long_term_memory { $_[0]->{ltm} }

sub save {
    my ($self) = @_;
    $self->{state}->save();
}

sub cleanup {
    my ($self) = @_;
    $self->{state}->cleanup();
}

sub get_history {
    my ($self) = @_;
    return $self->{stm}->get_context();
}

sub get_conversation_history {
    my ($self) = @_;
    print STDERR "[DEBUG][Session::Manager] get_conversation_history called, count: " . scalar(@{$self->{state}->{history}}) . "\n" if $self->{debug};
    return $self->{state}->{history} || [];
}

sub add_message {
    my ($self, $role, $content) = @_;
    print STDERR "[DEBUG][Session::Manager] add_message called: role=$role, content_len=" . length($content) . "\n" if $self->{debug};
    $self->{state}->add_message($role, $content);
    $self->{stm}->add_message($role, $content); # Keep STM in sync with session history
    print STDERR "[DEBUG][Session::Manager] History count after add: " . scalar(@{$self->{state}->{history}}) . "\n" if $self->{debug};
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
