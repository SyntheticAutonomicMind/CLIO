#!/usr/bin/env perl
# Session repair tool: removes messages with non-string content
#
# Bug history: ReadLine's __TIMEOUT__ control signal (a hash ref) could leak
# into the session as a phantom user message, corrupting subsequent context
# and confusing the model. This tool scrubs those entries from an existing
# session file so the user can resume work without restarting.
#
# Usage:
#   perl scripts/repair_session.pl <session-id>
#   perl scripts/repair_session.pl --scan   # scan all sessions
#   perl scripts/repair_session.pl --auto   # repair all corrupted sessions in default location

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";


use JSON::PP;
use File::Basename qw(basename dirname);
use File::Copy qw(copy);
use Getopt::Long qw(GetOptions);

# JSON::PP configured for UTF-8 + relaxed parsing (matches CLIO session files)
my $_json = JSON::PP->new->utf8->relaxed->allow_nonref;

sub _decode_session {
    my ($str) = @_;
    return eval { $_json->decode($str) };
}

sub _encode_session {
    my ($data) = @_;
    return $_json->encode($data);
}

sub find_sessions_dir {
    # CLIO looks in several places for sessions
    my @candidates = (
        $ENV{CLIO_SESSIONS_DIR},
        "$ENV{HOME}/.clio/sessions",
        "$ENV{HOME}/.config/clio/sessions",
        "$RealBin/../sessions",
    );
    for my $dir (@candidates) {
        next unless $dir && -d $dir;
        return $dir;
    }
    return undef;
}

sub list_sessions {
    my ($dir) = @_;
    return () unless $dir && -d $dir;
    opendir(my $dh, $dir) or return ();
    my @files = grep { /\.json$/ && -f "$dir/$_" } readdir($dh);
    closedir($dh);
    return sort @files;
}

sub scan_session {
    my ($file) = @_;
    my $content;
    {
        open my $fh, '<:raw', $file or do {
            warn "Cannot read $file: $!";
            return [];
        };
        $content = do { local $/; <$fh> };
        close $fh;
    }
    my $data = eval { decode_json($content) };
    $data //= eval { _decode_session($content) };
    if (!$data) {
        return [{ index => -1, role => '<file>', content => "INVALID JSON: $@" }];
    }
    my @issues;
    # Try common message keys
    my $msgs = $data->{messages} || $data->{history} || [];
    for my $i (0..$#$msgs) {
        my $m = $msgs->[$i];
        my $c = $m->{content};
        if (ref($c)) {
            push @issues, {
                index => $i,
                role => $m->{role} || '<unknown>',
                content => $c,
                timestamp => $m->{timestamp} || '',
            };
        }
    }
    return \@issues;
}

sub repair_session {
    my ($file) = @_;
    my $content;
    {
        open my $fh, '<:raw', $file or die "Cannot read $file: $!";
        $content = do { local $/; <$fh> };
        close $fh;
    }
    my $data = eval { decode_json($content) };
    $data //= eval { _decode_session($content) };
    if (!$data) {
        print STDERR "FAIL: $file is not valid JSON: $@\n";
        return 0;
    }
    my @msgs = @{$data->{messages} || $data->{history} || []};
    my @keep;
    my $removed = 0;
    for my $m (@msgs) {
        if (ref($m->{content})) {
            my $type = ref($m->{content});
            my $sig = $m->{content}{type} // '';
            print "  REMOVE: role=$m->{role} content=<$sig ref: $type>\n";
            $removed++;
            next;
        }
        push @keep, $m;
    }
    return 0 if $removed == 0;
    
    # Backup original
    my $backup = "$file.corrupted.bak";
    copy($file, $backup) or do {
        print STDERR "FAIL: cannot backup to $backup: $!\n";
        return 0;
    };
    print "  BACKUP: $backup\n";
    
    # Write repaired file
    $data->{messages} = \@keep if exists $data->{messages};
    $data->{history} = \@keep if exists $data->{history};
    my $json = _encode_session($data);
    {
        open my $fh, '>:raw', $file or die "Cannot write $file: $!";
        print $fh $json;
        close $fh;
    }
    print "  REPAIRED: removed $removed corrupted message(s)\n";
    return $removed;
}

# --- Main ---
my ($scan, $auto, $session_id, $help);
GetOptions(
    'scan' => \$scan,
    'auto' => \$auto,
    'session=s' => \$session_id,
    'help' => \$help,
) or die "Bad options\n";

if ($help) {
    print <<EOF;
Usage: repair_session.pl [options]

Options:
  --scan           Scan all sessions for corruption (read-only)
  --auto           Auto-repair all corrupted sessions in default location
  --session ID     Repair a specific session by ID (filename without .json)
  --help           Show this message

If no options are given, scans all sessions in default location.

EOF
    exit 0;
}

my $dir = find_sessions_dir();
if (!$dir) {
    die "No sessions directory found. Set CLIO_SESSIONS_DIR.\n";
}
print "Sessions directory: $dir\n\n";

my @sessions = list_sessions($dir);
if ($session_id) {
    @sessions = grep { basename($_, '.json') eq $session_id } @sessions;
    if (!@sessions) {
        die "No session file matching ID '$session_id' in $dir\n";
    }
}

if ($scan || (!$auto && !$session_id)) {
    print "=== Scan Mode ===\n";
    my $any = 0;
    for my $file (@sessions) {
        my $issues = scan_session("$dir/$file");
        if (@$issues) {
            $any = 1;
            print "$file:\n";
            for my $i (@$issues) {
                if ($i->{index} == -1) {
                    print "  FILE-LEVEL: $i->{content}\n";
                } else {
                    print "  [$i->{index}] role=$i->{role} ts=$i->{timestamp} content=$i->{content}\n";
                }
            }
        }
    }
    print $any ? "\nCorrupted sessions found. Run with --auto to repair.\n"
               : "All sessions clean.\n";
    exit($any ? 1 : 0);
}

if ($auto) {
    print "=== Auto-Repair Mode ===\n";
    my $total_fixed = 0;
    for my $file (@sessions) {
        my $issues = scan_session("$dir/$file");
        next unless @$issues;
        print "\n$file:\n";
        my $removed = repair_session("$dir/$file");
        $total_fixed++ if $removed;
    }
    print "\n=== Done: fixed $total_fixed session(s) ===\n";
    exit(0);
}

if ($session_id) {
    print "=== Repair Mode ===\n";
    my $file = "$dir/$session_id.json";
    if (!-f $file) {
        die "Session file not found: $file\n";
    }
    my $removed = repair_session($file);
    exit($removed ? 0 : 1);
}
