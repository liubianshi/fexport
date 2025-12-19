use strict;
use warnings;
use Test::More;
use Path::Tiny;
use Fexport::Config qw(process_params);

my $temp_dir = Path::Tiny->tempdir;
my $cwd = $temp_dir->absolute->stringify;

subtest 'Auto create output directory' => sub {
    my $infile = "input.md";
    my $out_dir_name = "new_output_dir";
    my $out_dir = $temp_dir->child($out_dir_name);
    
    ok(! -d $out_dir, "Output dir does not exist initially");

    my $opts = {
        outdir => $out_dir_name,
        to => 'html'
    };
    
    # process_params should trigger creation
    process_params($opts, $infile, $cwd);
    
    ok(-d $out_dir, "Output dir was created automatically");
};

done_testing();
