use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use YAML qw(Dump);

use_ok('Fexport::Config', qw(load_config merge_config));

# Test load_config
{
    my ($fh, $filename) = tempfile();
    print $fh "to: pdf\nkeep: 1\npandoc:\n  cmd: mypandoc\n";
    close $fh;
    
    my $config = load_config($filename);
    is($config->{to}, 'pdf', 'Loaded "to" from config');
    is($config->{keep}, 1, 'Loaded "keep" from config');
    is($config->{pandoc}->{cmd}, 'mypandoc', 'Loaded nested "pandoc.cmd"');
    
    unlink $filename;
}

# Test merge_config
{
    my $file_config = {
        to => 'docx',
        verbose => 0,
        pandoc => {
            cmd => 'file_cmd',
            filters => ['f1'],
        }
    };
    
    my $cli_opts = {
        to => 'html', # Overrides file
        verbose => 1, # Overrides defaults
        pandoc_opts => '--foo' # CLI override
    };
    
    my $merged = merge_config($file_config, $cli_opts);
    
    is($merged->{to}, 'html', 'CLI overrides file config');
    is($merged->{verbose}, 1, 'CLI overrides file/default');
    is($merged->{keep}, 0, 'Defaults preserved if not set (default keep=0)');
    is($merged->{pandoc}->{cmd}, 'file_cmd', 'File config nested key preserved');
    is_deeply($merged->{pandoc}->{filters}, ['f1'], 'File config nested array preserved');
}

done_testing();
