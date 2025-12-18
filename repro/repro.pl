use strict;
use warnings;
use File::Basename qw(basename dirname);
use Cwd qw(getcwd);
use File::Spec;

my $INFILE = "doc/_empirical_method.qmd";
my $OUTFORMAT = "docx";
my $OUTDIR = "out/manuscript";
my $current_pwd = getcwd();

my $out_basename = basename($INFILE);
$out_basename =~ s/\.\w+$/.$OUTFORMAT/r; # This uses /r non-destructive substitution! Wait.

# Check perl version for /r support. v5.20 supported it.
# Wait, s///r returns the string. If I assign it back?
# $out_basename = basename($INFILE) =~ s///r; 
# This assigns the RESULT of substitution to $out_basename. Correct.

print "Basename: $out_basename\n";

my $out_dir = $OUTDIR;
print "OutDir: $out_dir\n";

my $abs_out_dir = File::Spec->rel2abs($out_dir, $current_pwd);
print "AbsOutDir: $abs_out_dir\n";

my $OUTFILE = File::Spec->catfile($abs_out_dir, $out_basename);
print "OUTFILE: $OUTFILE\n";

my $local_outfile = basename($OUTFILE);
print "Local: $local_outfile\n";

# Test zip command string
my $cmd = qq/zip -r -q "$local_outfile" */;
print "CMD: $cmd\n";
