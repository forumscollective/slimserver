#!/usr/bin/env perl
use strict; use warnings;
use Data::Dumper; $Data::Dumper::Terse=1; $Data::Dumper::Indent=0;

# Minimal reproduction of tag assembly logic from Importer.pm without LMS context.
# Usage: perl repro_shift.pl /tmp/dbtemplate.db "/mnt/usbc1/.../05 - A Wave.flac"
# Prints raw alib row subset and assembled contributor tags to verify if role label shift
# (e.g. empty CONDUCTOR showing 'LYRICIST') occurs inherently or only inside LMS runtime.

my ($db, $path) = @ARGV;
if (!$db || !$path) { die "Usage: $0 <alib.db> <absolute track path>\n"; }
-d $db && die "First argument must be SQLite file, not directory";
-f $db or die "SQLite file not found: $db";

my @cols = qw(artist albumartist composer conductor lyricist writer arranger band ensemble performer engineer producer mixer remixer genre style mood);
my $colList = join(',', @cols);
my $escaped = $path; $escaped =~ s/'/''/g;
my $cmd = "sqlite3 '$db' \"SELECT $colList FROM alib WHERE __path = '$escaped';\"";
my $output = qx/$cmd/;
die "Row not found for path: $path\n" unless defined $output && length $output;
chomp $output;
my @vals = split(/\|/, $output); # default separator is | unless overridden; ensure matches sqlite3 default
if (@vals != @cols) {
        # Try tab separator fallback
        $cmd = "sqlite3 -separator '\t' '$db' \"SELECT $colList FROM alib WHERE __path = '$escaped';\"";
        $output = qx/$cmd/; chomp $output; @vals = split(/\t/, $output);
}
die "Unexpected column count (got " . scalar(@vals) . ", expected " . scalar(@cols) . ")\n" if @vals != @cols;
my %row; @row{@cols} = @vals;

my %subset; @subset{@cols} = map { $row{$_} } @cols;
print "RAW_SUBSET=" . Data::Dumper::Dumper(\%subset) . "\n";

sub splitMultiValue {
    my $val = shift; return unless defined $val && length $val;
    my @parts = map { s/^\s+|\s+$//gr } split /\\\\/, $val;
    @parts = grep { length $_ } @parts;
    return unless @parts; return @parts > 1 ? \@parts : $parts[0];
}

my %tags = (
    ARTIST      => splitMultiValue($row{'artist'}),
    ALBUMARTIST => splitMultiValue($row{'albumartist'}),
    COMPOSER    => splitMultiValue($row{'composer'}),
    CONDUCTOR   => splitMultiValue($row{'conductor'}),
    LYRICIST    => splitMultiValue($row{'lyricist'} || $row{'writer'}),
    ARRANGER    => splitMultiValue($row{'arranger'}),
    BAND        => splitMultiValue($row{'ensemble'}),
    PERFORMER   => splitMultiValue($row{'performer'}),
    ENGINEER    => splitMultiValue($row{'engineer'}),
    PRODUCER    => splitMultiValue($row{'producer'}),
    MIXER       => splitMultiValue($row{'mixer'}),
    REMIXER     => splitMultiValue($row{'remixer'}),
    GENRE       => splitMultiValue($row{'genre'}),
    STYLE       => splitMultiValue($row{'style'}),
    MOOD        => splitMultiValue($row{'mood'}),
);

my @roles = qw(ARTIST ALBUMARTIST COMPOSER CONDUCTOR LYRICIST ARRANGER BAND PERFORMER ENGINEER PRODUCER MIXER REMIXER GENRE STYLE MOOD);
my %flat; for my $r (@roles) { my $v = $tags{$r}; $flat{$r} = ref($v) eq 'ARRAY' ? join('|', @$v) : (defined $v ? $v : ''); }
print "ASSEMBLED_TAGS=" . Data::Dumper::Dumper(\%flat) . "\n";

# Detect shift pattern: empty raw field but tag equals next role label
for (my $i=0; $i < @roles - 1; $i++) {
    my $r1 = $roles[$i]; my $r2 = $roles[$i+1];
    my $k1 = lc $r1; my $k2 = lc $r2;
    my $rawEmpty = !defined $row{$k1} || $row{$k1} eq '';
    my $val = $flat{$r1};
    if ($rawEmpty && defined $val && $val eq $r2) {
        print "ROLESHIFT_DETECTED r1=$r1 placeholder='$val' nextRaw='" . (defined $row{$k2} ? $row{$k2} : '') . "'\n";
    }
}

print "Done.\n";
