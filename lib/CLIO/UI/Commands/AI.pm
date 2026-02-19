package CLIO::UI::Commands::AI;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use Cwd;
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::Commands::AI - AI-assisted code analysis commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::AI;
  
  my $ai_cmd = CLIO::UI::Commands::AI->new(
      chat => $chat_instance,
      session => $session,
      debug => 0
  );
  
  # Handle AI commands (returns prompt to send to AI)
  my $prompt = $ai_cmd->handle_explain_command('lib/CLIO/Core/Config.pm');
  my $prompt = $ai_cmd->handle_review_command('lib/CLIO/UI/Chat.pm');
  my $prompt = $ai_cmd->handle_test_command('lib/CLIO/Core/Logger.pm');

=head1 DESCRIPTION

Handles AI-assisted code analysis commands including:
- /explain <file> - Explain code
- /review <file> - Review code for issues
- /test <file> - Generate tests
- /fix <file> - Suggest fixes for errors
- /doc <file> - Generate documentation

These commands build prompts that are returned to the caller
to be sent to the AI agent.

Extracted from Chat.pm to improve maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    # Assign object references separately
    $self->{session} = $args{session};
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub writeline { shift->{chat}->writeline(@_) }

=head2 handle_explain_command(@args)

Explain code in a file. Returns prompt to send to AI.

=cut

sub handle_explain_command {
    my ($self, @args) = @_;
    
    my $file = join(' ', @args);
    my $code_content = "";
    
    if ($file) {
        # Resolve relative path
        unless ($file =~ m{^/}) {
            my $cwd = Cwd::getcwd() || $ENV{PWD} || '.';
            $file = "$cwd/$file";
        }
        
        unless (-f $file) {
            $self->display_error_message("File not found: $file");
            return;
        }
        
        # Read file content
        open my $fh, '<', $file or do {
            $self->display_error_message("Cannot read file: $!");
            return;
        };
        $code_content = do { local $/; <$fh> };
        close $fh;
        
        # Build prompt with code
        my $prompt = "Please explain the following code from $file:\n\n```\n$code_content\n```\n\n" .
                    "Provide a clear explanation of:\n" .
                    "1. What this code does (high-level overview)\n" .
                    "2. Key components and their purpose\n" .
                    "3. How the different parts work together\n" .
                    "4. Any notable patterns or techniques used";
        
        # Display info message
        $self->display_system_message("Explaining code from: $file");
        $self->writeline("", markdown => 0);
        
        return $prompt;
    } else {
        # No file specified - explain current conversation context
        my $prompt = "Please explain the code we've been discussing. " .
                    "Provide a clear explanation of what it does, key components, and how it works.";
        
        return $prompt;
    }
}

=head2 handle_review_command(@args)

Review code for potential issues. Returns prompt to send to AI.

=cut

sub handle_review_command {
    my ($self, @args) = @_;
    
    my $file = join(' ', @args);
    my $code_content = "";
    
    if ($file) {
        # Resolve relative path
        unless ($file =~ m{^/}) {
            my $cwd = Cwd::getcwd() || $ENV{PWD} || '.';
            $file = "$cwd/$file";
        }
        
        unless (-f $file) {
            $self->display_error_message("File not found: $file");
            return;
        }
        
        # Read file content
        open my $fh, '<', $file or do {
            $self->display_error_message("Cannot read file: $!");
            return;
        };
        $code_content = do { local $/; <$fh> };
        close $fh;
        
        # Build prompt with code
        my $prompt = "Please review the following code from $file:\n\n```\n$code_content\n```\n\n" .
                    "Conduct a thorough code review focusing on:\n" .
                    "1. Potential bugs or logic errors\n" .
                    "2. Security vulnerabilities\n" .
                    "3. Performance issues\n" .
                    "4. Code quality and best practices\n" .
                    "5. Edge cases that might not be handled\n" .
                    "6. Suggestions for improvement\n\n" .
                    "Be specific and provide examples where possible.";
        
        # Display info message
        $self->display_system_message("Reviewing code from: $file");
        $self->writeline("", markdown => 0);
        
        return $prompt;
    } else {
        # No file specified - review current conversation context
        my $prompt = "Please review the code we've been discussing. " .
                    "Look for potential bugs, security issues, performance problems, " .
                    "and opportunities for improvement.";
        
        return $prompt;
    }
}

=head2 handle_test_command(@args)

Generate tests for code. Returns prompt to send to AI.

=cut

sub handle_test_command {
    my ($self, @args) = @_;
    
    my $file = join(' ', @args);
    my $code_content = "";
    
    if ($file) {
        # Resolve relative path
        unless ($file =~ m{^/}) {
            my $cwd = Cwd::getcwd() || $ENV{PWD} || '.';
            $file = "$cwd/$file";
        }
        
        unless (-f $file) {
            $self->display_error_message("File not found: $file");
            return;
        }
        
        # Read file content
        open my $fh, '<', $file or do {
            $self->display_error_message("Cannot read file: $!");
            return;
        };
        $code_content = do { local $/; <$fh> };
        close $fh;
        
        # Detect file type for appropriate test framework
        my $test_framework = "appropriate test framework";
        if ($file =~ /\.pm$/) {
            $test_framework = "Test::More or Test2::Suite";
        } elsif ($file =~ /\.pl$/) {
            $test_framework = "Test::More or prove";
        } elsif ($file =~ /\.py$/) {
            $test_framework = "pytest or unittest";
        } elsif ($file =~ /\.js$/) {
            $test_framework = "Jest or Mocha";
        } elsif ($file =~ /\.ts$/) {
            $test_framework = "Jest or Vitest";
        }
        
        # Build prompt with code
        my $prompt = "Please generate comprehensive tests for the following code from $file:\n\n```\n$code_content\n```\n\n" .
                    "Generate tests using $test_framework that cover:\n" .
                    "1. Normal/happy path scenarios\n" .
                    "2. Edge cases and boundary conditions\n" .
                    "3. Error handling and failure modes\n" .
                    "4. Different input variations\n" .
                    "5. Integration points (if applicable)\n\n" .
                    "Provide complete, runnable test code with clear descriptions.";
        
        # Display info message
        $self->display_system_message("Generating tests for: $file");
        $self->writeline("", markdown => 0);
        
        return $prompt;
    } else {
        # No file specified - generate tests for current conversation context
        my $prompt = "Please generate comprehensive tests for the code we've been discussing. " .
                    "Include normal cases, edge cases, error handling, and clear test descriptions.";
        
        return $prompt;
    }
}

=head2 handle_fix_command(@args)

Suggest fixes for code errors. Returns prompt to send to AI.

=cut

sub handle_fix_command {
    my ($self, @args) = @_;
    
    my $file = join(' ', @args);
    
    unless ($file && -f $file) {
        $self->display_error_message("Usage: /fix <file>");
        return;
    }
    
    # Read file content
    open my $fh, '<', $file or do {
        $self->display_error_message("Cannot read file: $file");
        return;
    };
    my $code = do { local $/; <$fh> };
    close $fh;
    
    # Get errors/diagnostics (Perl only for now)
    my $errors = `perl -c $file 2>&1`;
    
    # Build prompt
    my $prompt = <<"PROMPT";
Analyze this code and propose fixes for any problems:

File: $file

Code:
```
$code
```

Problems detected:
$errors

Provide:
1. Clear explanation of each problem
2. Proposed fix for each issue
3. Complete corrected code

Focus on:
- Logic errors
- Security issues
- Performance problems
- Best practice violations
PROMPT

    return $prompt;
}

=head2 handle_doc_command(@args)

Generate documentation for code. Returns prompt to send to AI.

=cut

sub handle_doc_command {
    my ($self, @args) = @_;
    
    my $file = join(' ', @args);
    
    unless ($file && -f $file) {
        $self->display_error_message("Usage: /doc <file>");
        return;
    }
    
    # Read file content
    open my $fh, '<', $file or do {
        $self->display_error_message("Cannot read file: $file");
        return;
    };
    my $code = do { local $/; <$fh> };
    close $fh;
    
    # Detect language from file extension
    my $format = 'POD';  # Default for Perl
    if ($file =~ /\.js$/) { $format = 'JSDoc'; }
    elsif ($file =~ /\.py$/) { $format = 'Python docstrings'; }
    elsif ($file =~ /\.ts$/) { $format = 'TSDoc'; }
    
    my $prompt = <<"PROMPT";
Generate comprehensive documentation for this code:

File: $file

Code:
```
$code
```

Generate:
1. Module/function overview
2. Parameter descriptions with types
3. Return value documentation
4. Usage examples
5. Edge cases and error handling
6. Dependencies and requirements

Format: $format

Make the documentation clear, comprehensive, and ready to use.
PROMPT

    return $prompt;
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut
