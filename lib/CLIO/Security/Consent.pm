# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

package CLIO::Security::Consent;

use strict;
use warnings;
use utf8;

use CLIO::Core::Logger qw(log_debug);

=head1 NAME

CLIO::Security::Consent - one approval vocabulary for every security prompt

=head1 SYNOPSIS

    use CLIO::Security::Consent;

    my $options = CLIO::Security::Consent::options_text(
        allow_label => 'this path',
    );
    # (o)nce | (a)llow this path | (n)o deny

    my $answer = CLIO::Security::Consent::parse_answer($raw, caller => 'FileOp');
    # 'once' | 'all' | 'deny'

    my $decision = CLIO::Security::Consent::read_answer(
        caller  => 'FileOp',
        prompt  => sub { print "\n* Security | $path\n  $options: " },
        spinner => $spinner,
    );
    # prints the prompt, reads one line, returns 'once' | 'all' | 'deny'

=head1 DESCRIPTION

Every approval prompt in CLIO asks the same question, so every prompt must
offer the same three answers:

  o  approve this one request
  a  approve this category, keeping the approval in the grant store
  n  deny

Before this module each call site carried its own options string and its own
regexes, and they drifted: path approval still asked for C<(s)ession> while
command approval had moved to C<(a)ll>, and some sites accepted C<y> as an
alias for approval while others did not. One vocabulary, one parser, one place
to change it.

C<read_answer> is the other half: one implementation of the terminal dance
every prompt needs - stop the spinner, suppress the alarm timer that would eat
the keystroke, switch to cooked mode, print, flush, drain, read, restore. Each
call site prints its own prompt through the C<prompt> callback, because only
the tool knows what to show; the sequencing and the answer classification are
shared.

An answer of C<a> means "approve the category". What the category is - a
command flag set, file overwrites, script creation, external fetches, or a
single path for one conversation - belongs to the caller, because only the
caller knows what it is granting.

=cut

our $VERSION = '1.0';

# Answers accepted for each decision. The first form in each list is the one
# printed in the prompt; the rest exist so long-standing muscle memory (y/s)
# does not turn into a silent denial.
our %ACCEPTED = (
    once => [qw(o once y yes)],
    all  => [qw(a all allow s session)],
    deny => [qw(n no deny)],
);

=head2 options_text(%args)

Build the options line for a prompt.

Arguments:
- allow_label: what C<(a)> grants, e.g. 'category', 'this path',
  'file overwrites'. Required when C<grantable> is true.
- grantable: false when the concern cannot be granted for the session
  (internal address fetch, exfiltration-shaped request). Defaults to true.

Returns: the options string, without a trailing colon or newline.

=cut

sub options_text {
    my (%args) = @_;

    my $grantable = exists $args{grantable} ? $args{grantable} : 1;
    return '(o)nce | (n)o deny' unless $grantable;

    my $label = $args{allow_label};
    $label = 'category' unless defined $label && length $label;

    return "(o)nce | (a)llow $label | (n)o deny";
}

=head2 parse_answer($response, %args)

Classify a raw answer.

Arguments:
- response: the string the user typed. Case and surrounding whitespace are
  ignored; an empty or undefined answer is a denial.
- grantable: when false, C<a> is treated as C<once>, because there is no
  category to grant. Defaults to true.
- caller: tag for the debug log. Defaults to 'Consent'.

Returns: 'once', 'all', or 'deny'.

=cut

sub parse_answer {
    my ($response, %args) = @_;

    my $grantable = exists $args{grantable} ? $args{grantable} : 1;
    my $caller    = $args{caller} || 'Consent';

    my $answer = defined $response ? $response : '';
    $answer =~ s/^\s+|\s+$//g;
    $answer = lc $answer;

    return 'deny' unless length $answer;

    for my $decision (qw(once all deny)) {
        next unless grep { $answer eq $_ } @{ $ACCEPTED{$decision} };
        next if $decision eq 'all' && !$grantable;

        # Legacy keys are accepted deliberately, but the debug trail should
        # show the usage so it can be steered back to the printed forms.
        if ($answer eq 'y' || $answer eq 'yes') {
            log_debug($caller, "Legacy key '$answer' used for once - accepted, maps to (o)nce");
        } elsif (($answer eq 's' || $answer eq 'session') && $grantable) {
            log_debug($caller, "Legacy key '$answer' used - accepted, maps to (a)ll");
        }

        return $decision;
    }

    if ($grantable == 0 && $answer =~ /^(?:a|all|allow|s|session)$/) {
        log_debug($caller, "Answer '$answer' on an ungrantable concern - treating as (o)nce");
        return 'once';
    }

    # Anything unrecognised is a denial: an approval needs to be deliberate.
    log_debug($caller, "Unrecognised answer '$answer' - denying");
    return 'deny';
}

=head2 grant_type_for($decision)

Map a decision onto the grant type used on the broker wire format.

The relay protocol carries C<'once'>, C<'all'>, or C<'denied'>. This exists so
producers and consumers cannot disagree about the spelling.

=cut

sub grant_type_for {
    my ($decision) = @_;

    return 'once' if defined $decision && $decision eq 'once';
    return 'all'  if defined $decision && $decision eq 'all';
    return 'denied';
}

=head2 read_answer(%args)

Run one approval prompt: suspend the spinner's alarm, take the terminal out of
cbreak mode, print the prompt, read a line, put everything back, and classify
the answer.

Arguments:
- prompt: coderef that prints the prompt. Called after the terminal is in
  cooked mode and after buffered input is drained, before anything is read.
  Omit it when the caller has already printed the prompt itself.
- spinner: the active spinner, if any. Stopped for the prompt and restarted
  after it. Optional.
- grantable: passed to C<parse_answer>. Defaults to true.
- caller: debug tag. Defaults to 'Consent'.
- drain: drop keystrokes buffered by the spinner before reading. Defaults to
  true.
- flush: flush STDOUT before reading so the prompt is on screen. Defaults to
  true.

Returns: 'once', 'all', or 'deny'.

=head3 Why this is not duplicated per tool

Each call site needs the same five steps in the same order, and they were
copied instead of shared. The copies drifted, in ways only visible at a
prompt: a drain loop that consumed two keystrokes per iteration and so could
swallow the answer, a site with no drain at all, a site that never flushed
STDOUT before blocking, and a site that restored the alarm handler before
restarting the spinner on some paths but not others.

The order below is the one that works, and the reason each step is where it is:

1. Stop the spinner. Left running it repaints over the prompt.
2. Suppress C<$SIG{ALRM}> and cancel the pending alarm. Chat.pm's one-second
   timer calls C<ReadKey(-1)>, which consumes keystrokes before C<< <STDIN> >>
   can read them. A swallowed answer is a silent denial.
3. Cooked mode, before printing. Cbreak leaves the prompt without echo and
   makes the answer arrive byte-by-byte.
4. Drain, *before* printing. The drain exists to discard keystrokes the spinner
   buffered while cbreak was active. It cannot tell those apart from an answer
   the user typed at the prompt, so it runs while the prompt is still
   invisible and there is nothing yet for the user to answer.
5. Print, then flush. A prompt that is buffered while the process blocks on
   input looks like a hang.
6. Read the line.
7. Restore terminal mode, the alarm handler, and then the spinner.

=cut

sub read_answer {
    my (%args) = @_;

    my $spinner   = $args{spinner};
    my $caller    = $args{caller} || 'Consent';
    my $prompt    = $args{prompt};
    my $grantable = exists $args{grantable} ? $args{grantable} : 1;
    my $drain     = exists $args{drain}     ? $args{drain}     : 1;
    my $flush     = exists $args{flush}     ? $args{flush}     : 1;

    require CLIO::Compat::Terminal;

    $spinner->stop() if $spinner && $spinner->can('stop');

    my $saved_alrm      = $SIG{ALRM};
    my $remaining_alarm = alarm(0);

    CLIO::Compat::Terminal::ReadMode(0);

    if ($drain) {
        while (defined eval { CLIO::Compat::Terminal::ReadKey(-1) }) { }
    }

    $prompt->() if $prompt;

    if ($flush) {
        my $old_fh = select(STDOUT);
        $| = 1;
        select($old_fh);
    }

    # A closed or redirected STDIN reads as undef, which parse_answer treats as
    # a denial. There is no path here that approves an unread answer.
    my $response = <STDIN>;
    chomp($response) if defined $response;

    CLIO::Compat::Terminal::ReadMode(1);
    $SIG{ALRM} = $saved_alrm || 'DEFAULT';
    alarm($remaining_alarm) if $remaining_alarm;

    $spinner->start() if $spinner && $spinner->can('start');

    return parse_answer($response, caller => $caller, grantable => $grantable);
}

=head1 SEE ALSO

L<CLIO::Security::GrantStore> stores the approvals this module classifies.

=cut

1;
