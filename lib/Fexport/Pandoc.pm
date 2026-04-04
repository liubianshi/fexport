package Fexport::Pandoc;

use v5.20;
use strict;
use warnings;
use Exporter 'import';
use List::Util       qw(any);
use Text::ParseWords qw(shellwords);    # 核心模块，用于解析命令行字符串
use YAML::XS         qw(Dump);
use Encode           qw(decode_utf8 is_utf8 encode_utf8);
use File::Temp       qw(tempfile);

our @EXPORT_OK = qw(build_cmd);

# fexport 内部 key，不传给 pandoc
my %FEXPORT_ONLY =
  map { $_ => 1 } qw(ext intermediate intermediate_ext from-extensions from);

# 辅助函数：确保结构内所有字符串都是 Unicode 字符（带有 UTF8 flag）
# 防止 YAML::XS 将原始字节误认为 Latin-1 导致二次编码乱码（如 ç½...）
sub _normalize_internal {
  my ($data) = @_;
  return $data unless defined $data;
  if ( ref $data eq 'HASH' ) {
    return { map { $_ => _normalize_internal($data->{$_}) } keys %$data };
  }
  elsif ( ref $data eq 'ARRAY' ) {
    return [ map { _normalize_internal($_) } @$data ];
  }
  elsif ( ref $data eq '' ) {
    return $data if is_utf8($data);
    # 如果字符串包含非 ASCII 字符但没有 flag，手动补全解码
    return decode_utf8($data);
  }
  return $data;
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

  # 4. 格式配置转临时 defaults 文件
  my $defaults_file;
  if ( my $format_opts = $params->{format_opts} ) {
    my %pandoc_defaults;
    for my $key ( keys %$format_opts ) {
      next if $FEXPORT_ONLY{$key};
      $pandoc_defaults{$key} = $format_opts->{$key};
    }

    if ( keys %pandoc_defaults ) {
      my ( $fh, $filename ) = tempfile( "fexport-pandoc-defaults-XXXXXX", TMPDIR => 1, SUFFIX => '.yaml', UNLINK => 1 );
      binmode $fh; # 原始字节写入

      # 配置 YAML::XS
      local $YAML::XS::Boolean = "JSON::PP";
      local $YAML::XS::Unicode = 0; # Dump 返回编码后的 UTF-8 字节流

      # 确保所有内容都有 UTF8 flag，防止二次编码
      my $normalized = _normalize_internal( \%pandoc_defaults );

      my $yaml_bytes = Dump($normalized);
      print $fh $yaml_bytes;
      close $fh;
      $defaults_file = $filename;

      if ( $params->{verbose} ) {
        # 调试输出：将字节流解码为字符打印
        my $readable = $yaml_bytes;
        utf8::decode($readable);
        warn "[Debug] Generated Pandoc Defaults ($filename):\n$readable\n";
      }
    }
  }

  # 5. 构建最终命令列表
  my @cmd = ( @base_cmd, '--from', $input_fmt, @{ $config->{filters} // [] }, );

  push @cmd, "--defaults", $defaults_file if $defaults_file;

  push @cmd, (
    @config_opts,    # 配置文件中的选项
    @cli_opts,       # CLI 选项 (最高优先级)
  );

  # 6. 添加 Verbose 标记
  push @cmd, '--verbose' if $params->{verbose};

  return @cmd;
}

1;
