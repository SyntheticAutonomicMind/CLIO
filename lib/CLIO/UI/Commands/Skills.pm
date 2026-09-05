# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::UI::Commands::Skills;

use strict;
use warnings;
use utf8;
use parent 'CLIO::UI::Commands::Base';

use Carp qw(croak);
use File::Spec;
use CLIO::Util::JSON qw(decode_json safe_decode_json);

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
    
    # Assign object references separately
    $self->{session} = $args{session};
    
    bless $self, $class;
    return $self;
}


=head2 _get_skill_manager()

Get or create the SkillManager instance.

=cut

sub _get_skill_manager {
    my ($self) = @_;

    require CLIO::Core::SkillManager;
    require CLIO::Util::ConfigPath;

    # Detect the active project. We treat a directory containing a
    # .clio/ subdir as a project root. This keeps the user-level skills
    # file (in $HOME) distinct from the project-level one, so /skills
    # add and /skills install land in the right place.
    #
    # The user config dir (usually $HOME/.clio) is not a project root -
    # it is the global user skills file. Walking the tree must not pick
    # that up, otherwise a skill in the user file gets loaded twice and
    # the second pass tags it as scope=project, which mis-reports where
    # it lives and would let /skills add --project silently shadow it.
    my $user_dir = CLIO::Util::ConfigPath::get_config_dir();
    my $project_dir = $self->_resolve_project_dir($user_dir);
    my $project_skills_file = $project_dir
        ? File::Spec->catfile($project_dir, '.clio', 'skills.json')
        : undef;

    return CLIO::Core::SkillManager->new(
        debug => $self->{debug},
        project_skills_file => $project_skills_file,
        session_skills_file => $self->{session} ?
            File::Spec->catfile('sessions', $self->{session}{session_id}, 'skills.json') :
            undef,
    );
}

=head2 _resolve_project_dir

Return the absolute path of the project root for the current working
directory, or undef if CWD is not inside a CLIO project. A project is
identified by a .clio/ subdirectory anywhere up the tree, but we
prefer the closest ancestor so skills written to a sub-project do not
leak into the parent project's skills.json.

The C<$exclude> argument is an absolute path that must never be returned
as a project root even if it has a .clio/ subdirectory. This is the
user config dir (usually $HOME/.clio), which is the backing store for
the user scope, not a project.

=cut

sub _resolve_project_dir {
    my ($self, $exclude) = @_;

    # Use Cwd's getcwd so we always work with an absolute path. Without
    # this, on a cwd like "..", splitpath produces a different parent
    # each iteration and the .clio check can race.
    require Cwd;
    my $cwd = Cwd::getcwd();
    my @candidates = ($cwd);
    # Walk up at most 5 ancestors to avoid scanning the whole filesystem.
    my $dir = $cwd;
    for (1..5) {
        my ($vol, $parent) = File::Spec->splitpath($dir);
        $parent =~ s{/+\z}{};
        last unless length $parent && $parent ne $dir;
        $dir = $parent;
        unshift @candidates, $dir;
    }

    for my $candidate (@candidates) {
        # The user config dir (usually $HOME/.clio) holds the user-level
        # skills file, not a project. Treat its parent as the boundary:
        # candidates equal to that parent would point at the user dir if
        # it had a .clio/ subdir, but it IS the user dir, so skip it.
        if (defined $exclude) {
            my ($exclude_vol, $exclude_dir) = File::Spec->splitpath($exclude);
            $exclude_dir =~ s{/+\z}{};
            next if $candidate eq $exclude_dir;
        }
        my $clio = File::Spec->catdir($candidate, '.clio');
        return $candidate if -d $clio;
    }
    return undef;
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
        $self->_list_skills($sm, @args);
    }
    elsif ($action eq 'use' || $action eq 'exec') {
        return $self->_use_skill($sm, @args);
    }
    elsif ($action eq 'load') {
        $self->_load_skill($sm, @args);
    }
    elsif ($action eq 'unload') {
        $self->_unload_skill($sm, @args);
    }
    elsif ($action eq 'loaded') {
        $self->_show_loaded_skills($sm);
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
    elsif ($action eq 'repo') {
        $self->_handle_repo_command($sm, @args);
    }
    elsif ($action eq 'help') {
        $self->_show_help();
    }
    elsif ($action eq 'autocreate') {
        $self->_handle_autocreate(@args);
    }
    else {
        $self->display_error_message("Unknown action: $action");
        $self->_show_help();
    }

    return;
}

=head2 _parse_scope_flags

Pull --global / --project / --session flags (and the --scope=<value>
equivalent) out of an argument list. Returns the cleaned @args and a
hashref with key 'scope' set to 'user', 'project', or 'session' when
one of the flags was present, or empty when the user did not specify.

Recognised flags:
  --global      (alias: --user, --scope=user)
  --project     (alias: --scope=project)
  --session     (alias: --scope=session)

=cut

sub _parse_scope_flags {
    my ($self, @args) = @_;

    my %opts;
    my @kept;
    my $bad;
    for my $arg (@args) {
        if ($arg eq '--global' || $arg eq '--user') {
            $opts{scope} = 'user';
        }
        elsif ($arg eq '--project') {
            $opts{scope} = 'project';
        }
        elsif ($arg eq '--session') {
            $opts{scope} = 'session';
        }
        elsif ($arg =~ /^--scope=(user|project|session)$/i) {
            $opts{scope} = lc($1);
        }
        elsif ($arg =~ /^--scope=(\w+)$/i) {
            # --scope=<something> where <something> is not user/project/session.
            # Surface as a parse error rather than silently dropping it so the
            # user notices a typo before the skill gets written to the wrong
            # scope.
            $bad = $arg;
        }
        else {
            push @kept, $arg;
        }
    }
    return (\@kept, \%opts, $bad);
}

=head2 _scope_label

Return a human-readable label for a scope string. Centralised here so
the /skills list and /skills show output stay consistent.

=cut

sub _scope_label {
    my ($self, $scope) = @_;
    my %labels = (
        user => 'user', project => 'project', session => 'session',
        repository => 'repository', builtin => 'builtin', freeform => 'freeform',
    );
    return $labels{$scope} // $scope // 'unknown';
}

=head2 _show_help()

Display skills command help using unified style.

=cut

sub _show_help {
    my ($self) = @_;
    
    $self->display_command_header("SKILLS");

    $self->display_section_header("COMMANDS");
    $self->{chat}->display_command_row("/skills", "List all skills grouped by scope", 35);
    $self->{chat}->display_command_row("/skills --scope=<scope>", "Filter list (user|project|session|freeform|repository|builtin)", 35);
    $self->{chat}->display_command_row("/skills use <name> [file]", "Execute skill as user input", 35);
    $self->{chat}->display_command_row("/skills load <name>", "Load skill into system prompt", 35);
    $self->{chat}->display_command_row("/skills unload <name>", "Remove skill from system prompt", 35);
    $self->{chat}->display_command_row("/skills loaded", "Show loaded skills", 35);
    $self->{chat}->display_command_row("/skills show <name>", "Display skill details (includes scope + source)", 35);
    $self->{chat}->display_command_row("/skills add <name> \"<text>\" [--scope=...]", "Add custom skill (scope: user|project|session)", 35);
    $self->{chat}->display_command_row("/skills delete <name>", "Delete custom skill", 35);
    $self->{chat}->display_command_row("/skills autocreate [on|off]", "Toggle auto-skill creation on substantial work", 35);
    $self->writeline("", markdown => 0);

    $self->display_section_header("SCOPES");
    $self->writeline("  user       - ~/.clio/skills.json (visible in all projects)", markdown => 0);
    $self->writeline("  project    - .clio/skills.json in the current project", markdown => 0);
    $self->writeline("  session    - sessions/<id>/skills.json (cleared on session end)", markdown => 0);
    $self->writeline("  freeform   - .clio/skills/*.md files (edit the .md to modify)", markdown => 0);
    $self->writeline("  repository - skills pulled from a configured git repository", markdown => 0);
    $self->writeline("  builtin    - read-only skills shipped with CLIO", markdown => 0);
    $self->writeline("", markdown => 0);

    $self->display_section_header("CATALOG");
    $self->{chat}->display_command_row("/skills search [query]", "Search skills catalog", 35);
    $self->{chat}->display_command_row("/skills install <name> [--scope=...]", "Install skill from catalog (default: project)", 35);
    $self->writeline("", markdown => 0);

    $self->display_section_header("REPOSITORIES");
    $self->{chat}->display_command_row("/skills repo add <name> <url>", "Add skill repository", 35);
    $self->{chat}->display_command_row("/skills repo remove <name>", "Remove repository", 35);
    $self->{chat}->display_command_row("/skills repo list", "List configured repos", 35);
    $self->{chat}->display_command_row("/skills repo sync [name]", "Sync repositories", 35);
    $self->{chat}->display_command_row("/skills repo enable <name>", "Enable repository", 35);
    $self->{chat}->display_command_row("/skills repo disable <name>", "Disable repository", 35);
    $self->writeline("", markdown => 0);

    $self->display_section_header("MODES");
    $self->writeline("  use   - Send skill prompt as next message (immediate execution)", markdown => 0);
    $self->writeline("  load  - Merge skill into system prompt (persistent for session)", markdown => 0);
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
        $self->display_error_message("Usage: /skills add <name> \"<skill text>\" [--global|--project|--session]");
        return;
    }

    # Strip scope flags (--global / --project / --session) so they do not
    # become part of the prompt text. Reassemble the rest as the skill body.
    my ($cleaned, $opts, $bad_scope) = $self->_parse_scope_flags(@args);
    if ($bad_scope) {
        $self->display_error_message("Invalid $bad_scope (use --global, --project, --session, or --scope=user|project|session)");
        return;
    }
    $skill_text = join(' ', @$cleaned);
    # Remove quotes if present
    $skill_text =~ s/^["']//;
    $skill_text =~ s/["']$//;

    my $result = $sm->add_skill($name, $skill_text, %$opts);

    if ($result->{success}) {
        my $scope = $result->{prompt}{scope} // 'user';
        $self->display_success_message("Added skill '$name' to $scope scope");
        if ($result->{prompt}{source}) {
            $self->writeline("  File: $result->{prompt}{source}", markdown => 0);
        }
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _handle_autocreate(@args)

Toggle the auto-skill creation feature.

When auto_create_skills is on, the system prompt includes guidance for
the agent to call skill_operations(operation=create) after completing
substantial reusable work. The agent then writes a SKILL.md file that
future sessions can load via /skills load.

Usage:
  /skills autocreate         Show current setting
  /skills autocreate on      Enable
  /skills autocreate off     Disable

The setting persists in config as auto_create_skills (0/1).

=cut

sub _handle_autocreate {
    my ($self, @args) = @_;

    my $config = $self->{chat}->{config};
    unless ($config) {
        $self->display_error_message("Config unavailable; cannot toggle auto-create.");
        return;
    }

    my $current = $config->get('auto_create_skills');
    $current //= 1;  # Default mirrors Config.pm DEFAULT_CONFIG.

    my $arg = $args[0];

    # No arg or empty arg: show current state.
    if (!defined $arg || $arg eq '') {
        my $state = $current ? 'on' : 'off';
        $self->display_key_value("Auto-create skills", $state);
        if ($current) {
            $self->writeline("Agent will create a reusable skill after substantial work.", markdown => 0);
        }
        else {
            $self->writeline("Agent will not auto-create skills.", markdown => 0);
        }
        return;
    }

    my $lc = lc($arg);
    if ($lc eq 'on' || $lc eq '1' || $lc eq 'true' || $lc eq 'yes' || $lc eq 'enable') {
        $config->set('auto_create_skills', 1);
        $self->display_success_message("Auto-create skills: on");
    }
    elsif ($lc eq 'off' || $lc eq '0' || $lc eq 'false' || $lc eq 'no' || $lc eq 'disable') {
        $config->set('auto_create_skills', 0);
        $self->display_success_message("Auto-create skills: off");
    }
    else {
        $self->display_error_message("Unknown value: $arg (use 'on' or 'off')");
    }
}

=head2 _list_skills($sm, @args)

List all available skills with scope labels. Each skill is shown with
its source (file path for custom/freeform, repo name for repository).
A C<--scope=<user|project|session|repository|builtin|freeform>> filter
narrows the list to a single scope; C<--scope=custom> matches the
union of user, project, and session.

=cut

sub _list_skills {
    my ($self, $sm, @args) = @_;

    # Pull the optional --scope= filter out of @args.
    my %filter;
    my @kept;
    for my $arg (@args) {
        if ($arg =~ /^--scope=(\w+)$/i) {
            $filter{scope} = lc($1);
        }
        elsif ($arg =~ /^--(user|project|session|repository|builtin|freeform)$/i) {
            $filter{scope} = lc($1);
        }
        else {
            push @kept, $arg;
        }
    }
    if (@kept) {
        $self->display_error_message("Unknown list option: @kept (use --scope=<name>)");
        return;
    }

    my $skills = $sm->list_skills();

    # Determine which scope buckets to show. 'custom' is a virtual bucket
    # covering user + project + session .json-backed skills, kept for
    # back-compat with scripts that used the old /skills list grouping.
    my @buckets;
    my %by_scope = %{$skills->{by_scope} || {}};
    if (my $wanted = $filter{scope}) {
        if ($wanted eq 'custom') {
            @buckets = (
                ['user',    $by_scope{user}    // []],
                ['project', $by_scope{project} // []],
                ['session', $by_scope{session} // []],
            );
        }
        else {
            @buckets = ([$wanted, $by_scope{$wanted} // []]);
        }
    }
    else {
        @buckets = (
            ['user',       $by_scope{user}       // []],
            ['project',    $by_scope{project}    // []],
            ['session',    $by_scope{session}    // []],
            ['freeform',   $by_scope{freeform}   // []],
            ['repository', $by_scope{repository} // []],
            ['builtin',    $by_scope{builtin}    // []],
        );
    }

    # Check for loaded skills
    my $state = $self->_get_session_state();
    my $loaded = $state ? ($state->{loaded_skills} || []) : [];
    my %loaded_names = map { $_->{name} => 1 } @$loaded;
    
    $self->display_command_header("SKILLS");
    
    # Loaded skills section (show first if any are loaded)
    if (@$loaded) {
        $self->display_section_header("LOADED (IN SYSTEM PROMPT)");
        for my $ls (@$loaded) {
            my $name = $ls->{name} || 'unknown';
            my $desc = $ls->{description} || '';
            my $size = length($ls->{content} || '');
            $self->display_key_value($name, $desc . " (${size}b)", 16);
        }
        $self->writeline("", markdown => 0);
    }
    
    # Render one section per bucket. Order is consistent: user, project,
    # session, freeform, repository, builtin. A single bucket section is
    # omitted when empty so the output stays focused.
    my %scope_descriptions = (
        user       => 'Stored in your user skills file. Visible across all projects.',
        project    => 'Stored in this project\'s .clio/skills.json. Visible only here.',
        session    => 'Stored in this session\'s skills.json. Cleared when the session ends.',
        freeform   => 'Loaded from .clio/skills/*.md files. Edit the .md to modify.',
        repository => 'Loaded from a configured skill repository.',
        builtin    => 'Built into CLIO. Read-only.',
    );

    my $total_visible = 0;
    for my $bucket (@buckets) {
        my ($scope, $names) = @$bucket;
        $total_visible += scalar(@$names);
        next unless $names && @$names;

        my $label = uc($self->_scope_label($scope));
        $self->display_section_header("$label SKILLS" . ($filter{scope} ? '' : ''));
        if ($scope_descriptions{$scope} && !$filter{scope}) {
            $self->writeline("  " . $self->colorize($scope_descriptions{$scope}, 'DIM'), markdown => 0);
        }

        for my $name (sort @$names) {
            my $s = $sm->get_skill($name);
            my $desc = $s->{description} || '(no description)';
            my $indicator = $loaded_names{$name} ? ' [loaded]' : '';
            my $source_label = '';
            if ($scope eq 'repository' && $s->{source_repo}) {
                $source_label = " (repo: $s->{source_repo})";
            }
            elsif ($scope eq 'freeform' && $s->{location}) {
                $source_label = " (from $s->{location} dir)";
            }
            $self->display_key_value($name, $desc . $source_label . $indicator, 16);
        }
        $self->writeline("", markdown => 0);
    }

    # Empty hint when no skills are visible at all.
    if ($total_visible == 0) {
        my $hint = $filter{scope}
            ? "(no $filter{scope} skills)"
            : '(none)';
        $self->writeline("  " . $self->colorize($hint, 'DIM'), markdown => 0);
        $self->writeline("", markdown => 0);
    }

    # Summary
    print "\n";
    my $custom_count = scalar(@{$by_scope{user}   // []}) +
                       scalar(@{$by_scope{project}// []}) +
                       scalar(@{$by_scope{session}// []});
    my $builtin_count = scalar(@{$by_scope{builtin} // []});
    my $repo_count    = scalar(@{$by_scope{repository} // []});
    my $freeform_count= scalar(@{$by_scope{freeform} // []});
    my $loaded_count  = scalar(@$loaded);

    my $summary;
    if ($filter{scope}) {
        # When filtered, show how many skills matched the filter, and
        # remind the user which scope they were looking at. $total_visible
        # was computed while rendering the buckets above.
        $summary = $self->colorize("Filter: ", 'LABEL') .
                   $self->colorize($filter{scope}, 'DATA') . " - " .
                   $self->colorize("$total_visible", 'SUCCESS') . " visible";
        $summary .= " | " . $self->colorize("$loaded_count", 'DATA') . " loaded" if $loaded_count > 0;
    }
    else {
        my $total = $custom_count + $builtin_count + $repo_count + $freeform_count;
        $summary = $self->colorize("Total: ", 'LABEL') .
                   $self->colorize("$custom_count", 'DATA') . " custom, " .
                   $self->colorize("$freeform_count", 'DATA') . " freeform, " .
                   $self->colorize("$repo_count", 'DATA') . " repo, " .
                   $self->colorize("$builtin_count", 'DATA') . " built-in" .
                   " (" . $self->colorize("$total", 'SUCCESS') . " total)";
        $summary .= " | " . $self->colorize("$loaded_count", 'DATA') . " loaded" if $loaded_count > 0;
    }
    $self->writeline($summary, markdown => 0);

    # Management commands
    $self->display_section_header("COMMANDS");
    $self->{chat}->display_command_row("/skills use <name> [file]", "Execute skill as user input", 35);
    $self->{chat}->display_command_row("/skills load <name>", "Load skill into system prompt", 35);
    $self->{chat}->display_command_row("/skills unload <name>", "Remove from system prompt", 35);
    $self->{chat}->display_command_row("/skills show <name>", "Display skill details", 35);
    $self->{chat}->display_command_row("/skills add <name> \"<text>\" [--scope=...]", "Add custom skill", 35);
    $self->{chat}->display_command_row("/skills delete <name>", "Delete custom skill", 35);
    $self->{chat}->display_command_row("/skills autocreate [on|off]", "Toggle auto-skill creation on substantial work", 35);
    $self->writeline("", markdown => 0);

    $self->display_section_header("FILTERS");
    $self->{chat}->display_command_row("/skills --scope=user", "Show user-level skills only", 35);
    $self->{chat}->display_command_row("/skills --scope=project", "Show project-level skills only", 35);
    $self->{chat}->display_command_row("/skills --scope=session", "Show session-level skills only", 35);
    $self->{chat}->display_command_row("/skills --scope=freeform", "Show freeform .md skills only", 35);
    $self->writeline("", markdown => 0);

    $self->display_section_header("CATALOG");
    $self->{chat}->display_command_row("/skills search [query]", "Search skills catalog", 35);
    $self->{chat}->display_command_row("/skills install <name>", "Install skill from catalog", 35);
    $self->writeline("", markdown => 0);

    $self->display_section_header("REPOSITORIES");
    $self->{chat}->display_command_row("/skills repo add <name> <url>", "Add skill repository", 35);
    $self->{chat}->display_command_row("/skills repo remove <name>", "Remove repository", 35);
    $self->{chat}->display_command_row("/skills repo list", "List configured repos", 35);
    $self->{chat}->display_command_row("/skills repo sync [name]", "Sync repositories", 35);
    $self->{chat}->display_command_row("/skills repo enable <name>", "Enable repository", 35);
    $self->{chat}->display_command_row("/skills repo disable <name>", "Disable repository", 35);
    $self->writeline("", markdown => 0);
}

=head2 _load_skill($sm, @args)

Load a skill into the system prompt for the duration of the session.

=cut

sub _load_skill {
    my ($self, $sm, @args) = @_;
    
    my $name = shift @args;
    
    unless ($name) {
        $self->display_error_message("Usage: /skills load <name>");
        return;
    }
    
    # Get session state
    my $state = $self->_get_session_state();
    unless ($state) {
        $self->display_error_message("No active session");
        return;
    }
    
    my $result = $sm->load_skill($name, $state);
    
    if ($result->{success}) {
        $self->display_success_message("Skill '$name' loaded into system prompt");
        $self->writeline("  The skill will be active for the rest of this session.", markdown => 0);
        $self->writeline("  Use /skills unload $name to remove it.", markdown => 0);
        
        # Save session to persist loaded skills
        if ($self->{session} && $self->{session}->can('save')) {
            $self->{session}->save();
        }
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _unload_skill($sm, @args)

Remove a loaded skill from the system prompt.

=cut

sub _unload_skill {
    my ($self, $sm, @args) = @_;
    
    my $name = shift @args;
    
    unless ($name) {
        $self->display_error_message("Usage: /skills unload <name>");
        return;
    }
    
    my $state = $self->_get_session_state();
    unless ($state) {
        $self->display_error_message("No active session");
        return;
    }
    
    my $result = $sm->unload_skill($name, $state);
    
    if ($result->{success}) {
        $self->display_success_message("Skill '$name' unloaded from system prompt");
        
        # Save session to persist change
        if ($self->{session} && $self->{session}->can('save')) {
            $self->{session}->save();
        }
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _show_loaded_skills($sm)

Display skills currently loaded into the system prompt.

=cut

sub _show_loaded_skills {
    my ($self, $sm) = @_;
    
    my $state = $self->_get_session_state();
    unless ($state) {
        $self->display_error_message("No active session");
        return;
    }
    
    my $loaded = $sm->get_loaded_skills($state);
    
    $self->display_command_header("LOADED SKILLS");
    
    if (!$loaded || !@$loaded) {
        $self->writeline("  No skills loaded into system prompt.", markdown => 0);
        $self->writeline("  Use /skills load <name> to load one.", markdown => 0);
        $self->writeline("", markdown => 0);
        return;
    }
    
    for my $skill (@$loaded) {
        my $name = $skill->{name} || 'unknown';
        my $desc = $skill->{description} || '';
        my $size = length($skill->{content} || '');
        
        $self->display_key_value("Skill", $name, 15);
        $self->display_key_value("Description", $desc, 15) if $desc;
        $self->display_key_value("Size", "${size} bytes", 15);
        $self->writeline("", markdown => 0);
    }
}

=head2 _get_session_state

Get the session state object for loaded skills storage.

=cut

sub _get_session_state {
    my ($self) = @_;
    
    # session is the Session::Manager object
    if ($self->{session} && $self->{session}->can('state')) {
        return $self->{session}->state();
    }
    
    # Direct hash access (legacy or test)
    if ($self->{session} && ref($self->{session}) eq 'HASH' && $self->{session}{state}) {
        return $self->{session}{state};
    }
    
    return undef;
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

Display skill details with modern formatting and pagination.

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
    
    # Build output lines for paginated display
    my @lines;

    # Metadata section
    push @lines, $self->colorize("DETAILS", 'SECTION_HEADER');
    push @lines, "";
    push @lines, $self->colorize("Name:        ", 'LABEL') . $self->colorize($name, 'DATA');
    push @lines, $self->colorize("Type:        ", 'LABEL') . $self->colorize($skill->{type} || 'custom', 'DATA');
    push @lines, $self->colorize("Scope:       ", 'LABEL') . $self->colorize($self->_scope_label($skill->{scope} // 'user'), 'DATA');
    push @lines, $self->colorize("Description: ", 'LABEL') . $self->colorize($skill->{description} || '(none)', 'DATA');

    # Surface the file or repo that backs this skill so the user knows
    # where to edit it. Built-ins and freeform skills each have their own
    # hint about how to modify them.
    my $source = $skill->{source} || $skill->{_source_file};
    if ($skill->{source_repo}) {
        push @lines, $self->colorize("Repository:  ", 'LABEL') . $self->colorize($skill->{source_repo}, 'DATA');
    }
    if ($source) {
        push @lines, $self->colorize("Source:      ", 'LABEL') . $self->colorize($source, 'DATA');
    }
    if ($skill->{readonly}) {
        push @lines, $self->colorize("Read-only:   ", 'LABEL') . $self->colorize('yes (edit source file or .md to change)', 'DIM');
    }

    if ($skill->{variables} && @{$skill->{variables}}) {
        push @lines, $self->colorize("Variables:   ", 'LABEL') . $self->colorize(join(", ", @{$skill->{variables}}), 'DATA');
    }

    if ($skill->{created}) {
        push @lines, $self->colorize("Created:     ", 'LABEL') . $self->colorize(scalar(localtime($skill->{created})), 'DATA');
    }
    if ($skill->{modified}) {
        push @lines, $self->colorize("Modified:    ", 'LABEL') . $self->colorize(scalar(localtime($skill->{modified})), 'DATA');
    }
    push @lines, "";
    
    # Prompt section
    push @lines, $self->colorize("PROMPT TEMPLATE", 'SECTION_HEADER');
    push @lines, "";
    
    # Render through markdown pipeline for proper formatting
    my $rendered = $self->render_markdown($skill->{prompt});
    if (defined $rendered) {
        push @lines, split /\n/, $rendered;
    }
    
    push @lines, "";
    
    # Use Chat's display_paginated_content for consistent pagination
    $self->{chat}->display_paginated_content(
        "SKILL: " . uc($name),
        \@lines,
        undef  # No filepath for skills
    );
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
    
    # Display confirmation prompt using theme
    my $prompt = $self->{chat}{theme_mgr}->get_confirmation_prompt(
        "Delete skill '$name'?",
        "yes/no",
        "cancel"
    );
    
    print $prompt;
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

=head2 _handle_repo_command($sm, @args)

Handle /skills repo subcommands.

=cut

sub _handle_repo_command {
    my ($self, $sm, @args) = @_;
    
    my $subaction = shift @args || 'list';
    
    my $repo_mgr = $sm->get_repo_manager();
    unless ($repo_mgr) {
        $self->display_error_message("Skill repositories not available");
        return;
    }
    
    if ($subaction eq 'add') {
        $self->_repo_add($sm, $repo_mgr, @args);
    }
    elsif ($subaction eq 'remove' || $subaction eq 'rm') {
        $self->_repo_remove($repo_mgr, @args);
    }
    elsif ($subaction eq 'list' || $subaction eq 'ls') {
        $self->_repo_list($repo_mgr);
    }
    elsif ($subaction eq 'sync') {
        $self->_repo_sync($sm, $repo_mgr, @args);
    }
    elsif ($subaction eq 'enable') {
        $self->_repo_enable($repo_mgr, @args);
    }
    elsif ($subaction eq 'disable') {
        $self->_repo_disable($repo_mgr, @args);
    }
    else {
        $self->display_error_message("Unknown repo action: $subaction");
        $self->writeline("Use: /skills repo add|remove|list|sync|enable|disable", markdown => 0);
    }
    
    return;
}

=head2 _repo_add($sm, $repo_mgr, @args)

Add a skill repository.

=cut

sub _repo_add {
    my ($self, $sm, $repo_mgr, @args) = @_;
    
    my $name = shift @args;
    my $url = shift @args;
    
    unless ($name && $url) {
        $self->display_error_message("Usage: /skills repo add <name> <url>");
        $self->writeline("", markdown => 0);
        $self->writeline("  name: Short identifier (alphanumeric, hyphens)", markdown => 0);
        $self->writeline("  url:  Git repository URL", markdown => 0);
        $self->writeline("", markdown => 0);
        $self->writeline("Example:", markdown => 0);
        $self->writeline("  /skills repo add awesome https://github.com/ComposioHQ/awesome-claude-skills", markdown => 0);
        return;
    }
    
    # Parse optional flags
    my %opts;
    while (@args) {
        my $arg = shift @args;
        if ($arg eq '--branch' && @args) {
            $opts{branch} = shift @args;
        }
        elsif ($arg eq '--subpath' && @args) {
            $opts{subpath} = shift @args;
        }
    }
    
    $self->display_command_header("ADDING REPOSITORY");
    $self->writeline("Name:   $name", markdown => 0);
    $self->writeline("URL:    $url", markdown => 0);
    $self->writeline("Branch: " . ($opts{branch} || 'main'), markdown => 0);
    $self->writeline("", markdown => 0);
    
    my $result = $repo_mgr->add_repo($name, $url, %opts);
    
    if ($result->{success}) {
        $self->display_success_message("Repository '$name' added");
        $self->writeline("", markdown => 0);
        $self->writeline("Syncing repository...", markdown => 0);
        
        my $sync_result = $repo_mgr->sync_repo($name);
        if ($sync_result->{success}) {
            $self->display_success_message("Synced '$name': $sync_result->{skill_count} skills found");
            
            # Reload repository skills into SkillManager
            $sm->reload_repository_skills();
        } else {
            $self->display_error_message("Sync failed: $sync_result->{error}");
        }
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _repo_remove($repo_mgr, @args)

Remove a skill repository.

=cut

sub _repo_remove {
    my ($self, $repo_mgr, @args) = @_;
    
    my $name = shift @args;
    
    unless ($name) {
        $self->display_error_message("Usage: /skills repo remove <name>");
        return;
    }
    
    my $repo = $repo_mgr->get_repo($name);
    unless ($repo) {
        $self->display_error_message("Repository '$name' not found");
        return;
    }
    
    # Confirm removal
    my $prompt = $self->{chat}{theme_mgr}->get_confirmation_prompt(
        "Remove repository '$name' and its cached skills?",
        "yes/no",
        "cancel"
    );
    
    print $prompt;
    my $confirm = <STDIN>;
    chomp $confirm if defined $confirm;
    
    unless ($confirm && $confirm =~ /^y(es)?$/i) {
        $self->display_system_message("Removal cancelled");
        return;
    }
    
    my $result = $repo_mgr->remove_repo($name);
    
    if ($result->{success}) {
        $self->display_success_message("Removed repository '$name'");
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _repo_list($repo_mgr)

List configured skill repositories.

=cut

sub _repo_list {
    my ($self, $repo_mgr) = @_;
    
    my $repos = $repo_mgr->list_repos();
    
    $self->display_command_header("SKILL REPOSITORIES");
    
    unless (@$repos) {
        $self->writeline("  No repositories configured.", markdown => 0);
        $self->writeline("", markdown => 0);
        $self->writeline("  Add one with: /skills repo add <name> <url>", markdown => 0);
        $self->writeline("", markdown => 0);
        return;
    }
    
    for my $repo (@$repos) {
        my $status = $repo->{enabled} ? 
            $self->colorize("enabled", 'SUCCESS') : 
            $self->colorize("disabled", 'WARNING');
        my $sync_status = $repo->{last_sync} ? 
            scalar(localtime($repo->{last_sync})) : 
            $self->colorize("never synced", 'DIM');
        
        $self->display_key_value("Name", $repo->{name}, 12);
        $self->display_key_value("URL", $repo->{url}, 12);
        $self->display_key_value("Branch", $repo->{branch} || 'main', 12);
        $self->display_key_value("Status", $status, 12);
        $self->display_key_value("Skills", $repo->{skill_count} || 0, 12);
        $self->display_key_value("Last Sync", $sync_status, 12);
        $self->writeline("", markdown => 0);
    }
    
    my $total_skills = 0;
    my $enabled = 0;
    for my $repo (@$repos) {
        $total_skills += $repo->{skill_count} || 0;
        $enabled++ if $repo->{enabled};
    }
    
    my $summary = $self->colorize("Total: ", 'LABEL') .
                  $self->colorize(scalar(@$repos), 'DATA') . " repos, " .
                  $self->colorize($enabled, 'DATA') . " enabled, " .
                  $self->colorize($total_skills, 'DATA') . " skills";
    $self->writeline($summary, markdown => 0);
}

=head2 _repo_sync($sm, $repo_mgr, @args)

Sync skill repositories.

=cut

sub _repo_sync {
    my ($self, $sm, $repo_mgr, @args) = @_;
    
    my $name = shift @args;
    
    if ($name) {
        # Sync specific repository
        $self->display_command_header("SYNCING REPOSITORY");
        $self->writeline("Syncing '$name'...", markdown => 0);
        
        my $result = $repo_mgr->sync_repo($name);
        
        if ($result->{success}) {
            my $status = $result->{updated} ? "updated" : "no changes";
            $self->display_success_message("'$name': $status, $result->{skill_count} skills");
            
            # Reload repository skills
            $sm->reload_repository_skills();
        } else {
            $self->display_error_message($result->{error});
        }
    }
    else {
        # Sync all enabled repositories
        $self->display_command_header("SYNCING ALL REPOSITORIES");
        
        my $results = $repo_mgr->sync_all();
        
        unless (@$results) {
            $self->writeline("  No enabled repositories to sync.", markdown => 0);
            return;
        }
        
        my $total_skills = 0;
        for my $entry (@$results) {
            my $r = $entry->{result};
            if ($r->{success}) {
                my $status = $r->{updated} ? "updated" : "no changes";
                $self->display_key_value($entry->{name}, "$status, $r->{skill_count} skills", 16);
                $total_skills += $r->{skill_count};
            } else {
                $self->display_key_value($entry->{name}, $self->colorize("failed: $r->{error}", 'ERROR'), 16);
            }
        }
        
        $self->writeline("", markdown => 0);
        $self->writeline($self->colorize("Total: ", 'LABEL') . 
            $self->colorize($total_skills, 'DATA') . " skills across all repos", markdown => 0);
        
        # Reload repository skills
        $sm->reload_repository_skills();
    }
}

=head2 _repo_enable($repo_mgr, @args)

Enable a disabled repository.

=cut

sub _repo_enable {
    my ($self, $repo_mgr, @args) = @_;
    
    my $name = shift @args;
    
    unless ($name) {
        $self->display_error_message("Usage: /skills repo enable <name>");
        return;
    }
    
    my $result = $repo_mgr->enable_repo($name);
    
    if ($result->{success}) {
        $self->display_success_message("Repository '$name' enabled");
    } else {
        $self->display_error_message($result->{error});
    }
}

=head2 _repo_disable($repo_mgr, @args)

Disable a repository.

=cut

sub _repo_disable {
    my ($self, $repo_mgr, @args) = @_;
    
    my $name = shift @args;
    
    unless ($name) {
        $self->display_error_message("Usage: /skills repo disable <name>");
        return;
    }
    
    my $result = $repo_mgr->disable_repo($name);
    
    if ($result->{success}) {
        $self->display_success_message("Repository '$name' disabled");
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
    
    my $skills = safe_decode_json($resp->decoded_content);
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

    # Parse scope flags first so the help and confirmation copy can
    # mention where the skill is about to land.
    my ($cleaned, $opts, $bad_scope) = $self->_parse_scope_flags(@args);
    if ($bad_scope) {
        $self->display_error_message("Invalid $bad_scope (use --global, --project, --session, or --scope=user|project|session)");
        return;
    }
    @args = @$cleaned;

    my $name = shift @args;

    unless ($name) {
        $self->display_error_message("Usage: /skills install <name> [--global|--project|--session]");
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
    $self->display_key_value("Target scope", $opts->{scope} // 'project (default)', 15);
    my @lines = split /\n/, $content;
    $self->display_key_value("Lines", scalar(@lines), 15);
    
    # Ask if user wants to preview full content
    print "\n";
    
    my $prompt1 = $self->{chat}{theme_mgr}->get_confirmation_prompt(
        "View full content?",
        "yes/no",
        "skip"
    );
    
    print $prompt1;
    my $view_full = <STDIN>;
    chomp $view_full if defined $view_full;
    
    if ($view_full && $view_full =~ /^y(es)?$/i) {
        # Display full content with markdown rendering and pagination
        $self->writeline("", markdown => 0);
        $self->display_section_header("FULL CONTENT");
        $self->writeline("", markdown => 0);
        
        # Enable pagination for full content
        $self->{chat}->{pager}->enable();
        
        # Render the content as markdown (writeline with markdown => 1)
        last unless $self->writeline($content, markdown => 1);
        
        # Disable pagination
        $self->{chat}->{pager}->disable();
        $self->writeline("", markdown => 0);
    }
    
    # Confirm installation
    my $prompt2 = $self->{chat}{theme_mgr}->get_confirmation_prompt(
        "Install '$name'?",
        "yes/no",
        "cancel"
    );
    
    print $prompt2;
    my $confirm = <STDIN>;
    chomp $confirm if defined $confirm;
    
    unless ($confirm && $confirm =~ /^y(es)?$/i) {
        $self->display_system_message("Installation cancelled");
        return;
    }
    
    # Install by adding to custom skills. Default scope is 'project' for
    # installs because the typical use case is "add a skill to this
    # project". --global overrides to user-level.
    my $result = $sm->add_skill($name, $content, description => $description, %$opts);

    if ($result->{success}) {
        my $scope = $result->{prompt}{scope} // 'user';
        $self->display_success_message("Skill '$name' installed to $scope scope");
        if ($result->{prompt}{source}) {
            $self->writeline("  File: $result->{prompt}{source}", markdown => 0);
        }
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
1;
