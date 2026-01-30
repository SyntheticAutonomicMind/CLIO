package CLIO::UI::Commands::File;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use File::Spec;
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::Commands::File - File commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::File;
  
  my $file_cmd = CLIO::UI::Commands::File->new(
      chat => $chat_instance,
      session => $session,
      config => $config,
      debug => 0
  );
  
  # Handle /file commands
  $file_cmd->handle_file_command('read', 'README.md');
  $file_cmd->handle_file_command('edit', 'lib/CLIO/UI/Chat.pm');
  $file_cmd->handle_file_command('list', 'lib/CLIO/');

=head1 DESCRIPTION

Handles all file-related commands including:
- /file read <path> - Read and display file
- /file edit <path> - Open file in external editor
- /file list [path] - List directory contents

Extracted from Chat.pm to improve maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        session => $args{session},
        config => $args{config},
        debug => $args{debug} // 0,
    };
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub colorize { shift->{chat}->colorize(@_) }
sub display_paginated_content { shift->{chat}->display_paginated_content(@_) }

=head2 handle_file_command($action, @args)

Main dispatcher for /file commands.

=cut

sub handle_file_command {
    my ($self, $action, @args) = @_;
    
    $action ||= '';
    $action = lc($action);
    
    # /file (no args) - show help
    if ($action eq '' || $action eq 'help') {
        $self->_display_file_help();
        return;
    }
    
    # /file read <path> - read and display file
    if ($action eq 'read' || $action eq 'view' || $action eq 'cat') {
        $self->handle_read_command(@args);
        return;
    }
    
    # /file edit <path> - edit file
    if ($action eq 'edit') {
        $self->handle_edit_command(join(' ', @args));
        return;
    }
    
    # /file list [path] - list directory
    if ($action eq 'list' || $action eq 'ls') {
        my $path = join(' ', @args) || '.';
        $self->_list_directory($path);
        return;
    }
    
    # Unknown action
    $self->display_error_message("Unknown action: /file $action");
    $self->_display_file_help();
}

=head2 _display_file_help

Display help for /file commands

=cut

sub _display_file_help {
    my ($self) = @_;
    
    print "\n";
    print $self->colorize("FILE COMMANDS", 'DATA'), "\n";
    print $self->colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", 'DIM'), "\n\n";
    
    print $self->colorize("  /file read <path>", 'PROMPT'), "       Read and display file (markdown rendered)\n";
    print $self->colorize("  /file edit <path>", 'PROMPT'), "       Open file in external editor (\$EDITOR)\n";
    print $self->colorize("  /file list [path]", 'PROMPT'), "       List directory contents (default: .)\n";
    
    print "\n";
    print $self->colorize("EXAMPLES", 'DATA'), "\n";
    print $self->colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", 'DIM'), "\n";
    print "  /file read README.md                 # View a file\n";
    print "  /file edit lib/CLIO/UI/Chat.pm       # Edit a file\n";
    print "  /file list lib/CLIO/                 # List directory\n";
}

=head2 _list_directory

List directory contents

=cut

sub _list_directory {
    my ($self, $path) = @_;
    
    # Resolve path
    unless (File::Spec->file_name_is_absolute($path)) {
        my $working_dir = $self->{session} ? 
            ($self->{session}->state()->{working_directory} || '.') : '.';
        $path = File::Spec->catfile($working_dir, $path);
    }
    
    unless (-d $path) {
        $self->display_error_message("Not a directory: $path");
        return;
    }
    
    opendir(my $dh, $path) or do {
        $self->display_error_message("Cannot read directory: $!");
        return;
    };
    
    my @entries = sort grep { !/^\.\.?$/ } readdir($dh);
    closedir($dh);
    
    print "\n";
    print $self->colorize("Directory: $path", 'DATA'), "\n";
    print $self->colorize("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━", 'DIM'), "\n\n";
    
    my @dirs;
    my @files;
    
    for my $entry (@entries) {
        my $full_path = File::Spec->catfile($path, $entry);
        if (-d $full_path) {
            push @dirs, $entry;
        } else {
            push @files, $entry;
        }
    }
    
    # Show directories first
    for my $dir (@dirs) {
        print "  ", $self->colorize("$dir/", 'USER'), "\n";
    }
    
    # Then files
    for my $file (@files) {
        print "  $file\n";
    }
    
    print "\n";
    $self->display_system_message(scalar(@dirs) . " directories, " . scalar(@files) . " files");
}

=head2 handle_read_command

Read and display a file with markdown rendering

=cut

sub handle_read_command {
    my ($self, @args) = @_;
    
    my $filepath = join(' ', @args);
    
    unless ($filepath) {
        $self->display_error_message("Usage: /read <filename>");
        $self->display_system_message("Reads and displays a file with markdown rendering and pagination.");
        return;
    }
    
    # Resolve path relative to working directory
    unless (File::Spec->file_name_is_absolute($filepath)) {
        my $working_dir = $self->{session} ? 
            ($self->{session}->{working_directory} || '.') : '.';
        $filepath = File::Spec->catfile($working_dir, $filepath);
    }
    
    # Check if file exists
    unless (-f $filepath) {
        $self->display_error_message("File not found: $filepath");
        return;
    }
    
    # Check if file is readable
    unless (-r $filepath) {
        $self->display_error_message("Cannot read file: $filepath");
        return;
    }
    
    # Read file content
    my $content;
    eval {
        open my $fh, '<:encoding(UTF-8)', $filepath or die "Cannot open file: $!";
        local $/;  # Slurp mode
        $content = <$fh>;
        close $fh;
    };
    if ($@) {
        $self->display_error_message("Error reading file: $@");
        return;
    }
    
    # Check if it's a markdown file
    my $is_markdown = ($filepath =~ /\.md$/i);
    
    # Process content
    my @lines;
    my $chat = $self->{chat};
    
    if ($is_markdown && $chat->{markdown_renderer}) {
        # Render markdown
        my $rendered = $chat->{markdown_renderer}->render($content);
        # Process @-codes
        $rendered = $chat->{ansi}->parse($rendered) if $chat->{ansi};
        @lines = split /\n/, $rendered, -1;
    } else {
        # Plain text - just process @-codes if present
        if ($chat->{ansi} && $content =~ /\@\w+\@/) {
            $content = $chat->{ansi}->parse($content);
        }
        @lines = split /\n/, $content, -1;
    }
    
    # Get filename for title
    my $filename = (File::Spec->splitpath($filepath))[2];
    my $title = $is_markdown ? " $filename (Markdown)" : " $filename";
    
    # Display with pagination
    $self->display_paginated_content($title, \@lines, $filepath);
}

=head2 handle_edit_command

Open file in external editor

=cut

sub handle_edit_command {
    my ($self, $filepath) = @_;
    
    unless ($filepath) {
        $self->display_error_message("Usage: /edit <filepath>");
        return;
    }
    
    # Expand tilde to home directory
    $filepath =~ s/^~/$ENV{HOME}/;
    
    # Make relative paths absolute if needed
    unless ($filepath =~ m{^/}) {
        require Cwd;
        my $cwd = Cwd::getcwd();
        $filepath = "$cwd/$filepath";
    }
    
    require CLIO::Core::Editor;
    my $editor = CLIO::Core::Editor->new(
        config => $self->{config},
        debug => $self->{debug}
    );
    
    # Check if editor is available
    unless ($editor->check_editor_available()) {
        $self->display_error_message("Editor not found: " . $editor->{editor});
        $self->display_system_message("Set editor with: /config editor <editor>");
        $self->display_system_message("Or set \$EDITOR or \$VISUAL environment variable");
        return;
    }
    
    my $result = $editor->edit_file($filepath);
    
    if ($result->{success}) {
        $self->display_system_message("File edited: $filepath");
    } else {
        $self->display_error_message($result->{error});
    }
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
