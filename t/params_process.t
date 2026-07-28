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

subtest 'Absolute path -> workdir is parent dir' => sub {
    # Create the file first
    $temp_dir->child('doc')->mkpath;
    $temp_dir->child('doc/input.md')->touch;
    
    # Use ABSOLUTE path - should use file's parent as workdir
    my $infile = $temp_dir->child('doc/input.md')->absolute->stringify;
    my $opts = { workdir => undef, outdir => undef, outfile => undef, to => 'html' };
    
    my ($wd, $in, $out) = process_params($opts, $infile, $cwd);
    
    # check wd is absolute doc dir
    is(canon($wd), canon($temp_dir->child('doc')), "Workdir is input file dir");
    # check in is relative to wd (should be just filename)
    is($in, 'input.md', "Infile is relative to workdir");
    # check out is absolute (returned as absolute path to avoid downstream
    # wide-char vs byte-cwd concat issue in Path::Tiny->absolute)
    is(canon($out), canon($temp_dir->child('doc/input.html')), "Outfile is absolute path in workdir");
};

subtest 'Relative path -> workdir is current dir' => sub {
    # Use RELATIVE path - should use current dir as workdir
    my $infile = "input.md";
    my $opts = { 
        outdir => 'dist', 
        outfile => 'sub/output.html', 
        to => 'html' 
    };
    $temp_dir->child('input.md')->touch;
    
    my ($wd, $in, $out) = process_params($opts, $infile, $cwd);
    
    is(canon($wd), canon($cwd), "Workdir is current");
    
    # Expected: outdir 'dist' + basename('sub/output.html') = 'dist/output.html'
    # Returned as absolute path joined with workdir (cwd)
    is(canon($out), canon(path($cwd)->child('dist/output.html')), "Outfile re-parented to outdir (flattened)");
};

subtest 'Absolute Outfile' => sub {
    # Relative infile, absolute outfile
    my $infile = "input.md";
    my $abs_out = $temp_dir->child('custom/out.html')->absolute->stringify;
    
    my $opts = { 
        outfile => $abs_out,
        to => 'html'
    };
    
    my ($wd, $in, $out) = process_params($opts, $infile, $cwd);
    
    # wd is cwd (infile is relative)
    is(canon($wd), canon($cwd), "Workdir is current");
    
    # out should match the original absolute outfile
    is(canon($out), canon($abs_out), "Absolute outfile preserved as absolute");
};

# 扩展名必须归一到 script/fexport 用来分派渲染器的 md / rmd / qmd 三个键。
# 未归一时 .Rmd / .markdown 会落空全部分支，pandoc 收到空 stdin 却退出码 0，静默产出空文档。
subtest 'Input extension normalizes to a dispatch key' => sub {
    my %expected = (
        'a.md'         => 'md',
        'a.markdown'   => 'md',
        'a.MD'         => 'md',
        'a.rmd'        => 'rmd',
        'a.Rmd'        => 'rmd',
        'a.RMD'        => 'rmd',
        'a.rmarkdown'  => 'rmd',
        'a.qmd'        => 'qmd',
        'a.QMD'        => 'qmd',
        'a.quarto'     => 'qmd',
    );

    for my $name (sort keys %expected) {
        my $opts = { to => 'html' };
        process_params($opts, $name, $cwd);
        is($opts->{from}, $expected{$name}, "$name -> $expected{$name}");
    }

    # 显式 --from 同样归一，用户敲 -f Rmd 不该掉进空文档
    my $explicit = { to => 'html', from => 'Rmd' };
    process_params($explicit, 'a.md', $cwd);
    is($explicit->{from}, 'rmd', "explicit --from is normalized too");

    # 无法识别的扩展名退回 markdown，但必须出声警告，不能静默
    my $warned = '';
    my $unknown = { to => 'html' };
    {
        local $SIG{__WARN__} = sub { $warned .= $_[0] };
        process_params($unknown, 'a.txt', $cwd);
    }
    is($unknown->{from}, 'md', "unknown extension falls back to markdown");
    like($warned, qr/Unknown input format/, "unknown extension warns instead of failing silently");
};

done_testing();

