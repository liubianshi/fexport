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

sub run_fexport {
    my ($args) = @_;
    my $cmd = "$cmd_base $args 2>&1";
    my $out = qx/$cmd/;
    return $out;
}

# Test 1: Absolute path - output should appear in file's directory (subdir)
# When input is absolute path, workdir = file's parent directory
{
    my $abs_md_file = File::Spec->rel2abs($md_file);
    my $out = run_fexport("$abs_md_file");
    my $expected_output = File::Spec->catfile($subdir, 'test.html');
    
    if (!-e $expected_output) {
        diag("Output not found in subdir. Command output:\n$out");
    }
    ok(-e $expected_output, "Absolute path: Output generated in file's directory");
    unlink $expected_output if -e $expected_output;
}

# Test 2: Relative path - output should appear in current directory
# When input is relative path, workdir = current directory
chdir $temp_dir;
{
    my $out = run_fexport("subdir/test.md");
    my $expected_output = File::Spec->catfile($temp_dir, 'test.html');
    
    if (!-e $expected_output) {
        diag("Output not found in temp_dir. Command output:\n$out");
        if (-e File::Spec->catfile($subdir, 'test.html')) {
             diag("BUT found in subdir/test.html");
        }
    }
    ok(-e $expected_output, "Relative path: Output generated in current dir");
    unlink $expected_output if -e $expected_output;
}

# Test 3: Sanity check
ok(1, "Sanity check");

# Clean
chdir $cwd;

done_testing();

