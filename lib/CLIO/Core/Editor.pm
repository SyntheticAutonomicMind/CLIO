package CLIO::Core::Editor;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(log_debug);
use feature 'say';
use File::Temp qw(tempfile);
use File::Spec;

=head1 NAME

CLIO::Core::Editor - External editor integration for CLIO

=head1 DESCRIPTION

Provides functionality to open external editors for file editing and multi-line input.
Supports $EDITOR, $VISUAL environment variables, and fallback to nano.

=cut

sub new {
    my ($class, %args) = @_;
    
    # Determine editor priority: explicit arg > config > $EDITOR > $VISUAL > vim
    my $editor = $args{editor};
    
    if (!$editor && $args{config}) {
        $editor = $args{config}->get('editor');
    }
    
    $editor ||= $ENV{EDITOR} || $ENV{VISUAL} || 'vim';
    
    my $self = {
        editor => $editor,
        config => $args{config},  # Store config reference
        debug => $args{debug} || 0,
    };
    
    log_debug('Editor', "Using editor: $self->{editor}");
    
    return bless $self, $class;
}

=head2 edit_file

Edit an existing file in the configured editor.

Arguments:
- $filepath: Path to file to edit

Returns: Hash with success => 1 on success, or success => 0 with error message

=cut

sub edit_file {
    my ($self, $filepath) = @_;
    
    unless ($filepath) {
        return { success => 0, error => "No filepath provided" };
    }
    
    # Check if file exists
    unless (-f $filepath) {
        return { success => 0, error => "File not found: $filepath" };
    }
    
    # Check if file is readable/writable
    unless (-r $filepath && -w $filepath) {
        return { success => 0, error => "File not readable/writable: $filepath" };
    }
    
    log_debug('Editor', "Opening file: $filepath");
    
    # Open editor - use system() to wait for completion
    my $cmd = "$self->{editor} " . quotemeta($filepath);
    my $result = system($cmd);
    
    if ($result != 0) {
        my $exit_code = $result >> 8;
        return { success => 0, error => "Editor exited with code: $exit_code" };
    }
    
    log_debug('Editor', "File editing complete");
    
    return { success => 1, filepath => $filepath };
}

=head2 edit_multiline

Open editor with a temporary file for multi-line input.

Arguments:
- $initial_content: Optional initial content for the temp file

Returns: Hash with success => 1 and content => $text on success,
         or success => 0 with error message

=cut

sub edit_multiline {
    my ($self, $initial_content) = @_;
    
    # Create temp file
    my ($fh, $filename);
    eval {
        ($fh, $filename) = tempfile(
            'clio_XXXXXX',
            DIR => File::Spec->tmpdir(),
            SUFFIX => '.txt',
            UNLINK => 0  # Don't auto-delete - we'll clean up manually
        );
    };
    if ($@) {
        return { success => 0, error => "Cannot create temp file: $@" };
    }
    
    # Write initial content if provided
    if ($initial_content) {
        print $fh $initial_content;
    } else {
        # Add helpful comment
        print $fh "# Enter your multi-line prompt below.\n";
        print $fh "# Lines starting with # will be preserved.\n";
        print $fh "# Save and close editor to send to CLIO.\n\n";
    }
    close $fh;
    
    log_debug('Editor', "Created temp file: $filename");
    
    # Open editor
    my $cmd = "$self->{editor} " . quotemeta($filename);
    my $result = system($cmd);
    
    if ($result != 0) {
        unlink $filename;
        my $exit_code = $result >> 8;
        return { success => 0, error => "Editor exited with code: $exit_code" };
    }
    
    # Read content
    my $content;
    if (open my $rfh, '<', $filename) {
        $content = do { local $/; <$rfh> };
        close $rfh;
    } else {
        unlink $filename;
        return { success => 0, error => "Cannot read temp file: $!" };
    }
    
    # Clean up temp file
    unlink $filename;
    
    log_debug('Editor', "Multi-line editing complete");
    
    # Check if content is empty or only comments
    my $has_content = 0;
    for my $line (split /\n/, $content) {
        next if $line =~ /^\s*#/;  # Skip comments
        next if $line =~ /^\s*$/;   # Skip empty lines
        $has_content = 1;
        last;
    }
    
    unless ($has_content) {
        return { success => 0, error => "No content entered" };
    }
    
    return { success => 1, content => $content };
}

=head2 check_editor_available

Check if the configured editor is available on the system.

Returns: 1 if editor exists, 0 otherwise

=cut

sub check_editor_available {
    my ($self) = @_;
    
    # Try to find the editor in PATH
    my $editor = $self->{editor};
    
    # Handle editor with arguments (e.g., "vim -u NONE")
    my ($editor_cmd) = split /\s+/, $editor;
    
    # Check if it's a full path
    if ($editor_cmd =~ m{^/}) {
        return -x $editor_cmd ? 1 : 0;
    }
    
    # Search in PATH
    for my $dir (split /:/, $ENV{PATH}) {
        my $full_path = File::Spec->catfile($dir, $editor_cmd);
        return 1 if -x $full_path;
    }
    
    return 0;
}

1;
