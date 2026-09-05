# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Tools::SkillOperations;

use strict;
use warnings;
use utf8;
binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');
use parent 'CLIO::Tools::Tool';
use CLIO::Core::Logger qw(log_debug log_warning);
use File::Spec;
use Carp qw(croak);

=head1 NAME

CLIO::Tools::SkillOperations - Auto-discover and load installed skills

=head1 DESCRIPTION

Lets the agent see what skills are installed in the user's environment
and load any of them on demand. Catalog injection into the system prompt
is handled by CLIO::Core::PromptBuilder; this tool does the loading.

Two operations:

=over 4

=item list - Return the skill catalog (name, description, type, variables)

=item load - Return the full content of a single skill. The agent uses
this to fetch the prompt template and substitute its variables.

=back

This tool is gated on the C<auto_discover_skills> config flag. When the
flag is off, the tool is not registered and the catalog is not injected
into the system prompt.

=head1 SYNOPSIS

    use CLIO::Tools::SkillOperations;

    my $tool = CLIO::Tools::SkillOperations->new(debug => 0);
    my $result = $tool->execute({
        operation => 'load',
        name => 'code-review',
    });

=cut

sub new {
    my ($class, %opts) = @_;

    return $class->SUPER::new(
        name => 'skill_operations',
        description => q{Skill auto-discovery and loading.

INSTALLED SKILLS appear in the system prompt as a catalog. When you identify
a skill that matches the user's request, call this tool to load its full
content, then use the result on your next turn.

OPERATIONS:
- list: Return the catalog of installed skills (name, description, type, variables).
  Use this when you need to re-check what is available.
- load: Return the full prompt template for a single skill. The result
  includes the variables the skill expects so you know what context to substitute.
- create: Write a new freeform skill to .clio/skills/<name>.md. Use this
  to capture a reusable workflow as a skill that future sessions can load.
  The content must include YAML frontmatter (name, description) followed
  by a markdown body with action steps and constraints.

The catalog is also visible in the system prompt - prefer reading it from
there. Use this tool only when you need the full content of a specific skill
or want a fresh catalog listing.

Examples:
{"operation": "list"}
{"operation": "load", "name": "code-review"}
{"operation": "create", "name": "deploy-checklist", "description": "Use this skill when deploying to production", "content": "---\nname: deploy-checklist\ndescription: Use this skill when deploying to production\n---\n# Deploy Checklist\n\n1. Run tests\n2. Tag release\n3. Push to registry\n\n* Do not skip the test step"}

Skills are installed by the user via /skills add or by configuring a skill
repository. The create operation writes freeform skills that follow the
same SKILL.md format the user would write by hand.
},
        supported_operations => [qw(list load create)],
        %opts,
    );
}

=head2 dispatch_table

Map operations to methods.

=cut

sub dispatch_table {
    return {
        list => 'op_list',
        load => 'op_load',
        create => 'op_create',
    };
}

=head2 get_additional_parameters

Add parameters for load (name) and create (name, description, content, scope).

=cut

sub get_additional_parameters {
    my ($self) = @_;
    return {
        name => {
            type => 'string',
            description => '[REQUIRED for load and create] Skill name. For load: exact name from the catalog. For create: kebab-case slug for the new skill file (call operation=list first to see available names and avoid collisions).',
        },
        description => {
            type => 'string',
            description => '[REQUIRED for create] Short description for the skill (for catalog display). Start with "Use this skill when..." to match the discovery heuristic.',
        },
        content => {
            type => 'string',
            description => '[REQUIRED for create] Full SKILL.md body: YAML frontmatter (name, description) followed by markdown body with action steps and constraints.',
        },
        scope => {
            type => 'string',
            description => '[OPTIONAL for create] Scope: "project" (default, writes to .clio/skills/<name>.md) or "user" (writes to ~/.clio/skills/<name>.md).',
        },
    };
}

=head2 op_list

Return the catalog of installed skills.

=cut

sub op_list {
    my ($self, $params, $context) = @_;

    my $sm = $self->_get_skill_manager();
    unless ($sm) {
        return $self->error_result('SkillManager unavailable');
    }

    my $catalog = $sm->list_skill_catalog();
    my $count = scalar @$catalog;

    log_debug('SkillOperations', "Listed $count skills");

    return $self->success_result(
        $catalog,
        action_description => "listing $count installed skill" . ($count == 1 ? '' : 's'),
    );
}

=head2 op_load

Return the full content of a single skill.

=cut

sub op_load {
    my ($self, $params, $context) = @_;

    my $name = $params->{name} || '';
    unless ($name) {
        return $self->operation_error("'name' parameter is required for load operation");
    }

    if ($name !~ /^[a-zA-Z0-9_.\/-]+$/) {
        return $self->error_result("Invalid skill name: $name");
    }

    my $sm = $self->_get_skill_manager();
    unless ($sm) {
        return $self->error_result('SkillManager unavailable');
    }

    my $skill = $sm->get_skill_full($name);
    unless ($skill) {
        return $self->error_result("Skill '$name' not found. Use operation: list to see available skills.");
    }

    log_debug('SkillOperations', "Loaded skill '$name' (" . length($skill->{prompt}) . " bytes)");

    return $self->success_result(
        $skill,
        action_description => "loading skill '$name'",
    );
}

=head2 op_create

Create a new freeform skill file. The content is a full SKILL.md body
(YAML frontmatter + markdown body) that the user could have written
by hand - the tool writes the file exactly as provided.

The agent uses this after completing substantial work to capture a
reusable workflow as a skill that future sessions can load.

=cut

sub op_create {
    my ($self, $params, $context) = @_;

    my $name = $params->{name} || '';
    my $description = $params->{description} || '';
    my $content = $params->{content} || '';
    my $scope = $params->{scope} || 'project';

    unless ($name) {
        return $self->operation_error("'name' parameter is required for create operation");
    }
    unless ($description) {
        return $self->operation_error("'description' parameter is required for create operation");
    }
    unless (length $content) {
        return $self->operation_error("'content' parameter is required for create operation");
    }
    unless ($scope eq 'project' || $scope eq 'user') {
        return $self->operation_error("Invalid scope '$scope' (use 'project' or 'user')");
    }

    my $sm = $self->_get_skill_manager();
    unless ($sm) {
        return $self->error_result('SkillManager unavailable');
    }

    my $result = $sm->add_freeform_skill($name, $description, $content, scope => $scope);
    unless ($result->{success}) {
        return $self->error_result($result->{error});
    }

    log_debug('SkillOperations', "Created freeform skill '$name' at $result->{path}");

    return $self->success_result(
        {
            name => $name,
            path => $result->{path},
            scope => $scope,
            skill => $result->{skill},
        },
        action_description => "creating skill '$name'",
    );
}

=head2 _get_skill_manager

Construct a SkillManager. The session_skills_file (if any) is sourced from
context.session so session-level skills show up in the catalog and load results.

=cut

sub _get_skill_manager {
    my ($self) = @_;

    require CLIO::Core::SkillManager;

    my $session_file = undef;
    if ($ENV{CLIO_SESSION_DIR} && $ENV{CLIO_SESSION_ID}) {
        $session_file = File::Spec->catfile(
            $ENV{CLIO_SESSION_DIR},
            $ENV{CLIO_SESSION_ID},
            'skills.json',
        );
    }

    return CLIO::Core::SkillManager->new(
        debug => $self->{debug},
        session_skills_file => $session_file,
    );
}

1;

__END__

=head1 AUTHOR

Fewtarius

=head1 LICENSE

Copyright (c) 2026 CLIO Project

=cut

1;
