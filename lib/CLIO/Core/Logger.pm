package CLIO::Core::Logger;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(should_log LOG_LEVEL);

=head1 NAME

CLIO::Core::Logger - Global logging utility

=head1 DESCRIPTION

Provides global should_log() function that checks CLIO_LOG_LEVEL environment
variable (which is set automatically by the --debug flag) or falls back to WARNING default.

This allows modules without config access to still respect log level settings.

=cut

# Log level constants
use constant LOG_LEVEL => {
    ERROR => 0,
    WARNING => 1,
    INFO => 2,
    DEBUG => 3,
};

=head2 should_log

Check if a message at the given level should be logged

Arguments:
- $level: Log level (ERROR, WARNING, INFO, DEBUG)
- $config (optional): Config object to check, otherwise uses ENV

Returns: 1 if message should be shown, 0 otherwise

=cut

sub should_log {
    my ($level, $config) = @_;
    
    # Normalize level to uppercase
    $level = uc($level);
    
    # Get configured log level
    # Priority: CLIO_LOG_LEVEL env var (set by --debug) > config > default
    my $config_level;
    
    if ($ENV{CLIO_LOG_LEVEL}) {
        # Environment variable takes priority (set by --debug flag)
        # This ensures --debug works even when config object is passed
        $config_level = uc($ENV{CLIO_LOG_LEVEL});
    } elsif ($config && $config->can('get')) {
        # Fall back to config object if no env var
        $config_level = uc($config->get('log_level') || 'WARNING');
    } else {
        # Default to WARNING (less verbose than INFO)
        $config_level = 'WARNING';
    }
    
    # Validate levels
    return 0 unless exists LOG_LEVEL->{$level};
    return 0 unless exists LOG_LEVEL->{$config_level};
    
    # Show if message level <= configured level
    # (lower numbers = higher priority)
    return LOG_LEVEL->{$level} <= LOG_LEVEL->{$config_level};
}

1;

__END__

=head1 USAGE

    use CLIO::Core::Logger qw(should_log);
    
    # Simple usage (uses ENV or default)
    print STDERR "[DEBUG][Module] Message\n" if should_log('DEBUG');
    print STDERR "[ERROR][Module] Error\n" if should_log('ERROR');
    
    # With config object
    print STDERR "[INFO][Module] Info\n" if should_log('INFO', $self->{config});

=head1 ENVIRONMENT

CLIO_LOG_LEVEL - Set to DEBUG, INFO, WARNING, or ERROR
                 (automatically set to 'DEBUG' when --debug flag is used)

=head1 AUTHOR

Fewtarius

=cut
