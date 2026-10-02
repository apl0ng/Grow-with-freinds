# usage: perl splice.pl <target file> <old block file> <new block file>   ("<T>" in the blocks = one tab)
use strict; use warnings;
my ($f, $oldf, $newf) = @ARGV; local $/;
open my $fh, "<", $f or die "$f: $!"; my $s = <$fh>; close $fh;
my $crlf = $s =~ /\r\n/; $s =~ s/\r\n/\n/g;
open my $o, "<", $oldf or die; my $old = <$o>; close $o; open my $n, "<", $newf or die; my $new = <$n>; close $n;
for ($old, $new) { s/\r\n/\n/g; s/<T>/\t/g; }
my $i = index($s, $old); die "$f: old block not found" if $i < 0;
die "$f: old block found twice" if index($s, $old, $i + 1) >= 0;
substr($s, $i, length($old)) = $new;
$s =~ s/\n/\r\n/g if $crlf; open my $oh, ">", $f or die; print $oh $s; close $oh; print "$f spliced (crlf=$crlf)\n";
