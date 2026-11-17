#!/usr/bin/env perl
# SPDX-License-Identifier: GPL-3.0-only
# SPDX-FileCopyrightText: Copyright (c) 2026 Andrew Wyatt (Fewtarius)

=head1 NAME

test_consent_vocabulary.pl - every approval prompt asks the same question

=head1 DESCRIPTION

CLIO has five approval prompts (command, web fetch, script creation, file
overwrite, path access) and a sixth on the broker side for sub-agents. They
each used to carry their own options string and their own answer regexes, and
they drifted: path access still asked for C<(s)ession> after everything else
moved to C<(a)ll>, and only some sites accepted C<y>.

These tests pin one vocabulary across the whole surface, plus a source scan so
a new prompt cannot quietly reintroduce a fourth spelling.

=cut

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::RealBin/../../lib";

use Test::More;

use CLIO::Security::Consent;
use CLIO::Security::PathAuthorizer;
use CLIO::Tools::TerminalOperations;

# ---------------------------------------------------------------------------
subtest 'options text' => sub {
    is(CLIO::Security::Consent::options_text(allow_label => 'category'),
        '(o)nce | (a)llow category | (n)o deny',
        'single category');

    is(CLIO::Security::Consent::options_text(allow_label => 'these 3 categories'),
        '(o)nce | (a)llow these 3 categories | (n)o deny',
        'category count is carried through');

    is(CLIO::Security::Consent::options_text(allow_label => 'this directory'),
        '(o)nce | (a)llow this directory | (n)o deny',
        'path approval uses the same shape');

    is(CLIO::Security::Consent::options_text(grantable => 0),
        '(o)nce | (n)o deny',
        'an ungrantable concern offers no (a)');

    is(CLIO::Security::Consent::options_text(allow_label => 'x', grantable => 0),
        '(o)nce | (n)o deny',
        'grantable wins over a supplied label');
};

# ---------------------------------------------------------------------------
subtest 'answers' => sub {
    for my $answer (qw(o once O ONCE)) {
        is(CLIO::Security::Consent::parse_answer($answer), 'once',
            "'$answer' approves one request");
    }
    for my $answer (qw(a all allow A ALL)) {
        is(CLIO::Security::Consent::parse_answer($answer), 'all',
            "'$answer' approves the category");
    }
    for my $answer (qw(n no deny N NO)) {
        is(CLIO::Security::Consent::parse_answer($answer), 'deny',
            "'$answer' denies");
    }

    is(CLIO::Security::Consent::parse_answer('  a  '), 'all',
        'surrounding whitespace is ignored');
    is(CLIO::Security::Consent::parse_answer(''), 'deny', 'empty denies');
    is(CLIO::Security::Consent::parse_answer(undef), 'deny', 'undef denies');
    is(CLIO::Security::Consent::parse_answer('maybe'), 'deny',
        'an unrecognised answer denies rather than approves');
    is(CLIO::Security::Consent::parse_answer('yes please'), 'deny',
        'only the listed words are answers');
};

# ---------------------------------------------------------------------------
subtest 'legacy keys still work' => sub {
    is(CLIO::Security::Consent::parse_answer('y'), 'once', 'y maps to once');
    is(CLIO::Security::Consent::parse_answer('yes'), 'once', 'yes maps to once');
    is(CLIO::Security::Consent::parse_answer('s'), 'all', 's maps to all');
    is(CLIO::Security::Consent::parse_answer('session'), 'all', 'session maps to all');
};

# ---------------------------------------------------------------------------
subtest 'ungrantable concerns can only be approved once' => sub {
    is(CLIO::Security::Consent::parse_answer('a', grantable => 0), 'once',
        'a on an ungrantable concern approves just this request');
    is(CLIO::Security::Consent::parse_answer('s', grantable => 0), 'once',
        'legacy s on an ungrantable concern approves just this request');
    is(CLIO::Security::Consent::parse_answer('n', grantable => 0), 'deny',
        'deny still denies');
};

# ---------------------------------------------------------------------------
subtest 'grant type spelling' => sub {
    is(CLIO::Security::Consent::grant_type_for('once'), 'once', 'once');
    is(CLIO::Security::Consent::grant_type_for('all'), 'all', 'all');
    is(CLIO::Security::Consent::grant_type_for('deny'), 'denied', 'deny -> denied');
    is(CLIO::Security::Consent::grant_type_for(undef), 'denied', 'undef -> denied');
};

# ---------------------------------------------------------------------------
subtest 'the command prompt uses the shared vocabulary' => sub {
    my $term = CLIO::Tools::TerminalOperations->new();

    is($term->_consent_options_text(1),
        '(o)nce | (a)llow category | (n)o deny',
        'one category');
    is($term->_consent_options_text(2),
        '(o)nce | (a)llow these 2 categories | (n)o deny',
        'two categories');
};

# ---------------------------------------------------------------------------
# A source scan is the only way to catch a prompt that is written inline. Any
# new prompt must build its options line from Consent, and no module may offer
# (s)ession as an answer.
subtest 'no prompt re-spells the vocabulary' => sub {
    my $lib = "$FindBin::RealBin/../../lib";
    my @files;

    for my $dir ("$lib/CLIO/Tools", "$lib/CLIO/Security", "$lib/CLIO/UI/Chat") {
        opendir my $dh, $dir or die "Cannot read $dir: $!";
        push @files, map { "$dir/$_" } grep { /\.pm$/ } readdir $dh;
        closedir $dh;
    }

    my @offenders;
    for my $file (@files) {
        # Consent.pm is the one place allowed to spell the vocabulary.
        next if $file =~ m{/Consent\.pm$};
        open my $fh, '<:encoding(UTF-8)', $file or die "Cannot read $file: $!";
        my @lines = <$fh>;
        close $fh;
        my $line_no = 0;
        for my $line (@lines) {
            $line_no++;
            # Options strings are the thing that must go through Consent.
            push @offenders, "$file:$line_no offers (s)ession"
                if $line =~ /\(s\)ession/;
            push @offenders, "$file:$line_no hardcodes an options line"
                if $line =~ /['"]\(o\)nce\s*\|/
                && $line !~ /CLIO::Security::Consent::options_text/;
        }
    }

    is_deeply(\@offenders, [], 'every approval prompt uses Consent::options_text')
        or diag(join("\n", @offenders));
};

done_testing();
