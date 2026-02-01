package CLIO::UI::Commands::Skills;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

use Carp qw(croak);
use File::Spec;
use CLIO::Core::Logger qw(should_log);

=head1 NAME

CLIO::UI::Commands::Skills - Custom skill management commands for CLIO

=head1 SYNOPSIS

  use CLIO::UI::Commands::Skills;
  
  my $skills_cmd = CLIO::UI::Commands::Skills->new(
      chat => $chat_instance,
      session => $session,
      debug => 0
  );
  
  # Handle /skills commands
  $skills_cmd->handle_skills_command('list');
  $skills_cmd->handle_skills_command('add', 'myskill', 'prompt text');

=head1 DESCRIPTION

Handles custom skill management commands including:
- /skills list - List all custom and built-in skills
- /skills add <name> "<text>" - Add a custom skill
- /skills use <name> [file] - Execute a skill
- /skills show <name> - Display skill details
- /skills delete <name> - Delete a custom skill

Extracted from Chat.pm to improve maintainability.

=cut

sub new {
    my ($class, %args) = @_;
    
    my $self = {
        chat => $args{chat} || croak "chat instance required",
        debug => $args{debug} // 0,
    };
    
    # Assign object references separately (hash literal assignment bug workaround)
    $self->{session} = $args{session};
    
    bless $self, $class;
    return $self;
}

# Delegate display methods to chat
sub display_system_message { shift->{chat}->display_system_message(@_) }
sub display_error_message { shift->{chat}->display_error_message(@_) }
sub display_info_message { shift->{chat}->display_info_message(@_) }
sub display_success_message { shift->{chat}->display_success_message(@_) }
sub writeline { shift->{chat}->writeline(@_) }
sub display_command_header { shift->{chat}->display_command_header(@_) }
sub display_section_header { shift->{chat}->display_section_header(@_) }
sub display_key_value { shift->{chat}->display_key_value(@_) }
sub display_list_item { shift->{chat}->display_list_item(@_) }
sub colorize { shift->{chat}->colorize(@_) }
sub render_markdown { shift->{chat}->render_markdown(@_) }

=head2 _get_skill_manager()

Get or create the SkillManager instance.

=cut

sub _get_skill_manager {
    my ($self) = @_;
    
    require CLIO::Core::SkillManager;
    return CLIO::Core::SkillManager->new(
        debug => $self->{debug},
        session_skills_file => $self->{session} ? 
            File::Spec->catfile('sessions', $self->{session}{session_id}, 'skills.json') : 
            undef
    );
}

=head2 handle_skills_command(@args)

Main handler for /skills commands.

=cut

sub handle_skills_command {
    my ($self, @args) = @_;
    
    my $action = shift @args || 'list';
    my $sm = $self->_get_skill_manager();
    
    if ($action eq 'add') {
        return $self->_add_skill($sm, @args);
    }
    elsif ($action eq 'list' || $action eq 'ls') {
        $self->_list_skills($sm);
    }
    elsif ($action eq 'use' || $action eq 'exec') {
        return $self->_use_skill($sm, @args);
    }
    elsif ($action eq 'show') {
        $self->_show_skill($sm, @args);
    }
    elsif ($action eq 'delete' || $action eq 'rm') {
        $self->_delete_skill($sm, @args);
    }
    elsif ($action eq 'search') {
        $self->_search_skills(@args);
    }
    elsif ($action eq 'install') {
        $self->_install_skill($sm, @args);
    }
    elsif ($action eq 'help') {
        $self->_show_help();
    }
    else {
        $self->display_error_message("Unknown action: $action");
        $self->_show_help();
    }
    
    return;
}

=head2 _show_help()

Display skills command help using unified style.

=cut

sub _show_help {
    my ($self) = @_;
    
    $self->display_command_header("SKILLS");
    
    $self->display_section_header("COMMANDS");
    $self->{chat}->display_command_row("/skills", "List all skills", 35);
    $self->{chat}->display_command_row("/skills use <name> [file]", "Execute skill", 35);
    $self->{chat}->display_command_row("/skills show <name>", "Display skill details", 35);
    $self->{chat}->display_command_row("/skills add <name> \"<text>\"", "Add custom skill", 35);
    $self->{chat}->display_command_row("/skills delete <name>", "Delete custom skill", 35);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("CATALOG");
    $self->{chat}->display_command_row("/skills search [query]", "Search skills catalog", 35);
    $self->{chat}->display_command_row("/skills install <name>", "Install skill from catalog", 35);
    $self->writeline("", markdown => 0);
}

=head2 _add_skill($sm, @args)

Add a new custom skill.

=cut

sub _add_skill {
    my ($self, $sm, @args) = @_;
    
    my $name = shift @args;
    my $skill_text = join(' ', @args);
    
    unless ($name && $skill_text) {
        $self->display_error_message("Usage: /skills add <name> \"<skill text>\"");
        return;
    }
    
    # Remove quotes if present
    $skill_text =~ s/^["']//;
    $skill_text =~ s/["']$//;
    
    my $result = $sm->add_skill($name, $skill_text);
    
    if ($result->{success}) {
        $self->display_system_message("Added skill '$name'");
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _list_skills($sm)

List all available skills with modern formatting.

=cut

sub _list_skills {
    my ($self, $sm) = @_;
    
    my $skills = $sm->list_skills();
    
    $self->display_command_header("SKILLS");
    
    # Custom skills section
    $self->display_section_header("CUSTOM SKILLS");
    
    if (@{$skills->{custom}}) {
        for my $name (sort @{$skills->{custom}}) {
            my $s = $sm->get_skill($name);
            my $desc = $s->{description} || '(no description)';
            $self->display_key_value($name, $desc, 16);
        }
    } else {
        $self->writeline("  " . $self->colorize("(none)", 'DIM'), markdown => 0);
    }
    $self->writeline("", markdown => 0);
    
    # Built-in skills section
    $self->display_section_header("BUILT-IN SKILLS");
    
    for my $name (sort @{$skills->{builtin}}) {
        my $s = $sm->get_skill($name);
        my $desc = $s->{description} || '(no description)';
        $self->display_key_value($name, $desc, 16);
    }
    
    # Summary (with blank line before for separation)
    print "\n";
    my $custom_count = scalar(@{$skills->{custom}});
    my $builtin_count = scalar(@{$skills->{builtin}});
    my $total = $custom_count + $builtin_count;
    
    my $summary = $self->colorize("Total: ", 'LABEL') .
                  $self->colorize("$custom_count", 'DATA') . " custom, " .
                  $self->colorize("$builtin_count", 'DATA') . " built-in" .
                  " (" . $self->colorize("$total", 'SUCCESS') . " total)";
    $self->writeline($summary, markdown => 0);
    
    # Management commands
    $self->display_section_header("COMMANDS");
    $self->{chat}->display_command_row("/skills use <name> [file]", "Execute skill", 35);
    $self->{chat}->display_command_row("/skills show <name>", "Display skill details", 35);
    $self->{chat}->display_command_row("/skills add <name> \"<text>\"", "Add custom skill", 35);
    $self->{chat}->display_command_row("/skills delete <name>", "Delete custom skill", 35);
    $self->writeline("", markdown => 0);
    
    $self->display_section_header("CATALOG");
    $self->{chat}->display_command_row("/skills search [query]", "Search skills catalog", 35);
    $self->{chat}->display_command_row("/skills install <name>", "Install skill from catalog", 35);
    $self->writeline("", markdown => 0);
}

=head2 _use_skill($sm, @args)

Execute a skill and return prompt for AI.

=cut

sub _use_skill {
    my ($self, $sm, @args) = @_;
    
    my $name = shift @args;
    my $file = join(' ', @args);
    
    unless ($name) {
        $self->display_error_message("Usage: /skills use <name> [file]");
        return;
    }
    
    # Build context
    my $context = $self->_build_skill_context($file);
    
    # Execute skill
    my $result = $sm->execute_skill($name, $context);
    
    if ($result->{success}) {
        # Return prompt to be sent to AI
        return (1, $result->{rendered_prompt});
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _build_skill_context($file)

Build context hash for skill execution.

=cut

sub _build_skill_context {
    my ($self, $file) = @_;
    
    my $context = {};
    
    if ($file && -f $file) {
        open my $fh, '<', $file;
        $context->{code} = do { local $/; <$fh> };
        close $fh;
        $context->{file} = $file;
    }
    
    # Add session context if available
    if ($self->{session} && $self->{session}{state}) {
        my $history = $self->{session}{state}->get_history();
        if ($history && @$history) {
            # Get last few messages as context
            my $recent = @$history > 5 ? [@$history[-5..-1]] : $history;
            $context->{recent_context} = join("\n", map { 
                ($_->{role} || 'user') . ": " . ($_->{content} || '')
            } @$recent);
        }
    }
    
    return $context;
}

=head2 _show_skill($sm, @args)

Display skill details with modern formatting.

=cut

sub _show_skill {
    my ($self, $sm, @args) = @_;
    
    my $name = shift @args;
    
    unless ($name) {
        $self->display_error_message("Usage: /skills show <name>");
        return;
    }
    
    my $skill = $sm->get_skill($name);
    unless ($skill) {
        $self->display_error_message("Skill '$name' not found");
        return;
    }
    
    $self->display_command_header("SKILL: " . uc($name));
    
    # Metadata section
    $self->display_section_header("DETAILS");
    $self->display_key_value("Name", $name);
    $self->display_key_value("Type", $skill->{type} || 'custom');
    $self->display_key_value("Description", $skill->{description} || '(none)');
    
    if ($skill->{variables} && @{$skill->{variables}}) {
        $self->display_key_value("Variables", join(", ", @{$skill->{variables}}));
    }
    
    if ($skill->{created}) {
        $self->display_key_value("Created", scalar(localtime($skill->{created})));
    }
    if ($skill->{modified}) {
        $self->display_key_value("Modified", scalar(localtime($skill->{modified})));
    }
    $self->writeline("", markdown => 0);
    
    # Prompt section
    $self->display_section_header("PROMPT TEMPLATE");
    $self->writeline("", markdown => 0);
    
    # Render through markdown pipeline for proper formatting
    my $rendered = $self->render_markdown($skill->{prompt});
    if (defined $rendered) {
        for my $line (split /\n/, $rendered) {
            $self->writeline($line, markdown => 0);  # Already rendered
        }
    }
    
    $self->writeline("", markdown => 0);
}

=head2 _delete_skill($sm, @args)

Delete a custom skill.

=cut

sub _delete_skill {
    my ($self, $sm, @args) = @_;
    
    my $name = shift @args;
    
    unless ($name) {
        $self->display_error_message("Usage: /skills delete <name>");
        return;
    }
    
    print $self->{chat}{theme_mgr}->get_input_prompt("Delete skill '$name'? Type 'yes' to confirm", "cancel") . "\n";
    print "> ";
    my $confirm = <STDIN>;
    chomp $confirm if defined $confirm;
    
    unless ($confirm && $confirm =~ /^y(es)?$/i) {
        $self->display_system_message("Deletion cancelled");
        return;
    }
    
    my $result = $sm->delete_skill($name);
    
    if ($result->{success}) {
        $self->display_system_message("Deleted skill '$name'");
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _search_skills(@args)

Search for skills in the remote skills repository.

=cut

# Skills repository URL
our $SKILLS_REPO_API = 'https://api.github.com/repos/SyntheticAutonomicMind/clio-skills/contents/skills/.curated';
our $SKILLS_REPO_RAW = 'https://raw.githubusercontent.com/SyntheticAutonomicMind/clio-skills/main/skills/.curated';

sub _search_skills {
    my ($self, @args) = @_;
    
    my $query = join(' ', @args);
    
    $self->display_command_header("SKILLS CATALOG");
    $self->writeline("Fetching skills from catalog...", markdown => 0);
    $self->writeline("", markdown => 0);
    
    # Fetch skills list from GitHub API
    require CLIO::Compat::HTTP;
    my $ua = CLIO::Compat::HTTP->new(timeout => 30);
    
    my $resp = $ua->get($SKILLS_REPO_API, headers => {
        'Accept' => 'application/vnd.github.v3+json',
        'User-Agent' => 'CLIO/1.0'
    });
    
    unless ($resp->is_success) {
        $self->display_error_message("Failed to fetch skills catalog: " . $resp->status_line);
        return;
    }
    
    require JSON::PP;
    my $skills = eval { JSON::PP::decode_json($resp->decoded_content) };
    if ($@) {
        $self->display_error_message("Failed to parse skills catalog: $@");
        return;
    }
    
    # Filter to directories only (skill folders)
    my @skill_dirs = grep { $_->{type} eq 'dir' } @$skills;
    
    # Fetch SKILL.md for each to get descriptions
    my @available_skills;
    for my $skill (@skill_dirs) {
        my $skill_name = $skill->{name};
        my $skill_url = "$SKILLS_REPO_RAW/$skill_name/SKILL.md";
        
        my $skill_resp = $ua->get($skill_url, headers => { 'User-Agent' => 'CLIO/1.0' });
        next unless $skill_resp->is_success;
        
        my $content = $skill_resp->decoded_content;
        
        # Parse frontmatter
        my ($description) = $content =~ /description:\s*["']?([^"'\n]+)/;
        $description ||= '(no description)';
        
        # Filter by query if provided
        if ($query) {
            my $lc_query = lc($query);
            next unless lc($skill_name) =~ /\Q$lc_query\E/ || 
                        lc($description) =~ /\Q$lc_query\E/;
        }
        
        push @available_skills, {
            name => $skill_name,
            description => $description,
        };
    }
    
    if (@available_skills == 0) {
        if ($query) {
            $self->display_info_message("No skills found matching '$query'");
        } else {
            $self->display_info_message("No skills found in catalog");
        }
        return;
    }
    
    $self->display_section_header("AVAILABLE SKILLS");
    for my $skill (@available_skills) {
        $self->display_key_value($skill->{name}, $skill->{description}, 20);
    }
    
    print "\n";
    my $count = scalar(@available_skills);
    $self->writeline($self->colorize("Total: ", 'LABEL') . $self->colorize($count, 'DATA') . " skills", markdown => 0);
    
    $self->display_section_header("USAGE");
    $self->{chat}->display_command_row("/skills install <name>", "Install a skill", 30);
    $self->writeline("", markdown => 0);
}

=head2 _install_skill($sm, @args)

Install a skill from the remote skills repository.

=cut

sub _install_skill {
    my ($self, $sm, @args) = @_;
    
    my $name = shift @args;
    
    unless ($name) {
        $self->display_error_message("Usage: /skills install <name>");
        $self->writeline("", markdown => 0);
        $self->writeline("Use /skills search to see available skills", markdown => 0);
        return;
    }
    
    # Check if already installed
    my $existing = $sm->get_skill($name);
    if ($existing && $existing->{type} eq 'custom') {
        $self->display_error_message("Skill '$name' is already installed");
        return;
    }
    
    $self->display_command_header("INSTALLING SKILL");
    $self->writeline("Fetching skill '$name'...", markdown => 0);
    
    # Fetch SKILL.md from repository
    my $skill_url = "$SKILLS_REPO_RAW/$name/SKILL.md";
    
    require CLIO::Compat::HTTP;
    my $ua = CLIO::Compat::HTTP->new(timeout => 30);
    
    my $resp = $ua->get($skill_url, headers => { 'User-Agent' => 'CLIO/1.0' });
    
    unless ($resp->is_success) {
        if ($resp->code == 404) {
            $self->display_error_message("Skill '$name' not found in catalog");
            $self->writeline("Use /skills search to see available skills", markdown => 0);
        } else {
            $self->display_error_message("Failed to fetch skill: " . $resp->status_line);
        }
        return;
    }
    
    my $content = $resp->decoded_content;
    
    # Ensure content is properly decoded as UTF-8
    require Encode;
    $content = Encode::decode('UTF-8', $content) unless utf8::is_utf8($content);
    
    # Parse frontmatter
    my ($description) = $content =~ /description:\s*["']?([^"'\n]+)/;
    $description ||= "Skill from catalog";
    
    # Show skill info
    $self->writeline("", markdown => 0);
    $self->display_section_header("SKILL INFO");
    $self->display_key_value("Name", $name, 15);
    $self->display_key_value("Description", $description, 15);
    my @lines = split /\n/, $content;
    $self->display_key_value("Lines", scalar(@lines), 15);
    
    # Ask if user wants to preview full content
    print "\n";
    print $self->{chat}{theme_mgr}->get_input_prompt("View full content", "no") . " ";
    my $view_full = <STDIN>;
    chomp $view_full if defined $view_full;
    
    if ($view_full && $view_full =~ /^y(es)?$/i) {
        # Display full content with markdown rendering and pagination
        $self->writeline("", markdown => 0);
        $self->display_section_header("FULL CONTENT");
        $self->writeline("", markdown => 0);
        
        # Enable pagination for full content
        $self->{chat}->{pagination_enabled} = 1;
        $self->{chat}->{line_count} = 0;
        
        # Render the content as markdown (writeline with markdown => 1)
        last unless $self->writeline($content, markdown => 1);
        
        # Disable pagination
        $self->{chat}->{pagination_enabled} = 0;
        $self->writeline("", markdown => 0);
    }
    
    # Confirm installation
    print $self->{chat}{theme_mgr}->get_input_prompt("Install '$name'", "no") . " ";
    my $confirm = <STDIN>;
    chomp $confirm if defined $confirm;
    
    unless ($confirm && $confirm =~ /^y(es)?$/i) {
        $self->display_system_message("Installation cancelled");
        return;
    }
    
    # Install by adding to custom skills
    my $result = $sm->add_skill($name, $content, description => $description);
    
    if ($result->{success}) {
        $self->display_success_message("Skill '$name' installed successfully!");
        $self->writeline("Use: /skills use $name", markdown => 0);
    } else {
        $self->display_error_message("Failed to install skill: " . $result->{error});
    }
}

1;

__END__

=head1 AUTHOR

CLIO Development Team

=head1 LICENSE

Same as CLIO.

=cut