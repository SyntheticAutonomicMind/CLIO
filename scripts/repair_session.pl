#!/usr/bin/env perl
# Session repair tool: handles multiple corruption patterns in CLIO session files
#
# This tool repairs session files that the parser refuses to load. It handles:
#
#   1. ReadLine control signal leak (hash ref content in messages) - the original
#      bug, where ReadLine's __TIMEOUT__/__AGENT_EVENT__ signals leaked into user
#      message slots, storing { type => '__TIMEOUT__' } instead of a string. CLIO's
#      State::load silently drops these messages but the file remains on disk and
#      is unparseable in some downstream consumers.
#
#   2. Empty / 0-byte files - typically caused by SIGKILL during a non-atomic
#      write (pre-atomic_write era, before commit d9a90d5 in April 2026). Current
#      code uses atomic_write so this can no longer happen, but legacy files
#      left in sessions/ from that era are unparseable.
#
#   3. Truncated / partial JSON - parse fails mid-document. We try CLIO's
#      JSONRepair utility on the raw bytes for cases like missing values
#      ({"k":,}), trailing commas, and unescaped quotes inside string values.
#
#   4. Valid JSON but wrong shape - file parses but isn't a CLIO session
#      (no messages/history keys). Quarantined, not silently dropped.
#
# Usage:
#   perl scripts/repair_session.pl --scan                 # report only
#   perl scripts/repair_session.pl --auto                 # repair ReadLine + JSON-shape issues
#   perl scripts/repair_session.pl --auto --cleanup       # also quarantine unrepairable files
#   perl scripts/repair_session.pl --auto --delete-empty  # also delete 0-byte files
#   perl scripts/repair_session.pl --session ID           # repair one session by ID
#   perl scripts/repair_session.pl --dry-run --auto       # show what would happen, change nothing

use strict;
use warnings;
use utf8;
use FindBin qw($RealBin);
use lib "$RealBin/../lib";

use CLIO::Core::Logger;
use CLIO::Util::JSON qw(encode_json decode_json safe_decode_json);
use CLIO::Util::JSONRepair qw(repair_malformed_json);
use File::Basename qw(basename dirname);
use File::Copy qw(copy);
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);

# --- Path discovery ---

sub find_sessions_dir {
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

sub _read_file {
    my ($file) = @_;
    open my $fh, '<:raw', $file or return undef;
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}

sub _quarantine_name {
    my ($file) = @_;
    my $stamp = strftime('%Y%m%d-%H%M%S', localtime);
    my $bak = "$file.corrupted.$stamp.bak";
    # Avoid collisions if quarantine runs twice in the same second
    my $n = 0;
    while (-e $bak) {
        $n++;
        $bak = "$file.corrupted.$stamp-$n.bak";
    }
    return $bak;
}

# Returns one of: 'ok', 'empty', 'invalid', 'shape', 'message_corruption'
sub _classify {
    my ($content, $data) = @_;

    return 'empty' if !defined $content || length($content) == 0;
    return 'invalid' if !$data || ref($data) ne 'HASH';

    # CLIO sessions have messages or history at top level. STM uses stm (array).
    my $messages = $data->{messages} || $data->{history} || $data->{stm};
    return 'shape' unless $messages && ref($messages) eq 'ARRAY';

    # Check each message for hash-ref content (ReadLine leak pattern)
    my @bad;
    for my $i (0 .. $#$messages) {
        my $m = $messages->[$i];
        next unless ref($m) eq 'HASH';
        if (ref($m->{content}) ne '') {
            push @bad, $i;
        }
    }
    return @bad ? 'message_corruption' : 'ok';
}

# Try to parse the file. Returns ($data, $error_string_or_undef).
# Tries strict decode, then relaxed JSON::PP via repair, before giving up.
sub _try_decode {
    my ($content) = @_;

    # Path 1: strict decode
    my $data = eval { decode_json($content) };
    return ($data, undef) if $data && ref($data) eq 'HASH';

    # Path 2: relaxed decode (JSON::PP with allow_nonref + relaxed)
    require JSON::PP;
    my $relaxed_json = JSON::PP->new->utf8->relaxed->allow_nonref;
    my $relaxed = eval { $relaxed_json->decode($content) };
    return ($relaxed, undef) if $relaxed && ref($relaxed) eq 'HASH';

    # Path 3: try repair_malformed_json then re-decode. Useful for
    # {"k":,} and missing-value patterns that AI assistants leave behind.
    my $repaired_data = eval {
        my $fixed = repair_malformed_json($content);
        $relaxed_json->decode($fixed);
    };
    return ($repaired_data, undef) if $repaired_data && ref($repaired_data) eq 'HASH';

    return (undef, $@ || 'unknown parse error');
}

sub scan_session {
    my ($file) = @_;
    my $content = _read_file($file);
    my ($data, $err) = _try_decode($content // '');
    my $class = _classify($content, $data);

    my @issues;
    if ($class eq 'empty') {
        push @issues, {
            severity => 'unrepairable',
            kind     => 'empty_file',
            detail   => 'File is 0 bytes',
            action   => 'quarantine_or_delete',
        };
    } elsif ($class eq 'invalid') {
        push @issues, {
            severity => 'unrepairable',
            kind     => 'invalid_json',
            detail   => "JSON parse failed: $err",
            action   => 'quarantine',
        };
    } elsif ($class eq 'shape') {
        push @issues, {
            severity => 'unrepairable',
            kind     => 'wrong_shape',
            detail   => 'File parses but does not contain messages/history/stm keys',
            action   => 'quarantine',
        };
    } elsif ($class eq 'message_corruption') {
        my $messages = $data->{messages} || $data->{history} || $data->{stm};
        for my $i (0 .. $#$messages) {
            my $m = $messages->[$i];
            next unless ref($m) eq 'HASH';
            next unless ref($m->{content}) ne '';
            push @issues, {
                severity  => 'repairable',
                kind      => 'hash_ref_content',
                index     => $i,
                role      => $m->{role} || '<unknown>',
                ref_type  => ref($m->{content}),
                ref_inner => $m->{content}{type} // '',
                # Default action is replace (preserves message order for valid API flow).
                # Drop is opt-in via --drop-messages; legacy behavior.
                action    => 'replace_corrupted_content',
            };
        }
    }
    return (\@issues, $data);
}

sub repair_session {
    my ($file, %opts) = @_;
    my $dry_run = $opts{dry_run};
    my $cleanup = $opts{cleanup};
    my $delete_empty = $opts{delete_empty};
    # --drop-messages opt-in: legacy behavior, drops hash-ref messages entirely.
    # Default: replace content with a string marker so conversation flow and
    # tool_call/tool_result pairing remain valid for API requests.
    my $drop_messages = $opts{drop_messages};

    my $content = _read_file($file);
    my ($data, $err) = _try_decode($content // '');
    my ($issues) = scan_session($file);

    my @repairable = grep { $_->{severity} eq 'repairable' } @$issues;
    my @unrepairable = grep { $_->{severity} eq 'unrepairable' } @$issues;

    return ('noop', 0) if !@repairable && !@unrepairable;

    my $actions = [];

    # Repair: handle hash-ref content messages.
    # Default path: replace content with a string marker so the message stays
    # in the conversation (preserves tool_call/tool_result pairing and message
    # order for API requests). Strict-schema providers (e.g. NVIDIA NIM) require
    # string content; permissive providers (minimax) accept whatever.
    #
    # --drop-messages: legacy behavior, drops the message entirely.
    my $replaced_count = 0;
    my $dropped_count = 0;
    if (@repairable) {
        my $messages_ref = $data->{messages} || $data->{history} || $data->{stm};
        my @bad_indices = map { $_->{index} } @repairable;
        my %bad = map { $_ => 1 } @bad_indices;

        if ($drop_messages) {
            my @kept;
            for my $i (0 .. $#$messages_ref) {
                if ($bad{$i}) {
                    $dropped_count++;
                    next;
                }
                push @kept, $messages_ref->[$i];
            }
            $data->{messages} = \@kept if exists $data->{messages};
            $data->{history}  = \@kept if exists $data->{history};
            $data->{stm}      = \@kept if exists $data->{stm};

            push @$actions, {
                kind => 'drop_hash_ref_messages',
                count => $dropped_count,
            };
        } else {
            # Replace content with a marker, keep message in place.
            for my $i (sort { $a <=> $b } @bad_indices) {
                next if $i > $#$messages_ref;
                my $m = $messages_ref->[$i];
                next unless ref($m) eq 'HASH';
                my $ref_type = ref($m->{content});
                my $inner = '';
                if ($ref_type eq 'HASH' && defined $m->{content}{type}) {
                    $inner = " type='$m->{content}{type}'";
                }
                $m->{content} = '[CORRUPTED INPUT: ' . $ref_type . $inner
                    . ' - repaired by repair_session.pl]';
                $replaced_count++;
            }
            push @$actions, {
                kind => 'replace_corrupted_content',
                count => $replaced_count,
            };
        }
    }

    # Handle unrepairable cases
    if (@unrepairable) {
        my $kind = $unrepairable[0]{kind};

        if ($kind eq 'empty_file') {
            if ($delete_empty) {
                if ($dry_run) {
                    push @$actions, { kind => 'delete' };
                } else {
                    unlink $file or push @$actions, { kind => 'delete', failed => $! };
                    push @$actions, { kind => 'delete' } unless $!;
                }
            } elsif ($cleanup) {
                my $bak = _quarantine_name($file);
                if ($dry_run) {
                    push @$actions, { kind => 'quarantine', dest => $bak };
                } else {
                    if (rename $file, $bak) {
                        push @$actions, { kind => 'quarantine', dest => $bak };
                    } else {
                        push @$actions, { kind => 'quarantine', failed => $! };
                    }
                }
            } else {
                push @$actions, { kind => 'leave_in_place', reason => 'use --cleanup or --delete-empty' };
            }
        } elsif ($kind eq 'invalid_json' || $kind eq 'wrong_shape') {
            if ($cleanup) {
                my $bak = _quarantine_name($file);
                if ($dry_run) {
                    push @$actions, { kind => 'quarantine', dest => $bak };
                } else {
                    if (rename $file, $bak) {
                        push @$actions, { kind => 'quarantine', dest => $bak };
                    } else {
                        # rename can fail across filesystems; fall back to copy+unlink
                        if (copy($file, $bak)) {
                            unlink $file;
                            push @$actions, { kind => 'quarantine_via_copy', dest => $bak };
                        } else {
                            push @$actions, { kind => 'quarantine', failed => $! };
                        }
                    }
                }
            } else {
                push @$actions, { kind => 'leave_in_place', reason => 'use --cleanup to quarantine' };
            }
        }
    }

    # Write repaired data back if there were repairs and data is still a hash
    my $total_modified = $replaced_count + $dropped_count;
    if ($total_modified > 0 && !$dry_run) {
        my $json = encode_json($data);

        # Back up first (only for repairs, not for quarantine cases)
        my $backup = "$file.repair.bak";
        if (-f $backup) {
            # Avoid clobbering earlier backups
            my $stamp = strftime('%Y%m%d-%H%M%S', localtime);
            $backup = "$file.repair.$stamp.bak";
        }
        copy($file, $backup);

        open my $fh, '>:raw', $file or die "Cannot write $file: $!";
        print $fh $json;
        close $fh;
        chmod 0600, $file;
        push @$actions, { kind => 'backup', dest => $backup };
        push @$actions, { kind => 'rewrite_in_place' };
    } elsif ($total_modified > 0 && $dry_run) {
        push @$actions, { kind => 'would_rewrite_in_place' };
    }

    return ($total_modified > 0 ? 'repaired' : 'quarantined', $actions);
}

sub describe_issues {
    my ($issues) = @_;
    my @lines;
    for my $i (@$issues) {
        if ($i->{index}) {
            push @lines, sprintf("  [%d] %s role=%s content=<%s ref: %s> (action: %s)",
                $i->{index}, $i->{kind}, $i->{role},
                $i->{ref_inner}, $i->{ref_type}, $i->{action});
        } else {
            push @lines, sprintf("  %s: %s (action: %s)",
                $i->{kind}, $i->{detail}, $i->{action});
        }
    }
    return @lines;
}

# --- Main ---

my ($scan, $auto, $session_id, $help, $dry_run, $cleanup, $delete_empty, $drop_messages);
GetOptions(
    'scan'           => \$scan,
    'auto'           => \$auto,
    'session=s'      => \$session_id,
    'dry-run'        => \$dry_run,
    'cleanup'        => \$cleanup,
    'delete-empty'   => \$delete_empty,
    'drop-messages'  => \$drop_messages,
    'help'           => \$help,
) or die "Bad options\n";

if ($help) {
    print <<EOF;
Usage: repair_session.pl [options]

Options:
  --scan           Scan all sessions for corruption (read-only)
  --auto           Auto-repair all corrupted sessions in default location
  --cleanup        Quarantine unrepairable files (rename to .corrupted.bak)
  --delete-empty   Delete 0-byte files entirely (implies --cleanup behavior)
  --session ID     Repair a specific session by ID (filename without .json)
  --dry-run        Show what would happen, make no changes
  --drop-messages  Legacy behavior: drop hash-ref messages entirely instead of
                  replacing their content with a [CORRUPTED INPUT: ...] marker.
                  Default is to replace (preserves conversation flow and
                  tool_call/tool_result pairing for API requests)
  --help           Show this message

If no options are given, scans all sessions in default location.

Without --cleanup or --delete-empty, unrepairable files are reported but
left in place. With --cleanup they are renamed to *.corrupted.<stamp>.bak.
With --delete-empty, 0-byte files are unlinked.

Hash/array ref content (e.g. ReadLine __TIMEOUT__ control signal leaks) is
detected as corruption. Default repair strategy is to replace the content
with a string marker, keeping the message in the conversation flow. This
matters for strict-schema API providers (e.g. NVIDIA NIM) that reject object
content with "data did not match any variant of untagged enum
ChatCompletionRequestUserMessageContent".

EOF
    exit 0;
}

my $dir = find_sessions_dir();
if (!$dir) {
    die "No sessions directory found. Set CLIO_SESSIONS_DIR.\n";
}
print "Sessions directory: $dir\n";
print "Mode: ", ($dry_run ? 'DRY-RUN' : 'LIVE'), "\n";
print "\n";

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
        my ($issues) = scan_session("$dir/$file");
        if (@$issues) {
            $any = 1;
            print "\n$file:\n";
            print describe_issues($issues), "\n";
        }
    }
    print $any ? "\nCorrupted sessions found. Run with --auto to repair.\n"
               : "All sessions clean.\n";
    exit($any ? 1 : 0);
}

if ($auto) {
    print "=== Auto-Repair Mode ===\n";
    my $total_repaired = 0;
    my $total_quarantined = 0;
    my $total_deleted = 0;
    my $total_skipped = 0;
    for my $file (@sessions) {
        my ($issues) = scan_session("$dir/$file");
        next unless @$issues;
        print "\n$file:\n";
        print describe_issues($issues), "\n";
        my ($result, $actions) = repair_session("$dir/$file",
            dry_run       => $dry_run,
            cleanup       => $cleanup,
            delete_empty  => $delete_empty,
            drop_messages => $drop_messages,
        );

        for my $a (@$actions) {
            if ($a->{kind} eq 'drop_hash_ref_messages') {
                print "  REPAIR: dropping $a->{count} hash-ref message(s)\n";
            } elsif ($a->{kind} eq 'replace_corrupted_content') {
                print "  REPAIR: replaced $a->{count} hash-ref content message(s) with [CORRUPTED INPUT: ...] marker\n";
            } elsif ($a->{kind} eq 'quarantine') {
                if ($a->{failed}) {
                    print "  QUARANTINE FAILED: $a->{failed}\n";
                    $total_skipped++;
                } else {
                    print "  QUARANTINED -> $a->{dest}\n";
                    $total_quarantined++;
                }
            } elsif ($a->{kind} eq 'quarantine_via_copy') {
                print "  QUARANTINED (via copy) -> $a->{dest}\n";
                $total_quarantined++;
            } elsif ($a->{kind} eq 'delete') {
                if ($a->{failed}) {
                    print "  DELETE FAILED: $a->{failed}\n";
                    $total_skipped++;
                } else {
                    print "  DELETED\n";
                    $total_deleted++;
                }
            } elsif ($a->{kind} eq 'rewrite_in_place') {
                print "  REWROTE file (also backed up: $a->{dest})\n" if $a->{dest};
            } elsif ($a->{kind} eq 'backup') {
                # printed with rewrite
            } elsif ($a->{kind} eq 'would_rewrite_in_place') {
                print "  WOULD REWRITE (dry-run)\n";
            } elsif ($a->{kind} eq 'leave_in_place') {
                print "  LEFT IN PLACE: $a->{reason}\n";
                $total_skipped++;
            }
        }
        $total_repaired++ if $result eq 'repaired';
    }
    print "\n=== Summary ===\n";
    print "  Repaired:     $total_repaired\n";
    print "  Quarantined:  $total_quarantined\n";
    print "  Deleted:      $total_deleted\n";
    print "  Skipped:      $total_skipped\n";
    if ($dry_run) {
        print "  (DRY-RUN: no changes made)\n";
    }
    exit(0);
}

if ($session_id) {
    print "=== Repair Mode ===\n";
    my $file = "$dir/$session_id.json";
    if (!-f $file) {
        die "Session file not found: $file\n";
    }
    my ($issues) = scan_session($file);
    if (@$issues) {
        print describe_issues($issues), "\n";
    }
    my ($result, $actions) = repair_session($file,
        dry_run       => $dry_run,
        cleanup       => $cleanup,
        delete_empty  => $delete_empty,
        drop_messages => $drop_messages,
    );
    for my $a (@$actions) {
        if ($a->{kind} eq 'quarantine' || $a->{kind} eq 'quarantine_via_copy') {
            print "QUARANTINED -> $a->{dest}\n";
        } elsif ($a->{kind} eq 'delete') {
            print "DELETED\n" unless $a->{failed};
        } elsif ($a->{kind} eq 'leave_in_place') {
            print "LEFT IN PLACE: $a->{reason}\n";
        }
    }
    exit($result eq 'noop' ? 1 : 0);
}
