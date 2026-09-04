#!/usr/bin/perl
# Integration test for ReadLine with viewport/scrolling.
#
# When the input overflows the screen (taller than term_height rows),
# the readline must let the terminal scroll naturally. The old
# behavior was to emit \e[NA + \e[J (move up + clear) using the
# INPUT row count, which the terminal can't honor past the top
# of the screen, causing double-scroll and cursor drift.
#
# The fix: _emit_text tracks scroll_offset (how many input rows
# have scrolled off the top), and redraw_line / _redraw_from_cursor /
# reposition_cursor convert input rows to screen rows via
# _input_row_to_screen_row before emitting cursor movement commands.

use strict;
use warnings;
use utf8;
use FindBin;
use lib "$FindBin::Bin/../lib";

BEGIN {
    no warnings 'redefine', 'prototype';
    require CLIO::Compat::Terminal;
    *CLIO::Compat::Terminal::GetTerminalSize = sub { return (20, 24) };
    *CLIO::Compat::Terminal::ReadMode = sub { return 1 };
    *CLIO::Compat::Terminal::ReadKey = sub {
        return undef unless @main::KEY_QUEUE;
        return shift @main::KEY_QUEUE;
    };
}

our @KEY_QUEUE;
sub push_input { push @KEY_QUEUE, @_ }
sub push_bytes { push @KEY_QUEUE, map { chr($_) } @_ }
sub input_chars_for { return split //, $_[0] }

package VirtualTerminal;
sub new {
    my ($class, %opts) = @_;
    return bless {
        cols => $opts{cols} || 20, rows => $opts{rows} || 24,
        row => 0, col => 0, buffer => [], pending => 0,
    }, $class;
}
sub feed {
    my ($s,$b)=@_; my $i=0;
    while($i<length($b)){
        my $ch=substr($b,$i,1);
        my $c2 = ord($ch);
        if($ch eq "\e"){
            if(substr($b,$i+1,1)eq '['){
                my $j=$i+2;
                $j++ while $j<length($b)&&substr($b,$j,1)=~ /[\d;?]/;
                my $p=substr($b,$i+2,$j-$i-2); my $cmd=substr($b,$j,1);
                my $n=($p eq ''?1:$p)+0;$n=1 if $n==0;
                if($cmd eq 'C'){if($s->{pending}){$s->{row}++;$s->{col}=0;$s->{pending}=0}$s->{col}+=$n;$s->{col}=$s->{cols}-1 if $s->{col}>=$s->{cols}}
                elsif($cmd eq 'D'){if($s->{pending}){$s->{row}++;$s->{col}=0;$s->{pending}=0}$s->{col}-=$n;$s->{col}=0 if $s->{col}<0}
                elsif($cmd eq 'A'){if($s->{pending}){$s->{row}++;$s->{col}=0;$s->{pending}=0}$s->{row}-=$n;$s->{row}=0 if $s->{row}<0}
                elsif($cmd eq 'B'){if($s->{pending}){$s->{row}++;$s->{col}=0;$s->{pending}=0}$s->{row}+=$n}
                elsif($cmd eq 'J'){for my $r($s->{row}..$s->{rows}-1){my $start=($r==$s->{row})?$s->{col}:0;for my $c($start..$s->{cols}-1){$s->{buffer}[$r][$c]=' '}}}
                $i=$j+1
            }else{$i++}
        }elsif($ch eq "\r"){$s->{col}=0;$s->{pending}=0;$i++}
        elsif($ch eq "\n"){$s->{row}++;$i++}
        elsif($c2 >= 32 && $c2 < 127) {
            if($s->{pending}){
                if($s->{row}>=$s->{rows}-1){shift @{$s->{buffer}};$s->{buffer}[$s->{rows}-1]=[' ']}
                else{$s->{row}++}
                $s->{col}=0;$s->{pending}=0
            }
            $s->{buffer}[$s->{row}][$s->{col}]=$ch;
            $s->{col}++;
            if($s->{col}>=$s->{cols}){$s->{pending}=1}
            $i++
        }else{$i++}
    }
}
sub render {
    my $s=shift;
    my @l;
    for my $r(0..$s->{rows}-1){
        my $line='';
        for my $c(0..$s->{cols}-1){$line.=$s->{buffer}[$r][$c]//' '}
        push @l,$line
    }
    return join("\n",@l)
}

package main;

sub run_scenario {
    my (%args) = @_;
    pipe(my $read_end, my $write_end) or die "pipe: $!";
    my $saved_stdout = select($write_end); $| = 1;
    my $pid = fork(); die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        eval {
            local $SIG{ALRM} = sub { die "TIMEOUT\n" };
            alarm 5;
            require CLIO::Core::ReadLine;
            my $rl = CLIO::Core::ReadLine->new(prompt => $args{prompt} || '> ');
            my $line = $rl->readline($args{prompt} || undef);
            alarm 0;
        };
        exit(0);
    }
    my $waited = 0;
    while ($waited < 5.5) {
        my $kid = waitpid($pid, 1); last if $kid == $pid;
        select(undef, undef, undef, 0.05); $waited += 0.05;
    }
    if (kill 0, $pid) { kill 'KILL', $pid; waitpid($pid, 0) }
    close $write_end; select($saved_stdout); $| = 1;
    my $buf = '';
    while (1) { my $chunk = ''; my $n = sysread($read_end, $chunk, 4096); last unless defined $n && $n > 0; $buf .= $chunk }
    close $read_end;
    my $vt = VirtualTerminal->new(cols => $args{cols} || 20, rows => $args{rows} || 24);
    $vt->feed($buf);
    return ($vt, $buf);
}

use Test::More tests => 3;

# Test 1: Type 500 'a's (overflow), then Enter.
# The byte stream should NOT contain "\e[NA + \e[J" scrolling
# (which would indicate the readline doing its own scrolling from
# row 0 instead of letting the terminal scroll naturally).
{
    @KEY_QUEUE = ();
    push_input(input_chars_for("a" x 500));
    push_bytes(0x0a);

    my ($vt, $bytes) = run_scenario();

    my @up_moves = ($bytes =~ /\e\[(\d+)A/g);
    my $clears = () = $bytes =~ /\e\[J/g;
    is(scalar(@up_moves), 0, "test1: no \e[NA cursor up moves (no explicit scrolling)");
    is($clears, 0, "test1: no \e[J clear-to-end moves");
}

# Test 2: Word-movement round-trip with overflow input.
# Type 484 chars (overflows screen), Ctrl+Left, Ctrl+Right, Ctrl+Left,
# then type 'X'. Verify X is followed by c's (inserted before the c word).
{
    @KEY_QUEUE = ();
    my $text = "a" x 200 . " word " . "b" x 200 . " word " . "c" x 72;
    push_input(input_chars_for($text));
    push_bytes(0x1b, ord('['), ord('1'), ord(';'), ord('5'), ord('D'));  # Ctrl+Left
    push_bytes(0x1b, ord('['), ord('1'), ord(';'), ord('5'), ord('C'));  # Ctrl+Right
    push_bytes(0x1b, ord('['), ord('1'), ord(';'), ord('5'), ord('D'));  # Ctrl+Left
    push_input(input_chars_for("X"));
    push_bytes(0x0a);

    my ($vt, $bytes) = run_scenario();
    my @rows = split /\n/, $vt->render, -1;
    my $full = join('', @rows);

    # X should be followed by c's (inserted before the c word)
    like($full, qr/Xc/, "test2: X is followed by c's (correct insertion position)");
}
