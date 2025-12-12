use strict;
use warnings;
use Getopt::Long;

# Getopt::Long::Configure("bundling"); # Commented out

my $OUTFILE;
my $OUTDIR;
my $TO;

GetOptions(
  'outfile|o=s' => \$OUTFILE,
  'outdir|od=s' => \$OUTDIR,
  'to|t=s'      => \$TO,
);

print "OUTFILE: " . ($OUTFILE // "undef") . "\n";
print "OUTDIR: " . ($OUTDIR // "undef") . "\n";
print "TO: " . ($TO // "undef") . "\n";
print "ARGV: " . join(", ", @ARGV) . "\n";
