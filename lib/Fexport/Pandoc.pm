package Fexport::Pandoc;

use v5.20;
use strict;
use warnings;
use Exporter 'import';
use List::Util       qw(any);
use Text::ParseWords qw(shellwords);    # 核心模块，用于解析命令行字符串

our @EXPORT_OK = qw(build_cmd);

# fexport 内部 key，不传给 pandoc
my %FEXPORT_ONLY = map { $_ => 1 } qw(ext intermediate intermediate_ext from-extensions from _share_dir);

# 将格式配置 hashref 转换为 pandoc CLI 参数列表
sub _format_opts_to_args {
  my ($format_opts) = @_;
  return () unless ref $format_opts eq 'HASH';

  my @args;
  for my $key ( sort keys %$format_opts ) {
    next if $FEXPORT_ONLY{$key};
    my $val = $format_opts->{$key};
    next unless defined $val;

    if ( $key eq 'variables' || $key eq 'variable' ) {

      # -V key=value 形式
      if ( ref $val eq 'HASH' ) {
        for my $k ( sort keys %$val ) {
          my $v = $val->{$k};
          if ( ref $v eq 'ARRAY' ) {

            # 数组值以逗号连接 (适用于 biblatexoptions 等)
            push @args, '-V', "$k=" . join( ',', @$v );
          }
          elsif ( defined $v ) {
            push @args, '-V', "$k=$v";
          }
        }
      }
    }
    elsif ( $key eq 'metadata' ) {

      # -M key=value 形式，跳过数组/哈希值 (应在文档 frontmatter 中设置)
      if ( ref $val eq 'HASH' ) {
        for my $k ( sort keys %$val ) {
          my $v = $val->{$k};
          next if ref $v;    # 跳过复杂类型
          push @args, '-M', defined($v) ? "$k=$v" : $k;
        }
      }
    }
    elsif ( $key eq 'html-math-method' ) {

      # {method: katex} -> --html-math-method=katex
      if ( ref $val eq 'HASH' && defined $val->{method} ) {
        push @args, "--html-math-method", $val->{method};
      }
      elsif ( !ref $val ) {
        push @args, "--html-math-method", $val;
      }
    }
    elsif ( ref $val eq 'ARRAY' ) {

      # 重复选项：--key value1  --key value2 ...
      for my $item (@$val) {
        push @args, "--$key", $item;
      }
    }
    elsif ( ref $val eq '' ) {

      # 标量：布尔值只传 flag，其余传 --key value
      if ( $val eq '1' || $val eq 'true' ) {
        push @args, "--$key";
      }
      elsif ( $val eq '0' || $val eq 'false' || $val eq '' ) {

        # 假值：不传
      }
      else {
        push @args, "--$key", $val;
      }
    }

    # HASH (非特殊 key) 暂不处理
  }

  return @args;
}

sub build_cmd {
  my ( $config, $params ) = @_;

  # 1. 确定输入格式
  my $from      = $params->{from} // 'md';
  my $input_fmt = $from;

  # 优先使用格式配置中已构建好的 from 字符串 (含 markdown 扩展)
  my $fmt_from = $params->{format_opts} && $params->{format_opts}{from};
  if ( $fmt_from && index( $from, '+' ) == -1 ) {
    $input_fmt = $fmt_from;
  }

  # 否则按原逻辑：若当前格式在 markdown_exts 列表中，使用 markdown_fmt
  elsif ( defined $config->{markdown_exts} && any { $_ eq $from } @{ $config->{markdown_exts} } ) {
    my $fmt = $config->{markdown_fmt};

    # Support both string and array format
    $input_fmt = ref($fmt) eq 'ARRAY' ? join( '+', @$fmt ) : $fmt;
  }

  # 2. 解析基础命令 (e.g. "pandoc +RTS -M512M")
  my @base_cmd = shellwords( $config->{cmd} // 'pandoc' );

  # 3. 解析额外选项
  my @config_opts =
    ref( $config->{user_opts} ) eq 'ARRAY'
    ? @{ $config->{user_opts} }
    : shellwords( $config->{user_opts} // '' );
  my @cli_opts =
    ref( $params->{user_opts} ) eq 'ARRAY'
    ? @{ $params->{user_opts} }
    : shellwords( $params->{user_opts} // '' );

  # 4. 格式配置转 CLI 参数 (优先级低于用户配置和 CLI)
  my @format_args = _format_opts_to_args( $params->{format_opts} );

  # 5. 构建最终命令列表
  my @cmd = (
    @base_cmd,
    '--from', $input_fmt,
    @{ $config->{filters} // [] },
    @format_args,    # 格式默认值 (最低优先级)
    @config_opts,    # 配置文件中的选项
    @cli_opts,       # CLI 选项 (最高优先级)
  );

  # 6. 添加 Verbose 标记
  push @cmd, '--verbose' if $params->{verbose};

  return @cmd;
}

1;
