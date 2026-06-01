use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use YAML       qw(Dump);
use Storable   qw(dclone);
use JSON::PP   ();

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

# ---- 嵌套结构 (global / formats) 覆盖测试 ----
# 这一组放在最后：formats override 会修改 Config.pm 的模块级 %FORMAT_RAW，
# 影响后续 get_format_config 的返回值，所以必须在其它 case 之后跑。

# Case 1: global.* 上提到顶层
{
  my $file_config = {
    global => {
      verbose => 1,
      pandoc  => { cmd => 'nested_pandoc' },
    },
  };

  my $merged = merge_config( $file_config, {} );

  is( $merged->{verbose},       1,               'global.verbose 被上提到顶层' );
  is( $merged->{pandoc}->{cmd}, 'nested_pandoc', 'global.pandoc.cmd 深合并进 defaults' );
  ok( !exists $merged->{global}, '原 global 键不再以嵌套形式残留' );

  # defaults 中其它 pandoc.* 字段应仍存在（深合并而非整段替换）
  ok( exists $merged->{pandoc}->{filters},     'defaults 中的 pandoc.filters 保留' );
  ok( exists $merged->{pandoc}->{share_dir},   'defaults 中的 pandoc.share_dir 保留' );
}

# Case 2: 不污染调用方 — merge_config 调用前后 $file_config 应保持一致
{
  my $file_config = {
    global  => { verbose => 1 },
    formats => { pdf     => { listings => 0 } },
    to      => 'html',
  };

  my $snapshot = dclone($file_config);

  merge_config( $file_config, {} );

  is_deeply( $file_config, $snapshot, 'merge_config 不应修改传入的 $file_config' );
}

# Case 3: formats.pdf 深合并 — 覆盖 citeproc，其它字段（template/pdf-engine）保留
{
  my $file_config = {
    formats => {
      pdf => { citeproc => JSON::PP::false() },
    },
  };

  merge_config( $file_config, { to => 'pdf' } );

  my $pdf = get_format_config('pdf');
  ok( !$pdf->{citeproc},        'formats.pdf.citeproc 被覆盖为 false' );
  ok( exists $pdf->{template},  'formats.pdf.template 仍保留（深合并）' );
  is( $pdf->{'pdf-engine'}, 'xelatex', 'formats.pdf."pdf-engine" 仍保留' );
}

# Case 4: 新增未知 format
{
  my $file_config = {
    formats => {
      custom_xyz => { ext => 'foo', citeproc => JSON::PP::true() },
    },
  };

  merge_config( $file_config, {} );

  my $custom = get_format_config('custom_xyz');
  is( $custom->{ext}, 'foo', '新增 format 可通过 get_format_config 取到' );
  ok( $custom->{citeproc}, '新增 format 的字段完整保留' );
}

# Case 5: 嵌套结构 + 顶层混合用法（formats 嵌套 + outfile 扁平）
{
  my $file_config = {
    formats => { docx => { ext => 'docx2' } },
    to      => 'docx',
    outfile => '/tmp/whatever.docx',
  };

  my $merged = merge_config( $file_config, {} );

  is( $merged->{to},      'docx',               '扁平 to 仍生效' );
  is( $merged->{outfile}, '/tmp/whatever.docx', '扁平 outfile 仍生效' );
  is( $merged->{format_opts}->{ext}, 'docx2', '嵌套 formats.docx 改写也生效' );
}

done_testing();
