package CLIO::Core::TabCompletion;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(log_debug);
use feature 'say';
use File::Spec;
use Cwd;

=head1 NAME

CLIO::Core::TabCompletion - Tab completion for CLIO

=head1 DESCRIPTION

Provides comprehensive tab completion for:
- Slash commands (/help, /edit, /config, etc.)
- Subcommands (/git status, /api set model, etc.)
- Filesystem paths (files and directories)
- Command arguments (log levels, etc.)

Completion is data-driven: a subcommand map defines the tree of valid
completions. The complete() method walks the tree based on cursor position.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        # Master list of all slash commands (including aliases)
        commands => [
            # Help & navigation
            '/help', '/h', '/?',
            '/exit', '/quit', '/q',
            '/clear', '/cls',
            '/reset',

            # Session management
            '/session',

            # Configuration
            '/config',
            '/loglevel',
            '/style', '/theme',
            '/debug', '/color',

            # File operations
            '/file',
            '/edit',
            '/read', '/view', '/cat',

            # Git operations
            '/git',
            '/status', '/st', '/diff', '/commit', '/gitlog', '/gl',
            '/switch',

            # AI operations
            '/explain', '/review', '/test', '/fix', '/doc',

            # System
            '/exec', '/shell', '/sh',
            '/multi-line', '/multiline', '/multi', '/ml',
            '/performance', '/perf',

            # Tools & features
            '/todo',
            '/context', '/ctx',
            '/skills', '/skill',
            '/prompt',
            '/memory', '/mem', '/ltm',
            '/log',

            # API & auth
            '/api',
            '/login', '/logout',
            '/billing', '/bill', '/usage',
            '/models',

            # Project
            '/init', '/design',

            # Agents
            '/agent', '/subagent',

            # Device management
            '/device', '/dev',
            '/group',

            # Utilities
            '/undo',
            '/update',
            '/stats',
            '/mcp',
        ],

        # Subcommand tree: command -> [subcommands]
        # Nested: command -> { subcmd -> [sub-subcommands] }
        subcommands => {
            '/api' => {
                _subs => [qw(show set models providers login logout quota key base model provider help)],
                'set' => [qw(key serpapi_key search_engine search_provider github_pat base model provider thinking)],
            },
            '/session' => [qw(show list switch name new clear trim prune export help)],
            '/git' => {
                _subs => [qw(status diff log commit branch switch push pull blame stash tag help)],
                'stash' => [qw(list save apply drop)],
                'tag' => [qw(-d)],
            },
            '/file' => [qw(read edit list ls help)],
            '/config' => [qw(show set save load workdir loglevel help)],
            '/memory' => [qw(list ls store clear prune stats help)],
            '/mem' => [qw(list ls store clear prune stats help)],
            '/ltm' => [qw(list ls store clear prune stats help)],
            '/context' => [qw(add list ls clear remove rm help)],
            '/ctx' => [qw(add list ls clear remove rm help)],
            '/skills' => [qw(add list ls use exec show delete rm search install help)],
            '/skill' => [qw(add list ls use exec show delete rm search install help)],
            '/prompt' => [qw(show list ls set reset edit save delete rm help)],
            '/todo' => [qw(view list add done clear help)],
            '/style' => [qw(list show set save)],
            '/theme' => [qw(list show set save)],
            '/loglevel' => [qw(DEBUG INFO WARNING ERROR CRITICAL)],
            '/log' => [qw(filter search session)],
            '/stats' => [qw(current history hist log raw help)],
            '/agent' => [qw(spawn list ls status kill killall locks discoveries disc warnings warn inbox messages ack acknowledge history hist send reply broadcast help)],
            '/subagent' => [qw(spawn list ls status kill killall locks discoveries disc warnings warn inbox messages ack acknowledge history hist send reply broadcast help)],
            '/device' => [qw(add list remove show help)],
            '/dev' => [qw(add list remove show help)],
            '/group' => [qw(add create list remove help)],
            '/undo' => [qw(list diff)],
            '/update' => [qw(check install status list switch help)],
            '/mcp' => [qw(status list add remove auth help)],
            '/billing' => [qw(help)],
            '/bill' => [qw(help)],
        },

        # Commands that take file paths as the FIRST argument
        file_path_commands => [
            '/edit', '/read', '/view', '/cat',
            '/explain', '/review', '/test', '/fix', '/doc',
        ],

        # Commands where a specific subcommand takes a file path
        # Format: "command subcommand" -> takes file path after
        file_path_subcommands => {
            '/file read'     => 1,
            '/file edit'     => 1,
            '/file list'     => 1,
            '/file ls'       => 1,
            '/git blame'     => 1,
            '/git diff'      => 1,
            '/context add'   => 1,
            '/ctx add'       => 1,
            '/log filter'    => 1,
        },

        debug => $args{debug} || 0,
    };

    return bless $self, $class;
}

=head2 complete

Main completion method.

Arguments:
- $text: The text being completed (may be partial word or full line)
- $line: The entire input line
- $start: Starting position of $text in $line

The ReadLine integration passes the full line as both $text and $line
with $start=0. This method handles that by parsing the full line to
determine completion context.

Returns: List of completion candidates (full lines)

=cut

sub complete {
    my ($self, $text, $line, $start) = @_;

    log_debug('TabCompletion', "text='$text' line='$line' start=$start");

    # Parse the full line into parts
    my @parts = split(/\s+/, $line);
    my $cmd = $parts[0] || '';

    # Determine if we're at a word boundary (line ends with space)
    my $at_boundary = ($line =~ /\s$/);

    # Count how many complete words we have
    my $num_parts = scalar(@parts);
    # If at boundary, we're starting a NEW word
    my $completing_word_index = $at_boundary ? $num_parts : $num_parts - 1;

    # Case 1: Completing the command itself (first word, starts with /)
    if ($completing_word_index == 0 && $cmd =~ m{^/}) {
        return $self->complete_command($cmd);
    }

    # Case 2: Completing first argument (subcommand or file path)
    if ($completing_word_index == 1) {
        my $partial_sub = $at_boundary ? '' : ($parts[1] // '');

        # Check if this command has subcommands
        if (exists $self->{subcommands}{$cmd}) {
            my $subcmds = $self->{subcommands}{$cmd};

            my @candidates;
            if (ref $subcmds eq 'HASH') {
                @candidates = @{$subcmds->{_subs} || []};
            } elsif (ref $subcmds eq 'ARRAY') {
                @candidates = @$subcmds;
            }

            if (@candidates) {
                my @matches = grep { /^\Q$partial_sub\E/i } @candidates;
                log_debug('TabCompletion', "Subcommand matches for $cmd: @matches");
                return map { "$cmd $_" } @matches if @matches;
            }
        }

        # Check if this is a file-path command
        for my $fc (@{$self->{file_path_commands}}) {
            if ($cmd eq $fc) {
                return $self->complete_path_with_prefix($partial_sub, $cmd);
            }
        }

        # Default: try path completion for any unknown command with an argument
        if ($cmd =~ m{^/}) {
            return $self->complete_path_with_prefix($partial_sub, $cmd);
        }
    }

    # Case 3: Completing second argument (sub-subcommand or file path)
    if ($completing_word_index == 2) {
        my $subcmd = $parts[1] || '';
        my $partial = $at_boundary ? '' : ($parts[2] // '');

        # Check for nested subcommands (e.g., /git stash save, /api set model)
        if (exists $self->{subcommands}{$cmd} && ref $self->{subcommands}{$cmd} eq 'HASH') {
            my $nested = $self->{subcommands}{$cmd};
            if (exists $nested->{$subcmd} && ref $nested->{$subcmd} eq 'ARRAY') {
                my @matches = grep { /^\Q$partial\E/i } @{$nested->{$subcmd}};
                log_debug('TabCompletion', "Sub-subcommand matches for $cmd $subcmd: @matches");
                return map { "$cmd $subcmd $_" } @matches if @matches;
            }
        }

        # Check for file path completion after "command subcommand"
        my $cmd_sub = "$cmd $subcmd";
        if (exists $self->{file_path_subcommands}{$cmd_sub}) {
            return $self->complete_path_with_prefix($partial, "$cmd $subcmd");
        }

        # Default: try path completion
        return $self->complete_path_with_prefix($partial, "$cmd $subcmd");
    }

    # Case 4: Beyond second argument - try file path completion
    if ($completing_word_index >= 3) {
        my $partial = $at_boundary ? '' : ($parts[-1] // '');
        my $prefix = $line;
        $prefix =~ s/\S*$//;  # Remove the partial word
        $prefix =~ s/\s+$/ /; # Normalize trailing space
        return $self->complete_path_with_prefix($partial, $prefix);
    }

    return ();
}

=head2 complete_command

Complete slash commands at the beginning of input.

=cut

sub complete_command {
    my ($self, $text) = @_;

    my @matches = grep { /^\Q$text\E/i } @{$self->{commands}};

    log_debug('TabCompletion', "Command matches: @matches");

    return @matches;
}

=head2 complete_path_with_prefix

Complete a file path and prepend the command prefix.

Arguments:
- $partial: The partial path to complete
- $prefix: The command prefix (e.g., "/git blame")

Returns: List of completions with prefix

=cut

sub complete_path_with_prefix {
    my ($self, $partial, $prefix) = @_;

    my @paths = $self->complete_path($partial);
    return map { "$prefix $_" } @paths;
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

    # Clean up directory path
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
        if ($partial =~ m{/}) {
            my $prefix = $partial;
            $prefix =~ s{[^/]*$}{};  # Remove filename part
            @matches = map { $prefix . $_ } @matches;
        }

        return @matches;
    }
}

=head2 setup_readline

Setup completion for a Term::ReadLine instance (legacy support).

Arguments:
- $term: Term::ReadLine object

=cut

sub setup_readline {
    my ($self, $term) = @_;

    my $has_gnu = eval { require Term::ReadLine::Gnu; 1 };

    if ($has_gnu) {
        log_debug('TabCompletion', "Using Term::ReadLine::Gnu");

        $term->Attribs->{completion_function} = sub {
            my ($text, $line, $start) = @_;
            return $self->complete($text, $line, $start);
        };

        $term->Attribs->{filename_quote_characters} = '"\'';
        $term->Attribs->{completer_quote_characters} = '"\'';
    } else {
        log_debug('TabCompletion', "Term::ReadLine::Gnu not available, using basic readline");

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

    my $completer = CLIO::Core::TabCompletion->new(debug => 0);

    # Get completions for partial input
    my @candidates = $completer->complete('/gi', '/gi', 0);
    # Returns: ('/git', '/gitlog', '/gl')

    # Get subcommand completions
    my @subs = $completer->complete('st', '/git st', 5);
    # Returns: ('/git status', '/git stash')

    # Get nested subcommand completions
    my @nested = $completer->complete('sa', '/git stash sa', 11);
    # Returns: ('/git stash save')

=head1 AUTHOR

Fewtarius

=head1 LICENSE

See main CLIO LICENSE file.

=cut
