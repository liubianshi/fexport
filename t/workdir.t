use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir tempfile);
use File::Spec;
use Cwd qw(getcwd abs_path);

# Test requires running the script logic, which is hard to unit test directly 
# since it modifies global state (chdir) and is a script.
# We will use system calls to run the script against test files.

my $script = File::Spec->rel2abs('script/fexport');
my $perl   = $^X;
my $lib    = File::Spec->rel2abs('lib');
my $cmd_base = "$perl -I$lib $script";

# Setup test environment
my $cwd = getcwd();
my $temp_dir = tempdir(CLEANUP => 1);
my $subdir = File::Spec->catdir($temp_dir, 'subdir');
mkdir $subdir;

# Create a test markdown file in subdir
my $md_file = File::Spec->catfile($subdir, 'test.md');
open my $fh, '>', $md_file or die $!;
print $fh "# Hello\n";
close $fh;

# Test 1: Default (wd_mode=file) - Output should appear in subdir by default if not specified? 
# OR check stdout for "Output: /path/to/subdir/test.html" logic.
# The script prints the output file path at the end.
# If wd_mode=file, input path logic might change.

sub run_fexport {
    my ($args) = @_;
    my $cmd = "$cmd_base $args 2>&1";
    my $out = qx/$cmd/;
    return $out;
}

# Case A: wd_mode=current (explicit). Working dir should stay as Cwd (temp_dir parent usually or wherever we run from).
# If we run from $cwd, and input is relative "subdir/test.md" (if we were in temp_dir).
# Let's adjust Cwd to temp_dir for testing.
chdir $temp_dir;

# Case 1: Default (file). Input: subdir/test.md
# Expectation: Scripts chdirs to subdir. Output should be in subdir (since no outdir specified and outfile defaults to input location logic).
# Wait, if script chdirs to subdir, effectively output is ./test.html relative to new pwd, which is subdir/test.html relative to start.
{
    my $out = run_fexport("--wd-mode file subdir/test.md");
    if (!-e File::Spec->catfile($subdir, 'test.html')) {
        diag("Output not found in subdir. Command output:\n$out");
        if (-e File::Spec->catfile($temp_dir, 'test.html')) {
            diag("BUT found in temp_dir/test.html");
        }
    }
    ok(-e File::Spec->catfile($subdir, 'test.html'), "wd_mode=file: Output generated in subdir");
}

# Case 2: wd_mode=current. Input: subdir/test.md
# Expectation: Script stays in current dir. Output defaults to where?
# Logic: $out_dir = $opts{outdir} // (defined $opts{outfile} ? dirname($opts{outfile}) : $current_pwd);
# If outfile not defined: out_basename is test.html. 
# out_dir defaults to current_pwd (if outfile not defined).
# So output should be in current dir ($temp_dir), NOT subdir.
# WAIT, original code: 
# my $out_dir = $opts{outdir} // (defined $opts{outfile} ? dirname($opts{outfile}) : $current_pwd);
# If outfile undefined, out_dir = current_pwd.
# So test.html is created in current dir.
{
    my $out = run_fexport("--wd-mode current subdir/test.md");
    if (!-e File::Spec->catfile($temp_dir, 'test.html')) {
        diag("Output not found in temp_dir. Command output:\n$out");
        if (-e File::Spec->catfile($subdir, 'test.html')) {
             diag("BUT found in subdir/test.html");
        }
    }
    ok(-e File::Spec->catfile($temp_dir, 'test.html'), "wd_mode=current: Output generated in current dir");
    ok(!-e File::Spec->catfile($subdir, 'test.html.old'), "Sanity check"); 
    # (Note: previous test created subdir/test.html, cleanup or ignore)
    unlink File::Spec->catfile($subdir, 'test.html');
    unlink File::Spec->catfile($temp_dir, 'test.html');
}

# Clean
chdir $cwd;

done_testing();
