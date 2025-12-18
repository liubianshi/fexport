package Fexport::Config;

use v5.20;
use strict;
use warnings;
use Exporter 'import';
use YAML::XS qw(LoadFile);
use Path::Tiny;
use Hash::Merge;
use Const::Fast;

our @EXPORT_OK = qw(load_config merge_config process_params);

# 实例化一个本地的 Merger 对象，避免污染全局 Hash::Merge 行为
my $merger = Hash::Merge->new('RIGHT_PRECEDENT');

# Global Defaults
const my %DEFAULTS = (
  to      => 'html',
  from    => undef,    # Auto-detect
  outfile => undef,
  workdir => undef,
  wd_mode => 'file',
  outdir  => undef,
  verbose => 0,
  keep    => 0,
  preview => 0,
  lang    => 'zh',
  pandoc  => {
    cmd           => "pandoc +RTS -M512M -RTS",
    markdown_fmt  => "markdown+emoji+east_asian_line_breaks+autolink_bare_uris",
    markdown_exts => [qw(md markdown rmd rmarkdown qmd quarto)],
    filters       =>
      [ '--filter=pandoc-crossref', '--lua-filter=rm-test-table-line.lua', '--citeproc', '--lua-filter=rsbc.lua' ],
    user_opts => "",
  }
);

sub load_config {
  my ($file) = @_;

  # 增加 -f 判断确保是文件
  return {} unless defined $file && -f $file;

  # eval 捕获异常是个好习惯
  my $config = eval { LoadFile($file) };
  if ($@) {
    warn "[Warn] Failed to load config file '$file': $@";
    return {};
  }
  return $config;
}

sub merge_config {
  my ( $file_config, $cli_opts ) = @_;

  # 链式合并：Defaults -> File -> CLI
  # 使用实例化的 $merger 对象，保证行为一致且线程安全
  my $merged = \%DEFAULTS;

  $merged = $merger->merge( $merged, $file_config ) if $file_config;
  $merged = $merger->merge( $merged, $cli_opts )    if $cli_opts;

  return $merged;
}

sub process_params {
  my ( $opts, $infile_raw, $current_pwd ) = @_;

  # 0. 初始化基础路径对象
  my $cwd        = path( $current_pwd // '.' )->absolute;
  my $infile_abs = defined $infile_raw ? $cwd->child($infile_raw) : undef;

  # 1. 确定工作目录 (Effective Working Directory)
  my $work_dir;
  if ( $opts->{workdir} ) {
    $work_dir = $cwd->child( $opts->{workdir} );
  }
  elsif ( $opts->{wd_mode} eq 'file' && $infile_abs ) {
    $work_dir = $infile_abs->parent;
  }
  else {
    $work_dir = $cwd;
  }

  # 2. 计算输入文件的相对路径 (相对于将要 chdir 的目录)
  my $resolved_infile = $infile_abs ? $infile_abs->relative($work_dir) : undef;

  # 3. 推断格式
  $opts->{from} //= ( $resolved_infile && $resolved_infile->suffix ) || 'md';
  $opts->{to}   //= "html";

  # 4. 确定最终输出文件路径 (修正后的逻辑)
  # 逻辑核心：如果存在 outdir，则 outfile 被视为基于 outdir 的相对路径
  my $abs_outfile;

  if ( defined $opts->{outdir} ) {

    # 场景 A: 显式指定 outdir
    my $base_out = $cwd->child( $opts->{outdir} );

    if ( defined $opts->{outfile} ) {

      # 修正: 使用 basename 避免路径嵌套或绝对路径冲突，保持与旧版本行为一致 (reprenting)
      $abs_outfile = $base_out->child( path( $opts->{outfile} )->basename );
    }
    elsif ($resolved_infile) {

      # 自动生成：取文件名(去掉后缀) + 新后缀
      my $name = $resolved_infile->basename(qr/\.[^.]+$/) . '.' . $opts->{to};
      $abs_outfile = $base_out->child($name);
    }
    else {
      $abs_outfile = $base_out->child( "output." . $opts->{to} );
    }
  }
  elsif ( defined $opts->{outfile} ) {

    # 场景 B: 无 outdir，仅有 outfile
    # 用户提供的 outfile 相对于 cwd.
    $abs_outfile = $cwd->child( $opts->{outfile} );
  }
  else {
    # 场景 C: 默认输出到 work_dir
    my $base_out = $work_dir;
    my $name =
        $resolved_infile
      ? $resolved_infile->basename(qr/\.[^.]+$/) . '.' . $opts->{to}
      : "output." . $opts->{to};
    $abs_outfile = $base_out->child($name);
  }

  # 5. 返回相对于 work_dir 的路径 (因为脚本后续会 chdir 到 work_dir)
  my $rel_outfile = $abs_outfile->relative($work_dir);

  # 返回字符串路径 (显式 stringify 避免对象泄露给不识别 Path::Tiny 的旧代码)
  return ( "$work_dir", "$resolved_infile", "$rel_outfile" );
}

1;

