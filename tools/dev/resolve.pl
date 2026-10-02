# usage: perl resolve.pl <file> <head|theirs|both|both-spaced>
# Resolves EVERY conflict hunk in the file the same way: keep our side, their side, or both (ours first; "both-spaced"
# puts two blank lines between them, for regions appended at the end of a script). Keeps CRLF.
use strict; use warnings;
my ($f, $mode) = @ARGV; local $/;
open my $fh, "<", $f or die "$f: $!"; my $s = <$fh>; close $fh;
my $crlf = $s =~ /\r\n/; $s =~ s/\r\n/\n/g;
my $n = 0;
$s =~ s{<<<<<<< [^\n]*\n(.*?)=======\n(.*?)>>>>>>> [^\n]*\n}{
  $n++; my ($ours, $theirs) = ($1, $2);
  $mode eq "head" ? $ours : $mode eq "theirs" ? $theirs : $mode eq "both" ? $ours . $theirs
    : do { (my $o = $ours) =~ s/\n+\z/\n/; $o . "\n\n" . $theirs };
}gse;
die "$f: no conflict hunks" unless $n;
$s =~ s/\n/\r\n/g if $crlf; open my $oh, ">", $f or die; print $oh $s; close $oh; print "$f: $n hunk(s) resolved ($mode)\n";
