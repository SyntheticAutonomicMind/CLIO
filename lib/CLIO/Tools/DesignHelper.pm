package CLIO::Tools::DesignHelper;

use strict;
use warnings;
use utf8;
use File::Spec;
use File::Path qw(make_path);
use File::Basename qw(dirname);

binmode(STDOUT, ':encoding(UTF-8)');
binmode(STDERR, ':encoding(UTF-8)');

=head1 NAME

CLIO::Tools::DesignHelper - Product Requirements Document (PRD) management

=head1 DESCRIPTION

DesignHelper provides utilities for creating, loading, and managing Product
Requirements Documents (PRDs) in CLIO projects. PRDs are stored at `.clio/PRD.md`
and provide structured project documentation.

=head1 SYNOPSIS

    use CLIO::Tools::DesignHelper;
    
    my $helper = CLIO::Tools::DesignHelper->new();
    
    # Create new PRD
    my $prd = $helper->create_blank_prd(
        project_name => 'MyApp',
        purpose => 'A sample application'
    );
    
    # Save PRD
    $helper->save_prd($prd, '.clio/PRD.md');
    
    # Load existing PRD
    my $content = $helper->load_prd('.clio/PRD.md');
    
    # Check if PRD exists
    if ($helper->prd_exists('.clio/PRD.md')) {
        print "PRD found\n";
    }

=head1 METHODS

=head2 new

Constructor. Creates a new DesignHelper instance.

    my $helper = CLIO::Tools::DesignHelper->new();

=cut

sub new {
    my ($class, %opts) = @_;
    my $self = bless {
        %opts
    }, $class;
    return $self;
}

=head2 create_blank_prd

Generate a blank PRD structure with optional pre-filled values.

    my $prd = $helper->create_blank_prd(
        project_name => 'MyApp',
        purpose => 'Application purpose',
        version => '0.1.0',
        tech_stack => {
            language => 'Perl',
            framework => 'Mojolicious'
        }
    );

Returns a string containing the complete PRD markdown.

=cut

sub create_blank_prd {
    my ($self, %params) = @_;
    
    my $project_name = $params{project_name} || '[Project Name]';
    my $version = $params{version} || '0.1.0';
    my $purpose = $params{purpose} || '[What problem does this solve?]';
    my $date = $params{date} || _get_current_date();
    
    # Build tech stack section
    my $tech_stack = '';
    if ($params{tech_stack} && ref($params{tech_stack}) eq 'HASH') {
        my $ts = $params{tech_stack};
        $tech_stack = "- **Language:** " . ($ts->{language} || '[language + version]') . "\n";
        $tech_stack .= "- **Framework:** " . ($ts->{framework} || '[framework]') . "\n" if $ts->{framework};
        $tech_stack .= "- **Database:** " . ($ts->{database} || '[database]') . "\n" if $ts->{database};
        $tech_stack .= "- **Deployment:** " . ($ts->{deployment} || '[platform]') . "\n" if $ts->{deployment};
        $tech_stack .= "- **CI/CD:** " . ($ts->{cicd} || '[tools]') . "\n" if $ts->{cicd};
    } else {
        $tech_stack = <<'TECH';
- **Language:** [language + version]
- **Framework:** [framework]
- **Database:** [database]
- **Deployment:** [platform]
- **CI/CD:** [tools]
TECH
    }
    
    my $prd = <<PRD;
# Product Requirements Document

**Project Name:** $project_name  
**Version:** $version  
**Last Updated:** $date  
**Status:** Draft

## 1. Project Overview

### 1.1 Purpose
$purpose

### 1.2 Goals
- [Primary goal]
- [Secondary goal]

### 1.3 Non-Goals
- [What this project will NOT do]

## 2. User Stories & Use Cases

### 2.1 Primary Users
- [User type 1]: [description]
- [User type 2]: [description]

### 2.2 Key User Stories
- As a [user], I want [feature] so that [benefit]
- As a [user], I want [feature] so that [benefit]

### 2.3 Use Cases
1. **[Use Case Name]**
   - Actor: [who]
   - Precondition: [state]
   - Flow: [steps]
   - Postcondition: [result]

## 3. Features & Requirements

### 3.1 Must-Have (MVP)
- [ ] [Feature 1]: [description]
- [ ] [Feature 2]: [description]

### 3.2 Should-Have (Phase 2)
- [ ] [Feature 3]: [description]

### 3.3 Nice-to-Have (Future)
- [ ] [Feature 4]: [description]

## 4. Technical Architecture

### 4.1 Technology Stack
$tech_stack

### 4.2 System Architecture
[High-level architecture description or ASCII diagram]

### 4.3 Key Components
- **Component 1:** [purpose and responsibilities]
- **Component 2:** [purpose and responsibilities]

### 4.4 Data Model
[Key entities and relationships]

### 4.5 APIs & Integrations
- [External API 1]: [purpose]
- [External API 2]: [purpose]

## 5. Design & UX

### 5.1 Design Principles
- [Principle 1]
- [Principle 2]

### 5.2 User Interface
[Key screens or pages]

### 5.3 Accessibility
[A11y requirements]

## 6. Security & Privacy

### 6.1 Security Requirements
- [Authentication method]
- [Authorization approach]
- [Data encryption]

### 6.2 Privacy Considerations
- [Data handling]
- [Compliance requirements]

## 7. Performance & Scale

### 7.1 Performance Targets
- [Metric 1]: [target]
- [Metric 2]: [target]

### 7.2 Scalability Requirements
[Expected load and growth]

## 8. Testing Strategy

### 8.1 Test Coverage
- Unit tests: [target %]
- Integration tests: [scope]
- E2E tests: [key flows]

### 8.2 Quality Metrics
- [Metric 1]: [target]

## 9. Deployment & Operations

### 9.1 Deployment Process
[How releases happen]

### 9.2 Monitoring
- [What to monitor]
- [Alerting strategy]

### 9.3 Rollback Plan
[How to revert if needed]

## 10. Timeline & Milestones

### 10.1 Development Phases
- **Phase 1 (MVP):** [timeframe] - [scope]
- **Phase 2:** [timeframe] - [scope]

### 10.2 Key Milestones
- [Date]: [milestone]
- [Date]: [milestone]

## 11. Dependencies & Risks

### 11.1 External Dependencies
- [Dependency 1]: [description + risk]

### 11.2 Known Risks
- **Risk:** [description]
  - **Likelihood:** High/Medium/Low
  - **Impact:** High/Medium/Low
  - **Mitigation:** [strategy]

## 12. Success Metrics

### 12.1 Launch Criteria
- [ ] [Criterion 1]
- [ ] [Criterion 2]

### 12.2 Post-Launch Metrics
- [Metric to track]
- [Metric to track]

## Appendices

### A. Glossary
- **Term:** Definition

### B. References
- [Link to relevant docs]

### C. Change Log
- $date: Initial PRD created
PRD
    
    return $prd;
}

=head2 save_prd

Save PRD content to a file.

    $helper->save_prd($content, '.clio/PRD.md');

Creates parent directories if they don't exist.

=cut

sub save_prd {
    my ($self, $content, $path) = @_;
    
    unless (defined $content && length($content) > 0) {
        die "Cannot save empty PRD content\n";
    }
    
    unless (defined $path && length($path) > 0) {
        die "PRD path required\n";
    }
    
    # Create parent directory if it doesn't exist
    my $dir = dirname($path);
    if (!-d $dir) {
        make_path($dir) or die "Failed to create directory $dir: $!\n";
    }
    
    # Write file
    open(my $fh, '>:encoding(UTF-8)', $path) 
        or die "Failed to open $path for writing: $!\n";
    print $fh $content;
    close($fh) or die "Failed to close $path: $!\n";
    
    return 1;
}

=head2 load_prd

Load PRD content from a file.

    my $content = $helper->load_prd('.clio/PRD.md');

Returns the PRD content as a string, or undef if file doesn't exist.

=cut

sub load_prd {
    my ($self, $path) = @_;
    
    unless (defined $path && length($path) > 0) {
        die "PRD path required\n";
    }
    
    return undef unless -f $path;
    
    open(my $fh, '<:encoding(UTF-8)', $path)
        or die "Failed to open $path for reading: $!\n";
    my $content = do { local $/; <$fh> };
    close($fh);
    
    return $content;
}

=head2 prd_exists

Check if a PRD file exists at the given path.

    if ($helper->prd_exists('.clio/PRD.md')) {
        # PRD exists
    }

Returns 1 if file exists, 0 otherwise.

=cut

sub prd_exists {
    my ($self, $path) = @_;
    
    $path ||= '.clio/PRD.md';
    
    return -f $path ? 1 : 0;
}

=head2 _get_current_date

Internal helper to get current date in YYYY-MM-DD format.

=cut

sub _get_current_date {
    my @time = localtime();
    return sprintf("%04d-%02d-%02d", 
        $time[5] + 1900, 
        $time[4] + 1, 
        $time[3]
    );
}

=head1 AUTHOR

CLIO Development Team

=head1 COPYRIGHT

Copyright 2026 CLIO Project

=cut

1;
