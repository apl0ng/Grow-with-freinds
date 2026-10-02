# usage: perl insert_after.pl <target file> <anchor text> <block file>
# Inserts the block after the ONE line that contains the anchor text ("<T>" in the block = one tab). Keeps CRLF.
use strict; use warnings;
my ($f, $anchor, $blockf) = @ARGV; local $/;
open my $fh, "<", $f or die "$f: $!"; my $s = <$fh>; close $fh;
my $crlf = $s =~ /\r\n/; $s =~ s/\r\n/\n/g;
open my $b, "<", $blockf or die; my $block = <$b>; close $b; $block =~ s/\r\n/\n/g; $block =~ s/<T>/\t/g;
my @lines = split /\n/, $s, -1; my @hits = grep { index($lines[$_], $anchor) >= 0 } 0 .. $#lines;
die "$f: anchor found " . scalar(@hits) . " times: $anchor" unless @hits == 1;
$block =~ s/\n\z//; splice(@lines, $hits[0] + 1, 0, split(/\n/, $block, -1));
$s = join("\n", @lines); $s =~ s/\n/\r\n/g if $crlf;
open my $oh, ">", $f or die; print $oh $s; close $oh; print "$f: block inserted after line " . ($hits[0] + 1) . " (crlf=$crlf)\n";
