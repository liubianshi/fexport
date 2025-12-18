use strict;
use warnings;
use Test::More;
use File::Spec;
use Cwd qw(getcwd abs_path);
use Path::Tiny;
use Fexport::Config qw(process_params);

# Create a temporary directory structure for testing
my $temp_dir = Path::Tiny->tempdir;
my $cwd = $temp_dir->absolute->stringify;

# Mock getcwd to return our temp dir? 
# process_params takes current_pwd as argument. Good design.

# Helper to canonicalize for comparison (remove . and ..)
sub canon {
    return path(shift)->absolute->stringify;
}

subtest 'Defaults (wd_mode=file)' => sub {
    my $infile = "doc/input.md";
    my $opts = { wd_mode => 'file', workdir => undef, outdir => undef, outfile => undef, to => 'html' };
    
    # Create dummy input
    $temp_dir->child('doc')->mkpath;
    $temp_dir->child('doc/input.md')->touch;
    
    my ($wd, $in, $out) = process_params($opts, $infile, $cwd);
    
    # check wd is absolute doc dir
    is(canon($wd), canon($temp_dir->child('doc')), "Workdir is input file dir");
    # check in is relative to wd (should be just filename)
    is($in, 'input.md', "Infile is relative to workdir");
    # check out is relative to wd (should be input.html)
    is($out, 'input.html', "Outfile is relative default in workdir");
};

subtest 'Outdir + Outfile (Reparenting)' => sub {
    my $infile = "input.md";
    my $opts = { 
        wd_mode => 'current', # Stay in root
        outdir => 'dist', 
        outfile => 'sub/output.html', 
        to => 'html' 
    };
    $temp_dir->child('input.md')->touch;
    
    my ($wd, $in, $out) = process_params($opts, $infile, $cwd);
    
    is(canon($wd), canon($cwd), "Workdir is current");
    
    # Expected: outdir 'dist' + basename('sub/output.html') = 'dist/output.html'
    # Relative to workdir (cwd)
    is($out, 'dist/output.html', "Outfile re-parented to outdir (flattened)");
};

subtest 'Absolute Outfile (should be respected?)' => sub {
    # If outdir is NOT set, and outfile is absolute.
    my $infile = "input.md";
    my $abs_out = $temp_dir->child('custom/out.html')->absolute->stringify;
    
    my $opts = { 
        wd_mode => 'file', 
        outfile => $abs_out,
        to => 'html'
    };
    
    my ($wd, $in, $out) = process_params($opts, $infile, $cwd);
    
    # wd is cwd (infile in root)
    is(canon($wd), canon($cwd), "Workdir is current");
    
    # out should be relative to wd
    # $abs_out relative to $cwd
    my $expected = path($abs_out)->relative($cwd)->stringify;
    is($out, $expected, "Absolute outfile converted to relative to workdir");
};

done_testing();
