use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use YAML       qw(Dump);

use_ok( 'Fexport::Config', qw(load_config merge_config get_format_config) );

# Test load_config
{
  my ( $fh, $filename ) = tempfile();
  print $fh "to: pdf\nkeep: 1\npandoc:\n  cmd: mypandoc\n";
  close $fh;

  my $config = load_config($filename);
  is( $config->{to},            'pdf',      'Loaded "to" from config' );
  is( $config->{keep},          1,          'Loaded "keep" from config' );
  is( $config->{pandoc}->{cmd}, 'mypandoc', 'Loaded nested "pandoc.cmd"' );

  unlink $filename;
}

# Test merge_config
{
  my $file_config = {
    to      => 'docx',
    verbose => 0,
    pandoc  => {
      cmd     => 'file_cmd',
      filters => ['f1'],
    }
  };

  my $cli_opts = {
    to          => 'html',    # Overrides file
    verbose     => 1,         # Overrides defaults
    pandoc_opts => '--foo'    # CLI override
  };

  my $merged = merge_config( $file_config, $cli_opts );

  is( $merged->{to},            'html',     'CLI overrides file config' );
  is( $merged->{verbose},       1,          'CLI overrides file/default' );
  is( $merged->{keep},          0,          'Defaults preserved if not set (default keep=0)' );
  is( $merged->{pandoc}->{cmd}, 'file_cmd', 'File config nested key preserved' );
  is_deeply( $merged->{pandoc}->{filters}, ['f1'], 'File config nested array preserved' );
}

# Test get_format_config
{
  my $html_config = get_format_config('html');
  ok( ref $html_config eq 'HASH', 'get_format_config returns a hashref for html' );
  is( $html_config->{ext}, 'html', 'html format ext is html' );
  ok( exists $html_config->{'syntax-highlighting'}, 'html has syntax-highlighting key' );

  my $unknown = get_format_config('_nonexistent_format_xyz');
  is_deeply( $unknown, {}, 'unknown format returns empty hash' );
}

# Test merge_config populates format_opts
{
  my $merged = merge_config( {}, { to => 'html' } );
  ok( defined $merged->{format_opts}, 'merge_config populates format_opts when to is set' );
  is( $merged->{format_opts}{ext}, 'html', 'format_opts contains ext for html' );

  my $merged_no_to = merge_config( {}, {} );
  ok( !defined $merged_no_to->{format_opts}, 'format_opts absent when no to is set' );
}

done_testing();
