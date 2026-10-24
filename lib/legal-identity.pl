#!/usr/bin/env perl
# Fail-closed, deliberately restricted HTML identity paragraph recognizer. No output:
# callers receive only a verdict, never the scanned text. Offsets are gitleaks' byte columns.
use strict;
use warnings;

my ($path, $globs, $sl, $sc, $el, $ec) = @ARGV;
exit 1 unless @ARGV == 6 && $path !~ m{(?:^/|(?:^|/)\.\.(?:/|$))};
for ($sl, $sc, $el, $ec) { exit 1 unless defined && /\A[1-9][0-9]*\z/ }
exit 1 if $el < $sl || ($el == $sl && $ec < $sc);

# Repo-relative globs: * and ? never cross /; ** does. **/ also matches no directories.
my $allowed = 0;
for my $glob (split /\s+/, $globs) {
    my $re = '';
    while (length $glob) {
        if ($glob =~ s{\A\*\*/}{}) { $re .= '(?:.*/)?' }
        elsif ($glob =~ s/\A\*\*//) { $re .= '.*' }
        elsif ($glob =~ s/\A\*//) { $re .= '[^/]*' }
        elsif ($glob =~ s/\A\?//) { $re .= '[^/]' }
        else { $re .= quotemeta(substr($glob, 0, 1, '')) }
    }
    $allowed = 1 if $path =~ /\A$re\z/;
}
exit 1 unless $allowed;

binmode STDIN;
local $/;
my $html = <STDIN>;
exit 1 unless defined $html;
my @lines = split /\n/, $html, -1;
exit 1 if $el > @lines || $sc > length($lines[$sl-1]);
# Gitleaks 8.x can count a preceding newline in columns after the first fragment
# line. Require the conservative envelope of BOTH interpretations inside the block,
# rather than trusting the narrower (possibly shifted) range. A final newline is a byte.
my $end_limit = length($lines[$el-1]) + ($el < @lines ? 1 : 0);
exit 1 if $ec > $end_limit;
my @starts = (0);
for my $i (0 .. $#lines-1) { push @starts, $starts[-1] + length($lines[$i]) + 1 }
my $start_column = $sc - (($sl > 1 && $sc > 1) ? 1 : 0);
my ($start, $end) = ($starts[$sl-1] + $start_column - 1, $starts[$el-1] + $ec);

my $candidate;
my @blocks;
my $raw = '';
my $inert = 0;
pos($html) = 0;
while ((pos($html) // 0) < length($html)) {
    if ($raw ne '') {
        # Raw-text elements cannot authorize an identity block, even if they contain markup.
        exit 1 unless $html =~ m{\G.*?</\Q$raw\E\s*>}gcis;
        $raw = '';
        next;
    }
    if ($html =~ /\G[^<]+/gc) { next }
    if ($html =~ /\G<!--.*?-->/gcs) { undef $candidate; next }
    if ($html =~ /\G<!doctype\s+[^>]*>/gci) { undef $candidate; next }
    # Quoted > is part of an attribute, not a tag boundary. Unknown/malformed markup refuses.
    exit 1 unless $html =~ m{\G<( /? )([a-z][a-z0-9:-]*)( (?: [^<>"'] | "[^"]*" | '[^']*' )* )>}gcix;
    my ($closing, $tag, $attrs) = ($1, lc($2), $3);
    my ($tag_start, $tag_end) = ($-[0], $+[0]);
    if ($closing) {
        exit 1 unless $attrs =~ /\A\s*\z/;
        if (defined $candidate && $tag eq 'p') { push @blocks, [$candidate, $tag_start] }
        undef $candidate;
        $inert-- if ($tag eq 'template' || $tag eq 'noscript') && $inert;
        next;
    }
    # A legal block must contain text only, no nested elements or implicit closing tags.
    undef $candidate;
    my %attributes;
    pos($attrs) = 0;
    while ((pos($attrs) // 0) < length($attrs)) {
        last if $attrs =~ m{\G\s*/?\s*\z}gc;
        exit 1 unless $attrs =~ /\G\s+([a-z_:][a-z0-9_.:-]*)(?:\s*=\s*(?:"[^"]*"|'[^']*'|[^\s"'=<>`]+))?/gci;
        my $key = lc $1;
        exit 1 if $attributes{$key}++;
    }
    if ($tag =~ /\A(?:script|style|textarea|title|xmp|iframe|noembed|noframes)\z/) { $raw = $tag }
    exit 1 if $tag eq 'plaintext';
    $inert++ if $tag eq 'template' || $tag eq 'noscript';
    if ($tag eq 'p' && !$inert && exists $attributes{'data-legal-identity'} && $attrs !~ m{/\s*\z}) {
        $candidate = $tag_end;
    }
}
exit 1 if $raw ne '' || $inert;
for my $block (@blocks) { exit 0 if $start >= $block->[0] && $end <= $block->[1] }
exit 1;
