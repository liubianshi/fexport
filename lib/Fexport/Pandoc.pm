package Fexport::Pandoc;

use v5.20;
use strict;
use warnings;
use Exporter 'import';
use List::Util       qw(any);
use Text::ParseWords qw(shellwords);    # 核心模块，用于解析命令行字符串

our @EXPORT_OK = qw(build_cmd);

sub build_cmd {
  my ( $config, $params ) = @_;

  # 1. 确定输入格式
  my $from      = $params->{from} // 'md';
  my $input_fmt = $from;

  # 如果 config 中定义了 markdown_exts 且当前格式在其中，则使用配置的 markdown_fmt
  if ( defined $config->{markdown_exts} && any { $_ eq $from } @{ $config->{markdown_exts} } ) {
    $input_fmt = $config->{markdown_fmt};
  }

  # 2. 解析基础命令 (e.g. "pandoc +RTS -M512M")
  # 使用 shellwords 将字符串拆分为安全列表
  # 这样 system/IPC::Run3 才能正确识别程序名和初始参数
  my @base_cmd = shellwords( $config->{cmd} // 'pandoc' );

  # 3. 解析额外选项 (String -> List)
  # 这一步至关重要：它能正确处理带引号的选项，如 --variable title="Hello World"
  my @config_opts = shellwords( $config->{user_opts} // '' );
  my @cli_opts    = shellwords( $params->{user_opts} // '' );

  # 4. 构建最终命令列表
  # 注意：在列表上下文中，绝对不要手动给参数加引号（如 "--from=\"$fmt\"" 是错误的）
  # 系统会自动处理参数边界。
  my @cmd = (
    @base_cmd,
    '--from', $input_fmt,             # 推荐拆分为两个元素
    @{ $config->{filters} // [] },    # 确保 filters 是数组引用
    @config_opts,                     # 配置文件中的选项
    @cli_opts                         # CLI 选项 (放在最后以实现覆盖)
  );

  # 5. 添加 Verbose 标记
  push @cmd, '--verbose' if $params->{verbose};

  # 返回纯净的参数列表
  return @cmd;
}

1;
