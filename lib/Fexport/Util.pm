package Fexport::Util;

use v5.20;
use strict;
use warnings;
use utf8;
use Exporter 'import';

# 核心依赖
use IPC::Run3 qw(run3);
use Path::Tiny;
use File::ShareDir qw(dist_file);
use FindBin        qw($RealBin);

# 导出函数名更新
our @EXPORT_OK = qw(
  run_pandoc
  run_pandoc_and_load
  save_lines
  find_pandoc_datadir
  get_pandoc_defaults_flag
  find_resource
);

# ==============================================================================
# 1. Pandoc 执行相关
# ==============================================================================

# 作用: 将内容写入 Pandoc 的 STDIN 并执行，输出结果依赖 $cmd_ref 中的 -o 参数
sub run_pandoc {
  my ( $content_lines_ref, $cmd_ref, $log_fh ) = @_;

  # 1. 记录日志 (调试用)
  if ($log_fh) {
    say {$log_fh} join( " ", @$cmd_ref );
  }

  # 2. 准备输入数据
  # 将数组行合并为单个字符串，供 STDIN 使用
  my $stdin_data = join( "", @$content_lines_ref );

  # 3. 安全执行命令 (IPC::Run3)
  # \@$cmd_ref   : 避免 Shell 注入
  # \$stdin_data : 写入 STDIN
  # \undef       : 忽略 STDOUT (因为通常 Pandoc 通过 --output 写文件)
  # $log_fh      : 捕获 STDERR
  run3 $cmd_ref, \$stdin_data, \undef, $log_fh;

  # 4. 错误检查
  if ( $? != 0 ) {

    # $? >> 8 获取真实退出码
    my $exit_code = $? >> 8;
    die "Error: Pandoc exited with code $exit_code. Check logs for details.\n";
  }

  return 1;    # 成功返回真值
}

# 作用: 运行 Pandoc 生成文件，然后立即把生成的文件读回内存
# 优化: 不再通过参数引用(@$out)返回数据，而是直接 return 数组
sub run_pandoc_and_load {
  my ( $in_lines_ref, $cmd_ref, $outfile, $log_fh ) = @_;

  # 1. 执行转换
  run_pandoc( $in_lines_ref, $cmd_ref, $log_fh );

  # 2. 读取结果
  # 使用 Path::Tiny 对象
  my $file = path($outfile);

  if ( $file->exists ) {

    # 优化: 使用 lines_utf8 确保编码正确
    # chomp => 0 保留换行符，与原逻辑保持一致
    return $file->lines_utf8( { chomp => 0 } );
  }
  else {
    warn "Warning: Expected output file '$outfile' was not created by pandoc.\n";
    return ();
  }
}

# ==============================================================================
# 2. 文件 I/O
# ==============================================================================

# 作用: 将数组行写入文件
sub save_lines {
  my ( $lines_ref, $outfile ) = @_;

  # 优化: 使用 spew_utf8 自动处理编码
  path($outfile)->spew_utf8( join( "", @$lines_ref ) );
}

# ==============================================================================
# 3. 资源与配置查找
# ==============================================================================

sub find_pandoc_datadir {
  state $datadir;
  return $datadir if defined $datadir;

  # 1. 尝试通过 pandoc --version 获取
  # 使用 IPC::Run3 或 qx 安全调用? qx 对于 simple command 尚可
  my $output = qx(pandoc --version);

  if ( $output && $output =~ /User data directory:\s*([^\s]+)/m ) {
    $datadir = $1;
  }
  else {
    # 2. 失败回退: 检查默认目录 ~/.pandoc
    my $default_path = path( $ENV{HOME} )->child(".pandoc");
    $datadir = $default_path->is_dir ? $default_path->stringify : "";
  }

  return $datadir;
}

# 作用: 返回类似 "-d2html" 的默认配置文件参数
sub get_pandoc_defaults_flag {
  my $format = shift;

  my $datadir = find_pandoc_datadir();
  return "" unless $datadir;

  my $defaults_dir = path($datadir)->child("defaults");
  return "" unless $defaults_dir->is_dir;

  # 1. 检查 Mac 特有配置 (优先)
  if ( $^O eq 'darwin' ) {
    if ( $defaults_dir->child("2${format}_mac.yaml")->exists ) {
      return "-d2${format}_mac";
    }
  }

  # 2. 检查通用配置
  if ( $defaults_dir->child("2$format.yaml")->exists ) {
    return "-d2$format";
  }

  return "";
}

# 作用: 在开发目录、ShareDir、脚本同级目录查找文件
sub find_resource {
  my $filename = shift;

  # 1. 开发环境/本地路径 (../share)
  my $local = path($RealBin)->parent->child( "share", $filename );
  return $local->absolute->stringify if $local->exists;

  # 2. 发行版安装路径 (File::ShareDir)
  # 使用 eval 捕获可能的错误 (如未安装)
  my $dist_path;
  eval { $dist_path = dist_file( 'fexport', $filename ); };
  return $dist_path if defined $dist_path && -e $dist_path;

  # 3. 遗留/平铺路径 (脚本同级)
  my $legacy = path($RealBin)->child($filename);
  return $legacy->absolute->stringify if $legacy->exists;

  warn "Warning: Resource file '$filename' not found in share directory or local path.\n";
  return undef;
}

1;
