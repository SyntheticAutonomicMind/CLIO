#!/usr/bin/env perl

=head1 NAME

lint_size_regression.pl - Detect size-regressing changes in working tree

=head1 SYNOPSIS

    perl tools/lint_size_regression.pl [options]

    Options:
      --staged           Lint staged changes only (default: working tree vs HEAD)
      --base=REF         Compare against REF instead of HEAD
      --json             Emit JSON instead of human-readable output

=head1 DESCRIPTION

Lints the diff between HEAD and the working tree (or staged changes) for
patterns that historically caused the codebase to drift away from its
quality rubric:

- New C<.pm> file over 1000 lines (Architecture rubric)
- New C<sub> NAME> over 200 lines (Method Quality rubric)
- New bare C<die> outside C<eval>/C<or die>/C<$SIG> (Error Handling rubric)
- New C<use JSON::PP> without the empty-import workaround (Code Hygiene)
- New C<use NonCore::Module> outside the known dual-life list (Dependencies)

Warnings (not errors) - we want to surface these so they're visible in PR
review, but allow the change to proceed so the author can explain.

Designed to run in pre-commit and CI workflows. Exits 0 always (warnings).

=cut

use strict;
use warnings;
use utf8;
use File::Find;
use File::Basename;
use Cwd 'abs_path';

my $staged = grep { $_ eq '--staged' } @ARGV;
my $json_mode = grep { $_ eq '--json' } @ARGV;
my $base = 'HEAD';
for my $arg (@ARGV) {
    if ($arg =~ /^--base=(.+)$/) {
        $base = $1;
    }
}

# Determine which files to check
my @files;
if ($staged) {
    @files = `git diff --cached --name-only --diff-filter=AM 2>/dev/null`;
    chomp @files;
    @files = grep { /\.pm$/ } @files;
} else {
    # Compare HEAD vs working tree
    @files = `git diff --name-only --diff-filter=AM $base 2>/dev/null`;
    chomp @files;
    @files = grep { /\.pm$/ } @files;
    # Also include untracked .pm files in working tree
    my @untracked = `git ls-files --others --exclude-standard 2>/dev/null`;
    chomp @untracked;
    push @files, grep { /\.pm$/ } @untracked;
}

my @warnings;

# Check 1: New .pm file over 1000 lines (Architecture)
for my $file (@files) {
    next unless -f $file;
    my $line_count = `wc -l < "$file"`;
    chomp $line_count;
    if ($line_count > 1000) {
        push @warnings, {
            rule     => 'module-too-large',
            file     => $file,
            line     => $line_count,
            message  => "Module is $line_count lines (>1000); Architecture rubric penalizes modules over 1000 lines",
        };
    }
}

# Check 2: New sub over 200 lines (Method Quality)
for my $file (@files) {
    next unless -f $file;
    open my $fh, '<', $file or next;
    my @lines = <$fh>;
    close $fh;

    my @subs;
    for my $i (0..$#lines) {
        if ($lines[$i] =~ /^\s*sub\s+(\w+)/) {
            push @subs, { name => $1, start => $i };
        }
    }

    for my $j (0..$#subs) {
        my $end = ($j < $#subs) ? $subs[$j+1]{start} - 1 : $#lines;
        my $size = $end - $subs[$j]{start} + 1;
        if ($size > 200) {
            push @warnings, {
                rule     => 'method-too-large',
                file     => $file,
                line     => $subs[$j]{start} + 1,
                method   => $subs[$j]{name},
                message  => "Method $subs[$j]{name} is $size lines (>200); Method Quality rubric penalizes methods over 200 lines",
            };
        }
    }
}

# Check 3: New bare die outside eval/or die/$SIG (Error Handling)
for my $file (@files) {
    next unless -f $file;
    open my $fh, '<', $file or next;
    my @lines = <$fh>;
    close $fh;

    for my $i (0..$#lines) {
        next unless $lines[$i] =~ /\bdie\b/;
        next if $lines[$i] =~ /^\s*#|=head|=cut|croak|confess/;
        next if $lines[$i] =~ /\bor\s+die\b/;
        # Skip if line contains $SIG{} = sub { die ... } pattern (signal handler)
        next if $lines[$i] =~ /local\s+\$SIG/;
        push @warnings, {
            rule     => 'bare-die-added',
            file     => $file,
            line     => $i + 1,
            message  => "Bare die on line $i+1 - consider using croak() or eval{} with $@ handling",
        };
    }
}

# Check 4: New use JSON::PP without empty-import workaround (Code Hygiene)
for my $file (@files) {
    next unless -f $file;
    next if $file =~ /Util\/JSON\.pm$/;
    open my $fh, '<', $file or next;
    my $content = do { local $/; <$fh> };
    close $fh;

    if ($content =~ /use\s+JSON::PP(?!\s*\(\s*\))/) {
        push @warnings, {
            rule     => 'json-pp-direct-added',
            file     => $file,
            message  => "New use JSON::PP with imports - if accessing JSON::PP::true constant, use 'use JSON::PP ();' (empty parens) to avoid prototype conflict with CLIO::Util::JSON::encode_json",
        };
    }
}

# Check 5: New use of non-core, non-CLIO module (Dependencies)
# Only flag new uses of modules NOT in our known dual-life list.
my %known_modules = map { $_ => 1 } qw(
    strict warnings utf8
    POSIX Cwd File::Basename File::Find File::Path File::Copy File::Spec File::Temp File::Glob
    Fcntl IO IO::Handle IO::File IO::Select IO::Socket IO::Pipe IO::Dir IO::Poll IO::Seekable
    Carp Exporter Scalar::Util List::Util
    Time::HiRes Time::Local Time::Piece Time::Seconds
    Socket Net::hostent Net::netent Net::servent Net::protoent
    Getopt::Long Getopt::Std
    Encode Encode::Locale
    Storable Storable::CAN
    Data::Dumper
    Digest::MD5 Digest::SHA Digest::base
    MIME::Base64 MIME::QuotedPrint
    Term::ANSIColor Term::ReadKey Term::Cap Term::Complete
    Errno Config DirHandle
    constant base parent overload
    Sys::Hostname Sys::Syslog
    IPC::Open2 IPC::Open3 IPC::SysV IPC::Run IPC::Cmd
    Math::BigInt Math::BigFloat Math::BigRat Math::Complex Math::Trig Math::Prime::Util
    B B::Deparse B::Hooks::EndOfScope
    FindBin
    HTTP::Tiny HTTP::Status
    Test::More Test::Builder Test::Harness Test::Harness::Iterator
    feature open bytes locale if lib builtin experimental
    English mro
    JSON::PP JSON::XS JSON::Syck JSON::Any
    Text::ParseWords Text::Balanced Text::Tabs Text::Wrap
    UNIVERSAL Devel::Peek
);

for my $file (@files) {
    next unless -f $file;
    open my $fh, '<', $file or next;
    my @lines = <$fh>;
    close $fh;

    # Strip POD blocks first (matches assess_codebase.pl semantics)
    my $clean = join('', @lines);
    $clean =~ s/=pod.*?=cut//gs;
    $clean =~ s/^#[^\n]*/#c/gm;
    $clean =~ s/[ \t]+#[^\n]*$//gm;

    for my $line (split /\n/, $clean) {
        if ($line =~ /^use\s+(\S+)/) {
            my $mod = $1;
            next if $mod =~ /^CLIO/;
            next if $known_modules{$mod};
            next if $mod =~ /^5\./ || $mod =~ /;$/;
            push @warnings, {
                rule     => 'cpan-dep-added',
                file     => $file,
                module   => $mod,
                message  => "New use of $mod - verify it's a core Perl module or an intentional optional dep",
            };
        }
    }
}

# Output
if ($json_mode) {
    require CLIO::Util::JSON;
    print CLIO::Util::JSON::encode_json({
        checked_files => scalar(@files),
        warnings      => \@warnings,
    });
    print "\n";
} else {
    if (@warnings) {
        print "Size regression lint: " . scalar(@warnings) . " warning(s) in " . scalar(@files) . " file(s)\n\n";
        for my $w (@warnings) {
            my $where = $w->{file};
            $where .= ":" . $w->{line} if defined $w->{line};
            $where .= " (" . $w->{method} . ")" if defined $w->{method};
            print sprintf("[%-22s] %s\n  %s\n", $w->{rule}, $where, $w->{message});
        }
    } else {
        print "Size regression lint: clean (" . scalar(@files) . " files checked)\n";
    }
}

# Always exit 0 - these are warnings, not errors
exit 0;

1;