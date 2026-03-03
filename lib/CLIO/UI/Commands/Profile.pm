package CLIO::UI::Commands::Profile;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use CLIO::Core::Logger qw(log_debug log_warning);
use CLIO::Profile::Manager;
use CLIO::Profile::Analyzer;

=head1 NAME

CLIO::UI::Commands::Profile - /profile command for user personality profile management

=head1 DESCRIPTION

Manages the user's personality profile which personalizes CLIO's interaction
style across all projects and sessions.

Commands:
  /profile            - Show profile status
  /profile show       - Display current profile
  /profile build      - Analyze sessions and build/refine profile (AI-assisted)
  /profile edit       - Open profile in editor
  /profile clear      - Remove profile

The profile lives at ~/.clio/profile.md and is injected into the system
prompt alongside LTM patterns.

=cut

sub new {
    my ($class, %args) = @_;

    my $self = {
        chat    => $args{chat},
        session => $args{session},
        debug   => $args{debug} || 0,
    };

    return bless $self, $class;
}

# Display delegate methods
sub display_command_header  { shift->{chat}->display_command_header(@_) }
sub display_section_header  { shift->{chat}->display_section_header(@_) }
sub display_key_value       { shift->{chat}->display_key_value(@_) }
sub display_system_message  { shift->{chat}->display_system_message(@_) }
sub display_error_message   { shift->{chat}->display_error_message(@_) }
sub display_success_message { shift->{chat}->display_success_message(@_) }
sub display_list_item       { shift->{chat}->display_list_item(@_) }
sub writeline               { shift->{chat}->writeline(@_) }
sub colorize                { shift->{chat}->colorize(@_) }

=head2 handle_profile_command($action, @args)

Main dispatcher for /profile commands.

=cut

sub handle_profile_command {
    my ($self, $action, @args) = @_;

    $action ||= '';
    $action = lc($action);

    if ($action eq '' || $action eq 'help') {
        $self->_display_profile_status();
        return;
    }

    if ($action eq 'show') {
        $self->_display_profile();
        return;
    }

    if ($action eq 'build') {
        return $self->_handle_build();
    }

    if ($action eq 'edit') {
        $self->_handle_edit();
        return;
    }

    if ($action eq 'clear') {
        $self->_handle_clear();
        return;
    }

    if ($action eq 'path') {
        my $mgr = CLIO::Profile::Manager->new(debug => $self->{debug});
        $self->display_system_message($mgr->profile_path());
        return;
    }

    $self->display_error_message("Unknown action: /profile $action");
    $self->_display_profile_help();
}

sub _display_profile_status {
    my ($self) = @_;

    my $mgr = CLIO::Profile::Manager->new(debug => $self->{debug});
    my $analyzer = CLIO::Profile::Analyzer->new(debug => $self->{debug});

    $self->display_command_header("PROFILE");

    my $exists = $mgr->profile_exists();
    my $session_count = $analyzer->get_session_count();

    $self->display_key_value("Status", $exists ? "Active" : "Not configured");
    $self->display_key_value("Location", $mgr->profile_path());
    $self->display_key_value("Sessions available", $session_count);

    if ($exists) {
        my $content = $mgr->load_profile();
        if ($content) {
            my $lines = () = $content =~ /\n/g;
            $self->display_key_value("Profile size", length($content) . " bytes, ~" . ($lines + 1) . " lines");
        }
    }

    $self->writeline("");

    if (!$exists && $session_count >= 10) {
        $self->display_system_message("Run /profile build to create your profile from session history");
    } elsif (!$exists && $session_count < 10) {
        $self->display_system_message("Need ~10 sessions before /profile build has enough data ($session_count available)");
    }

    $self->_display_profile_help();
}

sub _display_profile_help {
    my ($self) = @_;

    $self->writeline("");
    $self->display_section_header("Commands");
    $self->display_key_value("/profile build", "Analyze sessions and build profile (AI-assisted)");
    $self->display_key_value("/profile show", "Display current profile");
    $self->display_key_value("/profile edit", "Open profile in your editor");
    $self->display_key_value("/profile clear", "Remove profile");
    $self->display_key_value("/profile path", "Show profile file location");
}

sub _display_profile {
    my ($self) = @_;

    my $mgr = CLIO::Profile::Manager->new(debug => $self->{debug});

    unless ($mgr->profile_exists()) {
        $self->display_system_message("No profile configured. Run /profile build to create one.");
        return;
    }

    my $content = $mgr->load_profile();
    unless ($content) {
        $self->display_error_message("Failed to read profile");
        return;
    }

    $self->display_command_header("USER PROFILE");
    $self->writeline("");

    # Display the profile content with basic formatting
    for my $line (split /\n/, $content) {
        if ($line =~ /^##\s+(.+)/) {
            $self->display_section_header($1);
        } elsif ($line =~ /^\*\*(.+?)\*\*(.*)/) {
            $self->display_key_value($1, $2);
        } elsif ($line =~ /^-\s+(.+)/) {
            $self->display_list_item($1);
        } else {
            $self->writeline($line) if $line =~ /\S/;
        }
    }
}

sub _handle_build {
    my ($self) = @_;

    my $analyzer = CLIO::Profile::Analyzer->new(debug => $self->{debug});
    my $mgr = CLIO::Profile::Manager->new(debug => $self->{debug});

    $self->display_system_message("Analyzing session history...");

    my $analysis = $analyzer->analyze_sessions();

    if (!$analysis || ($analysis->{total_user_msgs} || 0) < 5) {
        $self->display_error_message(
            "Not enough session data to build a profile " .
            "($analysis->{total_user_msgs} messages found, need at least 5)"
        );
        return;
    }

    $self->display_system_message(
        "Analyzed $analysis->{total_sessions} sessions, " .
        "$analysis->{total_user_msgs} messages across " .
        scalar(keys %{$analysis->{projects}}) . " projects"
    );

    # Generate draft
    my $draft = $analyzer->generate_profile_draft($analysis);

    # Build a prompt that sends the analysis to the AI for collaborative refinement
    my $prompt = $self->_build_refinement_prompt($analysis, $draft, $mgr->profile_exists());

    # Return the prompt to be sent to the AI (like /design does)
    return (1, $prompt);
}

sub _build_refinement_prompt {
    my ($self, $analysis, $draft, $existing) = @_;

    my $total = $analysis->{total_user_msgs};
    my $sessions = $analysis->{total_sessions};
    my $projects = scalar(keys %{$analysis->{projects}});

    # Build context from sample messages
    my $samples = '';
    my $count = 0;
    for my $msg (@{$analysis->{user_messages} || []}) {
        last if $count >= 30;
        my $content = $msg->{content};
        next if length($content) < 15;
        $samples .= "[$msg->{project}] $content\n";
        $count++;
    }

    my $style_summary = '';
    my $style = $analysis->{style} || {};
    for my $k (sort { ($style->{$b} || 0) <=> ($style->{$a} || 0) } keys %$style) {
        my $pct = sprintf("%.0f", 100 * ($style->{$k} || 0) / ($total || 1));
        $style_summary .= "  $k: $style->{$k} ($pct%)\n";
    }

    my $update_word = $existing ? "update" : "create";

    my $prompt = <<PROMPT;
You are helping the user $update_word their CLIO personality profile. This profile will be injected into the system prompt of every future CLIO session to personalize AI collaboration.

## Session Analysis Data

**Scope:** $sessions sessions, $total user messages, $projects projects

**Communication Style Indicators:**
$style_summary

**Sample User Messages (for qualitative analysis):**
$samples

**Auto-generated Draft:**
$draft

## Your Task

Use the user_collaboration tool to present the draft profile and refine it with the user. The profile should be:

1. **Concise** - 400-800 tokens max. This goes into every system prompt.
2. **Actionable** - Each line should change AI behavior, not just describe the user.
3. **Accurate** - Based on real data, not assumptions. The user validates everything.
4. **Formatted** as markdown with clear sections.

Walk through the draft with the user:
- Show what the analysis found
- Ask if each section feels accurate
- Let them add, remove, or modify anything
- When they're satisfied, save it with the file_operations tool to: ~/.clio/profile.md

The file path is: ${\CLIO::Profile::Manager->new()->profile_path()}

Remember: This profile describes the HUMAN, not the AI. It tells future AI sessions how to work with this specific person.
PROMPT

    return $prompt;
}

sub _handle_edit {
    my ($self) = @_;

    my $mgr = CLIO::Profile::Manager->new(debug => $self->{debug});
    my $path = $mgr->profile_path();

    unless ($mgr->profile_exists()) {
        $self->display_system_message("No profile exists yet. Run /profile build to create one first.");
        return;
    }

    # Find editor
    my $editor = $ENV{EDITOR} || $ENV{VISUAL} || 'vi';

    $self->display_system_message("Opening profile in $editor...");

    # Save terminal state and run editor
    system($editor, $path);

    $self->display_success_message("Profile saved. Changes take effect on next session.");
}

sub _handle_clear {
    my ($self) = @_;

    my $mgr = CLIO::Profile::Manager->new(debug => $self->{debug});

    unless ($mgr->profile_exists()) {
        $self->display_system_message("No profile to clear.");
        return;
    }

    if ($mgr->clear_profile()) {
        $self->display_success_message("Profile removed. CLIO will use default interaction style.");
    } else {
        $self->display_error_message("Failed to remove profile.");
    }
}

1;
