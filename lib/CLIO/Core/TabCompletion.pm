package CLIO::Core::TabCompletion;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(should_log log_debug);
use feature 'say';
use File::Spec;
use Cwd;

=head1 NAME

CLIO::Core::TabCompletion - Tab completion for CLIO

=head1 DESCRIPTION

Provides tab completion for:
- Slash commands (/help, /edit, /config, etc.)
- Filesystem paths (files and directories)
- Command arguments

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        commands => [
            '/help', '/h', '/?',
            '/exit', '/quit', '/q',
            '/clear', '/cls',
            '/session',
            '/debug',
            '/color',
            '/edit',
            '/read', '/view', '/cat',
            '/multi-line', '/multiline', '/ml',
            '/config',
            '/explain', '/review', '/test', '/fix', '/doc',
            '/todo',
            '/skills',
            '/prompt',
            '/status', '/st', '/diff', '/log', '/commit', '/gitlog', '/gl',
            '/billing', '/usage',
            '/models',
            '/context', '/ctx',
            '/exec', '/shell', '/sh',
            '/switch',
            '/api',
            '/loglevel',
            '/style', '/theme',
            '/login', '/logout',
            '/performance', '/perf'
        ],
        config_subcommands => [
            'show', 'key', 'url', 'model', 'editor', 'provider', 'save', 'load', 'workdir'
        ],
        # Commands that take file paths as arguments
        file_path_commands => [
            '/edit', '/read', '/view', '/cat', '/explain', '/review', '/test', '/fix', '/doc', '/context', '/diff'
        ],
        debug => $args{debug} || 0,
    };
    
    return bless $self, $class;
}

=head2 complete

Main completion method called by Term::ReadLine.

Arguments:
- $text: The word being completed
- $line: The entire input line
- $start: Starting position of $text in $line

Returns: List of completion candidates

=cut

sub complete {
    my ($self, $text, $line, $start) = @_;
    
    log_debug('TabCompletion', "text='$text' line='$line' start=$start");
    
    # Slash command completion
    if ($start == 0 && $text =~ m{^/}) {
        return $self->complete_command($text);
    }
    
    # Config subcommand completion
    if ($line =~ m{^/config\s+(\S*)$}) {
        return $self->complete_config_subcommand($1);
    }
    
    # File path completion for commands that take file arguments
    for my $cmd (@{$self->{file_path_commands}}) {
        if ($line =~ m{^\Q$cmd\E\s+(.*)$}) {
            return $self->complete_path($1);
        }
    }
    
    # Default: try path completion if text looks like a path
    if ($text =~ m{[/~\.]} || $start > 0) {
        return $self->complete_path($text);
    }
    
    return ();
}

=head2 complete_command

Complete slash commands

=cut

sub complete_command {
    my ($self, $text) = @_;
    
    my @matches = grep { /^\Q$text\E/i } @{$self->{commands}};
    
    log_debug('TabCompletion', "Command matches: @matches");
    
    return @matches;
}

=head2 complete_config_subcommand

Complete /config subcommands

=cut

sub complete_config_subcommand {
    my ($self, $text) = @_;
    
    my @matches = grep { /^\Q$text\E/i } @{$self->{config_subcommands}};
    
    log_debug('TabCompletion', "Config subcommand matches: @matches");
    
    return @matches;
}

=head2 complete_path

Complete filesystem paths (files and directories)

=cut

sub complete_path {
    my ($self, $partial) = @_;
    
    # Handle empty or whitespace-only input
    $partial //= '';
    $partial =~ s/^\s+//;
    
    # Default to current directory if empty
    $partial = './' unless length $partial;
    
    # Expand tilde
    if ($partial =~ s/^~//) {
        $partial = $ENV{HOME} . $partial;
    }
    
    # Determine directory and file prefix
    my ($dir, $file);
    
    if ($partial =~ m{/$}) {
        # Ends with /, complete everything in that directory
        $dir = $partial;
        $file = '';
    } elsif ($partial =~ m{^(.*/)([^/]*)$}) {
        # Contains /, split into dir and file
        ($dir, $file) = ($1, $2);
    } else {
        # No /, relative to current directory
        $dir = './';
        $file = $partial;
    }
    
    # Make directory absolute or clean it up
    $dir =~ s{/\./}{/}g;  # Remove /./
    $dir =~ s{//+}{/}g;   # Remove //
    
    # If relative path, resolve it
    unless ($dir =~ m{^/}) {
        $dir = Cwd::getcwd() . '/' . $dir;
    }
    
    log_debug('TabCompletion', "Completing in dir='$dir' file='$file'");
    
    # Read directory
    if (!opendir(my $dh, $dir)) {
        log_debug('TabCompletion', "Cannot open directory: $dir");
        return ();
    } else {
        my @entries = readdir($dh);
        closedir $dh;
        
        # Filter matches
        my @matches;
        for my $entry (@entries) {
            # Skip . and ..
            next if $entry eq '.' || $entry eq '..';
        
        # Skip hidden files unless explicitly requested
        next if $entry =~ /^\./ && $file !~ /^\./;
        
        # Check if entry matches prefix
        next unless $entry =~ /^\Q$file\E/;
        
        my $full_path = File::Spec->catfile($dir, $entry);
        
        # Add trailing / for directories
        if (-d $full_path) {
            push @matches, "$entry/";
        } else {
            push @matches, $entry;
        }
    }
    
    log_debug('TabCompletion', "Path matches: @matches");
    
    # Return matches with proper prefix
    # If original partial had a directory prefix, preserve it
    if ($partial =~ m{/}) {
        my $prefix = $partial;
        $prefix =~ s{[^/]*$}{};  # Remove filename part
        @matches = map { $prefix . $_ } @matches;
    }
    
    return @matches;
    }
}

=head2 setup_readline

Setup completion for a Term::ReadLine instance

Arguments:
- $term: Term::ReadLine object

=cut

sub setup_readline {
    my ($self, $term) = @_;
    
    # Check if we have Term::ReadLine::Gnu
    my $has_gnu = eval { require Term::ReadLine::Gnu; 1 };
    
    if ($has_gnu) {
        log_debug('TabCompletion', "Using Term::ReadLine::Gnu");
        
        # Set up completion function
        $term->Attribs->{completion_function} = sub {
            my ($text, $line, $start) = @_;
            return $self->complete($text, $line, $start);
        };
        
        # Enable filename quoting for paths with spaces
        $term->Attribs->{filename_quote_characters} = '"\'';
        $term->Attribs->{completer_quote_characters} = '"\'';
    } else {
        log_debug('TabCompletion', "Term::ReadLine::Gnu not available, using basic readline");
        
        # Basic Term::ReadLine doesn't support completion the same way
        # But we can still try to set it up
        eval {
            $term->Attribs->{completion_function} = sub {
                my ($text, $line, $start) = @_;
                return $self->complete($text, $line, $start);
            };
        };
    }
}

1;

__END__

=head1 USAGE

    use CLIO::Core::TabCompletion;
    use Term::ReadLine;
    
    my $completer = CLIO::Core::TabCompletion->new(debug => 0);
    my $term = Term::ReadLine->new('CLIO');
    
    $completer->setup_readline($term);
    
    # Now tab completion will work in readline

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.
1;
