#!/usr/bin/env perl
# Denylist matcher for `publishable check`. Usage:
#   git ls-files -z | perl denylist.pl worktree <list>                              -> "<path>\t<line>" per hit
#   git log -p ... --format='%x00commit %H' | perl denylist.pl history <list> <repo>  -> first commit per term
# One term per line; text from '#' is a comment; terms under 3 characters are skipped. A single token matches as a
# whole word (underscore counts as a boundary, so snake_case identifiers match); a term with whitespace matches as a
# substring; `a && b` matches only when every part is on one line. Only locations are printed, never terms.
use strict; use warnings;
my ($mode, $list, $repo) = @ARGV;
open(my $lf, '<', $list) or die "cannot read denylist\n";
# Case folding is Unicode-aware: a valid UTF-8 line is decoded, lowercased and re-encoded (Élodie and élodie are one
# term, as git grep -i judged them under a UTF-8 locale); anything else folds ASCII only. Whitespace tests stay ASCII
# ([ \t]), because \s on raw bytes can eat half of an accented letter.
sub norm {
  my $s = $_[0];
  return lc $s unless $s =~ /[\x80-\xff]/;
  my $u = $s;
  if (utf8::decode($u)) { $u = lc $u; utf8::encode($u); return $u }
  $s =~ tr/A-Z/a-z/;
  return $s;
}
my (%bounded, %phrase, %single, %conj_by_anchor, %part_re);
my $nterms = 0;
sub part_re {
  my $p = norm($_[0]);
  return $part_re{$p} //= ($p =~ /[ \t]/) ? qr/\Q$p\E/ : qr/(?<![a-z0-9])\Q$p\E(?![a-z0-9])/;
}
while (my $raw = <$lf>) {
  chomp $raw; $raw =~ s/\r\z//;
  (my $t = $raw) =~ s/#.*//s;
  $t =~ s/^[ \t]+//; $t =~ s/[ \t]+\z//;
  my $chars = $t; utf8::decode($chars);
  next unless length($chars) >= 3;
  my $id = $nterms++;
  my @parts = grep { length } split /[ \t]+&&[ \t]+/, $t;
  @parts = ($t) if @parts < 2;
  my $anchor = norm($parts[0]);
  if ($anchor =~ /[ \t]/) { $phrase{$anchor} = 1 } else { $bounded{$anchor} = 1 }
  if (@parts == 1) { push @{ $single{$anchor} }, $id }
  else { push @{ $conj_by_anchor{$anchor} }, [ $id, map { part_re($_) } @parts[1 .. $#parts] ] }
}
exit 0 unless $nterms;
# An alternation reports ONE term per start position, the longest that fits. A shorter term that matches at the same
# place is always a prefix of it, so each term carries, precomputed, the shorter terms of its kind that match wherever
# it does (for a bounded term: those followed by a non-word character inside it). So `Zephyr` still
# matches where `Zephyr-X && Missing` matches first and its pair then fails.
my %also;
for my $set ([\%bounded, 1], [\%phrase, 0]) {
  my ($h, $is_bounded) = @$set;
  for my $k (keys %$h) {
    for my $l (1 .. length($k) - 1) {
      my $p = substr($k, 0, $l);
      next unless $h->{$p};
      next if $is_bounded && substr($k, $l, 1) =~ /[a-z0-9]/;
      push @{ $also{$k} }, $p;
    }
  }
}
# Case folding happens ONCE per line and the patterns stay case-sensitive: Perl builds a fast trie for a big
# literal alternation only without /i (10,000 terms with /i run about 10,000 times slower),
# and only up to a size, so the terms go into chunks of bounded total length.
my $edge = '[a-z0-9]';
my (@res_bounded, @res_phrase);
for my $set ([\%bounded, \@res_bounded, 1], [\%phrase, \@res_phrase, 0]) {
  my ($h, $out, $is_bounded) = @$set;
  my @keys = sort { length($b) <=> length($a) || $a cmp $b } keys %$h;
  while (@keys) {
    my ($chars, @chunk) = (0);
    while (@keys && ($chars < 40000 || !@chunk)) { my $k = shift @keys; $chars += length $k; push @chunk, $k }
    my $alt = join '|', map { quotemeta } @chunk;
    push @$out, $is_bounded ? qr/(?<!$edge)($alt)(?!$edge)/ : qr/($alt)/;
  }
}
# Every term id a (folded) line carries. pos() restarts one character past each match start, so a term inside or
# overlapping another term is still found. $phrases_only: singles of the phrase kind, for binary content.
sub hits_in {
  my ($line, $phrases_only) = @_;
  my %ids;
  for my $re ($phrases_only ? @res_phrase : (@res_bounded, @res_phrase)) {
    while ($line =~ /$re/g) {
      my ($start, $m) = ($-[0], $1);              # copies: the pair checks below run other matches
      for my $k ($m, @{ $also{$m} || [] }) {
        $ids{$_} = 1 for @{ $single{$k} || [] };
        next if $phrases_only;
        for my $c (@{ $conj_by_anchor{$k} || [] }) {
          my ($id, @rest) = @$c;
          next if $ids{$id};
          my $all = 1;
          for my $r (@rest) { if ($line !~ $r) { $all = 0; last } }
          $ids{$id} = 1 if $all;
        }
      }
      pos($line) = $start + 1;
    }
  }
  return keys %ids;
}
sub line_hits { return hits_in(norm($_[0]), 0) }
if ($mode eq 'worktree') {
  local $/ = "\0";
  while (my $path = <STDIN>) {
    chomp $path;
    next if -l $path || !-f _;
    open(my $fh, '<:raw', $path) or next;
    my $head = '';
    read($fh, $head, 8000);
    next if index($head, "\0") >= 0;           # binary, as git grep -I judges it
    seek($fh, 0, 0);
    local $/ = "\n";
    my $n = 0;
    while (my $line = <$fh>) {
      $n++;
      print "$path\t$n\n" for line_hits($line);
    }
  }
} elsif ($mode eq 'history') {
  # Text diffs: the added and removed lines. Binary diffs print no lines, only "Binary files ... differ", so their
  # blobs (named by the --full-index header) are read afterwards: a blob without NUL bytes (text marked binary by an
  # attribute) gets the full rules, a real binary only the phrase terms, since a bounded short word in
  # random bytes is noise.
  my ($commit, $in_hunk, @ids, %first, @order, %blob_commit, @blobs) = ('', 0);
  my $zero = qr/^0+\z/;
  my $record = sub { my ($id, $c) = @_; return if exists $first{$id}; $first{$id} = $c; push @order, $id };
  while (my $line = <STDIN>) {
    if ($line =~ /^\0commit ([0-9a-f]+)/) { $commit = $1; $in_hunk = 0; @ids = (); next }
    if ($line =~ /^diff --/) { $in_hunk = 0; @ids = (); next }
    if (!$in_hunk && $line =~ /^index ([0-9a-f,]+)\.\.([0-9a-f]+)/) { @ids = ((split /,/, $1), $2); next }
    if (!$in_hunk && $line =~ /^Binary files /) {
      for my $b (@ids) {
        next if $b =~ $zero || exists $blob_commit{$b};
        $blob_commit{$b} = $commit; push @blobs, $b;
      }
      next;
    }
    if ($line =~ /^@@/) { $in_hunk = 1; next }
    next unless $in_hunk && $line =~ /^[+-]/;
    $record->($_, $commit) for line_hits(substr($line, 1));
  }
  if (@blobs) {
    defined $repo or die "no repository for blob reads\n";
    open(my $ids_fh, '+>', undef) or die "cannot buffer blob ids\n";
    print $ids_fh "$_\n" for @blobs;
    seek($ids_fh, 0, 0);
    open(STDIN, '<&', $ids_fh) or die "cannot redirect blob ids\n";
    open(my $cf, '-|', 'git', '-C', $repo, 'cat-file', '--batch') or die "cannot start git cat-file\n";
    binmode $cf;
    for my $b (@blobs) {
      my $hdr = <$cf>;
      defined $hdr or die "git cat-file ended early\n";
      next if $hdr =~ / missing$/;                  # remerge pre-images live in a temporary object store
      $hdr =~ /^([0-9a-f]+) blob (\d+)$/ or die "unexpected cat-file output\n";
      my $size = $2;
      my $buf = '';
      while (length($buf) < $size) { read($cf, $buf, $size - length($buf), length $buf) or die "short blob read\n" }
      read($cf, my $nl, 1);
      my $is_binary = index(substr($buf, 0, 8000), "\0") >= 0;
      for my $line (split /\n/, $buf) {
        $record->($_, $blob_commit{$b}) for hits_in(norm($line), $is_binary);
      }
    }
    close($cf) or die "git cat-file failed\n";
  }
  print "$first{$_}\n" for @order;
} else { die "unknown mode\n" }
